$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('issue72-repro-' + [guid]::NewGuid().ToString('N'))

function Test-NotificationDeliveryContract($Diagnostic, [int]$ExitCode, [string]$Stdout, [long]$TotalElapsedMs, [long]$DiagnosticCompletedMs) {
    $postDiagnosticExitDelayMs = [Math]::Max(0, $TotalElapsedMs - $DiagnosticCompletedMs)
    $deliveryShown = ([bool]$Diagnostic.nativeToastShown -and $Diagnostic.resultReason -eq 'shown-native') -or ([bool]$Diagnostic.fallbackShown -and $Diagnostic.resultReason -eq 'shown-fallback')
    return [pscustomobject]@{
        Passed = $ExitCode -eq 0 -and $Stdout -eq '{}' -and $Diagnostic.result -eq 'success' -and $Diagnostic.claimState -eq 'shown' -and $deliveryShown -and $postDiagnosticExitDelayMs -lt 2000 -and $TotalElapsedMs -lt 30000
        TotalElapsedMs = $TotalElapsedMs
        DiagnosticCompletedMs = $DiagnosticCompletedMs
        PostDiagnosticExitDelayMs = $postDiagnosticExitDelayMs
    }
}

function Assert-DeliveryContractCase([string]$Name, $Diagnostic, [int]$ExitCode, [string]$Stdout, [long]$TotalElapsedMs, [long]$DiagnosticCompletedMs, [bool]$Expected) {
    $actual = Test-NotificationDeliveryContract -Diagnostic $Diagnostic -ExitCode $ExitCode -Stdout $Stdout -TotalElapsedMs $TotalElapsedMs -DiagnosticCompletedMs $DiagnosticCompletedMs
    if ([bool]$actual.Passed -ne $Expected) { throw "Notification delivery contract case failed: $Name" }
}

$nativeSuccess = [pscustomobject]@{ result = 'success'; claimState = 'shown'; resultReason = 'shown-native'; nativeToastShown = $true; fallbackShown = $false }
$fallbackSuccess = [pscustomobject]@{ result = 'success'; claimState = 'shown'; resultReason = 'shown-fallback'; nativeToastShown = $false; fallbackShown = $true }
Assert-DeliveryContractCase 'native cold start' $nativeSuccess 0 '{}' 9500 9000 $true
Assert-DeliveryContractCase 'fallback cold start' $fallbackSuccess 0 '{}' 9500 9000 $true
Assert-DeliveryContractCase 'post-diagnostic foreground wait' $nativeSuccess 0 '{}' 12000 9000 $false
Assert-DeliveryContractCase 'total runtime guard' $nativeSuccess 0 '{}' 30000 29500 $false
Assert-DeliveryContractCase 'delivery failure' ([pscustomobject]@{ result = 'delivery-failed'; claimState = 'failed'; resultReason = 'fallback-failed'; nativeToastShown = $false; fallbackShown = $false }) 0 '{}' 1000 800 $false
Assert-DeliveryContractCase 'invalid stdout' $nativeSuccess 0 'unexpected' 1000 800 $false
Assert-DeliveryContractCase 'diagnostic failure' ([pscustomobject]@{ result = 'error'; claimState = 'shown'; resultReason = 'shown-native'; nativeToastShown = $true; fallbackShown = $false }) 0 '{}' 1000 800 $false
Assert-DeliveryContractCase 'claim not shown' ([pscustomobject]@{ result = 'success'; claimState = 'showing'; resultReason = 'shown-native'; nativeToastShown = $true; fallbackShown = $false }) 0 '{}' 1000 800 $false
Assert-DeliveryContractCase 'observed GitHub cold start' $nativeSuccess 0 '{}' 8672 8200 $true

