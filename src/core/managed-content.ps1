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
    $keysBySection = @{}
    $duplicates = New-Object 'System.Collections.Generic.List[string]'
    $currentSection = $null
    $multilineDelimiter = $null

    foreach ($line in ($Content -split '\r?\n')) {
        if ($null -ne $multilineDelimiter) {
            if ($line.Contains($multilineDelimiter)) { $multilineDelimiter = $null }
            continue
        }
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^[A-Za-z0-9_.-]+\s*=\s*(?<delimiter>"""|'''')') {
            $delimiter = $matches.delimiter
            $remainder = $trimmed.Substring($trimmed.IndexOf($delimiter) + 3)
            if (-not $remainder.Contains($delimiter)) { $multilineDelimiter = $delimiter }
        }
        if ($trimmed -match '^\[([^\]]+)\]\s*(?:#.*)?$') {
            $currentSection = $matches[1].Trim()
            if (-not $sections.Add($currentSection)) { [void]$duplicates.Add("section:$currentSection") }
            continue
        }
        if ($null -eq $currentSection -and $trimmed -match '^([A-Za-z0-9_.-]+)\s*=') {
            $key = $matches[1]
            if (-not $topLevelKeys.Add($key)) { [void]$duplicates.Add("key:$key") }
            continue
        }
        if ($trimmed -match '^([A-Za-z0-9_.-]+)\s*=') {
            $key = $matches[1]
            $scope = $currentSection
            if (-not $keysBySection.ContainsKey($scope)) { $keysBySection[$scope] = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
            if (-not $keysBySection[$scope].Add($key)) { [void]$duplicates.Add("key:$scope.$key") }
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
