[CmdletBinding()]
param(
    [string]$BackupPath,
    [string]$BackupRoot = (Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $SourceRoot 'modules\common.ps1')

function Copy-DirectoryContent {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return 0 }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $items = @(Get-ChildItem -LiteralPath $Source -Force)
    foreach ($item in $items) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Recurse -Force
    }
    return $items.Count
}

$operationLock = $null
try {
    $operationLock = Enter-CodexSettingsLock
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $recovered = @(Repair-PendingTransactions -BackupRoot $BackupRoot)
    foreach ($path in $recovered) { Write-Warning "已回復中斷的交易：$path" }

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $candidates = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10)
        if ($candidates.Count -eq 0) { throw "找不到備份：$BackupRoot" }

        Write-Host ''
        Write-Host '可用備份'
        Write-Host '========'
        for ($index = 0; $index -lt $candidates.Count; $index++) {
            Write-Host ("[{0}] {1}" -f ($index + 1), $candidates[$index].FullName)
        }
        Write-Host '[0] 結束'
        Write-Host ''

        $selection = [int](Read-Host '請選擇')
        if ($selection -eq 0) { exit 0 }
        if ($selection -lt 1 -or $selection -gt $candidates.Count) { throw '選項無效。' }
        $BackupPath = $candidates[$selection - 1].FullName
    }

    $BackupPath = (Resolve-Path -LiteralPath $BackupPath).Path
    $metadataPath = Join-Path $BackupPath 'backup-meta.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw "找不到備份中繼資料：$metadataPath" }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -ErrorAction Stop

    if (-not $Force) {
        Write-Host ''
        Write-Host "備份：$BackupPath"
        Write-Host "建立時間：$($metadata.CreatedAt)"
        Write-Host "類型：$($metadata.Mode)"
        $confirmation = Read-Host '要還原此備份嗎？[y/N]'
        if ($confirmation -notin @('y', 'Y', 'yes', 'YES')) {
            Write-Host '已取消還原。'
            exit 0
        }
    }

    $restoredCount = 0
    $warnings = New-Object 'System.Collections.Generic.List[string]'

    if ($metadata.PSObject.Properties.Name -contains 'Files' -and $null -ne $metadata.Files) {
        $entries = @($metadata.Files)
        for ($index = $entries.Count - 1; $index -ge 0; $index--) {
            $entry = $entries[$index]
            $targetPath = [string]$entry.Path
            if ([bool]$entry.Existed) {
                $backupFile = [string]$entry.BackupPath
                if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) { throw "找不到交易備份檔：$backupFile" }
                Copy-FileAtomic -Source $backupFile -Destination $targetPath
                $restoredCount++
            } else {
                Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
            }
        }
        Restore-ExternalTransactionState -Metadata $metadata
    } elseif ($metadata.PSObject.Properties.Name -contains 'FilesRoot') {
        $restoredCount += Copy-DirectoryContent -Source ([string]$metadata.FilesRoot) -Destination ([string]$metadata.TargetRoot)
        [void]$warnings.Add('舊版移除備份僅還原受管理檔案；舊版中繼資料未記錄所有外部狀態。')
    } else {
        $globalCodex = Join-Path $BackupPath 'global\.codex'
        $globalAgents = Join-Path $BackupPath 'global\.agents'
        $restoredCount += Copy-DirectoryContent -Source $globalCodex -Destination (Join-Path $HOME '.codex')
        $restoredCount += Copy-DirectoryContent -Source $globalAgents -Destination (Join-Path $HOME '.agents')
    }

    if ($metadata.PSObject.Properties.Name -contains 'Global' -and $null -ne $metadata.Global) {
        $profileEntries = if ($metadata.Global.PSObject.Properties.Name -contains 'PowerShellProfiles') {
            @($metadata.Global.PowerShellProfiles)
        } elseif ($null -ne $metadata.Global.PowerShellProfile) {
            @($metadata.Global.PowerShellProfile)
        } else { @() }
        foreach ($profileMetadata in $profileEntries) {
            $profilePath = [string]$profileMetadata.Path
            if ([string]::IsNullOrWhiteSpace($profilePath)) { continue }
            if ([bool]$profileMetadata.Existed) {
                $profileBackup = Join-Path $BackupPath ([string]$profileMetadata.BackupRelativePath)
                if (-not (Test-Path -LiteralPath $profileBackup -PathType Leaf)) { throw "找不到 PowerShell Profile 備份：$profileBackup" }
                Copy-FileAtomic -Source $profileBackup -Destination $profilePath
                $restoredCount++
            } else {
                Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
            }
        }

        if ($null -ne $metadata.Global.Ccusage) { Restore-CcusageState -State $metadata.Global.Ccusage }
        if ($null -ne $metadata.Global.Context7 -and [bool]$metadata.Global.Context7.KeyPresent -and
            [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User'))) {
            [void]$warnings.Add('手動備份偵測到 Context7 Key，但未複製。請手動重新設定 CONTEXT7_API_KEY。')
        }
    }

    Write-Host ''
    Write-Host "已還原項目：$restoredCount"
    foreach ($warning in $warnings) { Write-Warning $warning }
    Write-Host '請重新啟動 PowerShell 與 Codex，以載入還原後的設定。'
} finally {
    Exit-CodexSettingsLock -Lock $operationLock
}
