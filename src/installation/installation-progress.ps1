function New-InstallationProgressSteps {
    [CmdletBinding()]
    param(
        [int]$TargetCount = 1,
        [switch]$IncludeContext7,
        [switch]$IncludeSkills,
        [switch]$IncludeNotifications
    )

    $steps = New-Object 'System.Collections.Generic.List[object]'
    [void]$steps.Add([pscustomobject]@{ Id = 'Prerequisites'; Name = '前置需求檢查'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    [void]$steps.Add([pscustomobject]@{ Id = 'Plan'; Name = '安裝計畫'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    [void]$steps.Add([pscustomobject]@{ Id = 'Lock'; Name = '取得安裝鎖 / 回復中斷交易'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    [void]$steps.Add([pscustomobject]@{ Id = 'Backup'; Name = '建立交易備份'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    [void]$steps.Add([pscustomobject]@{ Id = 'Targets'; Name = '安裝/合併目標檔案'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0; TargetCount = $TargetCount })
    [void]$steps.Add([pscustomobject]@{ Id = 'Hooks'; Name = 'Hook 去重與信任驗證'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    if ($IncludeContext7) { [void]$steps.Add([pscustomobject]@{ Id = 'Context7'; Name = 'Context7 設定'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 }) }
    [void]$steps.Add([pscustomobject]@{ Id = 'Ccusage'; Name = 'ccusage / ccsessions / cdaily'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    if ($IncludeSkills) { [void]$steps.Add([pscustomobject]@{ Id = 'Skills'; Name = '選用 Skills'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 }) }
    if ($IncludeNotifications) { [void]$steps.Add([pscustomobject]@{ Id = 'Notifications'; Name = 'Windows 通知'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 }) }
    [void]$steps.Add([pscustomobject]@{ Id = 'Final'; Name = 'Manifest / 最終驗證'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })

    for ($index = 0; $index -lt $steps.Count; $index++) {
        $steps[$index].Index = $index + 1
    }
    return $steps.ToArray()
}

function Write-InstallLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([string]::IsNullOrWhiteSpace([string]$Progress.LogPath)) { return }
    try {
        $line = "{0} {1}{2}" -f (Get-Date).ToString('o'), $Message, [Environment]::NewLine
        [IO.File]::AppendAllText([string]$Progress.LogPath, $line, (New-Object Text.UTF8Encoding($false)))
    } catch {
        $Progress.LogWriteFailed = $true
    }
}

function Start-InstallProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Steps,
        [Parameter(Mandatory = $true)][string]$Root,
        [hashtable]$Metadata = @{}
    )

    $logDirectory = Join-Path $Root 'logs\installer'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $startedAt = Get-Date
    $logPath = Join-Path $logDirectory ('install-{0}.log' -f $startedAt.ToString('yyyyMMdd-HHmmss'))
    $progress = [pscustomobject]@{
        Steps = @($Steps)
        StartedAt = $startedAt
        Stopwatch = [Diagnostics.Stopwatch]::StartNew()
        CurrentStep = $null
        CurrentStepStartedAt = $null
        Status = 'InProgress'
        FailureStep = $null
        FailureReason = $null
        LogPath = $logPath
        LogWriteFailed = $false
        Metadata = $Metadata
    }
    [IO.File]::WriteAllText($logPath, '', (New-Object Text.UTF8Encoding($false)))
    $metadataText = @($Metadata.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; '
    Write-InstallLog -Progress $progress -Message $(if ([string]::IsNullOrWhiteSpace($metadataText)) { 'INSTALL START' } else { "INSTALL START $metadataText" })
    return $progress
}

function New-InstallProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Steps,
        [Parameter(Mandatory = $true)][string]$Root,
        [hashtable]$Metadata = @{}
    )
    return Start-InstallProgress -Steps $Steps -Root $Root -Metadata $Metadata
}

function Get-InstallProgressStep($Progress, [string]$StepId) {
    return @($Progress.Steps | Where-Object { [string]$_.Id -eq $StepId } | Select-Object -First 1)[0]
}

function Write-InstallProgressDisplay($Progress, $Step, [string]$Detail) {
    $total = [Math]::Max(1, @($Progress.Steps).Count)
    $percent = [int][Math]::Floor((([int]$Step.Index - 1) / $total) * 100)
    $filled = [Math]::Min(20, [Math]::Max(0, [int][Math]::Floor($percent / 5)))
    $bar = (('█' * $filled) -join '') + (('░' * (20 - $filled)) -join '')
    Write-Progress -Id 1 -Activity 'Codex Settings Installer' -Status ("{0}%  {1}/{2}  {3}" -f $percent, $Step.Index, $total, $Step.Name) -PercentComplete $percent
    Write-Host ("[{0}] {1,3}%  {2}/{3}" -f $bar, $percent, $Step.Index, $total)
    Write-Host "目前：$($Step.Name)"
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Host "狀態：$Detail" }
    Write-Host ("耗時：{0}" -f $Progress.Stopwatch.Elapsed.ToString('hh\:mm\:ss'))
}

function Set-InstallProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [Parameter(Mandatory = $true)][string]$StepId,
        [string]$Detail = ''
    )

    $step = Get-InstallProgressStep -Progress $Progress -StepId $StepId
    if ($null -eq $step) { throw "找不到安裝進度階段：$StepId" }
    $step.Status = 'InProgress'
    $step.Detail = $Detail
    $step.StartedAt = Get-Date
    $Progress.CurrentStep = $step
    $Progress.CurrentStepStartedAt = $step.StartedAt
    Write-InstallProgressDisplay -Progress $Progress -Step $step -Detail $Detail
    Write-InstallLog -Progress $Progress -Message ("STEP START {0}: {1}" -f $step.Id, $(if ($Detail) { $Detail } else { $step.Name }))
}

function Complete-InstallStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [string]$Result = '完成'
    )

    $step = $Progress.CurrentStep
    if ($null -eq $step) { throw '沒有可完成的安裝進度階段。' }
    $elapsed = if ($null -ne $Progress.CurrentStepStartedAt) { ((Get-Date) - $Progress.CurrentStepStartedAt).TotalSeconds } else { 0 }
    $step.Status = 'Completed'
    $step.Result = $Result
    $step.ElapsedSeconds = [Math]::Round($elapsed, 1)
    $total = [Math]::Max(1, @($Progress.Steps).Count)
    $percent = [int][Math]::Round(([int]$step.Index / $total) * 100)
    Write-Progress -Id 1 -Activity 'Codex Settings Installer' -Status ("{0}%  {1}/{2}  {3}" -f $percent, $step.Index, $total, $step.Name) -PercentComplete $percent
    Write-Host ("[✓] {0,-24} {1,6:N1}s  {2}" -f $step.Name, $step.ElapsedSeconds, $Result)
    Write-InstallLog -Progress $Progress -Message ("STEP END {0}: {1}; elapsed={2:N1}s" -f $step.Id, $Result, $step.ElapsedSeconds)
}

function Fail-InstallStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $step = $Progress.CurrentStep
    $stepName = if ($null -ne $step) { [string]$step.Name } else { '安裝流程' }
    if ($null -ne $step) {
        $elapsed = if ($null -ne $Progress.CurrentStepStartedAt) { ((Get-Date) - $Progress.CurrentStepStartedAt).TotalSeconds } else { 0 }
        $step.Status = 'Failed'
        $step.Result = $Reason
        $step.ElapsedSeconds = [Math]::Round($elapsed, 1)
    }
    $Progress.Status = 'Failed'
    $Progress.FailureStep = $stepName
    $Progress.FailureReason = $Reason
    Write-Host ("[✗] $stepName") -ForegroundColor Red
    Write-Host "原因：$Reason" -ForegroundColor Red
    Write-InstallLog -Progress $Progress -Message ("STEP FAILED {0}: {1}" -f $stepName, $Reason)
}

function Write-InstallResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [ValidateSet('SUCCESS', 'FAILED')][string]$Status = 'SUCCESS',
        [hashtable]$Summary = @{}
    )

    $Progress.Status = $Status
    Write-Progress -Id 1 -Activity 'Codex Settings Installer' -Completed
    Write-Host ''
    Write-Host ('=' * 60)
    Write-Host $(if ($Status -eq 'SUCCESS') { '安裝完成' } else { '安裝失敗' })
    Write-Host ('=' * 60)
    Write-Host "Result: $Status"
    Write-Host ("Elapsed: {0:N1}s" -f $Progress.Stopwatch.Elapsed.TotalSeconds)
    foreach ($name in @('Installed', 'Updated', 'Unchanged', 'Skipped')) {
        $value = if ($Summary.ContainsKey($name)) { $Summary[$name] } else { 0 }
        Write-Host ("{0}: {1}" -f $name, $value)
    }
    $rollback = if ($Summary.ContainsKey('Rollback')) { [string]$Summary.Rollback } else { 'N/A' }
    Write-Host "Rollback: $rollback"
    if ($Status -eq 'FAILED') {
        Write-Host "失敗階段：$($Progress.FailureStep)"
        Write-Host "原因：$($Progress.FailureReason)"
    }
    Write-Host "Log: $($Progress.LogPath)"
    Write-Host ('=' * 60)
    Write-InstallLog -Progress $Progress -Message ("INSTALL END status=$Status; elapsed={0:N1}s; rollback=$rollback" -f $Progress.Stopwatch.Elapsed.TotalSeconds)
}

