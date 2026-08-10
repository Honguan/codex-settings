function Invoke-CodexOrchestrationCodexCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & codex @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { [string]$_ }) }
}

function Invoke-CodexOrchestrationVersionCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Command)

    $output = & $Command --version 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($output | Out-String).Trim()) }
}

function Assert-CodexOrchestrationPrerequisites {
    Assert-Command 'codex'
    Assert-Command 'python'
    $codex = Invoke-CodexOrchestrationVersionCommand -Command 'codex'
    if ($codex.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($codex.Output)) {
        throw 'Codex-Orchestration 需要可用的 Codex CLI。請確認 codex --version 可執行後再重試。'
    }
    $python = Invoke-CodexOrchestrationVersionCommand -Command 'python'
    if ($python.ExitCode -ne 0 -or $python.Output -notmatch '(?i)Python\s+(?<major>\d+)\.(?<minor>\d+)(?:\.(?<patch>\d+))?') {
        throw 'Codex-Orchestration 需要 Python 3.11 以上，但目前無法解析 python --version。請先安裝或更新 Python 後重新執行安裝。'
    }
    $version = [version]::new([int]$Matches.major, [int]$Matches.minor, $(if ($Matches.patch) { [int]$Matches.patch } else { 0 }))
    if ($version -lt [version]'3.11.0') {
        throw "Codex-Orchestration 需要 Python 3.11 以上。`n目前版本：$($python.Output)`n請先升級 Python 後重新執行安裝。"
    }
    return [pscustomobject]@{ CodexVersion = $codex.Output; PythonVersion = $python.Output }
}

function Get-CodexOrchestrationInstallationState {
    $marketplaces = Invoke-CodexOrchestrationCodexCommand -Arguments @('plugin', 'marketplace', 'list')
    if ($marketplaces.ExitCode -ne 0) { throw "無法讀取 Codex plugin marketplace 狀態：$($marketplaces.Output -join [Environment]::NewLine)" }
    $plugins = Invoke-CodexOrchestrationCodexCommand -Arguments @('plugin', 'list', '--json')
    if ($plugins.ExitCode -ne 0) { throw "無法讀取 Codex plugin 狀態：$($plugins.Output -join [Environment]::NewLine)" }
    try { $pluginList = ($plugins.Output -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Codex plugin list 回傳無法解析的 JSON：$($_.Exception.Message)" }

    $plugin = @($pluginList.installed | Where-Object { [string]$_.pluginId -eq $script:CodexOrchestrationPluginId } | Select-Object -First 1)[0]
    return [pscustomobject]@{
        MarketplacePresent = (($marketplaces.Output -join "`n") -match '(?m)^\s*codex-orchestration\s+')
        PluginPresent = $null -ne $plugin
        Version = if ($null -ne $plugin) { [string]$plugin.version } else { '' }
    }
}

function Select-CodexOrchestrationExistingAction {
    Write-Host ''
    Write-Host '已偵測到 Codex-Orchestration。'
    Write-Host '[1] 更新外掛，保留目前 workflow（建議）'
    Write-Host '[2] 更新外掛並重新設定 workflow'
    Write-Host '[3] 保持現狀，不更新'
    switch (Read-Host '請選擇 [1]') {
        '' { return 'UpdatePreserve' }
        '1' { return 'UpdatePreserve' }
        '2' { return 'UpdateReconfigure' }
        '3' { return 'KeepCurrent' }
        default { throw 'Codex-Orchestration 更新選項無效。' }
    }
}

function Read-CodexOrchestrationFreeText([string]$Prompt) {
    $value = (Read-Host $Prompt).Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[,\r\n]') {
        throw '輸入不可為空，且不可包含逗號或換行。'
    }
    return $value
}

function Select-CodexOrchestrationModel([string]$Role) {
    Write-Host "請選擇 $Role 模型："
    Write-Host '[1] GPT-5.6 Luna'
    Write-Host '[2] GPT-5.6 Terra'
    Write-Host '[3] 其他 / 手動輸入'
    switch (Read-Host '請選擇 [1]') {
        '' { return 'GPT-5.6 Luna' }
        '1' { return 'GPT-5.6 Luna' }
        '2' { return 'GPT-5.6 Terra' }
        '3' { return Read-CodexOrchestrationFreeText -Prompt "請輸入 $Role 模型" }
        default { throw "$Role 模型選項無效。" }
    }
}

function Select-CodexOrchestrationEffort([string]$Role) {
    Write-Host "$Role 推理強度："
    Write-Host '[1] High'
    Write-Host '[2] Extra High'
    Write-Host '[3] 其他支援值 / 手動輸入'
    switch (Read-Host '請選擇 [1]') {
        '' { return 'High' }
        '1' { return 'High' }
        '2' { return 'Extra High' }
        '3' { return Read-CodexOrchestrationFreeText -Prompt "請輸入 $Role reasoning effort" }
        default { throw "$Role 推理強度選項無效。" }
    }
}

function New-CodexOrchestrationRole([string]$Name, [bool]$Enabled) {
    if (-not $Enabled) { return [pscustomobject]@{ Name = $Name; Enabled = $false; Model = ''; Effort = '' } }
    return [pscustomobject]@{
        Name = $Name
        Enabled = $true
        Model = Select-CodexOrchestrationModel -Role $Name
        Effort = Select-CodexOrchestrationEffort -Role $Name
    }
}

function ConvertTo-CodexOrchestrationSetupPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roles,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($role in @('Planner', 'Advisor', 'Designer', 'Executor')) {
        $entry = $Roles.$role
        if ([bool]$entry.Enabled) { [void]$parts.Add(('{0}: {1} {2}' -f $role.ToLowerInvariant(), $entry.Model, $entry.Effort)) }
    }
    $configPath = [IO.Path]::GetFullPath((Join-Path $Root 'config.toml'))
    return '$codex-orchestration:codex-orchestration setup ' + ($parts -join ', ') + "`n套用 setup 前，確認 Config 路徑完全等於「$configPath」。若不同或包含 CodexSandboxOffline，請停止、回報路徑不一致，且不得寫入 routing policy。"
}

