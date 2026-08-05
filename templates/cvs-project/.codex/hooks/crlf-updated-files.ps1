param(
    [switch]$Flush
)

$ErrorActionPreference = 'Stop'

$hookDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $hookDir)
$rootMarker = Join-Path $projectRoot '.codex-root'
if (-not (Test-Path -LiteralPath $rootMarker -PathType Leaf)) {
    throw "CVS project root marker was not found: $rootMarker"
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
$stateFile = Join-Path $stateBase ("crlf-$rootHash.json")
$legacyStateFile = Join-Path $stateBase ("crlf-$rootHash.txt")
$stateMutex = New-Object System.Threading.Mutex($false, "CodexSettings.Crlf.$rootHash")

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
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $projectRoot $expanded
    }

    try { $fullPath = [IO.Path]::GetFullPath($expanded) } catch { return $null }
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

    if ($null -eq $Path) { return }
    if ($Path -is [System.Collections.IEnumerable] -and -not ($Path -is [string])) {
        foreach ($item in $Path) { Add-Target $item }
        return
    }

    $target = Resolve-ManagedPath ([string]$Path)
    if ($null -ne $target -and (Test-AllowedTarget $target)) {
        [void]$script:targets.Add($target.RelativePath)
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
    } elseif (Test-Path -LiteralPath $legacyStateFile -PathType Leaf) {
        foreach ($path in [IO.File]::ReadAllLines($legacyStateFile)) {
            $target = Resolve-ManagedPath $path
            if ($null -ne $target) { [void]$pathSet.Add($target.RelativePath) }
        }
    } else {
        return $null
    }

    if ($null -eq $updatedAt) {
        $statePath = if (Test-Path -LiteralPath $stateFile -PathType Leaf) { $stateFile } else { $legacyStateFile }
        $updatedAt = [DateTimeOffset]([IO.File]::GetLastWriteTimeUtc($statePath))
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
    foreach ($path in @($stateFile, $legacyStateFile)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
            catch { if (Test-Path -LiteralPath $path -PathType Leaf) { throw } }
        }
    }
}

if ($Flush) {
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf) -and -not (Test-Path -LiteralPath $legacyStateFile -PathType Leaf)) {
        $stateMutex.Dispose()
        exit 0
    }

    Start-Sleep -Seconds $quietPeriodSeconds
    if (-not (Enter-StateLock)) {
        $stateMutex.Dispose()
        exit 0
    }

    $exitCode = 0
    $convertedCount = 0
    try {
        $state = Read-State
        if ($null -ne $state -and (([DateTimeOffset]::UtcNow - $state.UpdatedAt).TotalSeconds -ge $quietPeriodSeconds)) {
            $allSucceeded = $true
            foreach ($relativePath in $state.Files) {
                $target = Resolve-ManagedPath $relativePath
                if ($null -eq $target -or -not (Test-AllowedTarget $target)) { continue }
                try {
                    if (Convert-ToCrlf -Path $target.FullPath) { $convertedCount++ }
                } catch {
                    $allSucceeded = $false
                    Write-Error "CRLF conversion failed: $($target.RelativePath) - $($_.Exception.Message)"
                }
            }

            if ($allSucceeded) {
                Remove-StateFiles
                if (Test-Path -LiteralPath $stateFile -PathType Leaf) { $exitCode = 1 }
                if (Test-Path -LiteralPath $legacyStateFile -PathType Leaf) { $exitCode = 1 }
            } else {
                $exitCode = 1
            }
        }
    } catch {
        Write-Error "CRLF finalization failed: $($_.Exception.Message)"
        $exitCode = 1
    } finally {
        Exit-StateLock
        $stateMutex.Dispose()
    }

    if ($convertedCount -gt 0) { Write-Output "Converted $convertedCount file(s) to CRLF." }
    exit $exitCode
}

$script:targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$inputText = [Console]::In.ReadToEnd()
if (-not [string]::IsNullOrWhiteSpace($inputText)) {
    try {
        $payload = $inputText | ConvertFrom-Json -ErrorAction Stop
        Add-Target $payload.tool_input.file_path
        Add-Target $payload.tool_input.path
        Add-Target $payload.tool_input.file_paths
        Add-Target $payload.tool_input.paths
    } catch {
        # apply_patch payloads are handled by the text matcher below.
    }

    foreach ($match in [regex]::Matches($inputText, '\*\*\* (?:Add|Update) File: (.+)')) {
        Add-Target $match.Groups[1].Value
    }
}

if ($targets.Count -eq 0) {
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
    exit 0
} catch {
    Write-Error "CRLF state update failed: $($_.Exception.Message)"
    exit 1
} finally {
    $stateMutex.Dispose()
}
