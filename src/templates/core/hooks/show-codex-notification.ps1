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
    ccsessionsResolveMs = 0
    ccsessionsRunMs = 0
    ccsessionsRetrySleepMs = 0
    transcriptReadMs = 0
}
$script:TranscriptTokenEventCache = @{}
$script:CcSessionsCommandName = $null
$script:CcSessionsCommandKind = $null
$script:CcSessionsCommandPath = $null
$script:CcSessionsQueryCount = 0

function Add-HookTiming([string]$Name, [long]$Milliseconds) {
    if ($script:HookTimings.Contains($Name)) { $script:HookTimings[$Name] = [long]$script:HookTimings[$Name] + $Milliseconds }
}

function Write-HookResult { [Console]::Out.Write('{}') }

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
            ccsessionsResolveMs = [long]$script:HookTimings.ccsessionsResolveMs
            ccsessionsRunMs = [long]$script:HookTimings.ccsessionsRunMs
            ccsessionsRetrySleepMs = [long]$script:HookTimings.ccsessionsRetrySleepMs
            ccsessionsQueryCount = [long]$script:CcSessionsQueryCount
            transcriptReadMs = [long]$script:HookTimings.transcriptReadMs
            details = $Details
        }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::AppendAllText((Join-Path $root ($safeSessionId + '.log')), (($entry | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    } catch {} finally { Add-HookTiming -Name 'diagnosticWriteMs' -Milliseconds $stopwatch.ElapsedMilliseconds }
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
    return $null -ne $Claim -and [string]$Claim.state -in @('showing', 'shown')
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
    $titleXml = '<text hint-style="title" hint-maxLines="1">' + (ConvertTo-XmlText $Title) + '</text>'
    $lines = @($Message -split '\r?\n')
    $expectedRows = @(
        ,@('Session ID', 'Model')
        ,@('Input', 'Output')
        ,@('Think', 'Cache')
        ,@('Total', 'Cost')
    )

    if ($lines.Count -eq ($expectedRows.Count + 1)) {
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

        $timeMatch = [regex]::Match($lines[$expectedRows.Count], '^\s*Time\s+(?<timeValue>.+?)\s*$')
        if (-not $timeMatch.Success) { $isTokenUsageLayout = $false }
        if ($isTokenUsageLayout) {
            $time = 'Time ' + $timeMatch.Groups['timeValue'].Value.Trim()
            [void]$rowsXml.Append('<group><subgroup hint-weight="1"><text hint-style="body" hint-align="left" hint-maxLines="1">')
            [void]$rowsXml.Append((ConvertTo-XmlText $time))
            [void]$rowsXml.Append('</text></subgroup></group>')
            return $titleXml + $rowsXml.ToString()
        }
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

function Resolve-CcSessionsCommand {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND)) {
        return [pscustomobject]@{ Kind = 'test'; Name = 'pwsh'; Path = $env:CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND }
    }
    if ($null -ne $script:CcSessionsCommandName) {
        return [pscustomobject]@{ Kind = $script:CcSessionsCommandKind; Name = $script:CcSessionsCommandName; Path = $script:CcSessionsCommandPath }
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($profilePath in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique) {
            if (Test-Path -LiteralPath $profilePath -PathType Leaf) { . $profilePath *> $null }
            if (Get-Command ccsessions -ErrorAction SilentlyContinue) { break }
        }
        $command = Get-Command ccsessions -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) { throw 'ccsessions not found' }
        $script:CcSessionsCommandName = [string]$command.Name
        $script:CcSessionsCommandKind = 'profile'
        $script:CcSessionsCommandPath = [string]$command.Source
        return [pscustomobject]@{ Kind = 'profile'; Name = [string]$command.Name; Path = [string]$command.Source }
    } finally { Add-HookTiming -Name 'ccsessionsResolveMs' -Milliseconds $stopwatch.ElapsedMilliseconds }
}

function Test-CcSessionsRetryableError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) { $message = [string]$ErrorRecord }
    return $message -match '(?i)(?:usage\s+not\s+ready|not\s+ready|stale|no\s+matching\s+session|different\s+session|session\s+mismatch)'
}

