$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-hook-free-' + [guid]::NewGuid().ToString('N'))
$globalRoot = Join-Path $testRoot '.codex'

function Install-TestEnvironment([ValidateSet('Git', 'CVS')][string]$Environment, [string]$Cwd = '') {
    $transaction = New-FileTransaction -Root (Join-Path $testRoot ("transaction-$Environment-" + [guid]::NewGuid().ToString('N'))) -Mode "Test-$Environment"
    $target = New-InstallTarget -Id test-global -Mode Global -TemplateRoot (Join-Path $script:ScriptRoot 'templates\core') -EnvironmentTemplateRoot (Join-Path $script:ScriptRoot ("templates\environments\{0}" -f $Environment.ToLowerInvariant())) -DevelopmentEnvironment $Environment -Root $globalRoot -Cwd $Cwd -InstallWindowsNotifications $true -ManageWindowsNotifications $true -SourceRoot $script:ScriptRoot
    Invoke-TargetInstallation -Target $target -Transaction $transaction | Out-Null
    Complete-FileTransaction -Transaction $transaction
}

try {
    New-Item -ItemType Directory -Path (Join-Path $globalRoot 'hooks') -Force | Out-Null
    $hooks = [ordered]@{ hooks = [ordered]@{
        SessionStart = @([ordered]@{ hooks = @([ordered]@{ type = 'command'; command = 'custom-session-start.ps1' }) })
        PreToolUse = @([ordered]@{ matcher = '*'; hooks = @([ordered]@{ type = 'command'; command = 'pwsh preserve-line-endings.ps1 -Mode Track' }) })
        PostToolUse = @([ordered]@{ matcher = '*'; hooks = @([ordered]@{ type = 'command'; command = 'pwsh mixed-line-ending-hook.ps1 -Mode Fix' }) })
        PermissionRequest = @([ordered]@{ hooks = @([ordered]@{ type = 'command'; command = 'pwsh show-codex-notification.ps1 -Type PermissionRequired' }) })
        Stop = @([ordered]@{ hooks = @(
            [ordered]@{ type = 'command'; command = 'pwsh preserve-line-endings.ps1 -Mode Finalize' },
            [ordered]@{ type = 'command'; command = 'custom-stop.ps1' }
        ) })
    } }
    Write-JsonFileAtomic -Path (Join-Path $globalRoot 'hooks.json') -Value $hooks -Depth 10
    foreach ($name in @('mixed-line-ending-hook.ps1', 'preserve-line-endings.ps1', 'show-codex-notification.ps1')) { [IO.File]::WriteAllText((Join-Path $globalRoot "hooks\$name"), '# retired', [Text.UTF8Encoding]::new($false)) }

    foreach ($environment in @('Git', 'CVS')) {
        Install-TestEnvironment -Environment $environment
        $installed = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
        $managedCount = @($installed.hooks.PSObject.Properties.Value | ForEach-Object { @($_) } | Where-Object { (Test-ManagedLineEndingHookEntry $_) -or (Test-ManagedNotificationHookEntry $_) }).Count
        if ($managedCount -ne 0) { throw "$environment installation retained managed hooks." }
        if (@($installed.hooks.SessionStart).Count -ne 1 -or @($installed.hooks.Stop | ForEach-Object { @($_.hooks) } | Where-Object command -eq 'custom-stop.ps1').Count -ne 1) { throw "$environment installation removed unrelated hooks." }
        foreach ($name in @('mixed-line-ending-hook.ps1', 'preserve-line-endings.ps1', 'show-codex-notification.ps1')) { if (Test-Path -LiteralPath (Join-Path $globalRoot "hooks\$name")) { throw "$environment installation retained $name." } }
        Assert-GlobalLineEndingHook -DevelopmentEnvironment $environment -Root $globalRoot -InstallWindowsNotifications $true -ProjectRoot '' | Out-Null
    }

    foreach ($path in @('templates\core\hooks.json', 'templates\core\hooks\runtime-core.ps1', 'templates\core\hooks\show-codex-notification.ps1', 'templates\environments\cvs\hooks.json', 'templates\environments\cvs\hooks\mixed-line-ending-hook.ps1', 'templates\environments\cvs\hooks\preserve-line-endings.ps1')) {
        if (Test-Path -LiteralPath (Join-Path $script:ScriptRoot $path)) { throw "Active Hook template still exists: $path" }
    }
    Write-Host 'Hook-free global environment tests passed.'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
