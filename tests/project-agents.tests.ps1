[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ScriptRoot = $repositoryRoot
. (Join-Path $repositoryRoot 'lib\codex-settings-common.ps1')
. (Join-Path $repositoryRoot 'lib\install-functions.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-project-agents-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path (Join-Path $testRoot '.git'), (Join-Path $testRoot 'CVS') -Force | Out-Null
    $transaction = New-FileTransaction -Root (Join-Path $testRoot 'transaction') -Mode 'Test'
    $gitTarget = [pscustomobject]@{ Mode = 'Git'; Template = Join-Path $repositoryRoot 'templates\git-project'; Root = $testRoot }
    $cvsTarget = [pscustomobject]@{ Mode = 'CVS'; Template = Join-Path $repositoryRoot 'templates\cvs-project'; Root = $testRoot }

    [void](Install-Target $gitTarget $transaction)
    $agentsPath = Join-Path $testRoot 'AGENTS.md'
    $gitAgents = Get-Content -Raw -LiteralPath $agentsPath
    if ($gitAgents -notmatch '# Communication' -or $gitAgents -notmatch 'Do not preserve backward compatibility\.' -or $gitAgents -notmatch '# Git Project Rules') {
        throw 'Git project AGENTS.md must contain common and Git-specific rules.'
    }
    if ($gitAgents -notmatch 'CODEX-SETTINGS:PROJECT:AGENTS') {
        throw 'Project AGENTS.md must use the shared project managed block.'
    }

    [void](Install-Target $cvsTarget $transaction)
    $cvsAgents = Get-Content -Raw -LiteralPath $agentsPath
    if ($cvsAgents -notmatch '# Communication' -or $cvsAgents -notmatch 'Do not preserve backward compatibility\.' -or $cvsAgents -notmatch '# CVS Project Rules') {
        throw 'CVS project AGENTS.md must contain common and CVS-specific rules.'
    }
    if ($cvsAgents -match '# Git Project Rules') {
        throw 'Switching a project to CVS must replace Git-specific rules.'
    }
    if (Test-Path -LiteralPath (Join-Path $testRoot 'agent.md')) {
        throw 'CVS installation must use AGENTS.md and not create agent.md.'
    }

    [IO.File]::WriteAllText($agentsPath, "保留的自訂內容`r`n`r`n<!-- >>> CODEX-SETTINGS: >>> -->`r`n# Git Project Rules`r`n<!-- <<< CODEX-SETTINGS: <<< -->`r`n`r`n<!-- >>> CODEX-SETTINGS:Git:AGENTS >>> -->`r`n# Git Project Rules`r`n<!-- <<< CODEX-SETTINGS:Git:AGENTS <<< -->`r`n", [Text.UTF8Encoding]::new($false))
    [void](Install-Target $cvsTarget $transaction)
    $migratedAgents = Get-Content -Raw -LiteralPath $agentsPath
    if ($migratedAgents -notmatch '保留的自訂內容' -or $migratedAgents -match 'CODEX-SETTINGS: >>>' -or $migratedAgents -match 'CODEX-SETTINGS:Git:AGENTS' -or $migratedAgents -match '# Git Project Rules') {
        throw 'Legacy project AGENTS.md blocks must be replaced while preserving unmanaged content.'
    }

    Write-Host 'Project AGENTS regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
