function Resolve-GlobalTargets([ValidateSet('Git', 'CVS')][string]$DevelopmentEnvironment, [switch]$InstallRequestExecutionOptimizer, [switch]$EnableDefaultModeRequestUserInput, [bool]$InstallWindowsNotifications, [bool]$InstallTokenUsageInterface) {
    $targets = New-Object 'System.Collections.Generic.List[object]'
    [void]$targets.Add([pscustomobject]@{
        Mode = 'Global'
        Template = Join-Path $ScriptRoot 'templates\core'
        EnvironmentTemplate = Join-Path $ScriptRoot ("templates\environments\{0}" -f $DevelopmentEnvironment.ToLowerInvariant())
        DevelopmentEnvironment = $DevelopmentEnvironment
        Root = Join-Path $HOME '.codex'
        EnableDefaultModeRequestUserInput = [bool]$EnableDefaultModeRequestUserInput
        InstallWindowsNotifications = $InstallWindowsNotifications
        InstallTokenUsageInterface = $InstallTokenUsageInterface
    })
    $skillsRoot = Join-Path $HOME '.codex\skills'
    $skillManifest = Join-Path $skillsRoot '.codex-settings-manifest.json'
    if ($InstallRequestExecutionOptimizer -or (Test-Path -LiteralPath $skillManifest -PathType Leaf)) {
        [void]$targets.Add([pscustomobject]@{ Mode = 'GlobalSkills'; Template = Join-Path $ScriptRoot 'templates\skills'; Root = $skillsRoot })
    }
    return $targets.ToArray()
}

