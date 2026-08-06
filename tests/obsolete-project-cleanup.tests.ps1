$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'modules\common.ps1')
. (Join-Path $script:ScriptRoot 'modules\installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-project-cleanup-' + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $testRoot 'project'
$registryPath = Join-Path $testRoot 'projects.json'
$transactionRoot = Join-Path $testRoot 'transaction'

try {
    New-Item -ItemType Directory -Path (Join-Path $projectRoot '.codex\hooks'), (Join-Path $projectRoot '.codex\rules') -Force | Out-Null
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $projectRoot 'AGENTS.md'), "保留內容`r`n`r`n<!-- >>> CODEX-SETTINGS:PROJECT:AGENTS >>> -->`r`n受管理內容`r`n<!-- <<< CODEX-SETTINGS:PROJECT:AGENTS <<< -->`r`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $projectRoot '.codex\rules\default.rules'), "# >>> CODEX-SETTINGS:CVS:RULES >>>`r`n受管理規則`r`n# <<< CODEX-SETTINGS:CVS:RULES <<<`r`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $projectRoot '.codex\hooks.json'), '{"hooks":{"PostToolUse":[{"type":"command","command":"crlf-updated-files.ps1"}],"Stop":[{"type":"command","command":"custom.ps1"}]}}', $utf8)
    [IO.File]::WriteAllText((Join-Path $projectRoot '.codex\hooks\crlf-updated-files.ps1'), '# managed', $utf8)
    [IO.File]::WriteAllText((Join-Path $projectRoot '.codex-root'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $projectRoot '.gitignore'), "custom.log`r`n# Files managed locally by codex-settings`r`n/AGENTS.md`r`n/.codex-settings-manifest.json`r`n", $utf8)

    $manifest = [ordered]@{
        Version = 4
        Files = @(
            [ordered]@{ Path = 'AGENTS.md'; Strategy = 'managed-block'; StartMarker = '<!-- >>> CODEX-SETTINGS:PROJECT:AGENTS >>> -->'; EndMarker = '<!-- <<< CODEX-SETTINGS:PROJECT:AGENTS <<< -->'; ExistedBefore = $true },
            [ordered]@{ Path = '.codex\rules\default.rules'; Strategy = 'managed-block'; StartMarker = '# >>> CODEX-SETTINGS:CVS:RULES >>>'; EndMarker = '# <<< CODEX-SETTINGS:CVS:RULES <<<' ; ExistedBefore = $false },
            [ordered]@{ Path = '.codex\hooks.json'; Strategy = 'managed-hooks'; ExistedBefore = $true },
            [ordered]@{ Path = '.codex\hooks\crlf-updated-files.ps1'; Strategy = 'replace'; ExistedBefore = $false },
            [ordered]@{ Path = '.codex-root'; Strategy = 'replace'; ExistedBefore = $false }
        )
    }
    Write-JsonFileAtomic -Path (Join-Path $projectRoot '.codex-settings-manifest.json') -Value $manifest -Depth 10
    Write-JsonFileAtomic -Path $registryPath -Value ([ordered]@{ Version = 1; Projects = @([ordered]@{ Type = 'CVS'; Path = $projectRoot }) }) -Depth 6

    $transaction = New-FileTransaction -Root $transactionRoot -Mode 'TestCleanup'
    $result = Remove-ObsoleteProjectSettings -Transaction $transaction -RegistryPath $registryPath

    if ($result.Projects -ne 1) { throw 'Expected one obsolete project to be processed.' }
    if (Test-Path -LiteralPath $registryPath) { throw 'Obsolete project registry was not removed.' }
    if (Test-Path -LiteralPath (Join-Path $projectRoot 'AGENTS.md')) { throw 'Project AGENTS.md was not removed.' }
    if (Test-Path -LiteralPath (Join-Path $projectRoot '.codex\rules\default.rules')) { throw 'Managed rules file was not removed.' }
    if (Test-Path -LiteralPath (Join-Path $projectRoot '.codex\hooks\crlf-updated-files.ps1')) { throw 'Managed CRLF hook script was not removed.' }
    if (Test-Path -LiteralPath (Join-Path $projectRoot '.codex-root')) { throw 'Legacy project root marker was not removed.' }
    if (Test-Path -LiteralPath (Join-Path $projectRoot '.codex-settings-manifest.json')) { throw 'Project manifest was not removed.' }
    $gitIgnore = Get-Content -LiteralPath (Join-Path $projectRoot '.gitignore') -Raw
    if ($gitIgnore -notmatch 'custom\.log' -or $gitIgnore -match 'codex-settings|/AGENTS\.md') { throw 'Managed .gitignore entries were not removed correctly.' }
    $hooks = Get-Content -LiteralPath (Join-Path $projectRoot '.codex\hooks.json') -Raw | ConvertFrom-Json
    if ($hooks.hooks.PSObject.Properties.Name -contains 'PostToolUse' -or @($hooks.hooks.Stop).Count -ne 1) { throw 'Unmanaged hook was not preserved correctly.' }

    Write-Host 'Obsolete project cleanup tests passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
