$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$hookScript = Join-Path $repositoryRoot 'src\templates\core\hooks\show-codex-notification.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-notification-' + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $testRoot 'SampleProject'
$stateRoot = Join-Path $testRoot 'state'
$logPath = Join-Path $testRoot 'notifications.jsonl'

function Invoke-NotificationHook([string]$Type, [string]$EventName, [string]$TurnId, [string]$LastMessage = '') {
    $inputText = [ordered]@{
        session_id = 'session-a'
        turn_id = $TurnId
        cwd = Join-Path $projectRoot 'src'
        hook_event_name = $EventName
        last_assistant_message = $LastMessage
    } | ConvertTo-Json -Compress
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
}

try {
    New-Item -ItemType Directory -Path (Join-Path $projectRoot '.git'), (Join-Path $projectRoot 'src') -Force | Out-Null
    $env:CODEX_SETTINGS_NOTIFICATION_STATE_ROOT = $stateRoot
    $env:CODEX_SETTINGS_NOTIFICATION_TEST_MODE = '1'
    $env:CODEX_SETTINGS_NOTIFICATION_TEST_LOG = $logPath

    Invoke-NotificationHook -Type Completed -EventName Stop -TurnId 'turn-1' -LastMessage '工作完成。'
    Invoke-NotificationHook -Type Completed -EventName Stop -TurnId 'turn-1' -LastMessage '工作完成。'
    Invoke-NotificationHook -Type PermissionRequired -EventName PermissionRequest -TurnId 'turn-2'
    Invoke-NotificationHook -Type QuestionRequired -EventName PreToolUse -TurnId 'turn-3'
    Invoke-NotificationHook -Type Completed -EventName Stop -TurnId 'turn-4' -LastMessage '請確認是否繼續？'

    $events = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    if ($events.Count -ne 4) { throw "通知去重失敗：預期 4 筆，實際 $($events.Count) 筆。" }
    if (@($events | Where-Object type -eq Completed).Count -ne 1 -or @($events | Where-Object type -eq PermissionRequired).Count -ne 1 -or @($events | Where-Object type -eq QuestionRequired).Count -ne 2) { throw '通知類型分類錯誤。' }
    if (@($events | Where-Object project -ne 'SampleProject').Count -ne 0) { throw '通知未使用專案根目錄名稱。' }

    $settingsPath = Join-Path $stateRoot 'settings.json'
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $settings.completed = $false
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Invoke-NotificationHook -Type Completed -EventName Stop -TurnId 'turn-5' -LastMessage '再次完成。'
    if (@(Get-Content -LiteralPath $logPath).Count -ne 4) { throw '停用完成通知後仍產生通知。' }

    Write-Host 'Windows notification hook tests passed.'
} finally {
    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_TEST_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_TEST_LOG -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
