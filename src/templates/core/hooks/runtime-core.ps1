# Shared, low-cost runtime primitives for all managed Codex hooks.
# Keep adapters (ccusage, CVS, WinRT) in their entrypoints; this file owns
# invocation normalization, state envelopes, locking and diagnostics context.

function ConvertFrom-CodexHookInputJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)

    try { return $Text | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $originalError = $_
        $pattern = '(?s)("last_assistant_message"\s*:\s*)".*"(\s*}\s*)$'
        $sanitized = [regex]::Replace($Text, $pattern, '$1null$2')
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

function New-CodexHookInvocationContext {
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [string]$HookSource = 'global')

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        eventName = if ($null -eq $InputObject) { '' } else { [string]$InputObject.hook_event_name }
        sessionId = if ($null -eq $InputObject) { '' } else { [string]$InputObject.session_id }
        turnId = if ($null -eq $InputObject) { '' } else { [string]$InputObject.turn_id }
        cwd = if ($null -eq $InputObject) { '' } else { [string]$InputObject.cwd }
        toolName = if ($null -eq $InputObject) { '' } else { [string]$InputObject.tool_name }
        toolInput = if ($null -eq $InputObject) { $null } else { $InputObject.tool_input }
        hookSource = $HookSource
        processId = [int]$PID
        parentProcessId = 0
        startedAt = [DateTimeOffset]::UtcNow.ToString('o')
        payload = $InputObject
    }
}

function Read-CodexHookInvocation {
    [CmdletBinding()]
    param()

    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ConvertFrom-CodexHookInputJson -Text $raw
}

function Get-CodexHookSource {
    [CmdletBinding()]
    param()

    try {
        $current = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/')
        $globalRoot = [IO.Path]::GetFullPath((Join-Path $HOME '.codex\hooks')).TrimEnd('\', '/')
        if ($current.Equals($globalRoot, [StringComparison]::OrdinalIgnoreCase)) { return 'global' }
        if ([IO.Path]::GetFileName($current).Equals('hooks', [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName((Split-Path -Parent $current)).Equals('.codex', [StringComparison]::OrdinalIgnoreCase)) { return 'project' }
    } catch {}
    return 'global'
}

function Get-CodexHookParentProcessId {
    [CmdletBinding()]
    param()

    $parentProcessId = 0
    try {
        $parent = (Get-Process -Id $PID -ErrorAction Stop).Parent
        if ($null -ne $parent) { $parentProcessId = [int]$parent.Id }
    } catch {}
    if ($parentProcessId -eq 0) {
        try { $parentProcessId = [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId } catch {}
    }
    return $parentProcessId
}

function Invoke-CodexHookMutex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Action, [int]$TimeoutMilliseconds = 5000)

    $mutex = $null
    $lockHeld = $false
    try {
        $mutex = [Threading.Mutex]::new($false, $Name)
        try { $lockHeld = $mutex.WaitOne($TimeoutMilliseconds) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
        if (-not $lockHeld) { throw "Unable to acquire Codex hook mutex: $Name" }
        return & $Action
    } finally {
        if ($lockHeld -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Get-CodexHookStatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Kind, [Parameter(Mandatory = $true)][string]$Key, [string]$Root = '')

    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT)) { $env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT } else { Join-Path $HOME '.codex\state' } }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Kind|$Key")))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return Join-Path (Join-Path ([IO.Path]::GetFullPath($Root)) $Kind) ($hash + '.json')
}

function Read-CodexHookState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Kind, [Parameter(Mandatory = $true)][string]$Key, [AllowNull()]$DefaultPayload = $null, [string]$Root = '')

    $path = Get-CodexHookStatePath -Kind $Kind -Key $Key -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject][ordered]@{ schemaVersion = 1; kind = $Kind; key = $Key; createdAt = [DateTimeOffset]::UtcNow.ToString('o'); updatedAt = [DateTimeOffset]::UtcNow.ToString('o'); payload = $DefaultPayload } }
    try {
        $stored = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        if ($stored.PSObject.Properties.Name -contains 'payload' -and $stored.PSObject.Properties.Name -contains 'schemaVersion') { return $stored }
        return [pscustomobject][ordered]@{ schemaVersion = 1; kind = $Kind; key = $Key; createdAt = [DateTimeOffset]::UtcNow.ToString('o'); updatedAt = [DateTimeOffset]::UtcNow.ToString('o'); payload = $stored }
    } catch {
        try { Move-Item -LiteralPath $path -Destination ($path + '.corrupt-' + [guid]::NewGuid().ToString('N')) -Force -ErrorAction SilentlyContinue } catch {}
        return [pscustomobject][ordered]@{ schemaVersion = 1; kind = $Kind; key = $Key; createdAt = [DateTimeOffset]::UtcNow.ToString('o'); updatedAt = [DateTimeOffset]::UtcNow.ToString('o'); payload = $DefaultPayload }
    }
}

