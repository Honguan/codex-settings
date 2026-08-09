function New-InstallationProgressSteps {
    [CmdletBinding()]
    param(
        [int]$TargetCount = 1,
        [switch]$IncludeContext7,
        [switch]$IncludeSkills,
        [switch]$IncludePonytail,
        [switch]$IncludeCodexOrchestration,
        [switch]$IncludeSerena,
        [switch]$IncludeNotifications
    )

    $steps = New-Object 'System.Collections.Generic.List[object]'
    $addStep = {
        param([string]$Id, [string]$Name, [string]$Category, [string]$Component)
        [void]$steps.Add([pscustomobject]@{ Id = $Id; Name = $Name; Category = $Category; Component = $Component; CategoryIndex = 0; CategoryTotal = 0; Detail = ''; Index = 0; Status = 'Pending'; StartedAt = $null; Result = ''; ElapsedSeconds = 0 })
    }
    & $addStep 'Plan' '安裝計畫' 'Personal' 'CodexSettings'
    & $addStep 'Prerequisites' '前置需求檢查' 'Personal' 'CodexSettings'
    & $addStep 'Lock' '取得安裝鎖 / 回復中斷交易' 'Personal' 'CodexSettings'
    & $addStep 'Backup' '建立交易備份' 'Personal' 'CodexSettings'
    & $addStep 'Targets' '安裝/合併目標檔案' 'Personal' 'CodexSettings'
    $steps[$steps.Count - 1] | Add-Member -NotePropertyName TargetCount -NotePropertyValue $TargetCount
    & $addStep 'Hooks' 'Hook 去重與信任驗證' 'Personal' 'CodexSettings'
    if ($IncludeContext7) { & $addStep 'Context7' 'Context7 設定' 'Personal' 'CodexSettings' }
    & $addStep 'PersonalCheckpoint' '個人設定 checkpoint' 'Personal' 'CodexSettings'
    if ($IncludeNotifications) { & $addStep 'Notifications' 'Windows 開發狀態與使用量通知' 'Community' 'WindowsUsageNotifications' }
    if ($IncludeSkills) { & $addStep 'Skills' '選用 Skills' 'Community' 'MattPocockSkills' }
    if ($IncludePonytail) { & $addStep 'Ponytail' 'Ponytail plugin 與 lifecycle hooks' 'Community' 'Ponytail' }
    if ($IncludeCodexOrchestration) { & $addStep 'CodexOrchestration' 'Codex-Orchestration plugin 與 workflow' 'Community' 'CodexOrchestration' }
    if ($IncludeSerena) { & $addStep 'Serena' 'Serena 安裝與 Codex MCP 設定' 'Community' 'Serena' }
    & $addStep 'Final' 'Manifest / 最終驗證' 'Final' 'Summary'

    for ($index = 0; $index -lt $steps.Count; $index++) {
        $steps[$index].Index = $index + 1
    }
    foreach ($category in @('Personal', 'Community', 'Final')) {
        $categorySteps = @($steps | Where-Object Category -eq $category)
        for ($index = 0; $index -lt $categorySteps.Count; $index++) {
            $categorySteps[$index].CategoryIndex = $index + 1
            $categorySteps[$index].CategoryTotal = $categorySteps.Count
        }
    }
    return $steps.ToArray()
}

function New-InstallRendererProfile {
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'Interactive', 'Line')][string]$RendererMode = 'Auto',
        [Text.Encoding]$OutputEncoding = [Console]::OutputEncoding,
        [int]$WindowWidth = 0
    )

    $mode = if ($RendererMode -ne 'Auto') {
        $RendererMode
    } elseif ($env:CI -or $env:CODEX_SETTINGS_INSTALLER_NONINTERACTIVE -eq '1' -or [Console]::IsOutputRedirected) {
        'Line'
    } else {
        try { if ($null -ne $Host.UI.RawUI.WindowSize) { 'Interactive' } else { 'Line' } } catch { 'Line' }
    }
    if ($WindowWidth -le 0) {
        $WindowWidth = try { [Math]::Max(40, [int]$Host.UI.RawUI.WindowSize.Width) } catch { 80 }
    }
    $supportsUnicode = $null -ne $OutputEncoding -and $OutputEncoding.WebName -eq 'utf-8'
    $glyphs = if ($supportsUnicode) {
        [ordered]@{ Success = '✓'; Failure = '✗'; Updated = '~'; Separator = '—'; ProgressFilled = '█'; ProgressEmpty = '░'; Ellipsis = '…' }
    } else {
        [ordered]@{ Success = 'OK'; Failure = 'X'; Updated = '~'; Separator = '-'; ProgressFilled = '#'; ProgressEmpty = '.'; Ellipsis = '...' }
    }
    return [pscustomobject]@{
        Name = $mode + $(if ($supportsUnicode -and $mode -eq 'Line') { 'Utf8' } elseif ($supportsUnicode) { 'Unicode' } else { 'Ascii' })
        IsInteractive = $mode -eq 'Interactive'
        OutputRedirected = [Console]::IsOutputRedirected
        SupportsUnicode = $supportsUnicode
        SupportsAnsi = $false
        WindowWidth = $WindowWidth
        OutputEncoding = $OutputEncoding
        Glyphs = $glyphs
    }
}

