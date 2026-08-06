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

    $configTemplate = Join-Path $ScriptRoot 'templates\core\config.toml'
    $shape = Get-TomlShape -Content ([IO.File]::ReadAllText($configTemplate))
    if ($shape.Duplicates.Count -gt 0) { throw "內建 config.toml 無效：$($shape.Duplicates -join ', ')" }
}
