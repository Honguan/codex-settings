$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testRoot = [string]$env:CODEX_SETTINGS_ISSUE39_ROOT

if ([string]::IsNullOrWhiteSpace($testRoot)) {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-issue39-' + [guid]::NewGuid().ToString('N'))
    $homeRoot = Join-Path $testRoot 'home'
    $localAppData = Join-Path $testRoot 'local-app-data'
    $commandRoot = Join-Path $testRoot 'bin'
    New-Item -ItemType Directory -Path $homeRoot, $localAppData, $commandRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $commandRoot 'codex.cmd'), "@exit /b 0`r`n", [Text.ASCIIEncoding]::new())

    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        foreach ($argument in @('-NoProfile', '-File', $PSCommandPath)) { $startInfo.ArgumentList.Add($argument) }
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Environment['CODEX_SETTINGS_ISSUE39_ROOT'] = $testRoot
        $startInfo.Environment['HOME'] = $homeRoot
        $startInfo.Environment['USERPROFILE'] = $homeRoot
        $startInfo.Environment['LOCALAPPDATA'] = $localAppData
        $startInfo.Environment['PATH'] = "$commandRoot$([IO.Path]::PathSeparator)$($startInfo.Environment['PATH'])"
        $startInfo.Environment['CODEX_SETTINGS_APP_SERVER_TEST_COMMAND'] = Join-Path $PSScriptRoot 'fixtures\successful-app-server.ps1'
        $process = [Diagnostics.Process]::Start($startInfo)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        [Console]::Out.Write($stdout)
        [Console]::Error.Write($stderr)
        exit $process.ExitCode
    } finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    }
}