function Invoke-CcSessionsJson([string]$SessionId, $Baseline) {
    $script:CcSessionsQueryCount++
    $lastError = $null
    $retryDelays = @(150, 250, 400, 650, 900, 1200)
    $command = Resolve-CcSessionsCommand
    for ($attempt = 0; $attempt -le $retryDelays.Count; $attempt++) {
        try {
            $runStopwatch = [Diagnostics.Stopwatch]::StartNew()
            if ($command.Kind -eq 'test') {
                $output = & pwsh -NoLogo -NoProfile -File $command.Path -SessionId $SessionId 2>&1
            } else {
                $output = & $command.Name -Json $SessionId 2>&1
            }
            Add-HookTiming -Name 'ccsessionsRunMs' -Milliseconds $runStopwatch.ElapsedMilliseconds
            $text = ($output | Out-String).Trim()
            $start = $text.IndexOf('{')
            $end = $text.LastIndexOf('}')
            if ($start -lt 0 -or $end -le $start) {
                if ($text -match '(?i)(?:usage\s+not\s+ready|not\s+ready|stale|no\s+matching\s+session|different\s+session)') { throw 'ccsessions usage not ready' }
                throw 'ccsessions returned invalid JSON'
            }
            $result = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json -ErrorAction Stop
            if ($result -is [array]) { $result = @($result | Where-Object { [string]$_.sessionId -eq $SessionId })[0] }
            if ($null -eq $result -or -not [bool]$result.success) { throw $(if ($result.error) { [string]$result.error } else { 'ccsessions returned no matching session' }) }
            if ([string]$result.sessionId -ne $SessionId) { throw 'ccsessions returned a different session' }
            if ($null -ne $Baseline) {
                $candidate = ConvertTo-Snapshot -Usage $result -SessionId $SessionId -Source 'ccsessions'
                if (-not (Test-SnapshotChanged -Current $candidate -Previous $Baseline)) {
                    if ($attempt -ge $retryDelays.Count) { return [pscustomobject]@{ Data = $result; RetryCount = $attempt } }
                    $sleepStopwatch = [Diagnostics.Stopwatch]::StartNew()
                    Start-Sleep -Milliseconds $retryDelays[$attempt]
                    Add-HookTiming -Name 'ccsessionsRetrySleepMs' -Milliseconds $sleepStopwatch.ElapsedMilliseconds
                    continue
                }
            }
            return [pscustomobject]@{ Data = $result; RetryCount = $attempt }
        } catch {
            $lastError = $_
            try { $lastError.Exception.Data['ccsessionsRetryCount'] = $attempt } catch {}
            if (-not (Test-CcSessionsRetryableError -ErrorRecord $_) -or $attempt -ge $retryDelays.Count) { throw }
            $sleepStopwatch = [Diagnostics.Stopwatch]::StartNew()
            Start-Sleep -Milliseconds $retryDelays[$attempt]
            Add-HookTiming -Name 'ccsessionsRetrySleepMs' -Milliseconds $sleepStopwatch.ElapsedMilliseconds
        }
    }
    throw $lastError
}

function Get-LastTokenCountEvent([string]$TranscriptPath) {
    if ($script:TranscriptTokenEventCache.ContainsKey($TranscriptPath)) { return $script:TranscriptTokenEventCache[$TranscriptPath] }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $event = $null
    try {
        $event = Get-Content -LiteralPath $TranscriptPath -Tail 512 | ForEach-Object {
            try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        } | Where-Object {
            $_.type -eq 'event_msg' -and $_.payload.type -eq 'token_count'
        } | Select-Object -Last 1
    } catch {}
    $script:TranscriptTokenEventCache[$TranscriptPath] = $event
    Add-HookTiming -Name 'transcriptReadMs' -Milliseconds $stopwatch.ElapsedMilliseconds
    return $event
}

function Get-RealtimeUsage($InputObject) {
    $directUsage = Get-UsageValue -Usage $InputObject -Names @('last_token_usage') -Default $null
    if ($null -ne $directUsage) { return $directUsage }

    $transcriptPath = [string](Get-UsageValue -Usage $InputObject -Names @('transcript_path') -Default '')
    if ([string]::IsNullOrWhiteSpace($transcriptPath) -or -not (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) { return $null }
    try {
        $event = Get-LastTokenCountEvent -TranscriptPath $transcriptPath
        if ($null -ne $event -and $null -ne $event.payload.info.last_token_usage) { return $event.payload.info.last_token_usage }
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
            $event = Get-LastTokenCountEvent -TranscriptPath $transcriptPath
            if ($null -ne $event) {
                $models = @(Get-ModelNamesFromUsage -Usage $event.payload.info)
                if ($models.Count -eq 0) { $models = @(Get-ModelNamesFromUsage -Usage $event.payload) }
                if ($models.Count -gt 0) { return [pscustomobject]@{ Names = $models; Source = 'transcript' } }
            }
        } catch {}
    }
    return [pscustomobject]@{ Names = @(); Source = 'N/A' }
}