function Get-TerminalDisplayWidth {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '')

    $width = 0
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $code = [int]$Text[$index]
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($Text, $index)
        if ($category -in @([Globalization.UnicodeCategory]::NonSpacingMark, [Globalization.UnicodeCategory]::EnclosingMark, [Globalization.UnicodeCategory]::Format, [Globalization.UnicodeCategory]::Control)) { continue }
        if ([char]::IsHighSurrogate($Text[$index]) -and $index + 1 -lt $Text.Length -and [char]::IsLowSurrogate($Text[$index + 1])) {
            $index++
            $width += 2
        } elseif (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE10 -and $code -le 0xFE19) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF01 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
            $width += 2
        } else {
            $width++
        }
    }
    return $width
}

function Pad-TerminalText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text = '',
        [Parameter(Mandatory = $true)][int]$Width
    )

    return $Text + (' ' * [Math]::Max(0, $Width - (Get-TerminalDisplayWidth $Text)))
}

function Truncate-TerminalText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text = '',
        [Parameter(Mandatory = $true)][int]$Width,
        [string]$Ellipsis = '…'
    )

    if ($Width -le 0) { return '' }
    if ((Get-TerminalDisplayWidth $Text) -le $Width) { return $Text }
    $available = [Math]::Max(0, $Width - (Get-TerminalDisplayWidth $Ellipsis))
    $builder = New-Object Text.StringBuilder
    $used = 0
    $elements = [Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($elements.MoveNext()) {
        $element = [string]$elements.Current
        $elementWidth = Get-TerminalDisplayWidth $element
        if ($used + $elementWidth -gt $available) { break }
        [void]$builder.Append($element)
        $used += $elementWidth
    }
    return $builder.ToString() + $(if ((Get-TerminalDisplayWidth $Ellipsis) -le $Width) { $Ellipsis } else { '' })
}

function Format-InstallProgressStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Step,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][int]$Percent,
        [string]$Detail = '',
        [string]$Elapsed = '00:00:00'
    )

    $hasCategory = $Step.PSObject.Properties.Name -contains 'CategoryIndex' -and [int]$Step.CategoryTotal -gt 0
    $prefix = if ($hasCategory) { '{0} {1}/{2}  {3}%' -f $Step.Category, $Step.CategoryIndex, $Step.CategoryTotal, $Percent } else { '[{0}/{1}] {2}%' -f $Step.Index, $Total, $Percent }
    if ($Profile.WindowWidth -lt 80) {
        $status = "$prefix $($Step.Name)"
    } else {
        $status = "$prefix  $($Step.Name)  $Elapsed"
        if ($Profile.WindowWidth -ge 120 -and -not [string]::IsNullOrWhiteSpace($Detail)) {
            $status += " $($Profile.Glyphs.Separator) $Detail"
        }
    }
    return Truncate-TerminalText -Text $status -Width $Profile.WindowWidth -Ellipsis $Profile.Glyphs.Ellipsis
}

function Write-InstallConsoleLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [AllowEmptyString()][string]$Text = ''
    )

    Write-Host (Truncate-TerminalText -Text $Text -Width $Progress.RendererProfile.WindowWidth -Ellipsis $Progress.RendererProfile.Glyphs.Ellipsis)
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
        [ValidateSet('Auto', 'Interactive', 'Line')][string]$RendererMode = 'Auto',
        $RendererProfile
    )

    $logDirectory = Join-Path $Root 'logs\installer'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    $startedAt = Get-Date
    $logPath = Join-Path $logDirectory ('install-{0}.log' -f $startedAt.ToString('yyyyMMdd-HHmmss'))
    $profile = if ($null -ne $RendererProfile) { $RendererProfile } else { New-InstallRendererProfile -RendererMode $RendererMode }
    $resolvedRendererMode = if ($profile.IsInteractive) { 'Interactive' } else { 'Line' }
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
        RendererProfile = $profile
    }
    [IO.File]::WriteAllText($logPath, '', (New-Object Text.UTF8Encoding($false)))
    $metadataText = @($Metadata.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; '
    Write-InstallLog -Progress $progress -Message $(if ([string]::IsNullOrWhiteSpace($metadataText)) { 'INSTALL START' } else { "INSTALL START $metadataText" })
    return $progress
}

