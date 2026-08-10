$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-async-wait-' + [guid]::NewGuid().ToString('N'))
$globalRoot = Join-Path $testRoot '.codex'
$template = Get-LongRunningAsyncWaitPolicyTemplate -SourceRoot $script:ScriptRoot
$baseTemplate = [IO.File]::ReadAllText((Join-Path $script:ScriptRoot 'templates\core\AGENTS.md'))

try {
    if ($baseTemplate -match 'Long-running asynchronous work|write_stdin.*180000') { throw 'Optional async-wait policy leaked into the mandatory core AGENTS template.' }
    foreach ($required in @('write_stdin', 'yield_time_ms >= 180000', '300000', 'functions.wait', 'at least 30000 ms longer', 'non-empty', 'return early', 'Do not wake the model', 'short or synchronous', 'new Codex sessions/tasks', 'not guaranteed')) {
        if (-not $template.Contains($required)) { throw "Async-wait policy is missing: $required" }
    }

    $similarUserText = "# User notes`r`nUse a long wait for asynchronous work.`r`n"
    if ((Get-LongRunningAsyncWaitPolicyState -Content $similarUserText -ManagedContent $template).Status -ne 'NotInstalled') { throw 'Similar user text was incorrectly detected as installed.' }
    $installed = Set-LongRunningAsyncWaitPolicy -Content $similarUserText -ManagedContent $template -Action Install
    if ((Get-LongRunningAsyncWaitPolicyState -Content $installed -ManagedContent $template).Status -ne 'InstalledCurrent') { throw 'Installed policy was not detected.' }
    if ((Set-LongRunningAsyncWaitPolicy -Content $installed -ManagedContent $template -Action Install) -ne $installed) { throw 'Repeated policy installation is not idempotent.' }
    $outdated = $installed.Replace('prefer `300000`', 'prefer `240000`')
    if ((Get-LongRunningAsyncWaitPolicyState -Content $outdated -ManagedContent $template).Status -ne 'InstalledNeedsUpdate') { throw 'Outdated policy was not detected.' }
    if ((Get-LongRunningAsyncWaitPolicyState -Content (Set-LongRunningAsyncWaitPolicy -Content $outdated -ManagedContent $template -Action Install) -ManagedContent $template).Status -ne 'InstalledCurrent') { throw 'Outdated policy was not updated.' }
    $conflict = $installed + $script:LongRunningAsyncWaitPolicyStartMarker
    if ((Get-LongRunningAsyncWaitPolicyState -Content $conflict -ManagedContent $template).Status -ne 'Conflict') { throw 'Conflicting markers were not detected.' }

    $script:PromptAnswers = [Collections.Queue]::new()
    function Read-Host([string]$Prompt) { if ($script:PromptAnswers.Count -eq 0) { return '' }; return [string]$script:PromptAnswers.Dequeue() }
    New-Item -ItemType Directory -Path $globalRoot -Force | Out-Null
    if ((Select-LongRunningAsyncWaitPolicy -Root $globalRoot -SourceRoot $script:ScriptRoot) -ne 'Install') { throw 'Fresh blank prompt did not default to Install.' }
    $script:PromptAnswers.Enqueue('n')
    if ((Select-LongRunningAsyncWaitPolicy -Root $globalRoot -SourceRoot $script:ScriptRoot) -ne 'SkipNotInstalled') { throw 'Fresh explicit n did not skip installation.' }

    $agentsPath = Join-Path $globalRoot 'AGENTS.md'
    $userContent = "# User Custom Rules`r`n`r`n- Preserve this line.`r`n`r`n<!-- >>> OTHER-MANAGED >>>`r`nother setting`r`n<!-- <<< OTHER-MANAGED <<< -->`r`n"
    [IO.File]::WriteAllText($agentsPath, $userContent, [Text.UTF8Encoding]::new($false))
    $target = New-InstallTarget -Id test-global -Mode Global -Root $globalRoot -TemplateRoot (Join-Path $script:ScriptRoot 'templates\core') -EnvironmentTemplateRoot (Join-Path $script:ScriptRoot 'templates\environments\git') -DevelopmentEnvironment Git -InstallWindowsNotifications $false -LongRunningAsyncWaitAction Install -SourceRoot $script:ScriptRoot
    $installTransaction = New-FileTransaction -Root (Join-Path $testRoot 'install') -Mode AsyncWaitInstall
    [void](Invoke-TargetInstallation -Target $target -Transaction $installTransaction)
    Complete-FileTransaction $installTransaction
    $firstInstall = [IO.File]::ReadAllText($agentsPath)
    if ([regex]::Matches($firstInstall, [regex]::Escape($script:LongRunningAsyncWaitPolicyStartMarker)).Count -ne 1 -or -not $firstInstall.Contains('Preserve this line.') -or -not $firstInstall.Contains('OTHER-MANAGED')) { throw 'Install did not preserve user/other managed content or created duplicate blocks.' }
    $repeatTransaction = New-FileTransaction -Root (Join-Path $testRoot 'repeat') -Mode AsyncWaitRepeat
    $repeatResult = Invoke-TargetInstallation -Target $target -Transaction $repeatTransaction
    Complete-FileTransaction $repeatTransaction
    $repeatAgents = @($repeatResult.Files | Where-Object Path -eq 'AGENTS.md')[0]
    if ($repeatAgents.Changed -or [IO.File]::ReadAllText($agentsPath) -cne $firstInstall) { throw 'Installed current policy rewrote AGENTS.md.' }

    $script:PromptAnswers.Enqueue('')
    if ((Select-LongRunningAsyncWaitPolicy -Root $globalRoot -SourceRoot $script:ScriptRoot) -ne 'KeepCurrent') { throw 'Installed blank prompt did not default to keep/update.' }
    $script:PromptAnswers.Enqueue('n')
    if ((Select-LongRunningAsyncWaitPolicy -Root $globalRoot -SourceRoot $script:ScriptRoot) -ne 'Uninstall') { throw 'Installed No did not select uninstall.' }
    $removeTarget = $target.PSObject.Copy(); $removeTarget.LongRunningAsyncWaitAction = 'Uninstall'
    $removeTransaction = New-FileTransaction -Root (Join-Path $testRoot 'remove') -Mode AsyncWaitRemove
    [void](Invoke-TargetInstallation -Target $removeTarget -Transaction $removeTransaction)
    Complete-FileTransaction $removeTransaction
    $removed = [IO.File]::ReadAllText($agentsPath)
    if ((Get-LongRunningAsyncWaitPolicyState -Content $removed -ManagedContent $template).Status -ne 'NotInstalled' -or -not $removed.Contains('Preserve this line.') -or -not $removed.Contains('OTHER-MANAGED') -or -not $removed.Contains('# Communication')) { throw 'Remove changed base, user, or other managed AGENTS content.' }

    $reinstallTransaction = New-FileTransaction -Root (Join-Path $testRoot 'reinstall') -Mode AsyncWaitReinstall
    [void](Invoke-TargetInstallation -Target $target -Transaction $reinstallTransaction)
    Complete-FileTransaction $reinstallTransaction
    $reinstalled = [IO.File]::ReadAllText($agentsPath)
    if ([regex]::Matches($reinstalled, [regex]::Escape($script:LongRunningAsyncWaitPolicyStartMarker)).Count -ne 1) { throw 'Reinstall did not produce exactly one block.' }

    $beforeRollback = [IO.File]::ReadAllText($agentsPath)
    $rollbackTarget = $target.PSObject.Copy(); $rollbackTarget.LongRunningAsyncWaitAction = 'Uninstall'
    $rollbackTransaction = New-FileTransaction -Root (Join-Path $testRoot 'rollback') -Mode AsyncWaitRollback
    [void](Invoke-TargetInstallation -Target $rollbackTarget -Transaction $rollbackTransaction)
    Undo-FileTransaction $rollbackTransaction | Out-Null
    if ([IO.File]::ReadAllText($agentsPath) -cne $beforeRollback) { throw 'Transaction rollback did not restore the exact AGENTS content.' }

    $ownership = New-InstallationOwnershipManifest -LongRunningAsyncWaitAction Install
    if ($ownership.otherSettings.longRunningAsyncWait.Category -ne 'Other Settings' -or $ownership.otherSettings.longRunningAsyncWait.ManagedPaths -notcontains 'AGENTS.md') { throw 'Manifest ownership does not represent the setting independently.' }

    $trace = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\async-wait-rollout.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $beforeWakeups = @($trace | Where-Object { $_.phase -eq 'before' -and $_.result -eq 'still-running' -and $_.modelResumed }).Count
    $afterWakeups = @($trace | Where-Object { $_.phase -eq 'after' -and $_.result -eq 'still-running' -and $_.modelResumed }).Count
    $wait = @($trace | Where-Object { $_.phase -eq 'after' -and $_.tool -eq 'functions.wait' })[0]
    $exec = @($trace | Where-Object { $_.phase -eq 'after' -and $_.tool -eq 'functions.exec' })[0]
    $interactive = @($trace | Where-Object { $_.phase -eq 'after' -and $_.tool -eq 'write_stdin' -and $_.interactive })[0]
    $emptyPoll = @($trace | Where-Object { $_.phase -eq 'after' -and $_.tool -eq 'write_stdin' -and -not $_.interactive })[0]
    $short = @($trace | Where-Object { $_.phase -eq 'after' -and $_.tool -eq 'shell_command' })[0]
    $evidence = @($trace | Where-Object phase -eq 'evidence')[0]
    if ($beforeWakeups -le $afterWakeups -or [int]$wait.'yield_time_ms' -lt 180000 -or [int]$wait.actual_elapsed_ms -ge [int]$wait.'yield_time_ms' -or [string]$emptyPoll.chars -ne '' -or [int]$emptyPoll.'yield_time_ms' -ne 300000 -or [int]$emptyPoll.actual_elapsed_ms -ge [int]$emptyPoll.'yield_time_ms' -or [int]$exec.outer_yield_time_ms -lt ([int]$exec.nested_wait_ms + 30000) -or [string]::IsNullOrEmpty([string]$interactive.chars) -or [int]$interactive.'yield_time_ms' -ge 180000 -or [bool]$short.policyApplied -or [int]$evidence.before_below_180000 -ne [int]$evidence.before_wait_calls -or [int]$evidence.after_wait_calls -ne 2 -or [int]$evidence.after_below_180000 -ne 0 -or [int]$evidence.wait_actual_elapsed_ms -ge [int]$evidence.wait_requested_ms -or [int]$evidence.outer_exec_actual_elapsed_ms -ge [int]$evidence.outer_exec_requested_ms -or $evidence.token_comparison -ne 'not-comparable') { throw 'Sanitized rollout regression evidence does not satisfy the async-wait policy.' }
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'Async-wait policy tests passed.'
