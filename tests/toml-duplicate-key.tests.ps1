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

try {
    Merge-TomlTemplate -ExistingContent $duplicate -TemplateContent '# managed' -StartMarker '# >>> managed >>>' -EndMarker '# <<< managed <<<' | Out-Null
    throw 'Merge-TomlTemplate accepted a duplicate key inside a TOML section.'
} catch {
    if ($_.Exception.Message -notmatch 'Existing TOML contains duplicate entries:.*mcp_servers\.serena\.command') { throw }
}

Write-Host 'TOML duplicate-key tests passed.'
