function Select-Mode {
    Write-Host ''
    Write-Host 'Codex Settings Installer'
    Write-Host '========================'
    Write-Host '[1] Install global settings, MCP, ccusage, ccsessions, and cdaily'
    Write-Host '[2] Install Git project settings'
    Write-Host '[3] Install CVS project settings'
    Write-Host '[4] Backup current settings'
    Write-Host '[5] Restore a backup'
    Write-Host '[6] Update global settings and registered projects'
    Write-Host '[7] Uninstall managed settings'
    Write-Host '[0] Exit installer'

    switch (Read-Host 'Select') {
        '1' { return 'Global' }
        '2' { return 'Git' }
        '3' { return 'CVS' }
        '4' { return 'Backup' }
        '5' { return 'Restore' }
        '6' { return 'Update' }
        '7' { return 'Uninstall' }
        '0' { return 'Exit' }
        default { throw 'Invalid selection.' }
    }
}

function Select-InstallStyle {
    Write-Host ''
    Write-Host 'Installation style'
    Write-Host '[1] Merge managed settings and preserve other content'
    Write-Host '[2] Replace template files completely'

    switch (Read-Host 'Select') {
        '1' { return 'Merge' }
        '2' { return 'Replace' }
        default { throw 'Invalid installation style.' }
    }
}

function Select-OptionalGlobalSkill {
    Write-Host ''
    Write-Host 'Optional global skill'
    Write-Host 'request-execution-optimizer is not installed by default.'
    $selection = Read-Host 'Install request-execution-optimizer? [y/N]'
    return $selection -in @('y', 'Y', 'yes', 'YES')
}

function Read-ProjectPaths([string]$Prompt) {
    $value = [string](Read-Host $Prompt)
    if ([string]::IsNullOrWhiteSpace($value)) { return @() }
    return @($value -split ';' | ForEach-Object Trim | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Select-GlobalProjectPaths {
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $projects = @(Get-RegisteredCodexProjects)

    if ($projects.Count -gt 0) {
        Write-Host ''
        Write-Host 'Registered projects'
        for ($index = 0; $index -lt $projects.Count; $index++) {
            Write-Host ('[{0}] {1} {2}' -f ($index + 1), $projects[$index].Type, $projects[$index].Path)
        }
        $selection = [string](Read-Host 'Install registered projects (IDs separated by commas, blank to skip)')
        foreach ($part in ($selection -split '[,\s]+' | Where-Object { $_ })) {
            if ($part -notmatch '^\d+$') { continue }
            $index = [int]$part - 1
            if ($index -ge 0 -and $index -lt $projects.Count -and $seen.Add([string]$projects[$index].Path)) {
                [void]$paths.Add([string]$projects[$index].Path)
            }
        }
    } else {
        Write-Host 'No registered projects.'
    }

    foreach ($path in Read-ProjectPaths 'Add Git/CVS project paths (semicolon separated, blank to skip)') {
        if ($seen.Add($path)) { [void]$paths.Add($path) }
    }
    return $paths.ToArray()
}

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "$Name was not found in PATH." }
}

function Test-Prerequisites([string]$InstallMode, [string]$TargetPath) {
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        throw "PowerShell 5.1 or newer is required. Current: $($PSVersionTable.PSVersion)"
    }
    if ($InstallMode -eq 'Global' -and $PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7 or newer is required to install ccusage, ccsessions, and cdaily. Current: $($PSVersionTable.PSVersion)"
    }

    Test-DirectoryWritable -Path $TargetPath
    if ($InstallMode -ne 'Global') { return }

    foreach ($name in @('codex', 'node', 'npm', 'npx')) { Assert-Command $name }
    $nodeVersion = (& node --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v?(\d+)') {
        throw "Unable to determine Node.js version. Output: $nodeVersion"
    }
    if ([int]$matches[1] -lt 20) { throw "Node.js 20 or newer is required. Current: $nodeVersion" }

    $registry = & npm view ccusage version --silent 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($registry | Out-String))) {
        throw "Unable to reach npm or resolve ccusage@latest.`n$($registry | Out-String)"
    }
    Test-DirectoryWritable -Path (Split-Path -Parent $PROFILE.CurrentUserAllHosts)

    $configTemplate = Join-Path $ScriptRoot 'templates\global\config.toml'
    $shape = Get-TomlShape -Content ([IO.File]::ReadAllText($configTemplate))
    if ($shape.Duplicates.Count -gt 0) { throw "Bundled config.toml is invalid: $($shape.Duplicates -join ', ')" }
}

