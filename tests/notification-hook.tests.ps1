$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$hookScript = Join-Path $repositoryRoot 'src\templates\core\hooks\show-codex-notification.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-notification-' + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $testRoot 'SampleProject'
$notificationRoot = Join-Path $testRoot 'notifications'
$tokenRoot = Join-Path $testRoot 'token-usage'
$logPath = Join-Path $testRoot 'notifications.jsonl'
$diagnosticRoot = Join-Path $testRoot 'hook-logs'
$invocationRoot = Join-Path $testRoot 'hook-invocations'
$snapshotPath = Join-Path $testRoot 'snapshot.json'
$rolloutPath = Join-Path $testRoot 'rollout.jsonl'
$mockPath = Join-Path $testRoot 'mock-ccsessions.ps1'
$retryMarkerPath = Join-Path $testRoot 'retry.marker'
$hangMarkerPath = Join-Path $testRoot 'hang.marker'

function Set-Snapshot([string]$SessionId, [long]$InputTokens, [long]$CachedInputTokens, [long]$CacheWriteTokens, [long]$OutputTokens, [long]$TotalTokens, [decimal]$CostUsd, [string[]]$Models = @('gpt-5.6-sol'), [switch]$WithoutCost, [switch]$WithoutCacheWrite, [long]$ReasoningTokens = 0, [string]$Time = '08-07 03:43 PM') {
    $value = [ordered]@{ success = $true; sessionId = $SessionId; models = $Models; inputTokens = $InputTokens; outputTokens = $OutputTokens; reasoningTokens = $ReasoningTokens; totalTokens = $TotalTokens; time = $Time }
    if (-not $WithoutCacheWrite) { $value.cacheTokens = $CachedInputTokens }
    if (-not $WithoutCost) { $value.costUsd = $CostUsd }
    [IO.File]::WriteAllText($snapshotPath, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}

function Invoke-NotificationHook([string]$SessionId, [string]$TurnId, [hashtable]$AdditionalInput = @{}, [string]$RawInput, [string]$Type = 'Completed', [string]$LastMessage = '') {
    $inputObject = if ($Type -eq 'Completed') {
        [ordered]@{ type = 'agent-turn-complete'; 'thread-id' = $SessionId; 'turn-id' = $TurnId; cwd = Join-Path $projectRoot 'src'; client = 'codex_vscode'; 'input-messages' = @('fixture'); 'last-assistant-message' = $LastMessage }
    } else {
        [ordered]@{ session_id = $SessionId; turn_id = $TurnId; cwd = Join-Path $projectRoot 'src'; hook_event_name = $(if ($Type -eq 'PermissionRequired') { 'PermissionRequest' } else { 'PreToolUse' }); last_assistant_message = $LastMessage }
    }
    foreach ($property in $AdditionalInput.GetEnumerator()) { $inputObject[$property.Key] = $property.Value }
    $inputText = if ([string]::IsNullOrWhiteSpace($RawInput)) { $inputObject | ConvertTo-Json -Depth 8 -Compress } else { $RawInput }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $hookScript, '-Type', $Type)) { $startInfo.ArgumentList.Add($argument) }
    if ($Type -eq 'Completed') { $startInfo.ArgumentList.Add($inputText) }
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($Type -ne 'Completed') { $process.StandardInput.Write($inputText) }
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $script:LastHookStderr = $stderr
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or $stdout -ne '{}') { throw "通知 Hook 失敗：exit=$($process.ExitCode) stdout=$stdout stderr=$stderr" }
    return $stdout | ConvertFrom-Json
}

function Get-LastNotification {
    return (Get-Content -LiteralPath $logPath | Select-Object -Last 1) | ConvertFrom-Json
}

