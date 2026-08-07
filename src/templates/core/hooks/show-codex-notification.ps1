[CmdletBinding()]
param(
    [ValidateSet('Completed', 'PermissionRequired', 'QuestionRequired', 'Error')]
    [string]$Type = 'Completed',
    [switch]$Test,
    [switch]$NativeToast,
    [string]$NativeTitle,
    [string]$NativeMessage,
    [ValidateSet('Completed', 'PermissionRequired', 'QuestionRequired', 'Error')]
    [string]$NativeNotificationType = 'Completed',
    [switch]$NativeSound,
    [string]$NativeTag
)

$ErrorActionPreference = 'Stop'
$script:HookStartTime = [DateTimeOffset]::Now
$script:HookStopwatch = [Diagnostics.Stopwatch]::StartNew()
$script:HookCommand = if ([string]::IsNullOrWhiteSpace([string]$MyInvocation.Line)) { $PSCommandPath } else { [string]$MyInvocation.Line }
$script:HookSource = 'global'
$script:HookExitCode = 0
$script:ToastAppId = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App'
$script:ToastGroup = 'CodexSettings'
$script:ToastLifetimeSeconds = 60
$script:PreviousToastLifetimeSeconds = 60
$script:ToastStateMutexName = 'CodexSettings.ToastState'
$script:NotificationClaimState = 'not-claimed'
$script:NotificationClaimPath = ''
$script:NotificationHandlerId = 'notification-toast'
$script:NativeToastAttempted = $false
$script:NativeToastShown = $false
$script:FallbackAttempted = $false
$script:FallbackShown = $false
$script:CleanupScheduled = $false

function Write-HookResult { [Console]::Out.Write('{}') }

function ConvertFrom-HookInputJson([string]$Text) {
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

function Get-HookInput {
    try {
        $raw = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ConvertFrom-HookInputJson -Text $raw
    } catch { return $null }
}

function Get-UsageValue($Usage, [string[]]$Names, $Default = 0) {
    if ($null -eq $Usage) { return $Default }
    foreach ($name in $Names) {
        $property = $Usage.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $Default
}

function Test-UsageProperty($Usage, [string[]]$Names) {
    if ($null -eq $Usage) { return $false }
    foreach ($name in $Names) {
        $property = $Usage.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { return $true }
    }
    return $false
}

function Get-UsageField($Usage, [string[]]$Names) {
    if ($null -eq $Usage) { return [pscustomobject]@{ Present = $false; Value = $null; Name = $null } }
    foreach ($name in $Names) {
        $property = $Usage.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return [pscustomobject]@{ Present = $true; Value = $property.Value; Name = $name }
        }
    }
    return [pscustomobject]@{ Present = $false; Value = $null; Name = $null }
}
function Get-NotificationRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_NOTIFICATION_STATE_ROOT)) {
        return [IO.Path]::GetFullPath($env:CODEX_SETTINGS_NOTIFICATION_STATE_ROOT)
    }
    return Join-Path $HOME '.codex\state\notifications'
}

function Get-TokenUsageRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT)) {
        return [IO.Path]::GetFullPath($env:CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT)
    }
    return Join-Path $HOME '.codex\state\token-usage'
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
    try {
        $parent = (Get-Process -Id $PID -ErrorAction Stop).Parent
        if ($null -ne $parent) { return [int]$parent.Id }
    } catch {}
    try { return [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId }
    catch { return 0 }
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

function Get-HookInvocationCounts($InputObject, [ValidateSet('notification', 'crlf')][string]$Kind) {
    $counts = New-HookInvocationCounts
    try {
        $root = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT)) { Join-Path $HOME '.codex\state\hook-invocations' } else { [IO.Path]::GetFullPath($env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT) }
        $sessionId = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.session_id)) { 'unknown-session' } else { [string]$InputObject.session_id }
        $turnId = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.turn_id)) { 'unknown-turn' } else { [string]$InputObject.turn_id }
        $eventName = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.hook_event_name)) { $Type } else { [string]$InputObject.hook_event_name }
        $cwd = if ($null -eq $InputObject) { '' } else { [string]$InputObject.cwd }
        $key = "$cwd|$sessionId|$turnId|$eventName"
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $path = Join-Path $root ($hash + '.json')
        $counts = Invoke-WithNamedMutex -Name ('CodexSettings.HookInvocation.' + $hash) -Action {
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            $value = New-HookInvocationCounts
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                try {
                    $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
                    foreach ($property in @($value.Keys)) { if ($null -ne $stored.PSObject.Properties[$property]) { $value[$property] = [int]$stored.$property } }
                } catch {}
            }
            if ($Kind -eq 'notification') { $value.NotificationInvocationCount = [int]$value.NotificationInvocationCount + 1 }
            if ($Kind -eq 'crlf') { $value.CrlfInvocationCount = [int]$value.CrlfInvocationCount + 1 }
            if ($eventName -eq 'Stop') {
                if ($script:HookSource -eq 'project') { $value.ProjectStopHookCount = [int]$value.ProjectStopHookCount + 1 } else { $value.GlobalStopHookCount = [int]$value.GlobalStopHookCount + 1 }
            }
            if ($eventName -eq 'PostToolUse') {
                if ($script:HookSource -eq 'project') { $value.ProjectPostToolUseHookCount = [int]$value.ProjectPostToolUseHookCount + 1 } else { $value.GlobalPostToolUseHookCount = [int]$value.GlobalPostToolUseHookCount + 1 }
            }
            $value.EffectiveStopHookCount = $value.GlobalStopHookCount + $value.ProjectStopHookCount
            $value.EffectivePostToolUseHookCount = $value.GlobalPostToolUseHookCount + $value.ProjectPostToolUseHookCount
            $temporaryPath = $path + '.tmp-' + [guid]::NewGuid().ToString('N')
            try {
                [IO.File]::WriteAllText($temporaryPath, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
                Move-Item -LiteralPath $temporaryPath -Destination $path -Force
            } finally {
                if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
            }
            return [pscustomobject]$value
        }
    } catch {}
    if ($counts -is [hashtable] -or $counts -is [Collections.IDictionary]) { return [pscustomobject]$counts }
    return $counts
}

function Write-HookDiagnostic($InputObject, [string]$Result, [string]$Details) {
    try {
        $root = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_HOOK_LOG_ROOT)) { Join-Path $HOME '.codex\logs\hooks' } else { $env:CODEX_SETTINGS_HOOK_LOG_ROOT }
        $sessionId = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.session_id)) { 'unknown' } else { [string]$InputObject.session_id }
        $safeSessionId = [regex]::Replace($sessionId, '[^A-Za-z0-9._-]', '_')
        $counts = if ($null -eq $script:HookInvocationCounts) { [pscustomobject](New-HookInvocationCounts) } else { $script:HookInvocationCounts }
        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString('o')
            event = if ($null -eq $InputObject) { '' } else { [string]$InputObject.hook_event_name }
            handler = 'windows-notification'
            stopKind = 'notification'
            notificationType = $Type
            result = $Result
            sessionId = $sessionId
            turnId = if ($null -eq $InputObject) { '' } else { [string]$InputObject.turn_id }
            tool = if ($null -eq $InputObject) { '' } else { [string]$InputObject.tool_name }
            changedFileCount = 0
            changedFiles = @()
            statusMessage = ''
            handlerId = $script:NotificationHandlerId
            claimState = $script:NotificationClaimState
            claimPath = $script:NotificationClaimPath
            nativeToastAttempted = [bool]$script:NativeToastAttempted
            nativeToastShown = [bool]$script:NativeToastShown
            fallbackAttempted = [bool]$script:FallbackAttempted
            fallbackShown = [bool]$script:FallbackShown
            cleanupScheduled = [bool]$script:CleanupScheduled
            hookSource = $script:HookSource
            invocationSource = '{0}:{1}' -f $script:HookSource, $script:NotificationHandlerId
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
            notificationInvocationIndex = [int]$counts.NotificationInvocationCount
            CrlfInvocationCount = [int]$counts.CrlfInvocationCount
            details = $Details
        }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::AppendAllText((Join-Path $root ($safeSessionId + '.log')), (($entry | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    } catch {}
}

function Get-NotificationSettings([string]$Root) {
    $defaults = [ordered]@{
        enabled = $true
        completed = $true
        permissionRequired = $true
        questionRequired = $true
        error = $true
        sound = $true
        mainSessionOnly = $true
        dedupeSeconds = 10
    }
    $path = Join-Path $Root 'settings.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        [IO.File]::WriteAllText($path, (($defaults | ConvertTo-Json) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]$defaults
    }
    try {
        $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in $defaults.Keys) {
            if ($stored.PSObject.Properties.Name -notcontains $property) { $stored | Add-Member -NotePropertyName $property -NotePropertyValue $defaults[$property] }
        }
        return $stored
    } catch { return [pscustomobject]$defaults }
}

