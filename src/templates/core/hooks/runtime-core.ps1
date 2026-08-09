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

function Get-CodexPatchTargetPaths {
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return @() }
    $toolInput = $InputObject.tool_input
    $command = if ($null -eq $toolInput) { '' } else { [string]$toolInput.command }
    $patch = if ($null -ne $toolInput -and $null -ne $toolInput.patch) { [string]$toolInput.patch } else { '' }
    $text = ($command + "`n" + $patch).Replace('\n', "`n")
    return @([regex]::Matches($text, '(?m)^\*\*\* (?:Update|Add|Delete) File:\s*(?<path>[^\r\n]+)$') | ForEach-Object { $_.Groups['path'].Value.Trim().Replace('\\', '\') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Test-CodexVerifiedReadOnlyCommand {
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return $false }
    $command = ([string]$InputObject.tool_input.command).Trim()
    if ([string]::IsNullOrWhiteSpace($command) -or $command -match '[\r\n;|&<>`]' -or $command -match '\$[({]' -or $command -match '(?i)(?:--pre\b|Invoke-Expression|Start-Process|powershell(?:\.exe)?|pwsh(?:\.exe)?|cmd(?:\.exe)?|bash|sh)') { return $false }
    return $command -match '^(?:(?:Get-Content|Get-ChildItem|Get-Item|Test-Path|Resolve-Path|Select-String|rg|ripgrep|php\s+-l|cvs\s+(?:status|diff)|git\s+(?:status|diff|log|show|ls-files))(?:\s|$))'
}

function Get-CodexToolImpactClassification {
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    $toolName = if ($null -eq $InputObject) { '' } else { [string]$InputObject.tool_name }
    if ($toolName -in @('request_user_input', 'view_image', 'read_mcp_resource', 'list_mcp_resources', 'list_mcp_resource_templates')) {
            return [pscustomobject][ordered]@{ schemaVersion = 1; classification = 'NoFileImpact'; workClass = 'None'; validationLevel = 'None'; knownWriteTargets = @(); reason = 'tool-does-not-access-local-files' }
    }
    $targets = @(Get-CodexPatchTargetPaths -InputObject $InputObject)
    $command = if ($null -eq $InputObject) { '' } else { [string]$InputObject.tool_input.command }
    if ($toolName -eq 'apply_patch' -or $command -match '(?s)\*\*\* Begin Patch') {
        if ($targets.Count -gt 0) {
            return [pscustomobject][ordered]@{ schemaVersion = 1; classification = 'KnownWriteTargets'; workClass = 'Critical'; validationLevel = 'ChangedOnly'; knownWriteTargets = $targets; reason = 'patch-targets-are-explicit' }
        }
        return [pscustomobject][ordered]@{ schemaVersion = 1; classification = 'UnknownWriteScope'; workClass = 'Critical'; validationLevel = 'Full'; knownWriteTargets = @(); reason = 'write-tool-without-explicit-targets' }
    }
    if ($toolName -in @('request_user_input', 'view_image', 'read_mcp_resource', 'list_mcp_resources', 'list_mcp_resource_templates')) {
        return [pscustomobject][ordered]@{ schemaVersion = 1; classification = 'NoFileImpact'; workClass = 'None'; validationLevel = 'None'; knownWriteTargets = @(); reason = 'tool-does-not-access-local-files' }
    }
    if ($toolName -in @('exec', 'shell_command', 'run_shell_command') -and (Test-CodexVerifiedReadOnlyCommand -InputObject $InputObject)) {
        return [pscustomobject][ordered]@{ schemaVersion = 1; classification = 'ReadOnly'; workClass = 'Conditional'; validationLevel = 'Fast'; knownWriteTargets = @(); reason = 'command-matches-verified-read-only-form' }
    }
    return [pscustomobject][ordered]@{ schemaVersion = 1; classification = 'UnknownWriteScope'; workClass = 'Critical'; validationLevel = 'Full'; knownWriteTargets = @(); reason = 'write-scope-cannot-be-proven' }
}

function Get-CodexMainSessionClassification {
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return [pscustomobject]@{ Classification = 'Unknown'; Evidence = 'payload-null' } }
    foreach ($name in @('is_main_session', 'main_session', 'is_main')) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -eq $property) { continue }
        if ($property.Value -is [string]) {
            $text = ([string]$property.Value).Trim().ToLowerInvariant()
            if ($text -in @('true', '1', 'yes')) { return [pscustomobject]@{ Classification = 'Main'; Evidence = "$name=$text" } }
            if ($text -in @('false', '0', 'no')) { return [pscustomobject]@{ Classification = 'Subagent'; Evidence = "$name=$text" } }
        }
        return [pscustomobject]@{ Classification = $(if ([bool]$property.Value) { 'Main' } else { 'Subagent' }); Evidence = "$name=$($property.Value)" }
    }
    foreach ($name in @('parent_session_id', 'parent_session', 'forked_from_session_id')) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { return [pscustomobject]@{ Classification = 'Subagent'; Evidence = "$name=present" } }
    }
    return [pscustomobject]@{ Classification = 'Unknown'; Evidence = 'no-main-session-fields' }
}

function Test-CodexMainSession {
    [CmdletBinding()]
    param([AllowNull()]$InputObject)

    return (Get-CodexMainSessionClassification -InputObject $InputObject).Classification -ne 'Subagent'
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
