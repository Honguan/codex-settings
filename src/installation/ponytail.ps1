$script:PonytailMarketplaceSource = 'DietrichGebert/ponytail'
$script:PonytailMarketplaceName = 'ponytail'
$script:PonytailPluginId = 'ponytail@ponytail'

function Invoke-PonytailCodexCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & codex @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { [string]$_ }) }
}

function Get-PonytailInstallationState {
    [CmdletBinding()]
    param()

    $marketplaces = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'list')
    if ($marketplaces.ExitCode -ne 0) { throw "無法讀取 Codex plugin marketplace 狀態：$($marketplaces.Output -join [Environment]::NewLine)" }
    $plugins = Invoke-PonytailCodexCommand -Arguments @('plugin', 'list', '--json')
    if ($plugins.ExitCode -ne 0) { throw "無法讀取 Codex plugin 狀態：$($plugins.Output -join [Environment]::NewLine)" }
    try { $pluginList = ($plugins.Output -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Codex plugin list 回傳無法解析的 JSON：$($_.Exception.Message)" }

    $plugin = @($pluginList.installed | Where-Object { [string]$_.pluginId -eq $script:PonytailPluginId } | Select-Object -First 1)[0]
    return [pscustomobject]@{
        MarketplacePresent = (($marketplaces.Output -join "`n") -match '(?m)^\s*ponytail\s+')
        PluginPresent = $null -ne $plugin
        PluginId = $script:PonytailPluginId
        PluginSourcePath = if ($null -ne $plugin -and $null -ne $plugin.source) { [string]$plugin.source.path } else { '' }
        Version = if ($null -ne $plugin) { [string]$plugin.version } else { '' }
    }
}

function Select-OptionalPonytail([bool]$AlreadyInstalled) {
    Write-Host ''
    Write-Host '選用全域功能：Ponytail'
    Write-Host '透過 Codex plugin 安裝 Ponytail，並驗證其 2 個 lifecycle hooks。'
    if ($AlreadyInstalled) {
        Write-Host '已偵測到既有 Ponytail 安裝，本次會保留並更新。'
        return Read-YesNoChoice -Prompt '要繼續安裝/更新嗎？[Y/n]' -Default $true
    }
    return Read-YesNoChoice -Prompt '要安裝嗎？[Y/n]' -Default $true
}

function Assert-PonytailPrerequisites {
    Assert-Command 'node'
    Assert-Command 'codex'
    $nodeVersion = (& node --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v?\d+') {
        throw 'Ponytail 需要 Node.js，但目前找不到可用的 node。請先安裝 Node.js 並確認 node --version 可執行後再重試。'
    }
    $codexVersion = (& codex --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Ponytail 需要可用的 Codex CLI。請確認 codex --version 可執行後再重試。' }
    return [pscustomobject]@{ NodeVersion = $nodeVersion; CodexVersion = $codexVersion }
}

function Test-PonytailHookSource($Hook, [string]$PluginSourcePath) {
    if ([string]::IsNullOrWhiteSpace($PluginSourcePath) -or [string]::IsNullOrWhiteSpace([string]$Hook.sourcePath)) { return $false }
    try {
        $pluginRoot = [IO.Path]::GetFullPath($PluginSourcePath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $hookSource = [IO.Path]::GetFullPath([string]$Hook.sourcePath)
        return [string]::Equals($hookSource, $pluginRoot, [StringComparison]::OrdinalIgnoreCase) -or $hookSource.StartsWith($pluginRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-PonytailHookState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$Root, [string]$Cwd = $Root)

    if (-not [bool]$State.PluginPresent -or [string]::IsNullOrWhiteSpace([string]$State.PluginSourcePath)) {
        return [pscustomobject]@{ DetectedCount = 0; TrustedCount = 0; Hooks = @(); Error = 'Ponytail plugin source is unavailable.' }
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_APP_SERVER_TEST_COMMAND)) {
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $env:CODEX_SETTINGS_APP_SERVER_TEST_COMMAND)) { $startInfo.ArgumentList.Add($argument) }
    } else {
        $codexPath = [string](Get-Command codex -ErrorAction Stop).Source
        if ([IO.Path]::GetExtension($codexPath).ToLowerInvariant() -in @('.cmd', '.bat')) {
            $startInfo.FileName = $env:ComSpec
            foreach ($argument in @('/d', '/s', '/c', 'call', $codexPath, 'app-server', '--stdio')) { $startInfo.ArgumentList.Add($argument) }
        } else {
            $startInfo.FileName = $codexPath
            foreach ($argument in @('app-server', '--stdio')) { $startInfo.ArgumentList.Add($argument) }
        }
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['CODEX_HOME'] = [IO.Path]::GetFullPath($Root)
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $process.StandardInput.WriteLine((@{ method = 'initialize'; id = 1; params = @{ clientInfo = @{ name = 'codex_settings'; version = '1.0.0' } } } | ConvertTo-Json -Depth 8 -Compress))
        $process.StandardInput.Flush()
        [void](Read-CodexAppServerResponse -Process $process -RequestId 1)
        $process.StandardInput.WriteLine((@{ method = 'initialized'; params = @{} } | ConvertTo-Json -Compress))
        $process.StandardInput.WriteLine((@{ method = 'hooks/list'; id = 2; params = @{ cwds = @([IO.Path]::GetFullPath($Cwd)) } } | ConvertTo-Json -Depth 8 -Compress))
        $process.StandardInput.Flush()
        $listed = Read-CodexAppServerResponse -Process $process -RequestId 2
        $cwdResult = @($listed.data | Where-Object { [string]::Equals([IO.Path]::GetFullPath([string]$_.cwd), [IO.Path]::GetFullPath($Cwd), [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)[0]
        if ($null -eq $cwdResult) { throw 'Codex app-server 未回傳全域安裝目錄的 Hook 資訊。' }
        $hooks = @($cwdResult.hooks | Where-Object { Test-PonytailHookSource -Hook $_ -PluginSourcePath $State.PluginSourcePath })
        return [pscustomobject]@{ DetectedCount = $hooks.Count; TrustedCount = @($hooks | Where-Object { [string]$_.trustStatus -eq 'trusted' }).Count; Hooks = @($hooks | ForEach-Object { [pscustomobject]@{ Key = [string]$_.key; SourcePath = [string]$_.sourcePath; TrustStatus = [string]$_.trustStatus } }); Error = '' }
    } catch {
        return [pscustomobject]@{ DetectedCount = 0; TrustedCount = 0; Hooks = @(); Error = $_.Exception.Message }
    } finally {
        try { $process.StandardInput.Close() } catch {}
        if (-not $process.WaitForExit(1000)) { $process.Kill($true) }
        $process.Dispose()
    }
}

function Invoke-PonytailInstallation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$Root)

    $before = $State
    $marketplace = if ($before.MarketplacePresent) {
        Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'upgrade', $script:PonytailMarketplaceName, '--json')
    } else {
        Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'add', $script:PonytailMarketplaceSource, '--json')
    }
    if ($marketplace.ExitCode -ne 0) { throw "Ponytail marketplace 處理失敗：$($marketplace.Output -join [Environment]::NewLine)" }
    $plugin = Invoke-PonytailCodexCommand -Arguments @('plugin', 'add', $script:PonytailPluginId, '--json')
    if ($plugin.ExitCode -ne 0) { throw "Ponytail plugin 安裝/更新失敗：$($plugin.Output -join [Environment]::NewLine)" }
    $after = Get-PonytailInstallationState
    if (-not [bool]$after.PluginPresent) { throw 'Ponytail plugin 指令完成後仍未出現在 Codex plugin list。' }
    $hooks = Get-PonytailHookState -State $after -Root $Root
    $pluginStatus = if (-not $before.PluginPresent) { 'Installed' } elseif (($plugin.Output -join "`n") -match '(?i)unchanged|current|already installed') { 'Current' } else { 'Updated' }
    return [pscustomobject]@{
        Managed = $true
        WasInstalledBefore = [bool]$before.PluginPresent
        InstalledNow = -not [bool]$before.PluginPresent
        UpdatedNow = $pluginStatus -eq 'Updated'
        MarketplaceStatus = if ($before.MarketplacePresent) { 'Updated' } else { 'Installed' }
        PluginStatus = $pluginStatus
        PluginVersion = $after.Version
        HookCount = [int]$hooks.DetectedCount
        TrustedHookCount = [int]$hooks.TrustedCount
        HookIdentities = @($hooks.Hooks)
        ValidationStatus = if ($hooks.DetectedCount -eq 2) { 'Validated' } else { 'Failed' }
        TrustStatus = if ($hooks.DetectedCount -eq 2 -and $hooks.TrustedCount -eq 2) { 'Trusted' } else { 'ManualRequired' }
        ValidationError = [string]$hooks.Error
    }
}

function New-PonytailSkippedResult([bool]$AlreadyInstalled = $false) {
    return [pscustomobject]@{ Managed = $false; WasInstalledBefore = $AlreadyInstalled; InstalledNow = $false; UpdatedNow = $false; MarketplaceStatus = 'SkippedByUser'; PluginStatus = 'SkippedByUser'; PluginVersion = ''; HookCount = 0; TrustedHookCount = 0; HookIdentities = @(); ValidationStatus = 'SkippedByUser'; TrustStatus = 'SkippedByUser'; ValidationError = '' }
}

function Undo-PonytailInstallation($Result) {
    if ($null -eq $Result -or -not [bool]$Result.InstalledNow) { return }
    $remove = Invoke-PonytailCodexCommand -Arguments @('plugin', 'remove', $script:PonytailPluginId)
    if ($remove.ExitCode -ne 0) { throw "Ponytail rollback failed: $($remove.Output -join [Environment]::NewLine)" }
}