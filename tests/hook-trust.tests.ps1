$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-hook-trust-' + [guid]::NewGuid().ToString('N'))
$globalRoot = Join-Path $testRoot '.codex'
$hooksPath = Join-Path $globalRoot 'hooks.json'
$mockPath = Join-Path $testRoot 'mock-app-server.ps1'
$capturePath = Join-Path $testRoot 'trust-request.json'
$codexShimPath = Join-Path $testRoot 'codex.cmd'
$originalPath = $env:PATH

try {
    $installerSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'install.ps1') -Raw
    if ($installerSource -notmatch 'Set-CodexSettingsHookTrust\s+-Root\s+\$globalRoot') { throw 'Global installer does not trust managed Hooks after installation.' }

    New-Item -ItemType Directory -Path $globalRoot -Force | Out-Null
    [IO.File]::WriteAllText($hooksPath, '{"hooks":{}}', [Text.UTF8Encoding]::new($false))
    $mockSource = @'
$trusted = $false
while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $request = $line | ConvertFrom-Json
    switch ([string]$request.method) {
        'initialize' {
            [Console]::Out.WriteLine((@{ id = $request.id; result = @{ codexHome = $env:CODEX_SETTINGS_TEST_GLOBAL_ROOT } } | ConvertTo-Json -Compress))
        }
        'hooks/list' {
            $status = if ($trusted) { 'trusted' } else { 'untrusted' }
            $hooks = if ($env:CODEX_SETTINGS_TEST_NO_MANAGED_HOOKS -eq '1') { @() } else { @(
                    @{ key = "$($env:CODEX_SETTINGS_TEST_HOOKS_PATH):session_start:0:0"; sourcePath = $env:CODEX_SETTINGS_TEST_HOOKS_PATH; command = 'custom-session-start.ps1'; currentHash = 'sha256:custom'; trustStatus = 'untrusted'; enabled = $true },
                    @{ key = "$($env:CODEX_SETTINGS_TEST_HOOKS_PATH):stop:0:0"; sourcePath = $env:CODEX_SETTINGS_TEST_HOOKS_PATH; command = 'pwsh show-codex-notification.ps1 -Type Completed'; currentHash = 'sha256:notification'; trustStatus = $status; enabled = $true },
                    @{ key = "$($env:CODEX_SETTINGS_TEST_HOOKS_PATH):post_tool_use:0:0"; sourcePath = $env:CODEX_SETTINGS_TEST_HOOKS_PATH; command = 'pwsh preserve-line-endings.ps1 -Mode Restore'; currentHash = 'sha256:line-ending'; trustStatus = $status; enabled = $true }
                ) }
            $result = @{ data = @(@{ cwd = $env:CODEX_SETTINGS_TEST_CWD; hooks = $hooks; warnings = @(); errors = @() }) }
            [Console]::Out.WriteLine((@{ id = $request.id; result = $result } | ConvertTo-Json -Depth 10 -Compress))
        }
        'config/batchWrite' {
            [IO.File]::WriteAllText($env:CODEX_SETTINGS_TEST_CAPTURE_PATH, ($request | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $trusted = $true
            [Console]::Out.WriteLine((@{ id = $request.id; result = @{} } | ConvertTo-Json -Compress))
        }
    }
}
'@
    [IO.File]::WriteAllText($mockPath, $mockSource, [Text.UTF8Encoding]::new($false))

    $env:CODEX_SETTINGS_APP_SERVER_TEST_COMMAND = $mockPath
    $env:CODEX_SETTINGS_TEST_GLOBAL_ROOT = $globalRoot
    $env:CODEX_SETTINGS_TEST_HOOKS_PATH = $hooksPath
    $env:CODEX_SETTINGS_TEST_CAPTURE_PATH = $capturePath
    $env:CODEX_SETTINGS_TEST_CWD = $repositoryRoot

    $result = Set-CodexSettingsHookTrust -Root $globalRoot -Cwd $repositoryRoot
    if ($result.TrustedCount -ne 2 -or -not [bool]$result.Verified) { throw 'Installer did not trust and verify both managed hooks.' }

    $request = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
    $trustValues = $request.params.edits[0].value
    $trustedKeys = @($trustValues.PSObject.Properties.Name)
    if ($trustedKeys.Count -ne 2 -or $trustedKeys -notcontains "$hooksPath`:stop:0:0" -or $trustedKeys -notcontains "$hooksPath`:post_tool_use:0:0") {
        throw 'Hook trust update did not contain the exact managed hook keys.'
    }
    if ($trustedKeys -contains "$hooksPath`:session_start:0:0") { throw 'Installer trusted an unmanaged user hook.' }
    if ($request.params.edits[0].keyPath -ne 'hooks.state' -or $request.params.edits[0].mergeStrategy -ne 'upsert' -or -not [bool]$request.params.reloadUserConfig) {
        throw 'Hook trust update did not use the supported config/batchWrite shape.'
    }

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $shimSource = "@echo off`r`n`"$pwshPath`" -NoLogo -NoProfile -File `"$mockPath`" %*`r`n"
    [IO.File]::WriteAllText($codexShimPath, $shimSource, [Text.ASCIIEncoding]::new())
    Remove-Item Env:\CODEX_SETTINGS_APP_SERVER_TEST_COMMAND
    $env:PATH = $testRoot

    $shimResult = Set-CodexSettingsHookTrust -Root $globalRoot -Cwd $repositoryRoot
    if ($shimResult.TrustedCount -ne 2 -or -not [bool]$shimResult.Verified) {
        throw 'Installer did not start and verify Hooks through the resolved codex.cmd shim.'
    }

    $env:CODEX_SETTINGS_TEST_NO_MANAGED_HOOKS = '1'
    $emptyResult = Set-CodexSettingsHookTrust -Root $globalRoot -Cwd $repositoryRoot
    if ($emptyResult.TrustedCount -ne 0 -or $emptyResult.UpdatedCount -ne 0 -or -not [bool]$emptyResult.Verified) {
        throw 'Installer did not accept an installation without managed Hooks.'
    }

    Write-Host 'Managed hook trust tests passed.'
} finally {
    $env:PATH = $originalPath
    Remove-Item Env:\CODEX_SETTINGS_APP_SERVER_TEST_COMMAND -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_TEST_GLOBAL_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_TEST_HOOKS_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_TEST_CAPTURE_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_TEST_CWD -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_TEST_NO_MANAGED_HOOKS -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
