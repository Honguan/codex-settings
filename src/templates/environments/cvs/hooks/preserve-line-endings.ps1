[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Track', 'Restore', 'Finalize')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
$script:HookStartTime = [DateTimeOffset]::Now
$script:HookStopwatch = [Diagnostics.Stopwatch]::StartNew()
$script:HookCommand = if ([string]::IsNullOrWhiteSpace([string]$MyInvocation.Line)) { $PSCommandPath } else { [string]$MyInvocation.Line }
$script:HookSource = 'global'
$script:HookExitCode = 0
$stateRoot = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_LINE_ENDING_STATE_ROOT)) {
    Join-Path $HOME '.codex\state\line-endings'
} else {
    $env:CODEX_SETTINGS_LINE_ENDING_STATE_ROOT
}
$indexRoot = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_LINE_ENDING_INDEX_ROOT)) {
    Join-Path $HOME '.codex\state\line-ending-index'
} else {
    $env:CODEX_SETTINGS_LINE_ENDING_INDEX_ROOT
}
$script:HookParentProcessId = $null
$script:HookTimings = [ordered]@{
    stateLockWaitMs = 0
    stateReadMs = 0
    trackedFileDiscoveryMs = 0
    metadataScanMs = 0
    fileReadMs = 0
    restoreMs = 0
    stateWriteMs = 0
    invocationCounterMs = 0
    diagnosticWriteMs = 0
    candidateScoped = $false
    stateFileCountChecked = 0
    lineEndingIndexHitCount = 0
    lineEndingIndexMissCount = 0
}

function Add-HookTiming([string]$Name, [long]$Milliseconds) {
    if ($script:HookTimings.Contains($Name)) { $script:HookTimings[$Name] = [long]$script:HookTimings[$Name] + $Milliseconds }
}

function ConvertFrom-HookInputJson([string]$Text) {
    try { return $Text | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $originalError = $_
        $pattern = '(?s)(?<prefix>"last_assistant_message"\s*:\s*)".*"(?<suffix>\s*}\s*)$'
        $sanitized = [regex]::Replace($Text, $pattern, '${prefix}null${suffix}')
        if ($sanitized -ne $Text) {
            try { return $sanitized | ConvertFrom-Json -ErrorAction Stop } catch {}
        }
        $messageProperty = @([regex]::Matches($Text, ',\s*"last_assistant_message"\s*:'))[-1]
        if ($null -ne $messageProperty) {
            $prefix = $Text.Substring(0, $messageProperty.Index).TrimEnd()
            try { return ($prefix + '}') | ConvertFrom-Json -ErrorAction Stop } catch {}
        }
        throw $originalError
    }
}

