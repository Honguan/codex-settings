$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$hookScript = Join-Path $repositoryRoot 'src\templates\environments\cvs\hooks\preserve-line-endings.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-line-endings-' + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $testRoot 'project'
$binRoot = Join-Path $testRoot 'bin'
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Write-TestBytes([string]$Name, [byte[]]$Bytes) {
    [IO.File]::WriteAllBytes((Join-Path $projectRoot $Name), $Bytes)
}

function Assert-Bytes([string]$Name, [byte[]]$Expected) {
    $actual = [IO.File]::ReadAllBytes((Join-Path $projectRoot $Name))
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$actual, [byte[]]$Expected)) {
        throw "位元組內容不符：$Name"
    }
}

function Invoke-HookProcess([string]$WorkingDirectory, [string]$PathValue) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    $startInfo.ArgumentList.Add('-NoLogo')
    $startInfo.ArgumentList.Add('-NoProfile')
    $startInfo.ArgumentList.Add('-File')
    $startInfo.ArgumentList.Add($hookScript)
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['PATH'] = $PathValue
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

try {
    New-Item -ItemType Directory -Path (Join-Path $projectRoot 'CVS'), $binRoot -Force | Out-Null

    Write-TestBytes 'crlf-majority.txt' ([Text.Encoding]::ASCII.GetBytes("a`r`nb`r`nc`r`nd`n"))
    Write-TestBytes 'lf-majority.txt' ([Text.Encoding]::ASCII.GetBytes("a`nb`nc`nd`r`n"))
    Write-TestBytes 'pure-crlf.txt' ([Text.Encoding]::ASCII.GetBytes("a`r`nb`r`n"))
    Write-TestBytes 'pure-lf.txt' ([Text.Encoding]::ASCII.GetBytes("a`nb`n"))
    Write-TestBytes 'single-line.txt' ([Text.Encoding]::ASCII.GetBytes('single'))
    Write-TestBytes 'ambiguous.txt' ([Text.Encoding]::ASCII.GetBytes("a`r`nb`n"))
    Write-TestBytes 'utf8-bom.txt' ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("a`r`nb`r`nc`n"))
    Write-TestBytes 'ansi.txt' ([byte[]](0xE9, 0x0A, 0xE8, 0x0A, 0xE7, 0x0D, 0x0A))
    Write-TestBytes 'binary.bin' ([byte[]](0x00, 0x41, 0x0D, 0x0A, 0x42, 0x0A))

    $pureCrlf = [IO.File]::ReadAllBytes((Join-Path $projectRoot 'pure-crlf.txt'))
    $pureLf = [IO.File]::ReadAllBytes((Join-Path $projectRoot 'pure-lf.txt'))
    $singleLine = [IO.File]::ReadAllBytes((Join-Path $projectRoot 'single-line.txt'))
    $ambiguous = [IO.File]::ReadAllBytes((Join-Path $projectRoot 'ambiguous.txt'))
    $binary = [IO.File]::ReadAllBytes((Join-Path $projectRoot 'binary.bin'))

    $cvsOutput = @(
        'M crlf-majority.txt',
        'M lf-majority.txt',
        'M pure-crlf.txt',
        'M pure-lf.txt',
        'A single-line.txt',
        'C ambiguous.txt',
        'M utf8-bom.txt',
        'M ansi.txt',
        'M binary.bin'
    )
    $cmdLines = @('@echo off') + @($cvsOutput | ForEach-Object { 'echo ' + $_ })
    [IO.File]::WriteAllText((Join-Path $binRoot 'cvs.cmd'), ($cmdLines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)

    $result = Invoke-HookProcess -WorkingDirectory $projectRoot -PathValue ($binRoot + [IO.Path]::PathSeparator + $env:PATH)
    if ($result.ExitCode -ne 0) { throw "Hook 結束碼不是 0：$($result.ExitCode)" }
    if ($result.Stdout.Trim() -ne '{}') { throw "Stop Hook 標準輸出不是唯一的合法空 JSON：$($result.Stdout)" }
    if ($result.Stderr -notmatch 'ambiguous\.txt') {
        throw '數量相同的混合換行沒有輸出警告。'
    }

    Assert-Bytes 'crlf-majority.txt' ([Text.Encoding]::ASCII.GetBytes("a`r`nb`r`nc`r`nd`r`n"))
    Assert-Bytes 'lf-majority.txt' ([Text.Encoding]::ASCII.GetBytes("a`nb`nc`nd`n"))
    Assert-Bytes 'pure-crlf.txt' $pureCrlf
    Assert-Bytes 'pure-lf.txt' $pureLf
    Assert-Bytes 'single-line.txt' $singleLine
    Assert-Bytes 'ambiguous.txt' $ambiguous
    Assert-Bytes 'utf8-bom.txt' ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("a`r`nb`r`nc`r`n"))
    Assert-Bytes 'ansi.txt' ([byte[]](0xE9, 0x0A, 0xE8, 0x0A, 0xE7, 0x0A))
    Assert-Bytes 'binary.bin' $binary

    [IO.File]::WriteAllText((Join-Path $binRoot 'cvs.cmd'), "@echo off`r`nexit /b 1`r`n", [Text.Encoding]::ASCII)
    $failureResult = Invoke-HookProcess -WorkingDirectory $projectRoot -PathValue ($binRoot + [IO.Path]::PathSeparator + $env:PATH)
    if ($failureResult.ExitCode -ne 0 -or $failureResult.Stdout.Trim() -ne '{}' -or $failureResult.Stderr -notmatch 'CVS status scan failed') {
        throw 'CVS 掃描失敗時沒有警告並安全結束。'
    }

    $outsideRoot = Join-Path $testRoot 'outside'
    New-Item -ItemType Directory -Path $outsideRoot -Force | Out-Null
    $outsideResult = Invoke-HookProcess -WorkingDirectory $outsideRoot -PathValue $env:PATH
    if ($outsideResult.ExitCode -ne 0 -or $outsideResult.Stdout.Trim() -ne '{}') { throw '非 CVS 專案中未安全結束。' }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Preserve line endings hook tests passed.'
