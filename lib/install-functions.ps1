function Select-Mode {
    Write-Host ''
    Write-Host 'Codex Settings Installer'
    Write-Host '========================'
    Write-Host '[1] Install global settings, MCP, ccusage, cs, and cdaily'
    Write-Host '[2] Install Git project settings'
    Write-Host '[3] Install CVS project settings'
    Write-Host '[4] Backup current settings'
    Write-Host '[5] Restore a backup'
    Write-Host '[6] Update global settings and registered projects'
    Write-Host '[7] Uninstall managed settings'
    Write-Host '[0] Exit'

    switch (Read-Host 'Select') {
        '1' { return 'Global' }
        '2' { return 'Git' }
        '3' { return 'CVS' }
        '4' { & (Join-Path $ScriptRoot 'backup.ps1'); exit $LASTEXITCODE }
        '5' { & (Join-Path $ScriptRoot 'restore.ps1'); exit $LASTEXITCODE }
        '6' { & (Join-Path $ScriptRoot 'update.ps1'); exit $LASTEXITCODE }
        '7' { & (Join-Path $ScriptRoot 'uninstall.ps1'); exit $LASTEXITCODE }
        '0' { exit 0 }
        default { throw 'Invalid selection.' }
    }
}

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "$Name was not found in PATH." }
}

function Test-Prerequisites([string]$InstallMode, [string]$TargetPath) {
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        throw "PowerShell 5.1 or newer is required. Current: $($PSVersionTable.PSVersion)"
    }
    if ($InstallMode -eq 'Global' -and $PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7 or newer is required to install ccusage, cs, and cdaily. Current: $($PSVersionTable.PSVersion)"
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

function Resolve-Targets([string]$InstallMode, [string]$RequestedPath) {
    if ($InstallMode -eq 'Global') {
        return @(
            [pscustomobject]@{ Mode = 'Global'; Template = Join-Path $ScriptRoot 'templates\global'; Root = Join-Path $HOME '.codex' },
            [pscustomobject]@{ Mode = 'GlobalSkills'; Template = Join-Path $ScriptRoot 'templates\user-skills'; Root = Join-Path $HOME '.agents\skills' }
        )
    }

    if ([string]::IsNullOrWhiteSpace($RequestedPath)) { $RequestedPath = Read-Host "Enter the $InstallMode project root" }
    if ([string]::IsNullOrWhiteSpace($RequestedPath)) { throw 'Project path is required.' }
    $root = (Resolve-Path -LiteralPath $RequestedPath).Path
    $marker = if ($InstallMode -eq 'Git') { '.git' } else { 'CVS' }
    if (-not (Test-Path -LiteralPath (Join-Path $root $marker))) { throw "The selected directory is not a $InstallMode project root: $root" }

    return @([pscustomobject]@{
        Mode = $InstallMode
        Template = Join-Path $ScriptRoot ("templates\{0}-project" -f $InstallMode.ToLowerInvariant())
        Root = $root
    })
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

function Install-Target($Target, $Transaction) {
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
        Save-TransactionFile -Transaction $Transaction -Path $destination

        if ($strategy.Name -eq 'replace') {
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