try {
    $env:CODEX_SETTINGS_NOTIFICATION_TEST_MODE = '1'
    $env:CODEX_SETTINGS_NOTIFICATION_TEST_LOG = Join-Path $testRoot 'notification-test.log'
    $installPath = Join-Path $repositoryRoot 'src\install.ps1'

    function Get-LatestInstallLog {
        $log = Get-ChildItem -LiteralPath (Join-Path $HOME '.codex\logs\installer') -Filter 'install-*.log' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($null -eq $log) { throw 'Installer log was not created.' }
        return Get-Content -LiteralPath $log.FullName -Raw
    }

    function Assert-LogContains([string]$Log, [string[]]$Markers) {
        foreach ($marker in $Markers) {
            if ($Log -notmatch [regex]::Escape($marker)) { throw "Installer log is missing: $marker" }
        }
    }

    function Get-ManagedStateHashes {
        $globalRoot = Join-Path $HOME '.codex'
        $manifestPath = Join-Path $globalRoot '.codex-settings-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $hashes = [ordered]@{}
        foreach ($file in @($manifest.Files)) {
            $path = Join-Path $globalRoot ([string]$file.RelativePath)
            $hashes[[string]$file.RelativePath] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
        $hashes['.codex-settings-manifest.json'] = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        return ($hashes | ConvertTo-Json -Compress)
    }

    & $installPath -Mode Global -DevelopmentEnvironment Git -InstallStyle Merge -InstallWindowsNotifications $true -SkipContext7Key -SkipCcusageInstall -NoPause
    $gitChangedLog = Get-LatestInstallLog
    Assert-LogContains -Log $gitChangedLog -Markers @(
        'HOOKS subOperation=ResolveGlobalResult',
        'HOOKS subOperation=WorkflowDecision',
        'HOOKS subOperation=HookTrust',
        'HOOKS subOperation=ConfigValidation',
        'HOOKS subOperation=InstallationResultValidation'
    )

    & $installPath -Mode Global -DevelopmentEnvironment Git -InstallStyle Merge -InstallWindowsNotifications $true -SkipContext7Key -SkipCcusageInstall -NoPause
    Assert-LogContains -Log (Get-LatestInstallLog) -Markers @('STEP END Hooks: Hook 未變更，略過重新 trust', 'STEP END Notifications: 腳本、Hook 與使用量工具未變更', 'STEP END Final: Manifest 與交易驗證通過')

    $policyRemovalOutput = (& $installPath -Mode Global -DevelopmentEnvironment Git -InstallStyle Merge -InstallWindowsNotifications $true -LongRunningAsyncWaitAction Uninstall -SkipContext7Key -SkipCcusageInstall -NoPause 6>&1 | Out-String)
    if ($policyRemovalOutput -notmatch 'Long-running async wait policy\s+Uninstalled' -or [IO.File]::ReadAllText((Join-Path $HOME '.codex\AGENTS.md')) -match 'CODEX-SETTINGS:OTHER:LONG-RUNNING-ASYNC-WAIT') { throw 'Global installer did not report and apply independent async-wait removal.' }

    $manifestPath = Join-Path $HOME '.codex\.codex-settings-manifest.json'
    $legacyManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $legacyManifest.Version = 5
    $legacyManifest.PSObject.Properties.Remove('ManagedHooks')
    [IO.File]::WriteAllText($manifestPath, ($legacyManifest | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))

    & $installPath -Mode Global -DevelopmentEnvironment Git -InstallStyle Merge -InstallWindowsNotifications $true -SkipContext7Key -SkipCcusageInstall -NoPause
    $legacyUpgradeLog = Get-LatestInstallLog
    Assert-LogContains -Log $legacyUpgradeLog -Markers @('STEP END Notifications:', 'STEP END Final: Manifest 與交易驗證通過')

    & $installPath -Mode Global -DevelopmentEnvironment CVS -InstallStyle Merge -InstallWindowsNotifications $true -SkipContext7Key -SkipCcusageInstall -NoPause
    Assert-LogContains -Log (Get-LatestInstallLog) -Markers @('HOOKS subOperation=HookTrust', 'STEP END Hooks: 已驗證 3 個', 'STEP END Notifications:')

    & $installPath -Mode Global -DevelopmentEnvironment CVS -InstallStyle Replace -InstallWindowsNotifications $true -SkipContext7Key -SkipCcusageInstall -NoPause
    Assert-LogContains -Log (Get-LatestInstallLog) -Markers @('HOOKS subOperation=HookTrust', 'STEP END Final: Manifest 與交易驗證通過')

    $beforeFailureHashes = Get-ManagedStateHashes
    $env:CODEX_SETTINGS_APP_SERVER_TEST_COMMAND = Join-Path $PSScriptRoot 'fixtures\failing-app-server.ps1'
    $failureMessage = ''
    try {
        & $installPath -Mode Global -DevelopmentEnvironment Git -InstallStyle Replace -InstallWindowsNotifications $true -SkipContext7Key -SkipCcusageInstall -NoPause
        throw 'Expected Hook trust failure did not occur.'
    } catch {
        $failureMessage = $_.Exception.Message
    } finally {
        Remove-Item Env:\CODEX_SETTINGS_APP_SERVER_TEST_COMMAND -ErrorAction SilentlyContinue
    }
    if ($failureMessage -notmatch 'intentional Hook trust failure') { throw "Unexpected failure: $failureMessage" }
    if ((Get-ManagedStateHashes) -ne $beforeFailureHashes) { throw 'Hook trust failure did not restore the managed installation state.' }
    $failedLog = Get-LatestInstallLog
    if ($failedLog -match 'STEP START Notifications:') { throw 'Personal 失敗後仍啟動 Community component。' }
    Assert-LogContains -Log $failedLog -Markers @(
        'ERROR CurrentStepId=Hooks; CurrentSubOperation=HookTrust',
        'ExceptionType=',
        'FullyQualifiedErrorId=',
        'InvocationInfo.ScriptName=',
        'InvocationInfo.ScriptLineNumber=',
        'ScriptStackTrace=',
        'INSTALL END status=FAILED;'
    )
    $latestTransaction = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup') -Directory | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $rollbackMetadata = Get-Content -LiteralPath (Join-Path $latestTransaction.FullName 'backup-meta.json') -Raw | ConvertFrom-Json
    if ([string]$rollbackMetadata.Status -ne 'RolledBack') { throw 'Failed Hook trust transaction was not rolled back.' }

    $agentsPath = Join-Path $HOME '.codex\AGENTS.md'
    [IO.File]::AppendAllText($agentsPath, "`r`n# User content after install`r`n`r`n- keep me`r`n", [Text.UTF8Encoding]::new($false))
    & (Join-Path $repositoryRoot 'src\commands\uninstall-settings.ps1') -Mode Global -Force
    $agentsAfterUninstall = [IO.File]::ReadAllText($agentsPath)
    if ($agentsAfterUninstall -match 'CODEX-SETTINGS:OTHER:LONG-RUNNING-ASYNC-WAIT' -or -not $agentsAfterUninstall.Contains('keep me')) { throw 'Global uninstall did not remove only the async-wait managed block.' }

    Write-Host 'Installation Hook stage Git/CVS Merge/Replace, legacy manifest, diagnostics, and rollback tests passed.'
} catch {
    Write-Host "FAIL exception=$($_.Exception.GetType().FullName) message=$($_.Exception.Message)"
    Write-Host "fqid=$($_.FullyQualifiedErrorId)"
    Write-Host "position=$($_.InvocationInfo.PositionMessage)"
    Write-Host "stack=$($_.ScriptStackTrace)"
    exit 1
}
