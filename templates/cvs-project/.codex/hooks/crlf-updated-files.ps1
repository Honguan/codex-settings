param(
    [switch]$Flush
)

$ErrorActionPreference = 'Stop'

$hookDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $hookDir)
$rootMarker = Join-Path $projectRoot '.codex-root'

if (-not (Test-Path -LiteralPath $rootMarker -PathType Leaf)) {
    Write-Error "CVS project root marker was not found: $rootMarker"
    exit 1
}

$projectRoot = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/')
$comparison = [StringComparison]::OrdinalIgnoreCase
$stateBase = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'CodexSettings\HookState'
} else {
    Join-Path ([IO.Path]::GetTempPath()) 'CodexSettings-HookState'
}

$sha = [Security.Cryptography.SHA256]::Create()
$rootHash = [BitConverter]::ToString(
    $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($projectRoot))
).Replace('-', '').Substring(0, 16)
$sha.Dispose()

$stateDir = Join-Path $stateBase $rootHash
$stateFile = Join-Path $stateDir 'crlf-updated-files.txt'
$inputText = [Console]::In.ReadToEnd()
$targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

$excludedExtensions = @(
    '.sh', '.bash', '.zsh', '.fish', '.command', '.patch', '.diff',
    '.pem', '.key', '.p12', '.pfx', '.cer', '.crt', '.der'
)
$excludedNames = @('Dockerfile', 'Makefile', '.gitattributes')

function Test-WithinProject {
    param([string]$Path)

    if ([string]::Equals($Path, $projectRoot, $comparison)) {
        return $false
    }

    $prefix = $projectRoot + [IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($prefix, $comparison)
}

function Add-Target {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path (Get-Location) $expanded
    }

    $fullPath = [IO.Path]::GetFullPath($expanded)
    if (-not (Test-WithinProject $fullPath)) {
        return
    }

    $relativePath = $fullPath.Substring($projectRoot.Length).TrimStart('\', '/')
    if ($relativePath -match '(^|[\\/])(CVS|\.codex)([\\/]|$)') {
        return
    }

    $name = [IO.Path]::GetFileName($fullPath)
    $extension = [IO.Path]::GetExtension($fullPath).ToLowerInvariant()
    if ($excludedNames -contains $name -or $excludedExtensions -contains $extension) {
        return
    }

    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        $item = Get-Item -LiteralPath $fullPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return
        }

        [void]$targets.Add($item.FullName)
    }
}

function Convert-ToCrlf {
    param([string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0 -or [Array]::IndexOf($bytes, [byte]0) -ge 0) {
        return $false
    }

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
                } else {
                    $stream.WriteByte(10)
                    $changed = $true
                }
            } elseif ($value -eq 10) {
                $stream.WriteByte(13)
                $stream.WriteByte(10)
                $changed = $true
            } else {
                $stream.WriteByte($value)
            }
        }

        if ($changed) {
            [IO.File]::WriteAllBytes($Path, $stream.ToArray())
        }

        return $changed
    } finally {
        $stream.Dispose()
    }
}

try {
    if (-not [string]::IsNullOrWhiteSpace($inputText)) {
        try {
            $inputObject = $inputText | ConvertFrom-Json -ErrorAction Stop
            $toolInput = $inputObject.tool_input
            Add-Target ([string]$toolInput.file_path)
            Add-Target ([string]$toolInput.path)
        } catch {
            # apply_patch input is parsed below when the hook payload is not JSON-shaped.
        }

        foreach ($match in [regex]::Matches($inputText, '\*\*\* (?:Add|Update) File: (.+)')) {
            Add-Target $match.Groups[1].Value
        }
    }

    if ($Flush -and (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        foreach ($line in [IO.File]::ReadAllLines($stateFile)) {
            Add-Target $line
        }
    }

    $convertedCount = 0
    foreach ($target in $targets) {
        if (Convert-ToCrlf $target) {
            $convertedCount++
        }
    }

    if (-not $Flush -and $targets.Count -gt 0) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        $allTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
            foreach ($line in [IO.File]::ReadAllLines($stateFile)) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    [void]$allTargets.Add($line)
                }
            }
        }
        foreach ($target in $targets) {
            [void]$allTargets.Add($target)
        }
        [IO.File]::WriteAllLines($stateFile, @($allTargets))
    }

    if ($Flush -and (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        Remove-Item -LiteralPath $stateFile -Force
        if ((Test-Path -LiteralPath $stateDir -PathType Container) -and
            (Get-ChildItem -LiteralPath $stateDir -Force | Measure-Object).Count -eq 0) {
            Remove-Item -LiteralPath $stateDir -Force
        }
    }

    if ($convertedCount -gt 0) {
        Write-Output "Converted $convertedCount file(s) to CRLF."
    }

    exit 0
} catch {
    Write-Error "CRLF hook failed: $($_.Exception.Message)"
    exit 1
}
