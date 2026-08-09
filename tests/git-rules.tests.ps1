$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

function Get-PolicyRules([string]$Content) {
    @([regex]::Matches($Content, '(?ms)^# \d+\.[^\r\n]*\r?\nprefix_rule\(\r?\n(?<body>.*?)^\)') | ForEach-Object {
        $body = $_.Groups['body'].Value
        $patternMatch = [regex]::Match($body, '(?m)^\s*pattern\s*=\s*(?<value>.+),\s*$')
        $decisionMatch = [regex]::Match($body, '(?m)^\s*decision\s*=\s*"(?<value>[^"]+)"')
        if (-not $patternMatch.Success -or -not $decisionMatch.Success) {
            throw 'Unable to parse a managed prefix_rule block.'
        }
        $pattern = $patternMatch.Groups['value'].Value | ConvertFrom-Json
        if ($pattern.Count -gt 0 -and $pattern[0] -is [string]) {
            $pattern = , @($pattern)
        }
        [pscustomobject]@{
            Pattern = $pattern
            Decision = $decisionMatch.Groups['value'].Value
        }
    })
}

function Get-CommandDecision([object[]]$Rules, [string[]]$Command) {
    $rank = @{ allow = 1; prompt = 2; forbidden = 3 }
    $matchedDecisions = foreach ($rule in $Rules) {
        if ($Command.Count -lt $rule.Pattern.Count) { continue }
        $matches = $true
        for ($index = 0; $index -lt $rule.Pattern.Count; $index++) {
            if ($Command[$index] -notin @($rule.Pattern[$index])) {
                $matches = $false
                break
            }
        }
        if ($matches) { $rule.Decision }
    }
    if (@($matchedDecisions).Count -eq 0) { return $null }
    return @($matchedDecisions | Sort-Object { $rank[$_] } -Descending)[0]
}

function Assert-Decision([object[]]$Rules, [string[]]$Command, [string]$Expected) {
    $actual = Get-CommandDecision -Rules $Rules -Command $Command
    if ($actual -ne $Expected) {
        throw "Unexpected decision for '$($Command -join ' ')': expected=$Expected actual=$actual"
    }
}

function Assert-GitRules([string]$RulesPath) {
    $rules = Get-PolicyRules ([IO.File]::ReadAllText($RulesPath))
    $allowedCommands = @(
        'status', 'diff', 'log', 'show',
        'add file.txt', 'add -A', 'commit -m test',
        'fetch', 'fetch origin', 'pull', 'pull --rebase',
        'push', 'push origin main',
        'checkout main', 'checkout -b feature/test',
        'switch main', 'switch -c feature/test',
        'branch', 'branch feature/test', 'stash', 'stash push',
        'merge feature/test', 'rebase main',
        'cherry-pick <sha>', 'revert <sha>', 'tag v1.0.0'
    )
    foreach ($executable in @('git', 'git.exe')) {
        foreach ($commandText in $allowedCommands) {
            $command = @($executable) + @($commandText -split ' ')
            Assert-Decision -Rules $rules -Command $command -Expected 'allow'
        }
        foreach ($operation in @('restore', 'reset', 'clean', 'worktree', 'submodule')) {
            Assert-Decision -Rules $rules -Command @($executable, $operation) -Expected 'prompt'
        }
    }

    $destructiveCases = @(
        'reset --hard', 'reset --hard HEAD',
        'clean -f', 'clean -fd', 'clean -df', 'clean -fdx',
        'clean -xdf', 'clean -ff', 'clean -ffdx',
        'push --force', 'push -f', 'push --force-with-lease'
    )
    foreach ($executable in @('git', 'git.exe')) {
        foreach ($commandText in $destructiveCases) {
            $command = @($executable) + @($commandText -split ' ')
            Assert-Decision -Rules $rules -Command $command -Expected 'forbidden'
        }
    }

    $forbiddenPatterns = @($rules | Where-Object { $_.Decision -eq 'forbidden' -and 'git' -in @($_.Pattern[0]) } | ForEach-Object { $_.Pattern | ConvertTo-Json -Compress -Depth 5 })
    $expectedForbiddenPatterns = @(
        '[["git","git.exe"],["reset"],["--hard"]]',
        '[["git","git.exe"],["clean"],["-f","-fd","-df","-fdx","-xdf","-ff","-ffdx"]]',
        '[["git","git.exe"],["push"],["--force","-f","--force-with-lease"]]'
    )
    if (($forbiddenPatterns -join "`n") -ne ($expectedForbiddenPatterns -join "`n")) {
        throw 'The existing destructive Git rule patterns changed.'
    }

    Assert-Decision -Rules $rules -Command @('gh', 'issue', 'close', '60') -Expected 'prompt'
    Assert-Decision -Rules $rules -Command @('npm', 'install') -Expected 'prompt'
    Assert-Decision -Rules $rules -Command @('cvs', 'status') -Expected 'forbidden'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-git-rules-' + [guid]::NewGuid().ToString('N'))
try {
    $templatePath = Join-Path $script:ScriptRoot 'templates\environments\git\rules\default.rules'
    Assert-GitRules -RulesPath $templatePath

    $globalRoot = Join-Path $testRoot '.codex'
    $transaction = New-FileTransaction -Root (Join-Path $testRoot 'transaction') -Mode 'Test-Git-Rules'
    $target = New-InstallTarget -Id 'test-global' -Mode 'Global' -TemplateRoot (Join-Path $script:ScriptRoot 'templates\core') -EnvironmentTemplateRoot (Join-Path $script:ScriptRoot 'templates\environments\git') -DevelopmentEnvironment 'Git' -Root $globalRoot -EnableDefaultModeRequestUserInput $false -InstallWindowsNotifications $false -SourceRoot $script:ScriptRoot
    $result = Invoke-TargetInstallation -Target $target -Transaction $transaction
    Save-InstallationManifest -Result $result -Transaction $transaction -External $null
    Complete-FileTransaction -Transaction $transaction

    Assert-GitRules -RulesPath (Join-Path $globalRoot 'rules\default.rules')
    Write-Host 'Git rules decision matrix tests passed.'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
