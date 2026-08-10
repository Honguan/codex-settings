$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$hookScript = Join-Path $repositoryRoot 'src\templates\core\hooks\show-codex-notification.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-finality-' + [guid]::NewGuid().ToString('N'))
$notificationRoot = Join-Path $testRoot 'notifications'
$tokenRoot = Join-Path $testRoot 'token'
$logPath = Join-Path $testRoot 'notifications.jsonl'
$diagnosticRoot = Join-Path $testRoot 'diagnostics'
$invocationRoot = Join-Path $testRoot 'invocations'

function Invoke-CompletedNotification([string]$Payload, [switch]$AsArgument, [string]$Type = 'Completed') {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $hookScript, '-Type', $Type)) { $startInfo.ArgumentList.Add($argument) }
    if ($AsArgument) { $startInfo.ArgumentList.Add($Payload) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    if (-not $AsArgument) { $process.StandardInput.Write($Payload) }
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or $stdout -ne '{}') { throw "Completed notification failed: exit=$($process.ExitCode) stdout=$stdout stderr=$stderr" }
}

try {
    New-Item -ItemType Directory -Path $notificationRoot, $tokenRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $tokenRoot 'settings.json'), '{"enabled":false,"showAfterEachTurn":false,"mainSessionOnly":true}', [Text.UTF8Encoding]::new($false))
    $env:CODEX_SETTINGS_NOTIFICATION_STATE_ROOT = $notificationRoot
    $env:CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT = $tokenRoot
    $env:CODEX_SETTINGS_NOTIFICATION_TEST_MODE = '1'
    $env:CODEX_SETTINGS_NOTIFICATION_TEST_LOG = $logPath
    $env:CODEX_SETTINGS_HOOK_LOG_ROOT = $diagnosticRoot
    $env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT = $invocationRoot

    $stop = @{ session_id = 'session-finality'; turn_id = 'turn-finality'; cwd = $repositoryRoot; hook_event_name = 'Stop'; stop_hook_active = $false; last_assistant_message = 'intermediate' } | ConvertTo-Json -Compress
    Invoke-CompletedNotification -Payload $stop
    if (Test-Path -LiteralPath $logPath) { throw 'Generic Stop produced a premature Completed notification.' }
    if (Test-Path -LiteralPath (Join-Path $notificationRoot 'claims')) { throw 'Non-final Stop consumed a Completed claim.' }
    $stopDiagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot 'session-finality.log') -Raw | ConvertFrom-Json
    if ($stopDiagnostic.completionClassification -ne 'IntermediateStop' -or $stopDiagnostic.completionEvidence -ne 'generic-stop-not-final' -or $stopDiagnostic.claimAttempted -or $stopDiagnostic.resultReason -ne 'skipped-non-final') { throw 'Non-final Stop diagnostic is incomplete.' }

    foreach ($payload in @(
        (@{ type = 'contextCompaction'; 'thread-id' = 'session-compaction'; 'turn-id' = 'turn-compaction'; last_token_usage = @{ total_tokens = 999 } } | ConvertTo-Json -Compress),
        (@{ hook_event_name = 'PostCompact'; session_id = 'session-compaction'; turn_id = 'turn-compaction'; trigger = 'auto' } | ConvertTo-Json -Compress),
        (@{ type = 'agent-turn-complete'; 'thread-id' = 'session-aborted'; 'turn-id' = 'turn-aborted'; status = 'aborted' } | ConvertTo-Json -Compress),
        (@{ type = 'agent-turn-complete'; 'thread-id' = 'session-subagent'; 'turn-id' = 'turn-subagent'; parent_session_id = 'session-parent' } | ConvertTo-Json -Compress),
        (@{ type = 'task_complete'; turn_id = 'turn-background-task'; last_agent_message = 'background task done' } | ConvertTo-Json -Compress),
        (@{ type = 'unknown-lifecycle'; session_id = 'session-unknown'; turn_id = 'turn-unknown' } | ConvertTo-Json -Compress)
    )) { Invoke-CompletedNotification -Payload $payload -AsArgument }
    if (Test-Path -LiteralPath $logPath) { throw 'Compaction, aborted, subagent, task completion, or unknown finality produced a Completed notification.' }

    $completed = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\codex-notify-agent-turn-complete.json') -Raw
    $completed = $completed.Replace('019fe798-1ecb-7221-b31d-2f2d3280a361', 'session-finality').Replace('019fe798-turn-1', 'turn-finality')
    Invoke-CompletedNotification -Payload $completed -AsArgument
    Invoke-CompletedNotification -Payload $completed -AsArgument
    $notifications = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    if ($notifications.Count -ne 1 -or $notifications[0].type -ne 'Completed') { throw 'Canonical final completion did not produce exactly one notification.' }

    $permission = @{ session_id = 'session-permission'; turn_id = 'turn-permission'; cwd = $repositoryRoot; hook_event_name = 'PermissionRequest'; tool_name = 'Bash' } | ConvertTo-Json -Compress
    $question = @{ session_id = 'session-question'; turn_id = 'turn-question'; cwd = $repositoryRoot; hook_event_name = 'PreToolUse'; tool_name = 'request_user_input' } | ConvertTo-Json -Compress
    Invoke-CompletedNotification -Payload $permission -Type PermissionRequired
    Invoke-CompletedNotification -Payload $question -Type QuestionRequired
    $notifications = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    if (@($notifications | Where-Object type -eq 'PermissionRequired').Count -ne 1 -or @($notifications | Where-Object type -eq 'QuestionRequired').Count -ne 1) { throw 'PermissionRequired or QuestionRequired was incorrectly finality-gated.' }
} finally {
    foreach ($name in @('CODEX_SETTINGS_NOTIFICATION_STATE_ROOT', 'CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT', 'CODEX_SETTINGS_NOTIFICATION_TEST_MODE', 'CODEX_SETTINGS_NOTIFICATION_TEST_LOG', 'CODEX_SETTINGS_HOOK_LOG_ROOT', 'CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT')) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'Notification finality tests passed.'