function Get-InstallResultSummary {
    [CmdletBinding()]
    param([object[]]$Results)

    $summary = @{ Installed = 0; Updated = 0; Unchanged = 0; Skipped = 0 }
    foreach ($result in @($Results)) {
        if ($null -ne $result.Summary) {
            $summary.Installed += [int]$result.Summary.Installed
            $summary.Updated += [int]$result.Summary.Updated
            $summary.Unchanged += [int]$result.Summary.Unchanged
            $summary.Skipped += [int]$result.Summary.Failed
            continue
        }
        foreach ($file in @($result.Files)) {
            $status = [string]$file.Status
            if ($summary.ContainsKey($status)) { $summary[$status] = [int]$summary[$status] + 1 }
            elseif (-not [bool]$file.Changed) { $summary.Unchanged++ }
            elseif (-not [bool]$file.ExistedBefore) { $summary.Installed++ }
            else { $summary.Updated++ }
        }
    }
    return $summary
}

function Write-InstallationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][object[]]$Targets,
        $CcusageBefore,
        [switch]$InstallRequestExecutionOptimizer,
        [switch]$InstallMattPocockSkills,
        [switch]$EnableDefaultModeRequestUserInput,
        [switch]$SkipContext7Key
    )

    Write-Host ''
    Write-Host '安裝計畫'
    Write-Host "- 環境：$($Context.DevelopmentEnvironment)"
    Write-Host "- 模式：$($Context.InstallStyle)"
    Write-Host "- 目標：$($Context.GlobalRoot)"
    Write-Host ("- Windows 通知：{0}" -f $(if ($Context.InstallWindowsNotifications) { '安裝/更新' } else { '不安裝' }))
    $ccusageStatus = if ($null -eq $CcusageBefore) { '待偵測' } elseif ([bool]$CcusageBefore.Installed) { "已存在，沿用 $($CcusageBefore.Version)" } else { '未安裝，將安裝' }
    Write-Host "- ccusage：$ccusageStatus"
    Write-Host ("- Context7：{0}" -f $(if ($SkipContext7Key) { '略過' } else { '沿用或設定' }))
    Write-Host ("- Skills：{0}" -f $(if ($InstallRequestExecutionOptimizer -or $InstallMattPocockSkills) { '依選項處理' } else { '不安裝' }))
    Write-Host ("- 預計處理目標：{0}" -f $Targets.Count)
    foreach ($target in $Targets) { Write-Host "  - $($target.Mode)：$($target.Root)" }
    Write-InstallLog -Progress $Progress -Message ("PLAN environment={0}; style={1}; notifications={2}; targets={3}; skills={4}; defaultModeRequestUserInput={5}" -f $Context.DevelopmentEnvironment, $Context.InstallStyle, $Context.InstallWindowsNotifications, $Targets.Count, ($InstallRequestExecutionOptimizer -or $InstallMattPocockSkills), $EnableDefaultModeRequestUserInput)
}