function Get-TokenUsageSettings([string]$Root) {
    $defaults = [ordered]@{
        enabled = $true
        showAfterEachTurn = $true
        showSessionId = $true
        showCost = $true
        showModel = $true
        firstTurnMode = 'session-total'
        mainSessionOnly = $true
    }
    $path = Join-Path $Root 'settings.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        [IO.File]::WriteAllText($path, (($defaults | ConvertTo-Json) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]$defaults
    }
    try {
        $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in $defaults.Keys) {
            if ($stored.PSObject.Properties.Name -notcontains $property) { $stored | Add-Member -NotePropertyName $property -NotePropertyValue $defaults[$property] }
        }
        return $stored
    } catch { return [pscustomobject]$defaults }
}

function Get-NotificationClaimIdentity($InputObject, [string]$NotificationType) {
    $sessionId = [string]$InputObject.session_id
    $turnId = [string]$InputObject.turn_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = 'unknown-session' }
    if ([string]::IsNullOrWhiteSpace($turnId)) { $turnId = 'unknown-turn' }
    $key = if ($NotificationType -eq 'Completed') { "$sessionId|$turnId|Completed" } else { "$sessionId|$turnId|$NotificationType" }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{ SessionId = $sessionId; TurnId = $turnId; Type = $NotificationType; Key = $key; Hash = $hash }
}

function Get-DeduplicationPath([string]$Root, $InputObject, [string]$NotificationType) {
    $identity = Get-NotificationClaimIdentity -InputObject $InputObject -NotificationType $NotificationType
    return Join-Path (Join-Path $Root 'claims') ($identity.Hash + '.json')
}

function Write-NotificationJsonAtomic([string]$Path, $Value) {
    $root = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $temporaryPath = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, ($Value | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
        [void](Move-Item -LiteralPath $temporaryPath -Destination $Path -Force)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

function Read-NotificationClaim([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
}

function Test-NotificationClaimActive($Claim) {
    return $null -ne $Claim -and [string]$Claim.state -in @('showing', 'shown')
}

function Acquire-NotificationClaim([string]$Root, $InputObject, [string]$NotificationType) {
    $identity = Get-NotificationClaimIdentity -InputObject $InputObject -NotificationType $NotificationType
    $path = Join-Path (Join-Path $Root 'claims') ($identity.Hash + '.json')
    $claim = Invoke-WithNamedMutex -Name ('CodexSettings.NotificationClaim.' + $identity.Hash) -Action {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $existing = Read-NotificationClaim -Path $path
        if (Test-NotificationClaimActive -Claim $existing) {
            return [pscustomobject]@{ Acquired = $false; State = [string]$existing.state; Path = $path; Claim = $existing }
        }
        $value = [ordered]@{
            sessionId = $identity.SessionId
            turnId = $identity.TurnId
            type = $NotificationType
            handlerId = if ($NotificationType -eq 'Completed') { 'completed-token-toast' } else { 'notification-toast' }
            processId = $PID
            state = 'showing'
            startedAt = [DateTimeOffset]::UtcNow.ToString('o')
            updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Write-NotificationJsonAtomic -Path $path -Value $value
        return [pscustomobject]@{ Acquired = $true; State = 'showing'; Path = $path; Claim = [pscustomobject]$value }
    }
    $script:NotificationClaimPath = $path
    $script:NotificationClaimState = [string]$claim.State
    return $claim
}

function Set-NotificationClaimState($Claim, [ValidateSet('showing', 'shown', 'skipped', 'failed')][string]$State, [string]$Result = '') {
    if ($null -eq $Claim -or [string]::IsNullOrWhiteSpace([string]$Claim.Path)) { return }
    try {
        $path = [string]$Claim.Path
        $hash = [IO.Path]::GetFileNameWithoutExtension($path)
        Invoke-WithNamedMutex -Name ('CodexSettings.NotificationClaim.' + $hash) -Action {
            $value = Read-NotificationClaim -Path $path
            if ($null -eq $value) { return }
            $value.state = $State
            $updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
            if ($null -ne $value.PSObject.Properties['updatedAt']) { $value.updatedAt = $updatedAt } else { $value | Add-Member -NotePropertyName updatedAt -NotePropertyValue $updatedAt }
            if ($State -eq 'shown') {
                $shownAt = [DateTimeOffset]::UtcNow.ToString('o')
                if ($null -ne $value.PSObject.Properties['shownAt']) { $value.shownAt = $shownAt } else { $value | Add-Member -NotePropertyName shownAt -NotePropertyValue $shownAt }
            }
            if (-not [string]::IsNullOrWhiteSpace($Result)) {
                if ($null -ne $value.PSObject.Properties['result']) { $value.result = $Result } else { $value | Add-Member -NotePropertyName result -NotePropertyValue $Result }
            }
            Write-NotificationJsonAtomic -Path $path -Value $value
        } | Out-Null
        $script:NotificationClaimState = $State
    } catch {}
}

function ConvertTo-XmlText([string]$Text) { return [Security.SecurityElement]::Escape($Text) }

function ConvertTo-ToastVisualXml([string]$Title, [string]$Message) {
    $titleXml = '<text hint-style="title" hint-maxLines="1">' + (ConvertTo-XmlText $Title) + '</text>'
    $lines = @($Message -split '\r?\n')
    $expectedRows = @(
        ,@('Session', 'Model')
        ,@('Input', 'Output')
        ,@('Cache read', 'Cache write')
        ,@('Total', 'Cache hit rate')
        ,@('Cost', 'Estimated usage')
    )

    if ($lines.Count -eq $expectedRows.Count) {
        $rowsXml = [Text.StringBuilder]::new()
        $isTokenUsageLayout = $true
        for ($index = 0; $index -lt $expectedRows.Count; $index++) {
            $leftLabel = [regex]::Escape($expectedRows[$index][0])
            $rightLabel = [regex]::Escape($expectedRows[$index][1])
            $pattern = '^\s*' + $leftLabel + '\s+(?<leftValue>.+?)\s+\|\s+' + $rightLabel + '\s+(?<rightValue>.+?)\s*$'
            $match = [regex]::Match($lines[$index], $pattern)
            if (-not $match.Success) {
                $isTokenUsageLayout = $false
                break
            }

            $left = $expectedRows[$index][0] + ' ' + $match.Groups['leftValue'].Value.Trim()
            $right = $expectedRows[$index][1] + ' ' + $match.Groups['rightValue'].Value.Trim()
            [void]$rowsXml.Append('<group><subgroup hint-weight="1"><text hint-style="body" hint-align="left" hint-maxLines="1">')
            [void]$rowsXml.Append((ConvertTo-XmlText $left))
            [void]$rowsXml.Append('</text></subgroup><subgroup hint-weight="1"><text hint-style="body" hint-align="left" hint-maxLines="1">')
            [void]$rowsXml.Append((ConvertTo-XmlText $right))
            [void]$rowsXml.Append('</text></subgroup></group>')
        }

        if ($isTokenUsageLayout) { return $titleXml + $rowsXml.ToString() }
    }

    return $titleXml + '<text hint-style="body" hint-maxLines="4">' + (ConvertTo-XmlText $Message) + '</text>'
}

function Get-ToastTag($InputObject, [string]$NotificationType) {
    $sessionId = if ([string]::IsNullOrWhiteSpace([string]$InputObject.session_id)) { 'unknown-session' } else { [string]$InputObject.session_id }
    $turnId = if ([string]::IsNullOrWhiteSpace([string]$InputObject.turn_id)) { 'unknown-turn' } else { [string]$InputObject.turn_id }
    $key = "$sessionId|$turnId|$NotificationType"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-', '').ToLowerInvariant()
        return $hash.Substring(0, 16)
    }
    finally { $sha.Dispose() }
}

function Get-ActiveToastPath {
    return Join-Path (Get-NotificationRoot) 'active-toast.json'
}

function Get-ActiveToast {
    $path = Get-ActiveToastPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$value.tag) -or [string]::IsNullOrWhiteSpace([string]$value.group) -or [string]::IsNullOrWhiteSpace([string]$value.appId) -or [string]::IsNullOrWhiteSpace([string]$value.shownAt)) {
            return $null
        }
        return $value
    }
    catch { return $null }
}

