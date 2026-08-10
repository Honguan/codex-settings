$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$matrix = @(
    @('NotInstalled', 'Default', 'Install'), @('NotInstalled', 'Yes', 'Install'), @('NotInstalled', 'No', 'SkipNotInstalled'),
    @('InstalledCurrent', 'Default', 'KeepCurrent'), @('InstalledCurrent', 'Yes', 'KeepCurrent'), @('InstalledCurrent', 'No', 'Uninstall'),
    @('InstalledUpdateAvailable', 'Default', 'Update'), @('InstalledUpdateAvailable', 'Yes', 'Update'), @('InstalledUpdateAvailable', 'No', 'Uninstall'),
    @('InstalledNeedsMigration', 'Default', 'Update'), @('InstalledNeedsMigration', 'Yes', 'Update'), @('InstalledNeedsMigration', 'No', 'Uninstall'),
    @('InstalledNeedsRepair', 'Default', 'Repair'), @('InstalledNeedsRepair', 'Yes', 'Repair'), @('InstalledNeedsRepair', 'No', 'Uninstall'),
    @('ManagedPartialState', 'Default', 'Repair'), @('ManagedPartialState', 'Yes', 'Repair'), @('ManagedPartialState', 'No', 'Uninstall'),
    @('ManagedDuplicateState', 'Default', 'Repair'), @('ManagedDuplicateState', 'Yes', 'Repair'), @('ManagedDuplicateState', 'No', 'Uninstall'),
    @('InstalledCurrent', 'LeaveUnchanged', 'LeaveUnchanged'), @('NotInstalled', 'LeaveUnchanged', 'SkipNotInstalled'),
    @('TrueUnmanagedConflict', 'Default', 'Blocked'), @('MalformedUserOwnedState', 'No', 'Blocked'), @('Conflict', 'Default', 'Blocked'), @('Unknown', 'No', 'Blocked')
)
foreach ($case in $matrix) {
    $actual = Resolve-OptionalComponentAction -State $case[0] -Selection $case[1]
    if ($actual -ne $case[2]) { throw "Lifecycle mismatch: $($case -join '/') => $actual" }
}

foreach ($case in @(@($false, $false, '', 'SkipNotInstalled'), @($false, $true, '', 'Install'), @($true, $false, '', 'KeepCurrent'), @($true, $false, 'Uninstall', 'Uninstall'))) {
    $actual = Get-OptionalComponentPlanAction -Installed $case[0] -Requested $case[1] -ExplicitAction $case[2]
    if ($actual -ne $case[3]) { throw "Noninteractive lifecycle mismatch: $($case -join '/') => $actual" }
}

$script:answers = [Collections.Queue]::new()
function Read-Host([string]$Prompt) { if ($script:answers.Count) { return $script:answers.Dequeue() }; return '' }
if ((Select-OptionalComponentAction -Name Test -State NotInstalled) -ne 'Install') { throw 'First-install Enter did not install.' }
$script:answers.Enqueue('y'); if ((Select-OptionalComponentAction -Name Test -State NotInstalled) -ne 'Install') { throw 'First-install Yes did not install.' }
$script:answers.Enqueue('n'); if ((Select-OptionalComponentAction -Name Test -State NotInstalled) -ne 'SkipNotInstalled') { throw 'First-install No did not skip.' }
foreach ($state in @('InstalledCurrent', 'InstalledUpdateAvailable', 'InstalledNeedsMigration', 'InstalledNeedsRepair', 'ManagedPartialState', 'ManagedDuplicateState')) {
    $expected = Resolve-OptionalComponentAction -State $state
    if ((Select-OptionalComponentAction -Name Test -State $state) -ne $expected) { throw "$state Enter did not select $expected." }
    $script:answers.Enqueue('n'); if ((Select-OptionalComponentAction -Name Test -State $state) -ne 'Uninstall') { throw "$state No did not uninstall." }
}

$config = "x = 1`r`n`r`n[features]`r`ndefault_mode_request_user_input = true`r`nother = true`r`n"
$removed = Remove-DefaultModeRequestUserInputFeature -Content $config
if ($removed -match 'default_mode_request_user_input' -or $removed -notmatch 'other = true' -or (Remove-DefaultModeRequestUserInputFeature $removed) -ne $removed) { throw 'request_user_input uninstall is not owned/idempotent.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-lifecycle-' + [guid]::NewGuid().ToString('N'))
try {
    $managed = Join-Path $testRoot 'request-execution-optimizer'
    New-Item -ItemType Directory -Path $managed -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $managed 'SKILL.md'), 'managed')
    $transaction = New-FileTransaction -Root (Join-Path $testRoot 'transaction') -Mode Lifecycle
    if ((Remove-OptionalManagedDirectory -Path $managed -Transaction $transaction) -ne 'Uninstalled' -or (Test-Path $managed)) { throw 'Managed directory was not uninstalled.' }
    Undo-FileTransaction $transaction | Out-Null
    if ([IO.File]::ReadAllText((Join-Path $managed 'SKILL.md')) -ne 'managed') { throw 'Managed directory uninstall did not roll back.' }
} finally { if (Test-Path $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force } }

