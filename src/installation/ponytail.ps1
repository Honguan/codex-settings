$script:PonytailMarketplaceSource = 'DietrichGebert/ponytail'
$script:PonytailMarketplaceName = 'ponytail'
$script:PonytailPluginId = 'ponytail@ponytail'

function Invoke-PonytailCodexCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & codex @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { [string]$_ }) }
}

function ConvertTo-PonytailCanonicalMarketplaceSource {
    [CmdletBinding()]
    param([AllowNull()][string]$Source)

    $value = ([string]$Source).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    $value = $value -replace '(?i)^git@github\.com:', 'https://github.com/'
    $value = $value -replace '(?i)^ssh://git@github\.com/', 'https://github.com/'
    if ($value -match '^[^/:\s]+/[^/\s]+(?:\.git)?/?$') { $value = 'https://github.com/' + $value }
    if ($value -match '^(?i)https?://(?:www\.)?github\.com/(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?$') {
        return ('github.com/{0}/{1}' -f $Matches.owner, $Matches.repo).ToLowerInvariant()
    }
    return $value.TrimEnd('/').ToLowerInvariant()
}

function Get-PonytailMarketplaceSourceRelationship {
    [CmdletBinding()]
    param([bool]$Present, [AllowNull()][string]$Source)

    if (-not $Present) { return 'Missing' }
    if ([string]::IsNullOrWhiteSpace([string]$Source)) { return 'Unknown' }
    if ([string]::Equals(([string]$Source).Trim(), $script:PonytailMarketplaceSource, [StringComparison]::Ordinal)) { return 'Exact' }
    if ((ConvertTo-PonytailCanonicalMarketplaceSource $Source) -eq (ConvertTo-PonytailCanonicalMarketplaceSource $script:PonytailMarketplaceSource)) { return 'Equivalent' }
    return 'Conflict'
}

