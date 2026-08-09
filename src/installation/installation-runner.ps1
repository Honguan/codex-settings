function Invoke-ManagementMode {
    param(
        [ValidateSet('Backup', 'Restore', 'Uninstall')]
        [string]$Mode,
        [string]$SourceRoot
    )

    $actionScripts = @{
        Backup = 'commands\backup-settings.ps1'
        Restore = 'commands\restore-settings.ps1'
        Uninstall = 'commands\uninstall-settings.ps1'
    }
    $actionScript = Join-Path $SourceRoot $actionScripts[$Mode]
    if (-not (Test-Path -LiteralPath $actionScript -PathType Leaf)) { throw "ç®¡ç†åŠŸèƒ½ä¸å­˜åœ¨ï¼š$actionScript" }
    if ($Mode -eq 'Restore') { & $actionScript }
    else { & $actionScript -Mode Global }
}

function Invoke-InteractiveMode {
    param(
        [ValidateSet('Git', 'CVS')]
        [string]$DevelopmentEnvironment,
        [string]$GlobalRoot,
        [string]$SourceRoot
    )

    while ($true) {
        try {
            $selection = Select-Mode
            if ($selection -eq 'Exit') { return }

            if ($selection -eq 'Global') {
                $style = Select-InstallStyle
                $selectedEnvironment = Select-DevelopmentEnvironment -Default $DevelopmentEnvironment
                $installRequestExecutionOptimizer = Select-OptionalGlobalSkill
                $installMattPocockSkills = Select-OptionalMattPocockSkills
                $ponytailState = Get-PonytailInstallationState
                $installPonytail = Select-OptionalPonytail -AlreadyInstalled:([bool]$ponytailState.PluginPresent)
                $installCodexOrchestration = Select-OptionalCodexOrchestration
                $installSerena = Select-OptionalSerena
                $installSerenaUv = $false
                if ($installSerena -and -not (Test-SerenaUvAvailable)) { $installSerenaUv = Select-SerenaUvInstallation }
                $enableDefaultModeRequestUserInput = Select-OptionalDefaultModeRequestUserInput
                $installWindowsNotifications = Select-OptionalWindowsNotifications -AlreadyInstalled:(Test-WindowsNotificationsInstalled -Root $GlobalRoot)
                Invoke-Installer -Mode Global -InstallStyle $style -DevelopmentEnvironment $selectedEnvironment -InstallRequestExecutionOptimizer:$installRequestExecutionOptimizer -InstallMattPocockSkills:$installMattPocockSkills -InstallPonytail:$installPonytail -InstallCodexOrchestration:$installCodexOrchestration -ConfigureCodexOrchestration:$installCodexOrchestration -InstallSerena:$installSerena -InstallSerenaUv:$installSerenaUv -EnableDefaultModeRequestUserInput:$enableDefaultModeRequestUserInput -InstallWindowsNotifications:$installWindowsNotifications -SourceRoot $SourceRoot
                return
            }

            Invoke-ManagementMode -Mode $selection -SourceRoot $SourceRoot
        } catch {
            Write-Host "ä½œæ¥­å¤±æ•—ï¼š$($_.Exception.Message)" -ForegroundColor Red
        }

        Write-Host ''
        [void](Read-Host 'æŒ‰ Enter è¿”å›å®‰è£å™¨é¸å–®')
    }
}

function Invoke-InstallationRollback($Transaction, $CcusageBefore, $ContextState, $CodexOrchestration, [string]$Reason) {
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $Transaction) {
        try { Undo-FileTransaction $Transaction | Out-Null } catch { [void]$rollbackErrors.Add("File rollback failed: $($_.Exception.Message)") }
    }
    if ($null -ne $CcusageBefore) {
        try { Restore-CcusageState $CcusageBefore | Out-Null } catch { [void]$rollbackErrors.Add("ccusage rollback failed: $($_.Exception.Message)") }
    }
    if ($null -ne $ContextState -and [bool]$ContextState.CreatedNow) {
        try {
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $ContextState.UserBefore, 'User')
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $ContextState.ProcessBefore, 'Process')
        } catch { [void]$rollbackErrors.Add("Context7 rollback failed: $($_.Exception.Message)") }
    }
    if ($null -ne $CodexOrchestration -and [bool]$CodexOrchestration.InstalledNow) {
        try { Undo-CodexOrchestrationInstallation -Result $CodexOrchestration } catch { [void]$rollbackErrors.Add("Codex-Orchestration rollback failed: $($_.Exception.Message)") }
    }
    if ($null -ne $Transaction) {
        try {
        Save-TransactionMetadata -Transaction $Transaction -Metadata @{
            Status = 'RolledBack'
            RolledBackAt = (Get-Date).ToString('o')
            FailureReason = $Reason
            RollbackErrors = $rollbackErrors.ToArray()
        }
        } catch { [void]$rollbackErrors.Add("Journal update failed: $($_.Exception.Message)") }
    }
    return $rollbackErrors.ToArray()
}

function Write-InstallationSummary {
    param(
        [string]$InstallStyle,
        [string]$DevelopmentEnvironment,
        [object[]]$Results,
        $Ccusage,
        $CcusageBefore,
        $HookTrust,
        [string]$TransactionRoot,
        [bool]$InstallWindowsNotifications,
        $Progress,
        [string]$NotificationStatus = '',
        [int]$SkippedCount = 0,
        [switch]$SkipContext7Key,
        [switch]$InstallMattPocockSkills,
        [switch]$InstallRequestExecutionOptimizer,
        [switch]$EnableDefaultModeRequestUserInput,
        $ContextState,
        [int]$SkillsCount = 0,
        $Ponytail,
        $CodexOrchestration,
        $Serena
    )

    if ($null -ne $Progress) {
        $fileSummary = Get-InstallResultSummary -Results $Results
        $fileSummary.Skipped = [int]$fileSummary.Skipped + $SkippedCount
        $fileSummary.Footer = 'è«‹å®Œå…¨é—œé–‰ä¸¦é‡æ–°å•Ÿå‹• VS Codeã€Codex èˆ‡ PowerShellï¼›æ—¢æœ‰ Session ä¸æœƒè¼‰å…¥æ–°å®‰è£çš„ Hookã€‚'
        $ccusageStatus = if ([bool]$Ccusage.PackageInstalledNow) { 'Installed' } elseif ([bool]$CcusageBefore.Installed) { 'Existing' } else { 'SkippedByUser' }
        $commandStatus = if ([bool]$Ccusage.CommandsUpdated) { 'Updated' } else { 'Unchanged' }
        $context7Status = if ($SkipContext7Key) { 'SkippedByUser' } elseif ($null -ne $ContextState -and [bool]$ContextState.CreatedNow) { 'Installed' } elseif ($null -ne $ContextState -and [bool]$ContextState.CreatedByInstaller) { 'Existing' } else { 'Unchanged' }
        $hookStatus = if ([bool]$HookTrust.Skipped) { 'SkippedUnchanged' } elseif ([int]$HookTrust.UpdatedCount -gt 0) { 'Updated' } else { 'Validated' }
        $notificationComponentStatus = if (-not $InstallWindowsNotifications) { 'SkippedByUser' } elseif ($NotificationStatus -match 'ç•¥é|æœªè®Šæ›´') { 'SkippedUnchanged' } else { 'Updated' }
        $components = @(
            [pscustomobject]@{ Name = 'Codex'; Status = 'Validated'; Result = "Environment=$DevelopmentEnvironment" }
            [pscustomobject]@{ Name = 'MCP / Context7'; Status = $context7Status; Result = $(if ($SkipContext7Key) { 'ä½¿ç”¨è€…ç•¥é' } else { 'ç’°å¢ƒè¨­å®šå·²è™•ç†' }) }
            [pscustomobject]@{ Name = 'ccusage'; Status = $ccusageStatus; Result = [string]$Ccusage.PackageAfter.Version }
            [pscustomobject]@{ Name = 'ccsessions'; Status = $commandStatus; Result = $(if ($Ccusage.CommandsUpdated) { 'Profile å·²æ›´æ–°' } else { 'Profile æœªè®Šæ›´' }) }
            [pscustomobject]@{ Name = 'cdaily'; Status = $commandStatus; Result = $(if ($Ccusage.CommandsUpdated) { 'Profile å·²æ›´æ–°' } else { 'Profile æœªè®Šæ›´' }) }
            [pscustomobject]@{ Name = 'request-execution-optimizer'; Status = $(if ($InstallRequestExecutionOptimizer) { 'Enabled' } else { 'SkippedByUser' }); Result = $(if ($InstallRequestExecutionOptimizer) { 'å·²é¸ç”¨' } else { 'æœªé¸ç”¨' }) }
            [pscustomobject]@{ Name = 'mattpocock/skills'; Status = $(if ($InstallMattPocockSkills) { 'Updated' } else { 'SkippedByUser' }); Result = $(if ($InstallMattPocockSkills) { "å·²è™•ç† $SkillsCount å€‹" } else { 'æœªé¸ç”¨' }) }
            [pscustomobject]@{ Name = 'request_user_input feature'; Status = $(if ($EnableDefaultModeRequestUserInput) { 'Enabled' } else { 'SkippedByUser' }); Result = $(if ($EnableDefaultModeRequestUserInput) { 'å·²å•Ÿç”¨' } else { 'æœªå•Ÿç”¨' }) }
            [pscustomobject]@{ Name = 'Windows é–‹ç™¼ç‹€æ…‹èˆ‡ä½¿ç”¨é‡é€šçŸ¥'; Status = $notificationComponentStatus; Result = $(if ($InstallWindowsNotifications) { $NotificationStatus + 'ï¼ˆé–‹ç™¼ç‹€æ…‹ + Token / Cost ä½¿ç”¨é‡ï¼‰' } else { 'æœªå®‰è£' }) }
            [pscustomobject]@{ Name = 'Hook trust'; Status = $hookStatus; Result = $(if ($HookTrust.Skipped) { 'æœªè®Šæ›´ï¼Œç•¥éé‡æ–° trust' } else { "å·²é©—è­‰ $($HookTrust.TrustedCount) å€‹ã€æ›´æ–° $($HookTrust.UpdatedCount) å€‹" }) }
        )
        $components += @(Get-PonytailInstallationComponents -Result $Ponytail)
        $components += @(Get-CodexOrchestrationInstallationComponents -Result $CodexOrchestration)
        $components += @(Get-SerenaInstallationComponents -Result $Serena)
        Write-InstallLog -Progress $Progress -Message ("SUMMARY transaction={0}; components={1}; files={2}" -f $TransactionRoot, $components.Count, @($Results.Files).Count)
        Write-InstallResult -Progress $Progress -Status SUCCESS -Summary $fileSummary -Results $Results -Components $components
    }
}

