function Read-YesNoChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$Default
    )

    $selection = (Read-Host $Prompt).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($selection)) { return $Default }
    if ($selection -in @('y', 'yes')) { return $true }
    if ($selection -in @('n', 'no')) { return $false }
    throw '請輸入 Y 或 N。'
}

function Select-Mode {
    Write-Host ''
    Write-Host 'Codex Settings 一鍵安裝器'
    Write-Host '========================='
    Write-Host '[1] 全域安裝／更新：Codex、MCP、技能、ccusage 套件、ccsessions、cdaily'
    Write-Host ''
    Write-Host '備份與管理'
    Write-Host '[2] 備份目前設定'
    Write-Host '[3] 還原備份'
    Write-Host '[4] 移除受管理設定'
    Write-Host '[0] 結束'

    switch (Read-Host '請選擇 [1]') {
        '' { return 'Global' }
        '1' { return 'Global' }
        '2' { return 'Backup' }
        '3' { return 'Restore' }
        '4' { return 'Uninstall' }
        '0' { return 'Exit' }
        default { throw '選項無效。' }
    }
}

function Select-InstallStyle {
    Write-Host ''
    Write-Host '安裝方式'
    Write-Host '[1] 安全合併（預設、建議）：保留未受管理的既有內容'
    Write-Host '[2] 完整覆蓋：以範本取代目標檔案'

    switch (Read-Host '請選擇 [1]') {
        '' { return 'Merge' }
        '1' { return 'Merge' }
        '2' { return 'Replace' }
        default { throw '安裝方式無效。' }
    }
}

function Get-DefaultDevelopmentEnvironment([string]$Root) {
    $manifest = Get-Manifest -Root $Root
    $recorded = if ($null -ne $manifest) { [string]$manifest.DevelopmentEnvironment } else { '' }
    if ($recorded -in @('Git', 'CVS')) { return $recorded }
    return 'Git'
}

function Select-DevelopmentEnvironment([ValidateSet('Git', 'CVS')][string]$Default = 'Git') {
    Write-Host ''
    Write-Host '開發環境（設定會安裝到全域）'
    Write-Host $(if ($Default -eq 'Git') { '[1] Git（目前預設）' } else { '[1] Git' })
    Write-Host $(if ($Default -eq 'CVS') { '[2] CVS（目前預設）' } else { '[2] CVS' })

    $defaultOption = if ($Default -eq 'CVS') { '2' } else { '1' }
    switch (Read-Host "請選擇 [$defaultOption]") {
        '' { return $Default }
        '1' { return 'Git' }
        '2' { return 'CVS' }
        default { throw '開發環境選項無效。' }
    }
}

function Select-OptionalGlobalSkill {
    param([bool]$AlreadyInstalled = (Test-Path -LiteralPath (Join-Path $HOME '.codex\skills\request-execution-optimizer') -PathType Container))
    Write-Host ''
    Write-Host '選用全域技能：request-execution-optimizer'
    return Select-OptionalComponentAction -Name 'request-execution-optimizer' -State (Get-OptionalComponentState -Installed $AlreadyInstalled)
}

function Select-OptionalComponentAction([string]$Name, [string]$State) {
    if ($State -in @('TrueUnmanagedConflict', 'MalformedUserOwnedState', 'Conflict', 'Unknown')) { throw "$Name 的安裝狀態無法安全判定，請先排除衝突。" }
    if ($State -eq 'NotInstalled') {
        Write-Host "$Name 尚未安裝。"
        $selection = if (Read-YesNoChoice -Prompt '要安裝嗎？[Y/n]' -Default $true) { 'Yes' } else { 'No' }
    } else {
        Write-Host "$Name 已安裝。"
        Write-Host '選擇 No 會解除安裝此元件；只移除安裝器管理的內容。'
        $selection = if (Read-YesNoChoice -Prompt '要保留並檢查更新嗎？[Y/n]' -Default $true) { 'Yes' } else { 'No' }
    }
    return Resolve-OptionalComponentAction -State $State -Selection $selection
}

function Get-MattPocockSkillNames {
    return @(
        'setup-matt-pocock-skills',
        'grill-with-docs',
        'to-spec',
        'to-tickets',
        'implement',
        'tdd',
        'code-review',
        'diagnosing-bugs',
        'handoff',
        'wait-what'
    )
}

function Get-MattPocockSkillsArguments {
    $arguments = @('--yes', 'skills@latest', 'add', 'mattpocock/skills', '-g', '-a', 'codex', '-y')
    foreach ($name in Get-MattPocockSkillNames) { $arguments += @('--skill', $name) }
    return $arguments
}

