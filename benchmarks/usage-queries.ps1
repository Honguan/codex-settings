[CmdletBinding()]
param(
    [int[]]$SessionCounts = @(50, 500, 2000),
    [ValidateRange(1, 20)][int]$ColdRuns = 5,
    [ValidateRange(1, 100)][int]$WarmRuns = 20,
    [string]$BaselineRef = 'main',
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$usageTemplatePath = Join-Path $repositoryRoot 'src\templates\profile\usage-commands.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-usage-benchmark-' + [guid]::NewGuid().ToString('N'))
$runnerPath = Join-Path $testRoot 'runner.ps1'
$currentTemplatePath = Join-Path $testRoot 'usage-current.ps1'
$baselineTemplatePath = Join-Path $testRoot 'usage-baseline.ps1'

function Get-Percentile([double[]]$Values, [double]$Percent) {
    $items = @($Values | Sort-Object)
    if ($items.Count -eq 0) { return 0.0 }
    $index = [int][Math]::Ceiling($items.Count * $Percent) - 1
    $index = [Math]::Max(0, [Math]::Min($index, $items.Count - 1))
    return [double]$items[$index]
}

function Get-Improvement([double]$Before, [double]$After) {
    if ($Before -eq 0) { return 0.0 }
    return [Math]::Round((($Before - $After) / $Before) * 100, 1)
}

function Write-BenchmarkRunner {
    $runner = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProfilePath,
    [Parameter(Mandatory = $true)][string]$FixturePath,
    [Parameter(Mandatory = $true)][string]$DailyFixturePath,
    [Parameter(Mandatory = $true)][string]$CasesJson,
    [ValidateRange(1, 100)][int]$WarmRuns = 1,
    [switch]$CollectProfile,
    [Parameter(Mandatory = $true)][string]$ProfileLog
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'SilentlyContinue'
if ($CollectProfile) {
    $env:CODEX_SETTINGS_USAGE_PROFILE = '1'
    $env:CODEX_SETTINGS_USAGE_PROFILE_LOG = $ProfileLog
} else {
    Remove-Item Env:\CODEX_SETTINGS_USAGE_PROFILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_USAGE_PROFILE_LOG -ErrorAction SilentlyContinue
}
. $ProfilePath

function global:ccusage {
    $global:LASTEXITCODE = 0
    if ($args -contains 'daily') {
        Get-Content -LiteralPath $DailyFixturePath -Raw
    } else {
        Get-Content -LiteralPath $FixturePath -Raw
    }
}

function Invoke-BenchmarkQuery($Case) {
    if ($Case.Mode -eq 'ccsessions') {
        if ([bool]$Case.Json) {
            & ccsessions -Json $Case.Query 6>$null | Out-Null
        } else {
            & ccsessions $Case.Query 6>$null | Out-Null
        }
    } else {
        & cdaily ([int]$Case.Query) 6>$null
    }
}

$cases = @($CasesJson | ConvertFrom-Json)
foreach ($case in $cases) {
    for ($index = 0; $index -lt $WarmRuns; $index++) {
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-BenchmarkQuery $case
        $stopwatch.Stop()
        Write-Output ("{0}`t{1}" -f $case.Name, $stopwatch.Elapsed.TotalMilliseconds.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))
    }
}
'@
    [IO.File]::WriteAllText($runnerPath, $runner, [Text.UTF8Encoding]::new($false))
}

function Get-BaselineTemplate {
    $refSpec = '{0}:src/templates/profile/usage-commands.ps1' -f $BaselineRef
    $content = (& git.exe show $refSpec 2>&1) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($content)) {
        throw "Unable to read benchmark baseline: $refSpec`n$content"
    }
    return $content
}

