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
    & (Join-Path (Split-Path -Parent $scriptPath) 'build-installer.ps1') -Version 'v9.8.7' -OutputDirectory $buildRoot
    $versionedInstaller = Join-Path $buildRoot 'CodexSettings-Setup-v9.8.7.cmd'
    if (-not (Test-Path -LiteralPath $versionedInstaller -PathType Leaf)) {
        throw '建置結果沒有使用版本化檔名。'
    }
    if (Test-Path -LiteralPath (Join-Path $buildRoot 'CodexSettings-Setup.cmd')) {
        throw '建置結果仍包含無版本檔名。'
    }
} finally {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Release version tests passed.'
