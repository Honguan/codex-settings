[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$NotificationPayload,
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
$runtimeCorePath = Join-Path $PSScriptRoot 'runtime-core.ps1'
if (Test-Path -LiteralPath $runtimeCorePath -PathType Leaf) { . $runtimeCorePath }
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
$script:HookParentProcessId = $null
$script:HookTimings = [ordered]@{
    invocationCounterMs = 0
    diagnosticWriteMs = 0
}
$script:PayloadParsed = $false
$script:SettingsEnabled = $false
$script:MainSessionResult = 'Unknown'
$script:MainSessionEvidence = 'not-classified'
$script:DedupeResult = 'not-checked'
$script:NativeToastError = ''
$script:FallbackError = ''
$script:DeliveryResultReason = 'unexpected-error'
$script:CompletionClassification = 'NotApplicable'
$script:CompletionEvidence = 'not-applicable'
$script:CompactionDetected = $false
$script:ContinuationExpected = $false
$script:IsFinalTurn = $false
$script:ClaimAttempted = $false
$script:PayloadKeys = @()
$script:LifecyclePhase = ''
$script:Originator = ''
$script:InvocationClient = ''

function Add-HookTiming([string]$Name, [long]$Milliseconds) {
    if ($script:HookTimings.Contains($Name)) { $script:HookTimings[$Name] = [long]$script:HookTimings[$Name] + $Milliseconds }
}

function Write-HookResult { [Console]::Out.Write('{}') }

function Get-NotificationInputValue($InputObject, [string[]]$Names, $Default = 0) {
    if ($null -eq $InputObject) { return $Default }
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $Default
}

function Get-CompletionClassification($InputObject) {
    $eventType = [string](Get-NotificationInputValue -InputObject $InputObject -Names @('type') -Default '')
    $eventName = [string](Get-NotificationInputValue -InputObject $InputObject -Names @('hook_event_name') -Default '')
    $status = [string](Get-NotificationInputValue -InputObject $InputObject -Names @('status', 'turn_status') -Default '')
    if ($status -in @('aborted', 'cancelled', 'canceled')) {
        return [pscustomobject]@{ Classification = 'Aborted'; Evidence = 'aborted'; Compaction = $false; Continuation = $false; IsFinal = $false }
    }
    if ($status -eq 'interrupted') {
        return [pscustomobject]@{ Classification = 'Interrupted'; Evidence = 'interrupted'; Compaction = $false; Continuation = $true; IsFinal = $false }
    }
    if ($null -ne $InputObject.PSObject.Properties['agent_id'] -or $null -ne $InputObject.PSObject.Properties['parent_session_id']) {
        return [pscustomobject]@{ Classification = 'Subagent'; Evidence = 'subagent'; Compaction = $false; Continuation = $false; IsFinal = $false }
    }
    if ($eventType -eq 'agent-turn-complete') {
        $threadId = [string](Get-NotificationInputValue -InputObject $InputObject -Names @('thread-id') -Default '')
        $turnId = [string](Get-NotificationInputValue -InputObject $InputObject -Names @('turn-id') -Default '')
        if (-not [string]::IsNullOrWhiteSpace($threadId) -and -not [string]::IsNullOrWhiteSpace($turnId)) {
            return [pscustomobject]@{ Classification = 'FinalTurnCompletion'; Evidence = 'explicit-agent-turn-complete'; Compaction = $false; Continuation = $false; IsFinal = $true }
        }
        return [pscustomobject]@{ Classification = 'Unknown'; Evidence = 'agent-turn-complete-missing-identity'; Compaction = $false; Continuation = $false; IsFinal = $false }
    }
    if ($eventType -in @('contextCompaction', 'thread/compacted') -or $eventName -in @('PreCompact', 'PostCompact')) {
        return [pscustomobject]@{ Classification = 'ContextCompaction'; Evidence = 'context-compaction'; Compaction = $true; Continuation = $true; IsFinal = $false }
    }
    if ($eventName -eq 'Stop') {
        return [pscustomobject]@{ Classification = 'IntermediateStop'; Evidence = 'generic-stop-not-final'; Compaction = $false; Continuation = $true; IsFinal = $false }
    }
    return [pscustomobject]@{ Classification = 'Unknown'; Evidence = 'insufficient-evidence'; Compaction = $false; Continuation = $false; IsFinal = $false }
}

function ConvertTo-CompletedNotificationInput($InputObject) {
    $eventType = [string]$InputObject.type
    if ($eventType -ne 'agent-turn-complete') { return $InputObject }
    $normalized = [ordered]@{
        session_id = [string]$InputObject.'thread-id'
        turn_id = [string]$InputObject.'turn-id'
        cwd = [string]$InputObject.cwd
        hook_event_name = 'agent-turn-complete'
        last_assistant_message = [string]$InputObject.'last-assistant-message'
        originator = [string]$InputObject.client
        source = 'notify'
        is_main_session = $true
    }
    foreach ($property in @($InputObject.PSObject.Properties)) {
        if ($property.Name -notin @('type', 'thread-id', 'turn-id', 'cwd', 'client', 'input-messages', 'last-assistant-message')) { $normalized[$property.Name] = $property.Value }
    }
    return [pscustomobject]$normalized
}
function Get-NotificationRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_NOTIFICATION_STATE_ROOT)) {
        return [IO.Path]::GetFullPath($env:CODEX_SETTINGS_NOTIFICATION_STATE_ROOT)
    }
    return Join-Path $HOME '.codex\state\notifications'
}