$releaseWorkflow = [IO.File]::ReadAllText((Join-Path $repositoryRoot '.github\workflows\release.yml'))
if ($releaseWorkflow -match "nonBlocking\s*=.*notification-delivery\.tests\.ps1") { throw 'Notification delivery regression test must remain release-blocking.' }
$validateIndex = $releaseWorkflow.IndexOf('- name: Validate installer', [StringComparison]::Ordinal)
$buildIndex = $releaseWorkflow.IndexOf('- name: Build single-file installer', [StringComparison]::Ordinal)
$smokeIndex = $releaseWorkflow.IndexOf('- name: Smoke test built installer', [StringComparison]::Ordinal)
$publishIndex = $releaseWorkflow.IndexOf('- name: Publish installer', [StringComparison]::Ordinal)
if ($validateIndex -lt 0 -or $buildIndex -le $validateIndex -or $smokeIndex -le $buildIndex -or $publishIndex -le $smokeIndex) { throw 'Release build, Windows smoke test, and publish steps must follow blocking installer validation in order.' }

try {
    New-Item -ItemType Directory -Path (Join-Path $testRoot 'hooks'), (Join-Path $testRoot 'notification'), (Join-Path $testRoot 'token'), (Join-Path $testRoot 'logs'), (Join-Path $testRoot 'invocations') -Force | Out-Null
    Copy-Item (Join-Path $repositoryRoot 'src\templates\core\hooks\runtime-core.ps1') (Join-Path $testRoot 'hooks\runtime-core.ps1')
    $source = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'src\templates\core\hooks\show-codex-notification.ps1'))
    $source = $source.Replace('$script:ToastLifetimeSeconds = 60', '$script:ToastLifetimeSeconds = 3').Replace('$script:PreviousToastLifetimeSeconds = 60', '$script:PreviousToastLifetimeSeconds = 3')
    [IO.File]::WriteAllText((Join-Path $testRoot 'hooks\show-codex-notification.ps1'), $source, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $testRoot 'token\settings.json'), '{"enabled":false,"showAfterEachTurn":false,"mainSessionOnly":true}', [Text.UTF8Encoding]::new($false))

    $env:CODEX_SETTINGS_NOTIFICATION_STATE_ROOT = Join-Path $testRoot 'notification'
    $env:CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT = Join-Path $testRoot 'token'
    $env:CODEX_SETTINGS_HOOK_LOG_ROOT = Join-Path $testRoot 'logs'
    $env:CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT = Join-Path $testRoot 'invocations'

    $diagnosticPath = Join-Path $testRoot 'logs\notification-test.log'
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', (Join-Path $testRoot 'hooks\show-codex-notification.ps1'), '-Type', 'Completed', '-Test')) { [void]$startInfo.ArgumentList.Add($argument) }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $diagnosticCompletedMs = $null
    while (-not $process.WaitForExit(10)) {
        if ($null -eq $diagnosticCompletedMs -and (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) -and (Get-Item -LiteralPath $diagnosticPath).Length -gt 0) { $diagnosticCompletedMs = [long]$stopwatch.ElapsedMilliseconds }
    }
    $stopwatch.Stop()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    if ($null -eq $diagnosticCompletedMs -and (Test-Path -LiteralPath $diagnosticPath -PathType Leaf)) { $diagnosticCompletedMs = [long]$stopwatch.ElapsedMilliseconds }
    $diagnostic = Get-Content $diagnosticPath | Select-Object -Last 1 | ConvertFrom-Json
    $contract = Test-NotificationDeliveryContract -Diagnostic $diagnostic -ExitCode $process.ExitCode -Stdout $stdout -TotalElapsedMs $stopwatch.ElapsedMilliseconds -DiagnosticCompletedMs $diagnosticCompletedMs
    [pscustomobject]@{ Verdict = if ($contract.Passed) { 'PASS' } else { 'FAIL' }; TotalElapsedMs = $contract.TotalElapsedMs; DiagnosticCompletedMs = $contract.DiagnosticCompletedMs; PostDiagnosticExitDelayMs = $contract.PostDiagnosticExitDelayMs; ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr; DiagnosticResult = $diagnostic.result; ClaimState = $diagnostic.claimState; NativeToastShown = $diagnostic.nativeToastShown; FallbackShown = $diagnostic.fallbackShown; Details = [regex]::Replace([string]$diagnostic.details, '[\r\n]+', ' ') } | Format-List
    if (-not $contract.Passed) { exit 1 }
    Write-Host 'Windows notification delivery regression test passed.'
} finally {
    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_STATE_ROOT, Env:\CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT, Env:\CODEX_SETTINGS_HOOK_LOG_ROOT, Env:\CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