function Get-InstallProgressStep($Progress, [string]$StepId) {
    return @($Progress.Steps | Where-Object { [string]$_.Id -eq $StepId } | Select-Object -First 1)[0]
}

function Write-InstallProgressDisplay($Progress, $Step, [string]$Detail) {
    $total = [Math]::Max(1, @($Progress.Steps).Count)
    $percent = [int][Math]::Floor((([int]$Step.Index - 1) / $total) * 100)
    if ($Progress.RendererMode -eq 'Interactive') {
        $status = Format-InstallProgressStatus -Profile $Progress.RendererProfile -Step $Step -Total $total -Percent $percent -Detail $Detail -Elapsed $Progress.Stopwatch.Elapsed.ToString('hh\:mm\:ss')
        Write-Progress -Id 1 -Activity 'Codex Settings' -Status $status -PercentComplete $percent
    } else {
        Write-InstallConsoleLine -Progress $Progress -Text ("STEP START {0}/{1} {2}: {3}" -f $Step.Index, $total, $Step.Name, $Detail)
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
        $status = Format-InstallProgressStatus -Profile $Progress.RendererProfile -Step $step -Total $total -Percent $percent -Detail $Result -Elapsed $Progress.Stopwatch.Elapsed.ToString('hh\:mm\:ss')
        Write-Progress -Id 1 -Activity 'Codex Settings' -Status $status -PercentComplete $percent
    } else {
        Write-InstallConsoleLine -Progress $Progress -Text ("STEP END {0}/{1} {2}: {3} ({4:N1}s)" -f $step.Index, $total, $step.Name, $Result, $step.ElapsedSeconds)
    }
    Write-InstallLog -Progress $Progress -Message ("STEP END {0}: {1}; elapsed={2:N1}s" -f $step.Id, $Result, $step.ElapsedSeconds)
}

function Fail-InstallStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [Parameter(Mandatory = $true)][string]$Reason,
        [switch]$Continue
    )

    $step = $Progress.CurrentStep
    $stepName = if ($null -ne $step) { [string]$step.Name } else { '安裝流程' }
    if ($null -ne $step) {
        $elapsed = if ($null -ne $Progress.CurrentStepStartedAt) { ((Get-Date) - $Progress.CurrentStepStartedAt).TotalSeconds } else { 0 }
        $step.Status = 'Failed'
        $step.Result = $Reason
        $step.ElapsedSeconds = [Math]::Round($elapsed, 1)
    }
    $Progress.Status = if ($Continue) { 'PartialSuccess' } else { 'Failed' }
    if ($null -eq $Progress.FailureStep) { $Progress.FailureStep = $stepName; $Progress.FailureReason = $Reason }
    if ($Progress.RendererMode -eq 'Line') { Write-InstallConsoleLine -Progress $Progress -Text ("STEP FAILED {0}: {1}" -f $stepName, $Reason) }
    Write-InstallLog -Progress $Progress -Message ("STEP FAILED {0}: {1}" -f $stepName, $Reason)
}

function Get-InstallResultSymbol([string]$Status, $Glyphs) {
    switch -Regex ($Status) {
        '^(?:Installed|Created|Enabled)$' { return '+' }
        '^Updated$' { return '~' }
        '^(?:Existing|Unchanged|Current|Validated)$' { return '=' }
        '^(?:Skipped|SkippedByUser|SkippedUnchanged|NotConfigured)$' { return '-' }
        '^ActionRequired$' { return '!' }
        '^Failed$' { return $(if ($null -ne $Glyphs) { $Glyphs.Failure } else { '✗' }) }
        default { return '=' }
    }
}

