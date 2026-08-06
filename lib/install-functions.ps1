function Select-Mode {
    Write-Host ''
    Write-Host 'Codex Settings 一鍵安裝器'
    Write-Host '========================='
    Write-Host '安裝與更新'
    Write-Host '[1] 全域設定：Codex、MCP、ccusage 指令'
    Write-Host '專案開發環境（會合併通用與專屬 AGENTS.md 規則）'
    Write-Host '[2] Git 專案設定'
    Write-Host '[3] CVS 專案設定'
    Write-Host '[4] 更新：全域設定與已登記專案'
    Write-Host ''
    Write-Host '備份與管理'
    Write-Host '[5] 備份目前設定'
    Write-Host '[6] 還原備份'
    Write-Host '[7] 移除受管理設定'
    Write-Host '[0] 結束'

    switch (Read-Host '請選擇') {
        '1' { return 'Global' }
        '2' { return 'Git' }
        '3' { return 'CVS' }
        '4' { return 'Update' }
        '5' { return 'Backup' }
        '6' { return 'Restore' }
        '7' { return 'Uninstall' }
        '0' { return 'Exit' }
        default { throw '選項無效。' }
    }
}

function Select-InstallStyle {
    Write-Host ''
    Write-Host '安裝方式'
    Write-Host '[1] 安全合併（預設、建議）：保留未受管理的既有內容'
    Write-Host '[2] 完整覆蓋：以範本取代目標檔案'

    switch (Read-Host '請選擇 [1]') {
        '' { return 'Merge' }
        '1' { return 'Merge' }
        '2' { return 'Replace' }
        default { throw '安裝方式無效。' }
    }
}

function Select-OptionalGlobalSkill {
    Write-Host ''
    Write-Host '選用全域技能：request-execution-optimizer'
    Write-Host '預設不安裝；已受管理時會在後續更新中保留。'
    $selection = Read-Host '要安裝嗎？[y/N]'
    return $selection -in @('y', 'Y', 'yes', 'YES')
}

function Select-OptionalDefaultModeRequestUserInput {
    Write-Host ''
    Write-Host '選用功能：預設啟用 request_user_input'
    Write-Host '會在 config.toml 的 [features] 加入 default_mode_request_user_input = true。'
    $selection = Read-Host '要啟用嗎？[y/N]'
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
        Write-Host '已登記專案'
        for ($index = 0; $index -lt $projects.Count; $index++) {
            Write-Host ('[{0}] {1} {2}' -f ($index + 1), $projects[$index].Type, $projects[$index].Path)
        }
        $selection = [string](Read-Host '選擇要更新的專案 ID（以逗號分隔；直接按 Enter 全部更新）')
        if ([string]::IsNullOrWhiteSpace($selection)) {
            foreach ($project in $projects) {
                if ($seen.Add([string]$project.Path)) { [void]$paths.Add([string]$project.Path) }
            }
        } else {
            foreach ($part in ($selection -split '[,\s]+' | Where-Object { $_ })) {
                if ($part -notmatch '^\d+$') { continue }
                $index = [int]$part - 1
                if ($index -ge 0 -and $index -lt $projects.Count -and $seen.Add([string]$projects[$index].Path)) {
                    [void]$paths.Add([string]$projects[$index].Path)
                }
            }
        }
    } else {
        Write-Host '尚未登記任何專案。'
    }

    foreach ($path in Read-ProjectPaths '新增 Git／CVS 專案路徑（以分號分隔；直接按 Enter 略過）') {
        if ($seen.Add($path)) { [void]$paths.Add($path) }
    }
    return $paths.ToArray()
}

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "在 PATH 中找不到 $Name。" }
}

