function New-InstallerContext {
    [CmdletBinding()]
    param(
        [string]$DevelopmentEnvironment,
        [ValidateSet('Merge', 'Replace')]
        [string]$InstallStyle = 'Merge',
        [switch]$Force,
        [Nullable[bool]]$InstallWindowsNotifications
    )

    $globalRoot = Join-Path $HOME '.codex'
    if ([string]::IsNullOrWhiteSpace($DevelopmentEnvironment)) {
        $DevelopmentEnvironment = Get-DefaultDevelopmentEnvironment -Root $globalRoot
    }
    if ($Force) { $InstallStyle = 'Replace' }
    if ($null -eq $InstallWindowsNotifications) {
        $InstallWindowsNotifications = Test-WindowsNotificationsInstalled -Root $globalRoot
    }

    return [pscustomobject]@{
        ScriptRoot = $ScriptRoot
        BackupRoot = Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'
        GlobalRoot = $globalRoot
        DevelopmentEnvironment = $DevelopmentEnvironment
        InstallStyle = $InstallStyle
        Force = $InstallStyle -eq 'Replace'
        InstallWindowsNotifications = [bool]$InstallWindowsNotifications
    }
}