function Save-ActiveToast([string]$Tag, [string]$Group, [string]$AppId) {
    try {
        $root = Get-NotificationRoot
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $value = [ordered]@{
            tag = $Tag
            group = $Group
            appId = $AppId
            shownAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $path = Get-ActiveToastPath
        $temporaryPath = Join-Path $root ('.active-toast-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($temporaryPath, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $temporaryPath -Destination $path -Force
        } finally {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        }
        return $true
    } catch { return $false }
}

function Invoke-WithNamedMutex([string]$Name, [scriptblock]$Action, [int]$TimeoutMilliseconds = 5000) {
    $mutex = $null
    $lockHeld = $false
    try {
        $mutex = [Threading.Mutex]::new($false, $Name)
        try { $lockHeld = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [Threading.AbandonedMutexException] { $lockHeld = $true }
        if (-not $lockHeld) { throw "Unable to acquire notification mutex: $Name" }
        return & $Action
    } finally {
        if ($lockHeld -and $null -ne $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Invoke-WithToastStateLock([scriptblock]$Action) {
    return Invoke-WithNamedMutex -Name $script:ToastStateMutexName -Action $Action -TimeoutMilliseconds 2000
}

function Get-ToastRemainingSeconds($Toast, [int]$MaximumSeconds) {
    if ($null -eq $Toast) { return $MaximumSeconds }
    try {
        $shownAt = [DateTimeOffset]::Parse([string]$Toast.shownAt).ToUniversalTime()
        $ageSeconds = ([DateTimeOffset]::UtcNow - $shownAt).TotalSeconds
        return [int][Math]::Max(0, [Math]::Ceiling($MaximumSeconds - $ageSeconds))
    } catch { return $MaximumSeconds }
}

function ConvertTo-PowerShellLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-ProcessArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value.Replace('\\', '\\\\').Replace('"', '\\"')
    return '"' + $escaped + '"'
}

function Set-ProcessArguments($StartInfo, [string[]]$Arguments) {
    $argumentListProperty = $StartInfo.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentListProperty) {
        foreach ($argument in $Arguments) { [void]$StartInfo.ArgumentList.Add($argument) }
    } else {
        $StartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
    }
}

function Start-DetachedPowerShell([string[]]$Arguments, [switch]$Wait) {
    $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $powershell) { throw 'Windows PowerShell 5.1 is required for Windows Toast notifications.' }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powershell.Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    Set-ProcessArguments -StartInfo $startInfo -Arguments $Arguments
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.Close()
        if (-not $Wait) { return [pscustomobject]@{ Started = $true; ExitCode = $null; StandardOutput = ''; StandardError = '' } }
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill() } catch {}
            throw 'Windows Toast host timed out.'
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        return [pscustomobject]@{ Started = $true; ExitCode = $process.ExitCode; StandardOutput = $stdout; StandardError = $stderr }
    } finally { $process.Dispose() }
}

function Start-ToastCleanup([string]$Tag, [string]$Group, [string]$AppId, [int]$DelaySeconds = 60) {
    try {
        $DelaySeconds = [Math]::Max(0, $DelaySeconds)
        $tagLiteral = ConvertTo-PowerShellLiteral $Tag
        $groupLiteral = ConvertTo-PowerShellLiteral $Group
        $appIdLiteral = ConvertTo-PowerShellLiteral $AppId
        $cleanupCommand = @"
Start-Sleep -Seconds $DelaySeconds
try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    try {
        [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($tagLiteral, $groupLiteral, $appIdLiteral)
    } catch {
        try { [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($tagLiteral, $groupLiteral) } catch {}
    }
} catch {}
"@
        [void](Start-DetachedPowerShell -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $cleanupCommand))
        return $true
    } catch { return $false }
}

function New-NativeToast([string]$Title, [string]$Message, [string]$NotificationType, [bool]$Sound, [string]$Tag, [string]$Group, [bool]$Urgent) {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $audio = if (-not $Sound) { '<audio silent="true" />' } elseif ($NotificationType -eq 'PermissionRequired') { '<audio src="ms-winsoundevent:Notification.Reminder" />' } elseif ($NotificationType -eq 'QuestionRequired') { '<audio src="ms-winsoundevent:Notification.IM" />' } else { '<audio src="ms-winsoundevent:Notification.Default" />' }
    $scenario = if ($Urgent) { ' scenario="urgent"' } else { '' }
    $visualXml = ConvertTo-ToastVisualXml -Title $Title -Message $Message
    $xml = '<toast duration="long"' + $scenario + '><visual><binding template="ToastGeneric">' + $visualXml + '</binding></visual>' + $audio + '</toast>'
    $document = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $document.LoadXml($xml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($document)
    try { $toast.Tag = $Tag } catch {}
    try { $toast.Group = $Group } catch {}
    try { $toast.Priority = [Windows.UI.Notifications.ToastNotificationPriority]::High } catch {}
    try { $toast.ExpirationTime = [DateTimeOffset]::UtcNow.AddSeconds($script:ToastLifetimeSeconds) } catch {}
    return $toast
}

function Show-NativeToastCore([string]$Title, [string]$Message, [string]$NotificationType, [bool]$Sound, [string]$Tag) {
    $appId = $script:ToastAppId
    $group = $script:ToastGroup
    return Invoke-WithToastStateLock {
        $previousToast = Get-ActiveToast
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
        $toastShown = $false
        try {
            $toast = New-NativeToast -Title $Title -Message $Message -NotificationType $NotificationType -Sound $Sound -Tag $Tag -Group $group -Urgent $true
            $notifier.Show($toast)
            $toastShown = $true
            $script:NativeToastShown = $true
        } catch {
            $toast = New-NativeToast -Title $Title -Message $Message -NotificationType $NotificationType -Sound $Sound -Tag $Tag -Group $group -Urgent $false
            $notifier.Show($toast)
            $toastShown = $true
            $script:NativeToastShown = $true
        }
        if (-not $toastShown) { throw 'Windows Toast was not shown.' }
        $cleanupScheduled = $false
        try { [void](Save-ActiveToast -Tag $Tag -Group $group -AppId $appId) } catch {}
        if ($null -ne $previousToast -and [string]$previousToast.tag -ne $Tag) {
            $remainingSeconds = Get-ToastRemainingSeconds -Toast $previousToast -MaximumSeconds $script:PreviousToastLifetimeSeconds
            try { if (Start-ToastCleanup -Tag ([string]$previousToast.tag) -Group ([string]$previousToast.group) -AppId ([string]$previousToast.appId) -DelaySeconds $remainingSeconds) { $cleanupScheduled = $true } } catch {}
        }
        try { if (Start-ToastCleanup -Tag $Tag -Group $group -AppId $appId -DelaySeconds $script:ToastLifetimeSeconds) { $cleanupScheduled = $true } } catch {}
        return [pscustomobject]@{ Shown = $true; CleanupScheduled = $cleanupScheduled }
    }
}

function Invoke-WindowsPowerShellToast([string]$Title, [string]$Message, [string]$NotificationType, [bool]$Sound, [string]$Tag) {
    $arguments = @(
        '-NoLogo'
        '-NoProfile'
        '-NonInteractive'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $PSCommandPath
        '-NativeToast'
        '-NativeTitle'
        $Title
        '-NativeMessage'
        $Message
        '-NativeNotificationType'
        $NotificationType
        '-NativeTag'
        $Tag
    )
    if ($Sound) { $arguments += '-NativeSound' }
    $execution = Start-DetachedPowerShell -Arguments $arguments -Wait
    $output = [string]$execution.StandardOutput
    $start = $output.IndexOf('{')
    $end = $output.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        try {
            $result = $output.Substring($start, $end - $start + 1) | ConvertFrom-Json -ErrorAction Stop
            if ([bool]$result.shown) { return [pscustomobject]@{ Shown = $true; CleanupScheduled = [bool]$result.cleanupScheduled; ChildExitCode = $execution.ExitCode } }
        } catch {}
    }
    throw "Windows Toast host failed: exit=$($execution.ExitCode) stdout=$output stderr=$($execution.StandardError)"
}

function Show-NativeToast([string]$Title, [string]$Message, [string]$NotificationType, [bool]$Sound, [string]$Tag) {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return Show-NativeToastCore -Title $Title -Message $Message -NotificationType $NotificationType -Sound $Sound -Tag $Tag
    } else {
        return Invoke-WindowsPowerShellToast -Title $Title -Message $Message -NotificationType $NotificationType -Sound $Sound -Tag $Tag
    }
}

