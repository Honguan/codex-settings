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
            [void]$rowsXml.Append('<group><subgroup><text hint-style="body" hint-maxLines="1">')
            [void]$rowsXml.Append((ConvertTo-XmlText $left))
            [void]$rowsXml.Append('</text></subgroup><subgroup><text hint-style="body" hint-align="right" hint-maxLines="1">')
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
    foreach ($attempt in 1..2) {
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
            return $result
        } catch {
            $lastError = $_
            if ($_.Exception.Message -match 'ccsessions not found' -or $attempt -eq 2) { throw }
            Start-Sleep -Milliseconds 250
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

function ConvertTo-Snapshot($Usage, [string]$SessionId, [string]$Source = 'ccsessions', $Previous = $null) {
    $isRealtime = $Source -eq 'realtime'
    $models = @((Get-UsageValue -Usage $Usage -Names @('models', 'model') -Default @()))
    if ($isRealtime -and $models.Count -eq 0 -and $null -ne $Previous) { $models = @($Previous.models) }
    $hasCost = -not $isRealtime -and (Test-UsageProperty -Usage $Usage -Names @('costUsd', 'cost_usd'))
    return [pscustomobject][ordered]@{
        sessionId = $SessionId
        source = $Source
        models = $models
        inputTokens = [long](Get-UsageValue -Usage $Usage -Names @('inputTokens', 'input_tokens'))
        cachedInputTokens = [long](Get-UsageValue -Usage $Usage -Names @('cachedInputTokens', 'cached_input_tokens'))
        cacheWriteTokens = [long](Get-UsageValue -Usage $Usage -Names @('cacheWriteTokens', 'cache_write_input_tokens'))
        outputTokens = [long](Get-UsageValue -Usage $Usage -Names @('outputTokens', 'output_tokens'))
        totalTokens = [long](Get-UsageValue -Usage $Usage -Names @('totalTokens', 'total_tokens'))
        hasCost = $hasCost
        costUsd = if ($hasCost) { [decimal](Get-UsageValue -Usage $Usage -Names @('costUsd', 'cost_usd')) } else { [decimal]0 }
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

function Save-State([string]$Path, $Snapshot, [string]$Hash, [string]$TurnId) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $value = [ordered]@{
        sessionId = $Snapshot.sessionId
        source = $Snapshot.source
        models = @($Snapshot.models)
        inputTokens = $Snapshot.inputTokens
        cachedInputTokens = $Snapshot.cachedInputTokens
        cacheWriteTokens = $Snapshot.cacheWriteTokens
        outputTokens = $Snapshot.outputTokens
        totalTokens = $Snapshot.totalTokens
        hasCost = $Snapshot.hasCost
        costUsd = $Snapshot.costUsd
        snapshotHash = $Hash
        turnId = $TurnId
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
    if ($null -ne $realtimeUsage) {
        $current = ConvertTo-Snapshot -Usage $realtimeUsage -SessionId $sessionId -Source 'realtime' -Previous $previous
    } else {
        $usage = Invoke-CcSessionsJson -SessionId $sessionId
        $current = ConvertTo-Snapshot -Usage $usage -SessionId $sessionId -Previous $previous
    }
    $hash = Get-SnapshotHash -Snapshot $current
    if ($null -ne $previous -and [string]$previous.snapshotHash -eq $hash) {
        return [pscustomobject]@{ Duplicate = $true; Source = $current.source }
    }

    $isRealtime = $current.source -eq 'realtime'
    $isDelta = $false
    if (-not $isRealtime -and $null -ne $previous -and [string]$previous.source -eq 'ccsessions' -and $previous.PSObject.Properties.Name -contains 'cacheWriteTokens') {
        if ([bool]$current.hasCost -eq [bool]$previous.hasCost) {
            $isDelta = $true
            foreach ($property in @('inputTokens', 'cachedInputTokens', 'cacheWriteTokens', 'outputTokens', 'totalTokens', 'costUsd')) {
                if ([decimal]$current.$property -lt [decimal]$previous.$property) { $isDelta = $false; break }
            }
        }
    }
    $shown = if ($isDelta) {
        [pscustomobject]@{
            inputTokens = [long]$current.inputTokens - [long]$previous.inputTokens
            cachedInputTokens = [long]$current.cachedInputTokens - [long]$previous.cachedInputTokens
            cacheWriteTokens = [long]$current.cacheWriteTokens - [long]$previous.cacheWriteTokens
            outputTokens = [long]$current.outputTokens - [long]$previous.outputTokens
            totalTokens = [long]$current.totalTokens - [long]$previous.totalTokens
            costUsd = [decimal]$current.costUsd - [decimal]$previous.costUsd
        }
    } else { $current }
    Save-State -Path $statePath -Snapshot $current -Hash $hash -TurnId ([string]$InputObject.turn_id)

    $sessionText = if ([bool]$Settings.showSessionId) { Format-SessionId $sessionId } else { 'N/A' }
    $modelText = if ([bool]$Settings.showModel -and @($current.models).Count -gt 0) { [string]@($current.models)[0] } else { 'N/A' }
    $cacheTotal = [decimal]$shown.cachedInputTokens + [decimal]$shown.cacheWriteTokens + [decimal]$shown.inputTokens
    $cacheHitRate = if ($cacheTotal -gt 0) { ([decimal]$shown.cachedInputTokens / $cacheTotal) * 100 } else { 0 }
    $costText = if ([bool]$Settings.showCost -and [bool]$current.hasCost) { Format-Cost $shown.costUsd $isDelta } else { 'N/A' }
    $estimatedText = if ([bool]$Settings.showCost -and [bool]$current.hasCost) { Format-Percentage (([decimal]$shown.costUsd / [decimal]1.3) * 1) } else { 'N/A' }
    $lines = @(
        ('Session         {0}   | Model           {1}' -f $sessionText, $modelText)
        ('Input           {0}   | Output          {1}' -f (Format-TokenCount $shown.inputTokens $isDelta), (Format-TokenCount $shown.outputTokens $isDelta))
        ('Cache read      {0}   | Cache write     {1}' -f (Format-TokenCount $shown.cachedInputTokens $isDelta), (Format-TokenCount $shown.cacheWriteTokens $isDelta))
        ('Total           {0}   | Cache hit rate  {1}' -f (Format-TokenCount $shown.totalTokens $isDelta), (Format-Percentage $cacheHitRate))
        ('Cost            {0}   | Estimated usage {1}' -f $costText, $estimatedText)
    )
    return [pscustomobject]@{
        Text = $lines -join [Environment]::NewLine
        Source = $current.source
        DisplayedDelta = $isDelta
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
                            $details = 'source={0}; displayedDelta={1}' -f $usage.Source, $usage.DisplayedDelta
                        }
                    } catch {
                        $content.Message = 'Token 用量暫時無法取得'
                        $details = 'tokenUsageError={0}' -f $_.Exception.ToString()
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
