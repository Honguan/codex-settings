$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')
. (Get-OptionalInstallationScriptPath -Name Serena)

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-serena-staging-' + [guid]::NewGuid().ToString('N'))
$codexRoot = Join-Path $testRoot 'real-codex-home'
$configPath = Join-Path $codexRoot 'config.toml'
$transaction = $null
$previousCodexHome = $env:CODEX_HOME

try {
    New-Item -ItemType Directory -Path $codexRoot -Force | Out-Null
    $original = @'
# keep this comment
model = "gpt-5"

[mcp_servers.other]
command = "other"
args = ["serve"]

[features]
example = true
'@ -replace "`r`n", "`n"
    [IO.File]::WriteAllText($configPath, $original, [Text.UTF8Encoding]::new($false))
    $transaction = New-FileTransaction -Root (Join-Path $testRoot 'transaction') -Mode 'SerenaTest'
    $script:setupCodexHome = ''
    $script:setupMode = 'ValidReordered'

    function Invoke-SerenaCommand {
        param([string]$Command, [string[]]$Arguments)

        if ($Command -ne 'serena' -or ($Arguments -join ' ') -ne 'setup codex') { throw 'Unexpected Serena command.' }
        $script:setupCodexHome = [string]$env:CODEX_HOME
        if ($script:setupMode -eq 'Failure') { return [pscustomobject]@{ ExitCode = 1; Output = @('intentional setup failure') } }
        if ($script:setupMode -eq 'Throw') { throw 'intentional setup exception' }
        $stagedConfig = if ($script:setupMode -eq 'Invalid') {
            @'
[mcp_servers.serena]
command = "wrong"
args = ["start-mcp-server", "--context=codex"]
'@
        } else {
            @'
model="gpt-5"
[features]
example=true
[mcp_servers.other]
command="other"
args=["serve"]
[mcp_servers.serena]
command = "serena"
args = ["start-mcp-server", "--context=codex", "--project-from-cwd"]
'@ -replace "`r`n", "`n"
        }
        [IO.File]::WriteAllText((Join-Path $env:CODEX_HOME 'config.toml'), $stagedConfig, [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{ ExitCode = 0; Output = @() }
    }

    $env:CODEX_HOME = 'original-codex-home'
    $result = Invoke-SerenaCodexSetup -Root $codexRoot -Transaction $transaction
    if ($result -ne 'Configured') { throw "Serena setup result is invalid: $result" }
    if ([IO.Path]::GetFullPath($script:setupCodexHome) -eq [IO.Path]::GetFullPath($codexRoot)) { throw 'serena setup codex touched the real CODEX_HOME.' }
    if ($env:CODEX_HOME -ne 'original-codex-home') { throw 'CODEX_HOME was not restored after Serena setup.' }
    if (Test-Path -LiteralPath $script:setupCodexHome) { throw 'Serena staging CODEX_HOME was not removed after success.' }

    $expected = $original.TrimEnd("`r", "`n") + "`n`n[mcp_servers.serena]`ncommand = `"serena`"`nargs = [`"start-mcp-server`", `"--context=codex`", `"--project-from-cwd`"]`nstartup_timeout_sec = 30`ntool_timeout_sec = 120`n"
    $actual = [IO.File]::ReadAllText($configPath)
    if ($actual -ne $expected) { throw 'Serena setup changed non-Serena config content.' }

    $prefix = "# preserve CRLF and BOM`r`nmodel = `"gpt-5`"`r`n`r`n"
    $oldSerena = "[mcp_servers.serena]`r`ncommand = `"old-serena`"`r`nargs = [`"old`"]`r`n`r`n"
    $suffix = "[mcp_servers.other]`r`n# keep other MCP comment`r`ncommand = `"other`"`r`n"
    [IO.File]::WriteAllText($configPath, $prefix + $oldSerena + $suffix, [Text.UTF8Encoding]::new($true))
    $script:setupMode = 'ValidCrLf'
    [void](Invoke-SerenaCodexSetup -Root $codexRoot -Transaction $transaction)
    $updatedBytes = [IO.File]::ReadAllBytes($configPath)
    if ($updatedBytes[0] -ne 0xEF -or $updatedBytes[1] -ne 0xBB -or $updatedBytes[2] -ne 0xBF) { throw 'Serena setup removed the UTF-8 BOM.' }
    $updated = (Get-TextFileState -Path $configPath).Content
    $expectedUpdate = $prefix + "[mcp_servers.serena]`r`ncommand = `"serena`"`r`nargs = [`"start-mcp-server`", `"--context=codex`", `"--project-from-cwd`"]`r`nstartup_timeout_sec = 30`r`ntool_timeout_sec = 120`r`n" + $suffix
    if ($updated -ne $expectedUpdate) { throw 'Updating an existing Serena section changed surrounding CRLF content.' }
    if ([regex]::Matches($updated, '(?m)^\[mcp_servers\.serena\]\s*$').Count -ne 1) { throw 'Serena setup created a duplicate section.' }
    if (Test-Path -LiteralPath $script:setupCodexHome) { throw 'Serena staging CODEX_HOME was not removed after update.' }

    foreach ($failureMode in @('Invalid', 'Failure', 'Throw')) {
        $stableContent = "# unchanged on $failureMode`r`nmodel = `"gpt-5`"`r`n"
        [IO.File]::WriteAllText($configPath, $stableContent, [Text.UTF8Encoding]::new($true))
        $beforeBytes = [IO.File]::ReadAllBytes($configPath)
        $script:setupMode = $failureMode
        $failed = $false
        try { [void](Invoke-SerenaCodexSetup -Root $codexRoot -Transaction $transaction) } catch { $failed = $true }
        if (-not $failed) { throw "Serena setup mode $failureMode should fail." }
        if ([Convert]::ToHexString([IO.File]::ReadAllBytes($configPath)) -ne [Convert]::ToHexString($beforeBytes)) { throw "Serena setup mode $failureMode changed the real config." }
        if ($env:CODEX_HOME -ne 'original-codex-home') { throw "CODEX_HOME was not restored after $failureMode." }
        if (Test-Path -LiteralPath $script:setupCodexHome) { throw "Serena staging CODEX_HOME was not removed after $failureMode." }
    }

    Write-Host 'Serena staged setup tests passed.'
} finally {
    $env:CODEX_HOME = $previousCodexHome
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