function Show-BalloonFallback([string]$Title, [string]$Message, [string]$NotificationType, [bool]$Sound) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $icon = [Windows.Forms.NotifyIcon]::new()
    try {
        $icon.Icon = [Drawing.SystemIcons]::Information
        $icon.Visible = $true
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Message
        $icon.BalloonTipIcon = if ($NotificationType -eq 'PermissionRequired') { [Windows.Forms.ToolTipIcon]::Warning } elseif ($NotificationType -eq 'Error') { [Windows.Forms.ToolTipIcon]::Error } else { [Windows.Forms.ToolTipIcon]::Info }
        $icon.ShowBalloonTip(5000)
        if ($Sound) { [Console]::Beep(880, 120) }
        Start-Sleep -Milliseconds 800
    } finally { $icon.Dispose() }
    return [pscustomobject]@{ Shown = $true; CleanupScheduled = $false }
}

function Invoke-CcSessionsJson([string]$SessionId) {
    $lastError = $null
    $retryDelays = @(150, 250, 400, 650, 900, 1200)
    for ($attempt = 0; $attempt -le $retryDelays.Count; $attempt++) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND)) {
                $output = & pwsh -NoLogo -NoProfile -File $env:CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND -SessionId $SessionId 2>&1
            } else {
                foreach ($profilePath in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique) {
                    if (Test-Path -LiteralPath $profilePath -PathType Leaf) { . $profilePath *> $null }
                    if (Get-Command ccsessions -ErrorAction SilentlyContinue) { break }
                }
                if (-not (Get-Command ccsessions -ErrorAction SilentlyContinue)) { throw 'ccsessions not found' }
                $output = & ccsessions -Json $SessionId 2>&1
            }
            $text = ($output | Out-String).Trim()
            $start = $text.IndexOf('{')
            $end = $text.LastIndexOf('}')
            if ($start -lt 0 -or $end -le $start) { throw 'ccsessions returned invalid JSON' }
            $result = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json -ErrorAction Stop
            if ($result -is [array]) { $result = @($result | Where-Object { [string]$_.sessionId -eq $SessionId })[0] }
            if ($null -eq $result -or -not [bool]$result.success) { throw $(if ($result.error) { [string]$result.error } else { 'ccsessions returned no matching session' }) }
            if ([string]$result.sessionId -ne $SessionId) { throw 'ccsessions returned a different session' }
            return [pscustomobject]@{ Data = $result; RetryCount = $attempt }
        } catch {
            $lastError = $_
            try { $lastError.Exception.Data['ccsessionsRetryCount'] = $attempt } catch {}
            if ($_.Exception.Message -match 'ccsessions not found' -or $attempt -ge $retryDelays.Count) { throw }
            Start-Sleep -Milliseconds $retryDelays[$attempt]
        }
    }
    throw $lastError
}

function Get-RealtimeUsage($InputObject) {
    $directUsage = Get-UsageValue -Usage $InputObject -Names @('last_token_usage') -Default $null
    if ($null -ne $directUsage) { return $directUsage }

    $transcriptPath = [string](Get-UsageValue -Usage $InputObject -Names @('transcript_path') -Default '')
    if ([string]::IsNullOrWhiteSpace($transcriptPath) -or -not (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) { return $null }
    try {
        $event = Get-Content -LiteralPath $transcriptPath -Tail 512 | ForEach-Object {
            try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        } | Where-Object {
            $_.type -eq 'event_msg' -and $_.payload.type -eq 'token_count' -and $null -ne $_.payload.info.last_token_usage
        } | Select-Object -Last 1
        if ($null -ne $event) { return $event.payload.info.last_token_usage }
    } catch {}
    return $null
}

function ConvertTo-ModelNames($Value) {
    if ($null -eq $Value) { return @() }
    $values = if ($Value -is [string]) { @($Value) } else { @($Value) }
    return @($values | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ModelNamesFromUsage($Usage) {
    foreach ($name in @('models', 'model', 'model_name', 'modelName')) {
        $field = Get-UsageField -Usage $Usage -Names @($name)
        if ($field.Present) {
            $models = @(ConvertTo-ModelNames $field.Value)
            if ($models.Count -gt 0) { return $models }
        }
    }
    return @()
}

function Get-ModelNamesFromInput($InputObject) {
    $models = @(Get-ModelNamesFromUsage -Usage $InputObject)
    if ($models.Count -gt 0) { return [pscustomobject]@{ Names = $models; Source = 'input' } }

    $directUsage = Get-UsageValue -Usage $InputObject -Names @('last_token_usage') -Default $null
    $models = @(Get-ModelNamesFromUsage -Usage $directUsage)
    if ($models.Count -gt 0) { return [pscustomobject]@{ Names = $models; Source = 'payload' } }

    $transcriptPath = [string](Get-UsageValue -Usage $InputObject -Names @('transcript_path') -Default '')
    if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) {
        try {
            $event = Get-Content -LiteralPath $transcriptPath -Tail 512 | ForEach-Object {
                try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null }
            } | Where-Object {
                $_.type -eq 'event_msg' -and $_.payload.type -eq 'token_count'
            } | Select-Object -Last 1
            if ($null -ne $event) {
                $models = @(Get-ModelNamesFromUsage -Usage $event.payload.info)
                if ($models.Count -eq 0) { $models = @(Get-ModelNamesFromUsage -Usage $event.payload) }
                if ($models.Count -gt 0) { return [pscustomobject]@{ Names = $models; Source = 'transcript' } }
            }
        } catch {}
    }
    return [pscustomobject]@{ Names = @(); Source = 'N/A' }
}

function ConvertTo-Snapshot($Usage, [string]$SessionId, [string]$Source = 'ccsessions') {
    $models = @(Get-ModelNamesFromUsage -Usage $Usage)
    $inputField = Get-UsageField -Usage $Usage -Names @('inputTokens', 'input_tokens')
    $cachedInputField = Get-UsageField -Usage $Usage -Names @('cachedInputTokens', 'cached_input_tokens')
    $cacheWriteField = Get-UsageField -Usage $Usage -Names @('cacheWriteTokens', 'cache_write_input_tokens')
    $outputField = Get-UsageField -Usage $Usage -Names @('outputTokens', 'output_tokens')
    $totalField = Get-UsageField -Usage $Usage -Names @('totalTokens', 'total_tokens')
    $costField = Get-UsageField -Usage $Usage -Names @('costUsd', 'cost_usd')
    return [pscustomobject][ordered]@{
        sessionId = $SessionId
        source = $Source
        models = $models
        hasModel = $models.Count -gt 0
        inputTokens = if ($inputField.Present) { [long]$inputField.Value } else { [long]0 }
        hasInputTokens = [bool]$inputField.Present
        cachedInputTokens = if ($cachedInputField.Present) { [long]$cachedInputField.Value } else { [long]0 }
        hasCachedInputTokens = [bool]$cachedInputField.Present
        cacheWriteTokens = if ($cacheWriteField.Present) { [long]$cacheWriteField.Value } else { [long]0 }
        hasCacheWriteTokens = [bool]$cacheWriteField.Present
        outputTokens = if ($outputField.Present) { [long]$outputField.Value } else { [long]0 }
        hasOutputTokens = [bool]$outputField.Present
        totalTokens = if ($totalField.Present) { [long]$totalField.Value } else { [long]0 }
        hasTotalTokens = [bool]$totalField.Present
        hasCost = [bool]$costField.Present
        costUsd = if ($costField.Present) { [decimal]$costField.Value } else { [decimal]0 }
    }
}

function Get-SnapshotHash($Snapshot) {
    $json = $Snapshot | ConvertTo-Json -Depth 6 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-SessionStatePath([string]$Root, [string]$SessionId) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $name = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($SessionId)))).Replace('-', '').ToLowerInvariant() + '.json' }
    finally { $sha.Dispose() }
    return Join-Path $Root $name
}

function Read-PreviousState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $backup = "$Path.corrupt-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
        Move-Item -LiteralPath $Path -Destination $backup -Force
        return $null
    }
}

