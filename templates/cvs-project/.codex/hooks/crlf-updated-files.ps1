param(
    [switch]$Flush
)

$ErrorActionPreference = 'SilentlyContinue'

$hookDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateFile = Join-Path $hookDir 'crlf-updated-files.txt'
$inputText = [Console]::In.ReadToEnd()
$targets = New-Object System.Collections.Generic.List[string]
$inputObject = $null

function Add-Target {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path (Get-Location) $expanded
    }

    $fullPath = [System.IO.Path]::GetFullPath($expanded)
    if (-not $targets.Contains($fullPath)) {
        $targets.Add($fullPath) | Out-Null
    }
}

function Convert-ToCrlf {
    param([string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0 -or [Array]::IndexOf($bytes, [byte]0) -ge 0) {
        return
    }

    $stream = New-Object System.IO.MemoryStream
    $changed = $false

    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -eq 13) {
            $stream.WriteByte(13)
            if (($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 10) {
                $stream.WriteByte(10)
                $i++
            } else {
                $stream.WriteByte(10)
                $changed = $true
            }
        } elseif ($b -eq 10) {
            $stream.WriteByte(13)
            $stream.WriteByte(10)
            $changed = $true
        } else {
            $stream.WriteByte($b)
        }
    }

    if ($changed) {
        [System.IO.File]::WriteAllBytes($Path, $stream.ToArray())
    }
}

try {
    if (-not [string]::IsNullOrWhiteSpace($inputText)) {
        $inputObject = $inputText | ConvertFrom-Json
        $toolInput = $inputObject.tool_input
        Add-Target $toolInput.file_path
        Add-Target $toolInput.path
    }
} catch {
}

foreach ($match in [regex]::Matches($inputText, '\*\*\* (?:Add|Update) File: (.+)')) {
    Add-Target $match.Groups[1].Value.Trim()
}

if ($Flush -and [System.IO.File]::Exists($stateFile)) {
    foreach ($line in [System.IO.File]::ReadAllLines($stateFile)) {
        Add-Target $line
    }
}

foreach ($target in $targets) {
    Convert-ToCrlf $target
}

if ($targets.Count -gt 0 -and -not $Flush) {
    [System.IO.File]::AppendAllLines($stateFile, $targets)
}

if ($Flush -and [System.IO.File]::Exists($stateFile)) {
    Remove-Item -LiteralPath $stateFile -Force
}

exit 0