function Write-CodexHookState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Kind, [Parameter(Mandatory = $true)][string]$Key, [AllowNull()]$Payload = $null, [string]$Root = '', [int]$Depth = 12)

    $path = Get-CodexHookStatePath -Kind $Kind -Key $Key -Root $Root
    $directory = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToString('o')
    $value = [ordered]@{ schemaVersion = 1; kind = $Kind; key = $Key; createdAt = $now; updatedAt = $now; payload = $Payload }
    $temporaryPath = $path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, ($value | ConvertTo-Json -Depth $Depth -Compress), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]$value
}

function New-CodexHookInvocationCounts {
    return [ordered]@{ GlobalStopHookCount = 0; ProjectStopHookCount = 0; EffectiveStopHookCount = 0; GlobalPostToolUseHookCount = 0; ProjectPostToolUseHookCount = 0; EffectivePostToolUseHookCount = 0; NotificationInvocationCount = 0; CrlfInvocationCount = 0 }
}

function Get-CodexHookInvocationCounts {
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [ValidateSet('notification', 'crlf')][string]$Kind = 'notification', [string]$EventName = '', [string]$HookSource = 'global')

    $sessionId = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.session_id)) { 'unknown-session' } else { [string]$InputObject.session_id }
    $turnId = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.turn_id)) { 'unknown-turn' } else { [string]$InputObject.turn_id }
    $event = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.hook_event_name)) { $EventName } else { [string]$InputObject.hook_event_name }
    $cwd = if ($null -eq $InputObject) { '' } else { [string]$InputObject.cwd }
    $key = "$cwd|$sessionId|$turnId|$event"
    $root = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT)) { [IO.Path]::GetFullPath($env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT) } else { Join-Path $HOME '.codex\state\hook-invocations' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $path = Join-Path $root ($hash + '.json')
    return Invoke-CodexHookMutex -Name ('CodexSettings.HookInvocation.' + $hash) -Action {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $stored = $null
        if (Test-Path -LiteralPath $path -PathType Leaf) { try { $stored = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop } catch {} }
        $value = New-CodexHookInvocationCounts
        $payload = if ($null -ne $stored -and $null -ne $stored.payload) { $stored.payload } else { $stored }
        foreach ($property in @($value.Keys)) { if ($null -ne $payload -and $null -ne $payload.PSObject.Properties[$property]) { $value[$property] = [int]$payload.$property } }
        if ($Kind -eq 'notification') { $value.NotificationInvocationCount++ }
        if ($Kind -eq 'crlf') { $value.CrlfInvocationCount++ }
        if ($event -eq 'Stop') { if ($HookSource -eq 'project') { $value.ProjectStopHookCount++ } else { $value.GlobalStopHookCount++ } }
        if ($event -eq 'PostToolUse') { if ($HookSource -eq 'project') { $value.ProjectPostToolUseHookCount++ } else { $value.GlobalPostToolUseHookCount++ } }
        $value.EffectiveStopHookCount = $value.GlobalStopHookCount + $value.ProjectStopHookCount
        $value.EffectivePostToolUseHookCount = $value.GlobalPostToolUseHookCount + $value.ProjectPostToolUseHookCount
        $envelope = [ordered]@{ schemaVersion = 1; kind = 'hook-invocation'; key = $key; createdAt = [DateTimeOffset]::UtcNow.ToString('o'); updatedAt = [DateTimeOffset]::UtcNow.ToString('o'); payload = [pscustomobject]$value }
        foreach ($property in $value.Keys) { $envelope[$property] = $value[$property] }
        $temporaryPath = $path + '.tmp-' + [guid]::NewGuid().ToString('N')
        try { [IO.File]::WriteAllText($temporaryPath, ($envelope | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath $temporaryPath -Destination $path -Force }
        finally { if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue } }
        return [pscustomobject]$value
    }
}
