[CmdletBinding()]
param(
    [ValidateSet('Completed', 'PermissionRequired', 'QuestionRequired', 'Error')]
    [string]$Type = 'Completed',
    [string]$ProjectName,
    [switch]$Test
)

$ErrorActionPreference = 'Stop'

function Write-HookResult { [Console]::Out.Write('{}') }

function Get-HookInput {
    try {
        $raw = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch { return $null }
}

function Get-NotificationRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_NOTIFICATION_STATE_ROOT)) {
        return [IO.Path]::GetFullPath($env:CODEX_SETTINGS_NOTIFICATION_STATE_ROOT)
    }
    return Join-Path $HOME '.codex\state\notifications'
}

function Write-HookDiagnostic($InputObject, [string]$Result, [string]$Details) {
    try {
        $root = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_HOOK_LOG_ROOT)) { Join-Path $HOME '.codex\logs\hooks' } else { $env:CODEX_SETTINGS_HOOK_LOG_ROOT }
        $sessionId = if ($null -eq $InputObject -or [string]::IsNullOrWhiteSpace([string]$InputObject.session_id)) { 'unknown' } else { [string]$InputObject.session_id }
        $safeSessionId = [regex]::Replace($sessionId, '[^A-Za-z0-9._-]', '_')
        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString('o')
            event = if ($null -eq $InputObject) { '' } else { [string]$InputObject.hook_event_name }
            handler = 'windows-notification'
            notificationType = $Type
            result = $Result
            sessionId = $sessionId
            turnId = if ($null -eq $InputObject) { '' } else { [string]$InputObject.turn_id }
            tool = if ($null -eq $InputObject) { '' } else { [string]$InputObject.tool_name }
            changedFileCount = 0
            changedFiles = @()
            details = $Details
        }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::AppendAllText((Join-Path $root ($safeSessionId + '.log')), (($entry | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    } catch {}
}

function Get-Settings([string]$Root) {
    $defaults = [ordered]@{
        enabled = $true
        completed = $true
        permissionRequired = $true
        questionRequired = $true
        error = $true
        sound = $true
        mainSessionOnly = $true
        dedupeSeconds = 10
    }
    $path = Join-Path $Root 'settings.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        [IO.File]::WriteAllText($path, (($defaults | ConvertTo-Json) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]$defaults
    }
    try {
        $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in $defaults.Keys) {
            if ($stored.PSObject.Properties.Name -notcontains $property) { $stored | Add-Member -NotePropertyName $property -NotePropertyValue $defaults[$property] }
        }
        return $stored
    } catch { return [pscustomobject]$defaults }
}

function Resolve-ProjectName($InputObject, [string]$ExplicitName) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitName)) { return $ExplicitName.Trim() }
    $cwd = [string]$InputObject.cwd
    if ([string]::IsNullOrWhiteSpace($cwd) -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { return 'Codex' }
    $current = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($cwd))
    while ($null -ne $current) {
        if ((Test-Path -LiteralPath (Join-Path $current.FullName '.git')) -or (Test-Path -LiteralPath (Join-Path $current.FullName 'CVS'))) {
            return $current.Name
        }
        $current = $current.Parent
    }
    return [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($cwd)).Name
}

