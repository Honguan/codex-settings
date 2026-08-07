$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\plan-release.ps1'

$cases = @(
    @{ ChangeType = 'Architecture'; Expected = 'v2.0.0' }
    @{ ChangeType = 'Feature'; Expected = 'v1.4.0' }
    @{ ChangeType = 'Fix'; Expected = 'v1.3.5' }
)

foreach ($case in $cases) {
    $actual = & $scriptPath -ChangeType $case.ChangeType -CurrentVersion 'v1.3.4'
    if ($actual -ne $case.Expected) {
        throw "$($case.ChangeType) 升版錯誤：預期 $($case.Expected)，實際 $actual"
    }
}

$invalidVersionFailed = $false
try {
    & $scriptPath -ChangeType Fix -CurrentVersion 'v1.03.4'
} catch {
    $invalidVersionFailed = $true
}

if (-not $invalidVersionFailed) {
    throw '不合法的版本格式未被拒絕。'
}

$buildRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-versioned-build-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $buildRoot 'CodexSettings-Setup-v1.0.0.cmd') -Value 'stale installer'
    Set-Content -LiteralPath (Join-Path $buildRoot 'keep.txt') -Value 'unrelated file'
    & (Join-Path (Split-Path -Parent $scriptPath) 'build-installer.ps1') -Version 'v9.8.7' -OutputDirectory $buildRoot
    $versionedInstaller = Join-Path $buildRoot 'CodexSettings-Setup-v9.8.7.cmd'
    if (-not (Test-Path -LiteralPath $versionedInstaller -PathType Leaf)) {
        throw '建置結果沒有使用版本化檔名。'
    }
    if (Test-Path -LiteralPath (Join-Path $buildRoot 'CodexSettings-Setup.cmd')) {
        throw '建置結果仍包含無版本檔名。'
    }
    if (Test-Path -LiteralPath (Join-Path $buildRoot 'CodexSettings-Setup-v1.0.0.cmd')) {
        throw '建置結果仍保留舊版本安裝器。'
    }
    if (@(Get-ChildItem -LiteralPath $buildRoot -Filter 'CodexSettings-Setup-v*.cmd' -File).Count -ne 1) {
        throw '輸出目錄並非只有一個版本化安裝器。'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $buildRoot 'keep.txt') -PathType Leaf)) {
        throw '建置時誤刪除非安裝器檔案。'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'cmd.exe'
    foreach ($argument in @('/d', '/c', $versionedInstaller)) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.WorkingDirectory = $buildRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.WriteLine('0')
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "單檔安裝器啟動失敗：$($process.ExitCode)`n$stderr" }
    if ($stdout -notmatch 'Codex Settings 一鍵安裝器') { throw '單檔安裝器未載入完整安裝架構。' }
    if (($stdout + $stderr) -match "`e\[33|(?im)^WARNING:|警告") { throw '單檔安裝器啟動時輸出異常黃色警告。' }
} finally {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Release version tests passed.'
