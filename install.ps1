[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Git', 'CVS')]
    [string]$Mode = 'Interactive',

    [string]$ProjectPath
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupBase = Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'

function Get-RelativeTemplatePath {
    param(
        [Parameter(Mandatory = $true)][string]$TemplateRoot,
        [Parameter(Mandatory = $true)][string]$FullName
    )

    return $FullName.Substring($TemplateRoot.Length).TrimStart([char[]]'\/')
}

function Invoke-RepositoryScript {
    param([Parameter(Mandatory = $true)][string]$Name)

    $path = Join-Path $ScriptRoot $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required script is missing: $path"
    }

    & $path
    exit $LASTEXITCODE
}

function Select-InteractiveMode {
    Write-Host ''
    Write-Host 'Codex Settings Installer'
    Write-Host '========================'
    Write-Host '[1] Install global settings'
    Write-Host '[2] Install Git project settings'
    Write-Host '[3] Install CVS project settings'
    Write-Host '[4] Backup current settings'
    Write-Host '[5] Restore a backup'
    Write-Host '[6] Update this settings repository'
    Write-Host '[7] Uninstall managed settings'
    Write-Host '[0] Exit'
    Write-Host ''

    $choice = Read-Host 'Select'
    switch ($choice) {
        '1' { return 'Global' }
        '2' { return 'Git' }
        '3' { return 'CVS' }
        '4' { Invoke-RepositoryScript -Name 'backup.ps1' }
        '5' { Invoke-RepositoryScript -Name 'restore.ps1' }
        '6' { Invoke-RepositoryScript -Name 'update.ps1' }
        '7' { Invoke-RepositoryScript -Name 'uninstall.ps1' }
        '0' { exit 0 }
        default { throw "Invalid selection: $choice" }
    }
}

function Resolve-InstallTarget {
    param(
        [Parameter(Mandatory = $true)][string]$InstallMode,
        [string]$RequestedProjectPath
    )

    if ($InstallMode -eq 'Global') {
        return [pscustomobject]@{
            TemplateRoot = Join-Path $ScriptRoot 'templates\global'
            TargetRoot   = Join-Path $HOME '.codex'
        }
    }

    if ([string]::IsNullOrWhiteSpace($RequestedProjectPath)) {
        $RequestedProjectPath = Read-Host "Enter the $InstallMode project root"
    }

    if ([string]::IsNullOrWhiteSpace($RequestedProjectPath)) {
        throw 'Project path is required.'
    }

    $resolvedProjectPath = (Resolve-Path -LiteralPath $RequestedProjectPath).Path
    if (-not (Test-Path -LiteralPath $resolvedProjectPath -PathType Container)) {
        throw "Project directory does not exist: $resolvedProjectPath"
    }

    if ($InstallMode -eq 'Git' -and -not (Test-Path -LiteralPath (Join-Path $resolvedProjectPath '.git'))) {
        Write-Warning 'No .git marker was found at the selected project root.'
    }

    if ($InstallMode -eq 'CVS' -and -not (Test-Path -LiteralPath (Join-Path $resolvedProjectPath 'CVS'))) {
        Write-Warning 'No CVS directory was found at the selected project root.'
    }

    return [pscustomobject]@{
        TemplateRoot = Join-Path $ScriptRoot ("templates\{0}-project" -f $InstallMode.ToLowerInvariant())
        TargetRoot   = $resolvedProjectPath
    }
}

function Install-Template {
    param(
        [Parameter(Mandatory = $true)][string]$InstallMode,
        [Parameter(Mandatory = $true)][string]$TemplateRoot,
        [Parameter(Mandatory = $true)][string]$TargetRoot
    )

    if (-not (Test-Path -LiteralPath $TemplateRoot -PathType Container)) {
        throw "Template directory does not exist: $TemplateRoot"
    }

    New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $BackupBase -Force | Out-Null

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupRoot = Join-Path $BackupBase ("$stamp-$($InstallMode.ToLowerInvariant())")
    $backupFilesRoot = Join-Path $backupRoot 'files'
    New-Item -ItemType Directory -Path $backupFilesRoot -Force | Out-Null

    $manifestEntries = @()
    $backedUpCount = 0
    $installedCount = 0

    $templateFiles = Get-ChildItem -LiteralPath $TemplateRoot -Recurse -File
    foreach ($sourceFile in $templateFiles) {
        $relativePath = Get-RelativeTemplatePath -TemplateRoot $TemplateRoot -FullName $sourceFile.FullName
        $destinationPath = Join-Path $TargetRoot $relativePath
        $destinationDirectory = Split-Path -Parent $destinationPath

        if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
            $backupPath = Join-Path $backupFilesRoot $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
            Copy-Item -LiteralPath $destinationPath -Destination $backupPath -Force
            $backedUpCount++
        }

        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationPath -Force

        $manifestEntries += [pscustomobject]@{
            Path   = $relativePath
            Sha256 = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
        }
        $installedCount++
    }

    $manifestPath = Join-Path $TargetRoot '.codex-settings-manifest.json'
    $manifest = [pscustomobject]@{
        Version     = 1
        Mode        = $InstallMode
        InstalledAt = (Get-Date).ToString('o')
        TargetRoot  = $TargetRoot
        Files       = $manifestEntries
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $backupMetadata = [pscustomobject]@{
        Version      = 1
        CreatedAt    = (Get-Date).ToString('o')
        Mode         = $InstallMode
        TargetRoot   = $TargetRoot
        FilesRoot    = $backupFilesRoot
        BackedUpFiles = $backedUpCount
    }
    $backupMetadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupRoot 'backup-meta.json') -Encoding UTF8

    Write-Host ''
    Write-Host "Installed files : $installedCount"
    Write-Host "Backed up files : $backedUpCount"
    Write-Host "Target          : $TargetRoot"
    Write-Host "Backup          : $backupRoot"
    Write-Host ''
    Write-Host 'Restart Codex so it reloads AGENTS.md, config, rules, and skills.'
}

if ($Mode -eq 'Interactive') {
    $Mode = Select-InteractiveMode
}

$target = Resolve-InstallTarget -InstallMode $Mode -RequestedProjectPath $ProjectPath
Install-Template -InstallMode $Mode -TemplateRoot $target.TemplateRoot -TargetRoot $target.TargetRoot
