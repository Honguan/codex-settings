param(
    [switch]$Flush
)

$ErrorActionPreference = 'Stop'
$hookSource = 'project'
$hookVersion = 'crlf-v2'
$script:toolName = 'unknown'
$script:payloadParsed = $false
$script:rejectedCount = 0

$hookDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $hookDir)
$rootMarker = Join-Path $projectRoot '.codex-root'
if (-not (Test-Path -LiteralPath $rootMarker -PathType Leaf)) {
    Write-Error "HookSource=$hookSource HookVersion=$hookVersion ToolName=$script:toolName PayloadParsed=$script:payloadParsed StateFile=unresolved Tracked=0 Converted=0 Verified=0 Rejected=0 Failed=1 Error=CVS project root marker was not found: $rootMarker" -ErrorAction Continue
    exit 1
}

$projectRoot = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/')
$projectPrefix = $projectRoot + [IO.Path]::DirectorySeparatorChar
$maxFileSize = 10MB
$quietPeriodSeconds = 2
$allowedExtensions = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($extension in @(
    '.php', '.inc', '.phtml', '.js', '.jsx', '.ts', '.tsx', '.css', '.scss', '.less',
    '.html', '.htm', '.xml', '.json', '.yaml', '.yml', '.toml', '.ini', '.conf', '.config',
    '.sql', '.md', '.txt', '.csv', '.ps1', '.psm1', '.bat', '.cmd', '.java', '.cs', '.go',
    '.rs', '.py', '.rb', '.lua'
)) {
    [void]$allowedExtensions.Add($extension)
}

$stateBase = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'CodexSettings\HookState'
} else {
    Join-Path ([IO.Path]::GetTempPath()) 'CodexSettings-HookState'
}

$sha = [Security.Cryptography.SHA256]::Create()
try {
    $rootHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($projectRoot)))).Replace('-', '').Substring(0, 16)
} finally {
    $sha.Dispose()
}
$stateFile = Join-Path $stateBase ("crlf-v2-$rootHash.json")
$stateMutex = New-Object System.Threading.Mutex($false, "CodexSettings.Crlf.v2.$rootHash")

function Write-HookFailure {
    param(
        [Parameter(Mandatory = $true)][string]$ErrorMessage,
        [int]$Tracked = 0,
        [int]$Converted = 0,
        [int]$Verified = 0,
        [int]$Failed = 1
    )

    Write-Error "HookSource=$hookSource HookVersion=$hookVersion ToolName=$script:toolName PayloadParsed=$script:payloadParsed StateFile=$stateFile Tracked=$Tracked Converted=$Converted Verified=$Verified Rejected=$script:rejectedCount Failed=$Failed Error=$ErrorMessage" -ErrorAction Continue
}

function Write-HookResult {
    param(
        [int]$Tracked = 0,
        [int]$Converted = 0,
        [int]$Verified = 0,
        [int]$Failed = 0
    )

    Write-Output "HookSource=$hookSource HookVersion=$hookVersion ToolName=$script:toolName PayloadParsed=$script:payloadParsed StateFile=$stateFile Tracked=$Tracked Converted=$Converted Verified=$Verified Rejected=$script:rejectedCount Failed=$Failed"
}

function Enter-StateLock {
    param([int]$TimeoutMilliseconds = 10000)

    try {
        return $stateMutex.WaitOne($TimeoutMilliseconds)
    } catch [System.Threading.AbandonedMutexException] {
        return $true
    }
}

function Exit-StateLock {
    try { $stateMutex.ReleaseMutex() } catch { }
}

function Resolve-ManagedPath {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
        if (-not [IO.Path]::IsPathRooted($expanded)) {
            $expanded = Join-Path $projectRoot $expanded
        }
        $fullPath = [IO.Path]::GetFullPath($expanded)
    } catch { return $null }
    if (-not $fullPath.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $null }

    $relativePath = $fullPath.Substring($projectPrefix.Length).Replace('\', '/')
    if ($relativePath -match '(^|/)(CVS|\.codex)(/|$)') { return $null }
    return [pscustomobject]@{ FullPath = $fullPath; RelativePath = $relativePath }
}