function Test-Prerequisites([string]$InstallMode, [string]$TargetPath) {
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        throw "需要 PowerShell 5.1 或更新版本；目前版本：$($PSVersionTable.PSVersion)"
    }
    if ($InstallMode -eq 'Global' -and $PSVersionTable.PSVersion.Major -lt 7) {
        throw "安裝 ccusage、ccsessions 與 cdaily 需要 PowerShell 7 或更新版本；目前版本：$($PSVersionTable.PSVersion)"
    }

    Test-DirectoryWritable -Path $TargetPath
    if ($InstallMode -ne 'Global') { return }

    foreach ($name in @('codex', 'node', 'npm', 'npx')) { Assert-Command $name }
    $nodeVersion = (& node --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v?(\d+)') {
        throw "無法取得 Node.js 版本。輸出：$nodeVersion"
    }
    if ([int]$matches[1] -lt 20) { throw "需要 Node.js 20 或更新版本；目前版本：$nodeVersion" }

    Test-DirectoryWritable -Path (Split-Path -Parent $PROFILE.CurrentUserAllHosts)

    $configTemplate = Join-Path $ScriptRoot 'templates\global\config.toml'
    $shape = Get-TomlShape -Content ([IO.File]::ReadAllText($configTemplate))
    if ($shape.Duplicates.Count -gt 0) { throw "內建 config.toml 無效：$($shape.Duplicates -join ', ')" }
}

function Resolve-Targets([string]$InstallMode, [string[]]$RequestedPath, [switch]$InstallRequestExecutionOptimizer, [switch]$EnableDefaultModeRequestUserInput) {
    $targets = New-Object 'System.Collections.Generic.List[object]'
    if ($InstallMode -eq 'Global') {
        [void]$targets.Add([pscustomobject]@{ Mode = 'Global'; Template = Join-Path $ScriptRoot 'templates\global'; Root = Join-Path $HOME '.codex'; EnableDefaultModeRequestUserInput = [bool]$EnableDefaultModeRequestUserInput })
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
            else { throw "所選目錄不是 Git 或 CVS 專案根目錄：$root" }
        }
        $marker = if ($mode -eq 'Git') { '.git' } else { 'CVS' }
        if (-not (Test-Path -LiteralPath (Join-Path $root $marker))) { throw "所選目錄不是 $mode 專案根目錄：$root" }
        if (@($targets | Where-Object { [string]::Equals($_.Root, $root, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }

        [void]$targets.Add([pscustomobject]@{
            Mode = $mode
            Template = Join-Path $ScriptRoot ("templates\{0}-project" -f $mode.ToLowerInvariant())
            Root = $root
        })
    }

    if ($targets.Count -eq 0) { throw '需要提供專案路徑。' }
    return $targets.ToArray()
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
        if ($ModeName -in @('Git', 'CVS')) {
            return [pscustomobject]@{ Name = 'managed-block'; Start = '<!-- >>> CODEX-SETTINGS:PROJECT:AGENTS >>> -->'; End = '<!-- <<< CODEX-SETTINGS:PROJECT:AGENTS <<< -->' }
        }
        return [pscustomobject]@{ Name = 'managed-block'; Start = '<!-- >>> CODEX-SETTINGS: >>> -->'; End = '<!-- <<< CODEX-SETTINGS: <<< -->' }
    }
    if ($normalized -eq 'agent.md' -or $normalized.EndsWith('/agent.md')) {
        return [pscustomobject]@{ Name = 'managed-block'; Start = '<!-- >>> CODEX-SETTINGS: >>> -->'; End = '<!-- <<< CODEX-SETTINGS: <<< -->' }
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

function Get-ProjectAgentsTemplateContent($Target, [string]$SourcePath, [string]$RelativePath, [string]$NewLine) {
    $specific = [IO.File]::ReadAllText($SourcePath)
    if ($Target.Mode -notin @('Git', 'CVS') -or $RelativePath.Replace('\', '/') -ne 'AGENTS.md') { return $specific }

    $commonPath = Join-Path $ScriptRoot 'templates\global\AGENTS.md'
    if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) { throw "找不到通用 AGENTS.md 範本：$commonPath" }
    $common = [IO.File]::ReadAllText($commonPath)
    $normalize = { param([string]$Content) [regex]::Replace($Content.Trim(), "`r?`n", $NewLine) }
    return (& $normalize $common) + $NewLine + $NewLine + (& $normalize $specific)
}

function Remove-LegacyProjectAgentsBlocks([string]$Content) {
    $Content = Remove-ManagedBlock -Content $Content -StartMarker '<!-- >>> CODEX-SETTINGS: >>> -->' -EndMarker '<!-- <<< CODEX-SETTINGS: <<< -->'
    foreach ($mode in @('Git', 'CVS')) {
        $Content = Remove-ManagedBlock -Content $Content -StartMarker "<!-- >>> CODEX-SETTINGS:${mode}:AGENTS >>> -->" -EndMarker "<!-- <<< CODEX-SETTINGS:${mode}:AGENTS <<< -->"
    }
    return $Content
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

function Remove-GlobalCrlfHooks([string]$Root, $Transaction) {
    $hooksPath = Join-Path $Root 'hooks.json'
    if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
        $state = Get-TextFileState $hooksPath
        $cleaned = Remove-CrlfHooksJson -Content $state.Content
        if ($cleaned -ne $state.Content) {
            Save-TransactionFile -Transaction $Transaction -Path $hooksPath
            Write-TextFileState -Path $hooksPath -Content $cleaned -Encoding $state.Encoding
        }
    }

    $legacyScript = Join-Path $Root 'hooks\crlf-updated-files.ps1'
    if (Test-Path -LiteralPath $legacyScript -PathType Leaf) {
        Save-TransactionFile -Transaction $Transaction -Path $legacyScript
        Remove-Item -LiteralPath $legacyScript -Force
    }
}

function Remove-LegacyCrlfState([string]$ProjectRoot, $Transaction) {
    $normalizedRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $rootHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalizedRoot)))).Replace('-', '').Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
    $stateBase = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'CodexSettings\HookState' } else { Join-Path ([IO.Path]::GetTempPath()) 'CodexSettings-HookState' }
    foreach ($legacyState in @(
        (Join-Path $stateBase ("crlf-$rootHash.json")),
        (Join-Path $stateBase ("crlf-$rootHash.txt"))
    )) {
        if (Test-Path -LiteralPath $legacyState -PathType Leaf) {
            Save-TransactionFile -Transaction $Transaction -Path $legacyState
            Remove-Item -LiteralPath $legacyState -Force
        }
    }
}

