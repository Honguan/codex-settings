function New-InstallationOwnershipManifest {
    [CmdletBinding()]
    param(
        [switch]$InstallRequestExecutionOptimizer,
        [switch]$EnableDefaultModeRequestUserInput,
        [switch]$InstallWindowsNotifications,
        [switch]$InstallMattPocockSkills,
        [switch]$InstallPonytail,
        [switch]$InstallCodexOrchestration,
        [switch]$InstallSerena
    )

    return [ordered]@{
        personal = [ordered]@{
            codexSettings = [ordered]@{ Owner = 'CodexSettings'; Category = 'Personal'; Selected = $true; ManagedPaths = @('AGENTS.md', 'config.toml', 'hooks.json', 'hooks/runtime-core.ps1', 'rules/default.rules'); ManagedConfigSections = @('CODEX-SETTINGS:Global:CONFIG'); ManagedHooks = @('line-ending'); ManagedExternalState = @('CONTEXT7_API_KEY'); RollbackScope = 'PersonalTransaction' }
            requestExecutionOptimizer = [ordered]@{ Owner = 'CodexSettings'; Category = 'Personal'; Selected = [bool]$InstallRequestExecutionOptimizer; ManagedPaths = @('skills/request-execution-optimizer'); ManagedConfigSections = @(); ManagedHooks = @(); ManagedExternalState = @(); RollbackScope = 'PersonalTransaction' }
            requestUserInput = [ordered]@{ Owner = 'CodexSettings'; Category = 'Personal'; Selected = [bool]$EnableDefaultModeRequestUserInput; ManagedPaths = @(); ManagedConfigSections = @('features.default_mode_request_user_input'); ManagedHooks = @(); ManagedExternalState = @(); RollbackScope = 'PersonalTransaction' }
        }
        community = [ordered]@{
            windowsUsageNotifications = [ordered]@{ Owner = 'WindowsUsageNotifications'; Category = 'Community'; Selected = [bool]$InstallWindowsNotifications; ManagedPaths = @('hooks/show-codex-notification.ps1'); ManagedConfigSections = @(); ManagedHooks = @('PreToolUse/request_user_input', 'PermissionRequest', 'Stop/Completed'); ManagedExternalState = @('ccusage', 'ccsessions', 'cdaily', 'PowerShellProfiles'); RollbackScope = 'WindowsUsageNotificationTransaction' }
            mattpocockSkills = [ordered]@{ Owner = 'MattPocockSkills'; Category = 'Community'; Selected = [bool]$InstallMattPocockSkills; ManagedPaths = @('skills managed by mattpocock/skills'); ManagedConfigSections = @(); ManagedHooks = @(); ManagedExternalState = @('npx skills'); RollbackScope = 'MattPocockSkillsTransaction' }
            ponytail = [ordered]@{ Owner = 'Ponytail'; Category = 'Community'; Selected = [bool]$InstallPonytail; ManagedPaths = @(); ManagedConfigSections = @(); ManagedHooks = @('Ponytail lifecycle hooks'); ManagedExternalState = @('marketplace', 'plugin'); RollbackScope = 'PonytailTransaction' }
            codexOrchestration = [ordered]@{ Owner = 'CodexOrchestration'; Category = 'Community'; Selected = [bool]$InstallCodexOrchestration; ManagedPaths = @(); ManagedConfigSections = @('workflow'); ManagedHooks = @(); ManagedExternalState = @('marketplace', 'plugin'); RollbackScope = 'CodexOrchestrationTransaction' }
            serena = [ordered]@{ Owner = 'Serena'; Category = 'Community'; Selected = [bool]$InstallSerena; ManagedPaths = @(); ManagedConfigSections = @('mcp_servers.serena'); ManagedHooks = @(); ManagedExternalState = @('uv', 'serena'); RollbackScope = 'SerenaTransaction' }
        }
    }
}

function Save-InstallationManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Result, [Parameter(Mandatory = $true)]$Transaction, $External, $Ownership)

    $path = Join-Path $Result.Root '.codex-settings-manifest.json'
    Save-TransactionFile $Transaction $path
    $manifest = [ordered]@{
        Version = 6
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
    $manifest.Community = $Ownership.community
    if ($Result.Mode -eq 'Global') { $manifest.ManagedHooks = Get-ManagedHooksManifest -Root $Result.Root }
    if ($null -ne $External) { $manifest.External = $External }
    Write-JsonFileAtomic -Path $path -Value $manifest -Depth 16
}
