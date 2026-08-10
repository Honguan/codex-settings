$script:PonytailMarketplaceSource = 'DietrichGebert/ponytail'
$script:PonytailMarketplaceName = 'ponytail'
$script:PonytailPluginId = 'ponytail@ponytail'
$script:CodexOrchestrationMarketplaceSource = 'Cjbuilds/Codex-Orchestration'
$script:CodexOrchestrationMarketplaceName = 'codex-orchestration'
$script:CodexOrchestrationPluginId = 'codex-orchestration@codex-orchestration'
$script:SerenaPackageName = 'serena-agent'
$script:SerenaMcpSection = 'mcp_servers.serena'

function Get-OptionalInstallationScriptPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Ponytail', 'CodexOrchestration', 'Serena')][string]$Name)

    $relativePath = switch ($Name) {
        'Ponytail' { 'installation\ponytail.ps1' }
        'CodexOrchestration' { 'installation\codex-orchestration.ps1' }
        'Serena' { 'installation\serena.ps1' }
    }
    return Join-Path $script:ScriptRoot $relativePath
}

function Select-OptionalPonytail([bool]$AlreadyInstalled = $false) {
    Write-Host ''
    Write-Host '選用全域功能：Ponytail'
    Write-Host '透過 Codex plugin 安裝 Ponytail，並驗證其 lifecycle hooks。'
    return Select-OptionalComponentAction -Name 'Ponytail' -State (Get-OptionalComponentState -Installed $AlreadyInstalled)
}

function Select-OptionalCodexOrchestration([bool]$AlreadyInstalled = $false) {
    Write-Host ''
    Write-Host '選用全域功能：Codex-Orchestration'
    Write-Host '多模型／多角色 Codex 工作流，可設定 Planner、Advisor、Designer、Executor。'
    return Select-OptionalComponentAction -Name 'Codex-Orchestration' -State (Get-OptionalComponentState -Installed $AlreadyInstalled)
}

function Select-OptionalSerena([bool]$AlreadyInstalled = $false) {
    Write-Host ''
    Write-Host '選用全域功能：Serena'
    Write-Host '提供語意程式碼搜尋、分析與編輯能力，並透過 MCP 連接 Codex。'
    return Select-OptionalComponentAction -Name 'Serena' -State (Get-OptionalComponentState -Installed $AlreadyInstalled)
}

function Select-SerenaUvInstallation {
    Write-Host '未偵測到 uv。Serena 需要 uv。'
    Write-Host '會使用官方 Windows 安裝方式：winget install --id astral-sh.uv -e。'
    return Read-YesNoChoice -Prompt '是否使用官方安裝方式安裝 uv？[Y/n]' -Default $true
}

function New-PonytailSkippedResult([bool]$AlreadyInstalled = $false, [string]$Status = 'SkippedNotInstalled') {
    return [pscustomobject]@{ Managed = $false; WasInstalledBefore = $AlreadyInstalled; InstalledNow = $false; UpdatedNow = $false; MarketplaceStatus = $Status; MarketplaceAddedNow = $false; MarketplaceSwitchedNow = $false; MarketplaceRecoveredNow = $false; OriginalMarketplaceSource = ''; MarketplaceSource = ''; PluginStatus = $Status; PluginVersion = ''; HookCount = 0; TrustedHookCount = 0; HookIdentities = @(); ValidationStatus = $Status; TrustStatus = $Status; ValidationError = '' }
}

function New-CodexOrchestrationSkippedResult([string]$Status = 'SkippedNotInstalled') {
    return [pscustomobject]@{ Managed = $false; PluginPresent = $null; WasInstalledBefore = $false; InstalledNow = $false; UpdatedNow = $false; MarketplaceStatus = $Status; PluginStatus = $Status; PluginVersion = ''; WorkflowRequested = $false; WorkflowManaged = $false; WorkflowConfigured = $false; WorkflowEffective = $false; WorkflowStatus = $Status; WorkflowConfigurationSummary = ''; SetupPrompt = ''; ActionRequired = $false; LastVerified = $null }
}

function New-SerenaSkippedResult([string]$Status = 'SkippedNotInstalled') {
    return [pscustomobject]@{ Managed = $false; SelectedByUser = $false; UvAvailable = $false; UvVersion = ''; VersionBefore = ''; VersionAfter = ''; InstalledNow = $false; UpdatedNow = $false; ToolStatus = $Status; InitializationStatus = $Status; DashboardStatus = $Status; DashboardAutoOpenStatus = $Status; DashboardConfigStatus = $Status; CodexMcpStatus = $Status; RuntimeStatus = $Status }
}