function Assert-CrlfHookInstallation([string]$Mode, [string]$Root) {
    $hooksPath = if ($Mode -eq 'CVS') { Join-Path $Root '.codex\hooks.json' } else { Join-Path $Root 'hooks.json' }
    $content = if (Test-Path -LiteralPath $hooksPath -PathType Leaf) { [IO.File]::ReadAllText($hooksPath) } else { '' }
    $counts = Get-CrlfHookCounts -Content $content

    if ($Mode -eq 'Global') {
        $scriptCount = if (Test-Path -LiteralPath (Join-Path $Root 'hooks\crlf-updated-files.ps1') -PathType Leaf) { 1 } else { 0 }
        Write-Host "GlobalCRLFHookCount=$($counts.Total)"
        if ($counts.Total -ne 0 -or $scriptCount -ne 0) { throw 'Global CRLF hook cleanup self-check failed.' }
        return
    }

    if ($Mode -eq 'CVS') {
        $scriptCount = if (Test-Path -LiteralPath (Join-Path $Root '.codex\hooks\crlf-updated-files.ps1') -PathType Leaf) { 1 } else { 0 }
        Write-Host "ProjectPostToolUseCRLFHookCount=$($counts.PostToolUse)"
        Write-Host "ProjectStopCRLFHookCount=$($counts.Stop)"
        Write-Host "CRLFScriptCount=$scriptCount"
        if ($counts.PostToolUse -ne 1 -or $counts.Stop -ne 1 -or $scriptCount -ne 1) { throw 'CVS CRLF hook installation self-check failed.' }
    }
}

