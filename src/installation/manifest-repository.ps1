function New-InstallationOwnershipManifest {
    [CmdletBinding()]
    param(
        [switch]$EnableDefaultModeRequestUserInput,
        [ValidateSet('Install', 'KeepCurrent', 'Update', 'Repair', 'Uninstall', 'SkipNotInstalled', 'LeaveUnchanged', 'Blocked')][string]$LongRunningAsyncWaitAction = 'Install',
        [switch]$InstallWindowsNotifications,
        [switch]$InstallUsageTools,
        [switch]$InstallMattPocockSkills,
        [switch]$InstallPonytail,
        [switch]$InstallCodexOrchestration,
        [switch]$InstallSerena
    )

    return [ordered]@{
        personal = [ordered]@{
            codexSettings = [ordered]@{ Owner = 'CodexSettings'; Category = 'Personal'; Selected = $true; ManagedPaths = @('AGENTS.md', 'config.toml', 'rules/default.rules'); ManagedConfigSections = @('CODEX-SETTINGS:Global:CONFIG'); ManagedHooks = @(); ManagedExternalState = @(); RollbackScope = 'PersonalTransaction' }
            requestUserInput = [ordered]@{ Owner = 'CodexSettings'; Category = 'Personal'; Selected = [bool]$EnableDefaultModeRequestUserInput; Action = $(if ($EnableDefaultModeRequestUserInput) { 'Install' } else { 'SkipNotInstalled' }); DiscoveredState = 'Unknown'; LastResult = ''; ManagedPaths = @(); ManagedConfigSections = @('features.default_mode_request_user_input'); ManagedHooks = @(); ManagedExternalState = @(); RollbackScope = 'PersonalTransaction' }
        }
        otherSettings = [ordered]@{
            longRunningAsyncWait = [ordered]@{ Owner = 'CodexSettings'; Category = 'Other Settings'; Selected = (Test-OptionalComponentKeepAction $LongRunningAsyncWaitAction); Action = $LongRunningAsyncWaitAction; DiscoveredState = 'Unknown'; LastResult = ''; Version = $script:LongRunningAsyncWaitPolicyVersion; ManagedPaths = @('AGENTS.md'); ManagedConfigSections = @('CODEX-SETTINGS:OTHER:LONG-RUNNING-ASYNC-WAIT:v1'); ManagedHooks = @(); ManagedExternalState = @(); RollbackScope = 'PersonalTransaction'; managedBlockPresent = $false }
        }
        community = [ordered]@{
            usageTools = [ordered]@{ Owner = 'UsageTools'; Category = 'Community'; Selected = [bool]$InstallUsageTools; Action = $(if ($InstallUsageTools) { 'Install' } else { 'SkipNotInstalled' }); DiscoveredState = 'Unknown'; LastResult = ''; ManagedPaths = @(); ManagedConfigSections = @(); ManagedHooks = @(); ManagedExternalState = @('ccusage', 'ccsessions', 'cdaily', 'PowerShellProfiles'); RollbackScope = 'UsageToolsTransaction'; packageStatus = 'not-tested'; commandsStatus = 'not-tested' }
            windowsUsageNotifications = [ordered]@{ Owner = 'WindowsUsageNotifications'; Category = 'Community'; Selected = $false; Action = 'SkipNotInstalled'; DiscoveredState = 'Archived'; ManagedPaths = @(); ManagedConfigSections = @(); ManagedHooks = @(); ManagedExternalState = @(); RollbackScope = 'WindowsUsageNotificationTransaction'; scriptPresent = $false; hookConfigured = $false; hookTrusted = $false; hookEffective = $false; directToastShown = $false; lastInvocation = $null; lastResult = 'archived' }
            mattpocockSkills = [ordered]@{ Owner = 'MattPocockSkills'; Category = 'Community'; Selected = [bool]$InstallMattPocockSkills; Action = $(if ($InstallMattPocockSkills) { 'Install' } else { 'SkipNotInstalled' }); DiscoveredState = 'Unknown'; LastResult = ''; ManagedPaths = @('skills managed by mattpocock/skills'); ManagedConfigSections = @(); ManagedHooks = @(); ManagedExternalState = @('npx skills'); RollbackScope = 'MattPocockSkillsTransaction' }
            ponytail = [ordered]@{ Owner = 'Ponytail'; Category = 'Community'; Selected = [bool]$InstallPonytail; Action = $(if ($InstallPonytail) { 'Install' } else { 'SkipNotInstalled' }); DiscoveredState = 'Unknown'; LastResult = ''; ManagedPaths = @(); ManagedConfigSections = @(); ManagedHooks = @('Ponytail lifecycle hooks'); ManagedExternalState = @('marketplace', 'plugin'); RollbackScope = 'PonytailTransaction' }
            codexOrchestration = [ordered]@{ Owner = 'CodexOrchestration'; Category = 'Community'; Selected = [bool]$InstallCodexOrchestration; Action = $(if ($InstallCodexOrchestration) { 'Install' } else { 'SkipNotInstalled' }); DiscoveredState = 'Unknown'; LastResult = ''; ManagedPaths = @(); ManagedConfigSections = @('workflow'); ManagedHooks = @(); ManagedExternalState = @('marketplace', 'plugin'); RollbackScope = 'CodexOrchestrationTransaction'; pluginStatus = 'SkippedNotInstalled'; workflowRequested = $false; workflowStatus = 'SkippedNotInstalled'; setupPrompt = ''; actionRequired = $false; lastVerified = $null }
            serena = [ordered]@{ Owner = 'Serena'; Category = 'Community'; Selected = [bool]$InstallSerena; Action = $(if ($InstallSerena) { 'Install' } else { 'SkipNotInstalled' }); DiscoveredState = 'Unknown'; LastResult = ''; ManagedPaths = @('~/.serena/serena_config.yml:web_dashboard_open_on_launch'); ManagedConfigSections = @('mcp_servers.serena'); ManagedHooks = @(); ManagedExternalState = @('uv', 'serena'); RollbackScope = 'SerenaTransaction' }
        }
    }
}

function Save-InstallationManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Result, [Parameter(Mandatory = $true)]$Transaction, $External, $Ownership)

    $path = Join-Path $Result.Root '.codex-settings-manifest.json'
    Save-TransactionFile $Transaction $path
    $manifest = [ordered]@{
        Version = 8
        SchemaVersion = 2
        Mode = $Result.Mode
        DevelopmentEnvironment = $Result.DevelopmentEnvironment
        InstalledAt = (Get-Date).ToString('o')
        TargetRoot = $Result.Root
        Files = $Result.Files
        Summary = $Result.Summary
    }
    if ($null -eq $Ownership) { $Ownership = New-InstallationOwnershipManifest }
    $manifest.Personal = $Ownership.personal
    $manifest.OtherSettings = $Ownership.otherSettings
    $manifest.Community = $Ownership.community
    if ($Result.Mode -eq 'Global') { $manifest.ManagedHooks = Get-ManagedHooksManifest -Root $Result.Root }
    if ($null -ne $External) { $manifest.External = $External }
    Write-JsonFileAtomic -Path $path -Value $manifest -Depth 16
}