function Get-PonytailInstallationState {
    [CmdletBinding()]
    param()

    $marketplaces = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'list', '--json')
    if ($marketplaces.ExitCode -ne 0) { throw "無法讀取 Codex plugin marketplace 狀態：$($marketplaces.Output -join [Environment]::NewLine)" }
    $plugins = Invoke-PonytailCodexCommand -Arguments @('plugin', 'list', '--json')
    if ($plugins.ExitCode -ne 0) { throw "無法讀取 Codex plugin 狀態：$($plugins.Output -join [Environment]::NewLine)" }
    try { $marketplaceList = ($marketplaces.Output -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Codex marketplace list 回傳無法解析的 JSON：$($_.Exception.Message)" }
    try { $pluginList = ($plugins.Output -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Codex plugin list 回傳無法解析的 JSON：$($_.Exception.Message)" }

    $marketplace = @($marketplaceList.marketplaces | Where-Object { [string]$_.name -eq $script:PonytailMarketplaceName } | Select-Object -First 1)[0]
    $allPlugins = @($pluginList.installed) + @($pluginList.available)
    $plugin = @($pluginList.installed | Where-Object { [string]$_.pluginId -eq $script:PonytailPluginId } | Select-Object -First 1)[0]
    $sourceEntry = @($allPlugins | Where-Object { [string]$_.marketplaceName -eq $script:PonytailMarketplaceName -or [string]$_.pluginId -eq $script:PonytailPluginId } | Select-Object -First 1)[0]
    $marketplacePluginIds = @($pluginList.installed | Where-Object { [string]$_.marketplaceName -eq $script:PonytailMarketplaceName -or [string]$_.pluginId -eq $script:PonytailPluginId } | ForEach-Object { [string]$_.pluginId })
    $marketplaceSource = if ($null -ne $sourceEntry -and $null -ne $sourceEntry.marketplaceSource) { [string]$sourceEntry.marketplaceSource.source } else { '' }
    $marketplacePresent = $null -ne $marketplace
    $sourceRelationship = Get-PonytailMarketplaceSourceRelationship -Present:$marketplacePresent -Source $marketplaceSource
    return [pscustomobject]@{
        MarketplacePresent = $marketplacePresent
        MarketplaceName = if ($marketplacePresent) { [string]$marketplace.name } else { $script:PonytailMarketplaceName }
        MarketplaceSource = $marketplaceSource
        MarketplaceSourceKind = if ($null -ne $sourceEntry -and $null -ne $sourceEntry.marketplaceSource) { [string]$sourceEntry.marketplaceSource.sourceType } else { '' }
        MarketplaceCanonicalSource = ConvertTo-PonytailCanonicalMarketplaceSource $marketplaceSource
        ExpectedMarketplaceSource = $script:PonytailMarketplaceSource
        ExpectedMarketplaceCanonicalSource = ConvertTo-PonytailCanonicalMarketplaceSource $script:PonytailMarketplaceSource
        SourceRelationship = $sourceRelationship
        SourceMatchesExpected = $sourceRelationship -in @('Exact', 'Equivalent')
        MarketplacePluginIds = $marketplacePluginIds
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
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Root,
        [ValidateSet('Auto', 'Preserve', 'Switch', 'Skip')][string]$MarketplaceAction = 'Auto'
    )

    $before = $State
    if ($MarketplaceAction -eq 'Auto') { $MarketplaceAction = 'Preserve' }
    if ($MarketplaceAction -eq 'Skip') {
        $skipped = New-PonytailSkippedResult -AlreadyInstalled:([bool]$before.PluginPresent)
        $skipped.MarketplaceStatus = 'SkippedConflict'
        $skipped.ValidationError = "Marketplace=$($before.MarketplaceName); Current=$($before.MarketplaceSource); Expected=$($before.ExpectedMarketplaceSource); Relationship=$($before.SourceRelationship); Action=skip"
        return $skipped
    }
    if ($before.SourceRelationship -in @('Conflict', 'Unknown') -and $MarketplaceAction -eq 'Preserve') {
        $existingHooks = Get-PonytailHookState -State $before -Root $Root
        return [pscustomobject]@{
            Managed = $false
            WasInstalledBefore = [bool]$before.PluginPresent
            InstalledNow = $false
            UpdatedNow = $false
            MarketplaceStatus = 'PreservedConflict'
            MarketplaceAddedNow = $false
            MarketplaceSwitchedNow = $false
            OriginalMarketplaceSource = [string]$before.MarketplaceSource
            MarketplaceSource = [string]$before.MarketplaceSource
            PluginStatus = if ($before.PluginPresent) { 'Current' } else { 'SkippedConflict' }
            PluginVersion = [string]$before.Version
            HookCount = [int]$existingHooks.DetectedCount
            TrustedHookCount = [int]$existingHooks.TrustedCount
            HookIdentities = @($existingHooks.Hooks)
            ValidationStatus = if ($existingHooks.DetectedCount -eq 2) { 'Validated' } else { 'ManualRequired' }
            TrustStatus = if ($existingHooks.DetectedCount -eq 2 -and $existingHooks.TrustedCount -eq 2) { 'Trusted' } else { 'ManualRequired' }
            ValidationError = $(if ($existingHooks.DetectedCount -eq 2) { '' } else { "Marketplace=$($before.MarketplaceName); Current=$($before.MarketplaceSource); Expected=$($before.ExpectedMarketplaceSource); Relationship=$($before.SourceRelationship); Action=preserve; Hooks=$($existingHooks.DetectedCount)/2; $($existingHooks.Error)" })
        }
    }
    $marketplaceAddedNow = $false
    $marketplaceSwitchedNow = $false
    $marketplace = if ($before.SourceRelationship -in @('Conflict', 'Unknown') -and $MarketplaceAction -eq 'Switch') {
        $otherPlugins = @($before.MarketplacePluginIds | Where-Object { $_ -ne $script:PonytailPluginId })
        if ($otherPlugins.Count -gt 0) {
            throw "Ponytail marketplace 無法安全切換；其他已安裝 plugin：$($otherPlugins -join ', ')"
        }
        if ([string]::IsNullOrWhiteSpace([string]$before.MarketplaceSource)) {
            throw 'Ponytail marketplace 目前來源不明，無法建立可回復的安全切換。'
        }
        $remove = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'remove', $script:PonytailMarketplaceName, '--json')
        if ($remove.ExitCode -ne 0) { throw "Ponytail marketplace 切換前移除失敗：$($remove.Output -join [Environment]::NewLine)" }
        $added = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'add', $script:PonytailMarketplaceSource, '--json')
        if ($added.ExitCode -ne 0) {
            $restore = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'add', $before.MarketplaceSource, '--json')
            $restoreResult = if ($restore.ExitCode -eq 0) { '原來源已恢復' } else { "原來源恢復失敗：$($restore.Output -join [Environment]::NewLine)" }
            throw "Ponytail marketplace 切換失敗：$($added.Output -join [Environment]::NewLine)`n$restoreResult"
        }
        $marketplaceSwitchedNow = $true
        $added
    } elseif ($before.SourceRelationship -in @('Exact', 'Equivalent')) {
        Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'upgrade', $script:PonytailMarketplaceName, '--json')
    } elseif ($before.SourceRelationship -eq 'Missing') {
        $added = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'add', $script:PonytailMarketplaceSource, '--json')
        if ($added.ExitCode -eq 0) { $marketplaceAddedNow = $true }
        $added
    } else {
        throw ("Ponytail marketplace 來源需要人工確認。`nMarketplace: {0}`nCurrent source: {1}`nExpected source: {2}`nRelationship: {3}`nAction attempted: none" -f $before.MarketplaceName, $(if ($before.MarketplaceSource) { $before.MarketplaceSource } else { '<unknown>' }), $before.ExpectedMarketplaceSource, $before.SourceRelationship)
    }
    if ($marketplace.ExitCode -ne 0) { throw "Ponytail marketplace 處理失敗：$($marketplace.Output -join [Environment]::NewLine)" }
    try {
        $plugin = Invoke-PonytailCodexCommand -Arguments @('plugin', 'add', $script:PonytailPluginId, '--json')
        if ($plugin.ExitCode -ne 0) { throw "Ponytail plugin 安裝/更新失敗：$($plugin.Output -join [Environment]::NewLine)" }
        $after = Get-PonytailInstallationState
        if (-not [bool]$after.PluginPresent) { throw 'Ponytail plugin 指令完成後仍未出現在 Codex plugin list。' }
    } catch {
        $installationError = $_.Exception.Message
        $recovery = New-Object 'System.Collections.Generic.List[string]'
        if (-not [bool]$before.PluginPresent) {
            $removePlugin = Invoke-PonytailCodexCommand -Arguments @('plugin', 'remove', $script:PonytailPluginId)
            [void]$recovery.Add($(if ($removePlugin.ExitCode -eq 0) { '本次 plugin 已移除' } else { "本次 plugin 移除失敗：$($removePlugin.Output -join [Environment]::NewLine)" }))
        }
        if ($marketplaceAddedNow) {
            $removeMarketplace = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'remove', $script:PonytailMarketplaceName, '--json')
            [void]$recovery.Add($(if ($removeMarketplace.ExitCode -eq 0) { '本次 marketplace 已移除' } else { "本次 marketplace 移除失敗：$($removeMarketplace.Output -join [Environment]::NewLine)" }))
        } elseif ($marketplaceSwitchedNow) {
            $removeMarketplace = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'remove', $script:PonytailMarketplaceName, '--json')
            if ($removeMarketplace.ExitCode -ne 0) {
                [void]$recovery.Add("切換後 marketplace 移除失敗：$($removeMarketplace.Output -join [Environment]::NewLine)")
            } else {
                $restoreMarketplace = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'add', [string]$before.MarketplaceSource, '--json')
                [void]$recovery.Add($(if ($restoreMarketplace.ExitCode -eq 0) { '原 marketplace source 已恢復' } else { "原 marketplace source 恢復失敗：$($restoreMarketplace.Output -join [Environment]::NewLine)" }))
            }
        }
        throw "$installationError`nRecovery: $($recovery -join '; ')"
    }
    $hooks = Get-PonytailHookState -State $after -Root $Root
    $pluginStatus = if (-not $before.PluginPresent) { 'Installed' } elseif (($plugin.Output -join "`n") -match '(?i)unchanged|current|already installed') { 'Current' } else { 'Updated' }
    return [pscustomobject]@{
        Managed = $true
        WasInstalledBefore = [bool]$before.PluginPresent
        InstalledNow = -not [bool]$before.PluginPresent
        UpdatedNow = $pluginStatus -eq 'Updated'
        MarketplaceStatus = if ($marketplaceSwitchedNow) { 'Switched' } elseif ($before.MarketplacePresent) { 'Updated' } else { 'Installed' }
        MarketplaceAddedNow = $marketplaceAddedNow
        MarketplaceSwitchedNow = $marketplaceSwitchedNow
        OriginalMarketplaceSource = [string]$before.MarketplaceSource
        MarketplaceSource = $script:PonytailMarketplaceSource
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
    return [pscustomobject]@{ Managed = $false; WasInstalledBefore = $AlreadyInstalled; InstalledNow = $false; UpdatedNow = $false; MarketplaceStatus = 'SkippedByUser'; MarketplaceAddedNow = $false; MarketplaceSwitchedNow = $false; OriginalMarketplaceSource = ''; MarketplaceSource = ''; PluginStatus = 'SkippedByUser'; PluginVersion = ''; HookCount = 0; TrustedHookCount = 0; HookIdentities = @(); ValidationStatus = 'SkippedByUser'; TrustStatus = 'SkippedByUser'; ValidationError = '' }
}

