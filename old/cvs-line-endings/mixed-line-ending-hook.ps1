[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Track', 'Fix', 'Finalize')][string]$Mode
)

$ErrorActionPreference = 'Stop'

# Archived: Codex Code Mode does not dispatch nested apply_patch calls to this Hook reliably.

function Get-CvsRoot([string]$StartPath) {
    $current = [IO.DirectoryInfo][IO.Path]::GetFullPath($StartPath)
    while ($null -ne $current) {
        if (Test-Path -LiteralPath (Join-Path $current.FullName 'CVS') -PathType Container) { return $current.FullName }
        $current = $current.Parent
    }
    return $null
}

function Get-InputPaths($InputObject, [string]$Root) {
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $text = ($InputObject.tool_input | ConvertTo-Json -Depth 20 -Compress).Replace('\r', '').Replace('\n', "`n")
    foreach ($match in [regex]::Matches($text, '(?m)^\*\*\* (?:Update|Add|Delete) File:\s*(?<path>[^\r\n]+)$')) {
        try {
            $candidate = [string]$match.Groups['path'].Value.Trim().Replace('\\', '\')
            $path = if ([IO.Path]::IsPathRooted($candidate)) { [IO.Path]::GetFullPath($candidate) } else { [IO.Path]::GetFullPath((Join-Path ([string]$InputObject.cwd) $candidate)) }
            if ($path.StartsWith($Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { [void]$paths.Add($path) }
        } catch {}
    }
    return @($paths)
}

function Get-LineEnding([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $crlf = 0
    $lf = 0
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -ne 10) { continue }
        if ($index -gt 0 -and $bytes[$index - 1] -eq 13) { $crlf++ } else { $lf++ }
    }
    if ($crlf -eq 0 -and $lf -eq 0) { return 'auto' }
    return $(if ($crlf -ge $lf) { 'crlf' } else { 'lf' })
}

function Test-FinalNewline([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    return $bytes.Length -gt 0 -and $bytes[-1] -eq 10
}

function Set-FinalNewline([string]$Path, [bool]$Present, [ValidateSet('crlf', 'lf')][string]$Style) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasFinalNewline = $bytes.Length -gt 0 -and $bytes[-1] -eq 10
    if ($Present -eq $hasFinalNewline) { return }
    if ($Present) {
        $ending = if ($Style -eq 'crlf') { [byte[]](13, 10) } else { [byte[]](10) }
        [IO.File]::WriteAllBytes($Path, [byte[]]$bytes + $ending)
        return
    }
    $length = $bytes.Length - 1
    if ($length -gt 0 -and $bytes[$length - 1] -eq 13) { $length-- }
    [IO.File]::WriteAllBytes($Path, $(if ($length -eq 0) { [byte[]]@() } else { [byte[]]$bytes[0..($length - 1)] }))
}

function Get-StatePath([string]$Root, [string]$SessionId) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Root|$SessionId")))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $stateRoot = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_LINE_ENDING_STATE_ROOT)) { Join-Path $HOME '.codex\state\mixed-line-ending' } else { $env:CODEX_SETTINGS_LINE_ENDING_STATE_ROOT }
    return Join-Path $stateRoot ($key + '.json')
}

function Read-State([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [ordered]@{ files = [ordered]@{}; pending = @(); changed = @() } }
    return [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

function Write-State([string]$Path, $State) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $temporary = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Invoke-MixedLineEnding([ValidateSet('auto', 'crlf', 'lf', 'no')][string]$Fix, [string[]]$Paths) {
    $files = @($Paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Where-Object { -not [IO.File]::ReadAllBytes($_).Contains([byte]0) } | Select-Object -Unique)
    if ($files.Count -eq 0) { return }
    $command = Get-Command mixed-line-ending, mixed-line-ending.ps1 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { & $command.Source "--fix=$Fix" @files *> $null }
    elseif ($IsWindows -or $env:OS -eq 'Windows_NT') { & py -m pre_commit_hooks.mixed_line_ending "--fix=$Fix" @files *> $null }
    else { & python3 -m pre_commit_hooks.mixed_line_ending "--fix=$Fix" @files *> $null }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and $Fix -ne 'no') {
        if ($null -ne $command) { & $command.Source '--fix=no' @files *> $null }
        elseif ($IsWindows -or $env:OS -eq 'Windows_NT') { & py -m pre_commit_hooks.mixed_line_ending '--fix=no' @files *> $null }
        else { & python3 -m pre_commit_hooks.mixed_line_ending '--fix=no' @files *> $null }
        $exitCode = $LASTEXITCODE
    }
    if ($exitCode -ne 0) { throw 'mixed-line-ending found invalid files or could not run.' }
}

$inputText = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputText)) { exit 0 }
$inputObject = $inputText | ConvertFrom-Json -ErrorAction Stop
$root = Get-CvsRoot -StartPath ([string]$inputObject.cwd)
if ([string]::IsNullOrWhiteSpace($root)) { exit 0 }
$statePath = Get-StatePath -Root $root -SessionId ([string]$inputObject.session_id)

$state = Read-State -Path $statePath

if ($Mode -eq 'Track') {
    $paths = @(Get-InputPaths -InputObject $inputObject -Root $root)
    foreach ($path in $paths) {
        if ($state.files.Contains($path)) { continue }
        $state.files[$path] = if (Test-Path -LiteralPath $path -PathType Leaf) {
            [ordered]@{ eol = Get-LineEnding -Path $path; finalNewline = Test-FinalNewline -Path $path }
        } else {
            [ordered]@{ eol = 'auto'; finalNewline = $null }
        }
    }
    $state.pending = @($paths)
    Write-State -Path $statePath -State $state
    exit 0
}

$paths = if ($Mode -eq 'Fix') {
    $actual = @(Get-InputPaths -InputObject $inputObject -Root $root)
    if ($actual.Count -gt 0) { $actual } else { @($state.pending) }
} else {
    @(@($state.changed) + @($state.pending) | Select-Object -Unique)
}
$changed = [Collections.Generic.List[string]]::new()
foreach ($path in $paths) {
    if (-not $state.files.Contains($path)) { continue }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $style = [string]$state.files[$path].eol
    Invoke-MixedLineEnding -Fix $style -Paths @($path)
    if ($style -in @('lf', 'crlf')) { Set-FinalNewline -Path $path -Present ([bool]$state.files[$path].finalNewline) -Style $style }
    $changed.Add($path)
}

$state.changed = @(@($state.changed) + @($changed) | Select-Object -Unique)
$state.pending = @()
if ($Mode -eq 'Finalize') {
    Invoke-MixedLineEnding -Fix no -Paths @($state.changed)
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
} else {
    Write-State -Path $statePath -State $state
}
