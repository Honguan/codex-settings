$ErrorActionPreference = 'Stop'

function Get-CvsRoot {
    $current = [IO.DirectoryInfo](Get-Location).Path
    $root = $null
    while ($null -ne $current) {
        if (Test-Path -LiteralPath (Join-Path $current.FullName 'CVS') -PathType Container) {
            $root = $current.FullName
        }
        $current = $current.Parent
    }
    return $root
}

function Get-LineEndingCounts([byte[]]$Bytes) {
    $crlf = 0
    $lfOnly = 0
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -ne 10) { continue }
        if ($index -gt 0 -and $Bytes[$index - 1] -eq 13) { $crlf++ } else { $lfOnly++ }
    }
    return [pscustomobject]@{ CRLF = $crlf; LFOnly = $lfOnly }
}

function Convert-LineEndingBytes([byte[]]$Bytes, [ValidateSet('CRLF', 'LF')][string]$Style) {
    $result = [Collections.Generic.List[byte]]::new($Bytes.Length)
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        $value = $Bytes[$index]
        if ($Style -eq 'LF' -and $value -eq 13 -and $index + 1 -lt $Bytes.Length -and $Bytes[$index + 1] -eq 10) {
            continue
        }
        if ($Style -eq 'CRLF' -and $value -eq 10 -and ($index -eq 0 -or $Bytes[$index - 1] -ne 13)) {
            $result.Add(13)
        }
        $result.Add($value)
    }
    return $result.ToArray()
}

function Invoke-LineEndingProtection {
    $root = Get-CvsRoot
    if ([string]::IsNullOrWhiteSpace($root)) { return }
    if (-not (Get-Command cvs -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine('WARNING: CVS command was not found; mixed line-ending protection was skipped.')
        return
    }

    Push-Location -LiteralPath $root
    try {
        $statusLines = @(& cvs -qn update 2>$null)
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine('WARNING: CVS status scan failed; mixed line-ending protection was skipped.')
            return
        }
    } finally {
        Pop-Location
    }

    $rootPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($line in $statusLines) {
        if ([string]$line -notmatch '^[MAC]\s+(.+?)\s*$') { continue }
        $relativePath = $Matches[1]
        $path = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
        if (-not $path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes -contains 0) { continue }
        $counts = Get-LineEndingCounts -Bytes $bytes
        if ($counts.CRLF -eq 0 -or $counts.LFOnly -eq 0) { continue }
        if ($counts.CRLF -eq $counts.LFOnly) {
            [Console]::Error.WriteLine("WARNING: Skipped ambiguous mixed line endings: $relativePath")
            continue
        }

        $style = if ($counts.CRLF -gt $counts.LFOnly) { 'CRLF' } else { 'LF' }
        [IO.File]::WriteAllBytes($path, (Convert-LineEndingBytes -Bytes $bytes -Style $style))
    }
}

try {
    Invoke-LineEndingProtection
} catch {
    [Console]::Error.WriteLine("WARNING: Mixed line-ending protection failed: $($_.Exception.Message)")
}

[Console]::Out.WriteLine('{}')
exit 0
