$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-permissions-' + [guid]::NewGuid().ToString('N'))
$globalRoot = Join-Path $testRoot '.codex'

try {
    New-Item -ItemType Directory -Path $globalRoot -Force | Out-Null
    $configPath = Join-Path $globalRoot 'config.toml'
    $existingConfig = @'
approval_policy = "on-request"
sandbox_mode = "danger-full-access"

[windows]
sandbox = "unelevated"
'@
    [IO.File]::WriteAllText($configPath, $existingConfig.Trim() + "`r`n", [Text.UTF8Encoding]::new($false))

    $transaction = New-FileTransaction -Root (Join-Path $testRoot 'transaction') -Mode 'Test-Permissions'
    $target = [pscustomobject]@{
        Mode = 'Global'
        Template = Join-Path $script:ScriptRoot 'templates\core'
        EnvironmentTemplate = Join-Path $script:ScriptRoot 'templates\environments\git'
        DevelopmentEnvironment = 'Git'
        Root = $globalRoot
        EnableDefaultModeRequestUserInput = $false
        InstallWindowsNotifications = $false
    }
    $result = Invoke-TargetInstallation -Target $target -Transaction $transaction
    Save-InstallationManifest -Result $result -Transaction $transaction -External $null
    Complete-FileTransaction -Transaction $transaction

    $installedConfig = Get-Content -LiteralPath $configPath -Raw
    if ([regex]::Matches($installedConfig, '(?m)^approval_policy\s*=').Count -ne 1 -or $installedConfig -notmatch '(?m)^approval_policy\s*=\s*"on-request"\s*$') {
        throw 'Installation changed or duplicated approval_policy.'
    }
    if ([regex]::Matches($installedConfig, '(?m)^sandbox_mode\s*=').Count -ne 1 -or $installedConfig -notmatch '(?m)^sandbox_mode\s*=\s*"danger-full-access"\s*$') {
        throw 'Installation changed or duplicated sandbox_mode.'
    }
    if ([regex]::Matches($installedConfig, '(?m)^\[windows\]\s*$').Count -ne 1 -or $installedConfig -notmatch '(?ms)^\[windows\]\s*\r?\n\s*sandbox\s*=\s*"unelevated"\s*$') {
        throw 'Installation changed or duplicated the Windows sandbox setting.'
    }

    $freshRoot = Join-Path $testRoot 'fresh\.codex'
    $freshTransaction = New-FileTransaction -Root (Join-Path $testRoot 'fresh-transaction') -Mode 'Test-Fresh-Permissions'
    $freshTarget = $target.PSObject.Copy()
    $freshTarget.Root = $freshRoot
    $freshResult = Invoke-TargetInstallation -Target $freshTarget -Transaction $freshTransaction
    Save-InstallationManifest -Result $freshResult -Transaction $freshTransaction -External $null
    Complete-FileTransaction -Transaction $freshTransaction

    $freshConfig = Get-Content -LiteralPath (Join-Path $freshRoot 'config.toml') -Raw
    if ($freshConfig -match '(?m)^approval_policy\s*=' -or $freshConfig -match '(?m)^sandbox_mode\s*=' -or $freshConfig -match '(?m)^\[windows\]\s*$') {
        throw 'Fresh installation introduced permission settings that override Codex controls.'
    }

    Write-Host 'Permission settings preservation tests passed.'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