function Test-AllowedTarget {
    param([Parameter(Mandatory = $true)]$Target)

    if (-not (Test-Path -LiteralPath $Target.FullPath -PathType Leaf)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Target.FullPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($item.Length -gt $maxFileSize) { return $false }
        return $allowedExtensions.Contains($item.Extension)
    } catch {
        return $false
    }
}

function Add-Target {
    param([object]$Path)

    try {
        if ($null -eq $Path) { return $false }
        if ($Path -is [System.Collections.IEnumerable] -and -not ($Path -is [string])) {
            $added = $false
            foreach ($item in $Path) { if (Add-Target $item) { $added = $true } }
            return $added
        }

        $candidate = ([string]$Path).Trim()
        while ($candidate.EndsWith('\r') -or $candidate.EndsWith('\n')) { $candidate = $candidate.Substring(0, $candidate.Length - 2).TrimEnd() }
        $candidate = $candidate.Trim('"', "'", '`').TrimEnd(';').Trim()
        $candidate = $candidate.Trim('"', "'", '`')
        if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }

        $target = Resolve-ManagedPath $candidate
        if ($null -eq $target) {
            $script:rejectedCount++
            Write-Warning "CRLF target rejected: Path=[$candidate] Error=Path is outside the CVS project or is invalid."
            return $false
        }
        if (-not (Test-AllowedTarget $target)) { return $false }
        return $script:targets.Add($target.RelativePath)
    } catch {
        $script:rejectedCount++
        Write-Warning "CRLF target rejected: Path=[$Path] Error=$($_.Exception.Message)"
        return $false
    }
}

function Get-PropertyValue {
    param([object]$Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name })[0]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-PayloadText {
    param([object]$Payload, [AllowEmptyString()][string]$RawInput)

    $parts = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($RawInput)) { [void]$parts.Add($RawInput) }
    $toolInput = Get-PropertyValue $Payload 'tool_input'
    foreach ($value in @(
        (Get-PropertyValue $Payload 'input'),
        (Get-PropertyValue $Payload 'command'),
        $toolInput,
        (Get-PropertyValue $toolInput 'input'),
        (Get-PropertyValue $toolInput 'command')
    )) {
        if ($null -eq $value) { continue }
        if ($value -is [string]) { [void]$parts.Add($value); continue }
        try { [void]$parts.Add(($value | ConvertTo-Json -Depth 100 -Compress)) }
        catch { [void]$parts.Add([string]$value) }
    }
    return [string]::Join("`n", $parts)
}

function Add-PatchTargets {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $normalized = [regex]::Replace($Text, '\\\\r\\\\n', "`n")
    $normalized = [regex]::Replace($normalized, '\\\\n', "`n")
    $normalized = [regex]::Replace($normalized, '(?<!\\)\\r\\n', "`n")
    $normalized = [regex]::Replace($normalized, '(?<!\\)\\n', "`n")
    foreach ($match in [regex]::Matches($normalized, '(?m)^\s*\*\*\* (?:Add|Update) File:\s*(?<path>[^\r\n]+?)\s*$')) {
        Add-Target $match.Groups['path'].Value
    }
}

