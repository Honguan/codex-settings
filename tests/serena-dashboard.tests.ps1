$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')
. (Get-OptionalInstallationScriptPath -Name Serena)

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-serena-dashboard-' + [guid]::NewGuid().ToString('N'))
$previousSerenaHome = $env:SERENA_HOME

function New-DashboardTransaction([string]$Name) {
    return New-FileTransaction -Root (Join-Path $testRoot ('transaction-' + $Name + '-' + [guid]::NewGuid().ToString('N'))) -Mode SerenaDashboardTest
}

function Write-DashboardConfig([string]$Content, [bool]$Bom = $false) {
    New-Item -ItemType Directory -Path $env:SERENA_HOME -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $env:SERENA_HOME 'serena_config.yml'), $Content, [Text.UTF8Encoding]::new($Bom))
}

try {
    $env:SERENA_HOME = Join-Path $testRoot '.serena'
    $configPath = Join-Path $env:SERENA_HOME 'serena_config.yml'

    foreach ($value in @('true', 'True', 'TRUE')) {
        Write-DashboardConfig "web_dashboard: true`nweb_dashboard_open_on_launch: $value  # keep comment`nlog_level: 20`n"
        $result = Set-SerenaDashboardConfiguration -Transaction (New-DashboardTransaction $value)
        $content = [IO.File]::ReadAllText($configPath)
        if (-not $result.Changed -or $content -ne "web_dashboard: false`nweb_dashboard_open_on_launch: false  # keep comment`nlog_level: 20`n") { throw "True variant $value was not minimally reconciled." }
    }

    foreach ($value in @('false', 'False', 'FALSE')) {
        Write-DashboardConfig "web_dashboard: false`r`nweb_dashboard_open_on_launch: $value`r`n" -Bom $true
        $before = [IO.File]::ReadAllBytes($configPath)
        $result = Set-SerenaDashboardConfiguration -Transaction (New-DashboardTransaction $value)
        if ($result.Changed -or [Convert]::ToHexString([IO.File]::ReadAllBytes($configPath)) -ne [Convert]::ToHexString($before)) { throw "False variant $value should remain byte-for-byte unchanged." }
    }

    Write-DashboardConfig "# user comment`r`nweb_dashboard: true`r`ncustom_setting: keep`r`n" -Bom $true
    [void](Set-SerenaDashboardConfiguration -Transaction (New-DashboardTransaction missing))
    $bytes = [IO.File]::ReadAllBytes($configPath)
    $content = (Get-TextFileState -Path $configPath).Content
    if ($bytes[0] -ne 0xEF -or $content -ne "# user comment`r`nweb_dashboard: false`r`ncustom_setting: keep`r`nweb_dashboard_open_on_launch: false`r`n") { throw 'Missing key reconciliation did not preserve CRLF, BOM, or unrelated settings.' }

    foreach ($unsafe in @(
        "web_dashboard_open_on_launch: true`nweb_dashboard_open_on_launch: false`n",
        "web_dashboard_open_on_launch: &auto true`n",
        "web_dashboard_open_on_launch: true#not-a-comment`n",
        "web_dashboard_open_on_launch:`n  enabled: true`n",
        "web_dashboard: true`n...`n"
    )) {
        Write-DashboardConfig $unsafe
        $before = [IO.File]::ReadAllBytes($configPath)
        $conflictTransaction = New-DashboardTransaction conflict
        $message = ''
        try { [void](Set-SerenaDashboardConfiguration -Transaction $conflictTransaction) } catch { $message = $_.Exception.Message }
        if ($message -notmatch 'ConfigurationConflict' -or $conflictTransaction.Entries.Count -ne 1 -or [Convert]::ToHexString([IO.File]::ReadAllBytes($configPath)) -ne [Convert]::ToHexString($before)) { throw 'Unsafe YAML did not produce a backed-up, non-destructive ConfigurationConflict.' }
    }

    Write-DashboardConfig "web_dashboard: true`nweb_dashboard_open_on_launch: true`n"
    $transaction = New-DashboardTransaction rollback
    $before = [IO.File]::ReadAllBytes($configPath)
    [void](Set-SerenaDashboardConfiguration -Transaction $transaction)
    Undo-FileTransaction -Transaction $transaction
    if ([Convert]::ToHexString([IO.File]::ReadAllBytes($configPath)) -ne [Convert]::ToHexString($before)) { throw 'Serena configuration rollback did not restore the exact original bytes.' }

    Write-DashboardConfig "web_dashboard: true`n"
    for ($run = 1; $run -le 10; $run++) { [void](Set-SerenaDashboardConfiguration -Transaction (New-DashboardTransaction "repeat-$run")) }
    $stable = [IO.File]::ReadAllBytes($configPath)
    $repeatedContent = [IO.File]::ReadAllText($configPath)
    if ([regex]::Matches($repeatedContent, '(?m)^web_dashboard:').Count -ne 1 -or [regex]::Matches($repeatedContent, '(?m)^web_dashboard_open_on_launch:').Count -ne 1) { throw 'Repeated reconciliation duplicated a Dashboard key.' }
    [void](Set-SerenaDashboardConfiguration -Transaction (New-DashboardTransaction stable))
    if ([Convert]::ToHexString([IO.File]::ReadAllBytes($configPath)) -ne [Convert]::ToHexString($stable)) { throw 'Repeated reconciliation unnecessarily rewrote an already configured file.' }

    $script:stateCall = 0
    $script:freshScenario = $true
    $script:toolFailure = $false
    $script:upgradeFailureLeavesCliUsable = $true
    function Get-SerenaInstallationState {
        $script:stateCall++
        $beforeInstall = $script:stateCall -eq 1
        $cliPresent = -not $beforeInstall -and (-not $script:toolFailure -or $script:upgradeFailureLeavesCliUsable)
        return [pscustomobject]@{ UvAvailable = $true; UvVersion = '0.9.0'; ToolPresent = -not ($beforeInstall -and $script:freshScenario); CliPresent = $cliPresent; Version = $(if ($cliPresent) { '1.2.3' } else { '' }); Initialized = -not ($beforeInstall -and $script:freshScenario) }
    }
    function Invoke-SerenaCommand {
        param([string]$Command, [string[]]$Arguments)
        $operation = "$Command $($Arguments -join ' ')"
        if ($script:toolFailure -and $operation -match '^uv tool (?:install|upgrade) ') { return [pscustomobject]@{ ExitCode = 1; Output = @('intentional tool failure') } }
        if ($operation -eq 'serena init') {
            Write-DashboardConfig "web_dashboard: true`nweb_dashboard_open_on_launch: true`n"
        } elseif ($operation -eq 'serena setup codex') {
            [IO.File]::WriteAllText((Join-Path $env:CODEX_HOME 'config.toml'), "[mcp_servers.serena]`ncommand = `"serena`"`nargs = [`"start-mcp-server`", `"--context=codex`", `"--project-from-cwd`"]`n", [Text.UTF8Encoding]::new($false))
        }
        return [pscustomobject]@{ ExitCode = 0; Output = $(if ($Command -eq 'uv') { @($(if ($script:freshScenario) { 'installed' } else { 'already current' })) } else { @() }) }
    }
    function Test-SerenaUvAvailable { return $true }

    Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
    $codexRoot = Join-Path $testRoot 'codex'
    New-Item -ItemType Directory -Path $codexRoot -Force | Out-Null
    $fresh = Invoke-SerenaInstallation -Root $codexRoot -Transaction (New-DashboardTransaction fresh)
    if ($fresh.InitializationStatus -ne 'Initialized' -or $fresh.DashboardAutoOpenStatus -ne 'Disabled' -or (Get-SerenaConfigurationState).DashboardConfigStatus -ne 'Disabled') { throw 'Fresh Serena flow did not configure Dashboard auto-open after init.' }

    $script:stateCall = 0
    $script:freshScenario = $false
    Write-DashboardConfig "web_dashboard: true`nweb_dashboard_open_on_launch: true`n"
    $existing = Invoke-SerenaInstallation -Root $codexRoot -Transaction (New-DashboardTransaction existing)
    if ($existing.ToolStatus -ne 'Current' -or $existing.InitializationStatus -ne 'Existing' -or $existing.DashboardConfigStatus -ne 'Updated' -or (Get-SerenaConfigurationState).DashboardConfigStatus -ne 'Disabled') { throw 'Existing/current Serena flow skipped Dashboard reconciliation.' }
    if (-not (Test-SerenaCodexMcpConfiguration -ConfigPath (Join-Path $codexRoot 'config.toml'))) { throw 'Serena MCP configuration or required official arguments were not preserved.' }

    $script:stateCall = 0
    $script:toolFailure = $true
    Write-DashboardConfig "web_dashboard: true`nweb_dashboard_open_on_launch: true`n"
    $deferred = Invoke-SerenaInstallation -Root $codexRoot -Transaction (New-DashboardTransaction upgrade-deferred)
    if ($deferred.ToolStatus -ne 'UpgradeDeferred' -or $deferred.UpdatedNow -or $deferred.DashboardAutoOpenStatus -ne 'Disabled' -or $deferred.CodexMcpStatus -ne 'Configured' -or (Get-SerenaConfigurationState).DashboardConfigStatus -ne 'Disabled') { throw 'Usable Serena CLI did not survive a deferred upgrade and complete Serena reconciliation.' }

    $script:stateCall = 0
    $script:upgradeFailureLeavesCliUsable = $false
    Write-DashboardConfig "web_dashboard: true`nweb_dashboard_open_on_launch: true`n"
    $unusableFailure = try { Invoke-SerenaInstallation -Root $codexRoot -Transaction (New-DashboardTransaction upgrade-unusable) | Out-Null; '' } catch { $_.Exception.Message }
    if ($unusableFailure -notmatch 'Serena upgrade 失敗' -or (Get-SerenaConfigurationState).DashboardConfigStatus -ne 'Enabled') { throw 'Unusable Serena CLI did not retain the hard failure and untouched Dashboard config.' }

    $script:stateCall = 0
    $script:freshScenario = $true
    $freshFailure = try { Invoke-SerenaInstallation -Root $codexRoot -Transaction (New-DashboardTransaction install-failure) | Out-Null; '' } catch { $_.Exception.Message }
    if ($freshFailure -notmatch 'Serena install 失敗') { throw 'Fresh Serena install failure was incorrectly treated as deferred.' }

    $components = @(Get-SerenaInstallationComponents -Result $existing)
    if (@($components | Where-Object { $_.Name -eq 'Serena Dashboard' -and $_.Status -eq 'Disabled' }).Count -ne 1 -or @($components | Where-Object { $_.Name -eq 'Serena Dashboard auto-open' -and $_.Status -eq 'Disabled' }).Count -ne 1) { throw 'Serena summary does not report the disabled Dashboard and auto-open settings.' }
    $beforeSkip = [IO.File]::ReadAllBytes($configPath)
    $skipped = New-SerenaSkippedResult
    if ($skipped.SelectedByUser -or [Convert]::ToHexString([IO.File]::ReadAllBytes($configPath)) -ne [Convert]::ToHexString($beforeSkip)) { throw 'Skipping Serena modified its configuration.' }

    Write-Host 'Serena Dashboard configuration tests passed.'
} finally {
    $env:SERENA_HOME = $previousSerenaHome
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
