$script:CsStartMarker = '# >>> CS CODEX SESSION VIEWER >>>'
$script:CsEndMarker = '# <<< CS CODEX SESSION VIEWER <<<'
$script:CdailyStartMarker = '# >>> CDAILY CODEX DAILY REPORT >>>'
$script:CdailyEndMarker = '# <<< CDAILY CODEX DAILY REPORT <<<'
$script:CodexSettingsStateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexSettings'

function Write-BytesAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = Join-Path $directory ('.codex-settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                [IO.File]::Replace($temporaryPath, $Path, $null, $true)
            } catch {
                Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
            }
        } else {
            Move-Item -LiteralPath $temporaryPath -Destination $Path
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Copy-FileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Write-BytesAtomic -Path $Destination -Bytes ([IO.File]::ReadAllBytes($Source))
}

function Write-JsonFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 12
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    Write-BytesAtomic -Path $Path -Bytes ((New-Object Text.UTF8Encoding($false)).GetBytes($json))
}

function Get-LegacyTextEncoding {
    [CmdletBinding()]
    param()

    try {
        [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
    } catch {
        # Windows PowerShell already exposes legacy code pages.
    }

    $codePage = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    if ($codePage -in @(0, 65001, 1200, 1201)) {
        throw "The current Windows ANSI code page is not suitable for legacy text detection: $codePage"
    }

    try {
        return [Text.Encoding]::GetEncoding(
            $codePage,
            [Text.EncoderExceptionFallback]::new(),
            [Text.DecoderExceptionFallback]::new()
        )
    } catch {
        throw "Unable to load Windows ANSI code page $codePage. $($_.Exception.Message)"
    }
}

function Get-TextFileState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Content = ''
            Encoding = New-Object Text.UTF8Encoding($false, $true)
            EncodingName = 'utf-8'
            CodePage = 65001
            NewLine = "`r`n"
        }
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    $encoding = $null
    $encodingName = $null

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object Text.UTF8Encoding($true, $true)
        $encodingName = 'utf-8-bom'
        $offset = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object Text.UnicodeEncoding($false, $true, $true)
        $encodingName = 'utf-16-le'
        $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object Text.UnicodeEncoding($true, $true, $true)
        $encodingName = 'utf-16-be'
        $offset = 2
    } else {
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        try {
            [void]$utf8.GetString($bytes)
            $encoding = $utf8
            $encodingName = 'utf-8'
        } catch [Text.DecoderFallbackException] {
            $encoding = Get-LegacyTextEncoding
            $encodingName = "windows-$($encoding.CodePage)"
        }
    }

    try {
        $content = if ($bytes.Length -gt $offset) {
            $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
        } else {
            ''
        }
    } catch [Text.DecoderFallbackException] {
        throw "Unable to decode text file without data loss: $Path. Detected encoding: $encodingName"
    }

    $newLine = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    return [pscustomobject]@{
        Exists = $true
        Content = $content
        Encoding = $encoding
        EncodingName = $encodingName
        CodePage = $encoding.CodePage
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

    try {
        $body = $Encoding.GetBytes($Content)
    } catch [Text.EncoderFallbackException] {
        throw "The updated text cannot be represented by code page $($Encoding.CodePage): $Path"
    }

    $preamble = $Encoding.GetPreamble()
    if ($preamble.Length -gt 0) {
        $bytes = New-Object byte[] ($preamble.Length + $body.Length)
        [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
        [Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    } else {
        $bytes = $body
    }

    Write-BytesAtomic -Path $Path -Bytes $bytes
}

function Protect-LocalSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Local secret backup is supported only on Windows.'
    }
    $secure = ConvertTo-SecureString -String $Value -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $secure
}

function Unprotect-LocalSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProtectedValue)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Local secret restore is supported only on Windows.'
    }
    $secure = ConvertTo-SecureString -String $ProtectedValue
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
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
    if ([string]::IsNullOrWhiteSpace($base)) { return $block + $NewLine }
    return $base.TrimEnd() + $NewLine + $NewLine + $block + $NewLine
}

function Get-MarkdownTopLevelSections {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $matches = [regex]::Matches($Content, '(?m)^#\s+(.+?)\s*\r?$')
    $sections = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 0; $index -lt $matches.Count; $index++) {
        $start = $matches[$index].Index
        $end = if ($index + 1 -lt $matches.Count) { $matches[$index + 1].Index } else { $Content.Length }
        [void]$sections.Add([pscustomobject]@{
            Heading = $matches[$index].Groups[1].Value.Trim()
            Start = $start
            Length = $end - $start
            Content = $Content.Substring($start, $end - $start)
        })
    }
    return $sections.ToArray()
}

