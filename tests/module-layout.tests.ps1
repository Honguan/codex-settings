$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repositoryRoot 'src'

$expectedFiles = @(
    'install.ps1',
    'load-core.ps1',
    'load-operations.ps1',
    'load-installation.ps1',
    'commands\backup-settings.ps1',
    'commands\restore-settings.ps1',
    'commands\uninstall-settings.ps1',
    'core\file-system.ps1',
    'core\models.ps1',
    'core\errors.ps1',
    'core\state-repository.ps1',
    'core\workflow-policy.ps1',
    'core\hook-configuration.ps1',
    'core\managed-content.ps1',
    'core\file-transactions.ps1',
    'installation\hook-trust.ps1',
    'installation\hook-validation.ps1',
    'installation\installation-context.ps1',
    'installation\installation-plan.ps1',
    'installation\discovery.ps1',
    'installation\execution.ps1',
    'installation\verification.ps1',
    'installation\commit.ps1',
    'installation\installation-progress.ps1',
    'installation\installation-runner.ps1',
    'installation\installation-state.ps1',
    'installation\prerequisites.ps1',
    'installation\prompts.ps1',
    'installation\target-installer.ps1',
    'integrations\ccusage-state.ps1',
    'integrations\context7.ps1',
    'integrations\external-state-recovery.ps1',
    'integrations\install-usage-tools.ps1'
)
foreach ($relativePath in $expectedFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relativePath) -PathType Leaf)) {
        throw "缺少架構檔案：$relativePath"
    }
}

foreach ($obsoletePath in @('installer.ps1', 'modules', 'operations')) {
    if (Test-Path -LiteralPath (Join-Path $sourceRoot $obsoletePath)) {
        throw "仍保留舊架構路徑：$obsoletePath"
    }
}

$script:ScriptRoot = $sourceRoot
. (Join-Path $sourceRoot 'load-installation.ps1')
foreach ($commandName in @(
    'Write-BytesAtomic',
    'Merge-TomlTemplate',
    'Merge-HooksJson',
    'New-FileTransaction',
    'Select-Mode',
    'Test-Prerequisites',
    'New-InstallerContext',
    'New-InstallationPlan',
    'Set-CodexSettingsHookTrust',
    'Start-InstallProgress',
    'Set-InstallProgress',
    'Complete-InstallStep',
    'Fail-InstallStep',
    'Write-InstallResult',
    'Invoke-TargetInstallation',
    'Get-InstallationDiscovery',
    'New-InstallationChangePlan',
    'Test-CodexWorkflowDecision',
    'Invoke-InstallationPlan',
    'Test-InstallationResult',
    'Complete-Installation',
    'New-HookInvocationContext',
    'New-HookHandlerDescriptor',
    'Read-CodexSettingsState',
    'Write-CodexSettingsState',
    'Set-Context7EnvironmentState',
    'Save-InstallationManifest',
    'Invoke-Installer'
)) {
    if (-not (Get-Command $commandName -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "載入安裝模組後缺少函式：$commandName"
    }
}

foreach ($obsoleteCommand in @('Resolve-GlobalTargets', 'Install-Target', 'Set-Context7Key', 'Write-Manifest')) {
    if (Get-Command $obsoleteCommand -CommandType Function -ErrorAction SilentlyContinue) {
        throw "仍載入舊安裝函式：$obsoleteCommand"
    }
}

$entrySource = Get-Content -LiteralPath (Join-Path $sourceRoot 'install.ps1') -Raw
if ($entrySource -match 'New-FileTransaction|Install-Target|Write-Manifest' -or @($entrySource -split '\r?\n').Count -gt 40) {
    throw 'install.ps1 必須維持為參數解析與 runner 呼叫的薄入口。'
}

Write-Host 'Module layout tests passed.'
