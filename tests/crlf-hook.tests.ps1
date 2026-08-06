[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$hookTemplate = Join-Path $repositoryRoot 'templates\cvs-project\.codex\hooks\crlf-updated-files.ps1'
$hooksTemplate = Join-Path $repositoryRoot 'templates\cvs-project\.codex\hooks.json'
$common = Join-Path $repositoryRoot 'lib\codex-settings-common.ps1'
$installFunctions = Join-Path $repositoryRoot 'lib\install-functions.ps1'
$projectRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-crlf-' + [guid]::NewGuid().ToString('N'))
$jobs = @()
$localAppDataBefore = $env:LOCALAPPDATA

try {
    $env:LOCALAPPDATA = Join-Path $projectRoot '.local'
    $hookPath = Join-Path $projectRoot '.codex\hooks\crlf-updated-files.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $hookPath) -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $projectRoot '.codex-root') -Force | Out-Null
    Copy-Item -LiteralPath $hookTemplate -Destination $hookPath
    Copy-Item -LiteralPath $hooksTemplate -Destination (Join-Path $projectRoot '.codex\hooks.json')
    $pwsh = Join-Path $PSHOME 'pwsh.exe'

    $hookConfiguration = Get-Content -Raw -LiteralPath $hooksTemplate | ConvertFrom-Json
    $matcher = [string]$hookConfiguration.hooks.PostToolUse[0].matcher
    if ('exec' -notmatch $matcher) { throw "PostToolUse matcher does not include exec: $matcher" }
    $windowsHookCommand = [string]$hookConfiguration.hooks.PostToolUse[0].hooks[0].commandWindows
    if ($windowsHookCommand -notmatch '^pwsh\.exe\s' -or $windowsHookCommand -notmatch 'ExecutionPolicy Bypass') {
        throw 'Windows Hook must use PowerShell 7 with the bypass execution policy.'
    }

    $paths = @('A.php', 'B.php', 'C.php') | ForEach-Object { Join-Path $projectRoot $_ }
    foreach ($path in $paths) {
        [IO.File]::WriteAllText($path, "<?php`necho 'ok';`n", (New-Object Text.UTF8Encoding($false)))
    }
    $deletedPath = Join-Path $projectRoot 'deleted.php'
    [IO.File]::WriteAllText($deletedPath, "<?php`necho 'deleted';`n", (New-Object Text.UTF8Encoding($false)))
    $untouchedPath = Join-Path $projectRoot 'untouched.php'
    [IO.File]::WriteAllText($untouchedPath, "<?php`necho 'untouched';`n", (New-Object Text.UTF8Encoding($false)))

    $post = @{ tool_input = @{ file_path = $paths[0] } } | ConvertTo-Json -Compress
    Push-Location $projectRoot
    try {
        $windowsPostOutput = @(($post | & cmd.exe /d /s /c $windowsHookCommand) 2>&1)
        $windowsPostExitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($windowsPostExitCode -ne 0) {
        throw "Windows PostToolUse wrapper exited with code $windowsPostExitCode. Output: $($windowsPostOutput -join "`n")"
    }
    if (($windowsPostOutput -join "`n") -notmatch 'CRLF tracked files: 1') {
        throw 'Windows PostToolUse wrapper did not add the expected file to state.'
    }
    $directOutput = @(($post | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath) 2>&1)
    if (($directOutput -join "`n") -notmatch 'CRLF tracked files: 1') { throw 'Direct apply_patch target was not reported.' }
    $post | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath | Out-Null

    $execCommand = "const patch = `"*** Begin Patch\n*** Update File: $($paths[1])\n@@\n*** Update File: C.php\n@@\n*** End Patch`";"
    $execPayload = @{ tool_name = 'exec'; tool_input = @{ command = $execCommand } } | ConvertTo-Json -Compress
    $execOutput = @(($execPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath) 2>&1)
    $execText = $execOutput -join "`n"
    if ($execText -notmatch 'CRLF tracked files: 2') { throw "exec targets were not reported: $execText" }
    if ($execText -notmatch 'CRLF target: B\.php' -or $execText -notmatch 'CRLF target: C\.php') { throw "exec target paths were incomplete: $execText" }
    if ($LASTEXITCODE -ne 0 -or $execText -notmatch 'ToolName=exec PayloadParsed=True') { throw "exec payload diagnostics were incomplete: $execText" }

    $spacePath = Join-Path $projectRoot 'with space.php'
    [IO.File]::WriteAllText($spacePath, "<?php`necho 'space';`n", (New-Object Text.UTF8Encoding($false)))
    $paths += $spacePath
    $escapedExec = ('const patch = "*** Begin Patch\\n*** Update File: {0}\\n@@\\n*** Update File: {1}\\n@@\\n*** End Patch";' -f $spacePath.Replace('\', '/'), $paths[2].Replace('\', '/'))
    $escapedPayload = @{ input = @{ command = $escapedExec } } | ConvertTo-Json -Compress
    $escapedOutput = @(($escapedPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath) 2>&1)
    $escapedText = $escapedOutput -join "`n"
    if ($LASTEXITCODE -ne 0 -or $escapedText -notmatch 'CRLF tracked files: 2' -or $escapedText -notmatch 'with space\.php') { throw "Escaped exec payload was not handled safely: $escapedText" }

    $malformedOutput = @('{invalid-json' | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($malformedOutput -join "`n") -notmatch 'CRLF tracked files: 0') { throw 'Malformed payload did not safely return success.' }

    $missingFieldOutput = @('{"tool_name":"exec"}' | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($missingFieldOutput -join "`n") -notmatch 'PayloadParsed=True') { throw 'Missing payload fields did not safely return success.' }

    $rejectedPathOutput = @('{"tool_name":"exec","tool_input":{"file_path":"C:\\outside.php"}}' | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($rejectedPathOutput -join "`n") -notmatch 'Rejected=1') { throw 'A rejected path caused an unsafe Hook result.' }

    (@{ tool_input = @{ file_path = $deletedPath } } | ConvertTo-Json -Compress) | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "PostToolUse hook failed with exit code $LASTEXITCODE" }

    $zeroPayload = @{ tool_name = 'exec'; tool_input = @{ command = 'Write-Output no-patch' } } | ConvertTo-Json -Compress
    $zeroOutput = @(($zeroPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath) 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($zeroOutput -join "`n") -notmatch 'CRLF tracked files: 0') { throw 'Zero-target warning was not emitted.' }

    $stateFiles = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'CodexSettings\HookState') -Filter 'crlf-v2-*.json' -File)
    if ($stateFiles.Count -ne 1) { throw "Expected one state file, found $($stateFiles.Count)." }
    if ($stateFiles[0].Name -notmatch '^crlf-v2-[0-9A-F]{16}\.json$') { throw "State file is not versioned: $($stateFiles[0].Name)" }
    $state = Get-Content -Raw -LiteralPath $stateFiles[0].FullName | ConvertFrom-Json
    if (@($state.files).Count -ne 5) { throw "Expected five unique files, found $(@($state.files).Count)." }
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
    if ($finalSummary -notmatch 'Tracked=5 Converted=4 Verified=4 Skipped=1 Failed=0') { throw "Final summary was missing or incorrect: $finalSummary" }
    foreach ($path in $paths) {
        $raw = [IO.File]::ReadAllText($path)
        if (-not $raw.Contains("`r`n") -or ([regex]::Matches($raw, "(?<!`r)`n")).Count -gt 0) { throw "Final Stop did not normalize: $path" }
    }
    if (([regex]::Matches([IO.File]::ReadAllText($untouchedPath), "(?<!`r)`n")).Count -eq 0) { throw 'Unmodified user file was converted.' }
    if (Test-Path -LiteralPath $stateFiles[0].FullName -PathType Leaf) { throw 'State was not cleared after successful finalization.' }
    $emptyFlushOutput = @(& $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath -Flush 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($emptyFlushOutput -join "`n") -notmatch 'Tracked=0 Converted=0 Verified=0 Skipped=0 Failed=0') { throw 'Flush without state did not safely return success.' }

    . $common
    . $installFunctions
    $template = Get-Content -Raw -LiteralPath $hooksTemplate
    $old = [ordered]@{ hooks = [ordered]@{
        PostToolUse = @(
            @{ hooks = @(@{ type = 'command'; command = 'crlf-updated-files.ps1'; statusMessage = 'Converting updated file to CRLF' }) },
            @{ hooks = @(@{ type = 'command'; command = 'custom-post.ps1'; statusMessage = 'Custom post hook' }) }
        )
        Stop = @(
            @{ hooks = @(@{ type = 'command'; command = 'crlf-updated-files.ps1 -Flush'; statusMessage = 'Finalizing CRLF normalization' }) },
            @{ hooks = @(@{ type = 'command'; command = 'custom-stop.ps1'; statusMessage = 'Custom stop hook' }) }
        )
        Notification = @(@{ hooks = @(@{ type = 'command'; command = 'custom-notification.ps1' }) })
    } } | ConvertTo-Json -Depth 20
    $migratedContent = Merge-HooksJson $old $template
    $migrated = $migratedContent | ConvertFrom-Json
    $migratedCounts = Get-CrlfHookCounts -Content $migratedContent
    if ($migratedCounts.PostToolUse -ne 1 -or $migratedCounts.Stop -ne 1) { throw 'Migration did not retain exactly one CRLF hook per event.' }
    if ($migratedContent -match 'Converting updated file to CRLF|Finalizing CRLF normalization') { throw 'Migration retained a legacy CRLF status message.' }
    if (($migratedContent -notmatch 'custom-post\.ps1') -or ($migratedContent -notmatch 'custom-stop\.ps1')) { throw 'Migration removed custom event hooks.' }
    $managedPost = @($migrated.hooks.PostToolUse | Where-Object { Test-CrlfHookEntry $_ })[0]
    if ('exec' -notmatch [string]$managedPost.matcher) { throw 'Migration did not add exec to PostToolUse.' }
    if (-not ($migrated.hooks.PSObject.Properties.Name -contains 'Notification')) { throw 'Migration removed unrelated hooks.' }

    Assert-CrlfHookInstallation -Mode CVS -Root $projectRoot
    $projectHooksPath = Join-Path $projectRoot '.codex\hooks.json'
    $projectHooksOriginal = Get-Content -Raw -LiteralPath $projectHooksPath
    $duplicateHooks = $projectHooksOriginal | ConvertFrom-Json
    $duplicateHooks.hooks.PostToolUse = @($duplicateHooks.hooks.PostToolUse[0], $duplicateHooks.hooks.PostToolUse[0])
    [IO.File]::WriteAllText($projectHooksPath, ($duplicateHooks | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
    $duplicateRejected = $false
    try { Assert-CrlfHookInstallation -Mode CVS -Root $projectRoot } catch { $duplicateRejected = $true }
    if (-not $duplicateRejected) { throw 'CVS self-check accepted duplicate CRLF hooks.' }
    [IO.File]::WriteAllText($projectHooksPath, $projectHooksOriginal, (New-Object Text.UTF8Encoding($false)))

    $globalRoot = Join-Path $projectRoot 'global'
    $globalHooksDir = Join-Path $globalRoot 'hooks'
    New-Item -ItemType Directory -Path $globalHooksDir -Force | Out-Null
    $globalHooks = [ordered]@{ hooks = [ordered]@{
        UserPromptSubmit = @(@{ hooks = @(@{ type = 'command'; command = 'soluna-prompt-hook.ps1' }) })
        Stop = @(@{ hooks = @(@{ type = 'command'; command = 'legacy.ps1'; statusMessage = 'Converting updated files to CRLF' }) })
    } } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText((Join-Path $globalRoot 'hooks.json'), $globalHooks, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $globalHooksDir 'crlf-updated-files.ps1'), '# legacy', (New-Object Text.UTF8Encoding($false)))
    $transaction = New-FileTransaction -Root (Join-Path $projectRoot '.transactions\issue-3') -Mode 'Test'
    Remove-GlobalCrlfHooks -Root $globalRoot -Transaction $transaction
    Assert-CrlfHookInstallation -Mode Global -Root $globalRoot
    $globalAfter = Get-Content -Raw -LiteralPath (Join-Path $globalRoot 'hooks.json')
    if ($globalAfter -notmatch 'soluna-prompt-hook\.ps1') { throw 'Global cleanup removed the SOLUNA hook.' }
    if ((Get-CrlfHookCounts -Content $globalAfter).Total -ne 0) { throw 'Global cleanup retained a CRLF hook.' }

    $normalizedRoot = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $rootHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalizedRoot)))).Replace('-', '').Substring(0, 16) }
    finally { $sha.Dispose() }
    $stateBase = Join-Path $env:LOCALAPPDATA 'CodexSettings\HookState'
    $v1Json = Join-Path $stateBase "crlf-$rootHash.json"
    $v1Text = Join-Path $stateBase "crlf-$rootHash.txt"
    $v2Json = Join-Path $stateBase "crlf-v2-$rootHash.json"
    [IO.File]::WriteAllText($v1Json, '{}')
    [IO.File]::WriteAllText($v1Text, 'A.php')
    [IO.File]::WriteAllText($v2Json, '{}')
    Remove-LegacyCrlfState -ProjectRoot $projectRoot -Transaction $transaction
    if ((Test-Path -LiteralPath $v1Json) -or (Test-Path -LiteralPath $v1Text)) { throw 'Legacy CRLF state was not removed.' }
    if (-not (Test-Path -LiteralPath $v2Json -PathType Leaf)) { throw 'v2 CRLF state was removed during migration.' }

    [IO.File]::WriteAllText($v2Json, '{invalid-json')
    $failureOutput = @(& $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookPath -Flush 2>&1)
    $failureExitCode = $LASTEXITCODE
    $failureText = $failureOutput -join "`n"
    if ($failureExitCode -ne 1) { throw "Invalid state did not fail with exit code 1: $failureExitCode" }
    foreach ($required in @('HookSource=project', 'HookVersion=crlf-v2', 'StateFile=', 'Tracked=0', 'Converted=0', 'Verified=0', 'Rejected=', 'Failed=1', 'Error=')) {
        if ($failureText -notmatch [regex]::Escape($required)) { throw "Failure diagnostics were missing '$required': $failureText" }
    }

    Write-Output 'CRLF hook regression tests passed.'
} finally {
    foreach ($job in @($jobs)) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    if ($null -eq $localAppDataBefore) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue }
    else { $env:LOCALAPPDATA = $localAppDataBefore }
    if (Test-Path -LiteralPath $projectRoot) { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
