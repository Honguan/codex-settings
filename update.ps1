[CmdletBinding()]
param(
    [switch]$SkipRepositoryPull,
    [switch]$SkipGlobal,
    [switch]$SkipCcusageInstall
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $SkipRepositoryPull) {
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptRoot '.git'))) {
        Write-Host '發佈安裝包不含 Git 工作目錄；略過儲存庫更新，套用目前解壓縮的版本。'
    } else {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            throw '更新此設定儲存庫需要 Git。'
        }

        $dirty = & git -C $ScriptRoot status --porcelain
        if ($LASTEXITCODE -ne 0) {
            throw '無法檢查設定儲存庫狀態。'
        }
        if ($dirty) {
            throw '設定儲存庫有本機變更；請先提交或捨棄後再更新。'
        }

        & git -C $ScriptRoot pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            throw 'git pull --ff-only 失敗。'
        }

        Write-Host '設定儲存庫已更新。'
    }
} else {
    Write-Host '已略過設定儲存庫更新。'
}

$registryLibrary = Join-Path $ScriptRoot 'lib\project-registry.ps1'
$installer = Join-Path $ScriptRoot 'install.ps1'
if (-not (Test-Path -LiteralPath $registryLibrary -PathType Leaf)) {
    throw "找不到專案清單程式庫：$registryLibrary"
}
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "找不到安裝器：$installer"
}
. $registryLibrary

$results = New-Object 'System.Collections.Generic.List[object]'

function Add-UpdateResult {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][bool]$Succeeded,
        [string]$Reason
    )

    [void]$results.Add([pscustomobject]@{
        Scope = $Scope
        Target = $Target
        Status = if ($Succeeded) { '已更新' } else { '失敗' }
        Reason = $Reason
    })
}

if (-not $SkipGlobal) {
    Write-Host ''
    Write-Host '正在更新全域設定…'
    try {
        & $installer -Mode Global -SkipContext7Key -SkipCcusageInstall:$SkipCcusageInstall
        Add-UpdateResult -Scope 'Global' -Target (Join-Path $HOME '.codex') -Succeeded $true
    } catch {
        Add-UpdateResult -Scope 'Global' -Target (Join-Path $HOME '.codex') -Succeeded $false -Reason $_.Exception.Message
    }
}

$projects = @(Get-RegisteredCodexProjects)
foreach ($project in $projects) {
    $type = [string]$project.Type
    $path = [string]$project.Path

    Write-Host ''
    Write-Host "正在更新已登記的 $type 專案：$path"

    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Add-UpdateResult -Scope $type -Target $path -Succeeded $false -Reason '已登記的專案目錄不存在。'
        continue
    }

    try {
        & $installer -Mode $type -ProjectPath $path
        Add-UpdateResult -Scope $type -Target $path -Succeeded $true
    } catch {
        Add-UpdateResult -Scope $type -Target $path -Succeeded $false -Reason $_.Exception.Message
    }
}

Write-Host ''
Write-Host '更新摘要'
Write-Host '========'
if ($results.Count -eq 0) {
    Write-Host '沒有選擇或登記任何更新目標。'
    exit 0
}

$results | Select-Object Scope, Status, Target | Format-Table -AutoSize -Wrap | Out-Host
$failures = @($results | Where-Object Status -eq '失敗')
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host '失敗項目：'
    foreach ($failure in $failures) {
        Write-Host "- [$($failure.Scope)] $($failure.Target)"
        Write-Host "  $($failure.Reason)"
    }
    Write-Host ''
    Write-Host "已更新：$($results.Count - $failures.Count)；失敗：$($failures.Count)"
    exit 1
}

Write-Host "已更新：$($results.Count)；失敗：0"
Write-Host '請重新啟動 PowerShell 與 Codex，以載入更新後的設定。'