function Write-CodexOrchestrationPreview($Roles) {
    Write-Host ''
    Write-Host 'Codex-Orchestration 設定預覽'
    Write-Host ''
    Write-Host 'Root / Main Codex : 使用目前 /model 選擇'
    Write-Host ('Planner           : ' + $(if ($Roles.Planner.Enabled) { "$($Roles.Planner.Model) $($Roles.Planner.Effort)" } else { 'Root 主模型（未額外建立）' }))
    Write-Host ('Advisor           : ' + $(if ($Roles.Advisor.Enabled) { "$($Roles.Advisor.Model) $($Roles.Advisor.Effort)" } else { 'Off' }))
    Write-Host ('Designer          : ' + $(if ($Roles.Designer.Enabled) { "$($Roles.Designer.Model) $($Roles.Designer.Effort)" } else { 'Off' }))
    Write-Host ("Executor          : $($Roles.Executor.Model) $($Roles.Executor.Effort)")
    Write-Host ''
    Write-Host '預期流程：Root 規劃 / 協調 → Executor 實作 / 改檔 / 測試 → Root 驗證 / 最終回答'
}

function Select-CodexOrchestrationWorkflow {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    Write-Host ''
    Write-Host 'Codex-Orchestration 已安裝。'
    Write-Host '工作流設定必須在安裝後的新 Codex Task 中完成。'
    Write-Host '安裝程式只會產生完整 Setup Prompt，不會把 Codex 對話 Prompt 當成終端機命令執行。'
    Write-Host ''
    if (-not (Read-YesNoChoice -Prompt '要產生工作流 Setup Prompt 嗎？[Y/n]' -Default $true)) {
        return [pscustomobject]@{ Requested = $false; Status = 'NotConfigured'; SetupPrompt = ''; Roles = $null }
    }

    while ($true) {
        Write-Host ''
        Write-Host 'Codex-Orchestration 工作流設定'
        Write-Host '目前 Codex 主模型會繼續掌握主 Task、協調與最終驗證。'
        Write-Host '[1] 精簡模式：主模型規劃 + Executor 實作'
        Write-Host '[2] 自訂角色'
        Write-Host '[3] 暫不設定'
        $mode = switch (Read-Host '請選擇 [1]') {
            '' { 'Minimal' }
            '1' { 'Minimal' }
            '2' { 'Custom' }
            '3' { 'Skip' }
            default { throw 'Codex-Orchestration workflow 模式無效。' }
        }
        if ($mode -eq 'Skip') { return [pscustomobject]@{ Requested = $false; Status = 'NotConfigured'; SetupPrompt = ''; Roles = $null } }

        $plannerEnabled = $false
        $advisorEnabled = $false
        $designerEnabled = $false
        if ($mode -eq 'Custom') {
            Write-Host 'Planner：負責規劃與拆任務。若不設定，會由目前 Codex 主模型直接負責規劃。'
            $plannerEnabled = Read-YesNoChoice -Prompt '要另外指定 Planner 嗎？[y/N]' -Default $false
            Write-Host 'Advisor：獨立審查計畫，會增加額外模型呼叫與 Token 消耗；Planner / Advisor 應使用獨立模型路由。'
            $advisorEnabled = Read-YesNoChoice -Prompt '要啟用 Advisor 嗎？[y/N]' -Default $false
            Write-Host 'Designer：針對 UI / UX / Frontend / Dashboard 等任務產出設計 handoff；一般非 UI 專案通常不需要。'
            $designerEnabled = Read-YesNoChoice -Prompt '要啟用 Designer 嗎？[y/N]' -Default $false
        }
        Write-Host 'Executor：負責真正實作、改檔、補測試與機械性重構。'
        $roles = [pscustomobject]@{
            Planner = New-CodexOrchestrationRole -Name 'Planner' -Enabled $plannerEnabled
            Advisor = New-CodexOrchestrationRole -Name 'Advisor' -Enabled $advisorEnabled
            Designer = New-CodexOrchestrationRole -Name 'Designer' -Enabled $designerEnabled
            Executor = New-CodexOrchestrationRole -Name 'Executor' -Enabled $true
        }
        Write-CodexOrchestrationPreview -Roles $roles
        if (Read-YesNoChoice -Prompt '要產生這個 workflow Setup Prompt 嗎？[Y/n]' -Default $true) {
            return [pscustomobject]@{ Requested = $true; Status = 'ActionRequired'; SetupPrompt = ConvertTo-CodexOrchestrationSetupPrompt -Roles $roles -Root $Root; Roles = $roles }
        }
    }
}

