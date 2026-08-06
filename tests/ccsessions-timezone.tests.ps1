[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$profileTemplate = Join-Path $repositoryRoot 'src\templates\profile\usage-commands.ps1'
$source = Get-Content -Raw -LiteralPath $profileTemplate

if ($source -match '\.ToLocalTime\(\)') {
    throw 'ccsessions must not use the computer local time zone.'
}
if ($source -notmatch 'Taipei Standard Time') {
    throw 'ccsessions must explicitly resolve the Taipei time zone.'
}

. $profileTemplate
function global:npx {
    $global:LASTEXITCODE = 0
    '{"sessions":[{"sessionId":"11111111-1111-1111-1111-111111111111","lastActivity":"2026-01-01T00:30:00Z","models":"gpt-5","inputTokens":1,"outputTokens":2,"reasoningOutputTokens":3,"cacheReadTokens":4,"totalTokens":10,"costUSD":0.01}]}'
}

$output = @(& ccsessions 1 6>&1 | Out-String)
if (($output -join "`n") -notmatch '01-01 08:30') {
    throw "ccsessions did not render the Taipei time. Output: $($output -join "`n")"
}

Write-Host 'ccsessions Taipei timezone tests passed.'
