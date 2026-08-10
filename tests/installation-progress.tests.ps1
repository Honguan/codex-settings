$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-installation-progress-' + [guid]::NewGuid().ToString('N'))
try {
    $baseSteps = @(New-InstallationProgressSteps)
    if ($baseSteps.Id -contains 'Skills' -or $baseSteps.Id -contains 'CodexOrchestration' -or $baseSteps.Id -contains 'Serena' -or $baseSteps.Id -contains 'Notifications') {
        throw '未選用的選配階段不應佔用安裝進度。'
    }

$fullSteps = @(New-InstallationProgressSteps -TargetCount 2 -IncludeSkills -IncludeCodexOrchestration -IncludeSerena -IncludeNotifications -IncludeUsageTools)
    foreach ($requiredId in @('Prerequisites', 'Plan', 'Lock', 'Backup', 'Targets', 'Hooks', 'PersonalCheckpoint', 'Skills', 'CodexOrchestration', 'Serena', 'Notifications', 'UsageTools', 'Final')) {
        if ($fullSteps.Id -notcontains $requiredId) { throw "缺少安裝進度階段：$requiredId" }
    }
    if (@($fullSteps | Where-Object Id -eq 'Targets')[0].TargetCount -ne 2) { throw '安裝進度未記錄目標數量。' }

    $script:progressCalls = New-Object 'System.Collections.Generic.List[object]'
    function Write-Progress {
        param([int]$Id, [string]$Activity, [string]$Status, [int]$PercentComplete, [switch]$Completed)
        [void]$script:progressCalls.Add([pscustomobject]@{ Id = $Id; Status = $Status; Percent = $PercentComplete; Completed = [bool]$Completed })
    }

    $dynamicRoot = Join-Path $testRoot 'dynamic'
    $dynamicSteps = @(New-InstallationProgressSteps)
    $dynamicProgress = Start-InstallProgress -Steps $dynamicSteps -Root $dynamicRoot -RendererMode Interactive
    Set-InstallProgress -Progress $dynamicProgress -StepId 'Plan' -Detail '第一個動態步驟'
    $firstDynamicCall = $script:progressCalls[0]
    $personalCount = @($dynamicSteps | Where-Object Category -eq 'Personal').Count
    if ($dynamicSteps[0].Id -ne 'Plan' -or $firstDynamicCall.Percent -ne 0 -or $firstDynamicCall.Status -notmatch "Personal 1/$personalCount") { throw '動態步驟的第一階段未從一致的 0% 與 Personal 1/total 開始。' }
    Complete-InstallStep -Progress $dynamicProgress -Result '完成'
    $completedDynamicCall = $script:progressCalls[$script:progressCalls.Count - 1]
    $expectedFirstCompletion = [int][Math]::Round(100 / $dynamicSteps.Count)
    if ($completedDynamicCall.Percent -ne $expectedFirstCompletion) { throw "第一個動態步驟完成比例錯誤：expected=$expectedFirstCompletion actual=$($completedDynamicCall.Percent)" }
    $script:progressCalls.Clear()

    $interactiveRoot = Join-Path $testRoot 'interactive'
    $interactiveSteps = @(New-InstallationProgressSteps)
    $interactiveProgress = Start-InstallProgress -Steps $interactiveSteps -Root $interactiveRoot -Metadata @{ Test = 'interactive-progress' } -RendererMode Interactive
    $runningOutput = (& {
        Set-InstallProgress -Progress $interactiveProgress -StepId 'Plan' -Detail '整理安裝計畫'
        Complete-InstallStep -Progress $interactiveProgress -Result '已建立 1 個目標'
        Set-InstallProgress -Progress $interactiveProgress -StepId 'Prerequisites' -Detail '驗證環境'
        Complete-InstallStep -Progress $interactiveProgress -Result '通過'
    } 6>&1 | Out-String)
    if ($runningOutput -match '\[(?:✓|✗)\]' -or $runningOutput -match '(?m)^\[[█░]+\]') { throw '互動式安裝期間不應永久輸出進度條或 Step 歷史行。' }
    if (@($script:progressCalls | Where-Object Id -ne 1).Count -ne 0 -or @($script:progressCalls | Where-Object Completed).Count -ne 0) { throw '互動式安裝期間只能維持一個未完成的 installation progress record。' }

    $finalOutput = (& { Write-InstallResult -Progress $interactiveProgress -Status SUCCESS -Summary @{ Installed = 0; Updated = 0; Unchanged = 0; Skipped = 0 } } 6>&1 | Out-String)
    if (@($script:progressCalls | Where-Object Completed).Count -ne 1) { throw '最終摘要前未清除 installation progress record。' }
    foreach ($stepName in @('安裝計畫', '前置需求檢查')) {
        if (@([regex]::Matches($finalOutput, [regex]::Escape($stepName))).Count -ne 1) { throw "完成 Step 未在最終摘要中恰好顯示一次：$stepName" }
    }
    if ($finalOutput -notmatch '\[✓\].*安裝計畫.*已建立 1 個目標' -or $finalOutput -notmatch '\[✓\].*前置需求檢查.*通過') { throw '最終摘要未使用 Progress.Steps 顯示完整 Step 結果。' }

    $fileResults = @(
        [pscustomobject]@{ RelativePath = 'config.toml'; Status = 'Unchanged'; Changed = $false; ExistedBefore = $true },
        [pscustomobject]@{ RelativePath = 'hooks.json'; Status = 'Updated'; Changed = $true; ExistedBefore = $true },
        [pscustomobject]@{ RelativePath = 'hooks\show-codex-notification.ps1'; Status = 'Installed'; Changed = $true; ExistedBefore = $false },
        [pscustomobject]@{ RelativePath = 'optional.txt'; Status = 'Skipped'; Changed = $false; ExistedBefore = $false }
    )
    $installationResults = @([pscustomobject]@{ Mode = 'Global'; Root = 'C:\Users\tester\.codex'; Files = $fileResults })
    $components = @(
        [pscustomobject]@{ Name = 'ccusage'; Status = 'Existing'; Result = '20.0.19' },
        [pscustomobject]@{ Name = 'ccsessions'; Status = 'Updated'; Result = 'Profile 已更新' },
        [pscustomobject]@{ Name = 'Windows notifications'; Status = 'Unchanged'; Result = 'Hook 未變更' }
    )
    $contentOutput = (& { Write-InstallResult -Progress $interactiveProgress -Status SUCCESS -Summary @{ Installed = 1; Updated = 1; Unchanged = 1; Skipped = 1 } -Results $installationResults -Components $components } 6>&1 | Out-String)
    foreach ($expected in @('[=] config.toml', '[~] hooks.json', '[+] hooks\show-codex-notification.ps1', '[-] optional.txt', '[=] ccusage', '[~] ccsessions', '[=] Windows notifications')) {
        if (-not $contentOutput.Contains($expected)) { throw "最終摘要缺少安裝內容：$expected" }
    }
    $staleSummaryResult = [pscustomobject]@{ Files = $fileResults; Summary = [pscustomobject]@{ Created = 4; Installed = 4; Updated = 0; Unchanged = 0; Failed = 0 } }
    $recomputedSummary = Get-InstallResultSummary -Results @($staleSummaryResult)
    if ($recomputedSummary.Installed -ne 1 -or $recomputedSummary.Updated -ne 1 -or $recomputedSummary.Unchanged -ne 1 -or $recomputedSummary.Skipped -ne 1) { throw '最終統計未依 InstallationResult.Files 的最終狀態重新計算。' }

    $runnerProgress = Start-InstallProgress -Steps @(New-InstallationProgressSteps) -Root (Join-Path $testRoot 'runner-summary') -Metadata @{ Environment = 'Git'; InstallStyle = 'Merge' } -RendererMode Interactive
    Set-InstallProgress -Progress $runnerProgress -StepId 'Plan' -Detail '建立計畫'
    Complete-InstallStep -Progress $runnerProgress -Result '完成'
    $ccusageBefore = [pscustomobject]@{ Installed = $true; Version = '20.0.19' }
    $ccusage = [pscustomobject]@{ PackageInstalledNow = $false; CommandsUpdated = $true; PackageAfter = [pscustomobject]@{ Version = '20.0.19' } }
    $hookTrust = [pscustomobject]@{ Skipped = $false; TrustedCount = 3; UpdatedCount = 1 }
    $runnerOutput = (& {
        Write-InstallationSummary -InstallStyle Merge -DevelopmentEnvironment Git -Results $installationResults -Ccusage $ccusage -CcusageBefore $ccusageBefore -HookTrust $hookTrust -TransactionRoot 'C:\backup' -InstallWindowsNotifications $true -InstallUsageTools $true -Progress $runnerProgress -NotificationStatus '測試通知已顯示' -UsageStatus '已更新用量指令' -SkippedCount 0 -InstallMattPocockSkills $false -EnableDefaultModeRequestUserInput $true
    } 6>&1 | Out-String)
    if (@([regex]::Matches($runnerOutput, '(?m)^安裝完成')).Count -ne 1) { throw 'runner 不應先輸出舊摘要再輸出第二份最終摘要。' }
    foreach ($expected in @('config.toml', 'hooks.json', '個人 Codex Settings', 'Other Settings', 'Long-running async wait policy', '社區／開源元件', 'Codex Settings', 'mattpocock/skills', 'request_user_input feature', 'Windows 開發狀態通知', 'ccusage、ccsessions、cdaily 用量指令')) {
        if (-not $runnerOutput.Contains($expected)) { throw "runner 最終摘要缺少處理結果：$expected" }
    }
    foreach ($expected in @('PersonalResult: SUCCESS', 'CommunityResult: SUCCESS', 'OverallResult: SUCCESS', 'Personal', 'Community')) {
        if (-not $runnerOutput.Contains($expected)) { throw "runner 最終摘要缺少分區結果或統計：$expected" }
    }

    $planProgress = Start-InstallProgress -Steps @(New-InstallationProgressSteps) -Root (Join-Path $testRoot 'plan-output') -RendererMode Interactive
    $planContext = [pscustomobject]@{ DevelopmentEnvironment = 'Git'; InstallStyle = 'Merge'; GlobalRoot = 'C:\Users\tester\.codex'; InstallWindowsNotifications = $true; InstallUsageTools = $false }
    $planTargets = @([pscustomobject]@{ Mode = 'Global'; Root = $planContext.GlobalRoot })
    $planOutput = (& { Write-InstallationPlan -Progress $planProgress -Context $planContext -Targets $planTargets -CcusageBefore $ccusageBefore } 6>&1 | Out-String)
    if (-not [string]::IsNullOrWhiteSpace($planOutput)) { throw '安裝計畫不得在互動執行期間繞過單一 progress renderer 輸出歷史內容。' }
    $planLog = Get-Content -LiteralPath $planProgress.LogPath -Raw
    if ($planLog -notmatch 'PLAN environment=Git; style=Merge; notifications=True; usageTools=False; targets=1') { throw '精簡 console 後 installer log 仍須保留完整 PLAN。' }
    if ($planLog -notmatch 'PLAN targetRoots=.*; ccusage=未選用，略過') { throw '未選用 usage tools 時不應規劃 ccusage 安裝。' }
    if ($planLog -notmatch 'PLAN Other Settings; Long-running async wait policy=Install') { throw '安裝計畫未獨立列出 async-wait Other Setting。' }

    $lineProgress = Start-InstallProgress -Steps @(New-InstallationProgressSteps) -Root (Join-Path $testRoot 'line-mode') -RendererMode Line
    $lineOutput = (& {
        Set-InstallProgress -Progress $lineProgress -StepId 'Plan' -Detail '建立計畫'
        Complete-InstallStep -Progress $lineProgress -Result '完成'
    } 6>&1 | Out-String)
    if (@([regex]::Matches($lineOutput, '(?m)^STEP START ')).Count -ne 1 -or @([regex]::Matches($lineOutput, '(?m)^STEP END ')).Count -ne 1) { throw 'line-mode 每個 Step 事件必須只輸出一行。' }
    if ($lineOutput.Contains([char]27) -or $lineOutput -match '[█░]') { throw 'redirected / line-mode 不得輸出 ANSI 游標控制或互動式進度條。' }

    $setupPrompt = '$codex-orchestration:codex-orchestration setup executor: GPT-5.6 Luna Extra High'
    $actionComponents = @([pscustomobject]@{ Category = 'Community'; Name = 'Codex-Orchestration workflow'; Status = 'ActionRequired'; Result = "請建立新的 Codex Task 並貼上：`n`n$setupPrompt" })
    $actionOutput = (& { Write-InstallResult -Progress $lineProgress -Status 'PARTIAL SUCCESS' -Summary @{ PersonalResult = 'SUCCESS'; CommunityResult = 'PARTIAL SUCCESS'; OverallResult = 'PARTIAL SUCCESS' } -Components $actionComponents } 6>&1 | Out-String)
    if (-not $actionOutput.Contains($setupPrompt) -or $actionOutput.Contains([char]27) -or $actionOutput -match '失敗階段：') { throw 'line-mode ActionRequired 摘要未完整輸出 Prompt，或誤報為失敗。' }

    $failureSteps = @(New-InstallationProgressSteps | Select-Object -First 6)
    $failureProgress = Start-InstallProgress -Steps $failureSteps -Root (Join-Path $testRoot 'failure') -RendererMode Interactive
    $script:progressCalls.Clear()
    foreach ($step in @($failureSteps | Select-Object -First 5)) {
        Set-InstallProgress -Progress $failureProgress -StepId $step.Id -Detail "執行 $($step.Name)"
        Complete-InstallStep -Progress $failureProgress -Result '完成'
    }
    $failedStep = $failureSteps[5]
    Set-InstallProgress -Progress $failureProgress -StepId $failedStep.Id -Detail '人工失敗'
    Fail-InstallStep -Progress $failureProgress -Reason 'intentional step failure'
    $failureOutput = (& { Write-InstallResult -Progress $failureProgress -Status FAILED -Summary @{ Installed = 1; Updated = 2; Unchanged = 3; Skipped = 0; Rollback = 'SUCCESS' } -Results $installationResults } 6>&1 | Out-String)
    if (@($script:progressCalls | Where-Object Completed).Count -ne 1) { throw '失敗摘要前未清除互動式 progress record。' }
    foreach ($step in @($failureSteps | Select-Object -First 5)) {
        if ($failureOutput -notmatch ('\[✓\].*' + [regex]::Escape($step.Name))) { throw "失敗摘要缺少已完成 Step：$($step.Name)" }
    }
    if ($failureOutput -notmatch ('\[✗\].*' + [regex]::Escape($failedStep.Name) + '.*intentional step failure') -or $failureOutput -notmatch 'Rollback: SUCCESS' -or $failureOutput -notmatch '原因：intentional step failure') { throw '失敗摘要缺少失敗 Step、reason 或 rollback。' }

    $progress = Start-InstallProgress -Steps $fullSteps -Root $testRoot -Metadata @{ Test = 'installation-progress' }
    Set-InstallProgress -Progress $progress -StepId 'Plan' -Detail '測試安裝計畫'
    Complete-InstallStep -Progress $progress -Result '通過'
    Set-InstallProgress -Progress $progress -StepId 'Hooks' -Detail '測試錯誤診斷'
    try {
        throw 'Hook trust failed with SERVICE_API_KEY=do-not-log-this-secret'
    } catch {
        Write-InstallErrorRecord -Progress $progress -ErrorRecord $_ -CurrentSubOperation 'HookTrust'
    }
    Complete-InstallStep -Progress $progress -Result '診斷已記錄'
    $summary = [ordered]@{ Installed = 1; Updated = 2; Unchanged = 3; Skipped = 4; Rollback = 'N/A' }
    Write-InstallResult -Progress $progress -Status SUCCESS -Summary $summary

    if (-not (Test-Path -LiteralPath $progress.LogPath -PathType Leaf)) { throw '安裝 log 未建立。' }
    $log = Get-Content -LiteralPath $progress.LogPath -Raw
    foreach ($marker in @(
        'INSTALL START',
        'STEP START Plan',
        'STEP END Plan',
        'ERROR CurrentStepId=Hooks; CurrentSubOperation=HookTrust',
        'ExceptionType=System.Management.Automation.RuntimeException',
        'Message=Hook trust failed with SERVICE_API_KEY=<REDACTED>',
        'FullyQualifiedErrorId=',
        'CategoryInfo=',
        'InvocationInfo.MyCommand=',
        'InvocationInfo.ScriptName=',
        'InvocationInfo.ScriptLineNumber=',
        'InvocationInfo.PositionMessage=',
        'ScriptStackTrace=',
        'INSTALL END status=SUCCESS'
    )) {
        if ($log -notmatch [regex]::Escape($marker)) { throw "安裝 log 缺少記錄：$marker" }
    }
    if ($log -match 'do-not-log-this-secret') { throw '安裝 log 洩漏敏感值。' }
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
