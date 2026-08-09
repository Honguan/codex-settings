$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('issue72-repro-' + [guid]::NewGuid().ToString('N'))

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

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', (Join-Path $testRoot 'hooks\show-codex-notification.ps1'), '-Type', 'Completed', '-Test')) { [void]$startInfo.ArgumentList.Add($argument) }
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $stopwatch.Stop()
    $diagnostic = Get-Content (Join-Path $testRoot 'logs\notification-test.log') | Select-Object -Last 1 | ConvertFrom-Json
    $passed = $process.ExitCode -eq 0 -and $stdout -eq '{}' -and $stopwatch.ElapsedMilliseconds -lt 3000 -and $diagnostic.result -eq 'success' -and $diagnostic.claimState -eq 'shown' -and $diagnostic.resultReason -eq 'shown-native' -and ($diagnostic.nativeToastShown -or $diagnostic.fallbackShown)
    [pscustomobject]@{ Verdict = if ($passed) { 'PASS' } else { 'FAIL' }; ElapsedMs = $stopwatch.ElapsedMilliseconds; ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr; DiagnosticResult = $diagnostic.result; ClaimState = $diagnostic.claimState; NativeToastShown = $diagnostic.nativeToastShown; FallbackShown = $diagnostic.fallbackShown; Details = [regex]::Replace([string]$diagnostic.details, '[\r\n]+', ' ') } | Format-List
    if (-not $passed) { exit 1 }
    Write-Host 'Windows notification delivery regression test passed.'
} finally {
    Remove-Item Env:\CODEX_SETTINGS_NOTIFICATION_STATE_ROOT, Env:\CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT, Env:\CODEX_SETTINGS_HOOK_LOG_ROOT, Env:\CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
