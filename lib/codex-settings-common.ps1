$script:CsStartMarker = '# >>> CS CODEX SESSION VIEWER >>>'
$script:CsEndMarker = '# <<< CS CODEX SESSION VIEWER <<<'
$script:CdailyStartMarker = '# >>> CDAILY CODEX DAILY REPORT >>>'
$script:CdailyEndMarker = '# <<< CDAILY CODEX DAILY REPORT <<<'

function Get-TextFileState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Content = ''
            Encoding = New-Object Text.UTF8Encoding($false)
            NewLine = "`r`n"
        }
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    $encoding = New-Object Text.UTF8Encoding($false)
    $offset = 0

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object Text.UTF8Encoding($true)
        $offset = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.Encoding]::Unicode
        $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [Text.Encoding]::BigEndianUnicode
        $offset = 2
    }

    $content = if ($bytes.Length -gt $offset) {
        $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    } else {
        ''
    }

    $newLine = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }

    return [pscustomobject]@{
        Exists = $true
        Content = $content
        Encoding = $encoding
        NewLine = $newLine
    }
}

function Write-TextFileState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)]$Encoding
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [IO.File]::WriteAllText($Path, $Content, $Encoding)
}

function Remove-ManagedBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$StartMarker,
        [Parameter(Mandatory = $true)][string]$EndMarker
    )

    $pattern = '(?ms)^\s*' + [regex]::Escape($StartMarker) + '\r?\n.*?^\s*' + [regex]::Escape($EndMarker) + '\r?\n?'
    return [regex]::Replace($Content, $pattern, '').TrimEnd()
}

function Merge-ManagedBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ManagedContent,
        [Parameter(Mandatory = $true)][string]$StartMarker,
        [Parameter(Mandatory = $true)][string]$EndMarker,
        [string]$NewLine = "`r`n"
    )

    $base = Remove-ManagedBlock -Content $ExistingContent -StartMarker $StartMarker -EndMarker $EndMarker
    $block = $StartMarker + $NewLine + $ManagedContent.Trim() + $NewLine + $EndMarker

    if ([string]::IsNullOrWhiteSpace($base)) {
        return $block + $NewLine
    }

    return $base.TrimEnd() + $NewLine + $NewLine + $block + $NewLine
}

function Get-TomlShape {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $topLevelKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $sections = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $duplicates = New-Object 'System.Collections.Generic.List[string]'
    $currentSection = $null

    foreach ($line in ($Content -split '\r?\n')) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($trimmed -match '^\[([^\]]+)\]\s*(?:#.*)?$') {
            $currentSection = $matches[1].Trim()
            if (-not $sections.Add($currentSection)) {
                [void]$duplicates.Add("section:$currentSection")
            }
            continue
        }

        if ($null -eq $currentSection -and $trimmed -match '^([A-Za-z0-9_.-]+)\s*=') {
            $key = $matches[1]
            if (-not $topLevelKeys.Add($key)) {
                [void]$duplicates.Add("key:$key")
            }
        }
    }

    return [pscustomobject]@{
        TopLevelKeys = $topLevelKeys
        Sections = $sections
        Duplicates = @($duplicates)
    }
}

function Select-TomlTemplateContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TemplateContent,
        [Parameter(Mandatory = $true)]$ExistingShape,
        [string]$NewLine = "`r`n"
    )

    $lines = @($TemplateContent -split '\r?\n')
    $output = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object 'System.Collections.Generic.List[string]'
    $index = 0

    while ($index -lt $lines.Count) {
        $line = $lines[$index]
        $trimmed = $line.Trim()

        if ($trimmed -match '^\[([^\]]+)\]\s*(?:#.*)?$') {
            $sectionName = $matches[1].Trim()
            $block = New-Object 'System.Collections.Generic.List[string]'
            foreach ($item in $pending) { [void]$block.Add($item) }
            $pending.Clear()
            [void]$block.Add($line)
            $index++

            while ($index -lt $lines.Count -and $lines[$index].Trim() -notmatch '^\[([^\]]+)\]\s*(?:#.*)?$') {
                [void]$block.Add($lines[$index])
                $index++
            }

            if (-not $ExistingShape.Sections.Contains($sectionName)) {
                foreach ($item in $block) { [void]$output.Add($item) }
                [void]$output.Add('')
            }
            continue
        }

        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) {
            [void]$pending.Add($line)
            $index++
            continue
        }

        if ($trimmed -match '^([A-Za-z0-9_.-]+)\s*=') {
            $key = $matches[1]
            if (-not $ExistingShape.TopLevelKeys.Contains($key)) {
                foreach ($item in $pending) { [void]$output.Add($item) }
                [void]$output.Add($line)
                [void]$output.Add('')
            }
            $pending.Clear()
            $index++
            continue
        }

        foreach ($item in $pending) { [void]$output.Add($item) }
        $pending.Clear()
        [void]$output.Add($line)
        $index++
    }

    return (($output -join $NewLine).Trim())
}

function Merge-TomlTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TemplateContent,
        [Parameter(Mandatory = $true)][string]$StartMarker,
        [Parameter(Mandatory = $true)][string]$EndMarker,
        [string]$NewLine = "`r`n"
    )

    $base = Remove-ManagedBlock -Content $ExistingContent -StartMarker $StartMarker -EndMarker $EndMarker
    $baseShape = Get-TomlShape -Content $base
    if ($baseShape.Duplicates.Count -gt 0) {
        throw "Existing TOML contains duplicate entries: $($baseShape.Duplicates -join ', ')"
    }

    $selected = Select-TomlTemplateContent -TemplateContent $TemplateContent -ExistingShape $baseShape -NewLine $NewLine
    if ([string]::IsNullOrWhiteSpace($selected)) {
        $result = if ([string]::IsNullOrWhiteSpace($base)) { '' } else { $base.TrimEnd() + $NewLine }
    } else {
        $result = Merge-ManagedBlock -ExistingContent $base -ManagedContent $selected -StartMarker $StartMarker -EndMarker $EndMarker -NewLine $NewLine
    }

    $resultShape = Get-TomlShape -Content $result
    if ($resultShape.Duplicates.Count -gt 0) {
        throw "Merged TOML contains duplicate entries: $($resultShape.Duplicates -join ', ')"
    }

    return $result
}