function New-Fixture([int]$SessionCount, [string]$Directory) {
    $sessions = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 1; $index -le $SessionCount; $index++) {
        $id = '{0:D8}-0000-4000-8000-{0:D12}' -f $index
        [void]$sessions.Add([ordered]@{
            sessionId = $id
            lastActivity = [DateTimeOffset]::UtcNow.AddMinutes(-$index).ToString('o')
            models = [ordered]@{ 'gpt-5.6-sol' = @{} }
            inputTokens = $index * 10
            outputTokens = $index * 5
            reasoningOutputTokens = $index
            cacheReadTokens = $index * 2
            totalTokens = $index * 18
            costUSD = [decimal]$index / 100
        })
    }

    $daily = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 0; $index -lt 365; $index++) {
        [void]$daily.Add([ordered]@{
            date = (Get-Date).Date.AddDays(-$index).ToString('yyyy-MM-dd')
            models = [ordered]@{ 'gpt-5.6-sol' = @{} }
            inputTokens = $index * 10
            outputTokens = $index * 5
            reasoningOutputTokens = $index
            cacheReadTokens = $index * 2
            totalTokens = $index * 18
            costUSD = [decimal]$index / 100
        })
    }

    $sessionPath = Join-Path $Directory ("sessions-{0}.json" -f $SessionCount)
    $dailyPath = Join-Path $Directory ("daily-{0}.json" -f $SessionCount)
    [IO.File]::WriteAllText($sessionPath, ([ordered]@{ sessions = @($sessions.ToArray()) } | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($dailyPath, ([ordered]@{ daily = @($daily.ToArray()); totals = $null } | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        SessionPath = $sessionPath
        DailyPath = $dailyPath
        FullSessionId = [string]$sessions[0].sessionId
        PartialSessionId = ([string]$sessions[0].sessionId).Substring(0, 8)
    }
}

function Invoke-Runner(
    [string]$ProfilePath,
    [string]$FixturePath,
    [string]$DailyFixturePath,
    [string]$CasesJson,
    [int]$Runs,
    [bool]$CollectProfile,
    [string]$ProfileLog
) {
    if ($CollectProfile -and (Test-Path -LiteralPath $ProfileLog)) { Remove-Item -LiteralPath $ProfileLog -Force }
    $runnerArguments = @(
        '-ProfilePath', $ProfilePath,
        '-FixturePath', $FixturePath,
        '-DailyFixturePath', $DailyFixturePath,
        '-CasesJson', $CasesJson,
        '-WarmRuns', [string]$Runs,
        "-CollectProfile:$CollectProfile",
        '-ProfileLog', $ProfileLog
    )
    $output = @(
        & pwsh -NoLogo -NoProfile -File $runnerPath @runnerArguments
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Benchmark runner failed.`n$($output -join [Environment]::NewLine)"
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $output) {
        $parts = ([string]$line) -split "`t", 2
        if ($parts.Count -ne 2) { throw "Unexpected benchmark runner output: $line" }
        [void]$rows.Add([pscustomobject]@{
            Name = $parts[0]
            Milliseconds = [double]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
        })
    }
    return $rows.ToArray()
}

function Measure-Variant(
    [string]$Label,
    [string]$ProfilePath,
    [object]$Fixture,
    [object[]]$Cases
) {
    $measurements = @{}
    foreach ($case in $Cases) {
        $measurements[$case.Name] = [pscustomobject]@{
            Cold = New-Object 'System.Collections.Generic.List[double]'
            Warm = New-Object 'System.Collections.Generic.List[double]'
            Profiles = New-Object 'System.Collections.Generic.List[object]'
        }
    }
    $casesJson = $Cases | ConvertTo-Json -Depth 4 -Compress

    for ($index = 1; $index -le $ColdRuns; $index++) {
        $logPath = Join-Path $testRoot ("{0}-cold-{1}.jsonl" -f $Label, $index)
        $rows = Invoke-Runner -ProfilePath $ProfilePath -FixturePath $Fixture.SessionPath -DailyFixturePath $Fixture.DailyPath -CasesJson $casesJson -Runs 1 -CollectProfile $false -ProfileLog $logPath
        foreach ($row in $rows) {
            [void]$measurements[$row.Name].Cold.Add($row.Milliseconds)
        }
    }

    $warmLogPath = Join-Path $testRoot ("{0}-warm.jsonl" -f $Label)
    $warmRows = Invoke-Runner -ProfilePath $ProfilePath -FixturePath $Fixture.SessionPath -DailyFixturePath $Fixture.DailyPath -CasesJson $casesJson -Runs $WarmRuns -CollectProfile $false -ProfileLog $warmLogPath
    foreach ($row in $warmRows) {
        [void]$measurements[$row.Name].Warm.Add($row.Milliseconds)
    }

    $profileLogPath = Join-Path $testRoot ("{0}-profile.jsonl" -f $Label)
    [void](Invoke-Runner -ProfilePath $ProfilePath -FixturePath $Fixture.SessionPath -DailyFixturePath $Fixture.DailyPath -CasesJson $casesJson -Runs 1 -CollectProfile $true -ProfileLog $profileLogPath)
    if (Test-Path -LiteralPath $profileLogPath) {
        $profileLines = @(Get-Content -LiteralPath $profileLogPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        for ($index = 0; $index -lt [Math]::Min($profileLines.Count, $Cases.Count); $index++) {
            [void]$measurements[$Cases[$index].Name].Profiles.Add(($profileLines[$index] | ConvertFrom-Json))
        }
    }

    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($case in $Cases) {
        $measurement = $measurements[$case.Name]
        $profileSummary = [ordered]@{}
        foreach ($field in @('backendResolveMs', 'ccusageMs', 'stdoutParseMs', 'jsonParseMs', 'normalizeMs', 'filterMs', 'sortMs', 'renderMs', 'totalMs')) {
            $values = @($measurement.Profiles.ToArray() | ForEach-Object { if ($_.PSObject.Properties.Name -contains $field) { [double]$_.$field } })
            $profileSummary[$field + 'P50'] = Get-Percentile -Values $values -Percent 0.50
            $profileSummary[$field + 'P95'] = Get-Percentile -Values $values -Percent 0.95
        }
        [void]$results.Add([pscustomobject]@{
            Label = $Label
            Name = $case.Name
            ColdP50 = Get-Percentile -Values $measurement.Cold.ToArray() -Percent 0.50
            ColdP95 = Get-Percentile -Values $measurement.Cold.ToArray() -Percent 0.95
            WarmP50 = Get-Percentile -Values $measurement.Warm.ToArray() -Percent 0.50
            WarmP95 = Get-Percentile -Values $measurement.Warm.ToArray() -Percent 0.95
            Profile = [pscustomobject]$profileSummary
        })
    }
    return $results.ToArray()
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Write-BenchmarkRunner
    [IO.File]::WriteAllText($currentTemplatePath, [IO.File]::ReadAllText($usageTemplatePath), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($baselineTemplatePath, (Get-BaselineTemplate), [Text.UTF8Encoding]::new($false))

    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($sessionCount in $SessionCounts) {
        $fixture = New-Fixture -SessionCount $sessionCount -Directory $testRoot
        $cases = @(
            [pscustomobject]@{ Name = 'ccsessions-1'; Mode = 'ccsessions'; Query = '1'; Json = $false },
            [pscustomobject]@{ Name = 'ccsessions-10'; Mode = 'ccsessions'; Query = '10'; Json = $false },
            [pscustomobject]@{ Name = 'ccsessions-100'; Mode = 'ccsessions'; Query = '100'; Json = $false },
            [pscustomobject]@{ Name = 'ccsessions-full'; Mode = 'ccsessions'; Query = $fixture.FullSessionId; Json = $false },
            [pscustomobject]@{ Name = 'ccsessions-partial'; Mode = 'ccsessions'; Query = $fixture.PartialSessionId; Json = $false },
            [pscustomobject]@{ Name = 'ccsessions-json'; Mode = 'ccsessions'; Query = $fixture.FullSessionId; Json = $true },
            [pscustomobject]@{ Name = 'cdaily-1'; Mode = 'cdaily'; Query = '1'; Json = $false },
            [pscustomobject]@{ Name = 'cdaily-7'; Mode = 'cdaily'; Query = '7'; Json = $false },
            [pscustomobject]@{ Name = 'cdaily-30'; Mode = 'cdaily'; Query = '30'; Json = $false },
            [pscustomobject]@{ Name = 'cdaily-365'; Mode = 'cdaily'; Query = '365'; Json = $false }
        )

        Write-Host ("Benchmarking {0} sessions ({1} cases)" -f $sessionCount, $cases.Count)
        $beforeResults = @(Measure-Variant -Label 'before' -ProfilePath $baselineTemplatePath -Fixture $fixture -Cases $cases)
        $afterResults = @(Measure-Variant -Label 'after' -ProfilePath $currentTemplatePath -Fixture $fixture -Cases $cases)
        foreach ($case in $cases) {
            $before = @($beforeResults | Where-Object Name -eq $case.Name)[0]
            $after = @($afterResults | Where-Object Name -eq $case.Name)[0]
            [void]$results.Add([pscustomobject]@{
                Sessions = $sessionCount
                Scenario = $case.Name
                Before = $before
                After = $after
                WarmP50ImprovementPercent = Get-Improvement -Before $before.WarmP50 -After $after.WarmP50
                WarmP95ImprovementPercent = Get-Improvement -Before $before.WarmP95 -After $after.WarmP95
            })
        }
    }

    Write-Host ''
    Write-Host 'Scenario                                  Before p50  After p50  Improve  Before p95  After p95  Improve'
    Write-Host '---------------------------------------------------------------------------------------------------------'
    foreach ($result in $results) {
        Write-Host ('{0,-42} {1,10:N1} {2,10:N1} {3,7:N1}% {4,11:N1} {5,10:N1} {6,7:N1}%' -f `
            ("{0}/{1}" -f $result.Sessions, $result.Scenario),
            $result.Before.WarmP50,
            $result.After.WarmP50,
            $result.WarmP50ImprovementPercent,
            $result.Before.WarmP95,
            $result.After.WarmP95,
            $result.WarmP95ImprovementPercent)
    }
    $summary = [pscustomobject]@{
        BaselineRef = $BaselineRef
        ColdRuns = $ColdRuns
        WarmRuns = $WarmRuns
        Results = @($results.ToArray())
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $outputAbsolutePath = [IO.Path]::GetFullPath($OutputPath)
        [IO.File]::WriteAllText($outputAbsolutePath, ($summary | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        Write-Host "Benchmark JSON: $outputAbsolutePath"
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
