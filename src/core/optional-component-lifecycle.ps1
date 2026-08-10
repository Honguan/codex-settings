$script:OptionalComponentStates = @('NotInstalled', 'InstalledCurrent', 'InstalledUpdateAvailable', 'InstalledNeedsMigration', 'InstalledNeedsRepair', 'ManagedPartialState', 'ManagedDuplicateState', 'TrueUnmanagedConflict', 'MalformedUserOwnedState', 'Conflict', 'Unknown')
$script:OptionalComponentActions = @('Install', 'CheckUpdate', 'KeepCurrent', 'Update', 'Repair', 'Uninstall', 'SkipNotInstalled', 'LeaveUnchanged', 'Blocked')

function Resolve-OptionalComponentAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('NotInstalled', 'InstalledCurrent', 'InstalledUpdateAvailable', 'InstalledNeedsMigration', 'InstalledNeedsRepair', 'ManagedPartialState', 'ManagedDuplicateState', 'TrueUnmanagedConflict', 'MalformedUserOwnedState', 'Conflict', 'Unknown')][string]$State,
        [ValidateSet('Default', 'Yes', 'No', 'LeaveUnchanged')][string]$Selection = 'Default'
    )

    if ($State -in @('TrueUnmanagedConflict', 'MalformedUserOwnedState', 'Conflict', 'Unknown')) { return 'Blocked' }
    if ($Selection -eq 'LeaveUnchanged') { return $(if ($State -eq 'NotInstalled') { 'SkipNotInstalled' } else { 'LeaveUnchanged' }) }
    if ($Selection -eq 'No') { return $(if ($State -eq 'NotInstalled') { 'SkipNotInstalled' } else { 'Uninstall' }) }
    return $(switch ($State) {
        'NotInstalled' { 'Install' }
        'InstalledCurrent' { 'KeepCurrent' }
        'InstalledUpdateAvailable' { 'Update' }
        'InstalledNeedsMigration' { 'Update' }
        'InstalledNeedsRepair' { 'Repair' }
        'ManagedPartialState' { 'Repair' }
        'ManagedDuplicateState' { 'Repair' }
    })
}

function Get-OptionalComponentState([bool]$Installed, [switch]$UpdateAvailable, [switch]$NeedsRepair, [switch]$Conflict) {
    if ($Conflict) { return 'Conflict' }
    if (-not $Installed) { return 'NotInstalled' }
    if ($NeedsRepair) { return 'InstalledNeedsRepair' }
    if ($UpdateAvailable) { return 'InstalledUpdateAvailable' }
    return 'InstalledCurrent'
}

function Test-OptionalComponentKeepAction([string]$Action) {
    return $Action -in @('Install', 'CheckUpdate', 'KeepCurrent', 'Update', 'Repair')
}

function Get-OptionalComponentPlanAction([string]$ExplicitAction, [bool]$Installed, [bool]$Requested) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitAction)) { return $ExplicitAction }
    if ($Requested) { return Resolve-OptionalComponentAction -State (Get-OptionalComponentState -Installed $Installed) }
    return $(if ($Installed) { 'KeepCurrent' } else { 'SkipNotInstalled' })
}
