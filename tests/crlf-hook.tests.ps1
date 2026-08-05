[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hookTemplate = Join-Path $repositoryRoot 'templates\cvs-project\.codex\hooks\crlf-updated-files.ps1'
$hooksTemplate = Join-Path $repositoryRoot 'templates\cvs-project\.codex\hooks.json'
$common = Join-Path $repositoryRoot 'lib\codex-settings-common.ps1'

if (-not (Test-Path -LiteralPath $hookTemplate -PathType Leaf)) { throw "Hook template is missing: $hookTemplate" }

$projectRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-crlf-' + [guid]::NewGuid().ToString('N'))
$jobs = @()
try {
    $hookPath = Join-Path $projectRoot '.codex\hooks\crlf-updated-files.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $hookPath) -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $projectRoot '.codex-root') -Force | Out-Null
    Copy-Item -LiteralPath $hookTemplate -Destination $hookPath

    $samplePath = Join-Path $projectRoot 'sample.php'
    [IO.File]::WriteAllText($samplePath, "<?php`necho 'ok';`n", (New-Object Text.UTF8Encoding($false)))
    $payload = @{ tool_input = @{ file_path = $samplePath } } | ConvertTo-Json -Compress
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $payload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath
    if ($LASTEXITCODE -ne 0) { throw "PostToolUse hook failed with exit code $LASTEXITCODE" }
    if (-not ([IO.File]::ReadAllText($samplePath).Contains("`r`n"))) { throw 'PostToolUse hook did not normalize CRLF.' }

    1..8 | ForEach-Object {
        $jobs += Start-Job -ScriptBlock {
            param([string]$Path)
            & $Path -Flush
            [int]$LASTEXITCODE
        } -ArgumentList $hookPath
    }
    $flushResults = @($jobs | Wait-Job | Receive-Job)
    if (@($flushResults | Where-Object { $_ -ne 0 }).Count -gt 0) {
        throw "Parallel Flush hook failed: $($flushResults -join ', ')"
    }

    . $common
    $template = Get-Content -Raw -LiteralPath $hooksTemplate
    $old = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"crlf-updated-files.ps1 -Flush"}]}],"Notification":[{"hooks":[]}]}}'
    $migrated = Merge-HooksJson $old $template | ConvertFrom-Json
    if ($migrated.hooks.PSObject.Properties.Name -contains 'Stop') { throw 'Migration retained the obsolete Stop hook.' }
    if (-not ($migrated.hooks.PSObject.Properties.Name -contains 'PostToolUse')) { throw 'Migration removed PostToolUse.' }
    if (-not ($migrated.hooks.PSObject.Properties.Name -contains 'Notification')) { throw 'Migration removed unrelated hooks.' }

    Write-Output 'CRLF hook regression tests passed.'
} finally {
    foreach ($job in @($jobs)) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $projectRoot) { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
