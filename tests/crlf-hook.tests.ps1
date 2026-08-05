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

    $hookConfiguration = Get-Content -Raw -LiteralPath $hooksTemplate | ConvertFrom-Json
    $matcher = [string]$hookConfiguration.hooks.PostToolUse[0].matcher
    if ('exec' -notmatch $matcher) { throw "PostToolUse matcher does not include exec: $matcher" }

    $paths = @('A.php', 'B.php', 'C.php') | ForEach-Object { Join-Path $projectRoot $_ }
    foreach ($path in $paths) {
        [IO.File]::WriteAllText($path, "<?php`necho 'ok';`n", (New-Object Text.UTF8Encoding($false)))
    }
    $deletedPath = Join-Path $projectRoot 'deleted.php'
    [IO.File]::WriteAllText($deletedPath, "<?php`necho 'deleted';`n", (New-Object Text.UTF8Encoding($false)))
    $untouchedPath = Join-Path $projectRoot 'untouched.php'
    [IO.File]::WriteAllText($untouchedPath, "<?php`necho 'untouched';`n", (New-Object Text.UTF8Encoding($false)))

    $post = @{ tool_input = @{ file_path = $paths[0] } } | ConvertTo-Json -Compress
    $directOutput = @(($post | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath) 2>&1)
    if (($directOutput -join "`n") -notmatch 'CRLF tracked files: 1') { throw 'Direct apply_patch target was not reported.' }
    $post | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath | Out-Null

    $execCommand = "const patch = `"*** Begin Patch\n*** Update File: $($paths[1])\n@@\n*** Update File: C.php\n@@\n*** End Patch`";"
    $execPayload = @{ tool_name = 'exec'; tool_input = @{ command = $execCommand } } | ConvertTo-Json -Compress
    $execOutput = @(($execPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath) 2>&1)
    $execText = $execOutput -join "`n"
    if ($execText -notmatch 'CRLF tracked files: 2') { throw "exec targets were not reported: $execText" }
    if ($execText -notmatch 'CRLF target: B\.php' -or $execText -notmatch 'CRLF target: C\.php') { throw "exec target paths were incomplete: $execText" }

    (@{ tool_input = @{ file_path = $deletedPath } } | ConvertTo-Json -Compress) | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "PostToolUse hook failed with exit code $LASTEXITCODE" }

    $zeroPayload = @{ tool_name = 'exec'; tool_input = @{ command = 'Write-Output no-patch' } } | ConvertTo-Json -Compress
    $zeroOutput = @(($zeroPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath) 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($zeroOutput -join "`n") -notmatch 'CRLF tracked files: 0') { throw 'Zero-target warning was not emitted.' }

    $stateFiles = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'CodexSettings\HookState') -Filter '*.json' -File)
    if ($stateFiles.Count -ne 1) { throw "Expected one state file, found $($stateFiles.Count)." }
    $state = Get-Content -Raw -LiteralPath $stateFiles[0].FullName | ConvertFrom-Json
    if (@($state.files).Count -ne 4) { throw "Expected four unique files, found $(@($state.files).Count)." }
    foreach ($path in $paths) {
        if ([IO.File]::ReadAllText($path).Contains("`r`n")) { throw "PostToolUse converted before Stop: $path" }
    }
    if (@($state.files) -contains 'untouched.php') { throw 'Unmodified user file was added to CRLF state.' }

    # A child Stop during an active update must not finalize the state.
    $updaterJob = Start-Job -ScriptBlock {
        param([string]$PowerShell, [string]$Path, [string]$Payload)
        1..12 | ForEach-Object {
            $Payload | & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $Path | Out-Null
            [int]$LASTEXITCODE
            Start-Sleep -Milliseconds 250
        }
    } -ArgumentList $pwsh, $hookPath, $post
    $jobs += $updaterJob
    $stopperJob = Start-Job -ScriptBlock {
        param([string]$PowerShell, [string]$Path)
        & $PowerShell -NoProfile -ExecutionPolicy Bypass -File $Path -Flush | Out-Null
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
            $output = @(& $PowerShell -NoProfile -ExecutionPolicy Bypass -File $Path -Flush)
            [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Output = ($output -join "`n") }
        } -ArgumentList $pwsh, $hookPath
    })
    $jobs += $finalJobs
    $finalResults = @($finalJobs | Wait-Job | Receive-Job)
    if (@($finalResults | Where-Object { $_.ExitCode -ne 0 }).Count -gt 0) { throw "Final Stop failed: $($finalResults.ExitCode -join ', ')" }
    $finalSummary = @($finalResults.Output | Where-Object { $_ -match '^Tracked=' }) -join "`n"
    if ($finalSummary -notmatch 'Tracked=4 Converted=3 Verified=3 Skipped=1 Failed=0') { throw "Final summary was missing or incorrect: $finalSummary" }
    foreach ($path in $paths) {
        $raw = [IO.File]::ReadAllText($path)
        if (-not $raw.Contains("`r`n") -or ([regex]::Matches($raw, "(?<!`r)`n")).Count -gt 0) { throw "Final Stop did not normalize: $path" }
    }
    if (([regex]::Matches([IO.File]::ReadAllText($untouchedPath), "(?<!`r)`n")).Count -eq 0) { throw 'Unmodified user file was converted.' }
    if (Test-Path -LiteralPath $stateFiles[0].FullName -PathType Leaf) { throw 'State was not cleared after successful finalization.' }

    . $common
    $template = Get-Content -Raw -LiteralPath $hooksTemplate
    $old = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"crlf-updated-files.ps1 -Flush"}]}],"Notification":[{"hooks":[]}]}}'
    $migrated = Merge-HooksJson $old $template | ConvertFrom-Json
    if (@($migrated.hooks.Stop).Count -ne 1) { throw 'Migration did not retain exactly one Stop hook.' }
    if ((@($migrated.hooks.Stop)[0] | ConvertTo-Json -Depth 20 -Compress) -notmatch 'crlf-updated-files\.ps1') { throw 'Migrated Stop hook is incorrect.' }
    if ('exec' -notmatch [string]$migrated.hooks.PostToolUse[0].matcher) { throw 'Migration did not add exec to PostToolUse.' }
    if (-not ($migrated.hooks.PSObject.Properties.Name -contains 'Notification')) { throw 'Migration removed unrelated hooks.' }

    Write-Output 'CRLF hook regression tests passed.'
} finally {
    foreach ($job in @($jobs)) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    if ($null -eq $localAppDataBefore) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue }
    else { $env:LOCALAPPDATA = $localAppDataBefore }
    if (Test-Path -LiteralPath $projectRoot) { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