$manifest = New-InstallationOwnershipManifest
foreach ($component in @($manifest.personal.requestExecutionOptimizer, $manifest.personal.requestUserInput, $manifest.otherSettings.longRunningAsyncWait, $manifest.community.windowsUsageNotifications, $manifest.community.mattpocockSkills, $manifest.community.ponytail, $manifest.community.codexOrchestration, $manifest.community.serena)) {
    foreach ($field in @('Action', 'DiscoveredState')) { if (-not $component.Contains($field)) { throw "Manifest component is missing $field." } }
}

$runner = [IO.File]::ReadAllText((Join-Path $script:ScriptRoot 'installation\installation-runner.ps1'))
foreach ($required in @('Invoke-WindowsUsageNotificationFiles', 'Invoke-MattPocockSkillsUninstall', 'Invoke-PonytailUninstall', 'Invoke-CodexOrchestrationUninstall', 'Invoke-SerenaUninstall', "-eq 'Uninstall'", 'SkippedNotInstalled', 'LeftUnchanged')) {
    if (-not $runner.Contains($required)) { throw "Lifecycle execution/summary is missing: $required" }
}

function npx { $global:LASTEXITCODE = 0; $script:npxArguments = @($args); return 'removed' }
function Test-MattPocockSkillsInstalled { return $true }
if ((Invoke-MattPocockSkillsUninstall).Status -ne 'Uninstalled' -or $script:npxArguments -notcontains 'remove') { throw 'mattpocock/skills uninstall did not use the managed CLI removal path.' }

. (Get-OptionalInstallationScriptPath -Name Ponytail)
$script:ponytailCommands = @()
function Invoke-PonytailCodexCommand([string[]]$Arguments) { $script:ponytailCommands += ($Arguments -join ' '); return [pscustomobject]@{ ExitCode = 0; Output = @('ok') } }
$ponytailState = [pscustomobject]@{ PluginPresent = $true; MarketplacePluginIds = @($script:PonytailPluginId, 'other@ponytail'); SourceRelationship = 'Exact' }
if ((Invoke-PonytailUninstall -State $ponytailState).Status -ne 'Uninstalled' -or $script:ponytailCommands -notcontains "plugin remove $script:PonytailPluginId" -or @($script:ponytailCommands | Where-Object { $_ -match 'marketplace remove' }).Count) { throw 'Ponytail uninstall did not preserve a shared marketplace.' }

. (Get-OptionalInstallationScriptPath -Name CodexOrchestration)
$script:orchestrationCommands = @()
function Get-CodexOrchestrationInstallationState { return [pscustomobject]@{ PluginPresent = $true } }
function Invoke-CodexOrchestrationCodexCommand([string[]]$Arguments) { $script:orchestrationCommands += ($Arguments -join ' '); return [pscustomobject]@{ ExitCode = 0; Output = @('ok') } }
if ((Invoke-CodexOrchestrationUninstall).Status -ne 'Uninstalled' -or $script:orchestrationCommands -notcontains "plugin remove $script:CodexOrchestrationPluginId") { throw 'Codex-Orchestration uninstall did not remove only its plugin.' }

. (Get-OptionalInstallationScriptPath -Name Serena)
$serenaRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-serena-uninstall-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $serenaRoot -Force | Out-Null
    $serenaConfig = "unrelated = true`r`n`r`n[mcp_servers.serena]`r`ncommand = `"serena`"`r`nargs = [`"start-mcp-server`", `"--context=codex`", `"--project-from-cwd`"]`r`n"
    [IO.File]::WriteAllText((Join-Path $serenaRoot 'config.toml'), $serenaConfig)
    $serenaTransaction = New-FileTransaction -Root (Join-Path $serenaRoot 'transaction') -Mode SerenaUninstall
    function Get-SerenaInstallationState { return [pscustomobject]@{ ToolPresent = $true } }
    function Invoke-SerenaCommand([string]$Command, [string[]]$Arguments) { $script:serenaArguments = $Arguments -join ' '; return [pscustomobject]@{ ExitCode = 0; Output = @('ok') } }
    $serenaResult = Invoke-SerenaUninstall -Root $serenaRoot -Transaction $serenaTransaction
    $after = [IO.File]::ReadAllText((Join-Path $serenaRoot 'config.toml'))
    if ($serenaResult.ToolStatus -ne 'Uninstalled' -or $script:serenaArguments -ne 'tool uninstall serena-agent' -or $after -notmatch 'unrelated = true' -or $after -match 'mcp_servers\.serena') { throw 'Serena uninstall crossed its ownership boundary.' }
} finally { if (Test-Path $serenaRoot) { Remove-Item -LiteralPath $serenaRoot -Recurse -Force } }

Write-Host 'Optional component lifecycle tests passed.'
