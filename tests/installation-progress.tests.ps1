$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-installation-progress-' + [guid]::NewGuid().ToString('N'))
try {
    $baseSteps = @(New-InstallationProgressSteps)
    if ($baseSteps.Id -contains 'Context7' -or $baseSteps.Id -contains 'Skills' -or $baseSteps.Id -contains 'Notifications') {
        throw '未選用的選配階段不應佔用安裝進度。'
    }

    $fullSteps = @(New-InstallationProgressSteps -TargetCount 2 -IncludeContext7 -IncludeSkills -IncludeNotifications)
    foreach ($requiredId in @('Prerequisites', 'Plan', 'Lock', 'Backup', 'Targets', 'Hooks', 'Context7', 'Ccusage', 'Skills', 'Notifications', 'Final')) {
        if ($fullSteps.Id -notcontains $requiredId) { throw "缺少安裝進度階段：$requiredId" }
    }
    if (@($fullSteps | Where-Object Id -eq 'Targets')[0].TargetCount -ne 2) { throw '安裝進度未記錄目標數量。' }

    $progress = Start-InstallProgress -Steps $fullSteps -Root $testRoot -Metadata @{ Test = 'installation-progress' }
    Set-InstallProgress -Progress $progress -StepId 'Plan' -Detail '測試安裝計畫'
    Complete-InstallStep -Progress $progress -Result '通過'
    $summary = [ordered]@{ Installed = 1; Updated = 2; Unchanged = 3; Skipped = 4; Rollback = 'N/A' }
    Write-InstallResult -Progress $progress -Status SUCCESS -Summary $summary

    if (-not (Test-Path -LiteralPath $progress.LogPath -PathType Leaf)) { throw '安裝 log 未建立。' }
    $log = Get-Content -LiteralPath $progress.LogPath -Raw
    foreach ($marker in @('INSTALL START', 'STEP START Plan', 'STEP END Plan', 'INSTALL END status=SUCCESS')) {
        if ($log -notmatch [regex]::Escape($marker)) { throw "安裝 log 缺少記錄：$marker" }
    }
    if ((Get-Command Write-InstallResult -CommandType Function).Name -ne 'Write-InstallResult') { throw '缺少安裝結果函式。' }

    $targetRoot = Join-Path $testRoot 'target'
    $target = New-InstallTarget -Id 'test-global' -Mode 'Global' -TemplateRoot (Join-Path $script:ScriptRoot 'templates\core') -EnvironmentTemplateRoot (Join-Path $script:ScriptRoot 'templates\environments\git') -DevelopmentEnvironment 'Git' -Root $targetRoot -Cwd $testRoot -EnableDefaultModeRequestUserInput $false -InstallWindowsNotifications $false -SourceRoot $script:ScriptRoot
    $firstTransaction = New-FileTransaction -Root (Join-Path $testRoot 'first-transaction') -Mode 'Test'
    $firstResult = Invoke-TargetInstallation -Target $target -Transaction $firstTransaction
    Save-InstallationManifest -Result $firstResult -Transaction $firstTransaction -External $null
    Complete-FileTransaction -Transaction $firstTransaction
    $secondTransaction = New-FileTransaction -Root (Join-Path $testRoot 'second-transaction') -Mode 'Test'
    $secondResult = Invoke-TargetInstallation -Target $target -Transaction $secondTransaction
    if (@($secondResult.Files | Where-Object Changed).Count -ne 0 -or $secondTransaction.Entries.Count -ne 0) {
        throw '未變更安裝仍重新寫入檔案或建立交易備份。'
    }
    Write-Host 'Installation progress tests passed.'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