function Remove-DuplicateManagedMarkdownSections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ManagedContent
    )

    $managedSections = @{}
    foreach ($section in @(Get-MarkdownTopLevelSections -Content $ManagedContent)) {
        $managedSections[$section.Heading] = $section
    }
    $existingSections = @(Get-MarkdownTopLevelSections -Content $ExistingContent)
    $overlappingHeadings = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($section in $existingSections) {
        if ($managedSections.ContainsKey($section.Heading)) { [void]$overlappingHeadings.Add($section.Heading) }
    }

    $output = [Text.StringBuilder]::new()
    $position = 0
    foreach ($section in $existingSections) {
        if (-not $managedSections.ContainsKey($section.Heading)) { continue }
        $existingNormalized = ($section.Content -replace '\r\n?', "`n").Trim()
        $managedNormalized = ([string]$managedSections[$section.Heading].Content -replace '\r\n?', "`n").Trim()
        if ($overlappingHeadings.Count -lt 2 -and $existingNormalized -ne $managedNormalized) { continue }

        [void]$output.Append($ExistingContent.Substring($position, $section.Start - $position))
        $position = $section.Start + $section.Length
    }
    [void]$output.Append($ExistingContent.Substring($position))
    return $output.ToString().TrimEnd()
}

function Merge-ManagedMarkdownBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ManagedContent,
        [Parameter(Mandatory = $true)][string]$StartMarker,
        [Parameter(Mandatory = $true)][string]$EndMarker,
        [string]$NewLine = "`r`n"
    )

    $base = Remove-ManagedBlock -Content $ExistingContent -StartMarker $StartMarker -EndMarker $EndMarker
    $base = Remove-DuplicateManagedMarkdownSections -ExistingContent $base -ManagedContent $ManagedContent
    return Merge-ManagedBlock -ExistingContent $base -ManagedContent $ManagedContent -StartMarker $StartMarker -EndMarker $EndMarker -NewLine $NewLine
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
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^\[([^\]]+)\]\s*(?:#.*)?$') {
            $currentSection = $matches[1].Trim()
            if (-not $sections.Add($currentSection)) { [void]$duplicates.Add("section:$currentSection") }
            continue
        }
        if ($null -eq $currentSection -and $trimmed -match '^([A-Za-z0-9_.-]+)\s*=') {
            $key = $matches[1]
            if (-not $topLevelKeys.Add($key)) { [void]$duplicates.Add("key:$key") }
        }
    }

    return [pscustomobject]@{ TopLevelKeys = $topLevelKeys; Sections = $sections; Duplicates = $duplicates.ToArray() }
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
                [void]$block.Add($lines[$index]); $index++
            }
            if (-not $ExistingShape.Sections.Contains($sectionName)) {
                foreach ($item in $block) { [void]$output.Add($item) }
                [void]$output.Add('')
            }
            continue
        }
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { [void]$pending.Add($line); $index++; continue }
        if ($trimmed -match '^([A-Za-z0-9_.-]+)\s*=') {
            $key = $matches[1]
            if (-not $ExistingShape.TopLevelKeys.Contains($key)) {
                foreach ($item in $pending) { [void]$output.Add($item) }
                [void]$output.Add($line); [void]$output.Add('')
            }
            $pending.Clear(); $index++; continue
        }
        foreach ($item in $pending) { [void]$output.Add($item) }
        $pending.Clear(); [void]$output.Add($line); $index++
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
    if ($baseShape.Duplicates.Count -gt 0) { throw "Existing TOML contains duplicate entries: $($baseShape.Duplicates -join ', ')" }
    $selected = Select-TomlTemplateContent -TemplateContent $TemplateContent -ExistingShape $baseShape -NewLine $NewLine
    $result = if ([string]::IsNullOrWhiteSpace($selected)) {
        if ([string]::IsNullOrWhiteSpace($base)) { '' } else { $base.TrimEnd() + $NewLine }
    } else {
        Merge-ManagedBlock -ExistingContent $base -ManagedContent $selected -StartMarker $StartMarker -EndMarker $EndMarker -NewLine $NewLine
    }
    $resultShape = Get-TomlShape -Content $result
    if ($resultShape.Duplicates.Count -gt 0) { throw "Merged TOML contains duplicate entries: $($resultShape.Duplicates -join ', ')" }
    return $result
}