function Invoke-GlobalInstallation {
    param(
        $Context,
        [switch]$SkipContext7Key,
        [switch]$SkipCcusageInstall,
        [switch]$InstallRequestExecutionOptimizer,
        [switch]$InstallMattPocockSkills,
        [switch]$InstallPonytail,
        [switch]$SkipPonytail,
        [switch]$InstallCodexOrchestration,
        [switch]$SkipCodexOrchestration,
        [switch]$ConfigureCodexOrchestration,
        [switch]$InstallSerena,
        [switch]$SkipSerena,
        [switch]$InstallSerenaUv,
        [switch]$EnableDefaultModeRequestUserInput,
        [switch]$ForceValidation,
        [switch]$ForceNotificationTest,
        [ValidateSet('Auto', 'Interactive', 'Line')][string]$RendererMode = 'Auto'
    )

    if (-not $InstallMattPocockSkills -and (Test-MattPocockSkillsInstalled)) {
        $InstallMattPocockSkills = $true
    }
    $targets = @(New-InstallationPlan -DevelopmentEnvironment $Context.DevelopmentEnvironment -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -InstallWindowsNotifications $Context.InstallWindowsNotifications -SourceRoot $Context.ScriptRoot -IncludeExistingSkills $Context.ExistingSkillsInstalled)
    $steps = New-InstallationProgressSteps -TargetCount $targets.Count -IncludeContext7:(-not $SkipContext7Key) -IncludeSkills:$InstallMattPocockSkills -IncludePonytail:$InstallPonytail -IncludeCodexOrchestration:$InstallCodexOrchestration -IncludeSerena:$InstallSerena -IncludeNotifications:$Context.InstallWindowsNotifications
    $progress = Start-InstallProgress -Steps $steps -Root $Context.GlobalRoot -Metadata @{
        Mode = 'Global'
        Environment = $Context.DevelopmentEnvironment
        InstallStyle = $Context.InstallStyle
    } -RendererMode $RendererMode
    $operationLock = $null
    $transaction = $null
    $ccusageBefore = $null
    $contextState = $null
    $results = New-Object 'System.Collections.Generic.List[object]'
    $transactionRoot = $null
    $notificationStatus = ''
    $skippedCount = 0
    $discovery = $null
    $changePlan = $null
    $currentSubOperation = ''
    $mattPocockSkillNames = @()
    $ponytail = New-PonytailSkippedResult
    $codexOrchestration = New-CodexOrchestrationSkippedResult
    $serena = New-SerenaSkippedResult

    try {
        Set-InstallProgress -Progress $progress -StepId 'Plan' -Detail 'æ•´ç†ç›®æ¨™èˆ‡å¤–éƒ¨å¥—ä»¶ç‹€æ…‹'
        $ccusageBefore = Get-CcusageState
        $discovery = Get-InstallationDiscovery -Context $Context -Targets $targets -CcusageBefore $ccusageBefore
        Write-InstallationPlan -Progress $progress -Context $Context -Targets $targets -CcusageBefore $ccusageBefore -InstallRequestExecutionOptimizer:$InstallRequestExecutionOptimizer -InstallMattPocockSkills:$InstallMattPocockSkills -EnableDefaultModeRequestUserInput:$EnableDefaultModeRequestUserInput -SkipContext7Key:$SkipContext7Key
        Complete-InstallStep -Progress $progress -Result ("å·²å»ºç«‹ $($targets.Count) å€‹ç›®æ¨™")

        Set-InstallProgress -Progress $progress -StepId 'Prerequisites' -Detail 'é©—è­‰ PowerShellã€Node.jsã€Codex èˆ‡ç›®æ¨™ç›®éŒ„'
        Test-Prerequisites 'Global' $Context.GlobalRoot
        if ($InstallPonytail) { [void](Assert-PonytailPrerequisites) }
        if ($InstallCodexOrchestration) { [void](Assert-CodexOrchestrationPrerequisites) }
        foreach ($target in $targets) { Test-DirectoryWritable -Path $target.Root }
        Complete-InstallStep -Progress $progress -Result 'é€šé'

        Set-InstallProgress -Progress $progress -StepId 'Lock' -Detail 'å–å¾—å–®ä¸€å®‰è£æ“ä½œé–ä¸¦å›å¾©ä¸­æ–·äº¤æ˜“'
        $operationLock = Enter-CodexSettingsLock
        $recovered = @(Repair-PendingTransactions -BackupRoot $Context.BackupRoot)
        if ($recovered.Count -gt 0) { Write-InstallLog -Progress $progress -Message "RECOVERY restored=$($recovered.Count)" }
        Complete-InstallStep -Progress $progress -Result $(if ($recovered.Count -gt 0) { "å·²å›å¾© $($recovered.Count) ç­†äº¤æ˜“" } else { 'ç„¡å¾…å›å¾©äº¤æ˜“' })

        Set-InstallProgress -Progress $progress -StepId 'Backup' -Detail 'å»ºç«‹äº¤æ˜“ç›®éŒ„èˆ‡å¤–éƒ¨ç‹€æ…‹å¿«ç…§'
        New-Item -ItemType Directory -Path $Context.BackupRoot -Force | Out-Null
        $transactionRoot = Join-Path $Context.BackupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-global-transaction')
        $transaction = New-FileTransaction -Root $transactionRoot -Mode 'Install-Global'
        $context7KeyWasPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User'))
        $context7MayCreate = (-not $SkipContext7Key) -and (-not $context7KeyWasPresent)

        Save-TransactionMetadata -Transaction $transaction -Metadata @{
            Mode = 'Global'
            Status = 'InProgress'
            Discovery = $discovery
            CcusageBefore = $ccusageBefore
            Context7KeyWasPresent = $context7KeyWasPresent
            Context7InstallerMayCreate = $context7MayCreate
            Context7KeyCreatedNow = $false
        }
        Complete-InstallStep -Progress $progress -Result 'å·²å»ºç«‹äº¤æ˜“å‚™ä»½'

        try {
            Set-InstallProgress -Progress $progress -StepId 'Targets' -Detail ("è™•ç† $($targets.Count) å€‹å…¨åŸŸå®‰è£ç›®æ¨™")
            foreach ($result in @(Invoke-InstallationPlan -Targets $targets -Transaction $transaction -Discovery $discovery -Force:$Context.Force)) { [void]$results.Add($result) }
            Complete-InstallStep -Progress $progress -Result ("å®Œæˆ $($results.Count) å€‹ç›®æ¨™")

            [object[]]$resultArray = $results.ToArray()
            $changePlan = Ne×½<¶‰ËkºwµçV’[¦£¢/–ê<œô¤4(€€€€€€€€€€€€‘ÕÍ…”€ô¥˜€ ‘¡…¹•A±…¸¹ÕÍ…•Q½½±Í¡…¹•€µ½È€‘¡…¹•A±…¸¹ÉÕ¹UÍ…•IÕ¹Ñ¥µ•Y…±¥‘…Ñ¥½¸¤ì4(€€€€€€€€€€€€€€€€˜€¡)½¥¸µA…Ñ €‘½¹Ñ•áĞ¹MÉ¥ÁÑI½½Ğ€¥¹Ñ•É…Ñ¥½¹Íq¥¹ÍÑ…±°µÕÍ…”µÑ½½±Ì¹ÁÌÄœ¤€µM­¥ÁA…­…•%¹ÍÑ…±°è‘M­¥ÁÕÍ…•%¹ÍÑ…±°€µ½É•IÕ¹Ñ¥µ•Y…±¥‘…Ñ¥½¸è‘½É•Y…±¥‘…Ñ¥½¸€µA…­…•MÑ…Ñ”€‘ÕÍ…•	•™½É”€µQÉ…¹Í…Ñ¥½¸€‘ÑÉ…¹Í…Ñ¥½¸€µA…ÍÍQ¡ÉÔ€µ%¹™½Éµ…Ñ¥½¹Ñ¥½¸%¹½É”4(€€€€€€€€€€€ô•±Í”ì4(€€€€€€€€€€€€€€€9•ÜµÕÍ…•U¹¡…¹•‘I•ÍÕ±Ğ€µA…­…•MÑ…Ñ”€‘ÕÍ…•	•™½É”4(€€€€€€€€€€€ô4(€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±1½œ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µ5•ÍÍ…”€ ‰=559ÕÍ…”µÑ½½±ÌÁ…­…•	•™½É•%¹ÍÑ…±±•õìÁôì™½É•Y…±¥‘…Ñ¥½¸õìÅôìÍ­¥ÁÁ•õìÉôˆ€µ˜€‘ÕÍ…•	•™½É”¹%¹ÍÑ…±±•°€‘½É•Y…±¥‘…Ñ¥½¸°€‘ÕÍ…”¹M­¥ÁÁ•¤4(€€€€€€€€€€€½µÁ±•Ñ”µ%¹ÍÑ…±±MÑ•À€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µI•ÍÕ±Ğ€¡¥˜€ ‘ÕÍ…”¹½µµ…¹‘ÍUÁ‘…Ñ•¤ì€AÉ½™¥±”ƒ–ŞËšnÓšZÀœô•±Í”ì€AÉ½™¥±”ƒšr«¢º+šnĞœô¤4(4(€€€€€€€€€€€¥˜€ ‘%¹ÍÑ…±±5…ÑÑA½½­M­¥±±Ì¤ì4(€€€€€€€€€€€€€€€M•Ğµ%¹ÍÑ…±±AÉ½É•ÍÌ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µMÑ•Á%€M­¥±±Ìœ€µ•Ñ…¥°€Ÿ–>«–r£¦ãR£š"[–×šâ³–"Ãš^‹šr'š*¢÷šf–~ß¢†0¹Áàœ4(€€€€€€€€€€€€€€€€‘µ…ÑÑA½½­M­¥±±9…µ•Ì€ô ¡•Ğµ5…ÑÑA½½­M­¥±±9…µ•Ì¤4(€€€€€€€€€€€€€€€€‘Í­¥±±ÍÉÕµ•¹ÑÌ€ô ¡•Ğµ5…ÑÑA½½­M­¥±±ÍÉÕµ•¹ÑÌ¤4(€€€€€€€€€€€€€€€€‘Í­¥±±Í=ÕÑÁÕĞ€ô€˜¹ÁàÍ­¥±±ÍÉÕµ•¹ÑÌ€Èø˜Ä4(€€€€€€€€€€€€€€€¥˜€ ‘1MQa%Q=€µ¹”€À¤ìÑ¡É½Ü€‰µ…ÑÑÁ½½¬½Í­¥±±Ìƒ–º'¢w–’ÇšV_¾ò3ÖCšvŠó¾òh‘1MQa%Q=ˆô4(€€€€€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±1½œ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µ5•ÍÍ…”€ ‰=559¹ÁàÍ­¥±±Ì¥¹ÍÑ…±±•‘=ÉUÁ‘…Ñ•õìÁôˆ€µ˜€‘µ…ÑÑA½½­M­¥±±9…µ•Ì¹½Õ¹Ğ¤4(€€€€€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±1½œ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µ5•ÍÍ…”€ ‰=559=UQAUP¹ÁàÍ­¥±±ÌèìÁôˆ€µ˜€¡AÉ½Ñ•Ğµ%¹ÍÑ…±±1½Q•áĞ€ ‘Í­¥±±Í=ÕÑÁÕĞ€µ©½¥¸m¹Ù¥É½¹µ•¹Ñtèé9•İ1¥¹”¤¤¤4(€€€€€€€€€€€€€€€½µÁ±•Ñ”µ%¹ÍÑ…±±MÑ•À€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µI•ÍÕ±Ğ€ ‹–ŞË¢fWB€ ‘µ…ÑÑA½½­M­¥±±9…µ•Ì¹½Õ¹Ğ¤ƒ–/š*¢ôˆ¤4(€€€€€€€€€€€ô4(4(€€€€€€€€€€€¥˜€ ‘%¹ÍÑ…±±A½¹åÑ…¥°¤ì4(€€€€€€€€€€€€€€€M•Ğµ%¹ÍÑ…±±AÉ½É•ÍÌ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µMÑ•Á%€A½¹åÑ…¥°œ€µ•Ñ…¥°€ŸšnÓšZÀµ…É­•ÑÁ±…—–B3š¶”Á±Õ¥¸ƒ’â›¦¦_¢¶$€Èƒ–,±¥™•å±”¡½½­Ìœ4(€€€€€€€€€€€€€€€€‘Á½¹åÑ…¥°€ô%¹Ù½­”µA½¹åÑ…¥±%¹ÍÑ…±±…Ñ¥½¸€µMÑ…Ñ”€¡•ĞµA½¹åÑ…¥±%¹ÍÑ…±±…Ñ¥½¹MÑ…Ñ”¤€µI½½Ğ€‘½¹Ñ•áĞ¹±½‰…±I½½Ğ4(€€€€€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±1½œ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µ5•ÍÍ…”€ A=9eQ%0Á±Õ¥¸ôœ€¬€‘Á½¹åÑ…¥°¹A±Õ¥¹MÑ…ÑÕÌ€¬€œì¡½½­Ìôœ€¬€‘Á½¹åÑ…¥°¹!½½­½Õ¹Ğ€¬€œ¼ÈìÑÉÕÍĞôœ€¬€‘Á½¹åÑ…¥°¹QÉÕÍÑMÑ…ÑÕÌ¤4(€€€€€€€€€€€€€€€½µÁ±•Ñ”µ%¹ÍÑ…±±MÑ•À€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µI•ÍÕ±Ğ€ ‘Á½¹åÑ…¥°¹A±Õ¥¹MÑ…ÑÕÌ€¬€œì¡½½­Ì€œ€¬€‘Á½¹åÑ…¥°¹!½½­½Õ¹Ğ€¬€œ¼Èœ¤4(€€€€€€€€€€€ô4(4(€€€€€€€€€€€¥˜€ ‘%¹ÍÑ…±±½‘•á=É¡•ÍÑÉ…Ñ¥½¸¤ì4(€€€€€€€€€€€€€€€M•Ğµ%¹ÍÑ…±±AÉ½É•ÍÌ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µMÑ•Á%€½‘•á=É¡•ÍÑÉ…Ñ¥½¸œ€µ•Ñ…¥°€Ÿšª‹š~”AåÑ¡½»–º'¢t¿šnÓšZÀÁ±Õ¥»¢fWBİ½É­™±½Üƒ¢¢·–ºhœ4(€€€€€€€€€€€€€€€€‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸€ô%¹Ù½­”µ½‘•á=É¡•ÍÑÉ…Ñ¥½¹%¹ÍÑ…±±…Ñ¥½¸€µ%¹Ñ•É…Ñ¥Ù•]½É­™±½Üè‘½¹™¥ÕÉ•½‘•á=É¡•ÍÑÉ…Ñ¥½¸4(€€€€€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±1½œ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µ5•ÍÍ…”€ =`=I!MQIQ%=8Á±Õ¥¸ôœ€¬€‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹A±Õ¥¹MÑ…ÑÕÌ€¬€œìİ½É­™±½Üôœ€¬€‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹]½É­™±½İMÑ…ÑÕÌ¤4(€€€€€€€€€€€€€€€¥˜€ µ¹½ĞmÍÑÉ¥¹tèé%Í9Õ±±=É]¡¥Ñ•MÁ…” ‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹M•ÑÕÁAÉ½µÁĞ¤¤ì4(€€€€€€€€€€€€€€€€€€€]É¥Ñ”µ!½ÍĞ€œœ4(€€€€€€€€€€€€€€€€€€€]É¥Ñ”µ!½ÍĞ€l…t]½É­™±½ÜA•¹‘¥¹œÕÍ•ÈÍ•ÑÕÀœ4(€€€€€€€€€€€€€€€€€€€]É¥Ñ”µ!½ÍĞ€Ÿ¢®/–r£šZÃj½‘•àQ…Í¬ƒ–~ß¢†3¾òhœ4(€€€€€€€€€€€€€€€€€€€]É¥Ñ”µ!½ÍĞ€‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹M•ÑÕÁAÉ½µÁĞ4(€€€€€€€€€€€€€€€€€€€]É¥Ñ”µ!½ÍĞ€œ‘½‘•àµ½É¡•ÍÑÉ…Ñ¥½¸é½‘•àµ½É¡•ÍÑÉ…Ñ¥½¸ÍÑ…ÑÕÌ€´µÉ•ÅÕ¥É”µ•™™•Ñ¥Ù”œ4(€€€€€€€€€€€€€€€ô4(€€€€€€€€€€€€€€€½µÁ±•Ñ”µ%¹ÍÑ…±±MÑ•À€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µI•ÍÕ±Ğ€ ‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹A±Õ¥¹MÑ…ÑÕÌ€¬€œìİ½É­™±½Ü€œ€¬€‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹]½É­™±½İMÑ…ÑÕÌ¤4(€€€€€€€€€€€ô4(4(€€€€€€€€€€€¥˜€ ‘%¹ÍÑ…±±M•É•¹„¤ì4(€€€€€€€€€€€€€€€M•Ğµ%¹ÍÑ…±±AÉ½É•ÍÌ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µMÑ•Á%€M•É•¹„œ€µ•Ñ…¥°€Ÿšª‹š~”ÕÛ–º'¢wš"[šnÓšZÀM•É•¹‡–"w–/–2[’â›–º'–£¢¢·–ºh½‘•à5@œ4(€€€€€€€€€€€€€€€€‘Í•É•¹„€ô%¹Ù½­”µM•É•¹…%¹ÍÑ…±±…Ñ¥½¸€µI½½Ğ€‘½¹Ñ•áĞ¹±½‰…±I½½Ğ€µQÉ…¹Í…Ñ¥½¸€‘ÑÉ…¹Í…Ñ¥½¸€µ%¹ÍÑ…±±UØè‘%¹ÍÑ…±±M•É•¹…UØ4(€€€€€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±1½œ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µ5•ÍÍ…”€ MI9±¤ôœ€¬€‘Í•É•¹„¹Q½½±MÑ…ÑÕÌ€¬€œì¥¹¥Ğôœ€¬€‘Í•É•¹„¹%¹¥Ñ¥…±¥é…Ñ¥½¹MÑ…ÑÕÌ€¬€œìµÀôœ€¬€‘Í•É•¹„¹½‘•á5ÁMÑ…ÑÕÌ¤4(€€€€€€€€€€€€€€€½µÁ±•Ñ”µ%¹ÍÑ…±±MÑ•À€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µI•ÍÕ±Ğ€ ‘Í•É•¹„¹Q½½±MÑ…ÑÕÌ€¬€œì€œ€¬€‘Í•É•¹„¹½‘•á5ÁMÑ…ÑÕÌ¤4(€€€€€€€€€€€ô4(4(€€€€€€€€€€€€‘½É¥¥¹…°€ô€‘ÕÍ…•	•™½É”4(€€€€€€€€€€€€‘¥¹ÍÑ…±±•‘	åA…­…”€ôm‰½½±t‘ÕÍ…”¹A…­…•%¹ÍÑ…±±•‘9½Ü4(€€€€€€€€€€€¥˜€ ‘¹Õ±°€µ¹”€‘±½‰…°¹AÉ•Ù¥½ÕÌ€µ…¹€‘¹Õ±°€µ¹”€‘±½‰…°¹AÉ•Ù¥½ÕÌ¹áÑ•É¹…°€µ…¹€‘¹Õ±°€µ¹”€‘±½‰…°¹AÉ•Ù¥½ÕÌ¹áÑ•É¹…°¹ÕÍ…”¤ì4(€€€€€€€€€€€€€€€€‘½±€ô€‘±½‰…°¹AÉ•Ù¥½ÕÌ¹áÑ•É¹…°¹ÕÍ…”4(€€€€€€€€€€€€€€€€‘½É¥¥¹…°€ômÁÍÕÍÑ½µ½‰©•Ñuì%¹ÍÑ…±±•€ôm‰½½±t‘½±¹]…Í%¹ÍÑ…±±•‘	•™½É”ìY•ÉÍ¥½¸€ômÍÑÉ¥¹t‘½±¹AÉ•Ù¥½ÕÍY•ÉÍ¥½¸ô4(€€€€€€€€€€€€€€€€‘¥¹ÍÑ…±±•‘	åA…­…”€ôm‰½½±t‘½±¹%¹ÍÑ…±±•‘	åA…­…”4(€€€€€€€€€€€ô4(4(€€€€€€€€€€€€‘•áÑ•É¹…°€ôm½É‘•É•‘uì4(€€€€€€€€€€€€€€€A½İ•ÉM¡•±±AÉ½™¥±•Ì€ô  ‘ÕÍ…”¹AÉ½™¥±•MÑ…Ñ•Ì¤4(€€€€€€€€€€€€€€€ÕÍ…”€ôm½É‘•É•‘uì4(€€€€€€€€€€€€€€€€€€€5…¹…•€ô€‘¥¹ÍÑ…±±•‘	åA…­…”4(€€€€€€€€€€€€€€€€€€€%¹ÍÑ…±±•‘	åA…­…”€ô€‘¥¹ÍÑ…±±•‘	åA…­…”4(€€€€€€€€€€€€€€€€€€€]…Í%¹ÍÑ…±±•‘	•™½É”€ôm‰½½±t‘½É¥¥¹…°¹%¹ÍÑ…±±•4(€€€€€€€€€€€€€€€€€€€AÉ•Ù¥½ÕÍY•ÉÍ¥½¸€ômÍÑÉ¥¹t‘½É¥¥¹…°¹Y•ÉÍ¥½¸4(€€€€€€€€€€€€€€€€€€€ÕÉÉ•¹ÑY•ÉÍ¥½¸€ômÍÑÉ¥¹t‘ÕÍ…”¹A…­…•™Ñ•È¹Y•ÉÍ¥½¸4(€€€€€€€€€€€€€€€€€€€A…­…•%¹ÍÑ…±±•‘9½Ü€ôm‰½½±t‘ÕÍ…”¹A…­…•%¹ÍÑ…±±•‘9½Ü4(€€€€€€€€€€€€€€€ô4(€€€€€€€€€€€€€€€A½¹åÑ…¥°€ôm½É‘•É•‘uì5…¹…•€ôm‰½½±t‘Á½¹åÑ…¥°¹5…¹…•ì5…É­•ÑÁ±…”€ô€‘ÍÉ¥ÁĞéA½¹åÑ…¥±5…É­•ÑÁ±…•M½ÕÉ”ìA±Õ¥¸€ô€‘ÍÉ¥ÁĞéA½¹åÑ…¥±A±Õ¥¹%ì]…Í%¹ÍÑ…±±•‘	•™½É”€ôm‰½½±t‘Á½¹åÑ…¥°¹]…Í%¹ÍÑ…±±•‘	•™½É”ì%¹ÍÑ…±±•‘9½Ü€ôm‰½½±t‘Á½¹åÑ…¥°¹%¹ÍÑ…±±•‘9½ÜìUÁ‘…Ñ•‘9½Ü€ôm‰½½±t‘Á½¹åÑ…¥°¹UÁ‘…Ñ•‘9½Üì!½½­½Õ¹Ğ€ôm¥¹Ñt‘Á½¹åÑ…¥°¹!½½­½Õ¹ĞìQÉÕÍÑ•‘!½½­½Õ¹Ğ€ôm¥¹Ñt‘Á½¹åÑ…¥°¹QÉÕÍÑ•‘!½½­½Õ¹Ğì!½½­%‘•¹Ñ¥Ñ¥•Ì€ô  ‘Á½¹åÑ…¥°¹!½½­%‘•¹Ñ¥Ñ¥•Ì¤ìY…±¥‘…Ñ¥½¹MÑ…ÑÕÌ€ômÍÑÉ¥¹t‘Á½¹åÑ…¥°¹Y…±¥‘…Ñ¥½¹MÑ…ÑÕÌìQÉÕÍÑMÑ…ÑÕÌ€ômÍÑÉ¥¹t‘Á½¹åÑ…¥°¹QÉÕÍÑMÑ…ÑÕÌô4(€€€€€€€€€€€€€€€½‘•á=É¡•ÍÑÉ…Ñ¥½¸€ôm½É‘•É•‘uìÁ±Õ¥¹5…¹…•€ôm‰½½±t‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹5…¹…•ìÁ±Õ¥¹AÉ•Í•¹Ğ€ô€‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹A±Õ¥¹AÉ•Í•¹ĞìÁ±Õ¥¹UÁ‘…Ñ•‘Q¡¥ÍIÕ¸€ôm‰½½±t‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹UÁ‘…Ñ•‘9½Üìµ…É­•ÑÁ±…”€ô€‘ÍÉ¥ÁĞé½‘•á=É¡•ÍÑÉ…Ñ¥½¹5…É­•ÑÁ±…•M½ÕÉ”ìÁ±Õ¥¸€ô€‘ÍÉ¥ÁĞé½‘•á=É¡•ÍÑÉ…Ñ¥½¹A±Õ¥¹%ìİ½É­™±½İ5…¹…•€ôm‰½½±t‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹]½É­™±½İ5…¹…•ìİ½É­™±½İ½¹™¥ÕÉ•€ôm‰½½±t‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹]½É­™±½İ½¹™¥ÕÉ•ìİ½É­™±½İ™™•Ñ¥Ù”€ôm‰½½±t‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹]½É­™±½İ™™•Ñ¥Ù”ìİ½É­™±½İMÑ…ÑÕÌ€ômÍÑÉ¥¹t‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹]½É­™±½İMÑ…ÑÕÌìİ½É­™±½İ½¹™¥ÕÉ…Ñ¥½¹MÕµµ…Éä€ômÍÑÉ¥¹t‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹]½É­™±½İ½¹™¥ÕÉ…Ñ¥½¹MÕµµ…ÉäìÍ•ÑÕÁAÉ½µÁĞ€ômÍÑÉ¥¹t‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸¹M•ÑÕÁAÉ½µÁĞô4(€€€€€€€€€€€€€€€M•É•¹„€ôm½É‘•É•‘uì5…¹…•€ôm‰½½±t‘Í•É•¹„¹5…¹…•ìM•±•Ñ•‘	åUÍ•È€ôm‰½½±t‘Í•É•¹„¹M•±•Ñ•‘	åUÍ•ÈìUÙÙ…¥±…‰±”€ôm‰½½±t‘Í•É•¹„¹UÙÙ…¥±…‰±”ìUÙY•ÉÍ¥½¸€ômÍÑÉ¥¹t‘Í•É•¹„¹UÙY•ÉÍ¥½¸ìY•ÉÍ¥½¹	•™½É”€ômÍÑÉ¥¹t‘Í•É•¹„¹Y•ÉÍ¥½¹	•™½É”ìY•ÉÍ¥½¹™Ñ•È€ômÍÑÉ¥¹t‘Í•É•¹„¹Y•ÉÍ¥½¹™Ñ•Èì%¹ÍÑ…±±•‘9½Ü€ôm‰½½±t‘Í•É•¹„¹%¹ÍÑ…±±•‘9½ÜìUÁ‘…Ñ•‘9½Ü€ôm‰½½±t‘Í•É•¹„¹UÁ‘…Ñ•‘9½Üì%¹¥Ñ¥…±¥é…Ñ¥½¹MÑ…ÑÕÌ€ômÍÑÉ¥¹t‘Í•É•¹„¹%¹¥Ñ¥…±¥é…Ñ¥½¹MÑ…ÑÕÌì½‘•á5Á½¹™¥ÕÉ•€ô€¡mÍÑÉ¥¹t‘Í•É•¹„¹½‘•á5ÁMÑ…ÑÕÌ€µ•Ä€½¹™¥ÕÉ•œ¤ìIÕ¹Ñ¥µ•Y•É¥™¥•€ô€‘™…±Í”ô4(€€€€€€€€€€€€€€€½¹Ñ•áĞÜ€ôm½É‘•É•‘uì4(€€€€€€€€€€€€€€€€€€€¹Ù¥É½¹µ•¹ÑY…É¥…‰±”€ô€=9QaPİ}A%}-dœ4(€€€€€€€€€€€€€€€€€€€É•…Ñ•‘	å%¹ÍÑ…±±•È€ôm‰½½±t‘½¹Ñ•áÑMÑ…Ñ”¹É•…Ñ•‘	å%¹ÍÑ…±±•È4(€€€€€€€€€€€€€€€€€€€M•É•ÑMÑ½É•‘%¹I•Á½Í¥Ñ½Éä€ô€‘™…±Í”4(€€€€€€€€€€€€€€€ô4(€€€€€€€€€€€ô4(4(€€€€€€€€€€€½µÁ±•Ñ”µ%¹ÍÑ…±±…Ñ¥½¸€µI•ÍÕ±ÑÌ€‘É•ÍÕ±ÑÉÉ…ä€µQÉ…¹Í…Ñ¥½¸€‘ÑÉ…¹Í…Ñ¥½¸€µáÑ•É¹…°€‘•áÑ•É¹…°ğ=ÕĞµ9Õ±°4(4(€€€€€€€€€€€¥˜€ ‘½¹Ñ•áĞ¹%¹ÍÑ…±±]¥¹‘½İÍ9½Ñ¥™¥…Ñ¥½¹Ì¤ì4(€€€€€€€€€€€€€€€M•Ğµ%¹ÍÑ…±±AÉ½É•ÍÌ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µMÑ•Á%€9½Ñ¥™¥…Ñ¥½¹Ìœ€µ•Ñ…¥°€Ÿ¦¦_¢¶'¦Z/fó.š/¢"Q½­•¸€¼½ÍĞƒ’öÿR£¦?¦k~”œ4(€€€€€€€€€€€€€€€¥˜€¡Q•ÍĞµ½‘•á]½É­™±½İ•¥Í¥½¸€µA±…¸€‘¡…¹•A±…¸€µ=Á•É…Ñ¥½¸9½Ñ¥™¥…Ñ¥½¹Q•ÍĞ¤ì4(€€€€€€€€€€€€€€€€€€€€‘¹½Ñ¥™¥…Ñ¥½¹MÉ¥ÁĞ€ô)½¥¸µA…Ñ €‘½¹Ñ•áĞ¹±½‰…±I½½Ğ€¡½½­ÍqÍ¡½Üµ½‘•àµ¹½Ñ¥™¥…Ñ¥½¸¹ÁÌÄœ4(€€€€€€€€€€€€€€€€€€€€‘¹½Ñ¥™¥…Ñ¥½¹=ÕÑÁÕĞ€ô€˜ÁİÍ €µ9½1½¼€µ9½AÉ½™¥±”€µ9½¹%¹Ñ•É…Ñ¥Ù”€µ¥±”€‘¹½Ñ¥™¥…Ñ¥½¹MÉ¥ÁĞ€µQåÁ”½µÁ±•Ñ•€µQ•ÍĞ€Èø˜Ä4(€€€€€€€€€€€€€€€€€€€¥˜€ ‘1MQa%Q=€µ¹”€À¤ìÑ¡É½Ü€‰]¥¹‘½İÌƒ¦k~—šâ³¢¦›–’ÇšV_¾ò3ÖCšvŠó¾òh‘1MQa%Q=ˆô4(€€€€€€€€€€€€€€€€€€€€‘¹½Ñ¥™¥…Ñ¥½¹MÑ…ÑÕÌ€ô€Ÿ–ŞË¦–ëšâ³¢¦›¦k~”œ4(€€€€€€€€€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±1½œ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µ5•ÍÍ…”€=559¹½Ñ¥™¥…Ñ¥½¸Ñ•ÍĞ½µÁ±•Ñ•œ4(€€€€€€€€€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±1½œ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µ5•ÍÍ…”€ ‰=559=UQAUP¹½Ñ¥™¥…Ñ¥½¸Ñ•ÍĞèìÁôˆ€µ˜€¡AÉ½Ñ•Ğµ%¹ÍÑ…±±1½Q•áĞ€ ‘¹½Ñ¥™¥…Ñ¥½¹=ÕÑÁÕĞ€µ©½¥¸m¹Ù¥É½¹µ•¹Ñtèé9•İ1¥¹”¤¤¤4(€€€€€€€€€€€€€€€€€€€½µÁ±•Ñ”µ%¹ÍÑ…±±MÑ•À€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µI•ÍÕ±Ğ€‘¹½Ñ¥™¥…Ñ¥½¹MÑ…ÑÕÌ4(€€€€€€€€€€€€€€€ô•±Í”ì4(€€€€€€€€€€€€€€€€€€€€‘¹½Ñ¥™¥…Ñ¥½¹MÑ…ÑÕÌ€ô€Ÿ¢Ïšr³¢"!½½¬ƒšr«¢º+šnÓ¾ò3V—¦;šâ³¢¦˜œ4(€€€€€€€€€€€€€€€€€€€€‘Í­¥ÁÁ•‘½Õ¹Ğ¬¬4(€€€€€€€€€€€€€€€€€€€½µÁ±•Ñ”µ%¹ÍÑ…±±MÑ•À€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µI•ÍÕ±Ğ€‘¹½Ñ¥™¥…Ñ¥½¹MÑ…ÑÕÌ4(€€€€€€€€€€€€€€€ô4(€€€€€€€€€€€ô4(4(€€€€€€€€€€€M•Ğµ%¹ÍÑ…±±AÉ½É•ÍÌ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µMÑ•Á%€¥¹…°œ€µ•Ñ…¥°€Ÿ–¾¯–”5…¹¥™•ÍĞƒ’â›–º3š"C’ê“šbO¦¦_¢¶$œ4(€€€€€€€€€€€½µÁ±•Ñ”µ%¹ÍÑ…±±…Ñ¥½¸€µI•ÍÕ±ÑÌ€‘É•ÍÕ±ÑÉÉ…ä€µQÉ…¹Í…Ñ¥½¸€‘ÑÉ…¹Í…Ñ¥½¸€µáÑ•É¹…°€‘•áÑ•É¹…°€µ¥¹…±¥é•QÉ…¹Í…Ñ¥½¸ğ=ÕĞµ9Õ±°4(€€€€€€€€€€€½µÁ±•Ñ”µ%¹ÍÑ…±±MÑ•À€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µI•ÍÕ±Ğ€5…¹¥™•ÍĞƒ¢"’ê“šbO¦¦_¢¶'¦k¦8œ4(€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±…Ñ¥½¹MÕµµ…Éä€µ%¹ÍÑ…±±MÑå±”€‘½¹Ñ•áĞ¹%¹ÍÑ…±±MÑå±”€µ•Ù•±½Áµ•¹Ñ¹Ù¥É½¹µ•¹Ğ€‘½¹Ñ•áĞ¹•Ù•±½Áµ•¹Ñ¹Ù¥É½¹µ•¹Ğ€µI•ÍÕ±ÑÌ€‘É•ÍÕ±ÑÉÉ…ä€µÕÍ…”€‘ÕÍ…”€µÕÍ…•	•™½É”€‘ÕÍ…•	•™½É”€µ!½½­QÉÕÍĞ€‘¡½½­QÉÕÍĞ€µQÉ…¹Í…Ñ¥½¹I½½Ğ€‘ÑÉ…¹Í…Ñ¥½¹I½½Ğ€µ%¹ÍÑ…±±]¥¹‘½İÍ9½Ñ¥™¥…Ñ¥½¹Ì€‘½¹Ñ•áĞ¹%¹ÍÑ…±±]¥¹‘½İÍ9½Ñ¥™¥…Ñ¥½¹Ì€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µ9½Ñ¥™¥…Ñ¥½¹MÑ…ÑÕÌ€‘¹½Ñ¥™¥…Ñ¥½¹MÑ…ÑÕÌ€µM­¥ÁÁ•‘½Õ¹Ğ€‘Í­¥ÁÁ•‘½Õ¹Ğ€µM­¥Á½¹Ñ•áĞİ-•äè‘M­¥Á½¹Ñ•áĞİ-•ä€µ%¹ÍÑ…±±5…ÑÑA½½­M­¥±±Ìè‘%¹ÍÑ…±±5…ÑÑA½½­M­¥±±Ì€µ%¹ÍÑ…±±I•ÅÕ•ÍÑá•ÕÑ¥½¹=ÁÑ¥µ¥é•Èè‘%¹ÍÑ…±±I•ÅÕ•ÍÑá•ÕÑ¥½¹=ÁÑ¥µ¥é•È€µ¹…‰±••™…Õ±Ñ5½‘•I•ÅÕ•ÍÑUÍ•É%¹ÁÕĞè‘¹…‰±••™…Õ±Ñ5½‘•I•ÅÕ•ÍÑUÍ•É%¹ÁÕĞ€µ½¹Ñ•áÑMÑ…Ñ”€‘½¹Ñ•áÑMÑ…Ñ”€µM­¥±±Í½Õ¹Ğ€‘µ…ÑÑA½½­M­¥±±9…µ•Ì¹½Õ¹Ğ€µA½¹åÑ…¥°€‘Á½¹åÑ…¥°€µ½‘•á=É¡•ÍÑÉ…Ñ¥½¸€‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸€µM•É•¹„€‘Í•É•¹„4(€€€€€€€ô…Ñ ì4(€€€€€€€€€€€€‘É•…Í½¸€ô€‘|¹á•ÁÑ¥½¸¹5•ÍÍ…”4(€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±ÉÉ½ÉI•½É€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µÉÉ½ÉI•½É€‘|€µÕÉÉ•¹ÑMÕ‰=Á•É…Ñ¥½¸€‘ÕÉÉ•¹ÑMÕ‰=Á•É…Ñ¥½¸4(€€€€€€€€€€€…¥°µ%¹ÍÑ…±±MÑ•À€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µI•…Í½¸€‘É•…Í½¸4(€€€€€€€€€€€€‘É½±±‰…­ÉÉ½ÉÌ€ô ¡%¹Ù½­”µ%¹ÍÑ…±±…Ñ¥½¹I½±±‰…¬€µQÉ…¹Í…Ñ¥½¸€‘ÑÉ…¹Í…Ñ¥½¸€µÕÍ…•	•™½É”€‘ÕÍ…•	•™½É”€µ½¹Ñ•áÑMÑ…Ñ”€‘½¹Ñ•áÑMÑ…Ñ”€µ½‘•á=É¡•ÍÑÉ…Ñ¥½¸€‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸€µI•…Í½¸€‘É•…Í½¸¤4(€€€€€€€€€€€€‘µ•ÍÍ…”€ô€‰%¹ÍÑ…±±…Ñ¥½¸™…¥±•…¹É½±±‰…¬İ…Ì…ÑÑ•µÁÑ•¹¹I•…Í½¸è€‘É•…Í½¸ˆ4(€€€€€€€€€€€¥˜€ ‘É½±±‰…­ÉÉ½ÉÌ¹½Õ¹Ğ€µĞ€À¤ì€‘µ•ÍÍ…”€¬ô€‰¹I½±±‰…¬•ÉÉ½ÉÌé¸´€ˆ€¬€ ‘É½±±‰…­ÉÉ½ÉÌ€µ©½¥¸€‰¸´€ˆ¤ô4(€€€€€€€€€€€€‘É½±±‰…­MÑ…ÑÕÌ€ô¥˜€ ‘É½±±‰…­ÉÉ½ÉÌ¹½Õ¹Ğ€µ•Ä€À¤ì€MUMLœô•±Í”ì€%1œô4(€€€€€€€€€€€€‘™…¥±ÕÉ•MÕµµ…Éä€ô•Ğµ%¹ÍÑ…±±I•ÍÕ±ÑMÕµµ…Éä€µI•ÍÕ±ÑÌ€‘É•ÍÕ±ÑÌ¹Q½ÉÉ…ä ¤4(€€€€€€€€€€€€‘™…¥±ÕÉ•MÕµµ…Éä¹I½±±‰…¬€ô€‘É½±±‰…­MÑ…ÑÕÌ4(€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±I•ÍÕ±Ğ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µMÑ…ÑÕÌ%1€µMÕµµ…Éä€‘™…¥±ÕÉ•MÕµµ…Éä€µI•ÍÕ±ÑÌ€‘É•ÍÕ±ÑÌ¹Q½ÉÉ…ä ¤4(€€€€€€€€€€€Ñ¡É½Ü€‘µ•ÍÍ…”4(€€€€€€€ô4(€€€ô…Ñ ì4(€€€€€€€¥˜€ ‘ÁÉ½É•ÍÌ¹MÑ…ÑÕÌ€µ¹”€…¥±•œ¤ì4(€€€€€€€€€€€€‘É•…Í½¸€ô€‘|¹á•ÁÑ¥½¸¹5•ÍÍ…”4(€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±ÉÉ½ÉI•½É€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µÉÉ½ÉI•½É€‘|€µÕÉÉ•¹ÑMÕ‰=Á•É…Ñ¥½¸€‘ÕÉÉ•¹ÑMÕ‰=Á•É…Ñ¥½¸4(€€€€€€€€€€€…¥°µ%¹ÍÑ…±±MÑ•À€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µI•…Í½¸€‘É•…Í½¸4(€€€€€€€€€€€€‘É½±±‰…­ÉÉ½ÉÌ€ô ¡%¹Ù½­”µ%¹ÍÑ…±±…Ñ¥½¹I½±±‰…¬€µQÉ…¹Í…Ñ¥½¸€‘ÑÉ…¹Í…Ñ¥½¸€µÕÍ…•	•™½É”€‘ÕÍ…•	•™½É”€µ½¹Ñ•áÑMÑ…Ñ”€‘½¹Ñ•áÑMÑ…Ñ”€µ½‘•á=É¡•ÍÑÉ…Ñ¥½¸€‘½‘•á=É¡•ÍÑÉ…Ñ¥½¸€µI•…Í½¸€‘É•…Í½¸¤4(€€€€€€€€€€€€‘™…¥±ÕÉ•MÕµµ…Éä€ô•Ğµ%¹ÍÑ…±±I•ÍÕ±ÑMÕµµ…Éä€µI•ÍÕ±ÑÌ€‘É•ÍÕ±ÑÌ¹Q½ÉÉ…ä ¤4(€€€€€€€€€€€€‘™…¥±ÕÉ•MÕµµ…Éä¹I½±±‰…¬€ô¥˜€ ‘É½±±‰…­ÉÉ½ÉÌ¹½Õ¹Ğ€µ•Ä€À¤ì€MUMLœô•±Í”ì€%1œô4(€€€€€€€€€€€]É¥Ñ”µ%¹ÍÑ…±±I•ÍÕ±Ğ€µAÉ½É•ÍÌ€‘ÁÉ½É•ÍÌ€µMÑ…ÑÕÌ%1€µMÕµµ…Éä€‘™…¥±ÕÉ•MÕµµ…Éä€µI•ÍÕ±ÑÌ€‘É•ÍÕ±ÑÌ¹Q½ÉÉ…ä ¤4(€€€€€€€€€€€Ñ¡É½Ü4(€€€€€€€ô4(€€€€€€€Ñ¡É½Ü4(€€€ô™¥¹…±±äì4(€€€€€€€á¥Ğµ½‘•áM•ÑÑ¥¹Í1½¬€µ1½¬€‘½Á•É…Ñ¥½¹1½¬4(€€€ô4)ô4(4)™Õ¹Ñ¥½¸%¹Ù½­”µ%¹ÍÑ…±±•Èì4(€€€mµ‘±•Ñ	¥¹‘¥¹œ ¥t4(€€€Á…É…´ 4(€€€€€€€mY…±¥‘…Ñ•M•Ğ %¹Ñ•É…Ñ¥Ù”œ°€±½‰…°œ°€	…­ÕÀœ°€I•ÍÑ½É”œ°€U¹¥¹ÍÑ…±°œ¥t4(€€€€€€€mÍÑÉ¥¹t‘5½‘”€ô€%¹Ñ•É…Ñ¥Ù”œ°4(€€€€€€€mÍİ¥Ñ¡t‘M­¥Á½¹Ñ•áĞİ-•ä°4(€€€€€€€mÍİ¥Ñ¡t‘M­¥ÁÕÍ…•%¹ÍÑ…±°°4(€€€€€€€mÍİ¥Ñ¡t‘%¹ÍÑ…±±I•ÅÕ•ÍÑá•ÕÑ¥½¹=ÁÑ¥µ¥é•È°4(€€€€€€€mÍİ¥Ñ¡t‘%¹ÍÑ…±±5…ÑÑA½½­M­¥±±Ì°4(€€€€€€€mÍİ¥Ñ¡t‘%¹ÍÑ…±±A½¹åÑ…¥°°4(€€€€€€€mÍİ¥Ñ¡t‘M­¥ÁA½¹åÑ…¥°°4(€€€€€€€mÍİ¥Ñ¡t‘%¹ÍÑ…±±½‘•á=É¡•ÍÑÉ…Ñ¥½¸°4(€€€€€€€mÍİ¥Ñ¡t‘M­¥Á½‘•á=É¡•ÍÑÉ…Ñ¥½¸°4(€€€€€€€mÍİ¥Ñ¡t‘½¹™¥ÕÉ•½‘•á=É¡•ÍÑÉ…Ñ¥½¸°4(€€€€€€€mÍİ¥Ñ¡t‘%¹ÍÑ…±±M•É•¹„°4(€€€€€€€mÍİ¥Ñ¡t‘M­¥ÁM•É•¹„°4(€€€€€€€mÍİ¥Ñ¡t‘%¹ÍÑ…±±M•É•¹…UØ°4(€€€€€€€mÍİ¥Ñ¡t‘¹…‰±••™…Õ±Ñ5½‘•I•ÅÕ•ÍÑUÍ•É%¹ÁÕĞ°4(€€€€€€€mÍİ¥Ñ¡t‘½É•Y…±¥‘…Ñ¥½¸°4(€€€€€€€mÍİ¥Ñ¡t‘½É•9½Ñ¥™¥…Ñ¥½¹Q•ÍĞ°4(€€€€€€€mÍİ¥Ñ¡t‘9½A…ÕÍ”°4(€€€€€€€m9Õ±±…‰±•m‰½½±ut‘%¹ÍÑ…±±]¥¹‘½İÍ9½Ñ¥™¥…Ñ¥½¹Ì°4(€€€€€€€mY…±¥‘…Ñ•M•Ğ ¥Ğœ°€YLœ¥t4(€€€€€€€mÍÑÉ¥¹t‘•Ù•±½Áµ•¹Ñ¹Ù¥É½¹µ•¹Ğ°4(€€€€€€€mÍİ¥Ñ¡t‘½É”°4(€€€€€€€mY…±¥‘…Ñ•M•Ğ 5•É”œ°€I•Á±…”œ¥t4(€€€€€€€mÍÑÉ¥¹t‘%¹ÍÑ…±±MÑå±”€ô€5•É”œ°4(€€€€€€€mÍÑÉ¥¹t‘M½ÕÉ•I½½Ğ€ô€œœ4(€€€€¤4(4(€€€¥˜€ ‘%¹ÍÑ…±±A½¹åÑ…¥°€µ…¹€‘M­¥ÁA½¹åÑ…¥°¤ìÑ¡É½Ü€%¹ÍÑ…±±A½¹åÑ…¥°ƒ¢"M­¥ÁA½¹åÑ…¥°ƒ’â7–>¿–B3šfš2–ºkœô4(€€€¥˜€ ‘%¹ÍÑ…±±½‘•á=É¡•ÍÑÉ…Ñ¥½¸€µ…¹€‘M­¥Á½‘•á=É¡•ÍÑÉ…Ñ¥½¸¤ìÑ¡É½Ü€%¹ÍÑ…±±½‘•á=É¡•ÍÑÉ…Ñ¥½¸ƒ¢"M­¥Á½‘•á=É¡•ÍÑÉ…Ñ¥½¸ƒ’â7–>¿–B3šfš2–ºkœô4(€€€¥˜€ ‘½¹™¥ÕÉ•½‘•á=É¡•ÍÑÉ…Ñ¥½¸€µ…¹€µ¹½Ğ€‘%¹ÍÑ…±±½‘•á=É¡•ÍÑÉ…Ñ¥½¸¤ìÑ¡É½Ü€½¹™¥ÕÉ•½‘•á=É¡•ÍÑÉ…Ñ¥½¸ƒ–ş¦‚#šB·¦4%¹ÍÑ…±±½‘•á=É¡•ÍÑÉ…Ñ¥½»œô4(€€€¥˜€ ‘%¹ÍÑ…±±M•É•¹„€µ…¹€‘M­¥ÁM•É•¹„¤ìÑ¡É½Ü€%¹ÍÑ…±±M•É•¹„ƒ¢"M­¥ÁM•É•¹„ƒ’â7–>¿–B3šfš2–ºkœô4(€€€¥˜€¡mÍÑÉ¥¹tèé%Í9Õ±±=É]¡¥Ñ•MÁ…” ‘M½ÕÉ•I½½Ğ¤¤ì€‘M½ÕÉ•I½½Ğ€ômÍÑÉ¥¹t‘MÉ¥ÁÑI½½Ğô4(€€€¥˜€ ‘5½‘”€µ¥¸  	…­ÕÀœ°€I•ÍÑ½É”œ°€U¹¥¹ÍÑ…±°œ¤¤ì4(€€€€€€€%¹Ù½­”µ5…¹…•µ•¹Ñ5½‘”€µ5½‘”€‘5½‘”€µM½ÕÉ•I½½Ğ€‘M½ÕÉ•I½½Ğ4(€€€€€€€É•ÑÕÉ¸4(€€€ô4(4(€€€€‘½¹Ñ•áĞ€ô9•Üµ%¹ÍÑ…±±•É½¹Ñ•áĞ€µM½ÕÉ•I½½Ğ€‘M½ÕÉ•I½½Ğ€µ•Ù•±½Áµ•¹Ñ¹Ù¥É½¹µ•¹Ğ€‘•Ù•±½Áµ•¹Ñ¹Ù¥É½¹µ•¹Ğ€µ%¹ÍÑ…±±MÑå±”€‘%¹ÍÑ…±±MÑå±”€µ½É”è‘½É”€µ%¹ÍÑ…±±]¥¹‘½İÍ9½Ñ¥™¥…Ñ¥½¹Ì€‘%¹ÍÑ…±±]¥¹‘½İÍ9½Ñ¥™¥…Ñ¥½¹Ì4(€€€¥˜€ ‘5½‘”€µ•Ä€%¹Ñ•É…Ñ¥Ù”œ¤ì4(€€€€€€€%¹Ù½­”µ%¹Ñ•É…Ñ¥Ù•5½‘”€µ•Ù•±½Áµ•¹Ñ¹Ù¥É½¹µ•¹Ğ€‘½¹Ñ•áĞ¹•Ù•±½Áµ•¹Ñ¹Ù¥É½¹µ•¹Ğ€µ±½‰…±I½½Ğ€‘½¹Ñ•áĞ¹±½‰…±I½½Ğ€µM½ÕÉ•I½½Ğ€‘½¹Ñ•áĞ¹MÉ¥ÁÑI½½Ğ4(€€€€€€€É•ÑÕÉ¸4(€€€ô4(4(€€€%¹Ù½­”µ±½‰…±%¹ÍÑ…±±…Ñ¥½¸€µ½¹Ñ•áĞ€‘½¹Ñ•áĞ€µM­¥Á½¹Ñ•áĞİ-•äè‘M­¥Á½¹Ñ•áĞİ-•ä€µM­¥ÁÕÍ…•%¹ÍÑ…±°è‘M­¥ÁÕÍ…•%¹ÍÑ…±°€µ%¹ÍÑ…±±I•ÅÕ•ÍÑá•ÕÑ¥½¹=ÁÑ¥µ¥é•Èè‘%¹ÍÑ…±±I•ÅÕ•ÍÑá•ÕÑ¥½¹=ÁÑ¥µ¥é•È€µ%¹ÍÑ…±±5…ÑÑA½½­M­¥±±Ìè‘%¹ÍÑ…±±5…ÑÑA½½­M­¥±±Ì€µ%¹ÍÑ…±±A½¹åÑ…¥°è‘%¹ÍÑ…±±A½¹åÑ…¥°€µM­¥ÁA½¹åÑ…¥°è‘M­¥ÁA½¹åÑ…¥°€µ%¹ÍÑ…±±½‘•á=É¡•ÍÑÉ…Ñ¥½¸è‘%¹ÍÑ…±±½‘•á=É¡•ÍÑÉ…Ñ¥½¸€µM­¥Á½‘•á=É¡•ÍÑÉ…Ñ¥½¸è‘M­¥Á½‘•á=É¡•ÍÑÉ…Ñ¥½¸€µ½¹™¥ÕÉ•½‘•á=É¡•ÍÑÉ…Ñ¥½¸è‘½¹™¥ÕÉ•½‘•á=É¡•ÍÑÉ…Ñ¥½¸€µ%¹ÍÑ…±±M•É•¹„è‘%¹ÍÑ…±±M•É•¹„€µM­¥ÁM•É•¹„è‘M­¥ÁM•É•¹„€µ%¹ÍÑ…±±M•É•¹…UØè‘%¹ÍÑ…±±M•É•¹…UØ€µ¹…‰±••™…Õ±Ñ5½‘•I•ÅÕ•ÍÑUÍ•É%¹ÁÕĞè‘¹…‰±••™…Õ±Ñ5½‘•I•ÅÕ•ÍÑUÍ•É%¹ÁÕĞ€µ½É•Y…±¥‘…Ñ¥½¸è‘½É•Y…±¥‘…Ñ¥½¸€µ½É•9½Ñ¥™¥…Ñ¥½¹Q•ÍĞè‘½É•9½Ñ¥™¥…Ñ¥½¹Q•ÍĞ€µI•¹‘•É•É5½‘”€¡¥˜€ ‘9½A…ÕÍ”¤ì€1¥¹”œô•±Í”ì€ÕÑ¼œô¤4)ô4