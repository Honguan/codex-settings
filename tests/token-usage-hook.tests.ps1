$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$hookScript = Join-Path $repositoryRoot 'src\templates\core\hooks\show-turn-token-usage.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-token-usage-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $testRoot 'state'
$diagnosticRoot = Join-Path $testRoot 'logs'
$snapshotPath = Join-Path $testRoot 'snapshot.json'
$rolloutPath = Join-Path $testRoot 'rollout.jsonl'
$mockPath = Join-Path $testRoot 'mock-ccsessions.ps1'
$retryMarkerPath = Join-Path $testRoot 'retry.marker'

function Set-Snapshot([string]$SessionId, [long]$InputTokens, [long]$CachedInputTokens, [long]$CacheWriteTokens, [long]$OutputTokens, [long]$TotalTokens, [decimal]$CostUsd, [string[]]$Models = @('gpt-5.6-sol')) {
    $value = [ordered]@{ success = $true; sessionId = $SessionId; models = $Models; inputTokens = $InputTokens; cachedInputTokens = $CachedInputTokens; cacheWriteTokens = $CacheWriteTokens; outputTokens = $OutputTokens; totalTokens = $TotalTokens; costUsd = $CostUsd }
    [IO.File]::WriteAllText($snapshotPath, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}

function Invoke-TokenHook([string]$SessionId, [string]$TurnId, [hashtable]$AdditionalInput = @{}, [string]$RawInput) {
    $inputObject = [ordered]@{ session_id = $SessionId; turn_id = $TurnId; cwd = $repositoryRoot; hook_event_name = 'Stop'; stop_hook_active = $false }
    foreach ($property in $AdditionalInput.GetEnumerator()) { $inputObject[$property.Key] = $property.Value }
    $inputText = if ([string]::IsNullOrWhiteSpace($RawInput)) { $inputObject | ConvertTo-Json -Depth 8 -Compress } else { $RawInput }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $hookScript)) { $startInfo.ArgumentList.Add($argument) }
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
    if ($process.ExitCode -ne 0) { throw "Token Hook 失敗：exit=$($process.ExitCode) stderr=$stderr" }
    try { return $stdout | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Token Hook 輸出不是有效 JSON：$stdout" }
}