function ConvertTo-StateSnapshot($Snapshot) {
    return [ordered]@{
        sessionId = $Snapshot.sessionId
        source = $Snapshot.source
        models = @($Snapshot.models)
        hasModel = [bool]$Snapshot.hasModel
        inputTokens = $Snapshot.inputTokens
        hasInputTokens = [bool]$Snapshot.hasInputTokens
        cachedInputTokens = $Snapshot.cachedInputTokens
        hasCachedInputTokens = [bool]$Snapshot.hasCachedInputTokens
        cacheWriteTokens = $Snapshot.cacheWriteTokens
        hasCacheWriteTokens = [bool]$Snapshot.hasCacheWriteTokens
        outputTokens = $Snapshot.outputTokens
        hasOutputTokens = [bool]$Snapshot.hasOutputTokens
        totalTokens = $Snapshot.totalTokens
        hasTotalTokens = [bool]$Snapshot.hasTotalTokens
        hasCost = [bool]$Snapshot.hasCost
        costUsd = $Snapshot.costUsd
    }
}

function ConvertTo-BaselineSnapshot($Usage, [string]$SessionId) {
    $snapshot = ConvertTo-Snapshot -Usage $Usage -SessionId $SessionId -Source 'ccsessions'
    foreach ($property in @('hasModel', 'hasInputTokens', 'hasCachedInputTokens', 'hasCacheWriteTokens', 'hasOutputTokens', 'hasTotalTokens', 'hasCost')) {
        if ($Usage.PSObject.Properties.Name -contains $property) { $snapshot.$property = [bool]$Usage.$property }
    }
    return $snapshot
}

function Get-CcSessionsBaseline($State, [string]$SessionId) {
    if ($null -eq $State) { return $null }
    if ($State.PSObject.Properties.Name -contains 'ccsessionsBaseline' -and $null -ne $State.ccsessionsBaseline) {
        return ConvertTo-BaselineSnapshot -Usage $State.ccsessionsBaseline -SessionId $SessionId
    }
    if ([string]$State.source -eq 'ccsessions') {
        return ConvertTo-BaselineSnapshot -Usage $State -SessionId $SessionId
    }
    return $null
}

function Get-LastKnownModel($State) {
    if ($null -eq $State) { return '' }
    $lastKnownModel = [string]$State.lastKnownModel
    if (-not [string]::IsNullOrWhiteSpace($lastKnownModel)) { return $lastKnownModel }
    $models = @(ConvertTo-ModelNames $State.models)
    if ($models.Count -gt 0) { return [string]$models[0] }
    return ''
}

function Test-SnapshotHasCoreUsage($Snapshot) {
    if ($null -eq $Snapshot) { return $false }
    return [bool]$Snapshot.hasInputTokens -and [bool]$Snapshot.hasCachedInputTokens -and [bool]$Snapshot.hasOutputTokens -and [bool]$Snapshot.hasTotalTokens
}

function Test-SnapshotCanSubtract($Current, $Previous) {
    if ($null -eq $Current -or $null -eq $Previous) { return $false }
    $comparable = $false
    foreach ($property in @('inputTokens', 'cachedInputTokens', 'cacheWriteTokens', 'outputTokens', 'totalTokens')) {
        $hasProperty = 'has' + $property.Substring(0, 1).ToUpperInvariant() + $property.Substring(1)
        if ([bool]$Current.$hasProperty -and [bool]$Previous.$hasProperty) {
            if ([decimal]$Current.$property -lt [decimal]$Previous.$property) { return $false }
            $comparable = $true
        }
    }
    if ([bool]$Current.hasCost -and [bool]$Previous.hasCost -and [decimal]$Current.costUsd -lt [decimal]$Previous.costUsd) { return $false }
    return $comparable
}

function Test-SnapshotChanged($Current, $Previous) {
    if ($null -eq $Previous) { return $true }
    foreach ($property in @('inputTokens', 'cachedInputTokens', 'cacheWriteTokens', 'outputTokens', 'totalTokens')) {
        $hasProperty = 'has' + $property.Substring(0, 1).ToUpperInvariant() + $property.Substring(1)
        if ([bool]$Current.$hasProperty -ne [bool]$Previous.$hasProperty) { return $true }
        if ([bool]$Current.$hasProperty -and [decimal]$Current.$property -ne [decimal]$Previous.$property) { return $true }
    }
    if ([bool]$Current.hasCost -ne [bool]$Previous.hasCost) { return $true }
    if ([bool]$Current.hasCost -and [bool]$Previous.hasCost -and [decimal]$Current.costUsd -ne [decimal]$Previous.costUsd) { return $true }
    $currentModel = [string](@($Current.models)[0])
    $previousModel = [string](@($Previous.models)[0])
    return $currentModel -ne $previousModel
}

function New-SnapshotDelta($Current, $Previous, [string]$ModelFallback) {
    $models = if ([bool]$Current.hasModel -and @($Current.models).Count -gt 0) { @($Current.models) } elseif (-not [string]::IsNullOrWhiteSpace($ModelFallback)) { @($ModelFallback) } else { @() }
    $value = [ordered]@{
        sessionId = $Current.sessionId
        source = 'ccsessions-delta'
        models = $models
        hasModel = $models.Count -gt 0
    }
    foreach ($property in @('inputTokens', 'cachedInputTokens', 'cacheWriteTokens', 'outputTokens', 'totalTokens')) {
        $hasProperty = 'has' + $property.Substring(0, 1).ToUpperInvariant() + $property.Substring(1)
        $hasDelta = [bool]$Current.$hasProperty -and [bool]$Previous.$hasProperty
        $value[$property] = if ($hasDelta) { [long]$Current.$property - [long]$Previous.$property } else { [long]0 }
        $value[$hasProperty] = $hasDelta
    }
    $hasCostDelta = [bool]$Current.hasCost -and [bool]$Previous.hasCost
    $value.hasCost = $hasCostDelta
    $value.costUsd = if ($hasCostDelta) { [decimal]$Current.costUsd - [decimal]$Previous.costUsd } else { [decimal]0 }
    return [pscustomobject]$value
}

function New-DisplaySnapshot($TokenSnapshot, $MetadataSnapshot, [string]$ModelFallback, [bool]$UseMetadataCost, [string]$Source) {
    $value = [ordered]@{
        sessionId = $TokenSnapshot.sessionId
        source = $Source
    }
    $models = if ($null -ne $MetadataSnapshot -and @($MetadataSnapshot.models).Count -gt 0) { @($MetadataSnapshot.models) } elseif (@($TokenSnapshot.models).Count -gt 0) { @($TokenSnapshot.models) } elseif (-not [string]::IsNullOrWhiteSpace($ModelFallback)) { @($ModelFallback) } else { @() }
    $value.models = $models
    $value.hasModel = $models.Count -gt 0
    $fieldMap = [ordered]@{
        inputTokens = 'hasInputTokens'
        cachedInputTokens = 'hasCachedInputTokens'
        cacheWriteTokens = 'hasCacheWriteTokens'
        outputTokens = 'hasOutputTokens'
        totalTokens = 'hasTotalTokens'
    }
    foreach ($property in $fieldMap.Keys) {
        $hasProperty = $fieldMap[$property]
        $hasTokenValue = [bool]$TokenSnapshot.$hasProperty
        $value[$property] = if ($hasTokenValue) { $TokenSnapshot.$property } else { [long]0 }
        $value[$hasProperty] = $hasTokenValue
    }
    $hasMetadataCost = $null -ne $MetadataSnapshot -and [bool]$MetadataSnapshot.hasCost
    $useMetadataCostValue = $UseMetadataCost -and $hasMetadataCost
    $value.hasCost = if ($useMetadataCostValue) { $true } else { [bool]$TokenSnapshot.hasCost }
    $value.costUsd = if ($useMetadataCostValue) { [decimal]$MetadataSnapshot.costUsd } elseif ([bool]$TokenSnapshot.hasCost) { [decimal]$TokenSnapshot.costUsd } else { [decimal]0 }
    return [pscustomobject]$value
}

function Get-MissingSnapshotFields($Snapshot) {
    if ($null -eq $Snapshot) { return @('snapshot') }
    $missing = @()
    $fields = [ordered]@{
        inputTokens = 'hasInputTokens'
        cachedInputTokens = 'hasCachedInputTokens'
        cacheWriteTokens = 'hasCacheWriteTokens'
        outputTokens = 'hasOutputTokens'
        totalTokens = 'hasTotalTokens'
        costUsd = 'hasCost'
        model = 'hasModel'
    }
    foreach ($field in $fields.Keys) {
        if (-not [bool]$Snapshot.($fields[$field])) { $missing += $field }
    }
    return $missing
}

