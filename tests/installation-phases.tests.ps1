$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$steps = @(New-InstallationProgressSteps -IncludeSkills -IncludePonytail -IncludeCodexOrchestration -IncludeSerena -IncludeNotifications -IncludeUsageTools)
if (@($steps | Where-Object Id -eq 'Ccusage').Count -ne 0) { throw 'ccusage / ccsessions / cdaily 不得再是頂層 progress component。' }
if (@($steps | Where-Object Component -eq 'WindowsUsageNotifications').Count -ne 1 -or @($steps | Where-Object Component -eq 'UsageTools').Count -ne 1) { throw 'Windows notification 與 usage tools 必須是獨立 Community components。' }
if (@($steps | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Category) -or [string]::IsNullOrWhiteSpace([string]$_.Component) }).Count -ne 0) {
    throw '每個 progress step 都必須宣告 Category 與 Component ownership。'
}
$personalLast = @($steps | Where-Object Category -eq 'Personal' | Measure-Object Index -Maximum)[0].Maximum
$communityFirst = @($steps | Where-Object Category -eq 'Community' | Measure-Object Index -Minimum)[0].Minimum
if ($personalLast -ge $communityFirst) { throw '所有 Personal steps 必須在 Community components 之前完成。' }

$communitySteps = @($steps | Where-Object Category -eq 'Community')
$status = Format-InstallProgressStatus -Profile (New-InstallRendererProfile -RendererMode Interactive -OutputEncoding ([Text.UTF8Encoding]::new($false)) -WindowWidth 120) -Step $communitySteps[0] -Total $steps.Count -Percent 50 -Detail '驗證 component ownership' -Elapsed '00:00:02'
if ($status -notmatch '^Community 1/6') { throw "progress 未顯示 Community component index：$status" }

