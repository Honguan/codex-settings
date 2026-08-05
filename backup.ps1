[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Project', 'All')]
    [string]$Mode = 'Interactive',
    [string]$ProjectPath,
    [string]$DestinationRoot = (Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup')
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'lib\codex-settings-common.ps1')
. (Join-Path $ScriptRoot 'lib\project-registry.ps1')

function Copy-ExistingItem {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) { return 0 }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    return 1
}

if ($Mode -eq 'Interactive') {
    Write-Host ''
    Write-Host '備份 Codex 設定'
    Write-Host '==============='
    Write-Host '[1] 全域受管理設定、專案清單、Profile 與 ccusage 狀態'
    Write-Host '[2] 專案設定'
    Write-Host '[3] 全域與專案設定'
    Write-Host '[0] 結束'
    Write-Host ''

    switch (Read-Host '請選擇') {
        '1' { $Mode = 'Global' }
        '2' { $Mode = 'Project' }
        '3' { $Mode = 'All' }
        '0' { exit 0 }
        default { throw '選項無效。' }
    }
}

if (($Mode -eq 'Project' -or $Mode -eq 'All') -and [string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = Read-Host '輸入專案根目錄'
}
if ($Mode -eq 'Project' -or $Mode -eq 'All') {
    $ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
}

New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
$backupRoot = Join-Path $DestinationRoot (Get-Date -Format 'yyyyMMdd-HHmmss-fff-manual')
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

$itemCount = 0
$metadata = [ordered]@{
    Version = 4
    CreatedAt = (Get-Date).ToString('o')
    Mode = $Mode
    ProjectRoot = $ProjectPath
    PowerShellVersion = [string]$PSVersionTable.PSVersion
}

if ($Mode -eq 'Global' -or $Mode -eq 'All') {
    $codexHome = Join-Path $HOME '.codex'
    $globalTarget = Join-Path $backupRoot 'global\.codex'

    foreach ($name in @(
        'AGENTS.md', 'AGENTS.override.md', 'config.toml', 'rules', 'agents', 'skills', 'hooks.json', 'hooks', 'tools',
        '.codex-settings-manifest.json', 'model-router-state.json', 'config.toml.codex-model-router.bak'
    )) {
        $itemCount += Copy-ExistingItem -Source (Join-Path $codexHome $name) -Destination (Join-Path $globalTarget $name)
    }

    $userSkills = Join-Path $HOME '.agents\skills'
    $itemCount += Copy-ExistingItem -Source $userSkills -Destination (Join-Path $backupRoot 'global\.agents\skills')

    $registryPath = Get-CodexProjectRegistryPath
    $registryExisted = Test-Path -LiteralPath $registryPath -PathType Leaf
    if ($registryExisted) {
        $itemCount += Copy-ExistingItem -Source $registryPath -Destination (Join-Path $backupRoot 'global\registry\projects.json')
    }

    $profileItems = New-Object 'System.Collections.Generic.List[object]'
    $profilePaths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
    for ($index = 0; $index -lt $profilePaths.Count; $index++) {
        $profilePath = $profilePaths[$index]
        $relativePath = "global\powershell\profile-$($index + 1).ps1"
        $profileExisted = Test-Path -LiteralPath $profilePath -PathType Leaf
        if ($profileExisted) { $itemCount += Copy-ExistingItem -Source $profilePath -Destination (Join-Path $backupRoot $relativePath) }
        [void]$profileItems.Add([ordered]@{
            Path = $profilePath
            Existed = $profileExisted
            BackupRelativePath = if ($profileExisted) { $relativePath } else { $null }
        })
    }

    $ccusage = Get-CcusageState
    $metadata.Global = [ordered]@{
        BackedUpCodexItems = @(
            'AGENTS.md', 'AGENTS.override.md', 'config.toml', 'rules', 'agents', 'skills', 'hooks.json', 'hooks', 'tools',
            '.codex-settings-manifest.json', 'model-router-state.json', 'config.toml.codex-model-router.bak'
        )
        ProjectRegistry = [ordered]@{
            Path = $registryPath
            Existed = $registryExisted
            BackupRelativePath = if ($registryExisted) { 'global\registry\projects.json' } else { $null }
        }
        PowerShellProfiles = $profileItems.ToArray()
        Ccusage = [ordered]@{
            Installed = [bool]$ccusage.Installed
            Version = [string]$ccusage.Version
        }
        Context7 = [ordered]@{
            EnvironmentVariable = 'CONTEXT7_API_KEY'
            KeyPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User'))
            SecretBackedUp = $false
        }
    }
}

if ($Mode -eq 'Project' -or $Mode -eq 'All') {
    $projectTarget = Join-Path $backupRoot 'project'
    foreach ($name in @('AGENTS.md', 'agent.md', 'AGENTS.override.md', '.codex-root', '.codex', '.agents\skills', '.codex-settings-manifest.json')) {
        $itemCount += Copy-ExistingItem -Source (Join-Path $ProjectPath $name) -Destination (Join-Path $projectTarget $name)
    }
}

$metadata.ItemCount = $itemCount
Write-JsonFileAtomic -Path (Join-Path $backupRoot 'backup-meta.json') -Value $metadata -Depth 12

Write-Host ''
Write-Host "已備份項目：$itemCount"
Write-Host "備份位置：$backupRoot"
if ($null -ne $metadata.Global -and $metadata.Global.Context7.KeyPresent) {
    Write-Host 'Context7 Key：已偵測到，但手動備份不會複製。'
}