function Write-InstallResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Progress,
        [ValidateSet('SUCCESS', 'PARTIAL SUCCESS', 'FAILED')][string]$Status = 'SUCCESS',
        [hashtable]$Summary = @{},
        [object[]]$Results = @(),
        [object[]]$Components = @()
    )

    $Progress.Status = $Status
    if ($Progress.RendererMode -eq 'Interactive') { Write-Progress -Id 1 -Activity 'Codex Settings' -Completed }
    $profile = $Progress.RendererProfile
    $glyphs = $profile.Glyphs
    Write-Host ''
    Write-Host ('=' * 60)
    Write-Host $(if ($Status -eq 'SUCCESS') { '安裝完成' } elseif ($Status -eq 'PARTIAL SUCCESS') { '安裝部分完成' } else { '安裝失敗' })
    Write-Host ('=' * 60)
    Write-Host "Result: $Status"
    Write-Host ("Elapsed: {0:N1}s" -f $Progress.Stopwatch.Elapsed.TotalSeconds)
    if ($Progress.Metadata.ContainsKey('Environment')) { Write-Host "Environment: $($Progress.Metadata.Environment)" }
    if ($Progress.Metadata.ContainsKey('InstallStyle')) { Write-Host "Mode: $($Progress.Metadata.InstallStyle)" }
    Write-Host ''
    Write-Host '步驟'
    foreach ($step in @($Progress.Steps | Where-Object Status -ne 'Pending')) {
        $symbol = if ($step.Status -eq 'Completed') { $glyphs.Success } elseif ($step.Status -eq 'Failed') { $glyphs.Failure } else { $glyphs.ProgressEmpty }
        $name = Pad-TerminalText -Text (Truncate-TerminalText -Text ([string]$step.Name) -Width 28 -Ellipsis $glyphs.Ellipsis) -Width 28
        Write-InstallConsoleLine -Progress $Progress -Text ("[{0}] {1} {2,6:N1}s  {3}" -f $symbol, $name, $step.ElapsedSeconds, $step.Result)
    }
    if (@($Results).Count -gt 0) {
        Write-Host ''
        Write-Host '安裝內容'
        foreach ($result in @($Results)) {
            Write-InstallConsoleLine -Progress $Progress -Text ("{0}: {1}" -f $result.Mode, $result.Root)
            foreach ($file in @($result.Files)) {
                $fileStatus = [string]$file.Status
                if ([string]::IsNullOrWhiteSpace($fileStatus)) {
                    $fileStatus = if (-not [bool]$file.ExistedBefore) { 'Installed' } elseif ([bool]$file.Changed) { 'Updated' } else { 'Unchanged' }
                }
                Write-InstallConsoleLine -Progress $Progress -Text ("  [{0}] {1}  {2}" -f (Get-InstallResultSymbol $fileStatus $glyphs), $file.RelativePath, $fileStatus)
            }
        }
    }
    if (@($Components).Count -gt 0) {
        Write-Host ''
        Write-Host '外部元件'
        foreach ($category in @('Personal', 'Community')) {
            $categoryComponents = @($Components | Where-Object { $_.Category -eq $category -or ($category -eq 'Community' -and [string]::IsNullOrWhiteSpace([string]$_.Category)) })
            if ($categoryComponents.Count -eq 0) { continue }
            Write-InstallConsoleLine -Progress $Progress -Text $(if ($category -eq 'Personal') { '個人 Codex Settings' } else { '社區／開源元件' })
            foreach ($component in $categoryComponents) {
                $componentResult = [string]$component.Result
                if ($componentResult -match '[\r\n]') {
                    Write-InstallConsoleLine -Progress $Progress -Text ("  [{0}] {1}  {2}" -f (Get-InstallResultSymbol ([string]$component.Status) $glyphs), $component.Name, $component.Status)
                    Write-Host $componentResult
                } else {
                    Write-InstallConsoleLine -Progress $Progress -Text ("  [{0}] {1}  {2}  {3}" -f (Get-InstallResultSymbol ([string]$component.Status) $glyphs), $component.Name, $component.Status, $componentResult)
                }
            }
        }
    }
    Write-Host ''
    Write-Host '統計'
    if ($Summary.ContainsKey('PersonalStats') -and $Summary.ContainsKey('CommunityStats')) {
        foreach ($category in @('Personal', 'Community')) {
            Write-Host $category
            $stats = $Summary[$category + 'Stats']
            foreach ($name in @('Installed', 'Updated', 'Unchanged', 'Skipped', 'Failed')) { Write-Host ("  {0}: {1}" -f $name, $stats[$name]) }
        }
    } else {
        foreach ($name in @('Installed', 'Updated', 'Unchanged', 'Skipped', 'Failed')) {
            $value = if ($Summary.ContainsKey($name)) { $Summary[$name] } else { 0 }
            Write-Host ("{0}: {1}" -f $name, $value)
        }
    }
    $rollback = if ($Summary.ContainsKey('Rollback')) { [string]$Summary.Rollback } else { 'N/A' }
    Write-Host "Rollback: $rollback"
    foreach ($name in @('PersonalResult', 'CommunityResult', 'OverallResult')) {
        if ($Summary.ContainsKey($name)) { Write-Host ("{0}: {1}" -f $name, $Summary[$name]) }
    }
    if ($Status -eq 'FAILED') {
        Write-InstallConsoleLine -Progress $Progress -Text "失敗階段：$($Progress.FailureStep)"
        Write-InstallConsoleLine -Progress $Progress -Text "原因：$($Progress.FailureReason)"
    }
    if ($Summary.ContainsKey('Footer') -and -not [string]::IsNullOrWhiteSpace([string]$Summary.Footer)) { Write-InstallConsoleLine -Progress $Progress -Text ([string]$Summary.Footer) }
    Write-InstallConsoleLine -Progress $Progress -Text "Log: $($Progress.LogPath)"
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