$installerContextImplementation = (Get-Command New-InstallerContext -CommandType Function).ScriptBlock
$globalInstallationImplementation = (Get-Command Invoke-GlobalInstallation -CommandType Function).ScriptBlock
$targetUserProfile = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-user-' + [guid]::NewGuid().ToString('N'))
$expectedCodexHome = Join-Path $targetUserProfile '.codex'
$environmentNames = @('CODEX_HOME', 'HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA')
$previousEnvironment = @{}
foreach ($name in $environmentNames) { $previousEnvironment[$name] = [pscustomobject]@{ Present = Test-Path -LiteralPath "Env:\$name"; Value = [Environment]::GetEnvironmentVariable($name, 'Process') } }
try {
    function New-InstallerContext { [pscustomobject]@{ GlobalRoot = $expectedCodexHome; UserProfile = $targetUserProfile; AppData = (Join-Path $targetUserProfile 'AppData\Roaming'); LocalAppData = (Join-Path $targetUserProfile 'AppData\Local'); DevelopmentEnvironment = 'Git'; ScriptRoot = $script:ScriptRoot } }
    function Invoke-GlobalInstallation { [pscustomobject]@{ CodexHome = $env:CODEX_HOME; Home = $env:HOME; UserProfile = $env:USERPROFILE; AppData = $env:APPDATA; LocalAppData = $env:LOCALAPPDATA } }
    $env:CODEX_HOME = 'C:\Users\CodexSandboxOffline\.codex'
    $observedEnvironment = Invoke-Installer -Mode Global -SourceRoot $script:ScriptRoot -TargetUserProfile $targetUserProfile -NoPause
    $expectedEnvironment = @{ CodexHome = $expectedCodexHome; Home = $targetUserProfile; UserProfile = $targetUserProfile; AppData = (Join-Path $targetUserProfile 'AppData\Roaming'); LocalAppData = (Join-Path $targetUserProfile 'AppData\Local') }
    foreach ($name in $expectedEnvironment.Keys) {
        if ([IO.Path]::GetFullPath($observedEnvironment.$name) -ne [IO.Path]::GetFullPath($expectedEnvironment[$name])) { throw "Global 安裝子程序使用了錯誤的 $name：$($observedEnvironment.$name)" }
    }
    if ($env:CODEX_HOME -ne 'C:\Users\CodexSandboxOffline\.codex') { throw 'Global 安裝結束後未還原呼叫端的 CODEX_HOME。' }
} finally {
    Set-Item -Path Function:New-InstallerContext -Value $installerContextImplementation
    Set-Item -Path Function:Invoke-GlobalInstallation -Value $globalInstallationImplementation
    foreach ($name in $environmentNames) {
        if ($previousEnvironment[$name].Present) { [Environment]::SetEnvironmentVariable($name, [string]$previousEnvironment[$name].Value, 'Process') }
        else { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
    }
}
foreach ($name in $environmentNames) {
    if ((Test-Path -LiteralPath "Env:\$name") -ne $previousEnvironment[$name].Present -or [Environment]::GetEnvironmentVariable($name, 'Process') -ne $previousEnvironment[$name].Value) { throw "測試未還原原本的 $name。" }
}

$sandboxRejected = $false
try { [void](New-InstallerContext -SourceRoot $script:ScriptRoot -TargetUserProfile 'C:\Users\CodexSandboxOffline') } catch { $sandboxRejected = $_.Exception.Message -match 'CodexSandboxOffline' -and $_.Exception.Message -match 'TargetUserProfile' }
if (-not $sandboxRejected) { throw '安裝器未拒絕將使用者設定與套件安裝到 CodexSandboxOffline。' }
$explicitContext = New-InstallerContext -SourceRoot $script:ScriptRoot -TargetUserProfile $targetUserProfile
if ([IO.Path]::GetFullPath($explicitContext.GlobalRoot) -ne [IO.Path]::GetFullPath($expectedCodexHome)) { throw '明確的 TargetUserProfile 未成為 GlobalRoot。' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-ownership-' + [guid]::NewGuid().ToString('N'))
try {
    $result = New-InstallationResult -Mode Global -Root $testRoot -DevelopmentEnvironment Git
    $transaction = New-FileTransaction -Root (Join-Path $testRoot 'transaction') -Mode TestOwnership
    $ownership = New-InstallationOwnershipManifest -EnableDefaultModeRequestUserInput -InstallWindowsNotifications -InstallUsageTools -InstallMattPocockSkills -InstallPonytail -InstallCodexOrchestration -InstallSerena
    Save-InstallationManifest -Result $result -Transaction $transaction -External ([ordered]@{}) -Ownership $ownership
    $manifest = Get-Content -LiteralPath (Join-Path $testRoot '.codex-settings-manifest.json') -Raw | ConvertFrom-Json
    foreach ($path in @('codexSettings', 'requestUserInput')) {
        if ($manifest.personal.PSObject.Properties.Name -notcontains $path) { throw "manifest 缺少 Personal ownership：$path" }
    }
    foreach ($path in @('windowsUsageNotifications', 'usageTools', 'mattpocockSkills', 'ponytail', 'codexOrchestration', 'serena')) {
        if ($manifest.community.PSObject.Properties.Name -notcontains $path) { throw "manifest 缺少 Community ownership：$path" }
    }
    if ($manifest.otherSettings.longRunningAsyncWait.Category -ne 'Other Settings' -or @($manifest.otherSettings.longRunningAsyncWait.ManagedPaths) -notcontains 'AGENTS.md') { throw 'manifest 缺少獨立的 async-wait Other Settings ownership。' }
    if ($manifest.community.usageTools.Owner -ne 'UsageTools' -or @($manifest.community.usageTools.ManagedExternalState) -notcontains 'ccusage' -or @($manifest.community.windowsUsageNotifications.ManagedExternalState).Count -ne 0) {
        throw 'usage tools 與 Windows notification ownership 未分離。'
    }
    if ($manifest.community.windowsUsageNotifications.Owner -ne 'WindowsUsageNotifications' -or @($manifest.community.windowsUsageNotifications.ManagedHooks).Count -ne 3) {
        throw 'WindowsUsageNotifications ownership 未涵蓋單一 bundle 的三類 lifecycle hooks。'
    }
    foreach ($field in @('pluginStatus', 'workflowRequested', 'workflowStatus', 'setupPrompt', 'actionRequired', 'lastVerified')) {
        if ($manifest.community.codexOrchestration.PSObject.Properties.Name -notcontains $field) { throw "Codex-Orchestration ownership 缺少狀態欄位：$field" }
    }
    foreach ($field in @('ManagedPaths', 'ManagedExternalState', 'RollbackScope', 'scriptPresent', 'hookConfigured', 'hookTrusted', 'hookEffective', 'directToastShown', 'lastInvocation', 'lastResult')) {
        if ($manifest.community.windowsUsageNotifications.PSObject.Properties.Name -notcontains $field) { throw "WindowsUsageNotifications ownership 缺少 $field。" }
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$isolationRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-community-isolation-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $isolationRoot -Force | Out-Null
    $personalPath = Join-Path $isolationRoot 'personal.txt'
    [IO.File]::WriteAllText($personalPath, 'personal-checkpoint', [Text.UTF8Encoding]::new($false))
    $notificationPath = Join-Path $isolationRoot 'notification.txt'
    $skillsPath = Join-Path $isolationRoot 'skills.txt'
    $ponytailPath = Join-Path $isolationRoot 'ponytail.txt'
    $serenaPath = Join-Path $isolationRoot 'serena.txt'
    $backupRoot = Join-Path $isolationRoot 'transactions'

    $notification = Invoke-IsolatedCommunityComponent -Name WindowsUsageNotifications -BackupRoot $backupRoot -Operation {
        param($transaction)
        Save-TransactionFile -Transaction $transaction -Path $notificationPath
        [IO.File]::WriteAllText($notificationPath, 'notification', [Text.UTF8Encoding]::new($false))
        return 'configured'
    }
    $skills = Invoke-IsolatedCommunityComponent -Name MattPocockSkills -BackupRoot $backupRoot -Operation {
        param($transaction)
        Save-TransactionFile -Transaction $transaction -Path $skillsPath
        [IO.File]::WriteAllText($skillsPath, 'skills', [Text.UTF8Encoding]::new($false))
        return 'configured'
    }
    $ponytail = Invoke-IsolatedCommunityComponent -Name Ponytail -BackupRoot $backupRoot -Operation {
        param($transaction)
        Save-TransactionFile -Transaction $transaction -Path $ponytailPath
        [IO.File]::WriteAllText($ponytailPath, 'partial', [Text.UTF8Encoding]::new($false))
        throw 'marketplace conflict'
    }
    $serena = Invoke-IsolatedCommunityComponent -Name Serena -BackupRoot $backupRoot -Operation {
        param($transaction)
        Save-TransactionFile -Transaction $transaction -Path $serenaPath
        [IO.File]::WriteAllText($serenaPath, 'serena', [Text.UTF8Encoding]::new($false))
        return 'configured'
    }

    if ($notification.Status -ne 'SUCCESS' -or $skills.Status -ne 'SUCCESS' -or $ponytail.Status -ne 'FAILED' -or $serena.Status -ne 'SUCCESS') { throw 'Community component 狀態未隔離。' }
    if ((Get-Content -LiteralPath $personalPath -Raw) -ne 'personal-checkpoint' -or -not (Test-Path $notificationPath) -or -not (Test-Path $skillsPath) -or -not (Test-Path $serenaPath)) {
        throw 'Community failure 回滾了 Personal 或其他成功 component。'
    }
    if (Test-Path $ponytailPath) { throw '失敗的 Community component 未回滾自己的檔案。' }
    $serenaFailure = Invoke-IsolatedCommunityComponent -Name Serena -BackupRoot $backupRoot -Operation {
        param($transaction)
        Save-TransactionFile -Transaction $transaction -Path $serenaPath
        [IO.File]::WriteAllText($serenaPath, 'partial-serena', [Text.UTF8Encoding]::new($false))
        throw 'serena failure'
    }
    if ($serenaFailure.Status -ne 'FAILED' -or (Get-Content -LiteralPath $personalPath -Raw) -ne 'personal-checkpoint' -or (Get-Content -LiteralPath $serenaPath -Raw) -ne 'serena') {
        throw 'Serena failure 未限制在自己的 rollback scope。'
    }
} finally {
    Remove-Item -LiteralPath $isolationRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$notificationRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-notification-owner-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $notificationRoot -Force | Out-Null
    $hooksPath = Join-Path $notificationRoot 'hooks.json'
    $thirdPartyHook = '{"description":"third party","hooks":{"Stop":[{"hooks":[{"type":"command","command":"ponytail lifecycle"}]}]}}'
    [IO.File]::WriteAllText($hooksPath, $thirdPartyHook, [Text.UTF8Encoding]::new($false))
    foreach ($run in 1..2) {
        $transaction = New-FileTransaction -Root (Join-Path $notificationRoot "install-$run") -Mode WindowsUsageNotificationTransaction
        Invoke-WindowsUsageNotificationFiles -Root $notificationRoot -SourceRoot $script:ScriptRoot -Transaction $transaction | Out-Null
        Complete-FileTransaction $transaction
    }
    $hooks = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json
    if (@($hooks.hooks.Stop | Where-Object { (Get-HookEntryText $_) -match 'ponytail lifecycle' }).Count -ne 1) { throw 'WindowsUsageNotifications 修改了第三方 Hook。' }
    foreach ($event in @('PreToolUse', 'PermissionRequest')) {
        if (@($hooks.hooks.$event | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 1) { throw "notification bundle 未對 $event 保持唯一 Hook。" }
    }
    if (@($hooks.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 0 -or -not (Test-WindowsNotificationCommandConfig -Content (Get-Content -LiteralPath (Join-Path $notificationRoot 'config.toml') -Raw) -Root $notificationRoot)) { throw 'notification bundle 未使用唯一的原生完成通知。' }
    if (-not (Test-Path (Join-Path $notificationRoot 'hooks\show-codex-notification.ps1'))) { throw 'notification bundle 未安裝自己的腳本。' }
    $scriptHash = (Get-FileHash (Join-Path $notificationRoot 'hooks\show-codex-notification.ps1') -Algorithm SHA256).Hash
    $personalTarget = New-InstallTarget -Id personal -Mode Global -TemplateRoot (Join-Path $script:ScriptRoot 'templates\core') -EnvironmentTemplateRoot (Join-Path $script:ScriptRoot 'templates\environments\git') -DevelopmentEnvironment Git -Root $notificationRoot -Cwd $notificationRoot -InstallWindowsNotifications:$false -ManageWindowsNotifications:$false -SourceRoot $script:ScriptRoot
    $personalTransaction = New-FileTransaction -Root (Join-Path $notificationRoot 'personal') -Mode PersonalTransaction
    Invoke-TargetInstallation -Target $personalTarget -Transaction $personalTransaction | Out-Null
    $hooksAfterPersonal = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json
    if (@($hooksAfterPersonal.hooks.Stop | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 0 -or -not (Test-WindowsNotificationCommandConfig -Content (Get-Content -LiteralPath (Join-Path $notificationRoot 'config.toml') -Raw) -Root $notificationRoot) -or (Get-FileHash (Join-Path $notificationRoot 'hooks\show-codex-notification.ps1') -Algorithm SHA256).Hash -ne $scriptHash) {
        throw 'Personal phase 修改了 WindowsUsageNotifications 擁有的 Hook 或腳本。'
    }

    $removeTransaction = New-FileTransaction -Root (Join-Path $notificationRoot 'remove') -Mode WindowsUsageNotificationTransaction
    Invoke-WindowsUsageNotificationFiles -Root $notificationRoot -SourceRoot $script:ScriptRoot -Transaction $removeTransaction -Remove | Out-Null
    $hooksAfterRemove = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json
    if (@($hooksAfterRemove.hooks.Stop | Where-Object { (Get-HookEntryText $_) -match 'ponytail lifecycle' }).Count -ne 1 -or @($hooksAfterRemove.hooks.PSObject.Properties.Value | ForEach-Object { @($_) } | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -ne 0) {
        throw '移除 notification bundle 時修改了第三方 Hook 或保留受管理通知。'
    }
    if (Test-Path (Join-Path $notificationRoot 'hooks\show-codex-notification.ps1')) { throw '移除 notification bundle 後仍保留受管理腳本。' }
    if ((Test-Path (Join-Path $notificationRoot 'config.toml')) -and (Get-Content -LiteralPath (Join-Path $notificationRoot 'config.toml') -Raw) -match 'CODEX-SETTINGS:WINDOWS-NOTIFICATIONS:CONFIG') { throw '移除 notification bundle 後仍保留受管理 notify 設定。' }
} finally {
    Remove-Item -LiteralPath $notificationRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$uninstallSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'commands\uninstall-settings.ps1') -Raw
foreach ($fragment in @('Remove-ManagedLineEndingHooksJson', 'Remove-ManagedNotificationHooksJson', 'windowsUsageNotifications.ManagedPaths')) {
    if ($uninstallSource -notmatch [regex]::Escape($fragment)) { throw "uninstall 未依 component ownership 移除：$fragment" }
}

Write-Host 'Installation phase tests passed.'
