function New-InstallationProgressSteps {
    [CmdletBinding()]
    param(
        [int]$TargetCount = 1,
        [switch]$IncludeContext7,
        [switch]$IncludeSkills,
        [switch]$IncludePonytail,
        [switch]$IncludeNotifications
    )

    $steps = New-Object 'System.Collections.Generic.List[object]'
    [void]$steps.Add([pscustomobject]@{ Id = 'Plan'; Name = '安裝計畫'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    [void]$steps.Add([pscustomobject]@{ Id = 'Prerequisites'; Name = '前置需求檢查'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    [void]$steps.Add([pscustomobject]@{ Id = 'Lock'; Name = '取得安裝鎖 / 回復中斷交易'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    [void]$steps.Add([pscustomobject]@{ Id = 'Backup'; Name = '建立交易備份'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    [void]$steps.Add([pscustomobject]@{ Id = 'Targets'; Name = '安裝/合併目標檔案'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0; TargetCount = $TargetCount })
    [void]$steps.Add([pscustomobject]@{ Id = 'Hooks'; Name = 'Hook 去重與信任驗證'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    if ($IncludeContext7) { [void]$steps.Add([pscustomobject]@{ Id = 'Context7'; Name = 'Context7 設定'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 }) }
    [void]$steps.Add([pscustomobject]@{ Id = 'Ccusage'; Name = 'ccusage / ccsessions / cdaily'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    if ($IncludeSkills) { [void]$steps.Add([pscustomobject]@{ Id = 'Skills'; Name = '選用 Skills'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 }) }
    if ($IncludePonytail) { [void]$steps.Add([pscustomobject]@{ Id = 'Ponytail'; Name = 'Ponytail plugin 與 lifecycle hooks'; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 }) }
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

function Protect-InstallLogText {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) { return '' }
    $text = [regex]::Replace($text, '(?i)(CONTEXT7_API_KEY\s*[=:]\s*)[^\s;]+', '$1<REDACTED>')
    $text = [regex]::Replace($text, '(?i)\b(Bearer\s+)[A-Za-z0-9._~+/=-]+', '$1<REDACTED>')
    $text = [regex]::Replace($text, '(?i)((?:token|credential|api[_ -]?key)\s*[=:]\s*)[^\s;]+', '$1<REDACTED>')
    return ($text -replace '\r?\n', ' | ')
}

function Write-InstallErrorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [string]$CurrentSubOperation = ''
    )

    $invocation = $ErrorRecord.InvocationInfo
    $stepId = if ($null -ne $Progress.CurrentStep) { [string]$Progress.CurrentStep.Id } else { '' }
    $commandName = if ($null -ne $invocation -and $null -ne $invocation.MyCommand) { [string]$invocation.MyCommand.Name } else { '' }
    $scriptName = if ($null -ne $invocation) { [string]$invocation.ScriptName } else { '' }
    $lineNumber = if ($null -ne $invocation) { [int]$invocation.ScriptLineNumber } else { 0 }
    $exceptionType = if ($null -ne $ErrorRecord.Exception) { $ErrorRecord.Exception.GetType().FullName } else { '' }
    $message = if ($null -ne $ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }

    Write-InstallLog -Progress $Progress -Message ("ERROR CurrentStepId={0}; CurrentSubOperation={1}" -f (Protect-InstallLogText $stepId), (Protect-InstallLogText $CurrentSubOperation))
    Write-InstallLog -Progress $Progress -Message ("ExceptionType={0}" -f (Protect-InstallLogText $exceptionType))
    Write-InstallLog -Progress $Progress -Message ("Message={0}" -f (Protect-InstallLogText $message))
    Write-InstallLog -Progress $Progress -Message ("FullyQualifiedErrorId={0}" -f (Protect-InstallLogText $ErrorRecord.FullyQualifiedErrorId))
    Write-InstallLog -Progress $Progress -Message ("CategoryInfo={0}" -f (Protect-InstallLogText $ErrorRecord.CategoryInfo))
    Write-InstallLog -Progress $Progress -Message ("InvocationInfo.MyCommand={0}" -f (Protect-InstallLogText $commandName))
    Write-InstallLog -Progress $Progress -Message ("InvocationInfo.ScriptName={0}" -f (Protect-InstallLogText $scriptName))
    Write-InstallLog -Progress $Progress -Message ("InvocationInfo.ScriptLineNumber={0}" -f $lineNumber)
    Write-InstallLog -Progress $Progress -Message ("InvocationInfo.PositionMessage={0}" -f (Protect-InstallLogText $invocation.PositionMessage))
    Write-InstallLog -Progress $Progress -Message ("ScriptStackTrace={0}" -f (Protect-InstallLogText $ErrorRecord.ScriptStackTrace))
}

function Start-InstallProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Steps,
        [Parameter(Mandatory = $true)][string]$Root,
        [hashtable]$Metadata = @{},
        [ValidateSet('Auto', 'Interactive', 'Line')][string]$RendererMode = 'Auto'
    )

    $logDirectory = Join-Path $Root 'logs\installer'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $startedAt = Get-Date
    $logPath = Join-Path $logDirectory ('install-{0}.log' -f $startedAt.ToString('yyyyMMdd-HHmmss'))
    $resolvedRendererMode = if ($RendererMode -ne 'Auto') {
        $RendererMode
    } elseif ($env:CI -or $env:CODEX_SETTINGS_INSTALLER_NONINTERACTIVE -eq '1' -or [Console]::IsOutputRedirected) {
        'Line'
    } else {
        try { if ($null -ne $Host.UI.RawUI.WindowSize) { 'Interactive' } else { 'Line' } } catch { 'Line' }
    }
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
        RendererMode = $resolvedRendererMode
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
        [hashtable]$Metadata = @{},
        [ValidateSet('Auto', 'Interactive', 'Line')][string]$RendererMode = 'Auto'
    )
    return Start-InstallProgress -Steps $Steps -Root $Root -Metadata $Metadata -RendererMode $RendererMode
}

function Get-InstallProgressStep($Progress, [string]$StepId) {
    return @($Progress.Steps | Where-Object { [string]$_.Id -eq $StepId } | Select-Object -First 1)[0]
}

function Write-InstallProgressDisplay($Progress, $Step, [string]$Detail) {
    $total = [Math]::Max(1, @($Progress.Steps).Count)
    $percent = [int][Math]::Floor((([int]$Step.Index - 1) / $total) * 100)
    if ($Progress.RendererMode -eq 'Interactive') {
        $status = "{0}%  {1}/{2}  {3}  elapsed {4}" -f $percent, $Step.Index, $total, $Step.Name, $Progress.Stopwatch.Elapsed.ToString('hh\:mm\:ss')
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { $status += " — $Detail" }
        Write-Progress -Id 1 -Activity 'Codex Settings Installer' -Status $status -PercentComplete $percent
    } else {
        Write-Host ("STEP START {0}/{1} {2}: {3}" -f $Step.Index, $total, $Step.Name, $Detail)
    }
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
    if ($Progress.RendererMode -eq 'Interactive') {
        Write-Progress -Id 1 -Activity 'Codex Settings Installer' -Status ("{0}%  {1}/{2}  {3} — {4}  elapsed {5}" -f $percent, $step.Index, $total, $step.Name, $Result, $Progress.Stopwatch.Elapsed.ToString('hh\:mm\:ss')) -PercentComplete $percent
    } else {
        Write-Host ("STEP END {0}/{1} {2}: {3} ({4:N1}s)" -f $step.Index, $total, $step.Name, $Result, $step.ElapsedSeconds)
    }
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
    if ($Progress.RendererMode -eq 'Line') { Write-Host ("STEP FAILED {0}: {1}" -f $stepName, $Reason) }
    Write-InstallLog -Progress $Progress -Message ("STEP FAILED {0}: {1}" -f $stepName, $Reason)
}

function Get-InstallResultSymbol([string]$Status) {
    switch -Regex ($Status) {
        '^(?:Installed|Created|Enabled)$' { return '+' }
        '^Updated$' { return '~' }
        '^(?:Existing|Unchanged|Current|Validated)$' { return '=' }
        '^(?:Skipped|SkippedByUser|SkippedUnchanged)$' { return '-' }
        '^Failed$' { return '✗' }
        default { return '=' }
    }
}

function Write-InstallResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [ValidateSet('SUCCESS', 'FAILED')][string]$Status = 'SUCCESS',
        [hashtable]$Summary = @{},
        [object[]]$Results = @(),
        [object[]]$Components = @()
    )

    $Progress.Status = $Status
    if ($Progress.RendererMode -eq 'Interactive') { Write-Progress -Id 1 -Activity 'Codex Settings Installer' -Completed }
    Write-Host ''
    Write-Host ('=' * 60)
    Write-Host $(if ($Status -eq 'SUCCESS') { '安裝完成' } else { '安裝失敗' })
    Write-Host ('=' * 60)
    Write-Host "Result: $Status"
    Write-Host ("Elapsed: {0:N1}s" -f $Progress.Stopwatch.Elapsed.TotalSeconds)
    if ($Progress.Metadata.ContainsKey('Environment')) { Write-Host "Environment: $($Progress.Metadata.Environment)" }
    if ($Progress.Metadata.ContainsKey('InstallStyle')) { Write-Host "Mode: $($Progress.Metadata.InstallStyle)" }
    Write-Host ''
    Write-Host '步驟'
    foreach ($step in @($Progress.Steps | Where-Object Status -ne 'Pending')) {
        $symbol = if ($step.Status -eq 'Completed') { '✓' } elseif ($step.Status -eq 'Failed') { '✗' } else { '…' }
        Write-Host ("[{0}] {1,-28} {2,6:N1}s  {3}" -f $symbol, $step.Name, $step.ElapsedSeconds, $step.Result)
    }
    if (@($Results).Count -gt 0) {
        Write-Host ''
        Write-Host '安裝內容'
        foreach ($result in @($Results)) {
            Write-Host ("{0}: {1}" -f $result.Mode, $result.Root)
            foreach ($file in @($result.Files)) {
                $fileStatus = [string]$file.Status
                if ([string]::IsNullOrWhiteSpace($fileStatus)) {
                    $fileStatus = if (-not [bool]$file.ExistedBefore) { 'Installed' } elseif ([bool]$file.Changed) { 'Updated' } else { 'Unchanged' }
                }
                Write-Host ("  [{0}] {1}  {2}" -f (Get-InstallResultSymbol $fileStatus), $file.RelativePath, $fileStatus)
            }
        }
    }
    if (@($Components).Count -gt 0) {
        Write-Host ''
        Write-Host '外部元件'
        foreach ($component in @($Components)) {
            Write-Host ("[{0}] {1}  {2}  {3}" -f (Get-InstallResultSymbol ([string]$component.Status)), $component.Name, $component.Status, $component.Result)
        }
    }
    Write-Host ''
    Write-Host '統計'
    foreach ($name in @('Installed', 'Updated', 'Unchanged', 'Skipped', 'Failed')) {
        $value = if ($Summary.ContainsKey($name)) { $Summary[$name] } else { 0 }
        Write-Host ("{0}: {1}" -f $name, $value)
    }
    $rollback = if ($Summary.ContainsKey('Rollback')) { [string]$Summary.Rollback } else { 'N/A' }
    Write-Host "Rollback: $rollback"
    if ($Status -eq 'FAILED') {
        Write-Host "失敗階段：$($Progress.FailureStep)"
        Write-Host "原因：$($Progress.FailureReason)"
    }
    if ($Summary.ContainsKey('Footer') -and -not [string]::IsNullOrWhiteSpace([string]$Summary.Footer)) { Write-Host ([string]$Summary.Footer) }
    Write-Host "Log: $($Progress.LogPath)"
    Write-Host ('=' * 60)
    Write-InstallLog -Progress $Progress -Message ("INSTALL END status=$Status; elapsed={0:N1}s; rollback=$rollback" -f $Progress.Stopwatch.Elapsed.TotalSeconds)
}

function Get-InstallResultSummary {
    [CmdletBinding()]
    param([object[]]$Results)

    $summary = @{ Installed = 0; Updated = 0; Unchanged = 0; Skipped = 0; Failed = 0 }
    foreach ($result in @($Results)) {
        foreach ($file in @($result.Files)) {
            $status = [string]$file.Status
            if ($status -in @('Installed', 'Created')) { $summary.Installed++ }
            elseif ($status -eq 'Updated') { $summary.Updated++ }
            elseif ($status -eq 'Skipped') { $summary.Skipped++ }
            elseif ($status -eq 'Failed') { $summary.Failed++ }
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

    $ccusageStatus = if ($null -eq $CcusageBefore) { '待偵測' } elseif ([bool]$CcusageBefore.Installed) { "已存在，沿用 $($CcusageBefore.Version)" } else { '未安裝，將安裝' }
    Write-InstallLog -Progress $Progress -Message ("PLAN environment={0}; style={1}; notifications={2}; targets={3}; skills={4}; defaultModeRequestUserInput={5}" -f $Context.DevelopmentEnvironment, $Context.InstallStyle, $Context.InstallWindowsNotifications, $Targets.Count, ($InstallRequestExecutionOptimizer -or $InstallMattPocockSkills), $EnableDefaultModeRequestUserInput)
    Write-InstallLog -Progress $Progress -Message ("PLAN targetRoots={0}; ccusage={1}; context7={2}" -f ((@($Targets | ForEach-Object { $_.Root }) -join ',')), $ccusageStatus, $(if ($SkipContext7Key) { 'skipped-by-user' } else { 'configure-or-existing' }))
}