function Invoke-CodexOrchestrationInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [bool]$InteractiveWorkflow = $false
    )

    $before = Get-CodexOrchestrationInstallationState
    $action = if ($before.PluginPresent -and $InteractiveWorkflow) { Select-CodexOrchestrationExistingAction } elseif ($before.PluginPresent) { 'UpdatePreserve' } else { 'Install' }
    if ($action -eq 'KeepCurrent') {
        return [pscustomobject]@{ Managed = $false; PluginPresent = $true; WasInstalledBefore = $true; InstalledNow = $false; UpdatedNow = $false; MarketplaceStatus = 'Current'; PluginStatus = 'Current'; PluginVersion = $before.Version; WorkflowRequested = $false; WorkflowManaged = $false; WorkflowConfigured = $false; WorkflowEffective = $false; WorkflowStatus = 'Preserved'; WorkflowConfigurationSummary = 'Existing workflow preserved'; SetupPrompt = ''; ActionRequired = $false; LastVerified = (Get-Date).ToString('o') }
    }

    $marketplace = if ($before.MarketplacePresent) {
        Invoke-CodexOrchestrationCodexCommand -Arguments @('plugin', 'marketplace', 'upgrade', $script:CodexOrchestrationMarketplaceName, '--json')
    } else {
        Invoke-CodexOrchestrationCodexCommand -Arguments @('plugin', 'marketplace', 'add', $script:CodexOrchestrationMarketplaceSource, '--json')
    }
    if ($marketplace.ExitCode -ne 0) { throw "Codex-Orchestration marketplace 處理失敗：$($marketplace.Output -join [Environment]::NewLine)" }
    $plugin = Invoke-CodexOrchestrationCodexCommand -Arguments @('plugin', 'add', $script:CodexOrchestrationPluginId, '--json')
    if ($plugin.ExitCode -ne 0) { throw "Codex-Orchestration plugin 安裝/更新失敗：$($plugin.Output -join [Environment]::NewLine)" }
    $after = Get-CodexOrchestrationInstallationState
    if (-not $after.PluginPresent) { throw 'Codex-Orchestration plugin 指令完成後仍未出現在 Codex plugin list。' }

    $pluginStatus = if (-not $before.PluginPresent) { 'Installed' } elseif (($plugin.Output -join "`n") -match '(?i)unchanged|current|already installed') { 'Current' } else { 'Updated' }
    $shouldConfigure = $InteractiveWorkflow -and (-not $before.PluginPresent -or $action -eq 'UpdateReconfigure')
    $workflow = if ($shouldConfigure) { Select-CodexOrchestrationWorkflow -Root $Root } else { [pscustomobject]@{ Requested = $false; Status = $(if ($before.PluginPresent) { 'Preserved' } else { 'NotConfigured' }); SetupPrompt = ''; Roles = $null } }
    $summary = if ($null -ne $workflow.Roles) {
        "Planner=$(if ($workflow.Roles.Planner.Enabled) { $workflow.Roles.Planner.Model + ' ' + $workflow.Roles.Planner.Effort } else { 'Root current model' }); Advisor=$(if ($workflow.Roles.Advisor.Enabled) { $workflow.Roles.Advisor.Model + ' ' + $workflow.Roles.Advisor.Effort } else { 'Off' }); Designer=$(if ($workflow.Roles.Designer.Enabled) { $workflow.Roles.Designer.Model + ' ' + $workflow.Roles.Designer.Effort } else { 'Off' }); Executor=$($workflow.Roles.Executor.Model) $($workflow.Roles.Executor.Effort)"
    } else { $(if ($workflow.Status -eq 'Preserved') { 'Existing workflow preserved' } else { 'Workflow not configured' }) }

    return [pscustomobject]@{
        Managed = $true
        PluginPresent = $true
        WasInstalledBefore = [bool]$before.PluginPresent
        InstalledNow = -not [bool]$before.PluginPresent
        UpdatedNow = $pluginStatus -eq 'Updated'
        MarketplaceStatus = if ($before.MarketplacePresent) { 'Updated' } else { 'Installed' }
        PluginStatus = $pluginStatus
        PluginVersion = $after.Version
        WorkflowRequested = [bool]$workflow.Requested
        WorkflowManaged = $false
        WorkflowConfigured = $false
        WorkflowEffective = $false
        WorkflowStatus = [string]$workflow.Status
        WorkflowConfigurationSummary = $summary
        SetupPrompt = [string]$workflow.SetupPrompt
        ActionRequired = $workflow.Status -eq 'ActionRequired'
        LastVerified = (Get-Date).ToString('o')
    }
}

