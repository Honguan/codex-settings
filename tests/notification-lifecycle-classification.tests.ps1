$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-issue87-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $testRoot '.codex'
$utf8 = [Text.UTF8Encoding]::new($false)

function Reset-NotificationFixture {
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
    [IO.Directory]::CreateDirectory((Join-Path $root 'hooks')) | Out-Null
}

function Set-NotificationFixture([string]$Config = '', $Hooks = $null, [switch]$Script, [switch]$Manifest) {
    [IO.File]::WriteAllText((Join-Path $root 'config.toml'), $Config, $utf8)
    if ($null -ne $Hooks) { [IO.File]::WriteAllText((Join-Path $root 'hooks.json'), ($Hooks | ConvertTo-Json -Depth 30), $utf8) }
    if ($Script) { [IO.File]::Copy((Join-Path $script:ScriptRoot 'templates\core\hooks\show-codex-notification.ps1'), (Join-Path $root 'hooks\show-codex-notification.ps1'), $true) }
    if ($Manifest) {
        $value = [ordered]@{ Community = [ordered]@{ windowsUsageNotifications = [ordered]@{ Owner = 'WindowsUsageNotifications' } }; ManagedHooks = Get-ManagedHooksManifest -Root $root }
        [IO.File]::WriteAllText((Join-Path $root '.codex-settings-manifest.json'), ($value | ConvertTo-Json -Depth 16), $utf8)
    }
}

function Get-TemplateHooks { return Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'templates\core\hooks.json') -Raw | ConvertFrom-Json }
function Get-CurrentConfig { return Merge-WindowsNotificationCommandConfig -Content '' -Root $root -NewLine "`n" }
function Assert-State([string]$Expected) {
    $actual = Get-WindowsNotificationLifecycleState -Root $root
    if ($actual.State -ne $Expected) { throw "Expected $Expected, got $($actual.State): $(Format-WindowsNotificationLifecycleDiagnostic $actual)" }
    return $actual
}