function Undo-PonytailInstallation($Result) {
    if ($null -eq $Result) { return }
    if ([bool]$Result.InstalledNow) {
        $remove = Invoke-PonytailCodexCommand -Arguments @('plugin', 'remove', $script:PonytailPluginId)
        if ($remove.ExitCode -ne 0) { throw "Ponytail rollback failed: $($remove.Output -join [Environment]::NewLine)" }
    }
    if ([bool]$Result.MarketplaceAddedNow) {
        $removeMarketplace = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'remove', $script:PonytailMarketplaceName, '--json')
        if ($removeMarketplace.ExitCode -ne 0) { throw "Ponytail marketplace rollback failed: $($removeMarketplace.Output -join [Environment]::NewLine)" }
    } elseif ([bool]$Result.MarketplaceSwitchedNow) {
        $removeMarketplace = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'remove', $script:PonytailMarketplaceName, '--json')
        if ($removeMarketplace.ExitCode -ne 0) { throw "Ponytail marketplace rollback remove failed: $($removeMarketplace.Output -join [Environment]::NewLine)" }
        $restoreMarketplace = Invoke-PonytailCodexCommand -Arguments @('plugin', 'marketplace', 'add', [string]$Result.OriginalMarketplaceSource, '--json')
        if ($restoreMarketplace.ExitCode -ne 0) { throw "Ponytail marketplace rollback restore failed: $($restoreMarketplace.Output -join [Environment]::NewLine)" }
    }
}
function Get-PonytailInstallationComponents($Result) {
    return @(
        [pscustomobject]@{ Name = 'Ponytail marketplace'; Status = [string]$Result.MarketplaceStatus; Result = 'DietrichGebert/ponytail' }
        [pscustomobject]@{ Name = 'Ponytail plugin'; Status = [string]$Result.PluginStatus; Result = $script:PonytailPluginId }
        [pscustomobject]@{ Name = 'Ponytail hooks'; Status = [string]$Result.ValidationStatus; Result = ([string]$Result.HookCount + '/2 detected') }
        [pscustomobject]@{ Name = 'Ponytail hook trust'; Status = [string]$Result.TrustStatus; Result = ([string]$Result.TrustedHookCount + '/2 trusted') }
    )
}

