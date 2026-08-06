[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Track', 'Restore', 'Finalize')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
$stateRoot = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_LINE_ENDING_STATE_ROOT)) {
    Join-Path $HOME '.codex\state\line-endings'
} else {
    $env:CODEX_SETTINGS_LINE_ENDING_STATE_ROOT
}

function ConvertFrom-HookInputJson([string]$Text) {
    try { return $Text | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $originalError = $_
        $pattern = '(?s)(?<prefix>"last_assistant_message"\s*:\s*)".*"(?<suffix>\s*}\s*)$'
        $sanitized = [regex]::Replace($Text, $pattern, '${prefix}null${suffix}')
        if ($sanitized -eq $Text) { throw $originalError }
        try { return $sanitized | ConvertFrom-Json -ErrorAction Stop }
        catch { throw $originalError }
    }
}

function Get-Sha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-CvsRoot([string]$StartPath) {
    $current = [IO.DirectoryInfo][IO.Path]::GetFullPath($StartPath)
    $root = $null
    while ($null -ne $current) {
        if (Test-Path -LiteralPath (Join-Path $current.FullName 'CVS') -PathType Container) { $root = $current.FullName }
        $current = $current.Parent
    }
    return $root
}

function Test-BinaryBytes([byte[]]$Bytes) {
    foreach ($value in $Bytes) {
        if ($value -eq 0 -or $value -lt 9 -or ($value -gt 13 -and $value -lt 32)) { return $true }
    }
    return $false
}

function Get-LineEndingState([byte[]]$Bytes) {
    $crlf = 0
    $lfOnly = 0
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -ne 10) { continue }
        if ($index -gt 0 -and $Bytes[$index - 1] -eq 13) { $crlf++ } else { $lfOnly++ }
    }
    $style = if ($crlf -gt 0 -and $lfOnly -gt 0) { 'MIXED' } elseif ($crlf -gt 0) { 'CRLF' } elseif ($lfOnly -gt 0) { 'LF' } else { 'NONE' }
    $finalNewline = $Bytes.Length -gt 0 -and $Bytes[$Bytes.Length - 1] -eq 10
    $finalStyle = if (-not $finalNewline) { 'NONE' } elseif ($Bytes.Length -gt 1 -and $Bytes[$Bytes.Length - 2] -eq 13) { 'CRLF' } else { 'LF' }
    return [pscustomobject]@{ Style = $style; FinalNewline = $finalNewline; FinalStyle = $finalStyle }
}

function Get-BomName([byte[]]$Bytes) {
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return 'UTF8-BOM' }
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) { return 'UTF32-LE-BOM' }
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) { return 'UTF32-BE-BOM' }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return 'UTF16-LE-BOM' }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return 'UTF16-BE-BOM' }
    return 'NONE'
}

function Get-CvsTrackedFiles([string]$Root) {
    $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $directories = [Collections.Generic.Queue[string]]::new()
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $rootPrefix = $canonicalRoot + [IO.Path]::DirectorySeparatorChar
    $directories.Enqueue($canonicalRoot)
    while ($directories.Count -gt 0) {
        $directory = $directories.Dequeue()
        $entriesPath = Join-Path $directory 'CVS\Entries'
        if (-not (Test-Path -LiteralPath $entriesPath -PathType Leaf)) { continue }
        foreach ($line in [IO.File]::ReadAllLines($entriesPath)) {
            if ($line -match '^/([^/]+)/') {
                $name = $Matches[1]
                if ($name -in @('.', '..', 'CVS', '.git', '.codex')) { continue }
                $path = [IO.Path]::GetFullPath((Join-Path $directory $name))
                if ($path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $path -PathType Leaf)) { [void]$files.Add($path) }
            } elseif ($line -match '^D/([^/]+)/') {
                $name = $Matches[1]
                if ($name -in @('.', '..', 'CVS', '.git', '.codex')) { continue }
                $path = [IO.Path]::GetFullPath((Join-Path $directory $name))
                if ($path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $path -PathType Container)) { $directories.Enqueue($path) }
            }
        }
    }
    return @($files)
}

