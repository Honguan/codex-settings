$ErrorActionPreference = 'Stop'
# Archived with the inactive CVS mixed-line-ending Hook.
$hookPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'mixed-line-ending-hook.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-mixed-line-ending-' + [guid]::NewGuid().ToString('N'))
$previousPath = $env:PATH
$previousHome = $env:HOME

function Invoke-TestHook([string]$Mode, [string]$Root, [string]$SessionId, [string]$RelativePath) {
    $inputObject = [ordered]@{
        session_id = $SessionId
        cwd = $Root
        tool_input = [ordered]@{ code = $(if ([string]::IsNullOrWhiteSpace($RelativePath)) { '' } else { "await tools.apply_patch(`"*** Begin Patch`n*** Update File: $RelativePath`n*** End Patch`")" }) }
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh).Source
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $hookPath, '-Mode', $Mode)) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Write(($inputObject | ConvertTo-Json -Depth 5 -Compress))
    $process.StandardInput.Close()
    $process.WaitForExit()
    $output = $process.StandardOutput.ReadToEnd()
    if ($process.ExitCode -ne 0) { throw "CVS $Mode hook failed: $($process.StandardError.ReadToEnd())" }
    if (-not [string]::IsNullOrWhiteSpace($output)) { throw "CVS $Mode hook returned success output to the model: $output" }
}

try {
    $binRoot = Join-Path $testRoot 'bin'
    New-Item -ItemType Directory -Path $binRoot -Force | Out-Null
@'
$logPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'calls.log'
Add-Content -LiteralPath $logPath -Value ($args -join '|')
$fix = $args[0] -replace '^--fix=', ''
$paths = @($args | Select-Object -Skip 1)
if ($fix -eq 'no') { exit 0 }
foreach ($path in $paths) {
    $content = [IO.File]::ReadAllText($path)
    if ($fix -eq 'auto') {
        $crlf = [regex]::Matches($content, "`r`n").Count
        $lf = [regex]::Matches($content.Replace("`r`n", ''), "`n").Count
        $style = if ($crlf -ge $lf) { 'crlf' } else { 'lf' }
    } else { $style = $fix }
    $ending = if ($style -eq 'crlf') { "`r`n" } else { "`n" }
    $lines = @([regex]::Split($content, "`r`n|`n"))
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -SkipLast 1) }
    [IO.File]::WriteAllText($path, ($lines -join $ending) + $ending, [Text.UTF8Encoding]::new($false))
}
exit 0
'@ | Set-Content -LiteralPath (Join-Path $binRoot 'mixed-line-ending.ps1') -Encoding utf8NoBOM
    $env:PATH = $binRoot + [IO.Path]::PathSeparator + $previousPath
    $env:HOME = Join-Path $testRoot 'home'
    $env:CODEX_SETTINGS_LINE_ENDING_STATE_ROOT = Join-Path $testRoot 'state'

    $cvsRoot = Join-Path $testRoot 'cvs'
    New-Item -ItemType Directory -Path (Join-Path $cvsRoot 'CVS') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $cvsRoot 'CVS\Entries'), "/sample.txt/1.1///`n/untouched.txt/1.1///`n/fallback.txt/1.1///`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $cvsRoot 'sample.txt'), "one`r`ntwo`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $cvsRoot 'untouched.txt'), "leave`nme`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $cvsRoot 'fallback.txt'), "old`r`nvalue", [Text.UTF8Encoding]::new($false))

    $sessionId = 'cvs-test'
    Invoke-TestHook -Mode Track -Root $cvsRoot -SessionId $sessionId -RelativePath sample.txt
    $statePath = (Get-ChildItem -LiteralPath $env:CODEX_SETTINGS_LINE_ENDING_STATE_ROOT -Filter '*.json' -File).FullName
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json -AsHashtable
    if ($state.files.Count -ne 1) { throw 'CVS PreToolUse tracked files outside the tool input.' }
    [IO.File]::WriteAllText((Join-Path $cvsRoot 'sample.txt'), "one`ntwo`n", [Text.UTF8Encoding]::new($false))
    Invoke-TestHook -Mode Track -Root $cvsRoot -SessionId $sessionId -RelativePath sample.txt
    Invoke-TestHook -Mode Fix -Root $cvsRoot -SessionId $sessionId -RelativePath sample.txt
    $sample = [IO.File]::ReadAllText((Join-Path $cvsRoot 'sample.txt'))
    if ($sample -ne "one`r`ntwo`r`n") { throw 'CVS hook did not retain the first recorded CRLF style.' }

    Invoke-TestHook -Mode Track -Root $cvsRoot -SessionId $sessionId -RelativePath new.txt
    [IO.File]::WriteAllText((Join-Path $cvsRoot 'new.txt'), "a`r`nb`r`nc`nd`r`n", [Text.UTF8Encoding]::new($false))
    Invoke-TestHook -Mode Fix -Root $cvsRoot -SessionId $sessionId -RelativePath new.txt
    if ([IO.File]::ReadAllText((Join-Path $cvsRoot 'new.txt')).Replace("`r`n", '') -match "`n") { throw 'CVS new file was not normalized with auto.' }

    Invoke-TestHook -Mode Track -Root $cvsRoot -SessionId $sessionId -RelativePath fallback.txt
    [IO.File]::WriteAllText((Join-Path $cvsRoot 'fallback.txt'), "changed`nvalue", [Text.UTF8Encoding]::new($false))
    Invoke-TestHook -Mode Finalize -Root $cvsRoot -SessionId $sessionId -RelativePath ''
    $fallbackBytes = [IO.File]::ReadAllBytes((Join-Path $cvsRoot 'fallback.txt'))
    if ([Text.Encoding]::UTF8.GetString($fallbackBytes) -ne "changed`r`nvalue" -or $fallbackBytes[-1] -eq 10) { throw 'CVS Stop fallback did not preserve CRLF without an EOF newline.' }

    $log = [IO.File]::ReadAllText((Join-Path $testRoot 'calls.log'))
    if ($log -notmatch '--fix=crlf\|.*sample\.txt' -or $log -notmatch '--fix=auto\|.*new\.txt') { throw 'CVS hook used the wrong mixed-line-ending mode.' }
    if ($log -match 'untouched\.txt') { throw 'CVS hook processed an unmodified project file.' }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { throw 'CVS Stop hook did not remove session state.' }

    Write-Host 'Mixed-line-ending hook flow tests passed.'
} finally {
    $env:PATH = $previousPath
    $env:HOME = $previousHome
    Remove-Item Env:\CODEX_SETTINGS_LINE_ENDING_STATE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