function Add-PayloadPatchTargets {
    param(
        [object]$Value,
        [int]$Depth = 0
    )

    if ($null -eq $Value -or $Depth -gt 12) { return }
    if ($Value -is [string]) {
        Add-PatchTargets $Value
        $trimmed = $Value.Trim()
        if (($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) -or ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
            try { Add-PayloadPatchTargets ($Value | ConvertFrom-Json -ErrorAction Stop) ($Depth + 1) } catch { }
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($item in $Value.Values) { Add-PayloadPatchTargets $item ($Depth + 1) }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { Add-PayloadPatchTargets $item ($Depth + 1) }
        return
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        Add-PayloadPatchTargets $property.Value ($Depth + 1)
    }
}

function Convert-ToCrlf {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0 -or [Array]::IndexOf($bytes, [byte]0) -ge 0) { return $false }

    $stream = New-Object IO.MemoryStream
    try {
        $changed = $false
        for ($index = 0; $index -lt $bytes.Length; $index++) {
            $value = $bytes[$index]
            if ($value -eq 13) {
                $stream.WriteByte(13)
                if (($index + 1) -lt $bytes.Length -and $bytes[$index + 1] -eq 10) {
                    $stream.WriteByte(10)
                    $index++
                } else {
                    $stream.WriteByte(10)
                    $changed = $true
                }
            } elseif ($value -eq 10) {
                $stream.WriteByte(13)
                $stream.WriteByte(10)
                $changed = $true
            } else {
                $stream.WriteByte($value)
            }
        }

        if ($changed) {
            [IO.File]::WriteAllBytes($Path, $stream.ToArray())
        }
        return $changed
    } finally {
        $stream.Dispose()
    }
}

function Get-LfOnlyCount {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $count = 0
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -eq 10 -and ($index -eq 0 -or $bytes[$index - 1] -ne 13)) { $count++ }
    }
    return $count
}

function Read-State {
    $pathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $updatedAt = $null

    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        $state = (Get-Content -Raw -LiteralPath $stateFile) | ConvertFrom-Json -ErrorAction Stop
        foreach ($path in @($state.files)) {
            $target = Resolve-ManagedPath ([string]$path)
            if ($null -ne $target) { [void]$pathSet.Add($target.RelativePath) }
        }
        try { $updatedAt = [DateTimeOffset]::Parse([string]$state.updatedAt).ToUniversalTime() } catch { }
    } else {
        return $null
    }

    if ($null -eq $updatedAt) {
        $updatedAt = [DateTimeOffset]([IO.File]::GetLastWriteTimeUtc($stateFile))
    }
    return [pscustomobject]@{ Files = $pathSet; UpdatedAt = $updatedAt }
}

function Write-State {
    param([Parameter(Mandatory = $true)]$Paths)

    $state = [ordered]@{
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        files = @($Paths | Sort-Object)
    }
    $temporaryPath = Join-Path $stateBase ('.crlf-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($temporaryPath, ($state | ConvertTo-Json -Depth 5), $encoding)
        if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
            try { [IO.File]::Replace($temporaryPath, $stateFile, $null, $true) }
            catch { Move-Item -LiteralPath $temporaryPath -Destination $stateFile -Force }
        } else {
            Move-Item -LiteralPath $temporaryPath -Destination $stateFile
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-StateFiles {
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        try { Remove-Item -LiteralPath $stateFile -Force -ErrorAction Stop }
        catch { if (Test-Path -LiteralPath $stateFile -PathType Leaf) { throw } }
    }
}

if ($Flush) {
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        $stateMutex.Dispose()
        Write-Output 'Tracked=0 Converted=0 Verified=0 Skipped=0 Failed=0'
        Write-HookResult
        exit 0
    }

    Start-Sleep -Seconds $quietPeriodSeconds
    if (-not (Enter-StateLock)) {
        $stateMutex.Dispose()
        exit 0
    }

    $exitCode = 0
    $trackedCount = 0
    $convertedCount = 0
    $verifiedCount = 0
    $skippedCount = 0
    $failedCount = 0
    $finalized = $false
    try {
        $state = Read-State
        if ($null -ne $state -and (([DateTimeOffset]::UtcNow - $state.UpdatedAt).TotalSeconds -ge $quietPeriodSeconds)) {
            $finalized = $true
            $trackedCount = $state.Files.Count
            $allSucceeded = $true
            foreach ($relativePath in $state.Files) {
                $target = Resolve-ManagedPath $relativePath
                if ($null -eq $target -or -not (Test-AllowedTarget $target)) {
                    $skippedCount++
                    continue
                }
                try {
                    if (Convert-ToCrlf -Path $target.FullPath) { $convertedCount++ }
                    $lfOnly = Get-LfOnlyCount -Path $target.FullPath
                    if ($lfOnly -gt 0) {
                        throw "CRLF verification failed: $($target.RelativePath) still contains $lfOnly LF-only line ending(s)."
                    }
                    $verifiedCount++
                } catch {
                    $allSucceeded = $false
                    $failedCount++
                    Write-HookFailure -ErrorMessage "CRLF conversion failed: $($target.RelativePath) - $($_.Exception.Message)" -Tracked $trackedCount -Converted $convertedCount -Verified $verifiedCount -Failed $failedCount
                }
            }

            if ($allSucceeded) {
                Remove-StateFiles
                if (Test-Path -LiteralPath $stateFile -PathType Leaf) { $exitCode = 1 }
            } else {
                $exitCode = 1
            }
        }
    } catch {
        $failedCount++
        Write-HookFailure -ErrorMessage "CRLF finalization failed: $($_.Exception.Message)" -Tracked $trackedCount -Converted $convertedCount -Verified $verifiedCount -Failed $failedCount
        $exitCode = 1
    } finally {
        Exit-StateLock
        $stateMutex.Dispose()
    }

    if ($finalized) {
        Write-Output "Tracked=$trackedCount Converted=$convertedCount Verified=$verifiedCount Skipped=$skippedCount Failed=$failedCount"
    }
    Write-HookResult -Tracked $trackedCount -Converted $convertedCount -Verified $verifiedCount -Failed $failedCount
    exit $exitCode
}

