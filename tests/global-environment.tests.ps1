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
    Install-TestEnvironment -Environment Git
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    $rules = Get-Content -LiteralPath (Join-Path $globalRoot 'rules\default.rules') -Raw
    $config = Get-Content -LiteralPath (Join-Path $globalRoot 'config.toml') -Raw
    if ($agents -notmatch '# Communication' -or $agents -notmatch '# Git Project Rules' -or $agents -match '# CVS Project Rules') { throw 'Git AGENTS.md composition is invalid.' }
    if ($rules -notmatch 'Git project rules supplement' -or $rules -match 'CVS project rules supplement') { throw 'Git rules composition is invalid.' }
    if ($config -notmatch 'project_root_markers = \["\.git", "CVS"\]' -or $config -match '\.codex-root') { throw 'Global project root markers are invalid.' }
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1')) { throw 'Git environment installed the CVS CRLF hook.' }

    Install-TestEnvironment -Environment CVS
    $agents = Get-Content -LiteralPath (Join-Path $globalRoot 'AGENTS.md') -Raw
    $rules = Get-Content -LiteralPath (Join-Path $globalRoot 'rules\default.rules') -Raw
    if ($agents -notmatch '# Communication' -or $agents -notmatch '# CVS Project Rules' -or $agents -match '# Git Project Rules') { throw 'CVS AGENTS.md composition is invalid.' }
    if ($rules -notmatch 'CVS project rules supplement' -or $rules -match 'Git project rules supplement') { throw 'CVS rules composition is invalid.' }
    Assert-GlobalEnvironmentInstallation -DevelopmentEnvironment CVS -Root $globalRoot

    $outsideCvs = Join-Path $testRoot 'ordinary-directory'
    New-Item -ItemType Directory -Path $outsideCvs -Force | Out-Null
    Push-Location $outsideCvs
    try { & pwsh -NoLogo -NoProfile -File (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1') }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'Global CVS hook must skip non-CVS directories successfully.' }

    $cvsRoot = Join-Path $testRoot 'cvs-project'
    $nestedRoot = Join-Path $cvsRoot 'src'
    New-Item -ItemType Directory -Path (Join-Path $cvsRoot 'CVS'), (Join-Path $nestedRoot 'CVS') -Force | Out-Null
    $textPath = Join-Path $nestedRoot 'sample.php'
    [IO.File]::WriteAllText($textPath, "line1`nline2`n", [Text.UTF8Encoding]::new($false))
    $payload = [ordered]@{ tool_name = 'Edit'; tool_input = [ordered]@{ file_path = $textPath } } | ConvertTo-Json -Compress
    $localAppDataBefore = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = Join-Path $testRoot 'local-app-data'
    Push-Location $nestedRoot
    try {
        $payload | & pwsh -NoLogo -NoProfile -File (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Global CVS hook failed to track an updated file.' }
        Start-Sleep -Seconds 3
        & pwsh -NoLogo -NoProfile -File (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1') -Flush | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Global CVS hook failed to finalize CRLF conversion.' }
    } finally {
        Pop-Location
        $env:LOCALAPPDATA = $localAppDataBefore
    }
    $bytes = [IO.File]::ReadAllBytes($textPath)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($text -match '(?<!\r)\n') { throw 'Global CVS hook did not convert the updated file to CRLF.' }

    Install-TestEnvironment -Environment Git
    Assert-GlobalEnvironmentInstallation -DevelopmentEnvironment Git -Root $globalRoot
    if (Test-Path -LiteralPath (Join-Path $globalRoot 'hooks\normalize-cvs-crlf.ps1')) { throw 'Switching to Git did not remove the global CVS hook.' }

    Write-Host 'Global development environment tests passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
