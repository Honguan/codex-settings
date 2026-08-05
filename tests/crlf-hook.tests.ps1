[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hookTemplate = Join-Path $repositoryRoot 'templates\cvs-project\.codex\hooks\crlf-updated-files.ps1'
$hooksTemplate = Join-Path $repositoryRoot 'templates\cvs-project\.codex\hooks.json'
$common = Join-Path $repositoryRoot 'lib\codex-settings-common.ps1'
$projectRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-crlf-' + [guid]::NewGuid().ToString('N'))
$jobs = @()
$localAppDataBefore = $env:LOCALAPPDATA

try {
    $env:LOCALAPPDATA = Join-Path $projectRoot '.local'
    $hookPath = Join-Path $projectRoot '.codex\hooks\crlf-updated-files.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $hookPath) -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $projectRoot '.codex-root') -Force | Out-Null
    Copy-Item -LiteralPath $hookTemplate -Destination $hookPath
    $pwsh = Join-Path $PSHOME 'pwsh.exe'

    $paths = @('A.php', 'B.php', 'C.php') | ForEach-Object { Join-Path $projectRoot $_ }
    foreach ($path in $paths) {
        [IO.File]::WriteAllText($path, "<?php`necho 'ok';`n", (New-Object Text.UTF8Encoding($false)))
    }
    $deletedPath = Join-Path $projectRoot 'deleted.php'
    [IO.File]::WriteAllText($deletedPath, "<?php`necho 'deleted';`n", (New-Object Text.UTF8Encoding($false)))

    $post = @{ tool_input = @{ file_path = $paths[0] } } | ConvertTo-Json -Compress
    $post | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath
    $post | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath
    "*** Update File: $($paths[1])`n*** Update File: $($paths[2])" | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath
    (@{ tool_input = @{ file_path = $deletedPath } } | ConvertTo-Json -Compress) | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath
    if ($LASTEXITCODE -ne 0) { throw "PostToolUse hook failed with exit code $LASTEXITCODE" }

    $stateFiles = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'CodexSettings\HookState') -Filter '*.json' -File)
    if ($stateFiles.Count -ne 1) { throw "Expected one state file, found $($stateFiles.Count)." }
    $state = Get-Content -Raw -LiteralPath $stateFiles[0].FullName | ConvertFrom-Json
    if (@($state.files).Count -ne 4) { throw "Expected four unique files, found $(@($state.files).Count)." }
    foreach ($path in $paths) {
        if ([IO.File]::ReadAllText($path).Contains("`r`n")) { throw "PostToolUse converted before Stop: $path" }
    }

    # A child Stop during an active update must not finalize the state.
    $updaterJob = Start-Job -ScriptBlock {
        param([string]$PowerShell, [string]$Path, [string]$Payload)
        1..12 | ForEach-Object {
            $Payload | & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $Path
            [int]$LASTEXITCODE
            Start-Sleep -Milliseconds 250
        }
    } -ArgumentList $pwsh, $hookPath, $post
    $jobs += $updaterJob
    $stopperJob = Start-Job -ScriptBlock {
        param([string]$PowerShell, [string]$Path)
        & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $Path -Flush
        [int]$LASTEXITCODE
    } -ArgumentList $pwsh, $hookPath
    $jobs += $stopperJob
    $earlyResult = @($stopperJob | Wait-Job | Receive-Job)
    $updaterResult = @($updaterJob | Wait-Job | Receive-Job)
    if (@($earlyResult | Where-Object { $_ -ne 0 }).Count -gt 0) { throw "Early Stop did not return success: $($earlyResult -join ', ')" }
    if (@($updaterResult | Where-Object { $_ -ne 0 }).Count -gt 0) { throw "PostToolUse update failed during Stop: $($updaterResult -join ', ')" }
    if (-not (Test-Path -LiteralPath $stateFiles[0].FullName -PathType Leaf)) { throw 'Early Stop cleared active state.' }
    Remove-Item -LiteralPath $deletedPath -Force

    # Multiple final Stops convert every queued file once and clear state only after success.
    $finalJobs = @(1..3 | ForEach-Object {
        Start-Job -ScriptBlock {
            param([string]$PowerShell, [string]$Path)
            & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $Path -Flush | Out-Null
            [int]$LASTEXITCODE
        } -ArgumentList $pwsh, $hookPath
    })
    $jobs += $finalJobs
    $finalResults = @($finalJobs | Wait-Job | Receive-Job)
    if (@($finalResults | Where-Object { $_ -ne 0 }).Count -gt 0) { throw "Final Stop failed: $($finalResults -join ', ')" }
    foreach ($path in $paths) {
        if (-not [IO.File]::ReadAllText($path).Contains("`r`n")) { throw "Final Stop did not normalize: $path" }
    }
    if (Test-Path -LiteralPath $stateFiles[0].FullName -PathType Leaf) { throw 'State was not cleared after successful finalization.' }

    . $common
    $template = Get-Content -Raw -LiteralPath $hooksTemplate
    $old = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"crlf-updated-files.ps1 -Flush"}]}],"Notification":[{"hooks":[]}]}}'
    $migrated = Merge-HooksJson $old $template | ConvertFrom-Json
    if (@($migrated.hooks.Stop).Count -ne 1) { throw 'Migration did not retain exactly one Stop hook.' }
    if ((@($migrated.hooks.Stop)[0] | ConvertTo-Json -Depth 20 -Compress) -notmatch 'crlf-updated-files\.ps1') { throw 'Migrated Stop hook is incorrect.' }
    if (-not ($migrated.hooks.PSObject.Properties.Name -contains 'Notification')) { throw 'Migration removed unrelated hooks.' }

    Write-Output 'CRLF hook regression tests passed.'
} finally {
    foreach ($job in @($jobs)) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    if ($null -eq $localAppDataBefore) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue }
    else { $env:LOCALAPPDATA = $localAppDataBefore }
    if (Test-Path -LiteralPath $projectRoot) { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
