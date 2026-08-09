$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$originalConsoleEncoding = [Console]::OutputEncoding.WebName
$originalOutputEncoding = $OutputEncoding.WebName
$originalProgressView = if ($null -ne $PSStyle -and $null -ne $PSStyle.Progress) { [string]$PSStyle.Progress.View } else { '' }
$originalProgressMaxWidth = if ($null -ne $PSStyle -and $null -ne $PSStyle.Progress) { [int]$PSStyle.Progress.MaxWidth } else { 0 }

$unicode = New-InstallRendererProfile -RendererMode Interactive -OutputEncoding ([Text.UTF8Encoding]::new($false)) -WindowWidth 120
$ascii = New-InstallRendererProfile -RendererMode Line -OutputEncoding ([Text.ASCIIEncoding]::new()) -WindowWidth 80

if (-not $unicode.SupportsUnicode -or $unicode.Glyphs.Success -ne '✓' -or $unicode.Glyphs.Failure -ne '✗' -or $unicode.Glyphs.Separator -ne '—') {
    throw 'UTF-8 renderer profile 未使用一致的 Unicode glyph set。'
}
if ($ascii.SupportsUnicode -or (($ascii.Glyphs.Values -join '') -match '[^\x00-\x7F]')) {
    throw 'ASCII renderer profile 包含非 ASCII glyph。'
}

if ((Get-TerminalDisplayWidth 'A中Ｂ✓') -ne 6) {
    throw 'terminal display width 未正確計算 ASCII、CJK、全形與 installer glyph。'
}
$padded = Pad-TerminalText -Text '安裝 A' -Width 10
if ((Get-TerminalDisplayWidth $padded) -ne 10) {
    throw 'CJK padding 未依 terminal columns 對齊。'
}
$truncated = Truncate-TerminalText -Text 'AB中文C' -Width 5 -Ellipsis '…'
if ($truncated -ne 'AB中…' -or (Get-TerminalDisplayWidth $truncated) -gt 5) {
    throw "CJK truncate 結果錯誤：$truncated"
}

$step = [pscustomobject]@{ Index = 6; Name = 'Hook 去重與信任驗證' }
$status80 = Format-InstallProgressStatus -Profile (New-InstallRendererProfile -RendererMode Interactive -OutputEncoding ([Text.UTF8Encoding]::new($false)) -WindowWidth 80) -Step $step -Total 14 -Percent 43 -Detail '驗證 3 個 lifecycle hooks' -Elapsed '00:00:02'
$status120 = Format-InstallProgressStatus -Profile (New-InstallRendererProfile -RendererMode Interactive -OutputEncoding ([Text.UTF8Encoding]::new($false)) -WindowWidth 120) -Step $step -Total 14 -Percent 43 -Detail '驗證 3 個 lifecycle hooks' -Elapsed '00:00:02'
$status160 = Format-InstallProgressStatus -Profile (New-InstallRendererProfile -RendererMode Interactive -OutputEncoding ([Text.UTF8Encoding]::new($false)) -WindowWidth 160) -Step $step -Total 14 -Percent 43 -Detail '驗證 3 個 lifecycle hooks' -Elapsed '00:00:02'
if ($status80 -ne '[6/14] 43%  Hook 去重與信任驗證  00:00:02') { throw "80-column status 不穩定：$status80" }
if ($status120 -ne '[6/14] 43%  Hook 去重與信任驗證  00:00:02 — 驗證 3 個 lifecycle hooks') { throw "120-column status 不穩定：$status120" }
if ($status160 -ne $status120) { throw "160-column status 不穩定：$status160" }

