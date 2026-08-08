[CmdletBinding()]
param(
    [string]$HookScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\templates\environments\cvs\hooks\preserve-line-endings.ps1'),
    [string]$BaselineHookScript,
    [string]$BaselineRef,
    [ValidateRange(1, 10000)]
    [int]$TrackedFileCount = 100,
    [ValidateRange(1, 1000)]
    [int]$ReadOnlyCalls = 100
)

$ErrorActionPreference = 'Stop'

function New-BenchmarkProject([string]$Root, [int]$FileCount) {
    New-Item -ItemType Directory -Path (Join-Path $Root 'CVS') -Force | Out-Null
    $entries = [Collections.Generic.List[string]]::new()
    for ($index = 1; $index -le $FileCount; $index++) {
        $name = 'file-{0:D5}.txt' -f $index
        [void]$entries.Add("/$name/1.1///")
        $path = Join-Path $Root $name
        [IO.File]::WriteAllText($path, "benchmark $index`r`n", [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllLines((Join-Path $Root 'CVS\Entries'), $entries.ToArray(), [Text.Encoding]::ASCII)
}

function New-HookInput([string]$Root, [string]$SessionId, [string]$TurnId, [string]$EventName, [string]$ToolName, [string]$Command) {
    return [ordered]@{
        session_id = $SessionId
        turn_id = $TurnId
        cwd = $Root
        hook_event_name = $EventName
        tool_name = $ToolName
        tool_input = [ordered]@{ command = $Command }
    } | ConvertTo-Json -Depth 5 -Compress
}

function Invoke-BenchmarkHook([string]$ScriptPath, [string]$Mode, [string]$InputText, [string]$Root, [string]$StateRoot, [string]$IndexRoot, [string]$LogRoot, [string]$InvocationRoot) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $ScriptPath, '-Mode', $Mode)) { [void]$startInfo.ArgumentList.Add($argument) }
    $startInfo.WorkingDirectory = $Root
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['CODEX_SETTINGS_LINE_ENDING_STATE_ROOT'] = $StateRoot
    $startInfo.Environment['CODEX_SETTINGS_LINE_ENDING_INDEX_ROOT'] = $IndexRoot
    $startInfo.Environment['CODEX_SETTINGS_HOOK_LOG_ROOT'] = $LogRoot
    $startInfo.Environment['CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT'] = $InvocationRoot
    $process = [Diagnostics.Process]::Start($startInfo)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Hook exit code $($process.ExitCode): $stderr" }
        $safeSessionId = [regex]::Replace(([string]($InputText | ConvertFrom-Json).session_id), '[^A-Za-z0-9._-]', '_')
        $diagnosticPath = Join-Path $LogRoot ($safeSessionId + '.log')
        $diagnostic = if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) { @(Get-Content -LiteralPath $diagnosticPath | ForEach-Object { $_ | ConvertFrom-Json })[-1] } else { $null }
        return [pscustomobject]@{ ElapsedMs = $stopwatch.ElapsedMilliseconds; Diagnostic = $diagnostic }
    } finally { $process.Dispose() }
}

function Get-Percentile([long[]]$Values, [double]$Percentile) {
    $ordered = @($Values | Sort-Object)
    if ($ordered.Count -eq 0) { return 0 }
    $position = [int][Math]::Ceiling($ordered.Count * $Percentile) - 1
    return [long]$ordered[[Math]::Max(0, [Math]::Min($ordered.Count - 1, $position))]
}

function New-ResultRow([string]$Scenario, [long[]]$Samples, $Diagnostic) {
    return [pscustomobject][ordered]@{
        Scenario = $Scenario
        P50Ms = Get-Percentile -Values $Samples -Percentile 0.50
        P95Ms = Get-Percentile -Values $Samples -Percentile 0.95
        MaxMs = if (@($Samples).Count -gt 0) { [long](@($Samples | Measure-Object -Maximum).Maximum) } else { 0 }
        FileReadMs = if ($null -ne $Diagnostic) { [long]$Diagnostic.fileReadMs } else { 0 }
        StateFilesChecked = if ($null -ne $Diagnostic) { [long]$Diagnostic.stateFileCountChecked } else { 0 }
        IndexHits = if ($null -ne $Diagnostic) { [long]$Diagnostic.lineEndingIndexHitCount } else { 0 }
    }
}

