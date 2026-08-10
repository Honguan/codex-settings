$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')
. (Get-OptionalInstallationScriptPath -Name CodexOrchestration)

$script:readHostValues = New-Object 'System.Collections.Generic.Queue[string]'
function Read-Host {
    param([string]$Prompt)
    if ($script:readHostValues.Count -eq 0) { return '' }
    return $script:readHostValues.Dequeue()
}

$getStateImplementation = (Get-Command Get-CodexOrchestrationInstallationState -CommandType Function).ScriptBlock
$script:stateQueried = $false
function Get-CodexOrchestrationInstallationState { $script:stateQueried = $true; throw '不應查詢 plugin state' }
$script:readHostValues.Enqueue('')
if ((Select-OptionalCodexOrchestration) -ne 'Install') { throw 'Codex-Orchestration 首次安裝直接 Enter 應預設安裝。' }
if ($script:stateQueried) { throw '未選用 Codex-Orchestration 時不得查詢 marketplace 或 plugin。' }
Set-Item -Path Function:Get-CodexOrchestrationInstallationState -Value $getStateImplementation

$script:codexCommandIndex = 0
function Invoke-CodexOrchestrationCodexCommand {
    param([string[]]$Arguments)
    $script:codexCommandIndex++
    $joined = $Arguments -join ' '
    if ($joined -eq 'plugin marketplace list') {
        return [pscustomobject]@{ ExitCode = 0; Output = @($(if ($script:codexCommandIndex -gt 4) { 'codex-orchestration  Cjbuilds/Codex-Orchestration' } else { '' })) }
    }
    if ($joined -eq 'plugin list --json') {
        $installed = if ($script:codexCommandIndex -gt 4) { @([pscustomobject]@{ pluginId = 'codex-orchestration@codex-orchestration'; version = '0.9.0' }) } else { @() }
        return [pscustomobject]@{ ExitCode = 0; Output = @(([pscustomobject]@{ installed = $installed } | ConvertTo-Json -Depth 4 -Compress)) }
    }
    return [pscustomobject]@{ ExitCode = 0; Output = @('installed') }
}
$installed = Invoke-CodexOrchestrationInstallation -InteractiveWorkflow:$false
if (-not $installed.InstalledNow -or $installed.PluginStatus -ne 'Installed' -or $installed.WorkflowStatus -ne 'NotConfigured') { throw '非互動 plugin-only 安裝狀態錯誤。' }
if ($script:codexCommandIndex -ne 6) { throw "Codex-Orchestration 安裝命令序列錯誤：$script:codexCommandIndex" }

$script:codexCommandIndex = 0
$script:readHostValues.Clear()
foreach ($value in @('', '', '', '2', '')) { $script:readHostValues.Enqueue($value) }
$requested = Invoke-CodexOrchestrationInstallation -InteractiveWorkflow:$true
if ($requested.PluginStatus -ne 'Installed' -or $requested.WorkflowStatus -ne 'ActionRequired' -or -not $requested.WorkflowRequested -or -not $requested.ActionRequired) { throw '新安裝且要求 workflow 時未分離 plugin 與 ActionRequired 狀態。' }

function Invoke-CodexOrchestrationCodexCommand {
    param([string[]]$Arguments)
    $joined = $Arguments -join ' '
    if ($joined -eq 'plugin marketplace list') { return [pscustomobject]@{ ExitCode = 0; Output = @('codex-orchestration  Cjbuilds/Codex-Orchestration') } }
    if ($joined -eq 'plugin list --json') { return [pscustomobject]@{ ExitCode = 0; Output = @('{"installed":[{"pluginId":"codex-orchestration@codex-orchestration","version":"0.9.0"}]}') } }
    return [pscustomobject]@{ ExitCode = 0; Output = @('unchanged') }
}
$script:readHostValues.Clear()
$script:readHostValues.Enqueue('1')
$preserved = Invoke-CodexOrchestrationInstallation -InteractiveWorkflow:$true
if ($preserved.WorkflowStatus -ne 'Preserved' -or $preserved.WorkflowRequested -or $preserved.SetupPrompt) { throw '既有 plugin 保留 workflow 時不應產生 Setup Prompt。' }

$script:readHostValues.Clear()
foreach ($value in @('2', '', '', '', '2', '')) { $script:readHostValues.Enqueue($value) }
$reconfigured = Invoke-CodexOrchestrationInstallation -InteractiveWorkflow:$true
if ($reconfigured.WorkflowStatus -ne 'ActionRequired' -or -not $reconfigured.SetupPrompt.Contains('executor: GPT-5.6 Luna Extra High')) { throw '既有 plugin 重新設定時未產生完整 Setup Prompt。' }

function Assert-Command { param([string]$Name) }
function Invoke-CodexOrchestrationVersionCommand {
    param([string]$Command)
    if ($Command -eq 'codex') { return [pscustomobject]@{ ExitCode = 0; Output = 'codex-cli 1.2.3' } }
    return [pscustomobject]@{ ExitCode = 0; Output = 'Python 3.11.9' }
}
$prerequisites = Assert-CodexOrchestrationPrerequisites
if ($prerequisites.PythonVersion -ne 'Python 3.11.9') { throw 'Python 3.11+ 前置檢查結果錯誤。' }