function Restore-BomBytes([byte[]]$Bytes, [string]$OriginalBom) {
    $hasUtf8Bom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
    if ($OriginalBom -eq 'UTF8-BOM' -and -not $hasUtf8Bom) {
        return [byte[]](0xEF, 0xBB, 0xBF) + $Bytes
    }
    if ($OriginalBom -eq 'NONE' -and $hasUtf8Bom) {
        if ($Bytes.Length -eq 3) { return [byte[]]@() }
        return [byte[]]$Bytes[3..($Bytes.Length - 1)]
    }
    return $Bytes
}

function Convert-LineEndingBytes([byte[]]$Bytes, [ValidateSet('CRLF', 'LF')][string]$Style) {
    $result = [Collections.Generic.List[byte]]::new($Bytes.Length)
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        $value = $Bytes[$index]
        if ($Style -eq 'LF' -and $value -eq 13 -and $index + 1 -lt $Bytes.Length -and $Bytes[$index + 1] -eq 10) { continue }
        if ($Style -eq 'CRLF' -and $value -eq 10 -and ($index -eq 0 -or $Bytes[$index - 1] -ne 13)) { $result.Add(13) }
        $result.Add($value)
    }
    return $result.ToArray()
}

function Set-FinalNewlineBytes([byte[]]$Bytes, [bool]$FinalNewline, [string]$Style) {
    $length = $Bytes.Length
    while ($length -gt 0 -and $Bytes[$length - 1] -eq 10) {
        $length--
        if ($length -gt 0 -and $Bytes[$length - 1] -eq 13) { $length-- }
    }
    $result = [Collections.Generic.List[byte]]::new($Bytes.Length + 2)
    for ($index = 0; $index -lt $length; $index++) { $result.Add($Bytes[$index]) }
    if ($FinalNewline) {
        if ($Style -eq 'CRLF') { $result.Add(13) }
        $result.Add(10)
    }
    return $result.ToArray()
}