function Save-State([string]$Path, $Snapshot, [string]$Hash, [string]$TurnId, [string]$RealtimeHash, $Baseline, [string]$LastKnownModel) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $value = [ordered]@{
        sessionId = $Snapshot.sessionId
        source = $Snapshot.source
        models = @($Snapshot.models)
        hasModel = $Snapshot.hasModel
        inputTokens = $Snapshot.inputTokens
        hasInputTokens = $Snapshot.hasInputTokens
        cachedInputTokens = $Snapshot.cachedInputTokens
        hasCachedInputTokens = $Snapshot.hasCachedInputTokens
        cacheWriteTokens = $Snapshot.cacheWriteTokens
        hasCacheWriteTokens = $Snapshot.hasCacheWriteTokens
        outputTokens = $Snapshot.outputTokens
        hasOutputTokens = $Snapshot.hasOutputTokens
        totalTokens = $Snapshot.totalTokens
        hasTotalTokens = $Snapshot.hasTotalTokens
        hasCost = $Snapshot.hasCost
        costUsd = $Snapshot.costUsd
        snapshotHash = $Hash
        turnId = $TurnId
        lastDisplayedTurnId = $TurnId
        lastDisplayedRealtimeHash = $RealtimeHash
        lastDisplayedSnapshotHash = $Hash
        ccsessionsBaseline = if ($null -ne $Baseline) { ConvertTo-StateSnapshot -Snapshot $Baseline } else { $null }
        lastKnownModel = $LastKnownModel
        updatedAt = [DateTimeOffset]::Now.ToString('o')
    }
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporaryPath, (($value | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Format-TokenCount([long]$Value, [bool]$Delta) {
    $prefix = if ($Delta) { '+' } else { '' }
    $units = @(
        [pscustomobject]@{ Limit = 1000000000; Divisor = 1000000000; Suffix = 'B' },
        [pscustomobject]@{ Limit = 1000000; Divisor = 1000000; Suffix = 'M' },
        [pscustomobject]@{ Limit = 1000; Divisor = 1000; Suffix = 'K' }
    )
    foreach ($unit in $units) {
        if ([Math]::Abs($Value) -lt $unit.Limit) { continue }
        $scaled = [double]$Value / $unit.Divisor
        $decimals = if ([Math]::Abs($scaled) -ge 100) { 0 } elseif ([Math]::Abs($scaled) -ge 10) { 1 } else { 2 }
        $text = $scaled.ToString("F$decimals", [Globalization.CultureInfo]::InvariantCulture)
        if ($decimals -gt 0) { $text = $text.TrimEnd('0').TrimEnd('.') }
        return $prefix + $text + $unit.Suffix
    }
    return $prefix + $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Format-SnapshotToken($Snapshot, [string]$Property, [string]$HasProperty, [bool]$Delta) {
    if ($null -eq $Snapshot -or -not [bool]$Snapshot.$HasProperty) { return 'N/A' }
    return Format-TokenCount -Value ([long]$Snapshot.$Property) -Delta $Delta
}

function Format-Cost([decimal]$Value, [bool]$Delta) {
    $prefix = if ($Delta) { '+' } else { '' }
    $text = $Value.ToString('0.0000', [Globalization.CultureInfo]::InvariantCulture).TrimEnd('0').TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($text)) { $text = '0' }
    return $prefix + '$' + $text
}

function Format-SessionId([string]$SessionId) {
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return 'N/A' }
    if ($SessionId.Length -le 6) { return $SessionId }
    return $SessionId.Substring($SessionId.Length - 6)
}

function Format-Percentage([decimal]$Value) {
    return $Value.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) + '%'
}

