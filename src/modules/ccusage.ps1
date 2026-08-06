[CmdletBinding()]
param(
    [switch]$SkipPackageInstall,
    [switch]$SkipRuntimeValidation,
    [switch]$PassThru,
    [object]$PackageState
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $ScriptRoot 'common.ps1')

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "安裝 ccsessions 與 cdaily 需要 PowerShell 7 或更新版本；目前版本：$($PSVersionTable.PSVersion)"
}

$templatePath = Join-Path $SourceRoot 'templates\profile\usage-commands.ps1'
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "找不到 ccusage Profile 範本：$templatePath"
}

$packageBefore = if ($null -ne $PackageState) { $PackageState } else { Get-CcusageState }
$profilePaths = @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
$profileTargets = foreach ($profilePath in $profilePaths) {
    Test-DirectoryWritable -Path (Split-Path -Parent $profilePath)
    $profileState = Get-TextFileState -Path $profilePath
    [pscustomobject]@{
        Path = $profilePath
        State = $profileState
        BackupPath = $null
        Changed = $false
    }
}

try {
    $packageInstalledNow = $false
    if (-not [bool]$packageBefore.Installed -and -not $SkipPackageInstall) {
        $installOutput = & npm install --global 'ccusage@latest' 2>&1
        $installExitCode = $LASTEXITCODE
        $installOutput | Out-Host
        if ($installExitCode -ne 0) {
            throw "ccusage@latest 安裝失敗，npm 結束代碼：$installExitCode。`n$($installOutput | Out-String)"
        }
        $packageInstalledNow = $true
    }

    $managedContent = [IO.File]::ReadAllText($templatePath).Trim()
    foreach ($profileTarget in $profileTargets) {
        $existingContent = Remove-CcusageProfileBlocks -Content $profileTarget.State.Content
        $newContent = if ([string]::IsNullOrWhiteSpace($existingContent)) {
            $managedContent + $profileTarget.State.NewLine
        } else {
            $existingContent.TrimEnd() + $profileTarget.State.NewLine + $profileTarget.State.NewLine + $managedContent + $profileTarget.State.NewLine
        }

        if ($newContent -ne $profileTarget.State.Content) {
            $tokens = $null
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseInput($newContent, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count -gt 0) {
                $firstError = $parseErrors[0]
                throw "PowerShell Profile 驗證失敗：$($profileTarget.Path)，第 $($firstError.Extent.StartLineNumber) 行：$($firstError.Message)"
            }

            if ($profileTarget.State.Exists) {
                $profileTarget.BackupPath = "$($profileTarget.Path).ccusage-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')"
                Copy-FileAtomic -Source $profileTarget.Path -Destination $profileTarget.BackupPath
            }
            Write-TextFileState -Path $profileTarget.Path -Content $newContent -Encoding $profileTarget.State.Encoding
            $profileTarget.Changed = $true
        }
    }

    Remove-Item Function:\ccsessions, Function:\cdaily -Force -ErrorAction SilentlyContinue
    . $templatePath | Out-Null

    if (-not (Get-Command ccsessions -ErrorAction SilentlyContinue)) {
        throw "無法從範本載入 ccsessions 函式：$templatePath"
    }
    if (-not (Get-Command cdaily -ErrorAction SilentlyContinue)) {
        throw "無法從範本載入 cdaily 函式：$templatePath"
    }

    if ($packageInstalledNow -and -not $SkipRuntimeValidation) {
        $versionOutput = & npx --yes 'ccusage@latest' --version 2>&1
        $versionExitCode = $LASTEXITCODE
        if ($versionExitCode -ne 0) {
            throw "ccusage@latest 執行驗證失敗，結束代碼：$versionExitCode。`n$($versionOutput | Out-String)"
        }
    }

    $packageAfter = if ($packageInstalledNow) { Get-CcusageState } else { $packageBefore }
    $allHostsTarget = $profileTargets | Where-Object { $_.Path -eq $PROFILE.CurrentUserAllHosts } | Select-Object -First 1
    $result = [pscustomobject]@{
        ProfilePath = $allHostsTarget.Path
        ProfileExistedBefore = [bool]$allHostsTarget.State.Exists
        ProfileBackupPath = $allHostsTarget.BackupPath
        ProfilePaths = @($profileTargets.Path)
        ProfileStates = @($profileTargets | ForEach-Object {
            [pscustomobject]@{
                Path = $_.Path
                ExistedBefore = [bool]$_.State.Exists
            }
        })
        ProfileBackupPaths = @($profileTargets.BackupPath | Where-Object { $null -ne $_ })
        PackageBefore = $packageBefore
        PackageAfter = $packageAfter
        PackageInstalledNow = $packageInstalledNow
        CommandsUpdated = @($profileTargets | Where-Object Changed).Count -gt 0
        PowerShellVersion = [string]$PSVersionTable.PSVersion
    }

    if ($PassThru) { return $result }

    if ($packageInstalledNow) { Write-Host '已安裝 ccusage@latest。' }
    elseif ([bool]$packageBefore.Installed) { Write-Host "偵測到 ccusage $($packageBefore.Version)；略過套件重複安裝。" }
    else { Write-Host '已略過 ccusage 套件安裝。' }
    Write-Host (if (@($profileTargets | Where-Object Changed).Count -gt 0) { '已更新 ccsessions、cdaily 指令。' } else { 'ccsessions、cdaily 指令已是最新內容，未改寫 Profile。' })
    Write-Host '  ccsessions [數量或 Session ID]：查看 Session 的模型、Token、費用與台北時間。'
    Write-Host '  ccsessions -Json <Session ID>：輸出每輪 Token Hook 使用的機器可讀資料。'
    Write-Host '  cdaily [天數]：查看每日 Token 與費用統計。'
    Write-Host "PowerShell 版本：$($PSVersionTable.PSVersion)"
    foreach ($profileTarget in $profileTargets) { Write-Host "設定檔：$($profileTarget.Path)" }
    foreach ($profileTarget in $profileTargets) {
        if ($profileTarget.BackupPath) { Write-Host "備份：$($profileTarget.BackupPath)" }
    }
} catch {
    $primaryError = $_.Exception.Message
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'

    try {
        foreach ($profileTarget in $profileTargets) {
            if (-not $profileTarget.Changed) { continue }
            if ($profileTarget.State.Exists) {
                Copy-FileAtomic -Source $profileTarget.BackupPath -Destination $profileTarget.Path
            } else {
                Remove-Item -LiteralPath $profileTarget.Path -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        [void]$rollbackErrors.Add("Profile rollback failed: $($_.Exception.Message)")
    }

    if ($packageInstalledNow) {
        try { Restore-CcusageState -State $packageBefore }
        catch { [void]$rollbackErrors.Add("ccusage rollback failed: $($_.Exception.Message)") }
    }

    $message = "ccusage setup failed: $primaryError"
    if ($rollbackErrors.Count -gt 0) { $message += "`nRollback errors:`n- " + ($rollbackErrors -join "`n- ") }
    throw $message
}
