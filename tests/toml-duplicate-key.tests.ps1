$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'src\load-installation.ps1')

$duplicate = @'
[mcp_servers.serena]
command = "serena"
command = "serena"
'@
$shape = Get-TomlShape -Content $duplicate
if (@($shape.Duplicates) -notcontains 'key:mcp_servers.serena.command') {
    throw 'Get-TomlShape did not detect a duplicate key inside a TOML section.'
}

$valid = @'
[mcp_servers.one]
command = "one"

[mcp_servers.two]
command = "two"
'@
if (@((Get-TomlShape -Content $valid).Duplicates).Count -ne 0) {
    throw 'Get-TomlShape rejected distinct keys in distinct TOML sections.'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-existing-mcp-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $configPath = Join-Path $testRoot 'config.toml'
    [IO.File]::WriteAllText($configPath, "[mcp_servers.playwright]`r`ncommand = `"user-playwright`"`r`nenabled = false`r`n", [Text.UTF8Encoding]::new($false))
    $transaction = New-FileTransaction -Root (Join-Path $testRoot 'transaction') -Mode TestExistingMcp
    $target = New-InstallTarget -Id test-global -Mode Global -TemplateRoot (Join-Path $repositoryRoot 'src\templates\core') -EnvironmentTemplateRoot (Join-Path $repositoryRoot 'src\templates\environments\git') -DevelopmentEnvironment Git -Root $testRoot -InstallWindowsNotifications:$false -SourceRoot (Join-Path $repositoryRoot 'src')
    Invoke-TargetInstallation -Target $target -Transaction $transaction | Out-Null
    $installed = [IO.File]::ReadAllText($configPath)
    $installedShape = Get-TomlShape -Content $installed
    if (@($installedShape.Duplicates).Count -gt 0) { throw "Global Merge duplicated an existing MCP section: $($installedShape.Duplicates -join ', ')" }
    if ([regex]::Matches($installed, '(?m)^\[mcp_servers\.playwright\]\s*$').Count -ne 1 -or $installed -notmatch 'command = "user-playwright"' -or $installed -match '(?m)^model\s*=') {
        throw 'Global Merge did not preserve the existing MCP section or remove the model preset.'
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

try {
    Merge-TomlTemplate -ExistingContent $duplicate -TemplateContent '# managed' -StartMarker '# >>> managed >>>' -EndMarker '# <<< managed <<<' | Out-Null
    throw 'Merge-TomlTemplate accepted a duplicate key inside a TOML section.'
} catch {
    if ($_.Exception.Message -notmatch 'Existing TOML contains duplicate entries:.*mcp_servers\.serena\.command') { throw }
}

Write-Host 'TOML duplicate-key tests passed.'
