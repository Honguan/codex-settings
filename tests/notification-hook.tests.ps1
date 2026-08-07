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

function Set-Snapshot([string]$SessionId, [long]$InputTokens, [long]$CachedInputTokens, [long]$CacheWriteTokens, [long]$OutputTokens, [long]$TotalTokens, [decimal]$CostUsd, [string[]]$Models = @('gpt-5.6-sol'), [switch]$WithoutCost) {
    $value = [ordered]@{ success = $true; sessionId = $SessionId; models = $Models; inputTokens = $InputTokens; cachedInputTokens = $CachedInputTokens; cacheWriteTokens = $CacheWriteTokens; outputTokens = $OutputTokens; totalTokens = $TotalTokens }
    if (-not $WithoutCost) { $value.costUsd = $CostUsd }
    [IO.File]::WriteAllText($snapshotPath, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}

function Invoke-NotificationHook([string]$SessionId, [string]$TurnId, [hashtable]$AdditionalInput = @{}, [string]$RawInput, [string]$Type = 'Completed', [string]$LastMessage = '') {
    $inputObject = [ordered]@{ session_id = $SessionId; turn_id = $TurnId; cwd = Join-Path $projectRoot 'src'; hook_event_name = 'Stop'; stop_hook_active = $false; last_assistant_message = $LastMessage }
    foreach ($property in $AdditionalInput.GetEnumerator()) { $inputObject[$property.Key] = $property.Value }
    $inputText = if ([string]::IsNullOrWhiteSpace($RawInput)) { $inputObject | ConvertTo-Json -Depth 8 -Compress } else { $RawInput }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $hookScript, '-Type', $Type)) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Write($inputText)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
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
    if (@($hooksTemplate.hooks.Stop).Count -ne 1) { throw 'Stop Hook 必須只保留一個完成通知 Hook。' }
    $stopCommand = $hooksTemplate.hooks.Stop[0].hooks[0]
    if (($stopCommand | ConvertTo-Json -Compress) -notmatch 'show-codex-notification\.ps1' -or $stopCommand.timeout -ne 30 -or $stopCommand.PSObject.Properties.Name -contains 'statusMessage') {
        throw 'Stop 完成通知 Hook 設定錯誤。'
    }
    $notificationSource = Get-Content -LiteralPath $hookScript -Raw
    $notificationBytes = [IO.File]::ReadAllBytes($hookScript)
    if ($notificationBytes.Length -lt 3 -or $notificationBytes[0] -ne 0xEF -or $notificationBytes[1] -ne 0xBB -or $notificationBytes[2] -ne 0xBF) { throw '通知腳本必須使用 UTF-8 BOM，以便 Windows PowerShell 5.1 正確解析。' }
    foreach ($expected in @('duration="long"', 'scenario="urgent"', 'ConvertTo-ToastVisualXml', '<group>', 'hint-align="right"', 'hint-maxLines="1"', 'ToastNotificationPriority', 'ExpirationTime', 'WindowStyle =', 'UseShellExecute = $false', 'CreateNoWindow = $true', 'RedirectStandardInput', 'RedirectStandardOutput', 'RedirectStandardError', 'ToastLifetimeSeconds = 60', 'PreviousToastLifetimeSeconds = 60', 'Start-Sleep -Seconds $DelaySeconds', 'active-toast.json', 'History.Remove', 'powershell.exe', 'NativeToast', 'Invoke-WithNamedMutex')) {
        if ($notificationSource -notmatch [regex]::Escape($expected)) { throw "Toast 設定缺少：$expected" }
    }

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $mockContent = @'
param([string]$SessionId)
if ($env:CODEX_SETTINGS_CCSESSIONS_FAIL -eq '1') {
    Write-Output 'usage not ready'
    exit 0
}
if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER) -and -not (Test-Path -LiteralPath $env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER)) {
    [IO.File]::WriteAllText($env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER, 'first attempt')
    Write-Output 'usage not ready'
    exit 0
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

    $sessionRealtime = '019fd65b-39b0-7d60-99fc-deb094690001'
    Set-Snapshot -SessionId $sessionRealtime -InputTokens 999000 -CachedInputTokens 888000 -CacheWriteTokens 777000 -OutputTokens 666000 -TotalTokens 3330000 -CostUsd 9.99
    [void](Invoke-NotificationHook -SessionId $sessionRealtime -TurnId 'turn-realtime' -AdditionalInput @{
        last_token_usage = [ordered]@{ input_tokens = 4321; cached_input_tokens = 1234; cache_write_input_tokens = 345; output_tokens = 567; reasoning_output_tokens = 89; total_tokens = 6567 }
    })
    $realtimeNotification = Get-LastNotification
    foreach ($expected in @('Input           4.32K', 'Output          567', 'Cache read      1.23K', 'Cache write     345', 'Total           6.57K', 'Cache hit rate  20.92%', 'Cost            N/A', 'Estimated usage N/A', 'Model           N/A')) {
        if (-not $realtimeNotification.message.Contains($expected)) { throw "即時 Token 用量未正確整合到完成通知：$expected" }
    }
    if (@($realtimeNotification.message -split '\r?\n').Count -ne 5 -or $realtimeNotification.title -ne 'Codex 任務完成') { throw '完成通知不是固定五行格式。' }
    $realtimeDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot ($sessionRealtime + '.log')) -Raw | ConvertFrom-Json
    foreach ($field in @('timestamp', 'hookSource', 'hookCommand', 'processId', 'parentProcessId', 'startTime', 'endTime', 'elapsedMs', 'exitCode', 'GlobalStopHookCount', 'EffectiveStopHookCount', 'NotificationInvocationCount', 'CrlfInvocationCount')) {
        if ($realtimeDiagnostic.PSObject.Properties.Name -notcontains $field) { throw "通知診斷缺少欄位：$field" }
    }
    if ($realtimeDiagnostic.handler -ne 'windows-notification' -or $realtimeDiagnostic.result -ne 'success' -or $realtimeDiagnostic.details -notmatch 'source=realtime' -or $realtimeDiagnostic.hookSource -ne 'global' -or $realtimeDiagnostic.NotificationInvocationCount -ne 1 -or $realtimeDiagnostic.CrlfInvocationCount -ne 0) {
        throw '整合後的完成通知沒有寫入可診斷的執行紀錄。'
    }

    $tokenStateCountBeforeQuestion = @(Get-ChildItem -LiteralPath $tokenRoot -Filter '*.json' | Where-Object Name -ne 'settings.json').Count
    [void](Invoke-NotificationHook -SessionId '019fd65b-39b0-7d60-99fc-deb094690010' -TurnId 'turn-question' -LastMessage '請確認是否繼續？')
    $questionNotification = Get-LastNotification
    if ($questionNotification.type -ne 'QuestionRequired' -or $questionNotification.title -ne 'Codex 等待你的回答' -or $questionNotification.message -ne '請回到 Codex 繼續') { throw 'Completed 問句未改為等待回答通知。' }
    if (@(Get-ChildItem -LiteralPath $tokenRoot -Filter '*.json' | Where-Object Name -ne 'settings.json').Count -ne $tokenStateCountBeforeQuestion) { throw '等待回答通知不應執行 Token 統計。' }

    [void](Invoke-NotificationHook -SessionId 'session-permission' -TurnId 'turn-permission' -Type PermissionRequired)
    [void](Invoke-NotificationHook -SessionId 'session-error' -TurnId 'turn-error' -Type Error)
    $events = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    if (@($events | Where-Object type -eq PermissionRequired).Count -ne 1 -or @($events | Where-Object type -eq Error).Count -ne 1) { throw '權限與錯誤通知未使用固定內容。' }
    if (@($events | Where-Object { $_.PSObject.Properties.Name -contains 'project' }).Count -ne 0) { throw '通知不應包含專案名稱欄位。' }

    $eventCountBeforeDuplicate = $events.Count
    [void](Invoke-NotificationHook -SessionId $sessionRealtime -TurnId 'turn-realtime')
    if (@(Get-Content -LiteralPath $logPath).Count -ne $eventCountBeforeDuplicate) { throw '相同 Session、turn 與類型未正確去重。' }
    $duplicateDiagnostic = @(Get-Content -LiteralPath (Join-Path $diagnosticRoot ($sessionRealtime + '.log')) | ForEach-Object { $_ | ConvertFrom-Json }) | Select-Object -Last 1
    if ($duplicateDiagnostic.result -ne 'deduplicated' -or $duplicateDiagnostic.NotificationInvocationCount -ne 2 -or $duplicateDiagnostic.EffectiveStopHookCount -ne 2) { throw '重複 Stop Hook 未在早期去重並記錄有效執行次數。' }

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
    foreach ($expected in @('Input           2.47K', 'Output          579', 'Cache read      1.36K', 'Total           4.65K')) {
        if (-not $fromTranscript.message.Contains($expected)) { throw "rollout token_count 未優先使用：$expected" }
    }

    $sessionMalformed = '019fd65b-39b0-7d60-99fc-deb094690004'
    $malformedInput = [ordered]@{
        session_id = $sessionMalformed
        turn_id = 'turn-malformed-message'
        cwd = $repositoryRoot
        transcript_path = $rolloutPath
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = '已刪除 "activity_config.php" 註解'
    } | ConvertTo-Json -Compress
    $malformedInput = $malformedInput.Replace('\"activity_config.php\"', '"activity_config.php"')
    [void](Invoke-NotificationHook -SessionId $sessionMalformed -TurnId 'turn-malformed-message' -RawInput $malformedInput)
    if ((Get-LastNotification).message -match 'Token 用量暫時無法取得' -or -not (Get-LastNotification).message.Contains('Input           2.47K')) {
        throw '含未跳脫引號的 Stop payload 未使用 rollout Token 用量。'
    }

    $sessionTruncated = '019fd65b-39b0-7d60-99fc-deb094690005'
    $truncatedInput = [ordered]@{
        session_id = $sessionTruncated
        turn_id = 'turn-truncated-message'
        cwd = $repositoryRoot
        transcript_path = $rolloutPath
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'unfinished'
    } | ConvertTo-Json -Compress
    $truncatedInput = $truncatedInput.Substring(0, $truncatedInput.IndexOf('unfinished') + 'unfinished'.Length)
    [void](Invoke-NotificationHook -SessionId $sessionTruncated -TurnId 'turn-truncated-message' -RawInput $truncatedInput)
    if ((Get-LastNotification).message -match 'Token 用量暫時無法取得' -or -not (Get-LastNotification).message.Contains('Input           2.47K')) {
        throw '截斷的 Stop payload 未使用 rollout Token 用量。'
    }

    $sessionRetry = '019fd65b-39b0-7d60-99fc-deb094690003'
    Set-Snapshot -SessionId $sessionRetry -InputTokens 8765 -CachedInputTokens 4321 -CacheWriteTokens 123 -OutputTokens 987 -TotalTokens 14073 -CostUsd 0.02
    $env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER = $retryMarkerPath
    [void](Invoke-NotificationHook -SessionId $sessionRetry -TurnId 'turn-retry')
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER
    if (-not (Test-Path -LiteralPath $retryMarkerPath) -or -not (Get-LastNotification).message.Contains('Input           8.77K')) { throw 'ccsessions 資料延遲時未重試一次。' }

    $sessionA = '019fd65b-39b0-7d60-99fc-deb09469413b'
    Set-Snapshot -SessionId $sessionA -InputTokens 120000 -CachedInputTokens 80000 -CacheWriteTokens 20000 -OutputTokens 12000 -TotalTokens 212000 -CostUsd 0.18
    [void](Invoke-NotificationHook -SessionId $sessionA -TurnId 'turn-1')
    $first = Get-LastNotification
    foreach ($expected in @('Session         69413b', 'Model           gpt-5.6-sol', 'Input           120K', 'Cache read      80K', 'Cache hit rate  36.36%', 'Cost            $0.18', 'Estimated usage 0.14%')) {
        if (-not $first.message.Contains($expected)) { throw "新 Session 第一輪缺少：$expected" }
    }
    $eventCountBeforeTokenDuplicate = @((Get-Content -LiteralPath $logPath)).Count
    [void](Invoke-NotificationHook -SessionId $sessionA -TurnId 'turn-1-duplicate')
    if (@((Get-Content -LiteralPath $logPath)).Count -ne $eventCountBeforeTokenDuplicate) { throw '相同用量 snapshot 被重複顯示。' }

    Set-Snapshot -SessionId $sessionA -InputTokens 145000 -CachedInputTokens 96000 -CacheWriteTokens 22000 -OutputTokens 15500 -TotalTokens 256500 -CostUsd 0.22 -Models @('gpt-5.6-sol', 'gpt-5.6-terra')
    [void](Invoke-NotificationHook -SessionId $sessionA -TurnId 'turn-2')
    $second = Get-LastNotification
    foreach ($expected in @('+25K', '+16K', '+3.5K', '+2K', '+44.5K', 'Cache hit rate  37.21%', '+$0.04', 'Estimated usage 0.03%', 'Model           gpt-5.6-sol')) {
        if (-not $second.message.Contains($expected)) { throw "第二輪差值缺少：$expected" }
    }
    if ($second.message.Contains('gpt-5.6-terra')) { throw '完成通知應只顯示第一個模型。' }

    $sessionB = '019fd65b-39b0-7d60-99fc-deb094699999'
    Set-Snapshot -SessionId $sessionB -InputTokens 10 -CachedInputTokens 2 -CacheWriteTokens 1 -OutputTokens 3 -TotalTokens 15 -CostUsd 0.001
    [void](Invoke-NotificationHook -SessionId $sessionB -TurnId 'turn-b1')
    $sessionNoCost = '019fd65b-39b0-7d60-99fc-deb094690998'
    Set-Snapshot -SessionId $sessionNoCost -InputTokens 20 -CachedInputTokens 4 -CacheWriteTokens 2 -OutputTokens 5 -TotalTokens 31 -CostUsd 0 -WithoutCost
    [void](Invoke-NotificationHook -SessionId $sessionNoCost -TurnId 'turn-no-cost')
    if ((Get-LastNotification).message -notmatch 'Cost            N/A' -or (Get-LastNotification).message -notmatch 'Estimated usage N/A') { throw '缺少成本欄位時不應顯示虛構的零成本。' }
    $sessionStates = @(Get-ChildItem -LiteralPath $tokenRoot -Filter '*.json' | Where-Object Name -ne 'settings.json')
    if ($sessionStates.Count -ne 8) { throw "多 Session 狀態檔數量錯誤：$($sessionStates.Count)" }

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
    if ($failureDiagnostic.result -ne 'success' -or $failureDiagnostic.details -notmatch 'tokenUsageError=.*ccsessions returned invalid JSON') { throw 'Token 統計原始錯誤未寫入診斷紀錄。' }

    $settingsPath = Join-Path $tokenRoot 'settings.json'
    $tokenSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $tokenSettings.enabled = $false
    [IO.File]::WriteAllText($settingsPath, ($tokenSettings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    [void](Invoke-NotificationHook -SessionId 'session-token-disabled' -TurnId 'turn-token-disabled')
    if ((Get-LastNotification).message -ne '工作已完成') { throw '停用 Token 統計後完成通知未保留一般完成內容。' }

    Write-Host 'Windows notification and token usage integration tests passed.'
} finally {
    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_TEST_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_TEST_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_HOOK_LOG_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_SNAPSHOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_FAIL -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