function Test-MattPocockSkillsInstalled([string]$AgentsRoot = (Join-Path $HOME '.agents')) {
    $lockPath = Join-Path $AgentsRoot '.skill-lock.json'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { return $false }
    try { $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { return $false }
    if ($null -eq $lock.skills) { return $false }

    foreach ($entry in $lock.skills.PSObject.Properties) {
        if ([string]$entry.Value.source -eq 'mattpocock/skills') { return $true }
    }
    return $false
}

function Select-OptionalMattPocockSkills([bool]$AlreadyInstalled = (Test-MattPocockSkillsInstalled)) {
    Write-Host ''
    Write-Host '選用全域技能：mattpocock/skills'
    Write-Host "預設技能（10 個）：$((Get-MattPocockSkillNames) -join '、')"
    return Select-OptionalComponentAction -Name 'mattpocock/skills' -State (Get-OptionalComponentState -Installed $AlreadyInstalled)
}

function Select-OptionalDefaultModeRequestUserInput([bool]$AlreadyInstalled = $false) {
    Write-Host ''
    Write-Host '選用功能：預設啟用 request_user_input'
    Write-Host '會在 config.toml 的 [features] 加入 default_mode_request_user_input = true。'
    return Select-OptionalComponentAction -Name 'request_user_input' -State (Get-OptionalComponentState -Installed $AlreadyInstalled)
}

function Select-LongRunningAsyncWaitPolicy([string]$Root, [string]$SourceRoot) {
    Write-Host ''
    Write-Host 'Other Settings'
    Write-Host ''
    Write-Host 'Long-running async wait / Token-saving policy'
    Write-Host '減少長時間非同步工作尚未完成時的不必要模型喚醒。'
    Write-Host '會在全域 AGENTS.md 加入獨立受管理區塊。'
    $content = if (Test-Path -LiteralPath (Join-Path $Root 'AGENTS.md') -PathType Leaf) { [IO.File]::ReadAllText((Join-Path $Root 'AGENTS.md')) } else { '' }
    $template = Get-LongRunningAsyncWaitPolicyTemplate -SourceRoot $SourceRoot
    $state = Get-LongRunningAsyncWaitPolicyState -Content $content -ManagedContent $template
    if ($state.Status -eq 'NotInstalled') {
        Write-Host '尚未安裝。'
        return Select-OptionalComponentAction -Name 'Long-running async wait policy' -State 'NotInstalled'
    }
    if ($state.Status -eq 'Conflict') {
        Write-Host '偵測到不完整或重複的 managed block；本次不修改。'
        return 'Blocked'
    }
    $lifecycleState = if ($state.Status -eq 'InstalledCurrent') { 'InstalledCurrent' } else { 'InstalledUpdateAvailable' }
    return Select-OptionalComponentAction -Name 'Long-running async wait policy' -State $lifecycleState
}

function Test-WindowsNotificationsInstalled([string]$Root = (Join-Path $HOME '.codex')) {
    $configPath = Join-Path $Root 'config.toml'
    if ((Test-Path -LiteralPath (Join-Path $Root 'hooks\show-codex-notification.ps1') -PathType Leaf) -and (Test-Path -LiteralPath $configPath -PathType Leaf) -and (Test-WindowsNotificationCommandConfig -Content ([IO.File]::ReadAllText($configPath)) -Root $Root)) { return $true }
    $hooksPath = Join-Path $Root 'hooks.json'
    if (-not (Test-Path -LiteralPath $hooksPath -PathType Leaf)) { return $false }
    try {
        $hooksObject = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in @($hooksObject.hooks.PSObject.Properties)) {
            if (@($property.Value | Where-Object { Test-ManagedNotificationHookEntry $_ }).Count -gt 0) { return $true }
        }
    } catch { return $false }
    return $false
}

function Select-OptionalWindowsNotifications([bool]$AlreadyInstalled = (Test-WindowsNotificationsInstalled), [string]$State = '', $Lifecycle = $null) {
    Write-Host ''
    Write-Host '選用社區功能：Windows 開發狀態通知與用量指令'
    Write-Host '此功能會安裝／管理：'
    Write-Host '- 任務完成、等待權限、等待回答等 Codex 狀態提醒'
    Write-Host '- ccusage、ccsessions、cdaily 用量查詢指令（不由 Hook 自動執行）'
    Write-Host '手動用量指令欄位：Session、Model、Input、Output、Think、Cache、Total、Cost、Time'
    if ($null -ne $Lifecycle) { $State = [string]$Lifecycle.State }
    if ([string]::IsNullOrWhiteSpace($State)) { $State = Get-OptionalComponentState -Installed $AlreadyInstalled }
    if ($State -in @('TrueUnmanagedConflict', 'MalformedUserOwnedState', 'Unknown') -and $null -ne $Lifecycle) { throw (Format-WindowsNotificationLifecycleDiagnostic -Lifecycle $Lifecycle) }
    return Select-OptionalComponentAction -Name 'Windows 開發狀態通知與用量指令' -State $State
}

function Test-DefaultModeRequestUserInputInstalled([string]$Root = (Join-Path $HOME '.codex')) {
    $path = Join-Path $Root 'config.toml'
    return (Test-Path -LiteralPath $path -PathType Leaf) -and ([IO.File]::ReadAllText($path) -match '(?m)^\s*default_mode_request_user_input\s*=\s*true\s*(?:#.*)?$')
}