function Get-StatePath([string]$SessionId) {
    $safeName = [regex]::Replace($SessionId, '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = Get-Sha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($SessionId)) }
    return Join-Path $stateRoot ($safeName + '.json')
}

function Write-HookDiagnostic($InputObject, [string]$Result, [string[]]$ChangedFiles, [string]$Details) {
    try {
        $root = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_HOOK_LOG_ROOT)) { Join-Path $HOME '.codex\logs\hooks' } else { $env:CODEX_SETTINGS_HOOK_LOG_ROOT }
        $sessionId = if ($null -eq $InputObject) { 'unknown' } else { [string]$InputObject.session_id }
        $safeSessionId = [regex]::Replace($sessionId, '[^A-Za-z0-9._-]', '_')
        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString('o')
            event = if ($null -eq $InputObject) { $Mode } else { [string]$InputObject.hook_event_name }
            handler = 'preserve-line-endings'
            mode = $Mode
            result = $Result
            sessionId = $sessionId
            turnId = if ($null -eq $InputObject) { '' } else { [string]$InputObject.turn_id }
            tool = if ($null -eq $InputObject) { '' } else { [string]$InputObject.tool_name }
            changedFileCount = @($ChangedFiles).Count
            changedFiles = @($ChangedFiles)
            details = $Details
        }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::AppendAllText((Join-Path $root ($safeSessionId + '.log')), (($entry | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    } catch {}
}

function Save-InitialState($InputObject) {
    $statePath = Get-StatePath -SessionId ([string]$InputObject.session_id)
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { return }
    $root = Get-CvsRoot -StartPath ([string]$InputObject.cwd)
    if ([string]::IsNullOrWhiteSpace($root)) { return }

    $files = [ordered]@{}
    foreach ($path in Get-CvsTrackedFiles -Root $root) {
        $bytes = [IO.File]::ReadAllBytes($path)
        if (Test-BinaryBytes -Bytes $bytes) { continue }
        $lineEndings = Get-LineEndingState -Bytes $bytes
        $files[$path] = [ordered]@{
            lineEnding = $lineEndings.Style
            finalNewline = $lineEndings.FinalNewline
            finalNewlineStyle = $lineEndings.FinalStyle
            bom = Get-BomName -Bytes $bytes
            sha256 = Get-Sha256 -Bytes $bytes
        }
    }

    $state = [ordered]@{ sessionId = [string]$InputObject.session_id; projectRoot = $root; files = $files }
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $temporaryPath = $statePath + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporaryPath, ($state | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    try {
        [IO.File]::Move($temporaryPath, $statePath)
    } catch [IO.IOException] {
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

function Restore-InitialState($InputObject, [Collections.Generic.List[string]]$Warnings, [switch]$Cleanup) {
    $statePath = Get-StatePath -SessionId ([string]$InputObject.session_id)
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return }
    $changedFiles = [Collections.Generic.List[string]]::new()
    try {
        $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json -ErrorAction Stop
        $root = [IO.Path]::GetFullPath([string]$state.projectRoot).TrimEnd('\', '/')
        $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
        foreach ($property in @($state.files.PSObject.Properties)) {
            try {
                $path = [IO.Path]::GetFullPath([string]$property.Name)
                if (-not $path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                $bytes = [IO.File]::ReadAllBytes($path)
                if (Test-BinaryBytes -Bytes $bytes) { continue }
                $original = $property.Value
                if ((Get-Sha256 -Bytes $bytes) -eq [string]$original.sha256) { continue }

                $restored = Restore-BomBytes -Bytes $bytes -OriginalBom ([string]$original.bom)
                if ([string]$original.lineEnding -in @('CRLF', 'LF')) {
                    $restored = Convert-LineEndingBytes -Bytes $restored -Style ([string]$original.lineEnding)
                } elseif ([string]$original.lineEnding -eq 'MIXED') {
                    $Warnings.Add("Skipped original mixed line endings: $path")
                }
                $finalStyle = if ([string]$original.lineEnding -in @('CRLF', 'LF')) { [string]$original.lineEnding } elseif ([string]$original.finalNewlineStyle -in @('CRLF', 'LF')) { [string]$original.finalNewlineStyle } else { 'LF' }
                $restored = Set-FinalNewlineBytes -Bytes $restored -FinalNewline ([bool]$original.finalNewline) -Style $finalStyle
                if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$bytes, [byte[]]$restored)) {
                    [IO.File]::WriteAllBytes($path, $restored)
                    $changedFiles.Add($path)
                }
            } catch {
                $Warnings.Add("Failed to restore line endings for $($property.Name): $($_.Exception.Message)")
            }
        }
    } finally {
        if ($Cleanup) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
    }
    return $changedFiles.ToArray()
}

$warnings = [Collections.Generic.List[string]]::new()
$inputObject = $null
$changedFiles = @()
try {
    $inputText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputText)) { throw 'Hook input JSON is empty.' }
    $inputObject = ConvertFrom-HookInputJson -Text $inputText
    if ([string]::IsNullOrWhiteSpace([string]$inputObject.session_id)) { throw 'Hook input is missing session_id.' }
    if ($Mode -eq 'Track') {
        if ([string]::IsNullOrWhiteSpace([string]$inputObject.cwd)) { throw 'Hook input is missing cwd.' }
        Save-InitialState -InputObject $inputObject
    } else {
        $changedFiles = @(Restore-InitialState -InputObject $inputObject -Warnings $warnings -Cleanup:($Mode -eq 'Finalize'))
    }
} catch {
    $warnings.Add("Line-ending $($Mode.ToLowerInvariant()) failed: $($_.Exception.Message)")
}

if ($warnings.Count -eq 0) {
    Write-HookDiagnostic -InputObject $inputObject -Result 'success' -ChangedFiles $changedFiles -Details ''
    [Console]::Out.WriteLine('{}')
} else {
    Write-HookDiagnostic -InputObject $inputObject -Result 'error' -ChangedFiles $changedFiles -Details ($warnings -join '; ')
    [Console]::Out.WriteLine(([ordered]@{ systemMessage = ($warnings -join [Environment]::NewLine) } | ConvertTo-Json -Compress))
}
exit 0
