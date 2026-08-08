function New-InstallerContext {
    [CmdletBinding()]
    param(
        [string]$SourceRoot = '',
        [string]$DevelopmentEnvironment,
        [ValidateSet('Merge', 'Replace')]
        [string]$InstallStyle = 'Merge',
        [switch]$Force,
        [Nullable[bool]]$InstallWindowsNotifications
    )

    if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = [string]$ScriptRoot }
    $globalRoot = Join-Path $HOME '.codex'
    if ([string]::IsNullOrWhiteSpace($DevelopmentEnvironment)) {
        $DevelopmentEnvironment = Get-DefaultDevelopmentEnvironment -Root $globalRoot
    }
    if ($Force) { $InstallStyle = 'Replace' }
    if ($null -eq $InstallWindowsNotifications) {
        $InstallWindowsNotifications = Test-WindowsNotificationsInstalled -Root $globalRoot
    }
    $skillsManifestPath = Join-Path $HOME '.codex\skills\.codex-settings-manifest.json'

    return [pscustomobject]@{
        ScriptRoot = $SourceRoot
        SourceRoot = $SourceRoot
        BackupRoot = Join-Path $env:LOCALAPPDATA 'CodexSettingsBackup'
        GlobalRoot = $globalRoot
        DevelopmentEnvironment = $DevelopmentEnvironment
        InstallStyle = $InstallStyle
        Force = $InstallStyle -eq 'Replace'
        InstallWindowsNotifications = [bool]$InstallWindowsNotifications
        ExistingSkillsInstalled = Test-Path -LiteralPath $skillsManifestPath -PathType Leaf
    }
}
