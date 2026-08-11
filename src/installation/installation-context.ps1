function ConvertTo-InstallerBoolean([object]$Value, [string]$ParameterName) {
    if ($Value -is [bool]) { return $Value }
    if ([string]$Value -eq '1') { return $true }
    if ([string]$Value -eq '0') { return $false }
    $parsed = $false
    if ([bool]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    throw "$ParameterName 必須是 true、false、1 或 0。"
}

function New-InstallerContext {
    [CmdletBinding()]
    param(
        [string]$SourceRoot = '',
        [string]$DevelopmentEnvironment,
        [string]$TargetUserProfile,
        [ValidateSet('Merge', 'Replace')]
        [string]$InstallStyle = 'Merge',
        [switch]$Force,
        [Nullable[bool]]$InstallWindowsNotifications,
        [Nullable[bool]]$InstallUsageTools
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
    $InstallWindowsNotifications = $false
    if ($null -eq $InstallUsageTools) {
        $InstallUsageTools = Test-UsageToolsInstalled -SourceRoot $SourceRoot
    }
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
        InstallUsageTools = [bool]$InstallUsageTools
    }
}
