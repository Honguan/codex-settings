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

Write-Host 'Release version tests passed.'