function Install-Target($Target, $Transaction, [switch]$Force) {
    if (-not (Test-Path -LiteralPath $Target.Template -PathType Container)) { throw "找不到範本：$($Target.Template)" }
    New-Item -ItemType Directory -Path $Target.Root -Force | Out-Null
    if ($Target.Mode -eq 'Global') { Remove-GlobalCrlfHooks -Root $Target.Root -Transaction $Transaction }
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
        $template = Get-ProjectAgentsTemplateContent -Target $Target -SourcePath $source.FullName -RelativePath $relative -NewLine $state.NewLine
        $isOptionalFeatureConfig = $Target.Mode -eq 'Global' -and $relative -eq 'config.toml' -and [bool]$Target.EnableDefaultModeRequestUserInput
        if ($isOptionalFeatureConfig) { $template = Add-DefaultModeRequestUserInputFeature -Content $template -NewLine $state.NewLine }

        if ($Force -and $state.Exists) {
            if ($isOptionalFeatureConfig) { Write-TextFileState -Path $destination -Content $template -Encoding $state.Encoding }
            else { Copy-FileAtomic -Source $source.FullName -Destination $destination }
        } elseif ($strategy.Name -eq 'replace') {
            if ($state.Exists -and -not $owned) {
                $sourceHash = (Get-FileHash $source.FullName -Algorithm SHA256).Hash
                $destinationHash = (Get-FileHash $destination -Algorithm SHA256).Hash
                if ($sourceHash -ne $destinationHash) { throw "拒絕覆寫未受管理的檔案：$destination" }
            }
            if ($isOptionalFeatureConfig) { Write-TextFileState -Path $destination -Content $template -Encoding $state.Encoding }
            else { Copy-FileAtomic -Source $source.FullName -Destination $destination }
        } else {
            $existing = if ($owned -and $null -ne $previous -and [int]$previous.Version -lt 2) { '' } else { $state.Content }
            if ($Target.Mode -in @('Git', 'CVS') -and $relative.Replace('\', '/') -eq 'AGENTS.md') {
                $existing = Remove-LegacyProjectAgentsBlocks $existing
            }
            switch ($strategy.Name) {
                'managed-block' { $merged = Merge-ManagedBlock $existing $template $strategy.Start $strategy.End $state.NewLine }
                'managed-toml' { $merged = Merge-TomlTemplate $existing $template $strategy.Start $strategy.End $state.NewLine }
                'managed-hooks' { $merged = Merge-HooksJson $existing $template }
            }
            if ($isOptionalFeatureConfig) { $merged = Add-DefaultModeRequestUserInputFeature -Content $merged -NewLine $state.NewLine }
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

    if ($Target.Mode -eq 'CVS') { Remove-LegacyCrlfState -ProjectRoot $Target.Root -Transaction $Transaction }
    if ($Target.Mode -in @('Global', 'CVS')) { Assert-CrlfHookInstallation -Mode $Target.Mode -Root $Target.Root }

    return [pscustomobject]@{ Mode = $Target.Mode; Root = $Target.Root; Previous = $previous; Files = $entries.ToArray() }
}

function Set-Context7Key([switch]$Skip, $PreviousManifest) {
    $name = 'CONTEXT7_API_KEY'
    $userBefore = [Environment]::GetEnvironmentVariable($name, 'User')
    $processBefore = [Environment]::GetEnvironmentVariable($name, 'Process')
    $createdNow = $false

    if ([string]::IsNullOrWhiteSpace($userBefore) -and -not $Skip) {
        Write-Host ''
        Write-Host 'Context7 API Key 為選填；設定後可提高使用額度。'
        $secure = Read-Host '輸入 Context7 API Key，或直接按 Enter 略過' -AsSecureString
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
        Write-Host '使用既有的 CONTEXT7_API_KEY。'
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
        Version = 4
        Mode = $Result.Mode
        InstalledAt = (Get-Date).ToString('o')
        TargetRoot = $Result.Root
        Files = $Result.Files
    }
    if ($null -ne $External) { $manifest.External = $External }
    Write-JsonFileAtomic -Path $path -Value $manifest -Depth 14
}
