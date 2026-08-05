param(
    [switch]$Flush
)

$ErrorActionPreference = 'Stop'

$hookDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $hookDir)
$rootMarker = Join-Path $projectRoot '.codex-root'
if (-not (Test-Path -LiteralPath $rootMarker -PathType Leaf)) {
    throw "CVS project root marker was not found: $rootMarker"
}

$projectRoot = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/')
$projectPrefix = $projectRoot + [IO.Path]::DirectorySeparatorChar
$maxFileSize = 10MB
$allowedExtensions = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($extension in @(
        '.php', '.inc', '.phtml', '.js', '.jsx', '.ts', '.tsx', '.css', '.scss', '.less',
        '.html', '.htm', '.xml', '.json', '.yaml', '.yml', '.toml', '.ini', '.conf', '.config',
        '.sql', '.md', '.txt', '.csv', '.ps1', '.psm1', '.bat', '.cmd', '.java', '.cs', '.go',
        '.rs', '.py', '.rb', '.lua'
    )) {
    [void]$allowedExtensions.Add($extension)
}

$stateBase = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'CodexSettings\HookState'
}
else {
    Join-Path ([IO.Path]::GetTempPath()) 'CodexSettings-HookState'
}

New-Item -ItemType Directory -Path $stateBase -Force | Out-Null
Get-ChildItem -LiteralPath $stateBase -File -ErrorAction SilentlyContinue |
Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
Remove-Item -Force -ErrorAction SilentlyContinue

$sha = [Security.Cryptography.SHA256]::Create()
try {
    $rootHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($projectRoot)))).Replace('-', '').Substring(0, 16)
}
finally {
    $sha.Dispose()
}
$stateFile = Join-Path $stateBase ("crlf-$rootHash.txt")
$targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$inputText = [Console]::In.ReadToEnd()

function Add-Target {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path (Get-Location) $expanded
    }

    $fullPath = [IO.Path]::GetFullPath($expanded)
    if (-not $fullPath.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) { return }

    $relativePath = $fullPath.Substring($projectPrefix.Length)
    if ($relativePath -match '(^|[\\/])(CVS|\.codex)([\\/]|$)') { return }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return }

    $item = Get-Item -LiteralPath $fullPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
    if ($item.Length -gt $maxFileSize) { return }
    if (-not $allowedExtensions.Contains($item.Extension)) { return }

    [void]$targets.Add($item.FullName)
}

function Convert-ToCrlf {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0 -or [Array]::IndexOf($bytes, [byte]0) -ge 0) { return $false }

    $stream = New-Object IO.MemoryStream
    try {
        $changed = $false
        for ($index = 0; $index -lt $bytes.Length; $index++) {
            $value = $bytes[$index]
            if ($value -eq 13) {
                $stream.WriteByte(13)
                if (($index + 1) -lt $bytes.Length -and $bytes[$index + 1] -eq 10) {
                    $stream.WriteByte(10)
                    $index++
                }
                else {
                    $stream.WriteByte(10)
                    $changed = $true
                }
            }
            elseif ($value -eq 10) {
                $stream.WriteByte(13)
                $stream.WriteByte(10)
                $changed = $true
            }
            else {
                $stream.WriteByte($value)
            }
        }

        if ($changed) {
            [IO.File]::WriteAllBytes($Path, $stream.ToArray())
        }
        return $changed
    }
    finally {
        $stream.Dispose()
    }
}

try {
    if (-not [string]::IsNullOrWhiteSpace($inputText)) {
        try {
            $payload = $inputText | ConvertFrom-Json -ErrorAction Stop
            Add-Target ([string]$payload.tool_input.file_path)
            Add-Target ([string]$payload.tool_input.path)
        }
        catch {
            # apply_patch payloads are handled by the text matcher below.
        }

        foreach ($match in [regex]::Matches($inputText, '\*\*\* (?:Add|Update) File: (.+)')) {
            Add-Target $match.Groups[1].Value
        }
    }

    $convertedCount = 0
    if (-not $Flush) {
        foreach ($target in $targets) {
            if (Convert-ToCrlf -Path $target) { $convertedCount++ }
        }

        if ($targets.Count -gt 0) {
            $allTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
                foreach ($line in [IO.File]::ReadAllLines($stateFile)) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) { [void]$allTargets.Add($line) }
                }
            }
            foreach ($target in $targets) { [void]$allTargets.Add($target) }
            [IO.File]::WriteAllLines($stateFile, @($allTargets))
        }
    }

    if ($Flush) {
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    }

    if ($convertedCount -gt 0) {
        Write-Output "Converted $convertedCount file(s) to CRLF."
    }
    exit 0
}
catch {
    Write-Error "CRLF hook failed: $($_.Exception.Message)"
    exit 1
}