function Invoke-MattPocockSkillsUninstall {
    $names = @(Get-MattPocockSkillNames)
    if (-not (Test-MattPocockSkillsInstalled)) { return [pscustomobject]@{ Status = 'Unchanged'; Names = @() } }
    $output = & npx --yes skills@latest remove --global --agent codex --yes @names 2>&1
    if ($LASTEXITCODE -ne 0) {
        $removeExitCode = $LASTEXITCODE
        $restoreArguments = @(Get-MattPocockSkillsArguments)
        $restore = & npx @restoreArguments 2>&1
        throw "mattpocock/skills 解除安裝失敗，結束碼：$removeExitCode；復原：$(if ($LASTEXITCODE -eq 0) { '成功' } else { '失敗' })"
    }
    return [pscustomobject]@{ Status = 'Uninstalled'; Names = $names; Output = $output }
}

function Remove-OptionalManagedDirectory([string]$Path, $Transaction) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 'Unchanged' }
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse)) { Save-TransactionFile -Transaction $Transaction -Path $file.FullName }
    Remove-Item -LiteralPath $Path -Recurse -Force
    return 'Uninstalled'
}

function Get-PonytailInstallationComponents($Result) {
    return @(
        [pscustomobject]@{ Name = 'Ponytail marketplace'; Status = [string]$Result.MarketplaceStatus; Result = $script:PonytailMarketplaceSource }
        [pscustomobject]@{ Name = 'Ponytail plugin'; Status = [string]$Result.PluginStatus; Result = $script:PonytailPluginId }
        [pscustomobject]@{ Name = 'Ponytail hooks'; Status = [string]$Result.ValidationStatus; Result = ([string]$Result.HookCount + ' detected') }
        [pscustomobject]@{ Name = 'Ponytail hook trust'; Status = [string]$Result.TrustStatus; Result = ([string]$Result.TrustedHookCount + ' trusted') }
    )
}

function Get-CodexOrchestrationInstallationComponents($Result) {
    $workflowResult = switch ([string]$Result.WorkflowStatus) {
        'ActionRequired' { "請完全關閉並重新啟動 Codex，建立新的 Codex Task 並貼上（不是 PowerShell 命令）：`n`n$($Result.SetupPrompt)`n`n設定完成後，再建立另一個新的 Codex Task，workflow 才會生效。" }
        'Preserved' { '保留既有 workflow，未重新設定' }
        'NotConfigured' { 'Plugin only / workflow not configured' }
        default { '未選用' }
    }
    return @(
        [pscustomobject]@{ Name = 'Codex-Orchestration plugin'; Status = [string]$Result.PluginStatus; Result = $script:CodexOrchestrationPluginId }
        [pscustomobject]@{ Name = 'Codex-Orchestration workflow'; Status = [string]$Result.WorkflowStatus; Result = $workflowResult }
    )
}

function Get-SerenaInstallationComponents($Result) {
    return @(
        [pscustomobject]@{ Name = 'Serena / uv'; Status = $(if ($Result.UvAvailable) { 'Available' } else { [string]$Result.ToolStatus }); Result = [string]$Result.UvVersion }
        [pscustomobject]@{ Name = 'Serena CLI'; Status = [string]$Result.ToolStatus; Result = [string]$Result.VersionAfter }
        [pscustomobject]@{ Name = 'Serena initialization'; Status = [string]$Result.InitializationStatus; Result = $(if ($Result.InitializationStatus -eq 'Existing') { '保留既有設定' } else { '全域設定已初始化' }) }
        [pscustomobject]@{ Name = 'Serena Dashboard'; Status = [string]$Result.DashboardStatus; Result = 'Dashboard viewer disabled' }
        [pscustomobject]@{ Name = 'Serena Dashboard auto-open'; Status = [string]$Result.DashboardAutoOpenStatus; Result = [string]$Result.DashboardConfigStatus }
        [pscustomobject]@{ Name = 'Serena Codex MCP'; Status = [string]$Result.CodexMcpStatus; Result = 'serena start-mcp-server --context=codex --project-from-cwd' }
        [pscustomobject]@{ Name = 'Serena MCP runtime'; Status = [string]$Result.RuntimeStatus; Result = '請重新啟動 Codex，並以 /mcp 確認 connected' }
    )
}