function ConvertTo-NotificationTime($Value) {
    if ($null -eq $Value) { return '' }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    if ($text -match '^\d{2}-\d{2} \d{2}:\d{2} [AP]M$') { return $text }
    try {
        $parsed = if ($Value -is [DateTimeOffset]) { $Value } elseif ($Value -is [DateTime]) { [DateTimeOffset]::new($Value) } else { [DateTimeOffset]::Parse($text, [Globalization.CultureInfo]::InvariantCulture) }
        return [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($parsed, 'Taipei Standard Time').ToString('MM-dd hh:mm tt', [Globalization.CultureInfo]::InvariantCulture)
    } catch { return '' }
}

function Get-UsageTime($Usage) {
    foreach ($name in @('time', 'formattedTime', 'lastActivity', 'last_activity', 'timestamp', 'last_activity_time')) {
        $field = Get-UsageField -Usage $Usage -Names @($name)
        if ($field.Present) {
            $text = ConvertTo-NotificationTime -Value $field.Value
            if (-not [string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ Present = $true; Value = $text; Name = $name } }
        }
    }
    return [pscustomobject]@{ Present = $false; Value = ''; Name = $null }
}

function ConvertTo-Snapshot($Usage, [string]$SessionId, [string]$Source = 'ccsessions') {
    $models = @(Get-ModelNamesFromUsage -Usage $Usage)
    $inputField = Get-UsageField -Usage $Usage -Names @('inputTokens', 'input_tokens')
    $outputField = Get-UsageField -Usage $Usage -Names @('outputTokens', 'output_tokens')
    $reasoningField = Get-UsageField -Usage $Usage -Names @('reasoningTokens', 'reasoningOutputTokens', 'reasoning_output_tokens', 'thinkingTokens', 'thinking_tokens')
    $cacheField = Get-UsageField -Usage $Usage -Names @('cacheTokens', 'cachedInputTokens', 'cached_input_tokens', 'cacheReadTokens', 'cache_read_tokens')
    $totalField = Get-UsageField -Usage $Usage -Names @('totalTokens', 'total_tokens')
    $costField = Get-UsageField -Usage $Usage -Names @('costUsd', 'cost_usd', 'costUSD')
    $timeField = Get-UsageTime -Usage $Usage
    $presentFields = @()
    foreach ($field in @($inputField, $outputField, $reasoningField, $cacheField, $totalField, $costField)) { if ([bool]$field.Present) { $presentFields += [string]$field.Name } }
    if ([bool]$timeField.Present) { $presentFields += [string]$timeField.Name }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        sessionId = $SessionId
        source = $Source
        models = $models
        hasModel = $models.Count -gt 0
        time = [string]$timeField.Value
        hasTime = [bool]$timeField.Present
        inputTokens = if ($inputField.Present) { [long]$inputField.Value } else { [long]0 }
        hasInputTokens = [bool]$inputField.Present
        outputTokens = if ($outputField.Present) { [long]$outputField.Value } else { [long]0 }
        hasOutputTokens = [bool]$outputField.Present
        reasoningTokens = if ($reasoningField.Present) { [long]$reasoningField.Value } else { [long]0 }
        hasReasoningTokens = [bool]$reasoningField.Present
        cacheTokens = if ($cacheField.Present) { [long]$cacheField.Value } else { [long]0 }
        hasCacheTokens = [bool]$cacheField.Present
        totalTokens = if ($totalField.Present) { [long]$totalField.Value } else { [long]0 }
        hasTotalTokens = [bool]$totalField.Present
        hasCost = [bool]$costField.Present
        costUsd = if ($costField.Present) { [decimal]$costField.Value } else { [decimal]0 }
        presentFields = @($presentFields)
        capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
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
        schemaVersion = 2
        sessionId = $Snapshot.sessionId
        source = $Snapshot.source
        models = @($Snapshot.models)
        hasModel = [bool]$Snapshot.hasModel
        time = $Snapshot.time
        hasTime = [bool]$Snapshot.hasTime
        inputTokens = $Snapshot.inputTokens
        hasInputTokens = [bool]$Snapshot.hasInputTokens
        outputTokens = $Snapshot.outputTokens
        hasOutputTokens = [bool]$Snapshot.hasOutputTokens
        reasoningTokens = $Snapshot.reasoningTokens
        hasReasoningTokens = [bool]$Snapshot.hasReasoningTokens
        cacheTokens = $Snapshot.cacheTokens
        hasCacheTokens = [bool]$Snapshot.hasCacheTokens
        totalTokens = $Snapshot.totalTokens
        hasTotalTokens = [bool]$Snapshot.hasTotalTokens
        hasCost = [bool]$Snapshot.hasCost
        costUsd = $Snapshot.costUsd
    }
}

