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
    'core\hook-configuration.ps1',
    'core\managed-content.ps1',
    'core\file-transactions.ps1',
    'installation\hook-trust.ps1',
    'installation\hook-validation.ps1',
    'installation\installation-plan.ps1',
    'installation\legacy-project-cleanup.ps1',
    'installation\prerequisites.ps1',
    'installation\prompts.ps1',
    'installation\target-installer.ps1',
    'integrations\ccusage-state.ps1',
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
    'Resolve-GlobalTargets',
    'Remove-ObsoleteProjectSettings',
    'Set-CodexSettingsHookTrust',
    'Install-Target'
)) {
    if (-not (Get-Command $commandName -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "載入安裝模組後缺少函式：$commandName"
    }
}

Write-Host 'Module layout tests passed.'