function Undo-CodexOrchestrationInstallation($Result) {
    if ($null -eq $Result -or -not [bool]$Result.InstalledNow) { return }
    $remove = Invoke-CodexOrchestrationCodexCommand -Arguments @('plugin', 'remove', $script:CodexOrchestrationPluginId)
    if ($remove.ExitCode -ne 0) { throw "Codex-Orchestration rollback failed: $($remove.Output -join [Environment]::NewLine)" }
}

function Invoke-CodexOrchestrationUninstall {
    $before = Get-CodexOrchestrationInstallationState
    if (-not $before.PluginPresent) { return (New-CodexOrchestrationSkippedResult | Add-Member -NotePropertyName Status -NotePropertyValue 'Unchanged' -PassThru) }
    $remove = Invoke-CodexOrchestrationCodexCommand -Arguments @('plugin', 'remove', $script:CodexOrchestrationPluginId)
    if ($remove.ExitCode -ne 0) { throw "Codex-Orchestration 解除安裝失敗：$($remove.Output -join [Environment]::NewLine)" }
    $result = New-CodexOrchestrationSkippedResult
    $result.PluginPresent = $false
    $result.PluginStatus = 'Uninstalled'
    $result.WorkflowStatus = 'Uninstalled'
    $result | Add-Member -NotePropertyName Status -NotePropertyValue 'Uninstalled'
    return $result
}
