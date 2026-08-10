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
    Write-Host ''
    Write-Host '選用全域技能：request-execution-optimizer'
    Write-Host '預設不安裝；已受管理時會在後續更新中保留。'
    return Read-YesNoChoice -Prompt '要安裝嗎？[y/N]' -Default $false
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
    if ($AlreadyInstalled) {
        Write-Host '已偵測到既有安裝，本次會自動更新以上技能。'
        return $true
    }
    Write-Host '尚未安裝；選擇安裝後會加入 Codex 使用者層級。'
    return Read-YesNoChoice -Prompt '要安裝嗎？[y/N]' -Default $false
}

function Select-OptionalDefaultModeRequestUserInput {
    Write-Host ''
    Write-Host '選用功能：預設啟用 request_user_input'
    Write-Host '會在 config.toml 的 [features] 加入 default_mode_request_user_input = true。'
    return Read-YesNoChoice -Prompt '要啟用嗎？[y/N]' -Default $false
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
        return $(if (Read-YesNoChoice -Prompt '要安裝嗎？[Y/n]' -Default $true) { 'Install' } else { 'Skip' })
    }
    if ($state.Status -eq 'Conflict') {
        Write-Host '偵測到不完整或重複的 managed block；本次不修改。'
        return 'Skip'
    }
    Write-Host $(if ($state.Status -eq 'InstalledCurrent') { '已安裝目前版本。' } else { '已安裝舊版，可更新。' })
    Write-Host '[1] 保留／更新至目前版本（建議）'
    Write-Host '[2] 移除此設定'
    Write-Host '[3] 本次不變更'
    switch (Read-Host '請選擇 [1]') {
        '' { return 'Install' }
        '1' { return 'Install' }
        '2' { return 'Remove' }
        '3' { return 'Skip' }
        default { throw 'Long-running async wait 設定選項無效。' }
    }
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

function Select-OptionalWindowsNotifications([bool]$AlreadyInstalled = (Test-WindowsNotificationsInstalled)) {
    Write-Host ''
    Write-Host '選用社區功能：Windows 開發狀態與使用量通知'
    Write-Host '此功能會安裝／管理：'
    Write-Host '- 任務完成、等待權限、等待回答等 Codex 狀態提醒'
    Write-Host '- 每輪完成後的 Token / Cost 使用量通知'
    Write-Host '- ccusage、ccsessions、cdaily'
    Write-Host '使用量顯示：Session、Model、Input、Output、Think、Cache、Total、Cost、Time'
    if ($AlreadyInstalled) {
        Write-Host '已偵測到既有受管理通知；本次會保留並更新。'
        return Read-YesNoChoice -Prompt '要繼續安裝/更新嗎？[Y/n]' -Default $true
    }
    Write-Host '尚未安裝。'
    return Read-YesNoChoice -Prompt '要安裝嗎？[y/N]' -Default $false
}