$script:ManagedLineEndingHookSignaturePattern = '(?i)((?:crlf-updated-files|normalize-cvs-crlf|preserve-line-endings)\.ps1|Converting updated files? to CRLF|Normalizing updated files to CRLF|Finalizing CRLF normalization|CodexSettings CRLF (?:track|finalize)|Restoring original line endings)'
$script:PreserveLineEndingHookSignaturePattern = '(?i)(preserve-line-endings\.ps1|Restoring original line endings)'
$script:LegacyCrlfHookSignaturePattern = '(?i)((?:crlf-updated-files|normalize-cvs-crlf)\.ps1|Converting updated files? to CRLF|Normalizing updated files to CRLF|Finalizing CRLF normalization|CodexSettings CRLF (?:track|finalize))'
$script:ManagedNotificationHookSignaturePattern = '(?i)(show-codex-notification\.ps1|CodexSettings Windows notification)'
$script:ManagedTokenUsageHookSignaturePattern = '(?i)(show-turn-token-usage\.ps1|CodexSettings turn token usage)'
$script:ManagedGlobalHookSignaturePattern = '(?i)(show-(?:codex-notification|turn-token-usage)\.ps1|CodexSettings (?:Windows notification|turn token usage))'

function Test-ManagedLineEndingHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    return (($Entry | ConvertTo-Json -Depth 20 -Compress) -match $script:ManagedLineEndingHookSignaturePattern)
}

function Test-ManagedGlobalHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    return (($Entry | ConvertTo-Json -Depth 20 -Compress) -match $script:ManagedGlobalHookSignaturePattern)
}

function Test-ManagedNotificationHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    return (($Entry | ConvertTo-Json -Depth 20 -Compress) -match $script:ManagedNotificationHookSignaturePattern)
}

function Remove-ManagedNotificationHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }
    $object = $Content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $object.hooks) { return $Content }
    foreach ($property in @($object.hooks.PSObject.Properties)) {
        $filtered = @($property.Value | Where-Object { -not (Test-ManagedNotificationHookEntry $_) })
        if ($filtered.Count -eq 0) { $object.hooks.PSObject.Properties.Remove($property.Name) }
        else { $object.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $filtered -Force }
    }
    return ($object | ConvertTo-Json -Depth 30)
}

function Test-ManagedTokenUsageHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    return (($Entry | ConvertTo-Json -Depth 20 -Compress) -match $script:ManagedTokenUsageHookSignaturePattern)
}

function Remove-ManagedTokenUsageHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }
    $object = $Content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $object.hooks) { return $Content }
    foreach ($property in @($object.hooks.PSObject.Properties)) {
        $filtered = @($property.Value | Where-Object { -not (Test-ManagedTokenUsageHookEntry $_) })
        if ($filtered.Count -eq 0) { $object.hooks.PSObject.Properties.Remove($property.Name) }
        else { $object.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $filtered -Force }
    }
    return ($object | ConvertTo-Json -Depth 30)
}

function Remove-ManagedLineEndingHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }
    $object = $Content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $object.hooks) { return $Content }
    foreach ($property in @($object.hooks.PSObject.Properties)) {
        $filtered = @($property.Value | Where-Object { -not (Test-ManagedLineEndingHookEntry $_) })
        if ($filtered.Count -eq 0) {
            $object.hooks.PSObject.Properties.Remove($property.Name)
        } else {
            $object.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $filtered -Force
        }
    }
    return ($object | ConvertTo-Json -Depth 30)
}

function Merge-LineEndingHooksJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TemplateContent
    )

    $cleaned = Remove-ManagedLineEndingHooksJson -Content $ExistingContent
    $existing = if ([string]::IsNullOrWhiteSpace($cleaned)) { [pscustomobject]@{ hooks = [pscustomobject]@{} } } else { $cleaned | ConvertFrom-Json -ErrorAction Stop }
    if ($null -eq $existing.hooks) { $existing | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
    $template = $TemplateContent | ConvertFrom-Json -ErrorAction Stop
    foreach ($property in @($template.hooks.PSObject.Properties)) {
        $current = if ($existing.hooks.PSObject.Properties.Name -contains $property.Name) { @($existing.hooks.PSObject.Properties[$property.Name].Value) } else { @() }
        $existing.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue (@($current) + @($property.Value)) -Force
    }
    return ($existing | ConvertTo-Json -Depth 30)
}