function Test-Duplicate([string]$Root, $InputObject, [string]$NotificationType, [int]$Seconds) {
    $sessionId = [string]$InputObject.session_id
    $turnId = [string]$InputObject.turn_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = 'unknown-session' }
    if ([string]::IsNullOrWhiteSpace($turnId)) { $turnId = 'unknown-turn' }
    $key = "$sessionId|$turnId|$NotificationType"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $name = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))).Replace('-', '').ToLowerInvariant() + '.json' }
    finally { $sha.Dispose() }
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $path = Join-Path $Root $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $age = [DateTimeOffset]::UtcNow - [DateTimeOffset](Get-Item -LiteralPath $path).LastWriteTimeUtc
        if ($age.TotalSeconds -lt [Math]::Max(1, $Seconds)) { return $true }
    }
    [IO.File]::WriteAllText($path, (@{ sessionId = $sessionId; turnId = $turnId; type = $NotificationType; updatedAt = [DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    return $false
}

function ConvertTo-XmlText([string]$Text) { return [Security.SecurityElement]::Escape($Text) }

function Show-NativeToast([string]$Title, [string]$Message, [string]$NotificationType, [bool]$Sound) {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $audio = if (-not $Sound) { '<audio silent="true" />' } elseif ($NotificationType -eq 'PermissionRequired') { '<audio src="ms-winsoundevent:Notification.Reminder" />' } elseif ($NotificationType -eq 'QuestionRequired') { '<audio src="ms-winsoundevent:Notification.IM" />' } else { '<audio src="ms-winsoundevent:Notification.Default" />' }
    $xml = '<toast><visual><binding template="ToastGeneric"><text>' + (ConvertTo-XmlText $Title) + '</text><text>' + (ConvertTo-XmlText $Message) + '</text></binding></visual>' + $audio + '</toast>'
    $document = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $document.LoadXml($xml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($document)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Microsoft.WindowsTerminal_8wekyb3d8bbwe!App').Show($toast)
}

function Show-BalloonFallback([string]$Title, [string]$Message, [string]$NotificationType, [bool]$Sound) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $icon = [Windows.Forms.NotifyIcon]::new()
    try {
        $icon.Icon = [Drawing.SystemIcons]::Information
        $icon.Visible = $true
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Message
        $icon.BalloonTipIcon = if ($NotificationType -eq 'PermissionRequired') { [Windows.Forms.ToolTipIcon]::Warning } elseif ($NotificationType -eq 'Error') { [Windows.Forms.ToolTipIcon]::Error } else { [Windows.Forms.ToolTipIcon]::Info }
        $icon.ShowBalloonTip(5000)
        if ($Sound) { [Console]::Beep(880, 120) }
        Start-Sleep -Milliseconds 800
    } finally { $icon.Dispose() }
}

$inputObject = $null
try {
    $inputObject = if ($Test) { [pscustomobject]@{} } else { Get-HookInput }
    if ($null -eq $inputObject) { $inputObject = [pscustomobject]@{} }
    if ($Test) {
        $inputObject | Add-Member -NotePropertyName session_id -NotePropertyValue 'notification-test' -Force
        $inputObject | Add-Member -NotePropertyName turn_id -NotePropertyValue ([guid]::NewGuid().ToString('N')) -Force
        if ([string]::IsNullOrWhiteSpace($ProjectName)) { $ProjectName = 'Codex Settings' }
    }
    if ($Type -eq 'Completed' -and [string]$inputObject.last_assistant_message -match '(?s)(?:[?？]\s*$|請(?:選擇|確認|提供|回答))') { $Type = 'QuestionRequired' }
    $root = Get-NotificationRoot
    $settings = Get-Settings -Root $root
    $settingName = $Type.Substring(0, 1).ToLowerInvariant() + $Type.Substring(1)
    if (-not $Test -and (-not [bool]$settings.enabled -or -not [bool]$settings.$settingName)) {
        Write-HookDiagnostic -InputObject $inputObject -Result 'disabled' -Details ''
        Write-HookResult
        return
    }
    if (Test-Duplicate -Root $root -InputObject $inputObject -NotificationType $Type -Seconds ([int]$settings.dedupeSeconds)) {
        Write-HookDiagnostic -InputObject $inputObject -Result 'deduplicated' -Details ''
        Write-HookResult
        return
    }

    $project = (Resolve-ProjectName -InputObject $inputObject -ExplicitName $ProjectName) -replace '[\r\n\t]+', ' '
    if ($project.Length -gt 80) { $project = $project.Substring(0, 80) }
    $content = switch ($Type) {
        'PermissionRequired' { [pscustomobject]@{ Title = 'Codex 等待權限核准'; Message = "$project 需要你的核准才能繼續執行。" } }
        'QuestionRequired' { [pscustomobject]@{ Title = 'Codex 等待你的回答'; Message = "$project 有問題需要確認，請回到 Codex 繼續。" } }
        'Error' { [pscustomobject]@{ Title = 'Codex 執行失敗'; Message = "$project 的工作未完成，請查看錯誤內容。" } }
        default { [pscustomobject]@{ Title = 'Codex 任務完成'; Message = "$project 的工作已完成，請回到 Codex 查看結果。" } }
    }

    $testMode = $env:CODEX_SETTINGS_NOTIFICATION_TEST_MODE -eq '1'
    if ($testMode) {
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_NOTIFICATION_TEST_LOG)) {
            Add-Content -LiteralPath $env:CODEX_SETTINGS_NOTIFICATION_TEST_LOG -Value (@{ type = $Type; title = $content.Title; message = $content.Message; project = $project } | ConvertTo-Json -Compress) -Encoding UTF8
        }
    } else {
        try { Show-NativeToast -Title $content.Title -Message $content.Message -NotificationType $Type -Sound ([bool]$settings.sound) }
        catch {
            try { Show-BalloonFallback -Title $content.Title -Message $content.Message -NotificationType $Type -Sound ([bool]$settings.sound) }
            catch { if ([bool]$settings.sound) { [Console]::Error.Write([char]7) } }
        }
    }
    Write-HookDiagnostic -InputObject $inputObject -Result 'success' -Details ''
} catch {
    Write-HookDiagnostic -InputObject $inputObject -Result 'error' -Details $_.Exception.Message
}

Write-HookResult
