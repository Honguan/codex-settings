$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitAgentsPath = Join-Path $repositoryRoot 'src\templates\environments\git\AGENTS.md'
$readmePath = Join-Path $repositoryRoot 'README.md'
$workflowPaths = @(
    (Join-Path $repositoryRoot '.github\workflows\pull-request-validation.yml'),
    (Join-Path $repositoryRoot '.github\workflows\main-validation.yml'),
    (Join-Path $repositoryRoot '.github\workflows\issue-close-guard.yml'),
    (Join-Path $repositoryRoot '.github\workflows\release.yml')
)

if (-not (Test-Path -LiteralPath $gitAgentsPath -PathType Leaf)) { throw 'Git Issue workflow template is missing.' }
if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) { throw 'README Issue workflow documentation is missing.' }
foreach ($workflowPath in $workflowPaths) {
    if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) { throw "Issue workflow is missing: $workflowPath" }
}

$gitAgents = Get-Content -LiteralPath $gitAgentsPath -Raw
$readme = Get-Content -LiteralPath $readmePath -Raw
$pullRequestWorkflow = Get-Content -LiteralPath $workflowPaths[0] -Raw
$mainWorkflow = Get-Content -LiteralPath $workflowPaths[1] -Raw
$closeGuardWorkflow = Get-Content -LiteralPath $workflowPaths[2] -Raw
$releaseWorkflow = Get-Content -LiteralPath $workflowPaths[3] -Raw

foreach ($expected in @(
    'git pull --ff-only origin main',
    'issue/<issue-number>-<short-description>',
    'Never modify or commit an Issue fix directly on `main`',
    'Refs #<issue-number>',
    'Main verification',
    'Close the Issue only after'
)) {
    if ($gitAgents -notmatch [regex]::Escape($expected)) { throw "Git Issue workflow rule is missing: $expected" }
}

foreach ($expected in @(
    'Issue 修正與主分支驗證',
    'pull-request-validation.yml',
    'main-validation.yml',
    'issue-close-guard.yml',
    '完整測試只在發佈新版時執行'
)) {
    if ($readme -notmatch [regex]::Escape($expected)) { throw "README Issue workflow documentation is missing: $expected" }
}

foreach ($expected in @(
    'pull_request:',
    'issue/<issue-number>-<short-description>',
    'Refs #',
    'main',
    'issues: read'
)) {
    if ($pullRequestWorkflow -notmatch [regex]::Escape($expected)) { throw "PR validation workflow is missing: $expected" }
}
if ($pullRequestWorkflow -match '(?i)PR body.*(?:Fixes|Closes|Resolves)') { throw 'PR validation workflow permits automatic Issue closure in the PR body.' }
if ($pullRequestWorkflow -match 'Get-ChildItem ./tests/\*\.tests\.ps1|workflow_dispatch') { throw 'PR workflow must only validate Issue metadata.' }

foreach ($expected in @(
    'push:',
    'branches:',
    'commits/',
    'merged PR targeting main'
)) {
    if ($mainWorkflow -notmatch [regex]::Escape($expected)) { throw "Main validation workflow is missing: $expected" }
}
if ($mainWorkflow -match 'Get-ChildItem ./tests/\*\.tests\.ps1|workflow_dispatch') { throw 'Main workflow must only verify merged PR provenance.' }

foreach ($expected in @(
    'issues:',
    '- closed',
    'issues: write',
    'state=open',
    'main-validation.yml',
    'Merge commit'
)) {
    if ($closeGuardWorkflow -notmatch [regex]::Escape($expected)) { throw "Issue close guard is missing: $expected" }
}

foreach ($expected in @(
    "tags:",
    "- 'v*'",
    'git merge-base --is-ancestor',
    'Get-ChildItem ./tests/*.tests.ps1',
    'build-installer.ps1',
    'gh release create'
)) {
    if ($releaseWorkflow -notmatch [regex]::Escape($expected)) { throw "Release validation workflow is missing: $expected" }
}

Write-Host 'Issue workflow tests passed.'
