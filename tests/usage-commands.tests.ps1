[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$profileTemplate = Join-Path $repositoryRoot 'src\templates\profile\usage-commands.ps1'
$source = Get-Content -Raw -LiteralPath $profileTemplate
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-usage-' + [guid]::NewGuid().ToString('N'))
$sessionFixturePath = Join-Path $testRoot 'sessions.json'
$dailyFixturePath = Join-Path $testRoot 'daily.json'
$profileLogPath = Join-Path $testRoot 'profile.jsonl'

try {
    if ($source -notmatch 'Resolve-CodexUsageBackend' -or $source -notmatch 'ConvertFrom-CodexUsageOutput' -or $source -notmatch 'Invoke-CodexUsageJson') {
        throw 'usage commands must use the shared ccusage adapter.'
    }
    if ($source -match 'function Get-Title' -or $source -match 'function Get-SessionPath') {
        throw 'ccsessions must not define the unused title/session-file scan path.'
    }
    if ($source -notmatch 'shouldSort = -not \(\$Json -and \$arguments.Count -eq 1\)') {
        throw 'ccsessions exact JSON mode must use the no-sort fast path.'
    }

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $sessionId = '019fd1f8-4928-7432-9697-8070ae4a87a2'
    $secondSessionId = '019fd1f8-4928-7432-9697-8070ae4a87a3'
    $sessionReport = [ordered]@{
        sessions = @(
            [ordered]@{
                sessionId = $sessionId
                lastActivity = '2026-01-01T00:30:00Z'
                models = [ordered]@{ 'gpt-5.6-sol' = @{} }
                inputTokens = 10
                outputTokens = 20
                reasoningOutputTokens = 3
                cacheReadTokens = 4
                totalTokens = 37
                costUSD = 0.01
            },
            [ordered]@{
                sessionId = $secondSessionId
                lastActivity = '2026-01-02T00:30:00Z'
                models = [ordered]@{ 'gpt-5.6-terra' = @{} }
                inputTokens = 100
                outputTokens = 200
                reasoningOutputTokens = 30
                cacheReadTokens = 40
                totalTokens = 370
                costUSD = 0.10
            }
        )
    }
    $dailyReport = [ordered]@{
        daily = @(
            [ordered]@{
                date = '2026-01-02'
                models = [ordered]@{ 'gpt-5.6-terra' = @{} }
                inputTokens = 100
                outputTokens = 200
                reasoningOutputTokens = 30
                cacheReadTokens = 40
                totalTokens = 370
                costUSD = 0.10
            }
        )
        totals = [ordered]@{
            inputTokens = 100
            outputTokens = 200
            reasoningOutputTokens = 30
            cacheReadTokens = 40
            totalTokens = 370
            costUSD = 0.10
        }
    }
    [IO.File]::WriteAllText($sessionFixturePath, ($sessionReport | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($dailyFixturePath, ($dailyReport | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))

    . $profileTemplate
    $global:UsageBackendCalls = New-Object 'System.Collections.Generic.List[string]'
    function global:ccusage {
        [void]$global:UsageBackendCalls.Add(($args -join ' '))
        $global:LASTEXITCODE = 0
        Write-Output 'ccusage fixture'
        if ($args -contains 'daily') {
            Write-Output (Get-Content -LiteralPath $dailyFixturePath -Raw)
        } else {
            Write-Output (Get-Content -LiteralPath $sessionFixturePath -Raw)
        }
    }

    $listOutput = @(& ccsessions 1 6>&1 | Out-String) -join "`n"
    if ($listOutput -notmatch '019fd1f8\.\.\.4a87a3' -or $listOutput -notmatch '01-02 08:30 AM') {
        throw "ccsessions list output changed: $listOutput"
    }
    if ($global:UsageBackendCalls[0] -notmatch 'codex session --timezone Asia/Taipei --json') {
        throw "global ccusage received unexpected session arguments: $($global:UsageBackendCalls[0])"
    }

    $jsonText = (& ccsessions -Json $sessionId | Out-String).Trim()
    $json = $jsonText | ConvertFrom-Json -ErrorAction Stop
    if (-not [bool]$json.success -or $json.sessionId -ne $sessionId -or $json.totalTokens -ne 37 -or $json.reasoningTokens -ne 3 -or $json.cacheTokens -ne 4) {
        throw "ccsessions exact JSON output changed: $jsonText"
    }
    if ($json.PSObject.Properties.Name -contains 'cachedInputTokens' -or $json.PSObject.Properties.Name -contains 'cacheWriteTokens') {
        throw 'ccsessions JSON schema contains obsolete properties.'
    }

    $dailyOutput = @(& cdaily 7 6>&1 | Out-String) -join "`n"
    if ($dailyOutput -notmatch '2026-01-02' -or $dailyOutput -notmatch '370' -or $global:UsageBackendCalls[-1] -notmatch 'codex daily --last 7 --timezone Asia/Taipei --json') {
        throw "cdaily output or arguments changed: $dailyOutput / $($global:UsageBackendCalls[-1])"
    }

    $env:CODEX_SETTINGS_USAGE_PROFILE = '1'
    $env:CODEX_SETTINGS_USAGE_PROFILE_LOG = $profileLogPath
    [void](& ccsessions -Json $sessionId | Out-String)
    $profile = Get-Content -LiteralPath $profileLogPath -Tail 1 | ConvertFrom-Json
    foreach ($field in @('backendResolveMs', 'processLaunchMs', 'ccusageMs', 'stdoutParseMs', 'jsonParseMs', 'normalizeMs', 'filterMs', 'sortMs', 'renderMs', 'totalMs')) {
        if ($profile.PSObject.Properties.Name -notcontains $field) { throw "usage profiling 缺少欄位：$field" }
    }
    if ([bool]$profile.fallbackUsed) { throw 'global ccusage 不應標記為 fallback。' }

    function global:ccusage {
        [void]$global:UsageBackendCalls.Add('global-failure ' + ($args -join ' '))
        $global:LASTEXITCODE = 1
        Write-Output 'global ccusage unavailable'
    }
    function global:npx {
        [void]$global:UsageBackendCalls.Add('npx-fallback ' + ($args -join ' '))
        $global:LASTEXITCODE = 0
        Write-Output (Get-Content -LiteralPath $sessionFixturePath -Raw)
    }

    $fallbackJsonText = (& ccsessions -Json $sessionId | Out-String).Trim()
    $fallbackJson = $fallbackJsonText | ConvertFrom-Json -ErrorAction Stop
    if (-not [bool]$fallbackJson.success -or $fallbackJson.sessionId -ne $sessionId) {
        throw "npx fallback did not preserve ccsessions JSON: $fallbackJsonText"
    }
    if (-not (@($global:UsageBackendCalls) -match '^npx-fallback ')) {
        throw 'global ccusage failure did not fallback to npx.'
    }
    $fallbackProfile = Get-Content -LiteralPath $profileLogPath -Tail 1 | ConvertFrom-Json
    if (-not [bool]$fallbackProfile.fallbackUsed) { throw 'npx fallback was not recorded in profiling.' }

    Write-Host 'Usage command backend, fast path, schema and profiling tests passed.'
} finally {
    Remove-Item Env:\CODEX_SETTINGS_USAGE_PROFILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_USAGE_PROFILE_LOG -ErrorAction SilentlyContinue
    Remove-Item Function:\ccusage -ErrorAction SilentlyContinue
    Remove-Item Function:\npx -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