function Resolve-Targets([string]$InstallMode, [string[]]$RequestedPath, [switch]$InstallRequestExecutionOptimizer) {
    $targets = New-Object 'System.Collections.Generic.List[object]'
    if ($InstallMode -eq 'Global') {
        [void]$targets.Add([pscustomobject]@{ Mode = 'Global'; Template = Join-Path $ScriptRoot 'templates\global'; Root = Join-Path $HOME '.codex' })
        $skillsRoot = Join-Path $HOME '.codex\skills'
        $skillManifest = Join-Path $skillsRoot '.codex-settings-manifest.json'
        if ($InstallRequestExecutionOptimizer -or (Test-Path -LiteralPath $skillManifest -PathType Leaf)) {
            [void]$targets.Add([pscustomobject]@{ Mode = 'GlobalSkills'; Template = Join-Path $ScriptRoot 'templates\user-skills'; Root = $skillsRoot })
        }
    } elseif ($RequestedPath.Count -eq 0) {
        $RequestedPath = @(Read-ProjectPaths "Enter $InstallMode project paths (semicolon separated)")
    }

    foreach ($path in @($RequestedPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $root = (Resolve-Path -LiteralPath $path).Path
        $mode = $InstallMode
        if ($mode -eq 'Global') {
            if (Test-Path -LiteralPath (Join-Path $root '.git')) { $mode = 'Git' }
            elseif (Test-Path -LiteralPath (Join-Path $root 'CVS')) { $mode = 'CVS' }
            else { throw "The selected directory is not a Git or CVS project root: $root" }
        }
        $marker = if ($mode -eq 'Git') { '.git' } else { 'CVS' }
        if (-not (Test-Path -LiteralPath (Join-Path $root $marker))) { throw "The selected directory is not a $mode project root: $root" }
        if (@($targets | Where-Object { [string]::Equals($_.Root, $root, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }

        [void]$targets.Add([pscustomobject]@{
            Mode = $mode
            Template = Join-Path $ScriptRoot ("templates\{0}-project" -f $mode.ToLowerInvariant())
            Root = $root
        })
    }

    if ($targets.Count -eq 0) { throw 'Project path is required.' }
    return $targets.ToArray()
}

function Get-Manifest([string]$Root) {
    $path = Join-Path $Root '.codex-settings-manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid managed manifest: $path`n$($_.Exception.Message)" }
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
        return [pscustomobject]@{ Name = 'managed-block'; Start = "<!-- >>> CODEX-SETTINGS:$ModeName:AGENTS >>> -->"; End = "<!-- <<< CODEX-SETTINGS:$ModeName:AGENTS <<< -->" }
    }
    if ($normalized -eq 'config.toml') {
        return [pscustomobject]@{ Name = 'managed-toml'; Start = "# >>> CODEX-SETTINGS:$ModeName:CONFIG >>>"; End = "# <<< CODEX-SETTINGS:$ModeName:CONFIG <<<" }
    }
    if ($normalized -eq 'rules/default.rules' -or $normalized.EndsWith('/rules/default.rules')) {
        return [pscustomobject]@{ Name = 'managed-block'; Start = "# >>> CODEX-SETTINGS:$ModeName:RULES >>>"; End = "# <<< CODEX-SETTINGS:$ModeName:RULES <<<" }
    }
    if ($normalized.EndsWith('/hooks.json')) { return [pscustomobject]@{ Name = 'managed-hooks'; Start = $null; End = $null } }
    return [pscustomobject]@{ Name = 'replace'; Start = $null; End = $null }
}

function Update-GitIgnore([string]$Root, $Transaction, [string[]]$ManagedPaths) {
    $ignorePath = Join-Path $Root '.gitignore'
    $state = Get-TextFileState $ignorePath
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($managedPath in @($ManagedPaths)) {
        if ([string]::IsNullOrWhiteSpace($managedPath)) { continue }
        $rule = '/' + $managedPath.Replace('\', '/').TrimStart('/')
        if ($rule -ne '/.gitignore' -and $seen.Add($rule)) { [void]$paths.Add($rule) }
    }
    if ($paths.Count -eq 0) { return }

    $existingRules = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in ($state.Content -split "`r?`n")) { [void]$existingRules.Add($line.Trim()) }
    $missingRules = @($paths | Where-Object { -not $existingRules.Contains($_) })
    if ($missingRules.Count -eq 0) { return }

    Save-TransactionFile -Transaction $Transaction -Path $ignorePath
    $header = '# Files managed locally by codex-settings'
    $addition = if ($existingRules.Contains($header)) { $missingRules -join $state.NewLine } else { $header + $state.NewLine + ($missingRules -join $state.NewLine) }
    $content = if ([string]::IsNullOrWhiteSpace($state.Content)) {
        $addition + $state.NewLine
    } else {
        $state.Content.TrimEnd() + $state.NewLine + $state.NewLine + $addition + $state.NewLine
    }
    Write-TextFileState -Path $ignorePath -Content $content -Encoding $state.Encoding
}

function Install-Target($Target, $Transaction, [switch]$Force) {
    if (-not (Test-Path -LiteralPath $Target.Template -PathType Container)) { throw "Template missing: $($Target.Template)" }
    New-Item -ItemType Directory -Path $Target.Root -Force | Out-Null
    $previous = Get-Manifest $Target.Root
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $templatePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($source in Get-ChildItem -LiteralPath $Target.Template -Recurse -File) {
        $relative = $source.FullName.Substring($Target.Template.Length).TrimStart([char[]]'\/')
        [void]$templatePaths.Add($relative)
        $destination = Join-Path $Target.Root $relative
        $previousEntry = Get-ManifestEntry $previous $relative
        $owned = Test-Owned $previousEntry $destination
        $state = Get-TextFileState $destination
        $strategy = Get-Strategy $Target.Mode $relative
        $beforeHash = if ($state.Exists) { (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash } else { $null }
        Save-TransactionFile -Transaction $Transaction -Path $destination

        if ($Force -and $state.Exists) {
            Copy-FileAtomic -Source $source.FullName -Destination $destination
        } elseif ($strategy.Name -eq 'replace') {
            if ($state.Exists -and -not $owned) {
                $sourceHash = (Get-FileHash $source.FullName -Algorithm SHA256).Hash
                $destinationHash = (Get-FileHash $destination -Algorithm SHA256).Hash
                if ($sourceHash -ne $destinationHash) { throw "Refusing to overwrite an unmanaged file: $destination" }
            }
            Copy-FileAtomic -Source $source.FullName -Destination $destination
        } else {
            $existing = if ($owned -and $null -ne $previous -and [int]$previous.Version -lt 2) { '' } else { $state.Content }
            $template = [IO.File]::ReadAllText($source.FullName)
            switch ($strategy.Name) {
                'managed-block' { $merged = Merge-ManagedBlock $existing $template $strategy.Start $strategy.End $state.NewLine }
                'managed-toml' { $merged = Merge-TomlTemplate $existing $template $strategy.Start $strategy.End $state.NewLine }
                'managed-hooks' { $merged = Merge-HooksJson $existing $template }
            }
            Write-TextFileState $destination $merged $state.Encoding
        }

        [void]$entries.Add([pscustomobject]@{
            Path = $relative
            Strategy = $strategy.Name
            StartMarker = $strategy.Start
            EndMarker = $strategy.End
            ExistedBefore = [bool]$state.Exists
            OriginalEncoding = [string]$state.EncodingName
            OriginalCodePage = [int]$state.CodePage
            Sha256 = (Get-FileHash $destination -Algorithm SHA256).Hash
            Changed = $beforeHash -ne (Get-FileHash $destination -Algorithm SHA256).Hash
        })
    }

    if ($null -ne $previous -and $null -ne $previous.Files) {
        foreach ($old in @($previous.Files)) {
            $oldPath = [string]$old.Path
            if ($templatePaths.Contains($oldPath)) { continue }
            $obsolete = Join-Path $Target.Root $oldPath
            if (Test-Owned $old $obsolete) {
                Save-TransactionFile $Transaction $obsolete
                Remove-Item $obsolete -Force
            }
        }
    }

    if ($Target.Mode -eq 'Git') {
        $managedPaths = @($entries | ForEach-Object Path) + '.codex-settings-manifest.json'
        Update-GitIgnore -Root $Target.Root -Transaction $Transaction -ManagedPaths $managedPaths
    }

    return [pscustomobject]@{ Mode = $Target.Mode; Root = $Target.Root; Previous = $previous; Files = $entries.ToArray() }
}

function Set-Context7Key([switch]$Skip, $PreviousManifest) {
    $name = 'CONTEXT7_API_KEY'
    $userBefore = [Environment]::GetEnvironmentVariable($name, 'User')
    $processBefore = [Environment]::GetEnvironmentVariable($name, 'Process')
    $createdNow = $false

    if ([string]::IsNullOrWhiteSpace($userBefore) -and -not $Skip) {
        Write-Host ''
        Write-Host 'Context7 API key is optional but recommended for higher limits.'
        $secure = Read-Host 'Enter Context7 API key, or press Enter to skip' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if (-not [string]::IsNullOrWhiteSpace($plain)) {
            [Environment]::SetEnvironmentVariable($name, $plain, 'User')
            [Environment]::SetEnvironmentVariable($name, $plain, 'Process')
            $createdNow = $true
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($userBefore)) {
        [Environment]::SetEnvironmentVariable($name, $userBefore, 'Process')
        Write-Host 'Using existing CONTEXT7_API_KEY.'
    }

    $managedBefore = $false
    if ($null -ne $PreviousManifest -and $null -ne $PreviousManifest.External -and $null -ne $PreviousManifest.External.Context7) {
        $managedBefore = [bool]$PreviousManifest.External.Context7.CreatedByInstaller
    }
    return [pscustomobject]@{
        CreatedNow = $createdNow
        CreatedByInstaller = $managedBefore -or $createdNow
        UserBefore = $userBefore
        ProcessBefore = $processBefore
    }
}

function Write-Manifest($Result, $Transaction, $External) {
    $path = Join-Path $Result.Root '.codex-settings-manifest.json'
    Save-TransactionFile $Transaction $path
    $manifest = [ordered]@{
        Version = 3
        Mode = $Result.Mode
        InstalledAt = (Get-Date).ToString('o')
        TargetRoot = $Result.Root
        Files = $Result.Files
    }
    if ($null -ne $External) { $manifest.External = $External }
    Write-JsonFileAtomic -Path $path -Value $manifest -Depth 14
}