function Get-InstallTemplateEntries($Target) {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $globalPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($source in Get-ChildItem -LiteralPath $Target.Template -Recurse -File) {
        $relative = $source.FullName.Substring($Target.Template.Length).TrimStart([char[]]'\/')
        if ($Target.Mode -eq 'Global' -and -not [bool]$Target.InstallWindowsNotifications -and $relative.Replace('\', '/') -eq 'hooks/show-codex-notification.ps1') { continue }
        if ($Target.Mode -eq 'Global' -and -not [bool]$Target.InstallTokenUsageInterface -and $relative.Replace('\', '/') -eq 'hooks/show-turn-token-usage.ps1') { continue }
        [void]$globalPaths.Add($relative)
        $content = [IO.File]::ReadAllText($source.FullName)
        if ($Target.Mode -eq 'Global') {
            if (-not [bool]$Target.InstallWindowsNotifications -and $relative.Replace('\', '/') -eq 'hooks.json') {
                $content = Remove-ManagedNotificationHooksJson -Content $content
            }
            if (-not [bool]$Target.InstallTokenUsageInterface -and $relative.Replace('\', '/') -eq 'hooks.json') {
                $content = Remove-ManagedTokenUsageHooksJson -Content $content
            }
            $environmentSource = Join-Path $Target.EnvironmentTemplate $relative
            if (Test-Path -LiteralPath $environmentSource -PathType Leaf) {
                if ($relative.Replace('\', '/') -eq 'hooks.json') {
                    $content = Merge-HooksJson -ExistingContent $content -TemplateContent ([IO.File]::ReadAllText($environmentSource))
                } else {
                    $content = $content.TrimEnd() + "`r`n`r`n" + [IO.File]::ReadAllText($environmentSource).Trim()
                }
            }
        }
        [void]$entries.Add([pscustomobject]@{ RelativePath = $relative; Content = $content })
    }

    if ($Target.Mode -eq 'Global') {
        foreach ($source in Get-ChildItem -LiteralPath $Target.EnvironmentTemplate -Recurse -File) {
            $relative = $source.FullName.Substring($Target.EnvironmentTemplate.Length).TrimStart([char[]]'\/')
            if ($globalPaths.Contains($relative)) { continue }
            [void]$entries.Add([pscustomobject]@{ RelativePath = $relative; Content = [IO.File]::ReadAllText($source.FullName) })
        }
    }
    return $entries.ToArray()
}

function Get-Manifest([string]$Root) {
    $path = Join-Path $Root '.codex-settings-manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "受管理設定資訊檔無效：$path`n$($_.Exception.Message)" }
}

function Get-ManifestEntry($Manifest, [string]$Path) {
    if ($null -eq $Manifest -or $null -eq $Manifest.Files) { return $null }
    return @($Manifest.Files | Where-Object { [string]$_.Path -eq $Path } | Select-Object -First 1)[0]
}

function Test-Owned($Entry, [string]$Path) {
    if ($null -eq $Entry -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $hash = [string]$Entry.Sha256
    return -not [string]::IsNullOrWhiteSpace($hash) -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $hash
}

function Get-Strategy([string]$ModeName, [string]$RelativePath) {
    $normalized = $RelativePath.Replace('\', '/')
    if ($normalized -eq 'AGENTS.md' -or $normalized.EndsWith('/AGENTS.md')) {
        return [pscustomobject]@{ Name = 'managed-block'; Start = '<!-- >>> CODEX-SETTINGS: >>> -->'; End = '<!-- <<< CODEX-SETTINGS: <<< -->' }
    }
    if ($normalized -eq 'config.toml') {
        return [pscustomobject]@{ Name = 'managed-toml'; Start = "# >>> CODEX-SETTINGS:${ModeName}:CONFIG >>>"; End = "# <<< CODEX-SETTINGS:${ModeName}:CONFIG <<<" }
    }
    if ($normalized -eq 'rules/default.rules' -or $normalized.EndsWith('/rules/default.rules')) {
        return [pscustomobject]@{ Name = 'managed-block'; Start = "# >>> CODEX-SETTINGS:${ModeName}:RULES >>>"; End = "# <<< CODEX-SETTINGS:${ModeName}:RULES <<<" }
    }
    if ($normalized -eq 'hooks.json' -or $normalized.EndsWith('/hooks.json')) {
        return [pscustomobject]@{ Name = 'managed-hooks'; Start = $null; End = $null }
    }
    return [pscustomobject]@{ Name = 'replace'; Start = $null; End = $null }
}

function Remove-LegacyDefaultRulesContent([string]$ExistingContent, [string]$NewLine) {
    $cleaned = $ExistingContent -replace "`r`n|`r", "`n"
    $cleaned = Remove-ManagedBlock -Content $cleaned -StartMarker '# >>> CODEX-SETTINGS: >>>' -EndMarker '# <<< CODEX-SETTINGS: <<<'
    $templatePaths = @(
        (Join-Path $ScriptRoot 'templates\core\rules\default.rules'),
        (Join-Path $ScriptRoot 'templates\environments\git\rules\default.rules'),
        (Join-Path $ScriptRoot 'templates\environments\cvs\rules\default.rules')
    )
    foreach ($templatePath in $templatePaths) {
        $managedContent = ([IO.File]::ReadAllText($templatePath) -replace "`r`n|`r", "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($managedContent)) { continue }

        $cleaned = $cleaned.Replace($managedContent, '')
        $title = @($managedContent -split "`n", 2)[0]
        $cleaned = [regex]::Replace($cleaned, '(?m)^\s*' + [regex]::Escape($title) + '\s*\n?', '')
        foreach ($section in [regex]::Matches($managedContent, '(?ms)^# \d+\.[^\n]*\nprefix_rule\(\n.*?^\)')) {
            $cleaned = $cleaned.Replace($section.Value.Trim(), '')
        }
    }
    return ($cleaned.Trim() -replace "`n", $NewLine)
}

function Add-DefaultModeRequestUserInputFeature([string]$Content, [string]$NewLine) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($Content -split '\r?\n')) { [void]$lines.Add($line) }
    $featureIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -eq '[features]') { $featureIndex = $index; break }
    }
    if ($featureIndex -ge 0) {
        for ($index = $featureIndex + 1; $index -lt $lines.Count; $index++) {
            $trimmed = $lines[$index].Trim()
            if ($trimmed -match '^\[') { break }
            if ($trimmed -match '^default_mode_request_user_input\s*=') { return $Content }
        }
        [void]$lines.Insert($featureIndex + 1, 'default_mode_request_user_input = true')
        return ($lines -join $NewLine)
    }
    return $Content.TrimEnd() + $NewLine + $NewLine + '[features]' + $NewLine + 'default_mode_request_user_input = true'
}
