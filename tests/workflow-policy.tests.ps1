$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')
. (Join-Path $script:ScriptRoot 'templates\core\hooks\runtime-core.ps1')

function New-TestInput {
    param([string]$ToolName, [string]$Command = '')
    return [pscustomobject]@{
        tool_name = $ToolName
        tool_input = [pscustomobject]@{ command = $Command }
        session_id = 'workflow-session'
        turn_id = 'workflow-turn'
    }
}

$noFileImpact = Get-CodexToolImpactClassification -InputObject (New-TestInput -ToolName 'view_image')
if ($noFileImpact.classification -ne 'NoFileImpact' -or $noFileImpact.validationLevel -ne 'None') { throw 'NoFileImpact policy decision failed.' }

$readOnly = Get-CodexToolImpactClassification -InputObject (New-TestInput -ToolName 'exec' -Command 'rg --files .')
if ($readOnly.classification -ne 'ReadOnly' -or $readOnly.validationLevel -ne 'Fast') { throw 'ReadOnly policy decision failed.' }

$knownWrite = Get-CodexToolImpactClassification -InputObject (New-TestInput -ToolName 'apply_patch' -Command "*** Begin Patch`n*** Update File: src/test.ps1`n@@`n*** End Patch")
if ($knownWrite.classification -ne 'KnownWriteTargets' -or @($knownWrite.knownWriteTargets).Count -ne 1 -or $knownWrite.validationLevel -ne 'ChangedOnly') { throw 'KnownWriteTargets policy decision failed.' }

$unknownWrite = Get-CodexToolImpactClassification -InputObject (New-TestInput -ToolName 'exec' -Command 'pwsh -File update.ps1')
if ($unknownWrite.classification -ne 'UnknownWriteScope' -or $unknownWrite.validationLevel -ne 'Full') { throw 'UnknownWriteScope policy decision failed.' }

$mainSession = Get-CodexMainSessionClassification -InputObject ([pscustomobject]@{ is_main_session = $true })
$subagentSession = Get-CodexMainSessionClassification -InputObject ([pscustomobject]@{ parent_session_id = 'parent' })
$unknownSession = Get-CodexMainSessionClassification -InputObject (New-TestInput -ToolName 'exec')
if ($mainSession.Classification -ne 'Main' -or $subagentSession.Classification -ne 'Subagent' -or $unknownSession.Classification -ne 'Unknown' -or -not (Test-CodexMainSession -InputObject (New-TestInput -ToolName 'exec'))) { throw 'Main-session 三態或 Unknown allow policy decision failed.' }

$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-workflow-policy-' + [guid]::NewGuid().ToString('N'))
try {
    $unchangedFile = New-InstallFileResult -Path 'config.toml' -RelativePath 'config.toml' -Status Unchanged
    $existingResult = New-InstallationResult -Mode Global -Root $root -Files @($unchangedFile) -Previous ([pscustomobject]@{ Version = 5 }) -HookChanged $false
    $discovery = [pscustomobject]@{ usageTools = [pscustomobject]@{ profileCurrent = $true } }
    $fastPlan = New-InstallationChangePlan -Discovery $discovery -Results @($existingResult) -CcusageBefore ([pscustomobject]@{ Installed = $true; Version = '1.0.0' })
    if ($fastPlan.validationLevel -ne 'Fast' -or $fastPlan.runHookTrust -or $fastPlan.runNotificationTest -or $fastPlan.usageToolsChanged) { throw 'Unchanged install was not reduced to the fast workflow.' }
    if (Test-CodexWorkflowDecision -Plan $fastPlan -Operation HookTrust) { throw 'Fast workflow incorrectly enabled Hook trust.' }

    $serenaDiscovery = [pscustomobject]@{ usageTools = [pscustomobject]@{ profileCurrent = $true }; serenaDashboard = [pscustomobject]@{ Selected = $true; DashboardConfigStatus = 'Enabled'; NeedsChange = $true } }
    $serenaPlan = New-InstallationChangePlan -Discovery $serenaDiscovery -Results @($existingResult) -CcusageBefore ([pscustomobject]@{ Installed = $true; Version = '1.0.0' })
    if ($serenaPlan.validationLevel -ne 'ChangedOnly' -or -not $serenaPlan.externalConfigurationChanged -or $serenaPlan.serenaDashboard.action -ne 'ConfigureDoNotAutoOpen') { throw 'Current Serena package did not expose the required Dashboard ChangePlan item.' }
    $serenaDiscovery.serenaDashboard.DashboardConfigStatus = 'Disabled'
    $serenaDiscovery.serenaDashboard.NeedsChange = $false
    $serenaPlan = New-InstallationChangePlan -Discovery $serenaDiscovery -Results @($existingResult) -CcusageBefore ([pscustomobject]@{ Installed = $true; Version = '1.0.0' })
    if ($serenaPlan.serenaDashboard.action -ne 'AlreadyConfigured' -or $serenaPlan.externalConfigurationChanged) { throw 'Already configured Serena Dashboard plan is invalid.' }

    $changedFile = New-InstallFileResult -Path 'hooks.json' -RelativePath 'hooks.json' -Changed $true -Updated $true -Status Updated
    $changedResult = New-InstallationResult -Mode Global -Root $root -Files @($changedFile) -Previous ([pscustomobject]@{ Version = 5 }) -HookChanged $true
    $changedPlan = New-InstallationChangePlan -Discovery $discovery -Results @($changedResult) -CcusageBefore ([pscustomobject]@{ Installed = $true; Version = '1.0.0' })
    if ($changedPlan.validationLevel -ne 'ChangedOnly' -or -not $changedPlan.runHookTrust -or -not $changedPlan.runNotificationTest) { throw 'Hook-only change did not select the changed-only workflow.' }

    $changedConfig = New-InstallFileResult -Path 'config.toml' -RelativePath 'config.toml' -Changed $true -Updated $true -Status Updated
    $configPlan = New-InstallationChangePlan -Discovery $discovery -Results @((New-InstallationResult -Mode Global -Root $root -Files @($changedConfig) -Previous ([pscustomobject]@{ Version = 5 }) -HookChanged $false)) -CcusageBefore ([pscustomobject]@{ Installed = $true; Version = '1.0.0' })
    if (-not $configPlan.runConfigValidation -or -not $configPlan.runHookTrust) { throw 'Changed config.toml did not select real Codex app-server semantic validation.' }

    $firstPlan = New-InstallationChangePlan -Discovery $discovery -Results @([pscustomobject]@{ Mode = 'Global'; Previous = $null; HookChanged = $false; Files = @(); Summary = [pscustomobject]@{ Created = 0; Updated = 0 } }) -CcusageBefore ([pscustomobject]@{ Installed = $true; Version = '1.0.0' })
    if ($firstPlan.validationLevel -ne 'Full' -or -not $firstPlan.runHookValidation) { throw 'First install did not select full validation.' }
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host 'Workflow policy decision tests passed.'