function Get-TokenUsageDisplayCore($InputObject, $Settings) {
    $sessionId = [string]$InputObject.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'session ID could not be resolved' }
    if ([bool]$InputObject.stop_hook_active) { return [pscustomobject]@{ Skipped = $true } }

    $root = Get-TokenUsageRoot
    $statePath = Get-SessionStatePath -Root $root -SessionId $sessionId
    $previous = Read-PreviousState -Path $statePath
    $realtimeUsage = Get-RealtimeUsage -InputObject $InputObject
    $realtimeSnapshot = $null
    $realtimeHash = ''
    $realtimeModelSource = 'N/A'
    if ($null -ne $realtimeUsage) {
        $realtimeSnapshot = ConvertTo-Snapshot -Usage $realtimeUsage -SessionId $sessionId -Source 'realtime'
        $modelInfo = Get-ModelNamesFromInput -InputObject $InputObject
        if (-not [bool]$realtimeSnapshot.hasModel -and @($modelInfo.Names).Count -gt 0) {
            $realtimeSnapshot.models = @($modelInfo.Names)
            $realtimeSnapshot.hasModel = $true
            $realtimeModelSource = [string]$modelInfo.Source
        } elseif ([bool]$realtimeSnapshot.hasModel) {
            $realtimeModelSource = 'realtime'
        } elseif ($null -ne $previous -and -not [string]::IsNullOrWhiteSpace((Get-LastKnownModel -State $previous))) {
            $realtimeModelSource = 'lastKnownModel'
        }
        $realtimeHash = Get-SnapshotHash -Snapshot $realtimeSnapshot
        if ($null -ne $previous) {
            $previousTurnId = [string]$previous.lastDisplayedTurnId
            if ([string]::IsNullOrWhiteSpace($previousTurnId)) { $previousTurnId = [string]$previous.turnId }
            if ((-not [string]::IsNullOrWhiteSpace([string]$InputObject.turn_id) -and $previousTurnId -eq [string]$InputObject.turn_id) -or [string]$previous.lastDisplayedRealtimeHash -eq $realtimeHash -or ([string]$previous.source -eq 'realtime' -and [string]$previous.snapshotHash -eq $realtimeHash)) {
                return [pscustomobject]@{ Duplicate = $true; Source = 'realtime' }
            }
        }
    }

    $ccsessionsSnapshot = $null
    $ccsessionsRetryCount = 0
    $ccsessionsError = ''
    try {
        $ccsessionsResult = Invoke-CcSessionsJson -SessionId $sessionId
        $ccsessionsRetryCount = [int]$ccsessionsResult.RetryCount
        $ccsessionsSnapshot = ConvertTo-Snapshot -Usage $ccsessionsResult.Data -SessionId $sessionId -Source 'ccsessions'
    } catch {
        $ccsessionsError = $_.Exception.Message
        try {
            if ($_.Exception.Data.Contains('ccsessionsRetryCount')) { $ccsessionsRetryCount = [int]$_.Exception.Data['ccsessionsRetryCount'] }
        } catch {}
    }

    $baseline = Get-CcSessionsBaseline -State $previous -SessionId $sessionId
    $newBaseline = $baseline
    $display = $null
    $needsSubtraction = $false
    $showAsTurnDelta = $false
    $tokenSource = 'N/A'
    $modelSource = 'N/A'
    $costSource = 'N/A'
    $modelFallback = Get-LastKnownModel -State $previous
    if ($null -ne $realtimeSnapshot -and [bool]$realtimeSnapshot.hasModel) { $modelFallback = [string]@($realtimeSnapshot.models)[0] }

    if ($null -ne $ccsessionsSnapshot) {
        $ccsessionsHasCoreUsage = Test-SnapshotHasCoreUsage -Snapshot $ccsessionsSnapshot
        if ($ccsessionsHasCoreUsage) { $newBaseline = $ccsessionsSnapshot }
        $ccsessionsChanged = $null -eq $baseline -or (Test-SnapshotChanged -Current $ccsessionsSnapshot -Previous $baseline)
        $canSubtract = Test-SnapshotCanSubtract -Current $ccsessionsSnapshot -Previous $baseline

        if ($null -ne $baseline -and $ccsessionsChanged -and $canSubtract) {
            $needsSubtraction = $true
            $showAsTurnDelta = $true
            $tokenSource = 'ccsessions-delta'
            $modelSource = if ([bool]$ccsessionsSnapshot.hasModel) { 'ccsessions' } else { $realtimeModelSource }
            $costSource = 'N/A'
        } elseif ($null -eq $baseline) {
            if ($null -ne $realtimeSnapshot) {
                $display = New-DisplaySnapshot -TokenSnapshot $realtimeSnapshot -MetadataSnapshot $ccsessionsSnapshot -ModelFallback $modelFallback -UseMetadataCost $true -Source 'realtime+ccsessions'
                $showAsTurnDelta = $true
                $tokenSource = 'realtime'
                $modelSource = if ([bool]$ccsessionsSnapshot.hasModel) { 'ccsessions' } elseif ([bool]$realtimeSnapshot.hasModel) { $realtimeModelSource } else { 'N/A' }
                $costSource = if ([bool]$ccsessionsSnapshot.hasCost) { 'ccsessions' } elseif ([bool]$realtimeSnapshot.hasCost) { 'realtime' } else { 'N/A' }
            } else {
                $display = $ccsessionsSnapshot
                $modelSource = if ([bool]$display.hasModel) { 'ccsessions' } else { 'N/A' }
                $tokenSource = 'ccsessions'
                $costSource = if ([bool]$display.hasCost) { 'ccsessions' } else { 'N/A' }
            }
        } elseif (-not $ccsessionsChanged -and $null -ne $realtimeSnapshot) {
            $display = New-DisplaySnapshot -TokenSnapshot $realtimeSnapshot -MetadataSnapshot $null -ModelFallback $modelFallback -UseMetadataCost $false -Source 'realtime'
            $showAsTurnDelta = $true
            $tokenSource = 'realtime'
            $modelSource = if ([bool]$display.hasModel) { $realtimeModelSource } else { 'N/A' }
            $costSource = if ([bool]$realtimeSnapshot.hasCost) { 'realtime' } else { 'N/A' }
        } elseif (-not $ccsessionsChanged) {
            return [pscustomobject]@{ Duplicate = $true; Source = 'ccsessions' }
        } elseif ($null -ne $realtimeSnapshot) {
            $display = New-DisplaySnapshot -TokenSnapshot $realtimeSnapshot -MetadataSnapshot $null -ModelFallback $modelFallback -UseMetadataCost $false -Source 'realtime'
            $showAsTurnDelta = $true
            $tokenSource = 'realtime'
            $modelSource = if ([bool]$display.hasModel) { $realtimeModelSource } else { 'N/A' }
            $costSource = if ([bool]$realtimeSnapshot.hasCost) { 'realtime' } else { 'N/A' }
        } else {
            $display = $ccsessionsSnapshot
            $modelSource = if ([bool]$display.hasModel) { 'ccsessions' } else { 'N/A' }
            $tokenSource = 'ccsessions'
            $costSource = if ([bool]$display.hasCost) { 'ccsessions' } else { 'N/A' }
        }
    } elseif ($null -ne $realtimeSnapshot) {
        $display = New-DisplaySnapshot -TokenSnapshot $realtimeSnapshot -MetadataSnapshot $null -ModelFallback $modelFallback -UseMetadataCost $false -Source 'realtime'
        $showAsTurnDelta = $true
        $tokenSource = 'realtime'
        $modelSource = if ([bool]$display.hasModel) { $realtimeModelSource } else { 'N/A' }
        $costSource = if ([bool]$display.hasCost) { 'realtime' } else { 'N/A' }
    } else {
        if ([string]::IsNullOrWhiteSpace($ccsessionsError)) { $ccsessionsError = 'ccsessions returned no data' }
        $failure = [InvalidOperationException]::new($ccsessionsError)
        $failure.Data['realtimeAvailable'] = $false
        $failure.Data['ccsessionsAvailable'] = $false
        $failure.Data['ccsessionsRetryCount'] = $ccsessionsRetryCount
        $failure.Data['missingFields'] = 'inputTokens,cachedInputTokens,cacheWriteTokens,outputTokens,totalTokens,costUsd,model'
        $failure.Data['ccsessionsError'] = $ccsessionsError
        throw $failure
    }

    if ($needsSubtraction) {
        $display = New-SnapshotDelta -Current $ccsessionsSnapshot -Previous $baseline -ModelFallback $modelFallback
        $costSource = if ([bool]$display.hasCost) { 'ccsessions-delta' } else { 'N/A' }
    }
    if ($null -eq $display) { throw 'token usage display could not be assembled' }
    $displayHash = Get-SnapshotHash -Snapshot $display
    if ($null -ne $previous -and [string]$previous.lastDisplayedSnapshotHash -eq $displayHash) {
        return [pscustomobject]@{ Duplicate = $true; Source = $display.source }
    }
    if ($null -ne $previous -and [string]$previous.snapshotHash -eq $displayHash -and [string]$previous.source -eq [string]$display.source) {
        return [pscustomobject]@{ Duplicate = $true; Source = $display.source }
    }
    $lastKnownModel = if ([bool]$display.hasModel) { [string]@($display.models)[0] } else { Get-LastKnownModel -State $previous }
    Save-State -Path $statePath -Snapshot $display -Hash $displayHash -TurnId ([string]$InputObject.turn_id) -RealtimeHash $realtimeHash -Baseline $newBaseline -LastKnownModel $lastKnownModel

    $sessionText = if ([bool]$Settings.showSessionId) { Format-SessionId $sessionId } else { 'N/A' }
    $modelText = if ([bool]$Settings.showModel -and [bool]$display.hasModel) { [string]@($display.models)[0] } else { 'N/A' }
    $hasCacheRateFields = [bool]$display.hasInputTokens -and [bool]$display.hasCachedInputTokens -and [bool]$display.hasCacheWriteTokens
    $cacheTotal = if ($hasCacheRateFields) { [decimal]$display.cachedInputTokens + [decimal]$display.cacheWriteTokens + [decimal]$display.inputTokens } else { [decimal]0 }
    $cacheHitRate = if ($hasCacheRateFields -and $cacheTotal -gt 0) { Format-Percentage (([decimal]$display.cachedInputTokens / $cacheTotal) * 100) } else { 'N/A' }
    $costText = if ([bool]$Settings.showCost -and [bool]$display.hasCost) { Format-Cost $display.costUsd $showAsTurnDelta } else { 'N/A' }
    $estimatedText = if ([bool]$Settings.showCost -and [bool]$display.hasCost) { Format-Percentage (([decimal]$display.costUsd / [decimal]1.3) * 1) } else { 'N/A' }
    $lines = @(
        ('Session         {0}   | Model           {1}' -f $sessionText, $modelText)
        ('Input           {0}   | Output          {1}' -f (Format-SnapshotToken $display 'inputTokens' 'hasInputTokens' $showAsTurnDelta), (Format-SnapshotToken $display 'outputTokens' 'hasOutputTokens' $showAsTurnDelta))
        ('Cache read      {0}   | Cache write     {1}' -f (Format-SnapshotToken $display 'cachedInputTokens' 'hasCachedInputTokens' $showAsTurnDelta), (Format-SnapshotToken $display 'cacheWriteTokens' 'hasCacheWriteTokens' $showAsTurnDelta))
        ('Total           {0}   | Cache hit rate  {1}' -f (Format-SnapshotToken $display 'totalTokens' 'hasTotalTokens' $showAsTurnDelta), $cacheHitRate)
        ('Cost            {0}   | Estimated usage {1}' -f $costText, $estimatedText)
    )
    $missingFields = @(Get-MissingSnapshotFields -Snapshot $display)
    return [pscustomobject]@{
        Text = $lines -join [Environment]::NewLine
        Source = $display.source
        DisplayedDelta = $showAsTurnDelta
        RealtimeAvailable = $null -ne $realtimeSnapshot
        CcsessionsAvailable = $null -ne $ccsessionsSnapshot
        CcsessionsRetryCount = $ccsessionsRetryCount
        TokenSource = $tokenSource
        ModelSource = $modelSource
        CostSource = $costSource
        MissingFields = $missingFields
        CcsessionsError = $ccsessionsError
    }
}

function Get-TokenUsageDisplay($InputObject, $Settings) {
    $sessionId = [string]$InputObject.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { return Get-TokenUsageDisplayCore -InputObject $InputObject -Settings $Settings }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $sessionHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sessionId)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $mutexName = 'CodexSettings.TokenUsage.' + $sessionHash
    return Invoke-WithNamedMutex -Name $mutexName -Action { Get-TokenUsageDisplayCore -InputObject $InputObject -Settings $Settings }
}

if ($NativeToast) {
    try {
        $nativeResult = Show-NativeToastCore -Title $NativeTitle -Message $NativeMessage -NotificationType $NativeNotificationType -Sound ([bool]$NativeSound) -Tag $NativeTag
        [Console]::Out.Write(($nativeResult | ConvertTo-Json -Compress))
        exit 0
    } catch {
        [Console]::Error.WriteLine($_.Exception.ToString())
        exit 1
    }
}