function Write-HookDiagnostic($InputObject, [string]$Result, [string]$Details) {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $root = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_HOOK_LOG_ROOT)) { Join-Path $HOME '.codex\logs\hooks' } else { $env:CODEX_SETTINGS_HOOK_LOG_ROOT }
        $sessionId = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.session_id)) { 'unknown' } else { [string]$InputObject.session_id }
        $safeSessionId = [regex]::Replace($sessionId, '[^A-Za-z0-9._-]', '_')
        $counts = if ($null -eq $script:HookInvocationCounts) { [pscustomobject](New-CodexHookInvocationCounts) } else { $script:HookInvocationCounts }
        $elapsedMs = [long]$script:HookStopwatch.ElapsedMilliseconds
        $slowThresholdMs = if ($Type -eq 'Completed') { 1000 } else { 500 }
        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString('o')
            event = if ($null -eq $InputObject) { '' } else { [string]$InputObject.hook_event_name }
            handler = 'windows-notification'
            stopKind = 'notification'
            notificationType = $Type
            hookEventName = if ($null -eq $InputObject) { '' } else { [string]$InputObject.hook_event_name }
            lifecyclePhase = [string]$script:LifecyclePhase
            completionClassification = [string]$script:CompletionClassification
            completionEvidence = [string]$script:CompletionEvidence
            compactionDetected = [bool]$script:CompactionDetected
            continuationExpected = [bool]$script:ContinuationExpected
            isFinalTurn = [bool]$script:IsFinalTurn
            originator = [string]$script:Originator
            source = [string]$script:InvocationClient
            payloadKeys = @($script:PayloadKeys)
            claimAttempted = [bool]$script:ClaimAttempted
            hookInvoked = $true
            payloadParsed = [bool]$script:PayloadParsed
            settingsEnabled = [bool]$script:SettingsEnabled
            mainSessionResult = [string]$script:MainSessionResult
            mainSessionEvidence = [string]$script:MainSessionEvidence
            dedupeResult = [string]$script:DedupeResult
            result = $Result
            resultReason = [string]$script:DeliveryResultReason
            sessionId = $sessionId
            turnId = if ($null -eq $InputObject) { '' } else { [string]$InputObject.turn_id }
            tool = if ($null -eq $InputObject) { '' } else { [string]$InputObject.tool_name }
            changedFileCount = 0
            changedFiles = @()
            statusMessage = ''
            handlerId = $script:NotificationHandlerId
            claimState = $script:NotificationClaimState
            claimResult = $script:NotificationClaimState
            claimPath = $script:NotificationClaimPath
            nativeToastAttempted = [bool]$script:NativeToastAttempted
            nativeToastShown = [bool]$script:NativeToastShown
            fallbackAttempted = [bool]$script:FallbackAttempted
            fallbackShown = [bool]$script:FallbackShown
            nativeToastError = [string]$script:NativeToastError
            fallbackError = [string]$script:FallbackError
            cleanupScheduled = [bool]$script:CleanupScheduled
            hookSource = $script:HookSource
            invocationSource = '{0}:{1}' -f $script:HookSource, $script:NotificationHandlerId
            hookCommand = $script:HookCommand
            processId = $PID
            parentProcessId = Get-CodexHookParentProcessId
            startTime = $script:HookStartTime.ToString('o')
            endTime = [DateTimeOffset]::Now.ToString('o')
            elapsedMs = $elapsedMs
            slowThresholdMs = $slowThresholdMs
            slowPath = $elapsedMs -ge $slowThresholdMs
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
            invocationCounterMs = [long]$script:HookTimings.invocationCounterMs
            diagnosticWriteMs = [long]$stopwatch.ElapsedMilliseconds
            foregroundElapsedMs = $elapsedMs
            details = $Details
        }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::AppendAllText((Join-Path $root ($safeSessionId + '.log')), (($entry | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    } catch {
        try { [Console]::Error.WriteLine('notification diagnostic write failed: ' + $_.Exception.Message) } catch {}
    } finally { Add-HookTiming -Name 'diagnosticWriteMs' -Milliseconds $stopwatch.ElapsedMilliseconds }
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
        unknownMainSessionPolicy = 'Allow'
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

function Get-NotificationClaimIdentity($InputObject, [string]$NotificationType) {
    $sessionId = [string]$InputObject.session_id
    $turnId = [string]$InputObject.turn_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = 'unknown-session' }
    if ([string]::IsNullOrWhiteSpace($turnId)) {
        foreach ($name in @('event_id', 'notification_id', 'call_id', 'timestamp')) {
            $value = [string]$InputObject.$name
            if (-not [string]::IsNullOrWhiteSpace($value)) { $turnId = "fallback-$name-$value"; break }
        }
        if ([string]::IsNullOrWhiteSpace($turnId)) { $turnId = 'fallback-' + [guid]::NewGuid().ToString('N') }
    }
    $key = if ($NotificationType -eq 'Completed') { "$sessionId|$turnId|Completed" } else { "$sessionId|$turnId|$NotificationType" }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return [pscustomobject]@{ SessionId = $sessionId; TurnId = $turnId; Type = $NotificationType; Key = $key; Hash = $hash }
}

function Write-NotificationJsonAtomic([string]$Path, $Value) {
    $root = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $temporaryPath = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        $payload = [ordered]@{}
        if ($Value -is [Collections.IDictionary]) { foreach ($property in $Value.Keys) { $payload[$property] = $Value[$property] } }
        else { foreach ($property in $Value.PSObject.Properties) { $payload[$property.Name] = $property.Value } }
        $envelope = [ordered]@{ schemaVersion = 1; kind = 'notification-claim'; createdAt = [DateTimeOffset]::UtcNow.ToString('o'); updatedAt = [DateTimeOffset]::UtcNow.ToString('o'); payload = [pscustomobject]$payload }
        foreach ($property in $payload.Keys) { $envelope[$property] = $payload[$property] }
        [IO.File]::WriteAllText($temporaryPath, ($envelope | ConvertTo-Json -Depth 14 -Compress), [Text.UTF8Encoding]::new($false))
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
    if ($null -eq $Claim) { return $false }
    if ([string]$Claim.state -eq 'shown') { return $true }
    if ([string]$Claim.state -ne 'showing') { return $false }
    try { return ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$Claim.createdAt).ToUniversalTime()).TotalSeconds -lt 45 } catch { return $false }
}

