function Select-Mode {
    Write-Host ''
    Write-Host 'Codex Settings 一鍵安裝器'
    Write-Host '========================='
    Write-Host '[1] 全域安裝／更新：Codex、MCP、技能、ccusage 指令'
    Write-Host ''
    Write-Host '備份與管理'
    Write-Host '[2] 備份目前設定'
    Write-Host '[3] 還原備份'
    Write-Host '[4] 移除受管理設定'
    Write-Host '[0] 結束'

    switch (Read-Host '請選擇') {
        '1' { return 'Global' }
        '2' { return 'Backup' }
        '3' { return 'Restore' }
        '4' { return 'Uninstall' }
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

function Select-OptionalMattPocockSkills {
    Write-Host ''
    Write-Host '選用全域技能：mattpocock/skills'
    Write-Host '會安裝到 Codex 使用者層級，並在下一步由原始安裝器選擇技能。'
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

function Resolve-GlobalTargets([switch]$InstallRequestExecutionOptimizer, [switch]$EnableDefaultModeRequestUserInput) {
    $targets = New-Object 'System.Collections.Generic.List[object]'
    [void]$targets.Add([pscustomobject]@{ Mode = 'Global'; Template = Join-Path $ScriptRoot 'templates\global'; Root = Join-Path $HOME '.codex'; EnableDefaultModeRequestUserInput = [bool]$EnableDefaultModeRequestUserInput })
    $skillsRoot = Join-Path $HOME '.codex\skills'
    $skillManifest = Join-Path $skillsRoot '.codex-settings-manifest.json'
    if ($InstallRequestExecutionOptimizer -or (Test-Path -LiteralPath $skillManifest -PathType Leaf)) {
        [void]$targets.Add([pscustomobject]@{ Mode = 'GlobalSkills'; Template = Join-Path $ScriptRoot 'templates\user-skills'; Root = $skillsRoot })
    }
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

function Assert-GlobalCrlfHookRemoved([string]$Root) {
    $hooksPath = Join-Path $Root 'hooks.json'
    $content = if (Test-Path -LiteralPath $hooksPath -PathType Leaf) { [IO.File]::ReadAllText($hooksPath) } else { '' }
    $counts = Get-CrlfHookCounts -Content $content
    $scriptCount = if (Test-Path -LiteralPath (Join-Path $Root 'hooks\crlf-updated-files.ps1') -PathType Leaf) { 1 } else { 0 }
    if ($counts.Total -ne 0 -or $scriptCount -ne 0) { throw '全域 CRLF Hook 清理檢查失敗。' }
}

function Remove-ObsoleteProjectSettings($Transaction, [string]$RegistryPath) {
    if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
        $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
        if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = $env:LOCALAPPDATA }
        if ([string]::IsNullOrWhiteSpace($localAppData)) { return [pscustomobject]@{ Projects = 0; FilesRemoved = 0; FilesUpdated = 0 } }
        $RegistryPath = Join-Path $localAppData 'CodexSettings\projects.json'
    }
    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        return [pscustomobject]@{ Projects = 0; FilesRemoved = 0; FilesUpdated = 0 }
    }

    try { $registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "舊專案登記清單無效：$RegistryPath`n$($_.Exception.Message)" }

    $projectCount = 0
    $removedCount = 0
    $updatedCount = 0
    foreach ($project in @($registry.Projects)) {
        $root = [string]$project.Path
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $projectCount++
        $manifestPath = Join-Path $root '.codex-settings-manifest.json'
        $manifest = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            try { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop }
            catch { throw "舊專案受管理設定資訊檔無效：$manifestPath`n$($_.Exception.Message)" }
        } else { $null }

        foreach ($entry in @($manifest.Files)) {
            $relativePath = [string]$entry.Path
            if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
            $path = Join-Path $root $relativePath
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            Save-TransactionFile -Transaction $Transaction -Path $path
            $normalizedPath = $relativePath.Replace('\', '/')
            if ($normalizedPath -in @('AGENTS.md', 'agent.md', '.codex/rules/default.rules')) {
                Remove-Item -LiteralPath $path -Force
                $removedCount++
                continue
            }
            $strategy = [string]$entry.Strategy
            if ($strategy -eq 'managed-block') {
                $state = Get-TextFileState -Path $path
                $content = $state.Content
                if (-not [string]::IsNullOrWhiteSpace([string]$entry.StartMarker)) {
                    $content = Remove-ManagedBlock -Content $content -StartMarker ([string]$entry.StartMarker) -EndMarker ([string]$entry.EndMarker)
                }
                if ([string]::IsNullOrWhiteSpace($content)) {
                    Remove-Item -LiteralPath $path -Force
                    $removedCount++
                } else {
                    Write-TextFileState -Path $path -Content ($content.TrimEnd() + $state.NewLine) -Encoding $state.Encoding
                    $updatedCount++
                }
            } elseif ($strategy -eq 'managed-hooks') {
                $state = Get-TextFileState -Path $path
                $content = Remove-ManagedHooksJson -Content $state.Content
                $object = if ([string]::IsNullOrWhiteSpace($content)) { $null } else { $content | ConvertFrom-Json -ErrorAction Stop }
                $hasHooks = $null -ne $object -and $null -ne $object.hooks -and @($object.hooks.PSObject.Properties).Count -gt 0
                if (-not $hasHooks -and -not [bool]$entry.ExistedBefore) {
                    Remove-Item -LiteralPath $path -Force
                    $removedCount++
                } else {
                    Write-TextFileState -Path $path -Content ($content.TrimEnd() + $state.NewLine) -Encoding $state.Encoding
                    $updatedCount++
                }
            } else {
                Remove-Item -LiteralPath $path -Force
                $removedCount++
            }
        }

        $gitIgnorePath = Join-Path $root '.gitignore'
        if (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf) {
            $state = Get-TextFileState -Path $gitIgnorePath
            $managedIgnoreRules = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            [void]$managedIgnoreRules.Add('# Files managed locally by codex-settings')
            [void]$managedIgnoreRules.Add('/.codex-settings-manifest.json')
            foreach ($entry in @($manifest.Files)) {
                $relativePath = [string]$entry.Path
                if (-not [string]::IsNullOrWhiteSpace($relativePath)) { [void]$managedIgnoreRules.Add('/' + $relativePath.Replace('\', '/').TrimStart('/')) }
            }
            $remainingLines = @($state.Content -split '\r?\n' | Where-Object { -not $managedIgnoreRules.Contains($_.Trim()) })
            $content = ($remainingLines -join $state.NewLine).TrimEnd()
            if ($content -ne $state.Content.TrimEnd()) {
                Save-TransactionFile -Transaction $Transaction -Path $gitIgnorePath
                Write-TextFileState -Path $gitIgnorePath -Content $(if ($content) { $content + $state.NewLine } else { '' }) -Encoding $state.Encoding
                $updatedCount++
            }
        }

        $normalizedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $rootHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalizedRoot)))).Replace('-', '').Substring(0, 16) }
        finally { $sha.Dispose() }
        $stateRoot = Join-Path (Split-Path -Parent $RegistryPath) 'HookState'
        foreach ($stateName in @("crlf-$rootHash.json", "crlf-$rootHash.txt", "crlf-v2-$rootHash.json")) {
            $path = Join-Path $stateRoot $stateName
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Save-TransactionFile -Transaction $Transaction -Path $path
                Remove-Item -LiteralPath $path -Force
                $removedCount++
            }
        }

        foreach ($legacyPath in @('.codex-root', '.codex\hooks\crlf-updated-files.ps1', '.codex-settings-manifest.json')) {
            $path = Join-Path $root $legacyPath
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Save-TransactionFile -Transaction $Transaction -Path $path
                Remove-Item -LiteralPath $path -Force
                $removedCount++
            }
        }
        foreach ($directory in @('.codex\hooks', '.codex\rules', '.codex')) {
            $path = Join-Path $root $directory
            if ((Test-Path -LiteralPath $path -PathType Container) -and @(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }

    Save-TransactionFile -Transaction $Transaction -Path $RegistryPath
    Remove-Item -LiteralPath $RegistryPath -Force
    return [pscustomobject]@{ Projects = $projectCount; FilesRemoved = $removedCount; FilesUpdated = $updatedCount }
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
        $template = [IO.File]::ReadAllText($source.FullName)
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

    if ($Target.Mode -eq 'Global') { Assert-GlobalCrlfHookRemoved -Root $Target.Root }

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
