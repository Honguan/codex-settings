[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Global', 'Backup', 'Restore', 'Uninstall')]
    [string]$Mode = 'Interactive',
    [switch]$SkipCcusageInstall,
    [switch]$InstallRequestExecutionOptimizer,
    [switch]$InstallMattPocockSkills,
    [switch]$InstallPonytail,
    [switch]$SkipPonytail,
    [switch]$InstallCodexOrchestration,
    [switch]$SkipCodexOrchestration,
    [switch]$InstallSerena,
    [switch]$SkipSerena,
    [switch]$InstallSerenaUv,
    [switch]$EnableDefaultModeRequestUserInput,
    [ValidateSet('Auto', 'Install', 'KeepCurrent', 'Update', 'Repair', 'Uninstall', 'SkipNotInstalled', 'LeaveUnchanged', 'Blocked')]
    [string]$LongRunningAsyncWaitAction = 'Auto',
    [switch]$ForceValidation,
    [switch]$ForceNotificationTest,
    [switch]$NoPause,
    [Nullable[bool]]$InstallWindowsNotifications,
    [ValidateSet('Git', 'CVS')]
    [string]$DevelopmentEnvironment,
    [string]$TargetUserProfile,
    [switch]$Force,
    [ValidateSet('Merge', 'Replace')]
    [string]$InstallStyle = 'Merge'
)

$ErrorActionPreference = 'Stop'
$installerParameters = @{} + $PSBoundParameters
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'load-installation.ps1')

Invoke-Installer @installerParameters
