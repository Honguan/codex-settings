$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'modules\common.ps1')
. (Join-Path $script:ScriptRoot 'modules\installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-global-environment-' + [guid]::NewGuid().ToString('N'))
$globalRoot = Join-Path $testRoot '.codex'

function Install-TestEnvironment([ValidateSet('Git', 'CVS')][string]$Environment) {
    $transaction = New-FileTransaction -Root (Join-Path $testRoot ("transaction-$Environment-" + [guid]::NewGuid().ToString('N'))) -Mode "Test-$Environment"
    $target = [pscustomobject]@{
        Mode = 'Global'
        Template = Join-Path $script:ScriptRoot 'templates\core'
        EnvironmentTemplate = Join-Path $script:ScriptRoot ("templates\environments\{0}" -f $Environment.ToLowerInvariant())
        DevelopmentEnvironment = $Environment
        Root = $globalRoot
        EnableDefaultModeRequestUserInput = $false
    }
    $result = Install-Target -Target $target -Transaction $transaction
    Write-Manifest -Result $result -Transaction $transaction -External $null
    Complete-FileTransaction -Transaction $transaction
}

try {
    $installerSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'installer.ps1') -Raw
    if ($installerSource -match 'Write-Warning\s+"已回復中斷的交易') {
        throw 'Installer startup must not render recovered transactions as a yellow warning.'
    }
    if ($installerSource -notmatch 'Write-Host\s+"已自動回復上次中斷的安裝交易') {
        throw 'Installer startup did not preserve a clear recovered-transaction status message.'
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
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PostToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1) { throw 'CVS installation did not install one Track, Restore, and Finalize hook.' }
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedGlobalHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PermissionRequest | Where-Object { Test-ManagedGlobalHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedGlobalHookEntry $_ }).Count -ne 1) { throw 'CVS installation did not install one notification hook per supported event.' }
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

    Install-TestEnvironment -Environment Git
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    $rules = Get-Content -LiteralPath (Join-Path $globalRoot 'rules\default.rules') -Raw
    $config = Get-Content -LiteralPath (Join-Path $globalRoot 'config.toml') -Raw
    if ($agents -notmatch '# Communication' -or $agents -notmatch '# Git Project Rules' -or $agents -match '# CVS Project Rules') { throw 'Git AGENTS.md composition is invalid.' }
    if ([regex]::Matches($agents, '(?m)^## Issue Completion Workflow\s*$').Count -ne 1 -or $agents -notmatch 'Fixes #<issue-number>' -or $agents -notmatch 'only after the fixing commit is on the default branch') { throw 'Git Issue completion workflow is missing or duplicated.' }
    if ([regex]::Matches($rules, 'Git project rules supplement').Count -ne 1 -or [regex]::Matches($rules, 'CVS project rules supplement').Count -ne 0) { throw 'Git rules contain duplicate or conflicting project-type settings.' }
    if ($config -notmatch 'project_root_markers = \["\.git", "CVS"\]' -or $config -match '\.codex-root') { throw 'Global project root markers are invalid.' }
    if ((Get-DefaultDevelopmentEnvironment -Root $globalRoot) -ne 'Git') { throw 'Git was not recorded as the default project system.' }
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.SessionStart).Count -ne 1 -or @($installedHooks.hooks.PreToolUse).Count -ne 1 -or @($installedHooks.hooks.PermissionRequest).Count -ne 1 -or @($installedHooks.hooks.Stop).Count -ne 1 -or $installedHooks.hooks.PSObject.Properties.Name -contains 'PostToolUse') { throw 'Git installation did not preserve the global notification hooks.' }
    if (-not (Test-ManagedGlobalHookEntry $installedHooks.hooks.PreToolUse[0]) -or -not (Test-ManagedGlobalHookEntry $installedHooks.hooks.PermissionRequest[0]) -or -not (Test-ManagedGlobalHookEntry $installedHooks.hooks.Stop[0])) { throw 'Git notification hooks are invalid.' }
    if (-not (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\show-codex-notification.ps1') -PathType Leaf)) { throw 'Git installation omitted the global notification script.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\preserve-line-endings.ps1')) { throw 'Git installation retained the CVS line-ending protection script.' }

    Install-TestEnvironment -Environment CVS
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    $rules = Get-Content -LiteralPath (Join-Path $globalRoot 'rules\default.rules') -Raw
    if ($agents -notmatch '# Communication' -or $agents -notmatch '# CVS Project Rules' -or $agents -match '# Git Project Rules') { throw 'CVS AGENTS.md composition is invalid.' }
    if ($agents -match '(?m)^## Issue Completion Workflow\s*$') { throw 'CVS installation retained Git Issue completion instructions.' }
    if ([regex]::Matches($rules, 'CVS project rules supplement').Count -ne 1 -or [regex]::Matches($rules, 'Git project rules supplement').Count -ne 0) { throw 'CVS rules contain duplicate or conflicting project-type settings.' }
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.SessionStart).Count -ne 1) { throw 'CVS installation did not preserve the unmanaged user hook.' }
    if (@($installedHooks.hooks.PreToolUse).Count -ne 2 -or @($installedHooks.hooks.PermissionRequest).Count -ne 1 -or @($installedHooks.hooks.PostToolUse).Count -ne 1 -or @($installedHooks.hooks.Stop).Count -ne 2) { throw 'Repeated CVS installation duplicated or omitted managed hooks.' }
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PostToolUse | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedLineEndingHookEntry $_ }).Count -ne 1) { throw 'Repeated CVS installation duplicated or omitted the line-ending protection hooks.' }
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedGlobalHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PermissionRequest | Where-Object { Test-ManagedGlobalHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedGlobalHookEntry $_ }).Count -ne 1) { throw 'Repeated CVS installation duplicated or omitted the global notification hooks.' }
    if (-not (Test-Path -LiteralPath (Join-Path $script:ScriptRoot 'templates\environments\cvs\hooks.json')) -or -not (Test-Path -LiteralPath (Join-Path $script:ScriptRoot 'templates\environments\cvs\hooks\preserve-line-endings.ps1'))) { throw 'CVS line-ending hook templates are missing.' }

    Install-TestEnvironment -Environment Git
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1')) { throw 'Switching environments retained the obsolete CVS hook script.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\preserve-line-endings.ps1')) { throw 'Switching environments retained the CVS line-ending protection script.' }
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.PreToolUse | Where-Object { Test-ManagedGlobalHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.PermissionRequest | Where-Object { Test-ManagedGlobalHookEntry $_ }).Count -ne 1 -or @($installedHooks.hooks.Stop | Where-Object { Test-ManagedGlobalHookEntry $_ }).Count -ne 1) { throw 'Switching environments duplicated or removed the global notification hooks.' }

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
