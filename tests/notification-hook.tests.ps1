$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$hookScript = Join-Path $repositoryRoot 'src\templates\core\hooks\show-codex-notification.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-notification-' + [guid]::NewGuid().ToString('N'))
$notificationRoot = Join-Path $testRoot 'notifications'
$logPath = Join-Path $testRoot 'notifications.jsonl'
$diagnosticRoot = Join-Path $testRoot 'diagnostics'
$invocationRoot = Join-Path $testRoot 'invocations'

function Invoke-Notification([string]$Type, $InputObject, [switch]$AsArgument) {
    $payload = $InputObject | ConvertTo-Json -Depth 8 -Compress
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $hookScript, '-Type', $Type)) { [void]$startInfo.ArgumentList.Add($argument) }
    if ($AsArgument) { [void]$startInfo.ArgumentList.Add($payload) }
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($startInfo)
    if (-not $AsArgument) { $process.StandardInput.Write($payload) }
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or $stdout -ne '{}') { throw "通知 Hook 失敗：exit=$($process.ExitCode) stdout=$stdout stderr=$stderr" }
}

try {
    $source = [IO.File]::ReadAllText($hookScript)
    $bytes = [IO.File]::ReadAllBytes($hookScript)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { throw '通知腳本必須使用 UTF-8 BOM。' }
    foreach ($forbidden in @('ccsessions', 'CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT', 'Get-TokenUsageDisplay', 'Token 用量暫時無法取得', 'completed-token-toast')) {
        if ($source -match [regex]::Escape($forbidden)) { throw "現役通知 Hook 仍包含 Token 用量邏輯：$forbidden" }
    }

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:CODEX_SETTINGS_NOTIFICATION_STATE_ROOT = $notificationRoot
    $env:CODEX_SETTINGS_NOTIFICATION_TEST_MODE = '1'
    $env:CODEX_SETTINGS_NOTIFICATION_TEST_LOG = $logPath
    $env:CODEX_SETTINGS_HOOK_LOG_ROOT = $diagnosticRoot
    $env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT = $invocationRoot

    $completed = [ordered]@{ type = 'agent-turn-complete'; 'thread-id' = 'notification-session'; 'turn-id' = 'notification-turn'; cwd = $repositoryRoot; client = 'codex_vscode'; 'last-assistant-message' = 'done' }
    Invoke-Notification -Type Completed -InputObject $completed -AsArgument
    Invoke-Notification -Type Completed -InputObject $completed -AsArgument
    $taskCompleted = [ordered]@{ type = 'task_complete'; turn_id = 'task-complete-turn'; last_agent_message = 'done' }
    Invoke-Notification -Type Completed -InputObject $taskCompleted -AsArgument
    Invoke-Notification -Type Completed -InputObject $taskCompleted -AsArgument
    Invoke-Notification -Type Completed -InputObject ([ordered]@{ type = 'task_complete'; last_agent_message = 'missing identity' }) -AsArgument
    $permission = [ordered]@{ session_id = 'permission-session'; turn_id = 'permission-turn'; cwd = $repositoryRoot; hook_event_name = 'PermissionRequest' }
    Invoke-Notification -Type PermissionRequired -InputObject $permission

    $notifications = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    if (@($notifications | Where-Object type -eq 'Completed').Count -ne 2 -or @($notifications | Where-Object type -eq 'PermissionRequired').Count -ne 1) { throw '通知去重或類型保留失敗。' }
    $completedNotification = @($notifications | Where-Object type -eq 'Completed')[0]
    if ($completedNotification.title -ne 'Codex 任務完成' -or $completedNotification.message -ne '工作已完成') { throw '完成通知內容錯誤。' }
    $claim = Get-ChildItem -LiteralPath (Join-Path $notificationRoot 'claims') -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object type -eq 'Completed'
    if (@($claim).Count -ne 2 -or @($claim | Where-Object { $_.state -ne 'shown' -or $_.handlerId -ne 'completed-toast' }).Count -ne 0) { throw 'Completed 通知 Claim 錯誤。' }
    if (Test-Path -LiteralPath (Join-Path $testRoot 'token-usage')) { throw '現役通知 Hook 建立了 Token 使用量狀態。' }

    Write-Host 'Windows status notification tests passed.'
} finally {
    foreach ($name in @('CODEX_SETTINGS_NOTIFICATION_STATE_ROOT', 'CODEX_SETTINGS_NOTIFICATION_TEST_MODE', 'CODEX_SETTINGS_NOTIFICATION_TEST_LOG', 'CODEX_SETTINGS_HOOK_LOG_ROOT', 'CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT')) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