function Select-PonytailMarketplaceAction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    if ($State.SourceRelationship -notin @('Conflict', 'Unknown')) { return 'Auto' }
    Write-Host ''
    Write-Host "偵測到既有 Codex marketplace：$($State.MarketplaceName)"
    Write-Host "目前來源：$(if ($State.MarketplaceSource) { $State.MarketplaceSource } else { '<unknown>' })"
    Write-Host "預期來源：$($State.ExpectedMarketplaceSource)"
    Write-Host '[1] 保留目前來源並驗證 Ponytail（安全預設）'
    Write-Host '[2] 切換成 DietrichGebert/ponytail'
    Write-Host '[3] 本次略過 Ponytail'
    switch (Read-Host '請選擇 [1]') {
        { $_ -in @('', '1') } { return 'Preserve' }
        '2' {
            $otherPlugins = @($State.MarketplacePluginIds | Where-Object { $_ -ne $script:PonytailPluginId })
            if ($otherPlugins.Count -gt 0) { throw "無法安全切換 Ponytail marketplace；其他已安裝 plugin：$($otherPlugins -join ', ')" }
            if ([string]::IsNullOrWhiteSpace([string]$State.MarketplaceSource)) { throw '目前 marketplace 來源不明，無法建立可回復的安全切換。' }
            return 'Switch'
        }
        '3' { return 'Skip' }
        default { throw 'Ponytail marketplace 選項無效。' }
    }
}
