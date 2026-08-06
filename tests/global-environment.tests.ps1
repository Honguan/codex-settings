$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'modules\common.ps1')
. (Join-Path $script:ScriptRoot 'modules\installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-global-environment-' + [guid]::NewGuid().ToString('N'))
$globalRoot = Join-Path $testRoot '.codex'

function Install-TestEnvironment([ValidateSet('Git', 'CVS')][string]$Environment) {
    $transaction = New-FileTransaction -Root (Join-Path $testRoot ("transaction-$Environment-" + [guid]::NewGuid().ToString('N'))) -Mode "Test-$Environment"
    $target = [pscustomobject]@{
        Mode = 'Global'
        Template = Join-Path $script:ScriptRoot 'templates\core'
        EnvironmentTemplate = Join-Path $script:ScriptRoot ("templates\environments\{0}" -f $Environment.ToLowerInvariant())
        DevelopmentEnvironment = $Environment
        Root = $globalRoot
        EnableDefaultModeRequestUserInput = $false
    }
    $result = Install-Target -Target $target -Transaction $transaction
    Write-Manifest -Result $result -Transaction $transaction -External $null
    Complete-FileTransaction -Transaction $transaction
}

try {
    $installerSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'installer.ps1') -Raw
    if ($installerSource -match 'Write-Warning\s+"已回復中斷的交易') {
        throw 'Installer startup must not render recovered transactions as a yellow warning.'
    }
    if ($installerSource -notmatch 'Write-Host\s+"已自動回復上次中斷的安裝交易') {
        throw 'Installer startup did not preserve a clear recovered-transaction status message.'
    }

    if ((Get-DefaultDevelopmentEnvironment -Root $globalRoot) -ne 'Git') { throw 'First installation must default to Git.' }
    New-Item -ItemType Directory -Path $globalRoot -Force | Out-Null
    $existingHooks = [ordered]@{
        description = 'User hooks'
        hooks = [ordered]@{
            SessionStart = @(
                [ordered]@{
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = 'custom-session-start.ps1'
                        }
                    )
                }
            )
        }
    }
    Write-JsonFileAtomic -Path (Join-Path $globalRoot 'hooks.json') -Value $existingHooks -Depth 10
    $legacyAgents = [IO.File]::ReadAllText((Join-Path $script:ScriptRoot 'templates\core\AGENTS.md')).TrimEnd()
    $legacyAgents = $legacyAgents.Replace(
        '- Preserve existing architecture, coding style, naming, and structure unless current requirements change them.',
        '- Preserve existing architecture, coding style, naming, structure, and backward compatibility.'
    )
    $legacyAgents = [regex]::Replace($legacyAgents, '(?ms)^# Architecture\r?\n.*?(?=^# File Handling)', '')
    $legacyAgents += "`r`n`r`n# User Custom Rules`r`n`r`n- Preserve this custom rule.`r`n"
    [IO.File]::WriteAllText((Join-Path $globalRoot 'AGENTS.md'), $legacyAgents, [Text.UTF8Encoding]::new($false))

    Install-TestEnvironment -Environment CVS
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    foreach ($heading in @('Communication', 'Code Changes', 'Architecture', 'File Handling', 'Validation')) {
        if ([regex]::Matches($agents, "(?m)^# $([regex]::Escape($heading))\s*$").Count -ne 1) { throw "Safe merge duplicated or omitted the AGENTS.md section: $heading" }
    }
    if ($agents -notmatch '(?m)^# User Custom Rules\s*$') { throw 'Safe merge removed a custom AGENTS.md section.' }
    if ($agents -match 'and backward compatibility\.') { throw 'Safe merge did not update a legacy AGENTS.md section.' }
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.SessionStart).Count -ne 1) { throw 'CVS installation did not preserve the unmanaged user hook.' }
    if ($installedHooks.hooks.PSObject.Properties.Name -contains 'PostToolUse' -or @($installedHooks.hooks.Stop).Count -ne 1) { throw 'CVS installation did not add only its managed Stop hook.' }
    if ((Get-DefaultDevelopmentEnvironment -Root $globalRoot) -ne 'CVS') { throw 'CVS was not recorded as the default project system.' }

    Install-TestEnvironment -Environment Git
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    $rules = Get-Content -LiteralPath (Join-Path $globalRoot 'rules\default.rules') -Raw
    $config = Get-Content -LiteralPath (Join-Path $globalRoot 'config.toml') -Raw
    if ($agents -notmatch '# Communication' -or $agents -notmatch '# Git Project Rules' -or $agents -match '# CVS Project Rules') { throw 'Git AGENTS.md composition is invalid.' }
    if ($rules -notmatch 'Git project rules supplement' -or $rules -match 'CVS project rules supplement') { throw 'Git rules composition is invalid.' }
    if ($config -notmatch 'project_root_markers = \["\.git", "CVS"\]' -or $config -match '\.codex-root') { throw 'Global project root markers are invalid.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1')) { throw 'Git environment installed the CVS CRLF hook.' }
    if ((Get-DefaultDevelopmentEnvironment -Root $globalRoot) -ne 'Git') { throw 'Git was not recorded as the default project system.' }

    Install-TestEnvironment -Environment CVS
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    $rules = Get-Content -LiteralPath (Join-Path $globalRoot 'rules\default.rules') -Raw
    if ($agents -notmatch '# Communication' -or $agents -notmatch '# CVS Project Rules' -or $agents -match '# Git Project Rules') { throw 'CVS AGENTS.md composition is invalid.' }
    if ($rules -notmatch 'CVS project rules supplement' -or $rules -match 'Git project rules supplement') { throw 'CVS rules composition is invalid.' }
    Assert-GlobalEnvironmentInstallation -DevelopmentEnvironment CVS -Root $globalRoot
    $installedHooks = Get-Content -LiteralPath (Join-Path $globalRoot 'hooks.json') -Raw | ConvertFrom-Json
    if (@($installedHooks.hooks.SessionStart).Count -ne 1) { throw 'CVS installation did not preserve the unmanaged user hook.' }
    if ($installedHooks.hooks.PSObject.Properties.Name -contains 'PostToolUse' -or @($installedHooks.hooks.Stop).Count -ne 1) { throw 'CVS installation did not add only its managed Stop hook.' }

    $outsideCvs = Join-Path $testRoot 'ordinary-directory'
    New-Item -ItemType Directory -Path $outsideCvs -Force | Out-Null
    Push-Location $outsideCvs
    try { & pwsh -NoLogo -NoProfile -File (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1') }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'Global CVS hook must skip non-CVS directories successfully.' }

    Install-TestEnvironment -Environment Git
    Assert-GlobalEnvironmentInstallation -DevelopmentEnvironment Git -Root $globalRoot
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1')) { throw 'Switching to Git did not remove the global CVS hook.' }

    $script:capturedEnvironmentPrompt = ''
    function Read-Host([string]$Prompt) {
        $script:capturedEnvironmentPrompt = $Prompt
        return ''
    }
    try {
        if ((Select-DevelopmentEnvironment -Default CVS) -ne 'CVS') { throw 'Blank selection did not reuse the recorded CVS default.' }
        if ($script:capturedEnvironmentPrompt -ne '請選擇 [2]') { throw 'CVS default was not shown in the selection prompt.' }
    } finally {
        Remove-Item -LiteralPath Function:\Read-Host -ErrorAction SilentlyContinue
    }

    Write-Host 'Global development environment tests passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