function Acquire-NotificationClaim([string]$Root, $InputObject, [string]$NotificationType) {
    $identity = Get-NotificationClaimIdentity -InputObject $InputObject -NotificationType $NotificationType
    $path = Join-Path (Join-Path $Root 'claims') ($identity.Hash + '.json')
    $claim = Invoke-CodexHookMutex -Name ('CodexSettings.NotificationClaim.' + $identity.Hash) -Action {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $existing = Read-NotificationClaim -Path $path
        if (Test-NotificationClaimActive -Claim $existing) {
            return [pscustomobject]@{ Acquired = $false; State = [string]$existing.state; Path = $path; Claim = $existing }
        }
        $value = [ordered]@{
            sessionId = $identity.SessionId
            turnId = $identity.TurnId
            type = $NotificationType
            handlerId = if ($NotificationType -eq 'Completed') { 'completed-toast' } else { 'notification-toast' }
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
        Invoke-CodexHookMutex -Name ('CodexSettings.NotificationClaim.' + $hash) -Action {
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
    return '<text hint-style="title" hint-maxLines="1">' + (ConvertTo-XmlText $Title) + '</text><text hint-style="body" hint-maxLines="4">' + (ConvertTo-XmlText $Message) + '</text>'
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

function Invoke-WithToastStateLock([scriptblock]$Action) {
    return Invoke-CodexHookMutex -Name $script:ToastStateMutexName -Action $Action -TimeoutMilliseconds 2000
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
    $startInfo.RedirectStandardInput = [bool]$Wait
    $startInfo.RedirectStandardOutput = [bool]$Wait
    $startInfo.RedirectStandardError = [bool]$Wait
    Set-ProcessArguments -StartInfo $startInfo -Arguments $Arguments
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        if ($Wait) { $process.StandardInput.Close() }
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
    if ($env:CODEX_SETTINGS_NATIVE_TOAST_TEST_RESULT -eq 'shown') { return [pscustomobject]@{ Shown = $true; CleanupScheduled = $false } }
    if ($env:CODEX_SETTINGS_NATIVE_TOAST_TEST_RESULT -eq 'failed') { throw 'native toast test failure' }
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return Show-NativeToastCore -Title $Title -Message $Message -NotificationType $NotificationType -Sound $Sound -Tag $Tag
    } else {
        return Invoke-WindowsPowerShellToast -Title $Title -Message $Message -NotificationType $NotificationType -Sound $Sound -Tag $Tag
    }
}

function Show-BalloonFallback([string]$Title, [string]$Message, [string]$NotificationType, [bool]$Sound) {
    if ($env:CODEX_SETTINGS_FALLBACK_TEST_RESULT -eq 'shown') { return [pscustomobject]@{ Shown = $true } }
    if ($env:CODEX_SETTINGS_FALLBACK_TEST_RESULT -eq 'failed') { throw 'fallback test failure' }
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
            type = 'agent-turn-complete'
            'thread-id' = 'notification-test'
            'turn-id' = [guid]::NewGuid().ToString('N')
            cwd = (Get-Location).Path
            client = 'notification-test'
            'last-assistant-message' = ''
        }
    } else {
        $inputObject = if ($Type -eq 'Completed' -and -not [string]::IsNullOrWhiteSpace($NotificationPayload)) { ConvertFrom-CodexHookInputJson -Text $NotificationPayload } else { Read-CodexHookInvocation }
        if ($null -eq $inputObject) {
            $inputObject = [pscustomobject]@{}
            $script:DeliveryResultReason = 'invalid-payload'
        }
    }
    $script:PayloadParsed = $inputObject.PSObject.Properties.Count -gt 0
    $script:PayloadKeys = @($inputObject.PSObject.Properties.Name | Sort-Object)
    if ($Type -eq 'Completed') {
        $completion = Get-CompletionClassification -InputObject $inputObject
        $script:CompletionClassification = [string]$completion.Classification
        $script:CompletionEvidence = [string]$completion.Evidence
        $script:CompactionDetected = [bool]$completion.Compaction
        $script:ContinuationExpected = [bool]$completion.Continuation
        $script:IsFinalTurn = [bool]$completion.IsFinal
        $script:LifecyclePhase = if ($script:IsFinalTurn) { 'turn-completed' } elseif ($script:CompactionDetected) { 'compaction' } else { 'non-final' }
        $script:Originator = [string](Get-NotificationInputValue -InputObject $inputObject -Names @('client', 'originator') -Default '')
        $script:InvocationClient = if ([string]$inputObject.type -eq 'agent-turn-complete') { 'notify' } else { [string](Get-NotificationInputValue -InputObject $inputObject -Names @('source') -Default 'hook') }
        $inputObject = ConvertTo-CompletedNotificationInput -InputObject $inputObject
    }

    $script:HookSource = Get-CodexHookSource
    $script:HookInvocationContext = New-CodexHookInvocationContext -InputObject $inputObject -HookSource $script:HookSource
    $script:HookInvocationCounts = Get-CodexHookInvocationCounts -InputObject $inputObject -Kind notification -EventName $Type -HookSource $script:HookSource

    if ($Type -eq 'Completed' -and $script:IsFinalTurn -and [string]$inputObject.last_assistant_message -match '(?s)(?:[?？]\s*$|請(?:選擇|確認|提供|回答))') {
        $Type = 'QuestionRequired'
    }
    $script:NotificationHandlerId = switch ($Type) {
        'Completed' { 'completed-toast' }
        'PermissionRequired' { 'permission-toast' }
        'QuestionRequired' { 'question-toast' }
        default { 'error-toast' }
    }
    $root = Get-NotificationRoot
    $settings = Get-NotificationSettings -Root $root
    $script:SettingsEnabled = [bool]$settings.enabled
    $settingName = $Type.Substring(0, 1).ToLowerInvariant() + $Type.Substring(1)
    $mainSessionClassification = Get-CodexMainSessionClassification -InputObject $inputObject
    $script:MainSessionResult = [string]$mainSessionClassification.Classification
    $script:MainSessionEvidence = [string]$mainSessionClassification.Evidence
    $mainSession = $script:MainSessionResult -eq 'Main' -or ($script:MainSessionResult -eq 'Unknown' -and [string]$settings.unknownMainSessionPolicy -eq 'Allow')
    if (-not $Test -and -not $script:PayloadParsed) {
        $script:DeliveryResultReason = 'invalid-payload'
        Write-HookDiagnostic -InputObject $inputObject -Result 'invalid-payload' -Details ''
    } elseif (-not $Test -and $Type -eq 'Completed' -and -not $script:IsFinalTurn) {
        $script:DeliveryResultReason = 'skipped-non-final'
        Write-HookDiagnostic -InputObject $inputObject -Result 'skipped' -Details ('completionEvidence=' + $script:CompletionEvidence)
    } elseif (-not $Test -and (-not [bool]$settings.enabled -or -not [bool]$settings.$settingName)) {
        $script:DeliveryResultReason = 'skipped-disabled'
        Write-HookDiagnostic -InputObject $inputObject -Result 'disabled' -Details ''
    } elseif (-not $Test -and [bool]$settings.mainSessionOnly -and -not $mainSession) {
        $script:DeliveryResultReason = 'skipped-not-main'
        Write-HookDiagnostic -InputObject $inputObject -Result 'skipped' -Details ('mainSessionEvidence=' + $script:MainSessionEvidence)
    } else {
        $script:ClaimAttempted = $true
        $notificationClaim = Acquire-NotificationClaim -Root $root -InputObject $inputObject -NotificationType $Type
        if (-not [bool]$notificationClaim.Acquired) {
            $script:DedupeResult = 'duplicate'
            $script:DeliveryResultReason = 'skipped-duplicate'
            Write-HookDiagnostic -InputObject $inputObject -Result 'deduplicated' -Details ('claimState={0};claimAlreadyOwned=true' -f $notificationClaim.State)
        } else {
            $script:DedupeResult = 'acquired'
            $content = switch ($Type) {
                'PermissionRequired' { [pscustomobject]@{ Title = 'Codex 等待權限核准'; Message = '需要你的核准才能繼續執行' } }
                'QuestionRequired' { [pscustomobject]@{ Title = 'Codex 等待你的回答'; Message = '請回到 Codex 繼續' } }
                'Error' { [pscustomobject]@{ Title = 'Codex 執行失敗'; Message = '請查看錯誤內容' } }
                default { [pscustomobject]@{ Title = 'Codex 任務完成'; Message = '工作已完成' } }
            }
            $details = ''
            $deliverySucceeded = $false
                $testMode = $env:CODEX_SETTINGS_NOTIFICATION_TEST_MODE -eq '1'
                if ($testMode) {
                    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_NOTIFICATION_TEST_LOG)) {
                        Add-Content -LiteralPath $env:CODEX_SETTINGS_NOTIFICATION_TEST_LOG -Value (@{ type = $Type; title = $content.Title; message = $content.Message } | ConvertTo-Json -Compress) -Encoding UTF8
                    }
                    $deliverySucceeded = $true
                    $script:DeliveryResultReason = 'shown-test'
                } else {
                    $tag = Get-ToastTag -InputObject $inputObject -NotificationType $Type
                    $script:NativeToastAttempted = $true
                    try {
                        $nativeDelivery = Show-NativeToast -Title $content.Title -Message $content.Message -NotificationType $Type -Sound ([bool]$settings.sound) -Tag $tag
                        $script:NativeToastShown = $null -ne $nativeDelivery -and [bool]$nativeDelivery.Shown
                        $script:CleanupScheduled = $null -ne $nativeDelivery -and [bool]$nativeDelivery.CleanupScheduled
                        $deliverySucceeded = [bool]$script:NativeToastShown
                    } catch {
                        $script:NativeToastError = $_.Exception.Message
                        if (-not $script:NativeToastShown) {
                            $script:FallbackAttempted = $true
                            try {
                                $fallbackDelivery = Show-BalloonFallback -Title $content.Title -Message $content.Message -NotificationType $Type -Sound ([bool]$settings.sound)
                                $script:FallbackShown = $null -ne $fallbackDelivery -and [bool]$fallbackDelivery.Shown
                                $deliverySucceeded = [bool]$script:FallbackShown
                            } catch {
                                $script:FallbackError = $_.Exception.Message
                                if ([bool]$settings.sound) { [Console]::Error.Write([char]7) }
                            }
                        }
                    }
                }
                if ($deliverySucceeded) {
                    Set-NotificationClaimState -Claim $notificationClaim -State shown -Result $(if ($testMode) { 'test' } elseif ($script:NativeToastShown) { 'native-toast' } else { 'balloon-fallback' })
                    if (-not $testMode) { $script:DeliveryResultReason = if ($script:NativeToastShown) { 'shown-native' } else { 'shown-fallback' } }
                } else {
                    Set-NotificationClaimState -Claim $notificationClaim -State failed -Result 'no-notification-shown'
                    $script:DeliveryResultReason = if ($script:FallbackAttempted) { 'fallback-failed' } else { 'native-toast-failed' }
                }
                $deliveryDetails = 'claimState={0};nativeToastAttempted={1};nativeToastShown={2};fallbackAttempted={3};fallbackShown={4};cleanupScheduled={5}' -f $script:NotificationClaimState, $script:NativeToastAttempted, $script:NativeToastShown, $script:FallbackAttempted, $script:FallbackShown, $script:CleanupScheduled
                $details = if ([string]::IsNullOrWhiteSpace($details)) { $deliveryDetails } else { $details + ';' + $deliveryDetails }
                Write-HookDiagnostic -InputObject $inputObject -Result $(if ($deliverySucceeded) { 'success' } else { 'delivery-failed' }) -Details $details
        }
    }
} catch {
    if ($script:DeliveryResultReason -notin @('invalid-payload', 'timeout')) { $script:DeliveryResultReason = 'unexpected-error' }
    if ($null -ne $notificationClaim -and $script:NotificationClaimState -eq 'showing') { Set-NotificationClaimState -Claim $notificationClaim -State failed -Result 'unexpected-error' }
    Write-HookDiagnostic -InputObject $inputObject -Result 'error' -Details $_.Exception.ToString()
}

Write-HookResult