try {
    $hooksTemplate = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\templates\core\hooks.json') -Raw | ConvertFrom-Json
    $tokenHook = @($hooksTemplate.hooks.Stop | Where-Object { ($_.hooks | ConvertTo-Json -Depth 8 -Compress) -match 'show-turn-token-usage\.ps1' })[0]
    if ($null -eq $tokenHook -or $tokenHook.hooks[0].PSObject.Properties.Name -contains 'statusMessage') { throw 'Token Hook 不應持續顯示執行狀態。' }

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $mockContent = @'
param([string]$SessionId)
if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER) -and -not (Test-Path -LiteralPath $env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER)) {
    [IO.File]::WriteAllText($env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER, 'first attempt')
    Write-Output 'usage not ready'
    exit 0
}
Get-Content -LiteralPath $env:CODEX_SETTINGS_CCSESSIONS_SNAPSHOT -Raw
'@
    [IO.File]::WriteAllText($mockPath, $mockContent, [Text.UTF8Encoding]::new($false))
    $env:CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT = $stateRoot
    $env:CODEX_SETTINGS_HOOK_LOG_ROOT = $diagnosticRoot
    $env:CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND = $mockPath
    $env:CODEX_SETTINGS_CCSESSIONS_SNAPSHOT = $snapshotPath

    $sessionRealtime = '019fd65b-39b0-7d60-99fc-deb094690001'
    Set-Snapshot -SessionId $sessionRealtime -InputTokens 999000 -CachedInputTokens 888000 -CacheWriteTokens 777000 -OutputTokens 666000 -TotalTokens 3330000 -CostUsd 9.99
    $realtime = Invoke-TokenHook -SessionId $sessionRealtime -TurnId 'turn-realtime' -AdditionalInput @{
        last_token_usage = [ordered]@{ input_tokens = 4321; cached_input_tokens = 1234; cache_write_input_tokens = 345; output_tokens = 567; reasoning_output_tokens = 89; total_tokens = 6567 }
    }
    foreach ($expected in @('Input           4.32K', 'Output          567', 'Cache           1.23K', 'Total           6.57K')) {
        if (-not $realtime.systemMessage.Contains($expected)) { throw "Stop payload 即時 Token 未優先使用：$expected" }
    }
    if ($realtime.PSObject.Properties.Name -contains 'decision' -or -not $realtime.systemMessage.Contains('Input           4.32K')) {
        throw 'Token Hook 未透過 Stop systemMessage 顯示使用率。'
    }
    $realtimeDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot ($sessionRealtime + '.log')) -Raw | ConvertFrom-Json
    if ($realtimeDiagnostic.event -ne 'Stop' -or $realtimeDiagnostic.handler -ne 'turn-token-usage' -or $realtimeDiagnostic.result -ne 'success' -or $realtimeDiagnostic.details -notmatch 'source=realtime') {
        throw 'Token Hook 未寫入可診斷的執行紀錄。'
    }

    $sessionActive = '019fd65b-39b0-7d60-99fc-deb094690000'
    Set-Snapshot -SessionId $sessionActive -InputTokens 100 -CachedInputTokens 20 -CacheWriteTokens 0 -OutputTokens 10 -TotalTokens 110 -CostUsd 0
    $activeStop = Invoke-TokenHook -SessionId $sessionActive -TurnId 'turn-active' -AdditionalInput @{
        stop_hook_active = $true
        last_token_usage = [ordered]@{ input_tokens = 100; cached_input_tokens = 20; cache_write_input_tokens = 0; output_tokens = 10; reasoning_output_tokens = 0; total_tokens = 110 }
    }
    if (@($activeStop.PSObject.Properties).Count -ne 0) { throw 'Token Hook 在已啟用的 Stop 流程中再次顯示內容。' }

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
    $fromTranscript = Invoke-TokenHook -SessionId $sessionTranscript -TurnId 'turn-transcript' -AdditionalInput @{ transcript_path = $rolloutPath }
    foreach ($expected in @('Input           2.47K', 'Output          579', 'Cache           1.36K', 'Total           4.65K')) {
        if (-not $fromTranscript.systemMessage.Contains($expected)) { throw "rollout token_count 未優先使用：$expected" }
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
    $fromMalformedInput = Invoke-TokenHook -SessionId $sessionMalformed -TurnId 'turn-malformed-message' -RawInput $malformedInput
    if ([string]$fromMalformedInput.systemMessage -match 'Token usage unavailable' -or -not $fromMalformedInput.systemMessage.Contains('Input           2.47K')) {
        throw 'Stop payload 的 last_assistant_message 含未跳脫引號時，未顯示 rollout 使用率。'
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
    $fromTruncatedInput = Invoke-TokenHook -SessionId $sessionTruncated -TurnId 'turn-truncated-message' -RawInput $truncatedInput
    if ([string]$fromTruncatedInput.systemMessage -match 'Token usage unavailable' -or -not $fromTruncatedInput.systemMessage.Contains('Input           2.47K')) {
        throw '截斷的 Stop payload 未使用 rollout 顯示 Token 使用率。'
    }

    $sessionRetry = '019fd65b-39b0-7d60-99fc-deb094690003'
    Set-Snapshot -SessionId $sessionRetry -InputTokens 8765 -CachedInputTokens 4321 -CacheWriteTokens 123 -OutputTokens 987 -TotalTokens 14073 -CostUsd 0.02
    $env:CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER = $retryMarkerPath
    $retried = Invoke-TokenHook -SessionId $sessionRetry -TurnId 'turn-retry'
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER
    if (-not (Test-Path -LiteralPath $retryMarkerPath) -or -not $retried.systemMessage.Contains('Input           8.77K')) { throw 'ccsessions 資料延遲時未重試一次。' }

    $sessionA = '019fd65b-39b0-7d60-99fc-deb09469413b'
    Set-Snapshot -SessionId $sessionA -InputTokens 120000 -CachedInputTokens 80000 -CacheWriteTokens 20000 -OutputTokens 12000 -TotalTokens 212000 -CostUsd 0.18
    $first = Invoke-TokenHook -SessionId $sessionA -TurnId 'turn-1'
    foreach ($expected in @('Token usage since session start', 'Input           120K', 'Cache           80K', 'Cache hit rate  36.36%', 'Estimated usage 0.14%', '019fd65b...69413b')) {
        if (-not $first.systemMessage.Contains($expected)) { throw "新 Session 第一輪缺少：$expected" }
    }
    $orderedLabels = @('Session', 'Model', 'Input', 'Output', 'Cache', 'Total', 'Cache hit rate', 'Cost', 'Estimated usage')
    $previousIndex = -1
    foreach ($label in $orderedLabels) {
        $index = $first.systemMessage.IndexOf($label, [StringComparison]::Ordinal)
        if ($index -le $previousIndex) { throw "Token 顯示順序錯誤：$label" }
        $previousIndex = $index
    }

    $duplicate = Invoke-TokenHook -SessionId $sessionA -TurnId 'turn-1-duplicate'
    if (@($duplicate.PSObject.Properties).Count -ne 0) { throw '相同用量 snapshot 被重複顯示。' }

    Set-Snapshot -SessionId $sessionA -InputTokens 145000 -CachedInputTokens 96000 -CacheWriteTokens 22000 -OutputTokens 15500 -TotalTokens 256500 -CostUsd 0.22 -Models @('gpt-5.6-sol', 'gpt-5.6-terra')
    $second = Invoke-TokenHook -SessionId $sessionA -TurnId 'turn-2'
    foreach ($expected in @('Turn token usage', '+25K', '+16K', '+3.5K', '+44.5K', 'Cache hit rate  37.21%', '+$0.04', 'Estimated usage 0.03%', 'gpt-5.6-sol, gpt-5.6-terra')) {
        if (-not $second.systemMessage.Contains($expected)) { throw "第二輪差值缺少：$expected" }
    }

    $sessionB = '019fd65b-39b0-7d60-99fc-deb094699999'
    Set-Snapshot -SessionId $sessionB -InputTokens 10 -CachedInputTokens 2 -CacheWriteTokens 1 -OutputTokens 3 -TotalTokens 15 -CostUsd 0.001
    $other = Invoke-TokenHook -SessionId $sessionB -TurnId 'turn-b1'
    if ($other.systemMessage -notmatch 'Token usage since session start') { throw '不同 Session 未使用獨立基準。' }
    $sessionStates = @(Get-ChildItem -LiteralPath $stateRoot -Filter '*.json' | Where-Object Name -ne 'settings.json')
    if ($sessionStates.Count -ne 7) { throw "多 Session 狀態檔數量錯誤：$($sessionStates.Count)" }

    $stateA = @($sessionStates | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).sessionId -eq $sessionA })[0]
    [IO.File]::WriteAllText($stateA.FullName, '{invalid', [Text.UTF8Encoding]::new($false))
    Set-Snapshot -SessionId $sessionA -InputTokens 150000 -CachedInputTokens 97000 -CacheWriteTokens 22500 -OutputTokens 16000 -TotalTokens 263000 -CostUsd 0.23
    $rebuilt = Invoke-TokenHook -SessionId $sessionA -TurnId 'turn-3'
    if ($rebuilt.systemMessage -notmatch 'Token usage since session start' -or @(Get-ChildItem -LiteralPath $stateRoot -Filter '*.corrupt-*').Count -ne 1) { throw '損壞狀態未備份並重建。' }

    $settingsPath = Join-Path $stateRoot 'settings.json'
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $settings.enabled = $false
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $disabled = Invoke-TokenHook -SessionId $sessionA -TurnId 'turn-4'
    if (@($disabled.PSObject.Properties).Count -ne 0) { throw '停用 Token 統計後仍顯示內容。' }

    Write-Host 'Turn token usage hook tests passed.'
} finally {
    Remove-Item Env:\CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_HOOK_LOG_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_SNAPSHOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_RETRY_MARKER -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
