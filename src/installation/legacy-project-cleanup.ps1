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
                $content = Remove-ManagedLineEndingHooksJson -Content $state.Content
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
