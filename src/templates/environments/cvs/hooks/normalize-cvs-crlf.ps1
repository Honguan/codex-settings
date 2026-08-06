$ErrorActionPreference = 'Stop'
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

function Find-CvsRoot {
    $directory = [IO.DirectoryInfo](Get-Location).Path
    $root = $null
    while ($null -ne $directory) {
        if (Test-Path -LiteralPath (Join-Path $directory.FullName 'CVS') -PathType Container) {
            $root = $directory.FullName
        }
        $directory = $directory.Parent
    }
    return $root
}

function Resolve-CvsFile {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Path
    )

    try {
        $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
        $prefix = $root + [IO.Path]::DirectorySeparatorChar
        $fullPath = if ([IO.Path]::IsPathRooted($Path)) {
            [IO.Path]::GetFullPath($Path)
        } else {
            [IO.Path]::GetFullPath((Join-Path $root $Path))
        }
    } catch {
        return $null
    }

    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $relativePath = $fullPath.Substring($prefix.Length).Replace('\', '/')
    if ($relativePath -match '(^|/)(CVS|\.codex)(/|$)') { return $null }
    return [pscustomobject]@{ FullPath = $fullPath; RelativePath = $relativePath }
}

function Test-AllowedTextFile {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Target
    )

    if (-not (Test-Path -LiteralPath $Target.FullPath -PathType Leaf)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Target.FullPath -Force
        if ($item.Length -gt $maxFileSize -or -not $allowedExtensions.Contains($item.Extension)) { return $false }

        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $directory = $item.Directory
        $reachedRoot = $false
        while ($null -ne $directory) {
            if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if ($directory.FullName.Equals($ProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $reachedRoot = $true
                break
            }
            $directory = $directory.Parent
        }
        if (-not $reachedRoot) { return $false }

        $bytes = [IO.File]::ReadAllBytes($Target.FullPath)
        return $bytes.Length -gt 0 -and [Array]::IndexOf($bytes, [byte]0) -lt 0
    } catch {
        return $false
    }
}

function Convert-ToCrlf {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $stream = [IO.MemoryStream]::new()
    try {
        $changed = $false
        for ($index = 0; $index -lt $bytes.Length; $index++) {
            $value = $bytes[$index]
            if ($value -eq 0x0D) {
                $stream.WriteByte(0x0D)
                if (($index + 1) -lt $bytes.Length -and $bytes[$index + 1] -eq 0x0A) {
                    $stream.WriteByte(0x0A)
                    $index++
                } else {
                    $stream.WriteByte(0x0A)
                    $changed = $true
                }
            } elseif ($value -eq 0x0A) {
                $stream.WriteByte(0x0D)
                $stream.WriteByte(0x0A)
                $changed = $true
            } else {
                $stream.WriteByte($value)
            }
        }

        if ($changed) { [IO.File]::WriteAllBytes($Path, $stream.ToArray()) }
        return $changed
    } finally {
        $stream.Dispose()
    }
}

function Get-LfOnlyCount {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $count = 0
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -eq 0x0A -and ($index -eq 0 -or $bytes[$index - 1] -ne 0x0D)) { $count++ }
    }
    return $count
}

$projectRoot = Find-CvsRoot
if ([string]::IsNullOrWhiteSpace($projectRoot)) { exit 0 }
$projectRoot = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/')

try {
    Push-Location $projectRoot
    try {
        $cvsOutput = @(& cvs -qn update 2>&1)
        $cvsExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($cvsExitCode -ne 0) {
        $details = ($cvsOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        $message = "cvs -qn update failed with exit code $cvsExitCode."
        if (-not [string]::IsNullOrWhiteSpace($details)) { $message += [Environment]::NewLine + $details }
        [Console]::Error.WriteLine($message)
        exit 1
    }

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $cvsOutput) {
        if ([string]$line -match '^[MAC]\s+(.+)$') { [void]$paths.Add($Matches[1].Trim()) }
    }

    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $paths) {
        $target = Resolve-CvsFile -ProjectRoot $projectRoot -Path $path
        if ($null -eq $target -or -not (Test-AllowedTextFile -ProjectRoot $projectRoot -Target $target)) { continue }
        try {
            [void](Convert-ToCrlf -Path $target.FullPath)
            $lfOnly = Get-LfOnlyCount -Path $target.FullPath
            if ($lfOnly -gt 0) { throw "$lfOnly LF-only line ending(s) remain." }
        } catch {
            [void]$failures.Add("CRLF conversion failed: $($target.RelativePath) - $($_.Exception.Message)")
        }
    }

    if ($failures.Count -gt 0) {
        [Console]::Error.WriteLine(($failures -join [Environment]::NewLine))
        exit 1
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("CVS CRLF hook failed: $($_.Exception.Message)")
    exit 1
}