function Merge-HooksJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TemplateContent
    )

    $existing = if ([string]::IsNullOrWhiteSpace($ExistingContent)) {
        [pscustomobject]@{ hooks = [pscustomobject]@{} }
    } else {
        $ExistingContent | ConvertFrom-Json -ErrorAction Stop
    }

    if ($null -eq $existing.hooks) {
        $existing | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    foreach ($property in @($existing.hooks.PSObject.Properties)) {
        $filtered = @($property.Value | Where-Object {
            ($_ | ConvertTo-Json -Depth 20 -Compress) -notmatch 'crlf-updated-files\.ps1'
        })
        $existing.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $filtered -Force
    }

    $template = $TemplateContent | ConvertFrom-Json -ErrorAction Stop
    foreach ($property in @($template.hooks.PSObject.Properties)) {
        $current = @()
        if ($existing.hooks.PSObject.Properties.Name -contains $property.Name) {
            $current = @($existing.hooks.PSObject.Properties[$property.Name].Value)
        }
        $combined = @($current) + @($property.Value)
        $existing.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $combined -Force
    }

    return ($existing | ConvertTo-Json -Depth 30)
}

function Remove-ManagedHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ''
    }

    $object = $Content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $object.hooks) {
        return $Content
    }

    foreach ($property in @($object.hooks.PSObject.Properties)) {
        $filtered = @($property.Value | Where-Object {
            ($_ | ConvertTo-Json -Depth 20 -Compress) -notmatch 'crlf-updated-files\.ps1'
        })
        $object.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $filtered -Force
    }

    return ($object | ConvertTo-Json -Depth 30)
}

function Remove-CcusageProfileBlocks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $result = Remove-ManagedBlock -Content $Content -StartMarker $script:CsStartMarker -EndMarker $script:CsEndMarker
    $result = Remove-ManagedBlock -Content $result -StartMarker $script:CdailyStartMarker -EndMarker $script:CdailyEndMarker
    return $result
}

function Get-CcusageState {
    [CmdletBinding()]
    param()

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Installed = $false; Version = $null }
    }

    $output = & npm list --global ccusage --depth=0 --json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($output | Out-String))) {
        return [pscustomobject]@{ Installed = $false; Version = $null }
    }

    try {
        $data = ($output | Out-String) | ConvertFrom-Json -ErrorAction Stop
        $version = [string]$data.dependencies.ccusage.version
        return [pscustomobject]@{
            Installed = -not [string]::IsNullOrWhiteSpace($version)
            Version = if ([string]::IsNullOrWhiteSpace($version)) { $null } else { $version }
        }
    } catch {
        return [pscustomobject]@{ Installed = $false; Version = $null }
    }
}

function Restore-CcusageState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw 'npm is required to restore the ccusage package state.'
    }

    if ([bool]$State.Installed) {
        if ([string]::IsNullOrWhiteSpace([string]$State.Version)) {
            throw 'The previous ccusage version is missing.'
        }
        & npm install --global ("ccusage@{0}" -f [string]$State.Version)
    } else {
        & npm uninstall --global ccusage
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to restore the ccusage package state. npm exit code: $LASTEXITCODE"
    }
}

function Test-DirectoryWritable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $testPath = Join-Path $Path ('.codex-settings-write-test-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($testPath, 'test', (New-Object Text.UTF8Encoding($false)))
    } finally {
        Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
    }
}

function New-FileTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    return [pscustomobject]@{
        Root = $Root
        Entries = New-Object 'System.Collections.Generic.List[object]'
        Seen = @{}
    }
}

function Save-TransactionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Transaction,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($Transaction.Seen.ContainsKey($fullPath)) {
        return
    }

    $Transaction.Seen[$fullPath] = $true
    $hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath))
    $name = ([BitConverter]::ToString($hashBytes)).Replace('-', '')
    $backupPath = Join-Path $Transaction.Root ('files\' + $name)
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf

    if ($exists) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
        Copy-Item -LiteralPath $fullPath -Destination $backupPath -Force
    }

    [void]$Transaction.Entries.Add([pscustomobject]@{
        Path = $fullPath
        Existed = $exists
        BackupPath = if ($exists) { $backupPath } else { $null }
    })
}

function Undo-FileTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)

    for ($index = $Transaction.Entries.Count - 1; $index -ge 0; $index--) {
        $entry = $Transaction.Entries[$index]
        if ([bool]$entry.Existed) {
            New-Item -ItemType Directory -Path (Split-Path -Parent ([string]$entry.Path)) -Force | Out-Null
            Copy-Item -LiteralPath ([string]$entry.BackupPath) -Destination ([string]$entry.Path) -Force
        } else {
            Remove-Item -LiteralPath ([string]$entry.Path) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-TransactionMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Transaction,
        [Parameter(Mandatory = $true)][hashtable]$Metadata
    )

    $payload = [ordered]@{
        Version = 2
        CreatedAt = (Get-Date).ToString('o')
        Files = @($Transaction.Entries)
    }
    foreach ($key in $Metadata.Keys) {
        $payload[$key] = $Metadata[$key]
    }

    $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Transaction.Root 'backup-meta.json') -Encoding UTF8
}
