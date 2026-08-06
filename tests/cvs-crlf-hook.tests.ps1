$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$hookTemplate = Join-Path $repositoryRoot 'src\templates\environments\cvs\hooks.json'
$hookScript = Join-Path $repositoryRoot 'src\templates\environments\cvs\hooks\normalize-cvs-crlf.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-cvs-hook-' + [guid]::NewGuid().ToString('N'))

function Invoke-TestHook {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$MockDirectory,
        [Parameter(Mandatory)][string]$MockOutputPath,
        [switch]$FailCvs
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new('pwsh')
    $startInfo.ArgumentList.Add('-NoLogo')
    $startInfo.ArgumentList.Add('-NoProfile')
    $startInfo.ArgumentList.Add('-File')
    $startInfo.ArgumentList.Add($hookScript)
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['PATH'] = $MockDirectory + [IO.Path]::PathSeparator + $env:PATH
    $startInfo.Environment['CVS_MOCK_OUTPUT'] = $MockOutputPath
    $startInfo.Environment['CVS_MOCK_FAIL'] = if ($FailCvs) { '1' } else { '0' }

    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.WriteLine('{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done"}')
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Assert-NoLfOnly([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -eq 0x0A -and ($index -eq 0 -or $bytes[$index - 1] -ne 0x0D)) {
            throw "File still contains LF-only line endings: $Path"
        }
    }
}

