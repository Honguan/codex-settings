[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $HOME '.codex\config.toml')
)

$ErrorActionPreference = 'Stop'

function Get-PencilCandidate {
    $definitions = @(
        [pscustomobject]@{
            Pattern = (Join-Path $HOME '.vscode\extensions\highagency.pencildev-*\out\mcp-server-windows-x64.exe')
            App = 'visual_studio_code'
        },
        [pscustomobject]@{
            Pattern = (Join-Path $HOME '.cursor\extensions\highagency.pencildev-*\out\mcp-server-windows-x64.exe')
            App = 'cursor'
        },
        [pscustomobject]@{
            Pattern = (Join-Path $env:LOCALAPPDATA 'Programs\Pencil\resources\app.asar.unpacked\out\mcp-server-windows-x64.exe')
            App = 'desktop'
        },
        [pscustomobject]@{
            Pattern = (Join-Path $env:ProgramFiles 'Pencil\resources\app.asar.unpacked\out\mcp-server-windows-x64.exe')
            App = 'desktop'
        }
    )

    foreach ($definition in $definitions) {
        $match = Get-Item -Path $definition.Pattern -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($null -ne $match) {
            return [pscustomobject]@{
                Path = $match.FullName
                App = $definition.App
            }
        }
    }

    return $null
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Codex config was not found: $ConfigPath"
}

$content = [IO.File]::ReadAllText($ConfigPath)
$content = [regex]::Replace(
    $content,
    '(?ms)^\[mcp_servers\.pencil\]\r?\n.*?(?=^\[|\z)',
    ''
).TrimEnd()

$candidate = Get-PencilCandidate
if ($null -eq $candidate) {
    [IO.File]::WriteAllText($ConfigPath, $content + [Environment]::NewLine)
    Write-Warning 'Pencil MCP executable was not found. Start or install pen.dev, then rerun this script.'
    exit 0
}

$escapedPath = $candidate.Path.Replace('\', '\\').Replace('"', '\"')
$block = @"

[mcp_servers.pencil]
command = "$escapedPath"
args = ["--app", "$($candidate.App)"]
enabled = true
startup_timeout_sec = 30
tool_timeout_sec = 120
"@

[IO.File]::WriteAllText($ConfigPath, $content + $block + [Environment]::NewLine)
Write-Host "Configured Pencil MCP: $($candidate.Path)"