$narrowProfile = New-InstallRendererProfile -RendererMode Interactive -OutputEncoding ([Text.UTF8Encoding]::new($false)) -WindowWidth 40
$longStatus = Format-InstallProgressStatus -Profile $narrowProfile -Step ([pscustomobject]@{ Index = 1; Name = '非常長的中文階段名稱以及 C:\Users\tester\really-long-path\config.toml' }) -Total 14 -Percent 0 -Detail ('詳細內容' * 30) -Elapsed '00:00:00'
if ((Get-TerminalDisplayWidth $longStatus) -gt 40 -or $longStatus.Contains('詳細內容')) {
    throw "窄 terminal status 未正確省略 Detail 或截斷：$longStatus"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-renderer-' + [guid]::NewGuid().ToString('N'))
try {
    function Write-Progress { param([int]$Id, [string]$Activity, [string]$Status, [int]$PercentComplete, [switch]$Completed) }
    $summarySteps = @(New-InstallationProgressSteps | Select-Object -First 2)
    $asciiProgress = Start-InstallProgress -Steps $summarySteps -Root $testRoot -RendererProfile $ascii
    Set-InstallProgress -Progress $asciiProgress -StepId $summarySteps[0].Id -Detail '建立計畫'
    Complete-InstallStep -Progress $asciiProgress -Result '完成'
    Set-InstallProgress -Progress $asciiProgress -StepId $summarySteps[1].Id -Detail '驗證環境'
    Fail-InstallStep -Progress $asciiProgress -Reason ('很長的中文錯誤原因' * 12)
    $longPath = 'C:\Users\tester\source\' + ('very-long-directory\' * 8) + 'config.toml'
    $asciiOutput = (& {
        Write-InstallResult -Progress $asciiProgress -Status FAILED -Summary @{ Failed = 1 } -Results @(
            [pscustomobject]@{ Mode = 'Global'; Root = $longPath; Files = @([pscustomobject]@{ RelativePath = $longPath; Status = 'Failed'; Changed = $false; ExistedBefore = $true }) }
        )
    } 6>&1 | Out-String)
    if ($asciiOutput -match '[✓✗—█░]' -or $asciiOutput -notmatch '\[OK\].*安裝計畫' -or $asciiOutput -notmatch '\[X\].*前置需求檢查') {
        throw 'ASCII summary 未一致使用安全 glyph set。'
    }
    foreach ($line in @($asciiOutput -split '\r?\n' | Where-Object { $_ })) {
        if ((Get-TerminalDisplayWidth $line) -gt 80) { throw "summary line 超過 terminal 寬度：$line" }
    }
    if ($asciiOutput -notmatch '(?m)^原因：') { throw '長錯誤原因未使用獨立 reason 行。' }
    $logBytes = [IO.File]::ReadAllBytes($asciiProgress.LogPath)
    if ($logBytes.Length -ge 3 -and $logBytes[0] -eq 0xEF -and $logBytes[1] -eq 0xBB -and $logBytes[2] -eq 0xBF) { throw 'installer log 不得包含 UTF-8 BOM。' }
    $logText = ([Text.UTF8Encoding]::new($false, $true)).GetString($logBytes)
    if (-not $logText.Contains('很長的中文錯誤原因')) { throw 'ASCII console profile 不得降低 installer log 的 UTF-8 診斷內容。' }

    $childScript = Join-Path $testRoot 'renderer-child.ps1'
    [IO.File]::WriteAllText($childScript, @'
param([string]$RepositoryRoot, [string]$EncodingName)
$script:ScriptRoot = Join-Path $RepositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')
$originalEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = if ($EncodingName -eq 'ascii') { [Text.ASCIIEncoding]::new() } else { [Text.UTF8Encoding]::new($false) }
    $profile = New-InstallRendererProfile -RendererMode Line
    [Console]::Out.Write("[$($profile.Glyphs.Success)] 中文")
} finally {
    [Console]::OutputEncoding = $originalEncoding
}
'@, [Text.UTF8Encoding]::new($false))
    foreach ($encodingName in @('utf8', 'ascii')) {
        $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-File', $childScript, $repositoryRoot, $encodingName)) { [void]$startInfo.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($startInfo)
        $bytes = [IO.MemoryStream]::new()
        $process.StandardOutput.BaseStream.CopyTo($bytes)
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "redirected child renderer 失敗：$errorText" }
        if ($encodingName -eq 'utf8') {
            $decoded = ([Text.UTF8Encoding]::new($false, $true)).GetString($bytes.ToArray())
            if ($decoded -ne '[✓] 中文') { throw "UTF-8 child renderer bytes 解碼錯誤：$decoded" }
        } elseif (($bytes.ToArray() | Where-Object { $_ -gt 0x7F }).Count -ne 0 -or [Text.Encoding]::ASCII.GetString($bytes.ToArray()) -notmatch '^\[OK\]') {
            throw 'ASCII child renderer 輸出了非 ASCII bytes 或錯誤 glyph。'
        }
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ([Console]::OutputEncoding.WebName -ne $originalConsoleEncoding -or $OutputEncoding.WebName -ne $originalOutputEncoding) {
    throw 'renderer 不得永久修改 Console.OutputEncoding 或 $OutputEncoding。'
}
if ($null -ne $PSStyle -and $null -ne $PSStyle.Progress -and ([string]$PSStyle.Progress.View -ne $originalProgressView -or [int]$PSStyle.Progress.MaxWidth -ne $originalProgressMaxWidth)) {
    throw 'renderer 不得永久修改 PSStyle.Progress。'
}

Write-Host 'Installation progress renderer tests passed.'