try {
    Reset-NotificationFixture
    Set-NotificationFixture
    Assert-State NotInstalled | Out-Null

    Reset-NotificationFixture
    $sectionNotify = "[third_party]`n" + (Get-WindowsNotificationCommandConfig -Root $root) + "`n"
    Set-NotificationFixture -Config $sectionNotify
    Assert-State NotInstalled | Out-Null
    $sectionTransaction = New-FileTransaction -Root (Join-Path $testRoot 'section-transaction') -Mode Install
    Invoke-WindowsUsageNotificationFiles -Root $root -SourceRoot $script:ScriptRoot -Transaction $sectionTransaction | Out-Null
    if ([regex]::Matches([IO.File]::ReadAllText((Join-Path $root 'config.toml')), '(?m)^\s*notify\s*=').Count -ne 2) { throw 'A section-owned notify entry was removed during installation.' }

    Reset-NotificationFixture
    Set-NotificationFixture -Config (Get-CurrentConfig) -Hooks (Get-TemplateHooks) -Script -Manifest
    $current = Assert-State InstalledCurrent
    if (-not $current.ManagedManifestPresent -or -not $current.ManagedFingerprintEvidence) { throw 'Manifest notification fingerprints were not loaded automatically.' }

    Reset-NotificationFixture
    $legacyHooks = Get-TemplateHooks
    $legacyHooks.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @([pscustomobject]@{ matcher = '*'; hooks = @([pscustomobject]@{ type = 'command'; command = 'pwsh -File "$HOME/.codex/hooks/show-codex-notification.ps1" -Type Completed'; timeout = 15 }) }) -Force
    Set-NotificationFixture -Hooks $legacyHooks -Script
    Assert-State InstalledNeedsMigration | Out-Null

    Reset-NotificationFixture
    $outdated = (Get-CurrentConfig).Replace('"-Type", "Completed"', '"-Type", "Completed", "--legacy"')
    Set-NotificationFixture -Config $outdated -Hooks (Get-TemplateHooks) -Script
    Assert-State InstalledUpdateAvailable | Out-Null

    Reset-NotificationFixture
    $partial = $script:WindowsNotificationConfigStartMarker + "`n" + (Get-WindowsNotificationCommandConfig -Root $root) + "`nuser_setting = true`n"
    Set-NotificationFixture -Config $partial -Hooks (Get-TemplateHooks) -Script
    Assert-State ManagedPartialState | Out-Null

    Reset-NotificationFixture
    $block = Get-CurrentConfig
    Set-NotificationFixture -Config ($block + "`n" + $block) -Hooks (Get-TemplateHooks) -Script
    Assert-State ManagedDuplicateState | Out-Null

    Reset-NotificationFixture
    $duplicateHooks = Get-TemplateHooks
    $duplicateHooks.hooks.PreToolUse = @($duplicateHooks.hooks.PreToolUse) + @($duplicateHooks.hooks.PreToolUse)
    $duplicateHooks.hooks.PermissionRequest = @($duplicateHooks.hooks.PermissionRequest) + @($duplicateHooks.hooks.PermissionRequest)
    Set-NotificationFixture -Config (Get-CurrentConfig) -Hooks $duplicateHooks -Script
    Assert-State ManagedDuplicateState | Out-Null
    if ((Resolve-OptionalComponentAction -State ManagedDuplicateState) -ne 'Repair' -or (Resolve-OptionalComponentAction -State ManagedDuplicateState -Selection No) -ne 'Uninstall') { throw 'Managed duplicates did not follow installed-component repair/uninstall semantics.' }

    Reset-NotificationFixture
    $ownedUnmarked = (Get-WindowsNotificationCommandConfig -Root $root) + "`nuser_setting = true`n"
    Set-NotificationFixture -Config $ownedUnmarked -Hooks (Get-TemplateHooks) -Script -Manifest
    Assert-State InstalledNeedsMigration | Out-Null

    Reset-NotificationFixture
    Set-NotificationFixture -Config $ownedUnmarked
    $staleManifest = [ordered]@{ Community = [ordered]@{ windowsUsageNotifications = [ordered]@{ Owner = 'WindowsUsageNotifications'; Selected = $false; Status = 'Uninstalled' } } }
    [IO.File]::WriteAllText((Join-Path $root '.codex-settings-manifest.json'), ($staleManifest | ConvertTo-Json -Depth 8), $utf8)
    Assert-State TrueUnmanagedConflict | Out-Null

    Reset-NotificationFixture
    Set-NotificationFixture -Config 'notify = ["custom.exe", "secret-value-must-not-leak"]' -Hooks (Get-TemplateHooks) -Script
    $conflict = Assert-State TrueUnmanagedConflict
    $diagnostic = Format-WindowsNotificationLifecycleDiagnostic $conflict
    foreach ($field in @('notificationLifecycleState=TrueUnmanagedConflict', 'notificationConfigState=UnmanagedNotifyConflict', 'ownershipClassification=Unmanaged', 'conflictReason=', 'recommendedAction=')) { if (-not $diagnostic.Contains($field)) { throw "Missing conflict diagnostic: $field" } }
    if ($diagnostic.Contains('secret-value-must-not-leak')) { throw 'Conflict diagnostics exposed config content.' }
    $beforeConflict = [IO.File]::ReadAllBytes((Join-Path $root 'config.toml'))
    $conflictTransaction = New-FileTransaction -Root (Join-Path $testRoot 'conflict-transaction') -Mode Conflict
    $blocked = try { Invoke-WindowsUsageNotificationFiles -Root $root -SourceRoot $script:ScriptRoot -Transaction $conflictTransaction | Out-Null; $false } catch { $_.Exception.Message -match 'TrueUnmanagedConflict' }
    if (-not $blocked -or [Convert]::ToHexString($beforeConflict) -ne [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $root 'config.toml')))) { throw 'True unmanaged notify conflict was not blocked without mutation.' }

    Reset-NotificationFixture
    Set-NotificationFixture -Config 'notify = ["third-party-notifier.exe"]'
    Assert-State TrueUnmanagedConflict | Out-Null

    Reset-NotificationFixture
    $coexistenceHooks = Get-TemplateHooks
    $coexistenceHooks.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @([pscustomobject]@{ matcher = '*'; hooks = @([pscustomobject]@{ type = 'command'; command = 'pwsh -File "$HOME/.codex/hooks/show-codex-notification.ps1" -Type Completed'; timeout = 15 }) }) -Force
    $externalNotify = 'notify = ["node.exe", "C:\third-party\notify.cjs"]' + "`n"
    Set-NotificationFixture -Config $externalNotify -Hooks $coexistenceHooks -Script -Manifest
    Assert-State InstalledNeedsMigration | Out-Null
    $coexistenceTransaction = New-FileTransaction -Root (Join-Path $testRoot 'coexistence-transaction') -Mode Repair
    Invoke-WindowsUsageNotificationFiles -Root $root -SourceRoot $script:ScriptRoot -Transaction $coexistenceTransaction | Out-Null
    Assert-State InstalledCurrent | Out-Null
    if ([IO.File]::ReadAllText((Join-Path $root 'config.toml')) -ne $externalNotify) { throw 'External top-level notify was not preserved exactly.' }
    Assert-GlobalLineEndingHook -DevelopmentEnvironment Git -Root $root -InstallWindowsNotifications $true -ProjectRoot '' | Out-Null
    $coexistenceSecondTransaction = New-FileTransaction -Root (Join-Path $testRoot 'coexistence-idempotent-transaction') -Mode Repair
    if ((Invoke-WindowsUsageNotificationFiles -Root $root -SourceRoot $script:ScriptRoot -Transaction $coexistenceSecondTransaction).Changed) { throw 'Repeated coexistence repair was not idempotent.' }

    Reset-NotificationFixture
    Set-NotificationFixture -Config ((Get-CurrentConfig) + "`nnotify = [`"third-party-notifier.exe`"]`n") -Hooks (Get-TemplateHooks) -Script
    Assert-State TrueUnmanagedConflict | Out-Null

    Reset-NotificationFixture
    Set-NotificationFixture -Config 'user_setting = ['
    Assert-State MalformedUserOwnedState | Out-Null

    Reset-NotificationFixture
    $repairHooks = Get-TemplateHooks
    $repairHooks.hooks.PreToolUse = @($repairHooks.hooks.PreToolUse) + @($repairHooks.hooks.PreToolUse)
    $repairHooks.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @([pscustomobject]@{ matcher = '*'; hooks = @([pscustomobject]@{ type = 'command'; command = 'custom-stop.ps1'; timeout = 15 }) }) -Force
    Set-NotificationFixture -Config $partial -Hooks $repairHooks -Script
    $beforeRepair = @('config.toml', 'hooks.json', 'hooks\show-codex-notification.ps1') | ForEach-Object { [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $root $_))) }
    $repairTransaction = New-FileTransaction -Root (Join-Path $testRoot 'repair-transaction') -Mode Repair
    $repair = Invoke-WindowsUsageNotificationFiles -Root $root -SourceRoot $script:ScriptRoot -Transaction $repairTransaction
    Assert-State InstalledCurrent | Out-Null
    $repairedHooks = Get-Content -LiteralPath (Join-Path $root 'hooks.json') -Raw | ConvertFrom-Json
    if (@($repairedHooks.hooks.Stop[0].hooks | Where-Object command -eq 'custom-stop.ps1').Count -ne 1) { throw 'Repair removed an unrelated user hook.' }
    $secondTransaction = New-FileTransaction -Root (Join-Path $testRoot 'idempotent-transaction') -Mode Repair
    if ((Invoke-WindowsUsageNotificationFiles -Root $root -SourceRoot $script:ScriptRoot -Transaction $secondTransaction).Changed) { throw 'Repeated repair was not idempotent.' }
    Undo-FileTransaction -Transaction $repairTransaction
    $afterRollback = @('config.toml', 'hooks.json', 'hooks\show-codex-notification.ps1') | ForEach-Object { [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $root $_))) }
    if (($beforeRepair -join "`n") -ne ($afterRollback -join "`n")) { throw 'Repair rollback did not restore the exact prior state.' }

    Reset-NotificationFixture
    Set-NotificationFixture -Config (Get-CurrentConfig) -Hooks (Get-TemplateHooks)
    Assert-State ManagedPartialState | Out-Null
    Reset-NotificationFixture
    Set-NotificationFixture -Config (Get-CurrentConfig) -Script
    Assert-State ManagedPartialState | Out-Null

    Reset-NotificationFixture
    Set-NotificationFixture -Config (Get-CurrentConfig) -Hooks (Get-TemplateHooks) -Script
    $direct = Get-WindowsNotificationLifecycleState -Root $root
    $context = [pscustomobject]@{ ScriptRoot = $script:ScriptRoot; GlobalRoot = $root; DevelopmentEnvironment = 'Git'; InstallStyle = 'Merge' }
    $discovery = Get-InstallationDiscovery -Context $context -Targets @([pscustomobject]@{ Id = 'global'; Root = $root })
    if ($discovery.windowsUsageNotifications.State -ne $direct.State) { throw 'Interactive/plan discovery did not use the same notification classifier.' }

    Write-Host 'Windows notification ownership classification, diagnostics, repair, idempotency, and rollback tests passed.'
} finally {
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}
