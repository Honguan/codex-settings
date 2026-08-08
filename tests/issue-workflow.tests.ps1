$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitAgentsPath = Join-Path $repositoryRoot 'src\templates\environments\git\AGENTS.md'
$readmePath = Join-Path $repositoryRoot 'README.md'
$workflowRoot = Join-Path $repositoryRoot '.github\workflows'
$workflowFiles = [ordered]@{
    pullRequest = Join-Path $workflowRoot 'pull-request-validation.yml'
    main = Join-Path $workflowRoot 'main-validation.yml'
    closeGuard = Join-Path $workflowRoot 'issue-close-guard.yml'
    release = Join-Path $workflowRoot 'release.yml'
    changedArea = Join-Path $workflowRoot 'changed-area-regression.yml'
}

function Assert-Contains([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch [regex]::Escape($Pattern)) { throw $Message }
}

function Assert-NotContains([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -match [regex]::Escape($Pattern)) { throw $Message }
}

if (-not (Test-Path -LiteralPath $gitAgentsPath -PathType Leaf)) { throw 'Git Issue workflow template is missing.' }
if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) { throw 'README Issue workflow documentation is missing.' }
foreach ($workflowPath in $workflowFiles.Values) {
    if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) { throw "Issue workflow is missing: $workflowPath" }
}

$gitAgents = Get-Content -LiteralPath $gitAgentsPath -Raw
$readme = Get-Content -LiteralPath $readmePath -Raw
$pullRequestWorkflow = Get-Content -LiteralPath $workflowFiles.pullRequest -Raw
$mainWorkflow = Get-Content -LiteralPath $workflowFiles.main -Raw
$closeGuardWorkflow = Get-Content -LiteralPath $workflowFiles.closeGuard -Raw
$releaseWorkflow = Get-Content -LiteralPath $workflowFiles.release -Raw
$changedAreaWorkflow = Get-Content -LiteralPath $workflowFiles.changedArea -Raw

foreach ($expected in @(
    'git pull --ff-only origin main',
    'issue/<issue-number>-<short-description>',
    'Never modify or commit an Issue fix directly on `main`',
    'Refs #<issue-number>',
    'Main verification',
    'Close the Issue only after',
    'PR title must contain the Issue number'
)) {
    Assert-Contains $gitAgents $expected "Git Issue workflow rule is missing: $expected"
}

foreach ($expected in @(
    'Issue 修正與主分支驗證',
    'pull-request-validation.yml',
    'main-validation.yml',
    'issue-close-guard.yml',
    'codex-settings-main-verification:v1',
    'changed-area-regression.yml',
    'release-blocking'
)) {
    Assert-Contains $readme $expected "README Issue workflow documentation is missing: $expected"
}

foreach ($expected in @(
    'pull_request:',
    'concurrency:',
    'cancel-in-progress: true',
    'runs-on: ubuntu-latest',
    'timeout-minutes: 3',
    'issue/<issue-number>-<short-description>',
    'Refs #',
    'PR title',
    'main',
    'issues: read'
)) {
    Assert-Contains $pullRequestWorkflow $expected "PR validation workflow is missing: $expected"
}
Assert-NotContains $pullRequestWorkflow '/commits?per_page=100' 'PR validation still fetches 100 commits.'
Assert-NotContains $pullRequestWorkflow 'windows-latest' 'PR metadata workflow should use the Ubuntu runner.'
Assert-NotContains $pullRequestWorkflow 'Get-ChildItem ./tests/*.tests.ps1' 'PR metadata workflow must not run the full test suite.'
Assert-NotContains $pullRequestWorkflow 'workflow_dispatch' 'PR metadata workflow must remain event-driven.'

foreach ($expected in @(
    'push:',
    'branches:',
    'commits/',
    'merged PR targeting main',
    'no Issue receipt is required for this non-PR maintenance push',
    'codex-settings-main-verification:v1',
    'MainVerification: passed',
    'issues: write',
    'timeout-minutes: 3',
    'ubuntu-latest'
)) {
    Assert-Contains $mainWorkflow $expected "Main validation workflow is missing: $expected"
}
Assert-NotContains $mainWorkflow 'throw "The main commit' 'Main validation must not fail non-PR maintenance pushes.'
Assert-NotContains $mainWorkflow 'gh run list' 'Main validation must not search workflow runs after the receipt is written.'
Assert-NotContains $mainWorkflow 'Get-ChildItem ./tests/*.tests.ps1' 'Main validation must not run the full test suite.'
Assert-NotContains $mainWorkflow 'workflow_dispatch' 'Main validation workflow must remain push-driven.'

foreach ($expected in @(
    'issues:',
    '- closed',
    'issues: write',
    'concurrency:',
    'cancel-in-progress: true',
    'runs-on: ubuntu-latest',
    'timeout-minutes: 3',
    'comments',
    'codex-settings-main-verification:v1',
    'timeline',
    'compare/',
    'state=open'
)) {
    Assert-Contains $closeGuardWorkflow $expected "Issue close guard is missing: $expected"
}
Assert-NotContains $closeGuardWorkflow 'pulls?state=closed&base=main&per_page=100' 'Issue close guard still scans 100 closed PRs.'
Assert-NotContains $closeGuardWorkflow 'gh run list' 'Issue close guard must trust the main-verification receipt.'
Assert-Contains $closeGuardWorkflow 'deferred without reopen' 'Issue close guard does not handle the merge/close receipt race.'

foreach ($expected in @(
    'tags:',
    "- 'v*'",
    'fetch-depth: 1',
    'compare/',
    '$nonBlocking',
    'releaseTests',
    'build-installer.ps1',
    'gh release create'
)) {
    Assert-Contains $releaseWorkflow $expected "Release validation workflow is missing: $expected"
}
Assert-NotContains $releaseWorkflow 'fetch-depth: 0' 'Release workflow still downloads the complete repository history.'
Assert-NotContains $releaseWorkflow 'git merge-base --is-ancestor' 'Release workflow is still coupled to local full-history ancestry checks.'

foreach ($expected in @(
    'paths:',
    '.github/workflows/**',
    'tests/issue-workflow.tests.ps1',
    'runs-on: ubuntu-latest',
    'timeout-minutes: 5',
    'concurrency:'
)) {
    Assert-Contains $changedAreaWorkflow $expected "Changed-area regression workflow is missing: $expected"
}

if ($pullRequestWorkflow -match '(?i)PR body.*(?:Fixes|Closes|Resolves)') { throw 'PR validation workflow permits automatic Issue closure in the PR body.' }
if ($mainWorkflow -match 'git merge-base|Get-ChildItem ./tests/\*\.tests\.ps1') { throw 'Main validation workflow contains a release-only implementation detail.' }
if ($releaseWorkflow -match '(?i)Issue close guard|pull-request-validation') { throw 'Release workflow must not repeat Issue lifecycle checks.' }
if ($closeGuardWorkflow -match 'main-validation\.yml.*gh run list|gh run list.*main-validation\.yml') { throw 'Close guard still polls main-validation runs.' }

Write-Host 'Issue workflow contract tests passed.'
