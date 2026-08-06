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
    $global:CcSessionsNpxArguments = @($args)
    '{"sessions":[{"sessionId":"019fd1f8-4928-7432-9697-8070ae4a87a2","lastActivity":"2026-01-01T00:30:00Z","models":{"gpt-5.6-sol":{},"gpt-5.6-terra":{}},"inputTokens":1,"outputTokens":2,"reasoningOutputTokens":3,"cacheReadTokens":4,"cacheCreationTokens":5,"totalTokens":10,"costUSD":0.01}]}'
}

$output = @(& ccsessions 1 6>&1 | Out-String)
$outputText = $output -join "`n"
if ($outputText -notmatch '019fd1f8\.\.\.4a87a2') {
    throw "ccsessions did not render the abbreviated session ID. Output: $outputText"
}
$modelLines = @([regex]::Split($outputText, "`r?`n") | Where-Object { $_ -match 'gpt-5\.6-(sol|terra)' })
if ($modelLines.Count -ne 2 -or $modelLines[0] -notmatch 'gpt-5\.6-sol' -or $modelLines[1] -notmatch 'gpt-5\.6-terra') {
    throw "ccsessions did not render switched models on separate lines. Output: $outputText"
}
if ($outputText -notmatch '01-01 08:30 AM') {
    throw "ccsessions did not render the Taipei time. Output: $($output -join "`n")"
}
if (($global:CcSessionsNpxArguments -join ' ') -notmatch '--timezone Asia/Taipei') {
    throw "ccsessions did not request the Taipei timezone. Arguments: $($global:CcSessionsNpxArguments -join ' ')"
}

$jsonText = (& ccsessions -Json '019fd1f8-4928-7432-9697-8070ae4a87a2' | Out-String).Trim()
$json = $jsonText | ConvertFrom-Json -ErrorAction Stop
if (-not [bool]$json.success -or $json.sessionId -ne '019fd1f8-4928-7432-9697-8070ae4a87a2' -or $json.cachedInputTokens -ne 4 -or $json.cacheWriteTokens -ne 5 -or $json.totalTokens -ne 10 -or @($json.models).Count -ne 2) {
    throw "ccsessions JSON output is invalid: $jsonText"
}

Write-Host 'ccsessions Taipei timezone tests passed.'