$script:targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$inputText = [Console]::In.ReadToEnd()
if (-not [string]::IsNullOrWhiteSpace($inputText)) {
    try {
        $payload = $inputText | ConvertFrom-Json -ErrorAction Stop
        $script:payloadParsed = $true
        $script:toolName = [string](Get-PropertyValue $payload 'tool_name')
        if ([string]::IsNullOrWhiteSpace($script:toolName)) { $script:toolName = 'unknown' }
        foreach ($scope in @($payload, (Get-PropertyValue $payload 'input'), (Get-PropertyValue $payload 'tool_input'))) {
            Add-Target (Get-PropertyValue $scope 'file_path') | Out-Null
            Add-Target (Get-PropertyValue $scope 'path') | Out-Null
            Add-Target (Get-PropertyValue $scope 'file_paths') | Out-Null
            Add-Target (Get-PropertyValue $scope 'paths') | Out-Null
        }
        Add-PatchTargets (Get-PayloadText -Payload $payload -RawInput $inputText)
        Add-PayloadPatchTargets $payload
    } catch {
        # Raw and escaped apply_patch payloads are handled below.
    }
    Add-PatchTargets $inputText
}

if ($targets.Count -eq 0) {
    Write-Warning 'CRLF tracked files: 0. No updated file paths were found in the PostToolUse payload.'
    Write-HookResult
    $stateMutex.Dispose()
    exit 0
}

try {
    New-Item -ItemType Directory -Path $stateBase -Force | Out-Null
    Get-ChildItem -LiteralPath $stateBase -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    if (-not (Enter-StateLock)) { throw 'Unable to acquire CRLF state lock.' }
    try {
        $state = Read-State
        $allTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $state) {
            foreach ($path in $state.Files) { [void]$allTargets.Add($path) }
        }
        foreach ($path in $targets) { [void]$allTargets.Add($path) }
        Write-State $allTargets
    } finally {
        Exit-StateLock
    }
    Write-Output "CRLF tracked files: $($targets.Count)"
    foreach ($path in @($targets | Sort-Object)) { Write-Output "CRLF target: $path" }
    Write-HookResult -Tracked $targets.Count
    exit 0
} catch {
    Write-HookFailure -ErrorMessage "CRLF state update failed: $($_.Exception.Message)" -Tracked $targets.Count -Failed 1
    exit 1
} finally {
    $stateMutex.Dispose()
}