function Merge-HooksJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TemplateContent,
        [switch]$RemoveManagedGlobalHooks
    )

    $existing = if ([string]::IsNullOrWhiteSpace($ExistingContent)) { [pscustomobject]@{ hooks = [pscustomobject]@{} } } else { $ExistingContent | ConvertFrom-Json -ErrorAction Stop }
    if ($null -eq $existing.hooks) { $existing | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
    if ($RemoveManagedGlobalHooks) {
        foreach ($property in @($existing.hooks.PSObject.Properties)) {
            $filtered = @($property.Value | Where-Object { -not (Test-ManagedGlobalHookEntry $_) })
            if ($filtered.Count -eq 0) { $existing.hooks.PSObject.Properties.Remove($property.Name) }
            else { $existing.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $filtered -Force }
        }
    }
    $template = $TemplateContent | ConvertFrom-Json -ErrorAction Stop
    foreach ($property in @($template.hooks.PSObject.Properties)) {
        $current = if ($existing.hooks.PSObject.Properties.Name -contains $property.Name) { @($existing.hooks.PSObject.Properties[$property.Name].Value) } else { @() }
        $existing.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue (@($current) + @($property.Value)) -Force
    }
    return ($existing | ConvertTo-Json -Depth 30)
}

function Remove-CcusageProfileBlocks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $result = Remove-ManagedBlock -Content $Content -StartMarker $script:CsStartMarker -EndMarker $script:CsEndMarker
    return Remove-ManagedBlock -Content $result -StartMarker $script:CdailyStartMarker -EndMarker $script:CdailyEndMarker
}

function Get-CcusageState {
    [CmdletBinding()]
    param()

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ Installed = $false; Version = $null } }
    $output = & npm list --global ccusage --depth=0 --json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($output | Out-String))) { return [pscustomobject]@{ Installed = $false; Version = $null } }
    try {
        $data = ($output | Out-String) | ConvertFrom-Json -ErrorAction Stop
        $version = [string]$data.dependencies.ccusage.version
        return [pscustomobject]@{ Installed = -not [string]::IsNullOrWhiteSpace($version); Version = if ([string]::IsNullOrWhiteSpace($version)) { $null } else { $version } }
    } catch { return [pscustomobject]@{ Installed = $false; Version = $null } }
}

function Restore-CcusageState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { throw 'npm is required to restore the ccusage package state.' }
    if ([bool]$State.Installed) {
        if ([string]::IsNullOrWhiteSpace([string]$State.Version)) { throw 'The previous ccusage version is missing.' }
        & npm install --global ("ccusage@{0}" -f [string]$State.Version)
    } else {
        & npm uninstall --global ccusage
    }
    if ($LASTEXITCODE -ne 0) { throw "Unable to restore the ccusage package state. npm exit code: $LASTEXITCODE" }
}

function Test-DirectoryWritable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $testPath = Join-Path $Path ('.codex-settings-write-test-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($testPath, 'test', (New-Object Text.UTF8Encoding($false))) }
    finally { Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue }
}

function Enter-CodexSettingsLock {
    [CmdletBinding()]
    param([string]$Name = 'settings')

    New-Item -ItemType Directory -Path $script:CodexSettingsStateRoot -Force | Out-Null
    $path = Join-Path $script:CodexSettingsStateRoot ("$Name.lock")
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $stream = New-Object IO.FileStream($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $payload = [ordered]@{
                ProcessId = $PID
                ProcessStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
                CreatedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress
            $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($payload)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            return [pscustomobject]@{ Path = $path; Stream = $stream }
        } catch [IO.IOException] {
            $active = $true
            try {
                $existing = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $process = Get-Process -Id ([int]$existing.ProcessId) -ErrorAction SilentlyContinue
                $active = $null -ne $process -and $process.StartTime.ToUniversalTime().ToString('o') -eq [string]$existing.ProcessStartUtc
            } catch { $active = $true }
            if ($active) { throw "Another codex-settings operation is running. Lock: $path" }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
    throw "Unable to acquire codex-settings lock: $path"
}

function Exit-CodexSettingsLock {
    [CmdletBinding()]
    param($Lock)

    if ($null -eq $Lock) { return }
    try { $Lock.Stream.Dispose() } finally { Remove-Item -LiteralPath $Lock.Path -Force -ErrorAction SilentlyContinue }
}

function New-FileTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Mode = 'Operation'
    )

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $transaction = [pscustomobject]@{
        Root = $Root
        CreatedAt = (Get-Date).ToString('o')
        Entries = New-Object 'System.Collections.Generic.List[object]'
        Seen = @{}
        Metadata = [ordered]@{ Mode = $Mode; Status = 'InProgress' }
    }
    Save-TransactionMetadata -Transaction $transaction -Metadata @{}
    return $transaction
}