function Invoke-Benchmark([string]$ScriptPath) {
    $benchmarkRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-hook-benchmark-' + [guid]::NewGuid().ToString('N'))
    $projectRoot = Join-Path $benchmarkRoot 'project'
    $stateRoot = Join-Path $benchmarkRoot 'state'
    $indexRoot = Join-Path $benchmarkRoot 'index'
    $logRoot = Join-Path $benchmarkRoot 'logs'
    $invocationRoot = Join-Path $benchmarkRoot 'invocations'
    New-Item -ItemType Directory -Path $projectRoot, $stateRoot, $indexRoot, $logRoot, $invocationRoot -Force | Out-Null
    try {
        New-BenchmarkProject -Root $projectRoot -FileCount $TrackedFileCount
        $rows = [Collections.Generic.List[object]]::new()
        $cold = Invoke-BenchmarkHook -ScriptPath $ScriptPath -Mode Track -Root $projectRoot -StateRoot $stateRoot -IndexRoot $indexRoot -LogRoot $logRoot -InvocationRoot $invocationRoot -InputText (New-HookInput $projectRoot 'cold-session' 'cold-turn' 'PreToolUse' 'exec' 'const patch = getPatch(); text(await tools.apply_patch(patch));')
        [void]$rows.Add((New-ResultRow -Scenario 'First CVS snapshot' -Samples @($cold.ElapsedMs) -Diagnostic $cold.Diagnostic))

        $warm = Invoke-BenchmarkHook -ScriptPath $ScriptPath -Mode Track -Root $projectRoot -StateRoot $stateRoot -IndexRoot $indexRoot -LogRoot $logRoot -InvocationRoot $invocationRoot -InputText (New-HookInput $projectRoot 'warm-session' 'warm-turn' 'PreToolUse' 'exec' 'const patch = getPatch(); text(await tools.apply_patch(patch));')
        [void]$rows.Add((New-ResultRow -Scenario 'Warm CVS snapshot' -Samples @($warm.ElapsedMs) -Diagnostic $warm.Diagnostic))

        $readOnlySamples = [Collections.Generic.List[long]]::new()
        $readOnlyDiagnostic = $null
        for ($index = 1; $index -le $ReadOnlyCalls; $index++) {
            $result = Invoke-BenchmarkHook -ScriptPath $ScriptPath -Mode Track -Root $projectRoot -StateRoot $stateRoot -IndexRoot $indexRoot -LogRoot $logRoot -InvocationRoot $invocationRoot -InputText (New-HookInput $projectRoot ("read-only-{0}" -f $index) ("turn-{0}" -f $index) 'PreToolUse' 'exec' 'rg --files .')
            [void]$readOnlySamples.Add([long]$result.ElapsedMs)
            $readOnlyDiagnostic = $result.Diagnostic
        }
        [void]$rows.Add((New-ResultRow -Scenario ("Read-only exec ({0})" -f $ReadOnlyCalls) -Samples $readOnlySamples.ToArray() -Diagnostic $readOnlyDiagnostic))

        $patchSession = 'candidate-session'
        $patchInput = New-HookInput $projectRoot $patchSession 'patch-turn' 'PreToolUse' 'exec' 'const patch = getPatch(); text(await tools.apply_patch(patch));'
        Invoke-BenchmarkHook -ScriptPath $ScriptPath -Mode Track -Root $projectRoot -StateRoot $stateRoot -IndexRoot $indexRoot -LogRoot $logRoot -InvocationRoot $invocationRoot -InputText $patchInput | Out-Null
        [IO.File]::WriteAllText((Join-Path $projectRoot 'file-00001.txt'), "changed`n", [Text.UTF8Encoding]::new($false))
        $candidate = Invoke-BenchmarkHook -ScriptPath $ScriptPath -Mode Restore -Root $projectRoot -StateRoot $stateRoot -IndexRoot $indexRoot -LogRoot $logRoot -InvocationRoot $invocationRoot -InputText (New-HookInput $projectRoot $patchSession 'patch-turn' 'PostToolUse' 'apply_patch' '*** Update File: file-00001.txt')
        [void]$rows.Add((New-ResultRow -Scenario 'Single patch Restore' -Samples @($candidate.ElapsedMs) -Diagnostic $candidate.Diagnostic))

        $fallbackSession = 'fallback-session'
        Invoke-BenchmarkHook -ScriptPath $ScriptPath -Mode Track -Root $projectRoot -StateRoot $stateRoot -IndexRoot $indexRoot -LogRoot $logRoot -InvocationRoot $invocationRoot -InputText (New-HookInput $projectRoot $fallbackSession 'fallback-turn' 'PreToolUse' 'exec' 'const patch = getPatch(); text(await tools.apply_patch(patch));') | Out-Null
        [IO.File]::WriteAllText((Join-Path $projectRoot 'file-00001.txt'), "fallback`n", [Text.UTF8Encoding]::new($false))
        $fallback = Invoke-BenchmarkHook -ScriptPath $ScriptPath -Mode Restore -Root $projectRoot -StateRoot $stateRoot -IndexRoot $indexRoot -LogRoot $logRoot -InvocationRoot $invocationRoot -InputText (New-HookInput $projectRoot $fallbackSession 'fallback-turn' 'PostToolUse' 'exec' 'unknown write command')
        [void]$rows.Add((New-ResultRow -Scenario 'Unknown command fallback Restore' -Samples @($fallback.ElapsedMs) -Diagnostic $fallback.Diagnostic))
        return $rows.ToArray()
    } finally { Remove-Item -LiteralPath $benchmarkRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

function Show-Results([string]$Label, [object[]]$Rows) {
    Write-Host "[$Label]"
    $Rows | Format-Table Scenario, P50Ms, P95Ms, MaxMs, FileReadMs, StateFilesChecked, IndexHits -AutoSize | Out-String | Write-Host
}

if (-not (Test-Path -LiteralPath $HookScript -PathType Leaf)) { throw "找不到 Hook 腳本：$HookScript" }
$temporaryBaselinePath = $null
try {
    if (-not [string]::IsNullOrWhiteSpace($BaselineRef)) {
        $temporaryBaselinePath = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-baseline-hook-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $baselineContent = (& git show ("{0}:src/templates/environments/cvs/hooks/preserve-line-endings.ps1" -f $BaselineRef) | Out-String)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($baselineContent)) { throw "無法讀取 baseline ref：$BaselineRef" }
        [IO.File]::WriteAllText($temporaryBaselinePath, $baselineContent, [Text.UTF8Encoding]::new($false))
        $BaselineHookScript = $temporaryBaselinePath
    }

    $currentRows = @(Invoke-Benchmark -ScriptPath $HookScript)
    Show-Results -Label 'Current' -Rows $currentRows

    if (-not [string]::IsNullOrWhiteSpace($BaselineHookScript)) {
        if (-not (Test-Path -LiteralPath $BaselineHookScript -PathType Leaf)) { throw "找不到 baseline Hook 腳本：$BaselineHookScript" }
        $baselineRows = @(Invoke-Benchmark -ScriptPath $BaselineHookScript)
        Show-Results -Label 'Baseline' -Rows $baselineRows
        Write-Host '[Before / After]'
        $comparisonRows = foreach ($current in $currentRows) {
            $baseline = $baselineRows | Where-Object Scenario -eq $current.Scenario | Select-Object -First 1
            $improvement = if ($null -eq $baseline -or [long]$baseline.P50Ms -eq 0) { 0 } else { [Math]::Round((1 - ([double]$current.P50Ms / [double]$baseline.P50Ms)) * 100, 1) }
            [pscustomobject]@{ Scenario = $current.Scenario; BeforeP50Ms = $baseline.P50Ms; AfterP50Ms = $current.P50Ms; ImprovementPercent = $improvement }
        }
        $comparisonRows | Format-Table -AutoSize | Out-String | Write-Host
    }
} finally {
    if ($null -ne $temporaryBaselinePath) { Remove-Item -LiteralPath $temporaryBaselinePath -Force -ErrorAction SilentlyContinue }
}