try {
    $hooks = Get-Content -LiteralPath $hookTemplate -Raw | ConvertFrom-Json
    $eventNames = @($hooks.hooks.PSObject.Properties.Name)
    if ($eventNames.Count -ne 1 -or $eventNames[0] -ne 'Stop') { throw 'CVS hooks must contain only Stop.' }
    $stopCommand = [string]$hooks.hooks.Stop[0].hooks[0].commandWindows
    if ($stopCommand -match '(?i)-Flush') { throw 'Stop hook still uses the obsolete -Flush mode.' }
    $hookSource = Get-Content -LiteralPath $hookScript -Raw
    if ($hookSource -notmatch '& cvs -qn update') { throw 'Stop hook does not scan CVS changes directly.' }
    foreach ($obsoletePattern in @('\$Flush', 'HookState', 'Mutex', 'quietPeriod', 'Add-PatchTargets', 'Add-PayloadPatchTargets', 'Read-State', 'Write-State')) {
        if ($hookSource -match $obsoletePattern) { throw "Stop hook still contains obsolete state tracking code: $obsoletePattern" }
    }

    $projectRoot = Join-Path $testRoot 'project'
    $workingRoot = Join-Path $projectRoot 'src'
    $mockRoot = Join-Path $testRoot 'mock-bin'
    New-Item -ItemType Directory -Path (Join-Path $projectRoot 'CVS'), (Join-Path $workingRoot 'CVS'), (Join-Path $projectRoot '.codex'), $mockRoot -Force | Out-Null

    $mockScript = @'
@echo off
if "%CVS_MOCK_FAIL%"=="1" (
  >&2 echo mock cvs failure
  exit /b 1
)
type "%CVS_MOCK_OUTPUT%"
exit /b 0
'@
    [IO.File]::WriteAllText((Join-Path $mockRoot 'cvs.cmd'), $mockScript, [Text.Encoding]::ASCII)

    $utf8 = [Text.UTF8Encoding]::new($false)
    $modifiedPath = Join-Path $workingRoot 'modified.php'
    $addedPath = Join-Path $workingRoot 'added.txt'
    $conflictPath = Join-Path $workingRoot 'conflict.js'
    $binaryPath = Join-Path $workingRoot 'binary.php'
    $utf16Path = Join-Path $workingRoot 'utf16.php'
    $largePath = Join-Path $workingRoot 'large.php'
    $legacyPath = Join-Path $workingRoot 'legacy.php'
    $metadataPath = Join-Path $workingRoot 'CVS\Entries.txt'
    $codexPath = Join-Path $projectRoot '.codex\config.toml'
    $outsideRoot = Join-Path $testRoot 'outside'
    $outsidePath = Join-Path $outsideRoot 'outside.php'
    $junctionPath = Join-Path $workingRoot 'linked'
    New-Item -ItemType Directory -Path $outsideRoot -Force | Out-Null
    [IO.File]::WriteAllText($modifiedPath, "one`ntwo`n", $utf8)
    [IO.File]::WriteAllText($addedPath, "one`r`ntwo`n", $utf8)
    [IO.File]::WriteAllText($conflictPath, "one`r`ntwo`r`n", $utf8)
    [IO.File]::WriteAllBytes($binaryPath, [byte[]](0x41, 0x00, 0x0A, 0x42))
    [IO.File]::WriteAllText($utf16Path, "one`ntwo`n", [Text.Encoding]::Unicode)
    [IO.File]::WriteAllBytes($largePath, [byte[]]::new(10MB + 1))
    [IO.File]::WriteAllBytes($legacyPath, [byte[]](0xA4, 0x40, 0x0A, 0xA4, 0x41, 0x0A))
    [IO.File]::WriteAllText($metadataPath, "entry`n", $utf8)
    [IO.File]::WriteAllText($codexPath, "setting = true`n", $utf8)
    [IO.File]::WriteAllText($outsidePath, "outside`n", $utf8)
    New-Item -ItemType Junction -Path $junctionPath -Target $outsideRoot | Out-Null

    $conflictWriteTime = [DateTime]::UtcNow.AddMinutes(-5)
    [IO.File]::SetLastWriteTimeUtc($conflictPath, $conflictWriteTime)
    $binaryBefore = [IO.File]::ReadAllBytes($binaryPath)
    $utf16Before = [IO.File]::ReadAllBytes($utf16Path)
    $metadataBefore = [IO.File]::ReadAllBytes($metadataPath)
    $codexBefore = [IO.File]::ReadAllBytes($codexPath)
    $outsideBefore = [IO.File]::ReadAllBytes($outsidePath)

    $mockOutput = Join-Path $testRoot 'cvs-output.txt'
    @(
        'M src/modified.php'
        'A src/added.txt'
        'C src/conflict.js'
        'M src/binary.php'
        'M src/utf16.php'
        'M src/large.php'
        'M src/legacy.php'
        'M src/CVS/Entries.txt'
        'M .codex/config.toml'
        'M src/linked/outside.php'
        '? src/untracked.php'
        'U src/untouched.php'
    ) | Set-Content -LiteralPath $mockOutput -Encoding ascii

    $result = Invoke-TestHook -WorkingDirectory $workingRoot -MockDirectory $mockRoot -MockOutputPath $mockOutput
    if ($result.ExitCode -ne 0) { throw "CVS hook failed: $($result.Stderr)" }
    if (-not [string]::IsNullOrEmpty($result.Stdout)) { throw "CVS hook wrote stdout: $($result.Stdout)" }
    if (-not [string]::IsNullOrEmpty($result.Stderr)) { throw "CVS hook wrote stderr on success: $($result.Stderr)" }
    Assert-NoLfOnly $modifiedPath
    Assert-NoLfOnly $addedPath
    Assert-NoLfOnly $conflictPath
    Assert-NoLfOnly $legacyPath
    if ([IO.File]::GetLastWriteTimeUtc($conflictPath) -ne $conflictWriteTime) { throw 'Existing CRLF file was rewritten.' }
    if ([Convert]::ToHexString([IO.File]::ReadAllBytes($binaryPath)) -ne [Convert]::ToHexString($binaryBefore)) { throw 'Binary file was modified.' }
    if ([Convert]::ToHexString([IO.File]::ReadAllBytes($utf16Path)) -ne [Convert]::ToHexString($utf16Before)) { throw 'UTF-16 file was modified.' }
    if ((Get-Item -LiteralPath $largePath).Length -ne 10MB + 1) { throw 'Oversized file was modified.' }
    if ([Convert]::ToHexString([IO.File]::ReadAllBytes($metadataPath)) -ne [Convert]::ToHexString($metadataBefore)) { throw 'CVS metadata was modified.' }
    if ([Convert]::ToHexString([IO.File]::ReadAllBytes($codexPath)) -ne [Convert]::ToHexString($codexBefore)) { throw '.codex file was modified.' }
    if ([Convert]::ToHexString([IO.File]::ReadAllBytes($outsidePath)) -ne [Convert]::ToHexString($outsideBefore)) { throw 'File reached through a reparse point was modified.' }
    if ([Convert]::ToHexString([IO.File]::ReadAllBytes($legacyPath)) -ne 'A4400D0AA4410D0A') { throw 'Legacy encoded bytes were not preserved.' }

    [IO.File]::WriteAllText($mockOutput, '', [Text.Encoding]::ASCII)
    $noChanges = Invoke-TestHook -WorkingDirectory $workingRoot -MockDirectory $mockRoot -MockOutputPath $mockOutput
    if ($noChanges.ExitCode -ne 0 -or $noChanges.Stdout -ne '' -or $noChanges.Stderr -ne '') { throw 'No-change hook run was not silent and successful.' }

    $readOnlyPath = Join-Path $workingRoot 'readonly.php'
    [IO.File]::WriteAllText($readOnlyPath, "readonly`n", $utf8)
    [IO.File]::SetAttributes($readOnlyPath, [IO.FileAttributes]::ReadOnly)
    try {
        [IO.File]::WriteAllText($mockOutput, "M src/readonly.php`r`n", [Text.Encoding]::ASCII)
        $conversionFailure = Invoke-TestHook -WorkingDirectory $workingRoot -MockDirectory $mockRoot -MockOutputPath $mockOutput
        if ($conversionFailure.ExitCode -eq 0) { throw 'CRLF conversion failure returned success.' }
        if ($conversionFailure.Stdout -ne '') { throw 'CRLF conversion failure wrote stdout.' }
        if ($conversionFailure.Stderr -notmatch 'CRLF conversion failed: src/readonly\.php') { throw 'CRLF conversion failure was not reported on stderr.' }
    } finally {
        [IO.File]::SetAttributes($readOnlyPath, [IO.FileAttributes]::Normal)
    }

    $failure = Invoke-TestHook -WorkingDirectory $workingRoot -MockDirectory $mockRoot -MockOutputPath $mockOutput -FailCvs
    if ($failure.ExitCode -eq 0) { throw 'CVS command failure returned success.' }
    if ($failure.Stdout -ne '') { throw 'CVS command failure wrote stdout.' }
    if ($failure.Stderr -notmatch 'mock cvs failure') { throw 'CVS command failure was not reported on stderr.' }

    Write-Host 'CVS CRLF hook tests passed.'
} finally {
    if ($null -ne $junctionPath -and (Test-Path -LiteralPath $junctionPath)) { Remove-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