function Invoke-CodexOrchestrationVersionCommand {
    param([string]$Command)
    if ($Command -eq 'codex') { return [pscustomobject]@{ ExitCode = 0; Output = 'codex-cli 1.2.3' } }
    return [pscustomobject]@{ ExitCode = 0; Output = 'Python 3.10.14' }
}
$pythonRejected = $false
try { [void](Assert-CodexOrchestrationPrerequisites) } catch { $pythonRejected = $_.Exception.Message -match 'Python 3.11' -and $_.Exception.Message -match '3.10.14' }
if (-not $pythonRejected) { throw 'Python 3.11 以下版本未被清楚拒絕。' }

$script:readHostValues.Clear()
foreach ($value in @('', '', '', '2', '')) { $script:readHostValues.Enqueue($value) }
$minimal = Select-CodexOrchestrationWorkflow
if ($minimal.Status -ne 'ActionRequired' -or $minimal.Roles.Planner.Enabled -or $minimal.Roles.Advisor.Enabled -or $minimal.Roles.Designer.Enabled) { throw '精簡模式角色預設錯誤。' }
if ($minimal.SetupPrompt -ne '$codex-orchestration:codex-orchestration setup executor: GPT-5.6 Luna Extra High') { throw "精簡模式 setup Prompt 錯誤：$($minimal.SetupPrompt)" }

$multiRolePrompt = ConvertTo-CodexOrchestrationSetupPrompt -Roles ([pscustomobject]@{
    Planner = [pscustomobject]@{ Enabled = $true; Model = 'Planner Model'; Effort = 'High' }
    Advisor = [pscustomobject]@{ Enabled = $true; Model = 'Advisor Model'; Effort = 'Extra High' }
    Designer = [pscustomobject]@{ Enabled = $true; Model = 'Designer Model'; Effort = 'Medium' }
    Executor = [pscustomobject]@{ Enabled = $true; Model = 'Executor Model'; Effort = 'XHigh' }
})
if ($multiRolePrompt -ne '$codex-orchestration:codex-orchestration setup planner: Planner Model High, advisor: Advisor Model Extra High, designer: Designer Model Medium, executor: Executor Model XHigh') { throw '多角色 Setup Prompt 順序或模型／effort 遺失。' }

$script:readHostValues.Clear()
foreach ($value in @('', '2', '', '', '', '3', 'GPT-5.6 Sol', '3', 'XHigh', '')) { $script:readHostValues.Enqueue($value) }
$custom = Select-CodexOrchestrationWorkflow
if ($custom.SetupPrompt -ne '$codex-orchestration:codex-orchestration setup executor: GPT-5.6 Sol XHigh') { throw '自訂模式未保留 Root Planner 與關閉 Advisor / Designer。' }

$script:readHostValues.Clear()
$script:readHostValues.Enqueue('n')
$skippedWorkflow = Select-CodexOrchestrationWorkflow
if ($skippedWorkflow.Status -ne 'NotConfigured' -or $skippedWorkflow.Requested) { throw '只安裝 plugin 時 workflow 狀態錯誤。' }

$stepsWithout = @(New-InstallationProgressSteps)
if ($stepsWithout.Id -contains 'CodexOrchestration') { throw '未選用時不應建立 Codex-Orchestration 進度 Step。' }
$stepsWith = @(New-InstallationProgressSteps -IncludeCodexOrchestration)
if ($stepsWith.Id -notcontains 'CodexOrchestration') { throw '選用時缺少 Codex-Orchestration 進度 Step。' }
if ((Get-InstallResultSymbol -Status 'ActionRequired') -ne '!' -or (Get-InstallResultSymbol -Status 'NotConfigured') -ne '-') { throw 'Workflow 最終摘要符號錯誤。' }
$workflowComponent = @(Get-CodexOrchestrationInstallationComponents -Result $requested | Where-Object Name -eq 'Codex-Orchestration workflow')[0]
if ($workflowComponent.Status -ne 'ActionRequired' -or -not $workflowComponent.Result.Contains($requested.SetupPrompt) -or $workflowComponent.Result -notmatch '不是 PowerShell') { throw 'Workflow 最終摘要未完整顯示可直接貼上的 Setup Prompt。' }

$entrySource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'install.ps1') -Raw
foreach ($parameter in @('InstallCodexOrchestration', 'SkipCodexOrchestration')) {
    if ($entrySource -notmatch ('\[switch\]\$' + $parameter)) { throw "非互動入口缺少參數：$parameter" }
}
$runnerSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'installation\installation-runner.ps1') -Raw
foreach ($field in @('pluginManaged', 'pluginPresent', 'pluginStatus', 'pluginUpdatedThisRun', 'workflowRequested', 'workflowManaged', 'workflowConfigured', 'workflowEffective', 'workflowStatus', 'setupPrompt', 'actionRequired', 'lastVerified')) {
    if ($runnerSource -notmatch [regex]::Escape($field)) { throw "Manifest 缺少 Codex-Orchestration 欄位：$field" }
}
if ($runnerSource -notmatch '\$codexOrchestration\.ActionRequired' -or $runnerSource -notmatch "'PARTIAL SUCCESS'") { throw 'ActionRequired 未影響 aggregate result。' }
if ($runnerSource -match "codex-orchestration:codex-orchestration',\s*'setup" -or $runnerSource -match 'plugin\s+workflow\s+setup') { throw 'Installer 不得執行 Setup Prompt 或猜測不存在的 workflow CLI。' }

Write-Host 'Codex-Orchestration tests passed.'
