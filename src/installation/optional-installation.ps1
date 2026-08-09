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
    if ($AlreadyInstalled) {
        Write-Host '已偵測到既有 Ponytail 安裝，本次會保留並更新。'
        return Read-YesNoChoice -Prompt '要繼續安裝/更新嗎？[Y/n]' -Default $true
    }
    return Read-YesNoChoice -Prompt '要安裝嗎？[Y/n]' -Default $true
}

function Select-OptionalCodexOrchestration {
    Write-Host ''
    Write-Host '選用全域功能：Codex-Orchestration'
    Write-Host '多模型／多角色 Codex 工作流，可設定 Planner、Advisor、Designer、Executor。'
    Write-Host '預設不安裝；只有明確選擇後才會加入 Codex plugin。'
    return Read-YesNoChoice -Prompt '要安裝嗎？[y/N]' -Default $false
}

function Select-OptionalSerena {
    Write-Host ''
    Write-Host '選用全域功能：Serena'
    Write-Host '提供語意程式碼搜尋、分析與編輯能力，並透過 MCP 連接 Codex。'
    Write-Host '預設安裝；如果已安裝則會保留設定並更新。'
    return Read-YesNoChoice -Prompt '要安裝/更新嗎？[Y/n]' -Default $true
}

function Select-SerenaUvInstallation {
    Write-Host '未偵測到 uv。Serena 需要 uv。'
    Write-Host '會使用官方 Windows 安裝方式：winget install --id astral-sh.uv -e。'
    return Read-YesNoChoice -Prompt '是否使用官方安裝方式安裝 uv？[Y/n]' -Default $true
}

function New-PonytailSkippedResult([bool]$AlreadyInstalled = $false) {
    return [pscustomobject]@{ Managed = $false; WasInstalledBefore = $AlreadyInstalled; InstalledNow = $false; UpdatedNow = $false; MarketplaceStatus = 'SkippedByUser'; MarketplaceAddedNow = $false; MarketplaceSwitchedNow = $false; MarketplaceRecoveredNow = $false; OriginalMarketplaceSource = ''; MarketplaceSource = ''; PluginStatus = 'SkippedByUser'; PluginVersion = ''; HookCount = 0; TrustedHookCount = 0; HookIdentities = @(); ValidationStatus = 'SkippedByUser'; TrustStatus = 'SkippedByUser'; ValidationError = '' }
}

function New-CodexOrchestrationSkippedResult {
    return [pscustomobject]@{ Managed = $false; PluginPresent = $null; WasInstalledBefore = $false; InstalledNow = $false; UpdatedNow = $false; MarketplaceStatus = 'SkippedByUser'; PluginStatus = 'SkippedByUser'; PluginVersion = ''; WorkflowRequested = $false; WorkflowManaged = $false; WorkflowConfigured = $false; WorkflowEffective = $false; WorkflowStatus = 'SkippedByUser'; WorkflowConfigurationSummary = ''; SetupPrompt = ''; ActionRequired = $false; LastVerified = $null }
}

function New-SerenaSkippedResult {
    return [pscustomobject]@{ Managed = $false; SelectedByUser = $false; UvAvailable = $false; UvVersion = ''; VersionBefore = ''; VersionAfter = ''; InstalledNow = $false; UpdatedNow = $false; ToolStatus = 'SkippedByUser'; InitializationStatus = 'SkippedByUser'; CodexMcpStatus = 'SkippedByUser'; RuntimeStatus = 'SkippedByUser' }
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
        [pscustomobject]@{ Name = 'Serena Codex MCP'; Status = [string]$Result.CodexMcpStatus; Result = 'serena start-mcp-server --context=codex --project-from-cwd' }
        [pscustomobject]@{ Name = 'Serena MCP runtime'; Status = [string]$Result.RuntimeStatus; Result = '請重新啟動 Codex，並以 /mcp 確認 connected' }
    )
}