function Get-Sha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-CvsRoot([string]$StartPath) {
    $current = [IO.DirectoryInfo][IO.Path]::GetFullPath($StartPath)
    while ($null -ne $current) {
        if (Test-Path -LiteralPath (Join-Path $current.FullName 'CVS') -PathType Container) { return $current.FullName }
        $current = $current.Parent
    }
    return $null
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
    $preferredStyle = if ($style -in @('CRLF', 'LF')) {
        $style
    } elseif ($crlf -gt $lfOnly) {
        'CRLF'
    } elseif ($lfOnly -gt $crlf) {
        'LF'
    } elseif ($finalStyle -in @('CRLF', 'LF')) {
        $finalStyle
    } else {
        'CRLF'
    }
    return [pscustomobject]@{ Style = $style; PreferredStyle = $preferredStyle; FinalNewline = $finalNewline; FinalStyle = $finalStyle }
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

function Test-CvsTrackedFile([string]$Path) {
    $entriesPath = Join-Path (Split-Path -Parent $Path) 'CVS\Entries'
    if (-not (Test-Path -LiteralPath $entriesPath -PathType Leaf)) { return $false }
    $name = [IO.Path]::GetFileName($Path)
    return @([IO.File]::ReadAllLines($entriesPath) -match ('^/' + [regex]::Escape($name) + '/')).Count -gt 0
}

function Get-HookCandidateFiles($InputObject, [string]$Root) {
    $files = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $rootPrefix = $canonicalRoot + [IO.Path]::DirectorySeparatorChar
    $command = ([string]$InputObject.tool_input.command).Replace('\n', "`n")
    foreach ($match in [regex]::Matches($command, '(?m)^\*\*\* (?:Update|Add|Delete) File:\s*(?<path>[^\r\n]+)$')) {
        $candidate = $match.Groups['path'].Value.Trim().Replace('\\', '\')
        try {
            $path = if ([IO.Path]::IsPathRooted($candidate)) { [IO.Path]::GetFullPath($candidate) } else { [IO.Path]::GetFullPath((Join-Path ([string]$InputObject.cwd) $candidate)) }
            if ($path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-CvsTrackedFile -Path $path)) { [void]$files.Add($path) }
        } catch {}
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

function Get-StatePath([string]$SessionId, [string]$ProjectRoot) {
    $canonicalRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    $key = "$canonicalRoot|$SessionId"
    return Join-Path $stateRoot ((Get-Sha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant() + '.json')
}

function Get-LineEndingIndexPath([string]$ProjectRoot) {
    $canonicalRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    return Join-Path $indexRoot ((Get-Sha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($canonicalRoot))).ToLowerInvariant() + '.json')
}

function Read-LineEndingIndex([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }
}

function Write-LineEndingIndex([string]$Path, $Index) {
    $root = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $temporaryPath = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, ($Index | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

function Copy-LineEndingFileState($Value) {
    return [ordered]@{
        lineEnding = [string]$Value.lineEnding
        preferredLineEnding = [string]$Value.preferredLineEnding
        finalNewline = [bool]$Value.finalNewline
        finalNewlineStyle = [string]$Value.finalNewlineStyle
        bom = [string]$Value.bom
        sha256 = [string]$Value.sha256
        verifiedLength = [long]$Value.verifiedLength
        verifiedLastWriteTimeUtcTicks = [long]$Value.verifiedLastWriteTimeUtcTicks
    }
}

function New-LineEndingFileState([string]$Path, [IO.FileInfo]$FileInfo) {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $script:HookTimings.fileReadMs = [long]$script:HookTimings.fileReadMs + $stopwatch.ElapsedMilliseconds
        if (Test-BinaryBytes -Bytes $bytes) { return $null }
        $lineEndings = Get-LineEndingState -Bytes $bytes
        return [ordered]@{
            lineEnding = $lineEndings.Style
            preferredLineEnding = $lineEndings.PreferredStyle
            finalNewline = $lineEndings.FinalNewline
            finalNewlineStyle = $lineEndings.FinalStyle
            bom = Get-BomName -Bytes $bytes
            sha256 = Get-Sha256 -Bytes $bytes
            verifiedLength = $FileInfo.Length
            verifiedLastWriteTimeUtcTicks = $FileInfo.LastWriteTimeUtc.Ticks
        }
    } finally {
        if ($stopwatch.IsRunning) { $stopwatch.Stop() }
    }
}

function Get-HookSource {
    try {
        $current = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/')
        $globalRoot = [IO.Path]::GetFullPath((Join-Path $HOME '.codex\hooks')).TrimEnd('\', '/')
        if ($current.Equals($globalRoot, [StringComparison]::OrdinalIgnoreCase)) { return 'global' }
        if ([IO.Path]::GetFileName($current).Equals('hooks', [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName((Split-Path -Parent $current)).Equals('.codex', [StringComparison]::OrdinalIgnoreCase)) { return 'project' }
    } catch {}
    return 'global'
}

function Get-HookParentProcessId {
    if ($null -ne $script:HookParentProcessId) { return [int]$script:HookParentProcessId }
    $parentProcessId = 0
    try {
        $parent = (Get-Process -Id $PID -ErrorAction Stop).Parent
        if ($null -ne $parent) { $parentProcessId = [int]$parent.Id }
    } catch {}
    if ($parentProcessId -eq 0) {
        try { $parentProcessId = [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId }
        catch { $parentProcessId = 0 }
    }
    $script:HookParentProcessId = $parentProcessId
    return $parentProcessId
}

function New-HookInvocationCounts {
    return [ordered]@{
        GlobalStopHookCount = 0
        ProjectStopHookCount = 0
        EffectiveStopHookCount = 0
        GlobalPostToolUseHookCount = 0
        ProjectPostToolUseHookCount = 0
        EffectivePostToolUseHookCount = 0
        NotificationInvocationCount = 0
        CrlfInvocationCount = 0
    }
}

function Invoke-WithStateLock([string]$ProjectRoot, [string]$SessionId, [scriptblock]$Action) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$ProjectRoot|$SessionId")))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $mutex = $null
    $lockHeld = $false
    try {
        $mutex = [Threading.Mutex]::new($false, 'CodexSettings.LineEndingState.' + $hash)
        $waitStopwatch = [Diagnostics.Stopwatch]::StartNew()
        try { $lockHeld = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
        Add-HookTiming -Name 'stateLockWaitMs' -Milliseconds $waitStopwatch.ElapsedMilliseconds
        if (-not $lockHeld) { throw 'Unable to acquire line-ending state mutex.' }
        return & $Action
    } finally {
        if ($lockHeld -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Invoke-WithIndexLock([string]$ProjectRoot, [scriptblock]$Action) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProjectRoot)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $mutex = $null
    $lockHeld = $false
    try {
        $mutex = [Threading.Mutex]::new($false, 'CodexSettings.LineEndingIndex.' + $hash)
        $waitStopwatch = [Diagnostics.Stopwatch]::StartNew()
        try { $lockHeld = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
        Add-HookTiming -Name 'stateLockWaitMs' -Milliseconds $waitStopwatch.ElapsedMilliseconds
        if (-not $lockHeld) { throw 'Unable to acquire line-ending index mutex.' }
        return & $Action
    } finally {
        if ($lockHeld -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Write-LineEndingState([string]$Path, $State) {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $temporaryPath = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, ($State | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        try { Move-Item -LiteralPath $temporaryPath -Destination $Path -Force }
        finally { if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force } }
    } finally { Add-HookTiming -Name 'stateWriteMs' -Milliseconds $stopwatch.ElapsedMilliseconds }
}

function Invoke-WithNamedMutex([string]$Name, [scriptblock]$Action, [int]$TimeoutMilliseconds = 5000) {
    $mutex = $null
    $lockHeld = $false
    try {
        $mutex = [Threading.Mutex]::new($false, $Name)
        try { $lockHeld = $mutex.WaitOne($TimeoutMilliseconds) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
        if (-not $lockHeld) { throw "Unable to acquire hook mutex: $Name" }
        return & $Action
    } finally {
        if ($lockHeld -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Get-HookInvocationCounts($InputObject) {
    $counts = New-HookInvocationCounts
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $root = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT)) { Join-Path $HOME '.codex\state\hook-invocations' } else { [IO.Path]::GetFullPath($env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT) }
        $sessionId = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.session_id)) { 'unknown-session' } else { [string]$InputObject.session_id }
        $turnId = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.turn_id)) { 'unknown-turn' } else { [string]$InputObject.turn_id }
        $eventName = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.hook_event_name)) { $Mode } else { [string]$InputObject.hook_event_name }
        $cwd = if ($null -eq $InputObject) { '' } else { [string]$InputObject.cwd }
        $key = "$cwd|$sessionId|$turnId|$eventName"
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $path = Join-Path $root ($hash + '.json')
        $counts = Invoke-WithNamedMutex -Name ('CodexSettings.HookInvocation.' + $hash) -Action {
            $value = New-HookInvocationCounts
            $stored = $null
            if (Test-Path -LiteralPath $path -PathType Leaf) { try { $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop } catch {} }
            if ($null -ne $stored) { foreach ($property in @($value.Keys)) { if ($null -ne $stored.PSObject.Properties[$property]) { $value[$property] = [int]$stored.$property } } }
            $value.CrlfInvocationCount = [int]$value.CrlfInvocationCount + 1
            if ($eventName -eq 'Stop') {
                if ($script:HookSource -eq 'project') { $value.ProjectStopHookCount = [int]$value.ProjectStopHookCount + 1 } else { $value.GlobalStopHookCount = [int]$value.GlobalStopHookCount + 1 }
            }
            if ($eventName -eq 'PostToolUse') {
                if ($script:HookSource -eq 'project') { $value.ProjectPostToolUseHookCount = [int]$value.ProjectPostToolUseHookCount + 1 } else { $value.GlobalPostToolUseHookCount = [int]$value.GlobalPostToolUseHookCount + 1 }
            }
            $value.EffectiveStopHookCount = $value.GlobalStopHookCount + $value.ProjectStopHookCount
            $value.EffectivePostToolUseHookCount = $value.GlobalPostToolUseHookCount + $value.ProjectPostToolUseHookCount
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $temporaryPath = $path + '.tmp-' + [guid]::NewGuid().ToString('N')
            try {
                [IO.File]::WriteAllText($temporaryPath, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
                Move-Item -LiteralPath $temporaryPath -Destination $path -Force
            } finally {
                if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
            }
            return [pscustomobject]$value
        }
    } catch {} finally { Add-HookTiming -Name 'invocationCounterMs' -Milliseconds $stopwatch.ElapsedMilliseconds }
    return [pscustomobject]$counts
}

function Write-HookDiagnostic($InputObject, [string]$Result, [string[]]$ChangedFiles, [string]$Details) {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $root = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_HOOK_LOG_ROOT)) { Join-Path $HOME '.codex\logs\hooks' } else { $env:CODEX_SETTINGS_HOOK_LOG_ROOT }
        $sessionId = if ($null -eq $InputObject) { 'unknown' } else { [string]$InputObject.session_id }
        $safeSessionId = [regex]::Replace($sessionId, '[^A-Za-z0-9._-]', '_')
        $counts = if ($null -eq $script:HookInvocationCounts) { [pscustomobject](New-HookInvocationCounts) } else { $script:HookInvocationCounts }
        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString('o')
            event = if ($null -eq $InputObject) { $Mode } else { [string]$InputObject.hook_event_name }
            handler = 'preserve-line-endings'
            stopKind = if ($Mode -eq 'Finalize') { 'line-ending-finalize' } else { 'line-ending-' + $Mode.ToLowerInvariant() }
            mode = $Mode
            result = $Result
            sessionId = $sessionId
            turnId = if ($null -eq $InputObject) { '' } else { [string]$InputObject.turn_id }
            tool = if ($null -eq $InputObject) { '' } else { [string]$InputObject.tool_name }
            changedFileCount = @($ChangedFiles).Count
            changedFiles = @($ChangedFiles)
            statusMessage = ''
            hookSource = $script:HookSource
            hookCommand = $script:HookCommand
            processId = $PID
            parentProcessId = Get-HookParentProcessId
            startTime = $script:HookStartTime.ToString('o')
            endTime = [DateTimeOffset]::Now.ToString('o')
            elapsedMs = $script:HookStopwatch.ElapsedMilliseconds
            exitCode = $script:HookExitCode
            GlobalStopHookCount = [int]$counts.GlobalStopHookCount
            ProjectStopHookCount = [int]$counts.ProjectStopHookCount
            EffectiveStopHookCount = [int]$counts.EffectiveStopHookCount
            GlobalPostToolUseHookCount = [int]$counts.GlobalPostToolUseHookCount
            ProjectPostToolUseHookCount = [int]$counts.ProjectPostToolUseHookCount
            EffectivePostToolUseHookCount = [int]$counts.EffectivePostToolUseHookCount
            NotificationInvocationCount = [int]$counts.NotificationInvocationCount
            CrlfInvocationCount = [int]$counts.CrlfInvocationCount
            stateLockWaitMs = [long]$script:HookTimings.stateLockWaitMs
            stateReadMs = [long]$script:HookTimings.stateReadMs
            trackedFileDiscoveryMs = [long]$script:HookTimings.trackedFileDiscoveryMs
            metadataScanMs = [long]$script:HookTimings.metadataScanMs
            fileReadMs = [long]$script:HookTimings.fileReadMs
            restoreMs = [long]$script:HookTimings.restoreMs
            stateWriteMs = [long]$script:HookTimings.stateWriteMs
            invocationCounterMs = [long]$script:HookTimings.invocationCounterMs
            diagnosticWriteMs = [long]$stopwatch.ElapsedMilliseconds
            candidateScoped = [bool]$script:HookTimings.candidateScoped
            stateFileCountChecked = [long]$script:HookTimings.stateFileCountChecked
            lineEndingIndexHitCount = [long]$script:HookTimings.lineEndingIndexHitCount
            lineEndingIndexMissCount = [long]$script:HookTimings.lineEndingIndexMissCount
            details = $Details
        }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::AppendAllText((Join-Path $root ($safeSessionId + '.log')), (($entry | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    } catch {} finally { Add-HookTiming -Name 'diagnosticWriteMs' -Milliseconds $stopwatch.ElapsedMilliseconds }
}

function Save-InitialState($InputObject) {
    $root = Get-CvsRoot -StartPath ([string]$InputObject.cwd)
    if ([string]::IsNullOrWhiteSpace($root)) { return }
    $statePath = Get-StatePath -SessionId ([string]$InputObject.session_id) -ProjectRoot $root
    $stateExists = Invoke-WithStateLock -ProjectRoot $root -SessionId ([string]$InputObject.session_id) -Action { Test-Path -LiteralPath $statePath -PathType Leaf }
    if ($stateExists) { return }

    $discoveryStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $trackedPaths = @(Get-CvsTrackedFiles -Root $root)
    Add-HookTiming -Name 'trackedFileDiscoveryMs' -Milliseconds $discoveryStopwatch.ElapsedMilliseconds
    $indexPath = Get-LineEndingIndexPath -ProjectRoot $root
    $indexReadStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $index = Read-LineEndingIndex -Path $indexPath
    Add-HookTiming -Name 'stateReadMs' -Milliseconds $indexReadStopwatch.ElapsedMilliseconds
    $indexFiles = [ordered]@{}
    $files = [ordered]@{}

    foreach ($path in $trackedPaths) {
        $metadataStopwatch = [Diagnostics.Stopwatch]::StartNew()
        try { $fileInfo = [IO.FileInfo]::new($path) } catch { continue }
        Add-HookTiming -Name 'metadataScanMs' -Milliseconds $metadataStopwatch.ElapsedMilliseconds
        $cached = if ($null -ne $index -and $null -ne $index.files) { $index.files.PSObject.Properties[$path] } else { $null }
        $cachedMetadataMatches = $null -ne $cached -and [long]$cached.Value.verifiedLength -eq $fileInfo.Length -and [long]$cached.Value.verifiedLastWriteTimeUtcTicks -eq $fileInfo.LastWriteTimeUtc.Ticks
        if ($cachedMetadataMatches -and [bool]$cached.Value.binary) {
            $indexFiles[$path] = [ordered]@{ binary = $true; verifiedLength = $fileInfo.Length; verifiedLastWriteTimeUtcTicks = $fileInfo.LastWriteTimeUtc.Ticks }
            $script:HookTimings.lineEndingIndexHitCount++
            continue
        }
        if ($cachedMetadataMatches -and -not [string]::IsNullOrWhiteSpace([string]$cached.Value.sha256)) {
            $record = Copy-LineEndingFileState -Value $cached.Value
            $script:HookTimings.lineEndingIndexHitCount++
        } else {
            $record = New-LineEndingFileState -Path $path -FileInfo $fileInfo
            $script:HookTimings.lineEndingIndexMissCount++
        }
        if ($null -eq $record) {
            $indexFiles[$path] = [ordered]@{ binary = $true; verifiedLength = $fileInfo.Length; verifiedLastWriteTimeUtcTicks = $fileInfo.LastWriteTimeUtc.Ticks }
            continue
        }
        $files[$path] = $record
        $indexFiles[$path] = $record
    }

    $state = [ordered]@{ sessionId = [string]$InputObject.session_id; projectRoot = $root; files = $files }
    Invoke-WithStateLock -ProjectRoot $root -SessionId ([string]$InputObject.session_id) -Action {
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { Write-LineEndingState -Path $statePath -State $state }
    } | Out-Null
    Invoke-WithIndexLock -ProjectRoot $root -Action {
        Write-LineEndingIndex -Path $indexPath -Index ([ordered]@{ schemaVersion = 1; projectRoot = $root; files = $indexFiles })
    } | Out-Null
}

function Restore-InitialState($InputObject, [Collections.Generic.List[string]]$Warnings, [switch]$Cleanup) {
    $restoreStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $changedFiles = [Collections.Generic.List[string]]::new()
    $stateFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $updatedStateFiles = [ordered]@{}
    $root = Get-CvsRoot -StartPath ([string]$InputObject.cwd)
    $statePath = if ([string]::IsNullOrWhiteSpace($root)) { $null } else { Get-StatePath -SessionId ([string]$InputObject.session_id) -ProjectRoot $root }
    $candidateFiles = if ([string]::IsNullOrWhiteSpace($root)) { @() } else { @(Get-HookCandidateFiles -InputObject $InputObject -Root $root) }
    $useScopedCandidateScan = -not $Cleanup -and $candidateFiles.Count -gt 0 -and (Test-IsScopedPatchInput -InputObject $InputObject)
    $script:HookTimings.candidateScoped = $useScopedCandidateScan
    if ($null -ne $statePath -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        try {
            $state = Invoke-WithStateLock -ProjectRoot $root -SessionId ([string]$InputObject.session_id) -Action {
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
            $stateReadStopwatch = [Diagnostics.Stopwatch]::StartNew()
            try { return [IO.File]::ReadAllText($statePath) | ConvertFrom-Json -ErrorAction Stop }
            finally { Add-HookTiming -Name 'stateReadMs' -Milliseconds $stateReadStopwatch.ElapsedMilliseconds }
            }
            if ($null -ne $state) {
            $root = [IO.Path]::GetFullPath([string]$state.projectRoot).TrimEnd('\', '/')
            $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
            $stateProperties = if ($useScopedCandidateScan) {
                @($candidateFiles | ForEach-Object {
                    $candidateProperty = $state.files.PSObject.Properties[$_]
                    if ($null -ne $candidateProperty) { $candidateProperty }
                })
            } else {
                @($state.files.PSObject.Properties)
            }
            foreach ($property in $stateProperties) {
                $script:HookTimings.stateFileCountChecked++
                try {
                    $path = [IO.Path]::GetFullPath([string]$property.Name)
                    if (-not $path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
                    [void]$stateFiles.Add($path)
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                    $original = $property.Value
                    $fileInfo = [IO.FileInfo]::new($path)
                    if ($fileInfo.Length -eq [long]$original.verifiedLength -and $fileInfo.LastWriteTimeUtc.Ticks -eq [long]$original.verifiedLastWriteTimeUtcTicks) { continue }

                    $fileReadStopwatch = [Diagnostics.Stopwatch]::StartNew()
                    $bytes = [IO.File]::ReadAllBytes($path)
                    Add-HookTiming -Name 'fileReadMs' -Milliseconds $fileReadStopwatch.ElapsedMilliseconds
                    if (Test-BinaryBytes -Bytes $bytes) { continue }
                    if ((Get-Sha256 -Bytes $bytes) -ne [string]$original.sha256) {
                        $restored = Restore-BomBytes -Bytes $bytes -OriginalBom ([string]$original.bom)
                        $restoreStyle = if ([string]$original.lineEnding -eq 'MIXED') { [string]$original.preferredLineEnding } else { [string]$original.lineEnding }
                        if ($restoreStyle -in @('CRLF', 'LF')) {
                            $restored = Convert-LineEndingBytes -Bytes $restored -Style $restoreStyle
                        }
                        $finalStyle = if ($restoreStyle -in @('CRLF', 'LF')) { $restoreStyle } elseif ([string]$original.finalNewlineStyle -in @('CRLF', 'LF')) { [string]$original.finalNewlineStyle } else { 'LF' }
                        $restored = Set-FinalNewlineBytes -Bytes $restored -FinalNewline ([bool]$original.finalNewline) -Style $finalStyle
                        if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$bytes, [byte[]]$restored)) {
                            [IO.File]::WriteAllBytes($path, $restored)
                            $changedFiles.Add($path)
                        }
                    }

                    $fileInfo.Refresh()
                    $original.verifiedLength = $fileInfo.Length
                    $original.verifiedLastWriteTimeUtcTicks = $fileInfo.LastWriteTimeUtc.Ticks
                    $updatedStateFiles[$path] = $original
                } catch {
                    $Warnings.Add("Failed to restore line endings for $($property.Name): $($_.Exception.Message)")
                }
            }

            if ($updatedStateFiles.Count -gt 0) {
                if (-not $Cleanup) {
                    Invoke-WithStateLock -ProjectRoot $root -SessionId ([string]$InputObject.session_id) -Action {
                        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return }
                        $latestState = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json -ErrorAction Stop
                        foreach ($path in $updatedStateFiles.Keys) {
                            $latestProperty = $latestState.files.PSObject.Properties[$path]
                            if ($null -ne $latestProperty) {
                                $latestProperty.Value.verifiedLength = $updatedStateFiles[$path].verifiedLength
                                $latestProperty.Value.verifiedLastWriteTimeUtcTicks = $updatedStateFiles[$path].verifiedLastWriteTimeUtcTicks
                            }
                        }
                        Write-LineEndingState -Path $statePath -State $latestState
                    } | Out-Null
                }
            }
            }
        } finally {
            if ($Cleanup) {
                Invoke-WithStateLock -ProjectRoot $root -SessionId ([string]$InputObject.session_id) -Action {
                    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
                } | Out-Null
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($root)) {
        $mixedCandidateFiles = $candidateFiles
        foreach ($path in $mixedCandidateFiles) {
            try {
                if ($stateFiles.Contains($path)) { continue }
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                $fileReadStopwatch = [Diagnostics.Stopwatch]::StartNew()
                $bytes = [IO.File]::ReadAllBytes($path)
                Add-HookTiming -Name 'fileReadMs' -Milliseconds $fileReadStopwatch.ElapsedMilliseconds
                if (Test-BinaryBytes -Bytes $bytes) { continue }
                $lineEndings = Get-LineEndingState -Bytes $bytes
                if ($lineEndings.Style -ne 'MIXED') { continue }
                $restored = Convert-LineEndingBytes -Bytes $bytes -Style $lineEndings.PreferredStyle
                if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$bytes, [byte[]]$restored)) {
                    [IO.File]::WriteAllBytes($path, $restored)
                    if (-not $changedFiles.Contains($path)) { $changedFiles.Add($path) }
                }
            } catch {
                $Warnings.Add("Failed to repair mixed line endings for $path`: $($_.Exception.Message)")
            }
        }
    }
    Add-HookTiming -Name 'restoreMs' -Milliseconds $restoreStopwatch.ElapsedMilliseconds
    return $changedFiles.ToArray()
}

function Test-IsSafeReadOnlyCommand($InputObject) {
    $toolName = [string]$InputObject.tool_name
    if ($toolName -in @('request_user_input', 'view_image', 'read_mcp_resource', 'list_mcp_resources', 'list_mcp_resource_templates')) { return $true }
    if ($toolName -notin @('exec', 'shell_command', 'run_shell_command')) { return $false }
    $command = ([string]$InputObject.tool_input.command).Trim()
    if ([string]::IsNullOrWhiteSpace($command) -or $command -match '[\r\n;|&<>`]' -or $command -match '\$[({]' -or $command -match '(?i)(?:--pre\b|Invoke-Expression|Start-Process|powershell(?:\.exe)?|pwsh(?:\.exe)?|cmd(?:\.exe)?|bash|sh)') { return $false }
    return $command -match '^(?:(?:Get-Content|rg|ripgrep|php\s+-l|cvs\s+(?:status|diff)|git\s+(?:status|diff))(?:\s|$))'
}

function Test-IsScopedPatchInput($InputObject) {
    $toolName = [string]$InputObject.tool_name
    if ($toolName -eq 'apply_patch') { return $true }
    $command = ([string]$InputObject.tool_input.command).Trim()
    if ($command -match '[\r\n;|&<>`]' -or $command -match '\$[({]') { return $false }
    return $command -match '(?s)^.*\btools\.apply_patch\s*\('
}

function Test-NeedsLineEndingState($InputObject) {
    return -not (Test-IsSafeReadOnlyCommand -InputObject $InputObject)
}

$warnings = [Collections.Generic.List[string]]::new()
$inputObject = $null
$changedFiles = @()
try {
    $inputText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputText)) { throw 'Hook input JSON is empty.' }
    $inputObject = ConvertFrom-HookInputJson -Text $inputText
    if ([string]::IsNullOrWhiteSpace([string]$inputObject.session_id)) { throw 'Hook input is missing session_id.' }
    $script:HookSource = Get-HookSource
    $script:HookInvocationCounts = Get-HookInvocationCounts -InputObject $inputObject
    if ($Mode -eq 'Track') {
        if ([string]::IsNullOrWhiteSpace([string]$inputObject.cwd)) { throw 'Hook input is missing cwd.' }
        if (Test-NeedsLineEndingState -InputObject $inputObject) { Save-InitialState -InputObject $inputObject }
    } elseif ($Mode -eq 'Finalize' -or (Test-NeedsLineEndingState -InputObject $inputObject)) {
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
