$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-global-environment-' + [guid]::NewGuid().ToString('N'))
$globalRoot = Join-Path $testRoot '.codex'

function Install-TestEnvironment([ValidateSet('Git', 'CVS')][string]$Environment, [bool]$InstallWindowsNotifications = $true, [string]$Cwd = '') {
    $transaction = New-FileTransaction -Root (Join-Path $testRoot ("transaction-$Environment-" + [guid]::NewGuid().ToString('N'))) -Mode "Test-$Environment"
    $target = [pscustomobject]@{
        Mode = 'Global'
        Template = Join-Path $script:ScriptRoot 'templates\core'
        EnvironmentTemplate = Join-Path $script:ScriptRoot ("templates\environments\{0}" -f $Environment.ToLowerInvariant())
        DevelopmentEnvironment = $Environment
        Root = $globalRoot
        Cwd = $Cwd
        EnableDefaultModeRequestUserInput = $false
        InstallWindowsNotifications = $InstallWindowsNotifications
    }
    $result = Invoke-TargetInstallation -Target $target -Transaction $transaction
    Save-InstallationManifest -Result $result -Transaction $transaction -External $null
    Complete-FileTransaction -Transaction $transaction
}

try {
    $installerSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'install.ps1') -Raw
    $runnerSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'installation\installation-runner.ps1') -Raw
    $installationSource = $installerSource + $runnerSource
    if ($installationSource -match 'Write-Warning\s+"已回復中斷的交易') {
        throw 'Installer startup must not render recovered transactions as a yellow warning.'
    }
    if ($installationSource -notmatch 'Write-Host\s+"已自動回復上次中斷的安裝交易') {
        throw 'Installer startup did not preserve a clear recovered-transaction status message.'
    }
    foreach ($managementScript in @('commands\restore-settings.ps1', 'commands\uninstall-settings.ps1')) {
        $managementSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot $managementScript) -Raw
        if ($managementSource -match 'Write-Warning\s+"已回復中斷的交易') {
            throw "Successful transaction recovery must not render as a yellow warning: $managementScript"
        }
        if ($managementSource -notmatch 'Write-Host\s+"已自動回復上次中斷的交易') {
            throw "Transaction recovery status message is missing: $managementScript"
        }
    }
    if ($installationSource -notmatch '完全關閉並重新啟動 VS Code、Codex 與 PowerShell') {
        throw 'Installer completion message did not require restarting existing Codex sessions before testing Hooks.'
    }

    if ((Get-DefaultDevelopmentEnvironment -Root $globalRoot) -ne 'Git') { throw 'First installation must default to Git.' }
    New-Item -ItemType Directory -Path $globalRoot -Force | Out-Null
    $existingHooks = [ordered]@{
        description = 'User hooks'
        hooks = [ordered]@{
            SessionStart = @(
                [ordered]@{
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = 'custom-session-start.ps1'
                        }
                    )
                }
            )
            Stop = @(
                [ordered]@{
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = 'pwsh -File ~/.codex/hooks/normalize-cvs-crlf.ps1'
                        },
                        [ordered]@{
                            type = 'command'
                            command = 'pwsh -Command "& { [void][Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(''CodexSettings'') } # C:\\old\\.codex\\hooks\\legacy-completion-notification.ps1"'
                        },
                        [ordered]@{
                            type = 'command'
                            command = 'pwsh -Command "& { [void][Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(''UserApp'') } # .codex/hooks/user-toast.ps1"'
                        }
                    )
                }
            )
        }
    }
    Write-JsonFileAtomic -Path (Join-Path $globalRoot 'hooks.json') -Value $existingHooks -Depth 10
    $obsoleteHookScript = Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $obsoleteHookScript) -Force | Out-Null
    [IO.File]::WriteAllText($obsoleteHookScript, '# obsolete hook', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $globalRoot 'hooks\legacy-completion-notification.ps1'), '# legacy notification', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $globalRoot 'hooks\user-toast.ps1'), '# user notification', [Text.UTF8Encoding]::new($false))
    $legacyAgents = [IO.File]::ReadAllText((Join-Path $script:ScriptRoot 'templates\core\AGENTS.md')).TrimEnd()
    $legacyAgents = $legacyAgents.Replace(
        '- Preserve existing architecture, coding style, naming, and structure unless current requirements change them.',
        '- Preserve existing architecture, coding style, naming, structure, and backward compatibility.'
    )
    $legacyAgents = [regex]::Replace($legacyAgents, '(?ms)^# Architecture\r?\n.*?(?=^# File Handling)', '')
    $legacyAgents += "`r`n`r`n# User Custom Rules`r`n`r`n- Preserve this custom rule.`r`n"
    [IO.File]::WriteAllText((Join-Path $globalRoot 'AGENTS.md'), $legacyAgents, [Text.UTF8Encoding]::new($false))
    $legacyRulesPath = Join-Path $globalRoot 'rules\default.rules'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacyRulesPath) -Force | Out-Null
    $legacyRules = [IO.File]::ReadAllText((Join-Path $script:ScriptRoot 'templates\core\rules\default.rules')).TrimEnd()
    $legacyRules = [regex]::Replace($legacyRules, '(?ms)^# 48\. Read-only file and path inspection\..*$', '').TrimEnd()
    $legacyRules += "`r`n`r`n" + [IO.File]::ReadAllText((Join-Path $script:ScriptRoot 'templates\environments\git\rules\default.rules')).Trim()
    $legacyRules += "`r`n`r`n# >>> CODEX-SETTINGS: >>>`r`n" + [IO.File]::ReadAllText((Join-Path $script:ScriptRoot 'templates\core\rules\default.rules')).Trim() + "`r`n# <<< CODEX-SETTINGS: <<<"
    $legacyRules += "`r`n`r`n# User custom rule`r`nprefix_rule(`r`n    pattern = [[`"custom-tool`"]],`r`n    decision = `"allow`",`r`n)`r`n"
    [IO.File]::WriteAllText($legacyRulesPath, $legacyRules + "`r`n", [Text.UTF8Encoding]::new($false))
    $legacyConfigPath = Join-Path $globalRoot 'config.toml'
    $legacyConfig = "user_custom_setting = true`r`n`r`n# >>> CODEX-SETTINGS: >>>`r`n"
    $legacyConfig += [IO.File]::ReadAllText((Join-Path $script:ScriptRoot 'templates\core\config.toml')).Trim()
    $legacyConfig += "`r`n# <<< CODEX-SETTINGS: <<<`r`n"
    [IO.File]::WriteAllText($legacyConfigPath, $legacyConfig, [Text.UTF8Encoding]::new($false))

    Install-TestEnvironment -Environment CVS
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    foreach ($heading in @('Communication', 'Code Changes', 'Architecture', 'File Handling', 'Validation')) {
        if ([regex]::Matches($agents, "(?m)^# $([regex]::Escape($heading))\s*$").Count -ne 1) { throw "Safe merge duplicated or omitted the AGENTS.md section: $heading" }
    }
    if ([regex]::Matches($agents, '(?m)^## Line endings\s*$').Count -ne 1 -or $agents -notmatch "Preserve each file's original CRLF or LF format\. Never introduce mixed line endings\.") { throw 'Global AGENTS.md line-ending instructions are missing or duplicated.' }
    if ($agents -notmatch '(?m)^# User Custom Rules\s*$') { throw 'Safe merge removed a custom AGENTS.md section.' }
    if ($agents -match 'and backward compatibility\.') { throw 'Safe merge did not update a legacy AGENTS.md section.' }
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.SessionStart).Count -ne 1) { throw 'CVS installation did not preserve the unmanaged user hook.' }
    if (@($installedHooks.hooks.Stop | ForEach-Object { @($_.hooks) } | Where-Object { (Get-HookEntryText -Entry $_) -match 'user-toast\.ps1' }).Count -ne 1) { throw 'CVS installation removed an unrelated user Toast Hook.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\legacy-completion-notification.ps1')) { throw 'CVS installation retained a legacy completion notification script.' }
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PostToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1) { throw 'CVS installation did not install one Track, Restore, and Finalize hook.' }
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PermissionRequest | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1) { throw 'CVS installation did not install one notification hook per supported event.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1')) { throw 'CVS installation retained an obsolete CRLF conversion script.' }
    if (-not (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\preserve-line-endings.ps1') -PathType Leaf)) { throw 'CVS installation omitted the line-ending protection script.' }
    $rules = Get-Content -LiteralPath $legacyRulesPath -Raw
    if ([regex]::Matches($rules, 'Block disk formatting\.').Count -ne 1 -or [regex]::Matches($rules, 'CVS project rules supplement').Count -ne 1 -or [regex]::Matches($rules, 'Git project rules supplement').Count -ne 0) {
        throw 'CVS installation did not replace legacy unmarked default.rules content without duplicates or conflicts.'
    }
    if ($rules -match '# >>> CODEX-SETTINGS: >>>|# <<< CODEX-SETTINGS: <<<') { throw 'CVS installation retained obsolete default.rules markers.' }
    if ([regex]::Matches($rules, '(?m)^# >>> CODEX-SETTINGS:Global:RULES >>>\s*$').Count -ne 1) { throw 'CVS installation did not write the scoped default.rules marker.' }
    if ($rules -notmatch 'pattern = \[\["custom-tool"\]\]') { throw 'CVS installation removed an unmanaged custom rule.' }
    $config = Get-Content -LiteralPath $legacyConfigPath -Raw
    if ($config -notmatch '(?m)^user_custom_setting = true\s*$') { throw 'CVS installation removed an unmanaged config.toml setting.' }
    if ($config -match '# >>> CODEX-SETTINGS: >>>|# <<< CODEX-SETTINGS: <<<' -or [regex]::Matches($config, '(?m)^# >>> CODEX-SETTINGS:Global:CONFIG >>>\s*$').Count -ne 1) {
        throw 'CVS installation did not replace the obsolete config.toml marker with a scoped marker.'
    }
    if ((Get-DefaultDevelopmentEnvironment -Root $globalRoot) -ne 'CVS') { throw 'CVS was not recorded as the default project system.' }

    $projectRoot = Join-Path $testRoot 'cvs-project'
    $projectCodex = Join-Path $projectRoot '.codex'
    New-Item -ItemType Directory -Path (Join-Path $projectRoot 'CVS'), (Join-Path $projectCodex 'hooks') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $projectRoot 'CVS\Entries'), '', [Text.Encoding]::ASCII)
    $projectHooks = [ordered]@{
        hooks = [ordered]@{
            Stop = @([ordered]@{ hooks = @(
                [ordered]@{ type = 'command'; command = 'pwsh -File .codex/hooks/show-codex-notification.ps1 -Type Completed' },
                [ordered]@{ type = 'command'; command = 'pwsh -File .codex/hooks/show-turn-token-usage.ps1' },
                [ordered]@{ type = 'command'; command = 'pwsh -Command "& { [void][Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(''CodexSettings'') } # C:\\old\\.codex\\hooks\\legacy-completion-notification.ps1"' },
                [ordered]@{ type = 'command'; command = 'pwsh -Command "& { [void][Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(''UserApp'') } # .codex/hooks/user-toast.ps1"' },
                [ordered]@{ type = 'command'; command = 'pwsh -File .codex/hooks/preserve-line-endings.ps1 -Mode Finalize' },
                [ordered]@{ type = 'command'; command = 'custom-project-stop.ps1' }
            ) })
            PostToolUse = @([ordered]@{ matcher = '*'; hooks = @(
                [ordered]@{ type = 'command'; command = 'pwsh -File .codex/hooks/preserve-line-endings.ps1 -Mode Restore' },
                [ordered]@{ type = 'command'; command = 'custom-project-post.ps1' }
            ) })
        }
    }
    Write-JsonFileAtomic -Path (Join-Path $projectCodex 'hooks.json') -Value $projectHooks -Depth 10
    foreach ($scriptName in @('crlf-updated-files.ps1', 'normalize-cvs-crlf.ps1', 'preserve-line-endings.ps1', 'show-turn-token-usage.ps1', 'show-codex-notification.ps1', 'legacy-completion-notification.ps1')) {
        [IO.File]::WriteAllText((Join-Path $projectCodex ("hooks\$scriptName")), '# managed legacy hook', [Text.UTF8Encoding]::new($false))
    }
    $customProjectScript = Join-Path $projectCodex 'hooks\custom-project-stop.ps1'
    [IO.File]::WriteAllText($customProjectScript, '# user custom hook', [Text.UTF8Encoding]::new($false))
    $customProjectToastScript = Join-Path $projectCodex 'hooks\user-toast.ps1'
    [IO.File]::WriteAllText($customProjectToastScript, '# user custom notification hook', [Text.UTF8Encoding]::new($false))
    Install-TestEnvironment -Environment CVS -Cwd $projectRoot
    $projectHooksAfter = Get-Content -LiteralPath (Join-Path $projectCodex 'hooks.json') -Raw | ConvertFrom-Json
    $projectNotificationCount = @($projectHooksAfter.hooks.Stop | Where-Object { $null -ne $_ -and (Test-ManagedNotificationHookEntry $_) }).Count
    $projectPostLineCount = @($projectHooksAfter.hooks.PostToolUse | Where-Object { $null -ne $_ -and (Test-ManagedLineEndingHookEntry $_) }).Count
    $projectStopLineCount = @($projectHooksAfter.hooks.Stop | Where-Object { $null -ne $_ -and (Test-ManagedLineEndingHookEntry $_) }).Count
    if ($projectNotificationCount -ne 0 -or $projectPostLineCount -ne 1 -or $projectStopLineCount -ne 1) { throw "CVS 專案更新未清理受管理的重複 Hook：notification=$projectNotificationCount post=$projectPostLineCount stop=$projectStopLineCount" }
    $projectCheck = Assert-GlobalLineEndingHook -DevelopmentEnvironment CVS -Root $globalRoot -InstallWindowsNotifications $true -ProjectRoot $projectRoot
    if ($projectCheck.GlobalNotificationStopHookCount -ne 1 -or $projectCheck.ProjectNotificationStopHookCount -ne 0 -or $projectCheck.EffectiveCompletedNotificationHookCount -ne 1 -or $projectCheck.LegacyCompletedNotificationHookCount -ne 0 -or $projectCheck.StandaloneTokenUsageHookCount -ne 0 -or $projectCheck.ProjectLineEndingPostToolUseHookCount -ne 1 -or $projectCheck.ProjectLineEndingStopHookCount -notin @(0, 1) -or $projectCheck.ProjectLineEndingFinalizeHookCount -ne $projectCheck.ProjectLineEndingStopHookCount -or $projectCheck.LegacyCrlfHookCount -ne 0 -or $projectCheck.LegacyTokenHookCount -ne 0 -or $projectCheck.DuplicateManagedHookCount -ne 0 -or -not $projectCheck.DetachedToastCleanup) { throw 'CVS 專案 Hook 自檢結果不符合 Issue #18 驗收條件。' }
    if (-not (Test-Path -LiteralPath $customProjectScript -PathType Leaf)) { throw 'CVS 專案更新誤刪使用者自訂 Hook。' }
    if (-not (Test-Path -LiteralPath $customProjectToastScript -PathType Leaf) -or @($projectHooksAfter.hooks.Stop | ForEach-Object { @($_.hooks) } | Where-Object { (Get-HookEntryText -Entry $_) -match 'user-toast\.ps1' }).Count -ne 1) { throw 'CVS 專案更新誤刪使用者自訂 Toast Hook。' }
    foreach ($scriptName in @('crlf-updated-files.ps1', 'normalize-cvs-crlf.ps1', 'preserve-line-endings.ps1', 'show-turn-token-usage.ps1', 'show-codex-notification.ps1')) {
        if (Test-Path -LiteralPath (Join-Path $projectCodex ("hooks\$scriptName"))) { throw "CVS 專案更新保留舊受管理腳本：$scriptName" }
    }
    if (Test-Path -LiteralPath (Join-Path $projectCodex 'hooks\legacy-completion-notification.ps1')) { throw 'CVS 專案更新保留舊完成通知腳本。' }

    Install-TestEnvironment -Environment Git
    $manifest = Get-Manifest $globalRoot
    if ($manifest.ManagedHooks.managedId -ne 'codex-settings' -or [int]$manifest.ManagedHooks.managedVersion -ne 3 -or $manifest.ManagedHooks.notification.managedId -ne 'codex-settings-notification' -or [int]$manifest.ManagedHooks.notification.managedVersion -ne 3) { throw '安裝 manifest 缺少通知 managedId/managedVersion。' }
    $completedManifestHandlers = @($manifest.ManagedHooks.notification.handlers | Where-Object { $_.event -eq 'Stop' -and $_.handlerId -eq 'completed-token-toast' })
    if ($completedManifestHandlers.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$completedManifestHandlers[0].fingerprint)) { throw '安裝 manifest 未記錄唯一完成通知 Handler fingerprint。' }
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    $rules = Get-Content -LiteralPath (Join-Path $globalRoot 'rules\default.rules') -Raw
    $config = Get-Content -LiteralPath (Join-Path $globalRoot 'config.toml') -Raw
    if ($agents -notmatch '# Communication' -or $agents -notmatch '# Git Project Rules' -or $agents -match '# CVS Project Rules') { throw 'Git AGENTS.md composition is invalid.' }
    if ([regex]::Matches($agents, '(?m)^## Issue Branch Workflow\s*$').Count -ne 1 -or [regex]::Matches($agents, '(?m)^## Pull Request and Main Verification\s*$').Count -ne 1 -or $agents -notmatch 'issue/<issue-number>-<short-description>' -or $agents -notmatch 'Refs #<issue-number>' -or $agents -notmatch 'only after the fixing commit is on the default branch') { throw 'Git Issue branch and main-verification workflow is missing or duplicated.' }
    if ([regex]::Matches($rules, 'Git project rules supplement').Count -ne 1 -or [regex]::Matches($rules, 'CVS project rules supplement').Count -ne 0) { throw 'Git rules contain duplicate or conflicting project-type settings.' }
    if ($config -notmatch 'project_root_markers = \["\.git", "CVS"\]' -or $config -match '\.codex-root') { throw 'Global project root markers are invalid.' }
    if ((Get-DefaultDevelopmentEnvironment -Root $globalRoot) -ne 'Git') { throw 'Git was not recorded as the default project system.' }
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.SessionStart).Count -ne 1 -or @($installedHooks.hooks.PreToolUse).Count -ne 1 -or @($installedHooks.hooks.PermissionRequest).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1 -or $installedHooks.hooks.PSObject.Properties.Name -contains 'PostToolUse') { throw 'Git installation did not preserve the global hooks.' }
    if (-not (Test-ManagedNotificationHookEntry $installedHooks.hooks.PreToolUse[0]) -or -not (Test-ManagedNotificationHookEntry $installedHooks.hooks.PermissionRequest[0]) -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1) { throw 'Git notification hooks are invalid.' }
    if (-not (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\show-codex-notification.ps1') -PathType Leaf)) { throw 'Git installation omitted the global notification script.' }
    $notificationScriptBytes = [IO.File]::ReadAllBytes((Join-Path $globalRoot 'hooks\show-codex-notification.ps1'))
    if ($notificationScriptBytes.Length -lt 3 -or $notificationScriptBytes[0] -ne 0xEF -or $notificationScriptBytes[1] -ne 0xBB -or $notificationScriptBytes[2] -ne 0xBF) { throw 'Installed notification script lost its UTF-8 BOM.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\preserve-line-endings.ps1')) { throw 'Git installation retained the CVS line-ending protection script.' }

    Install-TestEnvironment -Environment CVS
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    $rules = Get-Content -LiteralPath (Join-Path $globalRoot 'rules\default.rules') -Raw
    if ($agents -notmatch '# Communication' -or $agents -notmatch '# CVS Project Rules' -or $agents -match '# Git Project Rules') { throw 'CVS AGENTS.md composition is invalid.' }
    if ($agents -match '(?m)^## Issue Completion Workflow\s*$') { throw 'CVS installation retained Git Issue completion instructions.' }
    if ([regex]::Matches($rules, 'CVS project rules supplement').Count -ne 1 -or [regex]::Matches($rules, 'Git project rules supplement').Count -ne 0) { throw 'CVS rules contain duplicate or conflicting project-type settings.' }
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.SessionStart).Count -ne 1) { throw 'CVS installation did not preserve the unmanaged user hook.' }
    if (@($installedHooks.hooks.PreToolUse).Count -ne 2 -or @($installedHooks.hooks.PermissionRequest).Count -ne 1 -or @($installedHooks.hooks.PostToolUse).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1) { throw 'Repeated CVS installation duplicated or omitted managed hooks.' }
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PostToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1) { throw 'Repeated CVS installation duplicated or omitted the line-ending protection hooks.' }
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PermissionRequest | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1) { throw 'Repeated CVS installation duplicated or omitted the global notification hooks.' }
    if (-not (Test-Path -LiteralPath (Join-Path $script:ScriptRoot 'templates\environments\cvs\hooks.json')) -or -not (Test-Path -LiteralPath (Join-Path $script:ScriptRoot 'templates\environments\cvs\hooks\preserve-line-endings.ps1'))) { throw 'CVS line-ending hook templates are missing.' }

    Install-TestEnvironment -Environment Git
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1')) { throw 'Switching environments retained the obsolete CVS hook script.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\preserve-line-endings.ps1')) { throw 'Switching environments retained the CVS line-ending protection script.' }
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PermissionRequest | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1) { throw 'Switching environments duplicated or removed the global notification hooks.' }

    Install-TestEnvironment -Environment Git -InstallWindowsNotifications $false
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.PSObject.Properties.Value | ForEach-Object { @($_) } | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 0) { throw 'Disabling Windows notifications retained managed notification hooks.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\show-codex-notification.ps1')) { throw 'Disabling Windows notifications retained the notification script.' }

    $script:notificationAnswer = ''
    $script:capturedNotificationPrompt = ''
    function Read-Host([string]$Prompt) {
        $script:capturedNotificationPrompt = $Prompt
        return $script:notificationAnswer
    }
    try {
        if (Select-OptionalWindowsNotifications -AlreadyInstalled:$false) { throw 'Blank first-install selection must not install Windows notifications.' }
        if ($script:capturedNotificationPrompt -ne '要安裝嗎？[y/N]') { throw 'First-install notification prompt is invalid.' }
        if (-not (Select-OptionalWindowsNotifications -AlreadyInstalled:$true)) { throw 'Blank update selection must preserve Windows notifications.' }
        if ($script:capturedNotificationPrompt -ne '要繼續安裝嗎？[Y/n]') { throw 'Existing notification prompt is invalid.' }
    } finally {
        Remove-Item -LiteralPath Function:\Read-Host -ErrorAction SilentlyContinue
    }

    $script:capturedEnvironmentPrompt = ''
    function Read-Host([string]$Prompt) {
        $script:capturedEnvironmentPrompt = $Prompt
        return ''
    }
    try {
        if ((Select-DevelopmentEnvironment -Default CVS) -ne 'CVS') { throw 'Blank selection did not reuse the recorded CVS default.' }
        if ($script:capturedEnvironmentPrompt -ne '請選擇 [2]') { throw 'CVS default was not shown in the selection prompt.' }
    } finally {
        Remove-Item -LiteralPath Function:\Read-Host -ErrorAction SilentlyContinue
    }

    Write-Host 'Global development environment tests passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