try {
    New-Item -ItemType Directory -Path (Join-Path $projectRoot '.git'), (Join-Path $projectRoot 'src') -Force | Out-Null
    $hooksTemplate = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\templates\core\hooks.json') -Raw | ConvertFrom-Json
    if ($null -ne $hooksTemplate.hooks.PSObject.Properties['Stop']) { throw 'Completed 通知不可再綁定 generic Stop。' }
    $notificationSource = Get-Content -LiteralPath $hookScript -Raw
    $notificationBytes = [IO.File]::ReadAllBytes($hookScript)
    if ($notificationBytes.Length -lt 3 -or $notificationBytes[0] -ne 0xEF -or $notificationBytes[1] -ne 0xBB -or $notificationBytes[2] -ne 0xBF) { throw '通知腳本必須使用 UTF-8 BOM，以便 Windows PowerShell 5.1 正確解析。' }
    foreach ($expected in @('duration="long"', 'scenario="urgent"', 'ConvertTo-ToastVisualXml', '<group>', 'hint-weight="1"', 'hint-align="left"', 'hint-maxLines="1"', 'ToastNotificationPriority', 'ExpirationTime', 'WindowStyle =', 'UseShellExecute = $false', 'CreateNoWindow = $true', 'RedirectStandardInput', 'RedirectStandardOutput', 'RedirectStandardError', 'ToastLifetimeSeconds = 60', 'PreviousToastLifetimeSeconds = 60', 'Start-Sleep -Seconds $DelaySeconds', 'active-toast.json', 'claims', 'Acquire-NotificationClaim', 'state = ''showing''', 'shownAt', 'History.Remove', 'powershell.exe', 'NativeToast', 'Invoke-CodexHookMutex', 'nativeToastShown', 'fallbackAttempted', 'cleanupScheduled')) {
        if ($notificationSource -notmatch [regex]::Escape($expected)) { throw "Toast 設定缺少：$expected" }
    }

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $mockContent = @'
param([string]$SessionId)
if ($env:CODEX_SETTINGS_CCSESSIONS_FAIL -eq '1') {
    Write-Output 'usage not ready'
    exit 0
}
if ($env:CODEX_SETTINGS_CCSESSIONS_NONRETRYABLE -eq '1') {
    Write-Output 'fatal backend error'
    exit 0
}
if ($env:CODEX_SETTINGS_CCSESSIONS_HANG -eq '1') {
    [IO.File]::WriteAllText($env:CODEX_SETTINGS_CCSESSIONS_HANG_MARKER, [string]$PID)
    Start-Sleep -Seconds 60
    exit 0
}
if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER) -and -not (Test-Path -LiteralPath $env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER)) {
    [IO.File]::WriteAllText($env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER, '0')
}
if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER)) {
    $attempt = [int](Get-Content -LiteralPath $env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER -Raw) + 1
    [IO.File]::WriteAllText($env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER, [string]$attempt)
    $failureCount = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_CCSESSIONS_RETRY_FAILURE_COUNT)) { 1 } else { [int]$env:CODEX_SETTINGS_CCSESSIONS_RETRY_FAILURE_COUNT }
    if ($attempt -le $failureCount) {
        Write-Output 'usage not ready'
        exit 0
    }
}
Get-Content -LiteralPath $env:CODEX_SETTINGS_CCSESSIONS_SNAPSHOT -Raw
'@
    [IO.File]::WriteAllText($mockPath, $mockContent, [Text.UTF8Encoding]::new($false))
    $env:CODEX_SETTINGS_NOTIFICATION_STATE_ROOT = $notificationRoot
    $env:CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT = $tokenRoot
    $env:CODEX_SETTINGS_NOTIFICATION_TEST_MODE = '1'
    $env:CODEX_SETTINGS_NOTIFICATION_TEST_LOG = $logPath
    $env:CODEX_SETTINGS_HOOK_LOG_ROOT = $diagnosticRoot
    $env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT = $invocationRoot
    $env:CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND = $mockPath
    $env:CODEX_SETTINGS_CCSESSIONS_SNAPSHOT = $snapshotPath

    $vscodeSession = '019fe798-1ecb-7221-b31d-2f2d3280a361'
    Set-Snapshot -SessionId $vscodeSession -InputTokens 100 -CachedInputTokens 20 -CacheWriteTokens 0 -OutputTokens 10 -TotalTokens 130 -CostUsd 0.01
    $vscodePayload = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\codex-notify-agent-turn-complete.json') -Raw
    [void](Invoke-NotificationHook -SessionId $vscodeSession -TurnId 'ignored' -RawInput $vscodePayload)
    $vscodeDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot ($vscodeSession + '.log')) -Raw | ConvertFrom-Json
    if ((Get-LastNotification).type -ne 'Completed' -or $vscodeDiagnostic.mainSessionResult -ne 'Main' -or $vscodeDiagnostic.resultReason -ne 'shown-test' -or $vscodeDiagnostic.completionClassification -ne 'FinalTurnCompletion') { throw '真實 Codex notify fixture 未走到 Completed delivery。' }

    $eventsBeforeMissingTurn = @(Get-Content -LiteralPath $logPath).Count
    [void](Invoke-NotificationHook -SessionId 'missing-turn-session' -TurnId '' -AdditionalInput @{ event_id = 'event-a' } -Type PermissionRequired)
    [void](Invoke-NotificationHook -SessionId 'missing-turn-session' -TurnId '' -AdditionalInput @{ event_id = 'event-b' } -Type PermissionRequired)
    [void](Invoke-NotificationHook -SessionId 'missing-turn-session' -TurnId '' -AdditionalInput @{ event_id = 'event-a' } -Type PermissionRequired)
    if (@(Get-Content -LiteralPath $logPath).Count -ne $eventsBeforeMissingTurn + 2) { throw '缺少 turn_id 的不同 lifecycle event 被永久去重，或同 event_id 未 exactly-once。' }

    $staleKey = 'stale-claim-session|stale-claim-turn|PermissionRequired'
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $staleHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($staleKey)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    $staleClaimPath = Join-Path (Join-Path $notificationRoot 'claims') ($staleHash + '.json')
    [IO.File]::WriteAllText($staleClaimPath, (@{ sessionId = 'stale-claim-session'; turnId = 'stale-claim-turn'; type = 'PermissionRequired'; state = 'showing'; createdAt = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o') } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $eventsBeforeStaleClaim = @(Get-Content -LiteralPath $logPath).Count
    [void](Invoke-NotificationHook -SessionId 'stale-claim-session' -TurnId 'stale-claim-turn' -Type PermissionRequired)
    if (@(Get-Content -LiteralPath $logPath).Count -ne $eventsBeforeStaleClaim + 1 -or (Get-Content -LiteralPath $staleClaimPath -Raw | ConvertFrom-Json).state -ne 'shown') { throw '被 timeout 留下的 stale showing claim 永久阻擋後續 delivery。' }

    [void](Invoke-NotificationHook -SessionId 'subagent-session' -TurnId 'subagent-turn' -AdditionalInput @{ is_main_session = $false } -Type PermissionRequired)
    $subagentDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot 'subagent-session.log') -Raw | ConvertFrom-Json
    if ($subagentDiagnostic.mainSessionResult -ne 'Subagent' -or $subagentDiagnostic.resultReason -ne 'skipped-not-main') { throw 'Subagent main-session policy 或診斷錯誤。' }

    $unwritableDiagnosticRoot = Join-Path $testRoot 'diagnostic-root-is-a-file'
    [IO.File]::WriteAllText($unwritableDiagnosticRoot, 'not a directory')
    $env:CODEX_SETTINGS_HOOK_LOG_ROOT = $unwritableDiagnosticRoot
    [void](Invoke-NotificationHook -SessionId 'diagnostic-failure' -TurnId 'diagnostic-failure-turn' -Type PermissionRequired)
    $env:CODEX_SETTINGS_HOOK_LOG_ROOT = $diagnosticRoot
    if ($script:LastHookStderr -notmatch 'notification diagnostic write failed') { throw '主要診斷路徑不可寫時，secondary diagnostic 未出現在 stderr。' }

    $tokenSettingsPath = Join-Path $tokenRoot 'settings.json'
    $tokenSettingsBeforeLoop = Get-Content -LiteralPath $tokenSettingsPath -Raw
    [IO.File]::WriteAllText($tokenSettingsPath, '{"enabled":false,"showAfterEachTurn":false,"mainSessionOnly":true}', [Text.UTF8Encoding]::new($false))
    $eventsBeforeLoop = @(Get-Content -LiteralPath $logPath).Count
    foreach ($index in 1..20) { [void](Invoke-NotificationHook -SessionId 'twenty-completed-session' -TurnId "turn-$index" -AdditionalInput @{ is_main_session = $true }) }
    [IO.File]::WriteAllText($tokenSettingsPath, $tokenSettingsBeforeLoop, [Text.UTF8Encoding]::new($false))
    if (@(Get-Content -LiteralPath $logPath).Count -ne $eventsBeforeLoop + 20) { throw '20 個連續 main-session Completed lifecycle events 未產生恰好 20 個 delivery 結果。' }

    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_TEST_MODE
    $env:CODEX_SETTINGS_NATIVE_TOAST_TEST_RESULT = 'shown'
    $env:CODEX_SETTINGS_FALLBACK_TEST_RESULT = 'failed'
    [void](Invoke-NotificationHook -SessionId 'native-success' -TurnId 'turn-native-success' -Type PermissionRequired)
    $nativeSuccess = Get-Content -LiteralPath (Join-Path $diagnosticRoot 'native-success.log') -Raw | ConvertFrom-Json
    if ($nativeSuccess.resultReason -ne 'shown-native' -or -not $nativeSuccess.nativeToastShown -or $nativeSuccess.fallbackAttempted -or $nativeSuccess.cleanupScheduled) { throw 'Native Show 成功後 cleanup 未排程時不應 fallback 或反轉 shown。' }

    $env:CODEX_SETTINGS_NATIVE_TOAST_TEST_RESULT = 'failed'
    $env:CODEX_SETTINGS_FALLBACK_TEST_RESULT = 'shown'
    [void](Invoke-NotificationHook -SessionId 'fallback-success' -TurnId 'turn-fallback-success' -Type PermissionRequired)
    $fallbackSuccess = Get-Content -LiteralPath (Join-Path $diagnosticRoot 'fallback-success.log') -Raw | ConvertFrom-Json
    if ($fallbackSuccess.resultReason -ne 'shown-fallback' -or -not $fallbackSuccess.fallbackShown -or $fallbackSuccess.nativeToastError -notmatch 'native toast test failure') { throw 'Native Show 失敗時未恰好 fallback 一次並保留錯誤。' }

    $env:CODEX_SETTINGS_FALLBACK_TEST_RESULT = 'failed'
    [void](Invoke-NotificationHook -SessionId 'delivery-failure' -TurnId 'turn-delivery-failure' -Type PermissionRequired)
    $deliveryFailure = Get-Content -LiteralPath (Join-Path $diagnosticRoot 'delivery-failure.log') -Raw | ConvertFrom-Json
    if ($deliveryFailure.resultReason -ne 'fallback-failed' -or $deliveryFailure.claimState -ne 'failed' -or $deliveryFailure.nativeToastError -notmatch 'native toast test failure' -or $deliveryFailure.fallbackError -notmatch 'fallback test failure') { throw 'Native + fallback 失敗時未保留兩個錯誤與 failed claim。' }
    $env:CODEX_SETTINGS_NOTIFICATION_TEST_MODE = '1'
    Remove-Item Env:\CODEX_SETTINGS_NATIVE_TOAST_TEST_RESULT, Env:\CODEX_SETTINGS_FALLBACK_TEST_RESULT

    $sessionRealtime = '019fd65b-39b0-7d60-99fc-deb094690001'
    Set-Snapshot -SessionId $sessionRealtime -InputTokens 999000 -CachedInputTokens 888000 -CacheWriteTokens 777000 -OutputTokens 666000 -TotalTokens 3330000 -CostUsd 9.99
    [void](Invoke-NotificationHook -SessionId $sessionRealtime -TurnId 'turn-realtime' -AdditionalInput @{
        last_token_usage = [ordered]@{ input_tokens = 4321; cached_input_tokens = 1234; cache_write_input_tokens = 345; output_tokens = 567; reasoning_output_tokens = 89; total_tokens = 6567 }
    })
    $realtimeNotification = Get-LastNotification
    foreach ($expected in @('Session ID     690001', 'Model      gpt-5.6-sol', 'Input          999K', 'Output     666K', 'Think          0', 'Cache      888K', 'Total          3.33M', 'Cost       $9.99', 'Time           08-07 03:43 PM')) {
        if (-not $realtimeNotification.message.Contains($expected)) { throw "ccsessions 累積 Token 用量未正確整合到完成通知：$expected" }
    }
    foreach ($obsolete in @('Cache read', 'Cache write', 'Cache hit rate', 'Estimated usage', 'Session         ')) {
        if ($realtimeNotification.message.Contains($obsolete)) { throw "完成通知仍包含淘汰欄位：$obsolete" }
    }
    if (@($realtimeNotification.message -split '\r?\n').Count -ne 5 -or $realtimeNotification.title -ne 'Codex 任務完成') { throw '完成通知不是固定五行格式。' }
    $realtimeClaim = @(Get-ChildItem -LiteralPath (Join-Path $notificationRoot 'claims') -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.sessionId -eq $sessionRealtime -and $_.turnId -eq 'turn-realtime' -and $_.type -eq 'Completed' })[0]
    if ($null -eq $realtimeClaim -or $realtimeClaim.state -ne 'shown' -or $realtimeClaim.handlerId -ne 'completed-token-toast' -or [string]::IsNullOrWhiteSpace([string]$realtimeClaim.shownAt)) { throw 'Completed 通知未建立 shown 狀態的 exactly-once Claim。' }
    $realtimeState = @(Get-ChildItem -LiteralPath $tokenRoot -Filter '*.json' | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).sessionId -eq $sessionRealtime })[0]
    if ($null -eq $realtimeState) { throw '即時 Token 狀態檔未建立。' }
    $realtimeStateValue = Get-Content -LiteralPath $realtimeState.FullName -Raw | ConvertFrom-Json
    if ($realtimeStateValue.schemaVersion -ne 2 -or $null -eq $realtimeStateValue.ccsessionsBaseline -or $realtimeStateValue.ccsessionsBaseline.inputTokens -ne 999000 -or $realtimeStateValue.ccsessionsBaseline.reasoningTokens -ne 0 -or $realtimeStateValue.ccsessionsBaseline.cacheTokens -ne 888000 -or $realtimeStateValue.ccsessionsBaseline.time -ne '08-07 03:43 PM') { throw 'ccsessions 累積基準未依新快照格式保存。' }
    $realtimeDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot ($sessionRealtime + '.log')) -Raw | ConvertFrom-Json
    foreach ($field in @('timestamp', 'hookInvoked', 'payloadParsed', 'settingsEnabled', 'mainSessionResult', 'mainSessionEvidence', 'dedupeResult', 'usageRequested', 'usageResult', 'resultReason', 'hookSource', 'hookCommand', 'processId', 'parentProcessId', 'startTime', 'endTime', 'elapsedMs', 'exitCode', 'handlerId', 'claimState', 'claimResult', 'claimAttempted', 'nativeToastAttempted', 'nativeToastShown', 'nativeToastError', 'fallbackAttempted', 'fallbackShown', 'fallbackError', 'cleanupScheduled', 'stopKind', 'invocationSource', 'hookEventName', 'lifecyclePhase', 'completionClassification', 'completionEvidence', 'compactionDetected', 'continuationExpected', 'isFinalTurn', 'originator', 'source', 'payloadKeys', 'GlobalStopHookCount', 'EffectiveStopHookCount', 'NotificationInvocationCount', 'CrlfInvocationCount', 'ccsessionsQueryCount', 'ccsessionsRetryCount', 'ccsessionsAttemptDurationsMs', 'ccsessionsRetrySleepMs', 'ccsessionsResolveMs', 'ccsessionsRunMs', 'resultAcceptedAtAttempt', 'usageResultReason', 'fallbackReason', 'foregroundElapsedMs')) {
        if ($realtimeDiagnostic.PSObject.Properties.Name -notcontains $field) { throw "通知診斷缺少欄位：$field" }
    }
    if ($realtimeDiagnostic.ccsessionsQueryCount -ne 1 -or $realtimeDiagnostic.ccsessionsRetryCount -ne 0 -or @($realtimeDiagnostic.ccsessionsAttemptDurationsMs).Count -ne 1 -or $realtimeDiagnostic.ccsessionsRetrySleepMs -ne 0 -or $realtimeDiagnostic.resultAcceptedAtAttempt -ne 1 -or $realtimeDiagnostic.usageResultReason -ne 'no-baseline' -or $realtimeDiagnostic.fallbackReason -ne '' -or $realtimeDiagnostic.foregroundElapsedMs -ge 3000) { throw '無基準且首次查詢成功時未立即接受結果。' }
    if (-not $realtimeDiagnostic.hookInvoked -or -not $realtimeDiagnostic.payloadParsed -or $realtimeDiagnostic.mainSessionResult -ne 'Main' -or -not $realtimeDiagnostic.isFinalTurn -or -not $realtimeDiagnostic.claimAttempted -or $realtimeDiagnostic.completionClassification -ne 'FinalTurnCompletion' -or $realtimeDiagnostic.completionEvidence -ne 'explicit-agent-turn-complete' -or $realtimeDiagnostic.resultReason -ne 'shown-test') { throw 'Lifecycle 診斷未記錄 canonical finality、claim 或 delivery 結果。' }
    if ($realtimeDiagnostic.handler -ne 'windows-notification' -or $realtimeDiagnostic.result -ne 'success' -or $realtimeDiagnostic.details -notmatch 'source=ccsessions-total' -or $realtimeDiagnostic.details -notmatch 'realtimeAvailable=true;ccsessionsAvailable=true;baselineFound=false;ccsessionsRetryCount=0;tokenSource=ccsessions-total;modelSource=ccsessions;costSource=ccsessions;showAsTurnDelta=false;model=gpt-5\.6-sol;input=999K;output=666K;think=0;cache=888K;total=3\.33M;cost=\$9\.99;time=08-07 03:43 PM;missingFields=\[\]' -or $realtimeDiagnostic.hookSource -ne 'global' -or $realtimeDiagnostic.NotificationInvocationCount -ne 1 -or $realtimeDiagnostic.CrlfInvocationCount -ne 0) {
        throw 'ccsessions 累積資料或完成通知診斷紀錄錯誤。'
    }

    Set-Snapshot -SessionId $sessionRealtime -InputTokens 999000 -CachedInputTokens 888000 -CacheWriteTokens 777000 -OutputTokens 666000 -TotalTokens 3330000 -CostUsd 9.99
    [void](Invoke-NotificationHook -SessionId $sessionRealtime -TurnId 'turn-realtime-fallback' -AdditionalInput @{
        last_token_usage = [ordered]@{ input_tokens = 4321; cached_input_tokens = 1234; cache_write_input_tokens = 345; output_tokens = 567; reasoning_output_tokens = 89; total_tokens = 6567 }
    })
    $fallbackNotification = Get-LastNotification
    foreach ($expected in @('Input          +4.32K', 'Output     +567', 'Think          +89', 'Cache      +1.23K', 'Total          +6.57K', 'Cost       $9.99', 'Time           08-07 03:43 PM')) {
        if (-not $fallbackNotification.message.Contains($expected)) { throw "realtime fallback 未正確顯示對應欄位：$expected" }
    }
    $fallbackDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot ($sessionRealtime + '.log')) | Select-Object -Last 1 | ConvertFrom-Json
    if ($fallbackDiagnostic.details -notmatch 'source=realtime-fallback;.*baselineFound=true;.*ccsessionsRetryCount=2;.*tokenSource=realtime-fallback;.*costSource=ccsessions-metadata' -or $fallbackDiagnostic.ccsessionsQueryCount -ne 3 -or $fallbackDiagnostic.resultAcceptedAtAttempt -ne 0 -or $fallbackDiagnostic.usageResultReason -ne 'stale-baseline' -or $fallbackDiagnostic.fallbackReason -ne 'stale-baseline' -or $fallbackDiagnostic.foregroundElapsedMs -ge 3000) { throw 'ccsessions 尚未落盤時未在前景預算內重試並正確記錄 realtime fallback。' }

    $tokenStateCountBeforeQuestion = @(Get-ChildItem -LiteralPath $tokenRoot -Filter '*.json' | Where-Object Name -ne 'settings.json').Count
    [void](Invoke-NotificationHook -SessionId '019fd65b-39b0-7d60-99fc-deb094690010' -TurnId 'turn-question' -LastMessage '請確認是否繼續？')
    $questionNotification = Get-LastNotification
    if ($questionNotification.type -ne 'QuestionRequired' -or $questionNotification.title -ne 'Codex 等待你的回答' -or $questionNotification.message -ne '請回到 Codex 繼續') { throw 'Completed 問句未改為等待回答通知。' }
    if (@(Get-ChildItem -LiteralPath $tokenRoot -Filter '*.json' | Where-Object Name -ne 'settings.json').Count -ne $tokenStateCountBeforeQuestion) { throw '等待回答通知不應執行 Token 統計。' }

    [void](Invoke-NotificationHook -SessionId 'session-permission' -TurnId 'turn-permission' -Type PermissionRequired)
    [void](Invoke-NotificationHook -SessionId 'session-error' -TurnId 'turn-error' -Type Error)
    $events = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    $permissionEvents = @($events | Where-Object type -eq PermissionRequired)
    if ($permissionEvents.Count -lt 1 -or @($permissionEvents | Where-Object { $_.title -ne 'Codex 等待權限核准' -or $_.message -ne '需要你的核准才能繼續執行' }).Count -gt 0 -or @($events | Where-Object type -eq Error).Count -ne 1) { throw '權限與錯誤通知未使用固定內容。' }
    if (@($events | Where-Object { $_.PSObject.Properties.Name -contains 'project' }).Count -ne 0) { throw '通知不應包含專案名稱欄位。' }

    $eventCountBeforeDuplicate = $events.Count
    [void](Invoke-NotificationHook -SessionId $sessionRealtime -TurnId 'turn-realtime')
    if (@(Get-Content -LiteralPath $logPath).Count -ne $eventCountBeforeDuplicate) { throw '相同 Session、turn 與類型未正確去重。' }
    $duplicateDiagnostic = @(Get-Content -LiteralPath (Join-Path $diagnosticRoot ($sessionRealtime + '.log')) | ForEach-Object { $_ | ConvertFrom-Json }) | Select-Object -Last 1
    if ($duplicateDiagnostic.result -ne 'deduplicated' -or $duplicateDiagnostic.NotificationInvocationCount -ne 2 -or $duplicateDiagnostic.EffectiveStopHookCount -ne 0) { throw '重複 canonical completion 未在早期去重並記錄有效執行次數。' }

    $sessionTranscript = '019fd65b-39b0-7d60-99fc-deb094690002'
    Set-Snapshot -SessionId $sessionTranscript -InputTokens 999000 -CachedInputTokens 888000 -CacheWriteTokens 777000 -OutputTokens 666000 -TotalTokens 3330000 -CostUsd 9.99
    $rolloutEvent = [ordered]@{
        type = 'event_msg'
        payload = [ordered]@{
            type = 'token_count'
            info = [ordered]@{
                last_token_usage = [ordered]@{ input_tokens = 2468; cached_input_tokens = 1357; cache_write_input_tokens = 246; output_tokens = 579; reasoning_output_tokens = 0; total_tokens = 4650 }
                total_token_usage = [ordered]@{ input_tokens = 999000; cached_input_tokens = 888000; cache_write_input_tokens = 777000; output_tokens = 666000; reasoning_output_tokens = 0; total_tokens = 3330000 }
                model_context_window = 272000
            }
        }
    }
    [IO.File]::WriteAllText($rolloutPath, ($rolloutEvent | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    [void](Invoke-NotificationHook -SessionId $sessionTranscript -TurnId 'turn-transcript' -AdditionalInput @{ transcript_path = $rolloutPath })
    $fromTranscript = Get-LastNotification
    foreach ($expected in @('Input          999K', 'Output     666K', 'Think          0', 'Cache      888K', 'Total          3.33M', 'Cost       $9.99')) {
        if (-not $fromTranscript.message.Contains($expected)) { throw "ccsessions 累積快照未優先於 rollout token_count：$expected" }
    }

    $sessionMalformed = '019fd65b-39b0-7d60-99fc-deb094690004'
    $malformedInput = [ordered]@{
        type = 'agent-turn-complete'
        'thread-id' = $sessionMalformed
        'turn-id' = 'turn-malformed-message'
        cwd = $repositoryRoot
        client = 'codex_cli_rs'
        transcript_path = $rolloutPath
        'last-assistant-message' = '已刪除 "activity_config.php" 註解'
    } | ConvertTo-Json -Compress
    $malformedInput = $malformedInput.Replace('\"activity_config.php\"', '"activity_config.php"')
    [void](Invoke-NotificationHook -SessionId $sessionMalformed -TurnId 'turn-malformed-message' -RawInput $malformedInput)
    if ((Get-LastNotification).message -match 'Token 用量暫時無法取得' -or -not (Get-LastNotification).message.Contains('Input          +2.47K') -or -not (Get-LastNotification).message.Contains('Cache      +1.36K')) {
        throw '含未跳脫引號的 canonical payload 未使用 rollout Token 用量。'
    }

    $sessionTruncated = '019fd65b-39b0-7d60-99fc-deb094690005'
    $truncatedInput = [ordered]@{
        type = 'agent-turn-complete'
        'thread-id' = $sessionTruncated
        'turn-id' = 'turn-truncated-message'
        cwd = $repositoryRoot
        client = 'codex_cli_rs'
        transcript_path = $rolloutPath
        'last-assistant-message' = 'unfinished'
    } | ConvertTo-Json -Compress
    $truncatedInput = $truncatedInput.Substring(0, $truncatedInput.IndexOf('unfinished') + 'unfinished'.Length)
    [void](Invoke-NotificationHook -SessionId $sessionTruncated -TurnId 'turn-truncated-message' -RawInput $truncatedInput)
    if ((Get-LastNotification).message -match 'Token 用量暫時無法取得' -or -not (Get-LastNotification).message.Contains('Input          +2.47K') -or -not (Get-LastNotification).message.Contains('Cache      +1.36K')) {
        throw '截斷的 canonical payload 未使用 rollout Token 用量。'
    }

    $sessionRetry = '019fd65b-39b0-7d60-99fc-deb094690003'
    Set-Snapshot -SessionId $sessionRetry -InputTokens 8765 -CachedInputTokens 4321 -CacheWriteTokens 123 -OutputTokens 987 -TotalTokens 14073 -CostUsd 0.02
    $env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER = $retryMarkerPath
    [void](Invoke-NotificationHook -SessionId $sessionRetry -TurnId 'turn-retry')
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER
    if (-not (Test-Path -LiteralPath $retryMarkerPath) -or -not (Get-LastNotification).message.Contains('Input          8.77K')) { throw 'ccsessions 資料延遲時未重試一次。' }
    $retryDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot ($sessionRetry + '.log')) -Raw | ConvertFrom-Json
    if ($retryDiagnostic.details -notmatch 'source=ccsessions-total;.*ccsessionsRetryCount=1;tokenSource=ccsessions-total;modelSource=ccsessions;costSource=ccsessions;showAsTurnDelta=false;.*missingFields=\[\]') { throw 'ccsessions 重試次數或來源診斷錯誤。' }
    if ($retryDiagnostic.ccsessionsQueryCount -ne 2 -or $retryDiagnostic.resultAcceptedAtAttempt -ne 2 -or $retryDiagnostic.usageResultReason -ne 'no-baseline') { throw '第二次查詢成功時未立即接受結果。' }

    $sessionThirdAttempt = '019fd65b-39b0-7d60-99fc-deb094690013'
    Set-Snapshot -SessionId $sessionThirdAttempt -InputTokens 13579 -CachedInputTokens 2468 -CacheWriteTokens 0 -OutputTokens 987 -TotalTokens 17034 -CostUsd 0.03
    Remove-Item -LiteralPath $retryMarkerPath -ErrorAction SilentlyContinue
    $env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER = $retryMarkerPath
    $env:CODEX_SETTINGS_CCSESSIONS_RETRY_FAILURE_COUNT = '2'
    [void](Invoke-NotificationHook -SessionId $sessionThirdAttempt -TurnId 'turn-third-attempt')
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_RETRY_FAILURE_COUNT
    $thirdAttemptDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot ($sessionThirdAttempt + '.log')) -Raw | ConvertFrom-Json
    if ($thirdAttemptDiagnostic.ccsessionsQueryCount -ne 3 -or $thirdAttemptDiagnostic.ccsessionsRetryCount -ne 2 -or $thirdAttemptDiagnostic.resultAcceptedAtAttempt -ne 3 -or $thirdAttemptDiagnostic.usageResultReason -ne 'no-baseline' -or $thirdAttemptDiagnostic.foregroundElapsedMs -ge 3000) { throw '第三次查詢成功時未在前景預算內立即接受結果。' }

    $sessionMissing = '019fd65b-39b0-7d60-99fc-deb094690006'
    Set-Snapshot -SessionId $sessionMissing -InputTokens 20 -CachedInputTokens 4 -CacheWriteTokens 0 -OutputTokens 5 -TotalTokens 29 -CostUsd 0.02 -WithoutCacheWrite
    [void](Invoke-NotificationHook -SessionId $sessionMissing -TurnId 'turn-missing-cache-write' -AdditionalInput @{
        last_token_usage = [ordered]@{ input_tokens = 20; cached_input_tokens = 4; output_tokens = 5; total_tokens = 29 }
    })
    if ((Get-LastNotification).message -notmatch 'Cache      N/A') { throw '缺少 Cache 欄位時不應顯示 0。' }

    $sessionA = '019fd65b-39b0-7d60-99fc-deb09469413b'
    Set-Snapshot -SessionId $sessionA -InputTokens 120000 -CachedInputTokens 80000 -CacheWriteTokens 20000 -OutputTokens 12000 -TotalTokens 212000 -CostUsd 0.18 -ReasoningTokens 3000
    [void](Invoke-NotificationHook -SessionId $sessionA -TurnId 'turn-1')
    $first = Get-LastNotification
    foreach ($expected in @('Session ID     69413b', 'Model      gpt-5.6-sol', 'Input          120K', 'Think          3K', 'Cache      80K', 'Total          212K', 'Cost       $0.18', 'Time           08-07 03:43 PM')) {
        if (-not $first.message.Contains($expected)) { throw "新 Session 第一輪缺少：$expected" }
    }
    $eventCountBeforeTokenDuplicate = @((Get-Content -LiteralPath $logPath)).Count
    [void](Invoke-NotificationHook -SessionId $sessionA -TurnId 'turn-1-duplicate')
    if (@((Get-Content -LiteralPath $logPath)).Count -ne $eventCountBeforeTokenDuplicate) { throw '相同用量 snapshot 被重複顯示。' }

    Set-Snapshot -SessionId $sessionA -InputTokens 145000 -CachedInputTokens 96000 -CacheWriteTokens 22000 -OutputTokens 15500 -TotalTokens 256500 -CostUsd 0.22 -Models @('gpt-5.6-sol', 'gpt-5.6-terra') -ReasoningTokens 4500
    [void](Invoke-NotificationHook -SessionId $sessionA -TurnId 'turn-2')
    $second = Get-LastNotification
    foreach ($expected in @('+25K', '+3.5K', '+1.5K', '+16K', '+44.5K', '+$0.04', 'Model      gpt-5.6-sol')) {
        if (-not $second.message.Contains($expected)) { throw "第二輪差值缺少：$expected" }
    }
    if ($second.message.Contains('gpt-5.6-terra')) { throw '完成通知應只顯示第一個模型。' }

    $sessionB = '019fd65b-39b0-7d60-99fc-deb094699999'
    Set-Snapshot -SessionId $sessionB -InputTokens 10 -CachedInputTokens 2 -CacheWriteTokens 1 -OutputTokens 3 -TotalTokens 15 -CostUsd 0.001
    [void](Invoke-NotificationHook -SessionId $sessionB -TurnId 'turn-b1')
    $sessionNoCost = '019fd65b-39b0-7d60-99fc-deb094690998'
    Set-Snapshot -SessionId $sessionNoCost -InputTokens 20 -CachedInputTokens 4 -CacheWriteTokens 2 -OutputTokens 5 -TotalTokens 31 -CostUsd 0 -WithoutCost
    [void](Invoke-NotificationHook -SessionId $sessionNoCost -TurnId 'turn-no-cost')
    if ((Get-LastNotification).message -notmatch 'Cost       N/A') { throw '缺少成本欄位時不應顯示虛構的零成本。' }
    $sessionZero = '019fd65b-39b0-7d60-99fc-deb094690997'
    Set-Snapshot -SessionId $sessionZero -InputTokens 0 -CachedInputTokens 0 -CacheWriteTokens 0 -OutputTokens 0 -TotalTokens 0 -CostUsd 0
    [void](Invoke-NotificationHook -SessionId $sessionZero -TurnId 'turn-zero')
    if ((Get-LastNotification).message -notmatch 'Cache      0' -or (Get-LastNotification).message -notmatch 'Cost       \$0') { throw '真正的零值不應被視為缺欄位。' }
    $sessionStates = @(Get-ChildItem -LiteralPath $tokenRoot -Filter '*.json' | Where-Object Name -ne 'settings.json')
    if ($sessionStates.Count -ne 12) { throw "多 Session 狀態檔數量錯誤：$($sessionStates.Count)" }

    $stateA = @($sessionStates | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).sessionId -eq $sessionA })[0]
    [IO.File]::WriteAllText($stateA.FullName, '{invalid', [Text.UTF8Encoding]::new($false))
    Set-Snapshot -SessionId $sessionA -InputTokens 150000 -CachedInputTokens 97000 -CacheWriteTokens 22500 -OutputTokens 16000 -TotalTokens 263000 -CostUsd 0.23
    [void](Invoke-NotificationHook -SessionId $sessionA -TurnId 'turn-3')
    if (@(Get-ChildItem -LiteralPath $tokenRoot -Filter '*.corrupt-*').Count -ne 1) { throw '損壞狀態未備份並重建。' }

    $env:CODEX_SETTINGS_CCSESSIONS_FAIL = '1'
    [void](Invoke-NotificationHook -SessionId 'session-failure' -TurnId 'turn-failure')
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_FAIL
    $failureNotification = Get-LastNotification
    if ($failureNotification.message -ne 'Token 用量暫時無法取得') { throw 'Token 統計失敗時未顯示完成通知的降級內容。' }
    $failureDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot 'session-failure.log') -Raw | ConvertFrom-Json
    if ($failureDiagnostic.result -ne 'success' -or $failureDiagnostic.details -notmatch 'tokenUsageError=.*ccsessions (?:returned invalid JSON|usage not ready)') { throw 'Token 統計原始錯誤未寫入診斷紀錄。' }

    $env:CODEX_SETTINGS_CCSESSIONS_NONRETRYABLE = '1'
    [void](Invoke-NotificationHook -SessionId 'session-nonretryable' -TurnId 'turn-nonretryable')
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_NONRETRYABLE
    $nonretryableDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot 'session-nonretryable.log') -Raw | ConvertFrom-Json
    if ($nonretryableDiagnostic.ccsessionsQueryCount -ne 1 -or $nonretryableDiagnostic.ccsessionsRetryCount -ne 0 -or $nonretryableDiagnostic.usageResultReason -ne 'non-retryable-error' -or $nonretryableDiagnostic.fallbackReason -ne 'non-retryable-error') { throw '非暫時性 ccsessions 錯誤不應重試。' }

    $env:CODEX_SETTINGS_CCSESSIONS_HANG = '1'
    $env:CODEX_SETTINGS_CCSESSIONS_HANG_MARKER = $hangMarkerPath
    [void](Invoke-NotificationHook -SessionId 'session-hung' -TurnId 'turn-hung')
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_HANG
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_HANG_MARKER
    $hungDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot 'session-hung.log') -Raw | ConvertFrom-Json
    $hungProcessId = [int](Get-Content -LiteralPath $hangMarkerPath -Raw)
    if ($hungDiagnostic.ccsessionsQueryCount -ne 1 -or $hungDiagnostic.ccsessionsRetryCount -ne 0 -or $hungDiagnostic.usageResultReason -ne 'query-timeout' -or $hungDiagnostic.fallbackReason -ne 'query-timeout' -or $hungDiagnostic.foregroundElapsedMs -ge 3000 -or $null -ne (Get-Process -Id $hungProcessId -ErrorAction SilentlyContinue)) { throw '卡住的 ccsessions 後端未在單次 timeout 後終止行程樹並降級。' }

    $settingsPath = Join-Path $tokenRoot 'settings.json'
    $tokenSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $tokenSettings.enabled = $false
    [IO.File]::WriteAllText($settingsPath, ($tokenSettings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    [void](Invoke-NotificationHook -SessionId 'session-token-disabled' -TurnId 'turn-token-disabled')
    if ((Get-LastNotification).message -ne '工作已完成') { throw '停用 Token 統計後完成通知未保留一般完成內容。' }

    $benchmarkRows = @(
        [pscustomobject]@{ Case = 'A/D first success'; Queries = $realtimeDiagnostic.ccsessionsQueryCount; Retries = $realtimeDiagnostic.ccsessionsRetryCount; RetrySleepMs = $realtimeDiagnostic.ccsessionsRetrySleepMs; ForegroundMs = $realtimeDiagnostic.foregroundElapsedMs; Reason = $realtimeDiagnostic.usageResultReason }
        [pscustomobject]@{ Case = 'B second success'; Queries = $retryDiagnostic.ccsessionsQueryCount; Retries = $retryDiagnostic.ccsessionsRetryCount; RetrySleepMs = $retryDiagnostic.ccsessionsRetrySleepMs; ForegroundMs = $retryDiagnostic.foregroundElapsedMs; Reason = $retryDiagnostic.usageResultReason }
        [pscustomobject]@{ Case = 'C third success'; Queries = $thirdAttemptDiagnostic.ccsessionsQueryCount; Retries = $thirdAttemptDiagnostic.ccsessionsRetryCount; RetrySleepMs = $thirdAttemptDiagnostic.ccsessionsRetrySleepMs; ForegroundMs = $thirdAttemptDiagnostic.foregroundElapsedMs; Reason = $thirdAttemptDiagnostic.usageResultReason }
        [pscustomobject]@{ Case = 'E stale fallback'; Queries = $fallbackDiagnostic.ccsessionsQueryCount; Retries = $fallbackDiagnostic.ccsessionsRetryCount; RetrySleepMs = $fallbackDiagnostic.ccsessionsRetrySleepMs; ForegroundMs = $fallbackDiagnostic.foregroundElapsedMs; Reason = $fallbackDiagnostic.usageResultReason }
        [pscustomobject]@{ Case = 'F hung backend'; Queries = $hungDiagnostic.ccsessionsQueryCount; Retries = $hungDiagnostic.ccsessionsRetryCount; RetrySleepMs = $hungDiagnostic.ccsessionsRetrySleepMs; ForegroundMs = $hungDiagnostic.foregroundElapsedMs; Reason = $hungDiagnostic.usageResultReason }
        [pscustomobject]@{ Case = 'G fatal error'; Queries = $nonretryableDiagnostic.ccsessionsQueryCount; Retries = $nonretryableDiagnostic.ccsessionsRetryCount; RetrySleepMs = $nonretryableDiagnostic.ccsessionsRetrySleepMs; ForegroundMs = $nonretryableDiagnostic.foregroundElapsedMs; Reason = $nonretryableDiagnostic.usageResultReason }
    )
    Write-Host ($benchmarkRows | Format-Table -AutoSize | Out-String)
    Write-Host 'Windows notification and token usage integration tests passed.'
} finally {
    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_TEST_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_TEST_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_NATIVE_TOAST_TEST_RESULT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_FALLBACK_TEST_RESULT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_HOOK_LOG_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_SNAPSHOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_RETRY_FAILURE_COUNT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_NONRETRYABLE -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_HANG -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_HANG_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_FAIL -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
