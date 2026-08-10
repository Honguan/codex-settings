function New-InstallerContext {
    [CmdletBinding()]
    param(
        [string]$SourceRoot = '',
        [string]$DevelopmentEnvironment,
        [string]$TargetUserProfile,
        [ValidateSet('Merge', 'Replace')]
        [string]$InstallStyle = 'Merge',
        [switch]$Force,
        [Nullable[bool]]$InstallWindowsNotifications
    )

    if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $SourceRoot = [string]$ScriptRoot }
    if ([string]::IsNullOrWhiteSpace($TargetUserProfile)) { $TargetUserProfile = [string]$HOME }
    $TargetUserProfile = [IO.Path]::GetFullPath($TargetUserProfile)
    if ($TargetUserProfile -match '(?i)(?:^|[\\/])CodexSandboxOffline(?:[\\/]|$)') {
        throw "拒絕安裝到 CodexSandboxOffline：$TargetUserProfile。請在一般 PowerShell 執行，或使用 -TargetUserProfile 指定實際 Windows 使用者目錄。"
    }
    $currentUserProfile = [IO.Path]::GetFullPath([string]$HOME)
    $useCurrentEnvironment = $TargetUserProfile -eq $currentUserProfile
    $appData = if ($useCurrentEnvironment -and -not [string]::IsNullOrWhiteSpace($env:APPDATA)) { [string]$env:APPDATA } else { Join-Path $TargetUserProfile 'AppData\Roaming' }
    $localAppData = if ($useCurrentEnvironment -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { [string]$env:LOCALAPPDATA } else { Join-Path $TargetUserProfile 'AppData\Local' }
    $globalRoot = Join-Path $TargetUserProfile '.codex'
    if ([string]::IsNullOrWhiteSpace($DevelopmentEnvironment)) {
        $DevelopmentEnvironment = Get-DefaultDevelopmentEnvironment -Root $globalRoot
    }
    if ($Force) { $InstallStyle = 'Replace' }
    if ($null -eq $InstallWindowsNotifications) {
        $InstallWindowsNotifications = Test-WindowsNotificationsInstalled -Root $globalRoot
    }
    $skillsManifestPath = Join-Path $globalRoot 'skills\.codex-settings-manifest.json'

    return [pscustomobject]@{
        ScriptRoot = $SourceRoot
        SourceRoot = $SourceRoot
        BackupRoot = Join-Path $localAppData 'CodexSettingsBackup'
        GlobalRoot = $globalRoot
        UserProfile = $TargetUserProfile
        AppData = $appData
        LocalAppData = $localAppData
        DevelopmentEnvironment = $DevelopmentEnvironment
        InstallStyle = $InstallStyle
        Force = $InstallStyle -eq 'Replace'
        InstallWindowsNotifications = [bool]$InstallWindowsNotifications
        ExistingSkillsInstalled = Test-Path -LiteralPath $skillsManifestPath -PathType Leaf
    }
}