$inputObject = $null
$notificationClaim = $null
try {
    if ($Test) {
        $inputObject = [pscustomobject]@{
            session_id = 'notification-test'
            turn_id = [guid]::NewGuid().ToString('N')
            hook_event_name = 'Stop'
            stop_hook_active = $false
            last_assistant_message = ''
        }
    } else {
        $inputObject = Get-HookInput
        if ($null -eq $inputObject) { $inputObject = [pscustomobject]@{} }
    }

    $script:HookSource = Get-HookSource
    $script:HookInvocationCounts = Get-HookInvocationCounts -InputObject $inputObject -Kind notification

    if ($Type -eq 'Completed' -and [string]$inputObject.last_assistant_message -match '(?s)(?:[?？]\s*$|請(?:選擇|確認|提供|回答))') {
        $Type = 'QuestionRequired'
    }
    $script:NotificationHandlerId = switch ($Type) {
        'Completed' { 'completed-token-toast' }
        'PermissionRequired' { 'permission-toast' }
        'QuestionRequired' { 'question-toast' }
        default { 'error-toast' }
    }
    $root = Get-NotificationRoot
    $settings = Get-NotificationSettings -Root $root
    $settingName = $Type.Substring(0, 1).ToLowerInvariant() + $Type.Substring(1)
    if (-not $Test -and (-not [bool]$settings.enabled -or -not [bool]$settings.$settingName)) {
        Write-HookDiagnostic -InputObject $inputObject -Result 'disabled' -Details ''
    } else {
        $notificationClaim = Acquire-NotificationClaim -Root $root -InputObject $inputObject -NotificationType $Type
        if (-not [bool]$notificationClaim.Acquired) {
            Write-HookDiagnostic -InputObject $inputObject -Result 'deduplicated' -Details ('claimState={0};claimAlreadyOwned=true' -f $notificationClaim.State)
        } else {
            $content = switch ($Type) {
                'PermissionRequired' { [pscustomobject]@{ Title = 'Codex 等待權限核准'; Message = '需要你的核准才能繼續執行' } }
                'QuestionRequired' { [pscustomobject]@{ Title = 'Codex 等待你的回答'; Message = '請回到 Codex 繼續' } }
                'Error' { [pscustomobject]@{ Title = 'Codex 執行失敗'; Message = '請查看錯誤內容' } }
                default { [pscustomobject]@{ Title = 'Codex 任務完成'; Message = '工作已完成' } }
            }
            $details = ''
            $skipNotification = $false
            if ($Type -eq 'Completed') {
                $tokenSettings = Get-TokenUsageSettings -Root (Get-TokenUsageRoot)
                if ([bool]$tokenSettings.enabled -and [bool]$tokenSettings.showAfterEachTurn) {
                    try {
                        $usage = Get-TokenUsageDisplay -InputObject $inputObject -Settings $tokenSettings
                        if ([bool]$usage.Duplicate) {
                            $skipNotification = $true
                            $details = 'tokenUsage=duplicate; source={0}' -f $usage.Source
                        } elseif (-not [bool]$usage.Skipped) {
                            $content.Message = $usage.Text
                            $realtimeAvailable = if ([bool]$usage.RealtimeAvailable) { 'true' } else { 'false' }
                            $ccsessionsAvailable = if ([bool]$usage.CcsessionsAvailable) { 'true' } else { 'false' }
                            $showAsTurnDelta = if ([bool]$usage.DisplayedDelta) { 'true' } else { 'false' }
                            $missingFields = (@($usage.MissingFields) | ForEach-Object { [string]$_ }) -join ','
                            $details = 'source={0};displayedDelta={1};realtimeAvailable={2};ccsessionsAvailable={3};ccsessionsRetryCount={4};tokenSource={5};modelSource={6};costSource={7};showAsTurnDelta={8};missingFields=[{9}]' -f $usage.Source, $showAsTurnDelta, $realtimeAvailable, $ccsessionsAvailable, $usage.CcsessionsRetryCount, $usage.TokenSource, $usage.ModelSource, $usage.CostSource, $showAsTurnDelta, $missingFields
                            if (-not [string]::IsNullOrWhiteSpace([string]$usage.CcsessionsError)) {
                                $safeError = [regex]::Replace([string]$usage.CcsessionsError, '[\r\n;]', ' ')
                                $details += ';ccsessionsError=' + $safeError
                            }
                        }
                    } catch {
                        $content.Message = 'Token 用量暫時無法取得'
                        $details = 'tokenUsageError={0}' -f $_.Exception.ToString()
                        try {
                            $errorData = $_.Exception.Data
                            if ($errorData.Contains('realtimeAvailable')) {
                                $realtimeAvailable = if ([bool]$errorData['realtimeAvailable']) { 'true' } else { 'false' }
                                $ccsessionsAvailable = if ([bool]$errorData['ccsessionsAvailable']) { 'true' } else { 'false' }
                                $missingFields = [string]$errorData['missingFields']
                                $safeError = [regex]::Replace([string]$errorData['ccsessionsError'], '[\r\n;]', ' ')
                                $details += ';realtimeAvailable=' + $realtimeAvailable + ';ccsessionsAvailable=' + $ccsessionsAvailable + ';ccsessionsRetryCount=' + [string]$errorData['ccsessionsRetryCount'] + ';missingFields=[' + $missingFields + '];ccsessionsError=' + $safeError
                            }
                        } catch {}
                    }
                }
            }

            if ($skipNotification) {
                Set-NotificationClaimState -Claim $notificationClaim -State skipped -Result 'token-usage-duplicate'
                Write-HookDiagnostic -InputObject $inputObject -Result 'deduplicated' -Details $details
            } else {
                $deliverySucceeded = $false
                $testMode = $env:CODEX_SETTINGS_NOTIFICATION_TEST_MODE -eq '1'
                if ($testMode) {
                    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_NOTIFICATION_TEST_LOG)) {
                        Add-Content -LiteralPath $env:CODEX_SETTINGS_NOTIFICATION_TEST_LOG -Value (@{ type = $Type; title = $content.Title; message = $content.Message } | ConvertTo-Json -Compress) -Encoding UTF8
                    }
                    $deliverySucceeded = $true
                } else {
                    $tag = Get-ToastTag -InputObject $inputObject -NotificationType $Type
                    $script:NativeToastAttempted = $true
                    try {
                        $nativeDelivery = Show-NativeToast -Title $content.Title -Message $content.Message -NotificationType $Type -Sound ([bool]$settings.sound) -Tag $tag
                        $script:NativeToastShown = $null -ne $nativeDelivery -and [bool]$nativeDelivery.Shown
                        $script:CleanupScheduled = $null -ne $nativeDelivery -and [bool]$nativeDelivery.CleanupScheduled
                        $deliverySucceeded = [bool]$script:NativeToastShown
                    } catch {
                        if (-not $script:NativeToastShown) {
                            $script:FallbackAttempted = $true
                            try {
                                $fallbackDelivery = Show-BalloonFallback -Title $content.Title -Message $content.Message -NotificationType $Type -Sound ([bool]$settings.sound)
                                $script:FallbackShown = $null -ne $fallbackDelivery -and [bool]$fallbackDelivery.Shown
                                $deliverySucceeded = [bool]$script:FallbackShown
                            } catch {
                                if ([bool]$settings.sound) { [Console]::Error.Write([char]7) }
                            }
                        }
                    }
                }
                if ($deliverySucceeded) {
                    Set-NotificationClaimState -Claim $notificationClaim -State shown -Result $(if ($testMode) { 'test' } elseif ($script:NativeToastShown) { 'native-toast' } else { 'balloon-fallback' })
                } else {
                    Set-NotificationClaimState -Claim $notificationClaim -State failed -Result 'no-notification-shown'
                }
                $deliveryDetails = 'claimState={0};nativeToastAttempted={1};nativeToastShown={2};fallbackAttempted={3};fallbackShown={4};cleanupScheduled={5}' -f $script:NotificationClaimState, $script:NativeToastAttempted, $script:NativeToastShown, $script:FallbackAttempted, $script:FallbackShown, $script:CleanupScheduled
                $details = if ([string]::IsNullOrWhiteSpace($details)) { $deliveryDetails } else { $details + ';' + $deliveryDetails }
                Write-HookDiagnostic -InputObject $inputObject -Result $(if ($deliverySucceeded) { 'success' } else { 'delivery-failed' }) -Details $details
            }
        }
    }
} catch {
    Write-HookDiagnostic -InputObject $inputObject -Result 'error' -Details $_.Exception.ToString()
}

Write-HookResult