function ConvertTo-BaselineSnapshot($Usage, [string]$SessionId) {
    $snapshot = ConvertTo-Snapshot -Usage $Usage -SessionId $SessionId -Source 'ccsessions'
    foreach ($property in @('hasModel', 'hasTime', 'hasInputTokens', 'hasOutputTokens', 'hasReasoningTokens', 'hasCacheTokens', 'hasTotalTokens', 'hasCost')) {
        if ($Usage.PSObject.Properties.Name -contains $property) { $snapshot.$property = [bool]$Usage.$property }
    }
    return $snapshot
}

function Get-CcSessionsBaseline($State, [string]$SessionId) {
    if ($null -eq $State) { return $null }
    if ([string]$State.source -eq 'realtime') { return $null }
    if ($State.PSObject.Properties.Name -contains 'ccsessionsBaseline' -and $null -ne $State.ccsessionsBaseline) {
        $storedBaseline = $State.ccsessionsBaseline
        if ($storedBaseline.PSObject.Properties.Name -notcontains 'source' -or [string]$storedBaseline.source -ne 'ccsessions') { return $null }
        $baseline = ConvertTo-BaselineSnapshot -Usage $storedBaseline -SessionId $SessionId
        if (Test-SnapshotHasCoreUsage -Snapshot $baseline) { return $baseline }
        return $null
    }
    if ([string]$State.source -eq 'ccsessions') {
        $baseline = ConvertTo-BaselineSnapshot -Usage $State -SessionId $SessionId
        if (Test-SnapshotHasCoreUsage -Snapshot $baseline) { return $baseline }
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
    return [bool]$Snapshot.hasInputTokens -and [bool]$Snapshot.hasOutputTokens -and [bool]$Snapshot.hasReasoningTokens -and [bool]$Snapshot.hasCacheTokens -and [bool]$Snapshot.hasTotalTokens
}

function Test-SnapshotCanSubtract($Current, $Previous) {
    if ($null -eq $Current -or $null -eq $Previous) { return $false }
    $comparable = $false
    foreach ($property in @('inputTokens', 'outputTokens', 'reasoningTokens', 'cacheTokens', 'totalTokens')) {
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
    foreach ($property in @('inputTokens', 'outputTokens', 'reasoningTokens', 'cacheTokens', 'totalTokens')) {
        $hasProperty = 'has' + $property.Substring(0, 1).ToUpperInvariant() + $property.Substring(1)
        if ([bool]$Current.$hasProperty -ne [bool]$Previous.$hasProperty) { return $true }
        if ([bool]$Current.$hasProperty -and [decimal]$Current.$property -ne [decimal]$Previous.$property) { return $true }
    }
    if ([bool]$Current.hasCost -ne [bool]$Previous.hasCost) { return $true }
    if ([bool]$Current.hasCost -and [bool]$Previous.hasCost -and [decimal]$Current.costUsd -ne [decimal]$Previous.costUsd) { return $true }
    return $false
}

function New-SnapshotDelta($Current, $Previous, [string]$ModelFallback) {
    $models = if ([bool]$Current.hasModel -and @($Current.models).Count -gt 0) { @($Current.models) } elseif (-not [string]::IsNullOrWhiteSpace($ModelFallback)) { @($ModelFallback) } else { @() }
    $value = [ordered]@{
        schemaVersion = 1
        kind = 'usage-delta'
        sessionId = $Current.sessionId
        source = 'ccsessions-delta'
        models = $models
        hasModel = $models.Count -gt 0
        time = $Current.time
        hasTime = [bool]$Current.hasTime
    }
    foreach ($property in @('inputTokens', 'outputTokens', 'reasoningTokens', 'cacheTokens', 'totalTokens')) {
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
        schemaVersion = 1
        kind = 'usage-display'
        sessionId = $TokenSnapshot.sessionId
        source = $Source
    }
    $models = if ($null -ne $MetadataSnapshot -and @($MetadataSnapshot.models).Count -gt 0) { @($MetadataSnapshot.models) } elseif (@($TokenSnapshot.models).Count -gt 0) { @($TokenSnapshot.models) } elseif (-not [string]::IsNullOrWhiteSpace($ModelFallback)) { @($ModelFallback) } else { @() }
    $value.models = $models
    $value.hasModel = $models.Count -gt 0
    $metadataHasTime = $null -ne $MetadataSnapshot -and [bool]$MetadataSnapshot.hasTime
    $value.time = if ($metadataHasTime) { [string]$MetadataSnapshot.time } elseif ([bool]$TokenSnapshot.hasTime) { [string]$TokenSnapshot.time } else { '' }
    $value.hasTime = $metadataHasTime -or [bool]$TokenSnapshot.hasTime
    $fieldMap = [ordered]@{
        inputTokens = 'hasInputTokens'
        outputTokens = 'hasOutputTokens'
        reasoningTokens = 'hasReasoningTokens'
        cacheTokens = 'hasCacheTokens'
        totalTokens = 'hasTotalTokens'
    }
    foreach ($property in $fieldMap.Keys) {
        $hasProperty = $fieldMap[$property]
        $hasTokenValue = [bool]$TokenSnapshot.$hasProperty
        $value[$property] = if ($hasTokenValue) { $TokenSnapshot.$property } else { [long]0 }
        $value[$hasProperty] = $hasTokenValue
    }
    $hasMetadataCost = $null -ne $MetadataSnapshot -and [bool]$MetadataSnapshot.hasCost
    $useMetadataCostValue = $UseMetadataCost -and -not [bool]$TokenSnapshot.hasCost -and $hasMetadataCost
    $value.hasCost = [bool]$TokenSnapshot.hasCost -or $useMetadataCostValue
    $value.costUsd = if ([bool]$TokenSnapshot.hasCost) { [decimal]$TokenSnapshot.costUsd } elseif ($useMetadataCostValue) { [decimal]$MetadataSnapshot.costUsd } else { [decimal]0 }
    return [pscustomobject]$value
}

function Get-MissingSnapshotFields($Snapshot) {
    if ($null -eq $Snapshot) { return @('snapshot') }
    $missing = @()
    $fields = [ordered]@{
        inputTokens = 'hasInputTokens'
        outputTokens = 'hasOutputTokens'
        reasoningTokens = 'hasReasoningTokens'
        cacheTokens = 'hasCacheTokens'
        totalTokens = 'hasTotalTokens'
        costUsd = 'hasCost'
        model = 'hasModel'
        time = 'hasTime'
    }
    foreach ($field in $fields.Keys) {
        if (-not [bool]$Snapshot.($fields[$field])) { $missing += $field }
    }
    return $missing
}

function Save-State([string]$Path, $Snapshot, [string]$Hash, [string]$TurnId, [string]$RealtimeHash, $Baseline, [string]$LastKnownModel) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $value = [ordered]@{
        schemaVersion = 2
        sessionId = $Snapshot.sessionId
        source = $Snapshot.source
        models = @($Snapshot.models)
        hasModel = $Snapshot.hasModel
        time = $Snapshot.time
        hasTime = $Snapshot.hasTime
        inputTokens = $Snapshot.inputTokens
        hasInputTokens = $Snapshot.hasInputTokens
        outputTokens = $Snapshot.outputTokens
        hasOutputTokens = $Snapshot.hasOutputTokens
        reasoningTokens = $Snapshot.reasoningTokens
        hasReasoningTokens = $Snapshot.hasReasoningTokens
        cacheTokens = $Snapshot.cacheTokens
        hasCacheTokens = $Snapshot.hasCacheTokens
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
    $payload = [ordered]@{}
    foreach ($property in $value.Keys) { $payload[$property] = $value[$property] }
    $value.kind = 'token-usage'
    $value.createdAt = [DateTimeOffset]::UtcNow.ToString('o')
    $value.payload = [pscustomobject]$payload
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporaryPath, (($value | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
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

function Get-TokenUsageDisplayCore($InputObject, $Settings) {
    $sessionId = [string]$InputObject.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'session ID could not be resolved' }
    if ([bool]$InputObject.stop_hook_active) { return [pscustomobject]@{ Skipped = $true } }

    $root = Get-TokenUsageRoot
    $statePath = Get-SessionStatePath -Root $root -SessionId $sessionId
    $previous = Read-PreviousState -Path $statePath
    $baseline = Get-CcSessionsBaseline -State $previous -SessionId $sessionId
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
            if (-not [string]::IsNullOrWhiteSpace([string]$InputObject.turn_id) -and $previousTurnId -eq [string]$InputObject.turn_id) {
                return [pscustomobject]@{ Duplicate = $true; Source = [string]$previous.source }
            }
            if ([string]$previous.source -eq 'realtime-fallback' -and [string]$previous.lastDisplayedRealtimeHash -eq $realtimeHash) {
                return [pscustomobject]@{ Duplicate = $true; Source = 'realtime-fallback' }
            }
        }
    }

    $ccsessionsSnapshot = $null
    $ccsessionsRetryCount = 0
    $ccsessionsError = ''
    try {
        $ccsessionsResult = Invoke-CcSessionsJson -SessionId $sessionId -Baseline $baseline
        $ccsessionsRetryCount = [int]$ccsessionsResult.RetryCount
        $ccsessionsSnapshot = ConvertTo-Snapshot -Usage $ccsessionsResult.Data -SessionId $sessionId -Source 'ccsessions'
    } catch {
        $ccsessionsError = $_.Exception.Message
        try {
            if ($_.Exception.Data.Contains('ccsessionsRetryCount')) { $ccsessionsRetryCount = [int]$_.Exception.Data['ccsessionsRetryCount'] }
        } catch {}
    }

    $newBaseline = $baseline
    $display = $null
    $showAsTurnDelta = $false
    $tokenSource = 'N/A'
    $modelSource = 'N/A'
    $costSource = 'N/A'
    $modelFallback = Get-LastKnownModel -State $previous
    if ($null -ne $realtimeSnapshot -and [bool]$realtimeSnapshot.hasModel) { $modelFallback = [string]@($realtimeSnapshot.models)[0] }

    if ($null -ne $ccsessionsSnapshot) {
        $ccsessionsHasCoreUsage = Test-SnapshotHasCoreUsage -Snapshot $ccsessionsSnapshot
        $ccsessionsChanged = $null -eq $baseline -or (Test-SnapshotChanged -Current $ccsessionsSnapshot -Previous $baseline)
        $canSubtract = Test-SnapshotCanSubtract -Current $ccsessionsSnapshot -Previous $baseline
        if ($ccsessionsHasCoreUsage -and $ccsessionsChanged) { $newBaseline = $ccsessionsSnapshot }

        if ($null -eq $baseline) {
            $display = New-DisplaySnapshot -TokenSnapshot $ccsessionsSnapshot -MetadataSnapshot $null -ModelFallback $modelFallback -UseMetadataCost $false -Source 'ccsessions-total'
            $tokenSource = 'ccsessions-total'
            $modelSource = if ([bool]$display.hasModel) { 'ccsessions' } else { 'N/A' }
            $costSource = if ([bool]$display.hasCost) { 'ccsessions' } else { 'N/A' }
        } elseif ($ccsessionsChanged -and $canSubtract) {
            $display = New-SnapshotDelta -Current $ccsessionsSnapshot -Previous $baseline -ModelFallback $modelFallback
            $showAsTurnDelta = $true
            $tokenSource = 'ccsessions-delta'
            $modelSource = if ([bool]$ccsessionsSnapshot.hasModel) { 'ccsessions' } elseif ([bool]$baseline.hasModel) { 'ccsessions-baseline' } else { $realtimeModelSource }
            $costSource = if ([bool]$display.hasCost) { 'ccsessions-delta' } else { 'N/A' }
        } elseif ($ccsessionsChanged) {
            $display = New-DisplaySnapshot -TokenSnapshot $ccsessionsSnapshot -MetadataSnapshot $null -ModelFallback $modelFallback -UseMetadataCost $false -Source 'ccsessions-total'
            $tokenSource = 'ccsessions-total'
            $modelSource = if ([bool]$display.hasModel) { 'ccsessions' } else { 'N/A' }
            $costSource = if ([bool]$display.hasCost) { 'ccsessions' } else { 'N/A' }
        } elseif ($null -ne $realtimeSnapshot) {
            $metadataSnapshot = if ($null -ne $baseline) { $baseline } else { $ccsessionsSnapshot }
            $display = New-DisplaySnapshot -TokenSnapshot $realtimeSnapshot -MetadataSnapshot $metadataSnapshot -ModelFallback $modelFallback -UseMetadataCost $true -Source 'realtime-fallback'
            $showAsTurnDelta = $true
            $tokenSource = 'realtime-fallback'
            $modelSource = if ($null -ne $metadataSnapshot -and [bool]$metadataSnapshot.hasModel) { 'ccsessions' } elseif ([bool]$display.hasModel) { $realtimeModelSource } else { 'N/A' }
            $costSource = if ([bool]$realtimeSnapshot.hasCost) { 'realtime-fallback' } elseif ($null -ne $metadataSnapshot -and [bool]$metadataSnapshot.hasCost) { 'ccsessions-metadata' } else { 'N/A' }
        } else {
            return [pscustomobject]@{ Duplicate = $true; Source = 'ccsessions-total' }
        }
    } elseif ($null -ne $realtimeSnapshot) {
        $display = New-DisplaySnapshot -TokenSnapshot $realtimeSnapshot -MetadataSnapshot $baseline -ModelFallback $modelFallback -UseMetadataCost $true -Source 'realtime-fallback'
        $showAsTurnDelta = $true
        $tokenSource = 'realtime-fallback'
        $modelSource = if ($null -ne $baseline -and [bool]$baseline.hasModel) { 'ccsessions' } elseif ([bool]$display.hasModel) { $realtimeModelSource } else { 'N/A' }
        $costSource = if ([bool]$realtimeSnapshot.hasCost) { 'realtime-fallback' } elseif ($null -ne $baseline -and [bool]$baseline.hasCost) { 'ccsessions-metadata' } else { 'N/A' }
    } else {
        if ([string]::IsNullOrWhiteSpace($ccsessionsError)) { $ccsessionsError = 'ccsessions returned no data' }
        $failure = [InvalidOperationException]::new($ccsessionsError)
        $failure.Data['realtimeAvailable'] = $false
        $failure.Data['ccsessionsAvailable'] = $false
        $failure.Data['ccsessionsRetryCount'] = $ccsessionsRetryCount
        $failure.Data['missingFields'] = 'inputTokens,outputTokens,reasoningTokens,cacheTokens,totalTokens,costUsd,model,time'
        $failure.Data['ccsessionsError'] = $ccsessionsError
        throw $failure
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
    $inputText = Format-SnapshotToken $display 'inputTokens' 'hasInputTokens' $showAsTurnDelta
    $outputText = Format-SnapshotToken $display 'outputTokens' 'hasOutputTokens' $showAsTurnDelta
    $reasoningText = Format-SnapshotToken $display 'reasoningTokens' 'hasReasoningTokens' $showAsTurnDelta
    $cacheText = Format-SnapshotToken $display 'cacheTokens' 'hasCacheTokens' $showAsTurnDelta
    $totalText = Format-SnapshotToken $display 'totalTokens' 'hasTotalTokens' $showAsTurnDelta
    $costIsDelta = $showAsTurnDelta -and $costSource -ne 'ccsessions-metadata'
    $costText = if ([bool]$Settings.showCost -and [bool]$display.hasCost) { Format-Cost $display.costUsd $costIsDelta } else { 'N/A' }
    $timeText = if ([bool]$display.hasTime) { [string]$display.time } else { 'N/A' }
    $lines = @(
        ('Session ID     {0}   | Model      {1}' -f $sessionText, $modelText)
        ('Input          {0}   | Output     {1}' -f $inputText, $outputText)
        ('Think          {0}   | Cache      {1}' -f $reasoningText, $cacheText)
        ('Total          {0}   | Cost       {1}' -f $totalText, $costText)
        ('Time           {0}' -f $timeText)
    )
    $missingFields = @(Get-MissingSnapshotFields -Snapshot $display)
    return [pscustomobject]@{
        Text = $lines -join [Environment]::NewLine
        Source = $display.source
        DisplayedDelta = $showAsTurnDelta
        BaselineFound = $null -ne $baseline
        RealtimeAvailable = $null -ne $realtimeSnapshot
        CcsessionsAvailable = $null -ne $ccsessionsSnapshot
        CcsessionsRetryCount = $ccsessionsRetryCount
        TokenSource = $tokenSource
        ModelSource = $modelSource
        CostSource = $costSource
        MissingFields = $missingFields
        DisplaySnapshot = $display
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
    return Invoke-CodexHookMutex -Name $mutexName -Action { Get-TokenUsageDisplayCore -InputObject $InputObject -Settings $Settings }
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
        $inputObject = Read-CodexHookInvocation
        if ($null -eq $inputObject) { $inputObject = [pscustomobject]@{} }
    }

    $script:HookSource = Get-CodexHookSource
    $script:HookInvocationContext = New-CodexHookInvocationContext -InputObject $inputObject -HookSource $script:HookSource
    $script:HookInvocationCounts = Get-CodexHookInvocationCounts -InputObject $inputObject -Kind notification -EventName $Type -HookSource $script:HookSource

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
    $mainSession = Test-CodexMainSession -InputObject $inputObject
    if (-not $Test -and (-not [bool]$settings.enabled -or -not [bool]$settings.$settingName)) {
        Write-HookDiagnostic -InputObject $inputObject -Result 'disabled' -Details ''
    } elseif (-not $Test -and [bool]$settings.mainSessionOnly -and -not $mainSession) {
        Write-HookDiagnostic -InputObject $inputObject -Result 'skipped' -Details 'notification=non-main-session'
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
                if ([bool]$tokenSettings.enabled -and [bool]$tokenSettings.showAfterEachTurn -and (-not [bool]$tokenSettings.mainSessionOnly -or $mainSession)) {
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
                            $baselineFound = if ([bool]$usage.BaselineFound) { 'true' } else { 'false' }
                            $snapshot = $usage.DisplaySnapshot
                            $modelValue = if ([bool]$snapshot.hasModel) { [string]@($snapshot.models)[0] } else { 'N/A' }
                            $inputValue = Format-SnapshotToken $snapshot 'inputTokens' 'hasInputTokens' ([bool]$usage.DisplayedDelta)
                            $outputValue = Format-SnapshotToken $snapshot 'outputTokens' 'hasOutputTokens' ([bool]$usage.DisplayedDelta)
                            $reasoningValue = Format-SnapshotToken $snapshot 'reasoningTokens' 'hasReasoningTokens' ([bool]$usage.DisplayedDelta)
                            $cacheValue = Format-SnapshotToken $snapshot 'cacheTokens' 'hasCacheTokens' ([bool]$usage.DisplayedDelta)
                            $totalValue = Format-SnapshotToken $snapshot 'totalTokens' 'hasTotalTokens' ([bool]$usage.DisplayedDelta)
                            $costValue = if ([bool]$snapshot.hasCost) { Format-Cost $snapshot.costUsd ([bool]$usage.DisplayedDelta -and [string]$usage.CostSource -ne 'ccsessions-metadata') } else { 'N/A' }
                            $timeValue = if ([bool]$snapshot.hasTime) { [string]$snapshot.time } else { 'N/A' }
                            $details = 'source={0};displayedDelta={1};realtimeAvailable={2};ccsessionsAvailable={3};baselineFound={4};ccsessionsRetryCount={5};tokenSource={6};modelSource={7};costSource={8};showAsTurnDelta={9};model={10};input={11};output={12};think={13};cache={14};total={15};cost={16};time={17};missingFields=[{18}]' -f $usage.Source, $showAsTurnDelta, $realtimeAvailable, $ccsessionsAvailable, $baselineFound, $usage.CcsessionsRetryCount, $usage.TokenSource, $usage.ModelSource, $usage.CostSource, $showAsTurnDelta, $modelValue, $inputValue, $outputValue, $reasoningValue, $cacheValue, $totalValue, $costValue, $timeValue, $missingFields
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
                } elseif ([bool]$tokenSettings.enabled -and [bool]$tokenSettings.showAfterEachTurn -and [bool]$tokenSettings.mainSessionOnly -and -not $mainSession) {
                    $details = 'tokenUsage=skipped-non-main-session'
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