function Save-TransactionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Transaction,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($Transaction.Seen.ContainsKey($fullPath)) { return }
    $Transaction.Seen[$fullPath] = $true
    $hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath))
    $name = ([BitConverter]::ToString($hashBytes)).Replace('-', '')
    $backupPath = Join-Path $Transaction.Root ('files\' + $name)
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    if ($exists) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
        Copy-FileAtomic -Source $fullPath -Destination $backupPath
    }
    [void]$Transaction.Entries.Add([pscustomobject]@{ Path = $fullPath; Existed = $exists; BackupPath = if ($exists) { $backupPath } else { $null } })
    Save-TransactionMetadata -Transaction $Transaction -Metadata @{}
}

function Undo-FileTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)

    for ($index = $Transaction.Entries.Count - 1; $index -ge 0; $index--) {
        $entry = $Transaction.Entries[$index]
        if ([bool]$entry.Existed) {
            Copy-FileAtomic -Source ([string]$entry.BackupPath) -Destination ([string]$entry.Path)
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

    foreach ($key in $Metadata.Keys) { $Transaction.Metadata[$key] = $Metadata[$key] }
    $payload = [ordered]@{
        Version = 3
        CreatedAt = $Transaction.CreatedAt
        UpdatedAt = (Get-Date).ToString('o')
        Files = $Transaction.Entries.ToArray()
    }
    foreach ($key in $Transaction.Metadata.Keys) { $payload[$key] = $Transaction.Metadata[$key] }
    Write-JsonFileAtomic -Path (Join-Path $Transaction.Root 'backup-meta.json') -Value $payload -Depth 14
}

function Complete-FileTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)

    Save-TransactionMetadata -Transaction $Transaction -Metadata @{ Status = 'Completed'; CompletedAt = (Get-Date).ToString('o') }
}

function Restore-ExternalTransactionState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Metadata)

    if ($Metadata.PSObject.Properties.Name -contains 'CcusageBefore' -and $null -ne $Metadata.CcusageBefore) {
        Restore-CcusageState -State $Metadata.CcusageBefore
    }

    if ($Metadata.PSObject.Properties.Name -contains 'Context7Before' -and $null -ne $Metadata.Context7Before) {
        if ([bool]$Metadata.Context7Before.WasPresent) {
            $value = Unprotect-LocalSecret -ProtectedValue ([string]$Metadata.Context7Before.ProtectedValue)
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $value, 'User')
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $value, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'User')
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'Process')
        }
    } elseif (($Metadata.PSObject.Properties.Name -contains 'Context7InstallerMayCreate') -and [bool]$Metadata.Context7InstallerMayCreate -and
        (-not [bool]$Metadata.Context7KeyWasPresent)) {
        [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'User')
        [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'Process')
    }
}

function Repair-PendingTransactions {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupRoot)

    $recovered = New-Object 'System.Collections.Generic.List[string]'
    foreach ($directory in @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue)) {
        $metadataPath = Join-Path $directory.FullName 'backup-meta.json'
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { continue }
        try { $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }
        if ([string]$metadata.Status -ne 'InProgress' -or $null -eq $metadata.Files) { continue }

        for ($index = @($metadata.Files).Count - 1; $index -ge 0; $index--) {
            $entry = @($metadata.Files)[$index]
            if ([bool]$entry.Existed) {
                if (-not (Test-Path -LiteralPath ([string]$entry.BackupPath) -PathType Leaf)) {
                    throw "Pending transaction backup is missing: $($entry.BackupPath)"
                }
                Copy-FileAtomic -Source ([string]$entry.BackupPath) -Destination ([string]$entry.Path)
            } else {
                Remove-Item -LiteralPath ([string]$entry.Path) -Force -ErrorAction SilentlyContinue
            }
        }
        Restore-ExternalTransactionState -Metadata $metadata
        $metadata.Status = 'Recovered'
        $metadata | Add-Member -NotePropertyName RecoveredAt -NotePropertyValue (Get-Date).ToString('o') -Force
        Write-JsonFileAtomic -Path $metadataPath -Value $metadata -Depth 14
        [void]$recovered.Add($directory.FullName)
    }
    return $recovered.ToArray()
}
