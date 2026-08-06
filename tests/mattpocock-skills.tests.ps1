$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$expectedNames = @(
    'setup-matt-pocock-skills', 'grill-with-docs', 'to-spec', 'to-tickets', 'implement',
    'tdd', 'code-review', 'diagnosing-bugs', 'handoff', 'wait-what'
)
$actualNames = @(Get-MattPocockSkillNames)
if ($actualNames.Count -ne 10 -or (Compare-Object $expectedNames $actualNames)) {
    throw "mattpocock/skills default skill list is invalid: $($actualNames -join ', ')"
}
$expectedArguments = @('--yes', 'skills@latest', 'add', 'mattpocock/skills', '-g', '-a', 'codex', '-y')
foreach ($name in $expectedNames) { $expectedArguments += @('--skill', $name) }
$actualArguments = @(Get-MattPocockSkillsArguments)
if (($actualArguments -join "`0") -ne ($expectedArguments -join "`0")) {
    throw "mattpocock/skills command arguments are invalid: $($actualArguments -join ' ')"
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ('codex-settings-mattpocock-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    if (Test-MattPocockSkillsInstalled -AgentsRoot $testRoot) {
        throw 'Missing mattpocock/skills installation was detected as installed.'
    }

    $lock = [ordered]@{
        version = 3
        skills = [ordered]@{
            'code-review' = [ordered]@{ source = 'another/repository' }
        }
    }
    $lock | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $testRoot '.skill-lock.json') -Encoding UTF8
    if (Test-MattPocockSkillsInstalled -AgentsRoot $testRoot) {
        throw 'A same-name skill from another source was detected as mattpocock/skills.'
    }

    $lock.skills = [ordered]@{
        'ask-matt' = [ordered]@{ source = 'mattpocock/skills' }
    }
    $lock | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $testRoot '.skill-lock.json') -Encoding UTF8
    if (-not (Test-MattPocockSkillsInstalled -AgentsRoot $testRoot)) {
        throw 'An existing non-default skill from mattpocock/skills was not detected.'
    }

    function global:Read-Host { return '' }
    if (Select-OptionalMattPocockSkills -AlreadyInstalled:$false) {
        throw 'First mattpocock/skills installation did not default to No.'
    }
    if (-not (Select-OptionalMattPocockSkills -AlreadyInstalled:$true)) {
        throw 'Existing mattpocock/skills installation did not select automatic update.'
    }

    $installerSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'install.ps1') -Raw
    foreach ($fragment in @('Test-MattPocockSkillsInstalled', 'Get-MattPocockSkillsArguments', '& npx @skillsArguments')) {
        if (-not $installerSource.Contains($fragment)) { throw "Installer command is missing: $fragment" }
    }
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe test cleanup path: $resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'mattpocock/skills tests passed.'
