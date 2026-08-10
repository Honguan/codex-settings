$script:ManagedHookManifestId = 'codex-settings'
$script:ManagedHookManifestVersion = 3
$script:ManagedNotificationId = 'codex-settings-notification'
$script:ManagedNotificationVersion = 4
$script:WindowsNotificationConfigStartMarker = '# >>> CODEX-SETTINGS:WINDOWS-NOTIFICATIONS:CONFIG >>>'
$script:WindowsNotificationConfigEndMarker = '# <<< CODEX-SETTINGS:WINDOWS-NOTIFICATIONS:CONFIG <<<'
$script:ManagedLineEndingHookSignaturePattern = '(?i)((?:crlf-updated-files|normalize-cvs-crlf|preserve-line-endings)\.ps1|Converting updated files? to CRLF|Normalizing updated files to CRLF|Finalizing CRLF normalization|CodexSettings CRLF (?:track|finalize)|Restoring original line endings)'
$script:PreserveLineEndingHookSignaturePattern = '(?i)(preserve-line-endings\.ps1|Restoring original line endings)'
$script:LegacyCrlfHookSignaturePattern = '(?i)((?:crlf-updated-files|normalize-cvs-crlf)\.ps1|Converting updated files? to CRLF|Normalizing updated files to CRLF|Finalizing CRLF normalization|CodexSettings CRLF (?:track|finalize))'
$script:ManagedNotificationHookSignaturePattern = '(?i)(show-codex-notification\.ps1|CodexSettings Windows notification)'
$script:ManagedTokenHookSignaturePattern = '(?i)(show-turn-token-usage\.ps1|turn-token-usage|CodexSettings turn token usage)'
$script:ManagedGlobalHookSignaturePattern = '(?i)(show-codex-notification\.ps1|CodexSettings Windows notification|show-turn-token-usage\.ps1|turn-token-usage|CodexSettings turn token usage)'
$script:LegacyNotificationHookSignaturePattern = '(?i)(show[-_]?(?:codex|windows|win32|toast|balloon)[-_]?(?:notification|notify|toast|completion|completed)\.ps1|(?:codex|windows|win32|toast|balloon|completion|completed)[-_]?(?:notification|notify|toast|completion|completed)\.ps1|notify[-_]?codex\.ps1|CodexSettings Windows notification|Codex 任務完成|工作已完成|請回到 Codex)'
$script:LegacyTokenHookSignaturePattern = '(?i)(show[-_]?(?:turn[-_]?)?token[-_]?usage\.ps1|turn[-_]?token[-_]?usage|CodexSettings turn token usage)'

function Get-WindowsNotificationCommandConfig([string]$Root) {
    $scriptPath = (Join-Path $Root 'hooks\show-codex-notification.ps1').Replace('\', '\\').Replace('"', '\"')
    return 'notify = ["pwsh.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "' + $scriptPath + '", "-Type", "Completed"]'
}

function Remove-WindowsNotificationCommandConfig([string]$Content) {
    return Remove-ManagedBlock -Content $Content -StartMarker $script:WindowsNotificationConfigStartMarker -EndMarker $script:WindowsNotificationConfigEndMarker
}

function Merge-WindowsNotificationCommandConfig([string]$Content, [string]$Root, [string]$NewLine = "`r`n") {
    $base = Remove-WindowsNotificationCommandConfig -Content $Content
    $shape = Get-TomlShape -Content $base
    if ($shape.TopLevelKeys.Contains('notify')) { throw 'config.toml 已有非 Codex Settings 管理的 notify；無法安全安裝 Windows 完成通知。' }
    $block = $script:WindowsNotificationConfigStartMarker + $NewLine + (Get-WindowsNotificationCommandConfig -Root $Root) + $NewLine + $script:WindowsNotificationConfigEndMarker
    if ([string]::IsNullOrWhiteSpace($base)) { return $block + $NewLine }
    return $block + $NewLine + $NewLine + $base.Trim() + $NewLine
}

function Test-WindowsNotificationCommandConfig([string]$Content, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Content)) { return $false }
    $expected = Get-WindowsNotificationCommandConfig -Root $Root
    return $Content.Contains($script:WindowsNotificationConfigStartMarker) -and $Content.Contains($script:WindowsNotificationConfigEndMarker) -and $Content.Contains($expected)
}

function Get-HookEntryText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    return ($Entry | ConvertTo-Json -Depth 30 -Compress)
}

function Get-HookHandlerEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $hookProperty = $Entry.PSObject.Properties['hooks']
    if ($null -ne $hookProperty) { return @($hookProperty.Value) }
    return @($Entry)
}

function Get-CanonicalHookHandlerDescriptor {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$EventName, [Parameter(Mandatory = $true)]$Entry)

    $handler = @(Get-HookHandlerEntries -Entry $Entry | Select-Object -First 1)[0]
    if ($null -eq $handler) { return $null }
    $command = [string]$handler.command
    $commandWindows = [string]$handler.commandWindows
    $handlerId = $null
    $kind = $null
    $managedId = $null
    if (($command + ' ' + $commandWindows) -match '(?i)show-codex-notification\.ps1') {
        $kind = 'notification'
        $managedId = $script:ManagedNotificationId
        $handlerId = switch ($EventName) {
            'PreToolUse' { 'question-toast' }
            'PermissionRequest' { 'permission-toast' }
            'Stop' { 'completed-token-toast' }
            default { 'notification-toast' }
        }
    } elseif (($command + ' ' + $commandWindows) -match '(?i)preserve-line-endings\.ps1') {
        $kind = 'line-ending'
        $managedId = $script:ManagedHookManifestId
        $handlerId = 'line-ending-' + $EventName.ToLowerInvariant()
    } elseif (($command + ' ' + $commandWindows) -match '(?i)(?:show-turn-token-usage|turn-token-usage)\.ps1') {
        $kind = 'token'
        $managedId = $script:ManagedHookManifestId
        $handlerId = 'legacy-token-usage'
    }
    if ([string]::IsNullOrWhiteSpace($handlerId)) { return $null }
    return New-HookHandlerDescriptor -ManagedId $managedId -ManagedVersion $(if ($managedId -eq $script:ManagedNotificationId) { [string]$script:ManagedNotificationVersion } else { [string]$script:ManagedHookManifestVersion }) -HandlerId $handlerId -Kind $kind -EventName $EventName -Matcher (Get-CodexSettingsPropertyValue -InputObject $Entry -Names @('matcher') -Default '*') -Command $command -CommandWindows $commandWindows -Timeout ([int](Get-CodexSettingsPropertyValue -InputObject $handler -Names @('timeout') -Default 0)) -Fingerprint (Get-HookEntryFingerprint -Entry $Entry) -Legacy ($kind -eq 'token')
}

function Get-HookEntryFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((Get-HookEntryText -Entry $Entry))
        return 'sha256:' + ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Test-HookFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [string[]]$Fingerprints = @())

    if (@($Fingerprints).Count -eq 0) { return $false }
    $fingerprint = Get-HookEntryFingerprint -Entry $Entry
    return @($Fingerprints | Where-Object { [string]$_ -eq $fingerprint }).Count -gt 0
}

function Test-ManagedLineEndingHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $descriptor = Get-CanonicalHookHandlerDescriptor -EventName 'Unknown' -Entry $Entry
    return ($null -ne $descriptor -and [string]$descriptor.kind -eq 'line-ending') -or (Get-HookEntryText -Entry $Entry) -match $script:ManagedLineEndingHookSignaturePattern
}

function Test-CurrentManagedNotificationHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [string[]]$ManagedHookFingerprints = @())

    $descriptor = Get-CanonicalHookHandlerDescriptor -EventName 'Unknown' -Entry $Entry
    return (Test-HookFingerprint -Entry $Entry -Fingerprints $ManagedHookFingerprints) -or ($null -ne $descriptor -and [string]$descriptor.kind -eq 'notification') -or (Get-HookEntryText -Entry $Entry) -match $script:ManagedNotificationHookSignaturePattern
}

function Test-LegacyManagedNotificationHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $text = Get-HookEntryText -Entry $Entry
    if ($text -match $script:ManagedNotificationHookSignaturePattern) { return $false }
    if ($text -match $script:LegacyNotificationHookSignaturePattern) { return $true }

    $hasNativeNotifier = $text -match '(?i)(ToastNotificationManager|ToastNotification|BurntToast|NotifyIcon|ShowBalloonTip)'
    $hasCodexSettingsOwnership = $text -match '(?i)(codex-settings|codexsettings)'
    $hasCodexHookPath = $text -match '(?i)(\.codex[\\/]+hooks[\\/]+|Join-Path\s+\$HOME)'
    $hasKnownNotificationText = $text -match '(?i)(CodexSettings|Codex 任務|工作已完成|請回到 Codex|等待(?:權限|回答))'
    $hasManagedScriptName = $text -match '(?i)(show[-_]?(?:codex|windows|win32|toast|balloon)[-_]?(?:notification|notify|toast|completion|completed)|(?:codex|windows|win32|toast|balloon|completion|completed)[-_]?(?:notification|notify|toast|completion|completed)|notify[-_]?codex)\.ps1'
    return $hasNativeNotifier -and ($hasCodexSettingsOwnership -or $hasKnownNotificationText -or ($hasCodexHookPath -and $hasManagedScriptName))
}

function Test-ManagedNotificationHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [string[]]$ManagedHookFingerprints = @())

    return (Test-CurrentManagedNotificationHookEntry -Entry $Entry -ManagedHookFingerprints $ManagedHookFingerprints) -or (Test-LegacyManagedNotificationHookEntry -Entry $Entry)
}

function Test-ManagedTokenHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [string[]]$ManagedHookFingerprints = @())

    $text = Get-HookEntryText -Entry $Entry
    $descriptor = Get-CanonicalHookHandlerDescriptor -EventName 'Unknown' -Entry $Entry
    return (Test-HookFingerprint -Entry $Entry -Fingerprints $ManagedHookFingerprints) -or ($null -ne $descriptor -and [string]$descriptor.kind -eq 'token') -or $text -match $script:ManagedTokenHookSignaturePattern -or $text -match $script:LegacyTokenHookSignaturePattern
}

function Test-ManagedGlobalHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [string[]]$ManagedHookFingerprints = @())

    return (Test-HookFingerprint -Entry $Entry -Fingerprints $ManagedHookFingerprints) -or (Test-ManagedNotificationHookEntry -Entry $Entry) -or (Test-ManagedTokenHookEntry -Entry $Entry)
}

function Get-ManagedHookEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)][string]$SignaturePattern, [scriptblock]$EntryPredicate)

    foreach ($hook in @(Get-HookHandlerEntries -Entry $Entry)) {
        $matched = if ($null -ne $EntryPredicate) { [bool](& $EntryPredicate $hook) } else { (Get-HookEntryText -Entry $hook) -match $SignaturePattern }
        if ($matched) { Write-Output $hook }
    }
}

function Remove-HookEntriesJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$SignaturePattern,
        [switch]$ManagedGlobal,
        [switch]$ManagedNotification,
        [string[]]$ManagedHookFingerprints = @()
    )

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }
    $object = $Content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $object.hooks) { return $Content }
    foreach ($property in @($object.hooks.PSObject.Properties)) {
        $keptGroups = New-Object 'System.Collections.Generic.List[object]'
        foreach ($group in @($property.Value)) {
            $hookProperty = $group.PSObject.Properties['hooks']
            if ($null -ne $hookProperty) {
                $keptHooks = New-Object 'System.Collections.Generic.List[object]'
                foreach ($hook in @($hookProperty.Value)) {
                    $remove = if ($ManagedGlobal) {
                        Test-ManagedGlobalHookEntry -Entry $hook -ManagedHookFingerprints $ManagedHookFingerprints
                    } elseif ($ManagedNotification) {
                        Test-ManagedNotificationHookEntry -Entry $hook -ManagedHookFingerprints $ManagedHookFingerprints
                    } else {
                        (Get-HookEntryText -Entry $hook) -match $SignaturePattern
                    }
                    if (-not $remove) { [void]$keptHooks.Add($hook) }
                }
                if ($keptHooks.Count -gt 0) {
                    $group | Add-Member -NotePropertyName hooks -NotePropertyValue $keptHooks.ToArray() -Force
                    [void]$keptGroups.Add($group)
                }
            } elseif (-not (if ($ManagedGlobal) { Test-ManagedGlobalHookEntry -Entry $group -ManagedHookFingerprints $ManagedHookFingerprints } elseif ($ManagedNotification) { Test-ManagedNotificationHookEntry -Entry $group -ManagedHookFingerprints $ManagedHookFingerprints } else { (Get-HookEntryText -Entry $group) -match $SignaturePattern })) {
                [void]$keptGroups.Add($group)
            }
        }
        if ($keptGroups.Count -eq 0) { $object.hooks.PSObject.Properties.Remove($property.Name) }
        else { $object.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $keptGroups.ToArray() -Force }
    }
    return ($object | ConvertTo-Json -Depth 30)
}

function Remove-ManagedHookEntriesJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$SignaturePattern
    )

    return Remove-HookEntriesJson -Content $Content -SignaturePattern $SignaturePattern
}

function Remove-ManagedNotificationHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content, [string[]]$ManagedHookFingerprints = @())

    return Remove-HookEntriesJson -Content $Content -SignaturePattern $script:ManagedNotificationHookSignaturePattern -ManagedNotification -ManagedHookFingerprints $ManagedHookFingerprints
}

function Remove-ManagedGlobalHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content, [string[]]$ManagedHookFingerprints = @())

    return Remove-HookEntriesJson -Content $Content -SignaturePattern $script:ManagedGlobalHookSignaturePattern -ManagedGlobal -ManagedHookFingerprints $ManagedHookFingerprints
}

function Remove-ManagedLineEndingHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    return Remove-ManagedHookEntriesJson -Content $Content -SignaturePattern $script:ManagedLineEndingHookSignaturePattern
}

function Get-ManifestManagedHookFingerprints {
    [CmdletBinding()]
    param($Manifest, [ValidateSet('All', 'Notification', 'Token', 'LineEnding')][string]$Kind = 'All')

    $fingerprints = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Manifest -or $null -eq $Manifest.ManagedHooks) { return $fingerprints.ToArray() }
    $containers = New-Object 'System.Collections.Generic.List[object]'
    if ($Kind -eq 'All') {
        [void]$containers.Add($Manifest.ManagedHooks)
        foreach ($name in @('notification', 'token', 'lineEnding')) {
            $property = $Manifest.ManagedHooks.PSObject.Properties[$name]
            if ($null -ne $property) { [void]$containers.Add($property.Value) }
        }
    } else {
        $propertyName = $Kind.Substring(0, 1).ToLowerInvariant() + $Kind.Substring(1)
        $property = $Manifest.ManagedHooks.PSObject.Properties[$propertyName]
        if ($null -ne $property) { [void]$containers.Add($property.Value) }
    }
    foreach ($container in $containers.ToArray()) {
        $handlerProperty = $container.PSObject.Properties['handlers']
        if ($null -eq $handlerProperty) { continue }
        foreach ($handler in @($handlerProperty.Value)) {
            $fingerprint = [string]$handler.fingerprint
            if (-not [string]::IsNullOrWhiteSpace($fingerprint) -and -not $fingerprints.Contains($fingerprint)) { [void]$fingerprints.Add($fingerprint) }
        }
    }
    return $fingerprints.ToArray()
}

function Get-ManagedHookHandlerId([string]$EventName, $Entry) {
    $descriptor = Get-CanonicalHookHandlerDescriptor -EventName $EventName -Entry $Entry
    if ($null -ne $descriptor) { return [string]$descriptor.handlerId }
    if (Test-ManagedNotificationHookEntry -Entry $Entry) {
        switch ($EventName) {
            'PreToolUse' { return 'question-toast' }
            'PermissionRequest' { return 'permission-toast' }
            'Stop' { return 'completed-token-toast' }
            default { return 'notification-toast' }
        }
    }
    if (Test-ManagedTokenHookEntry -Entry $Entry) { return 'legacy-token-usage' }
    if (Test-ManagedLineEndingHookEntry -Entry $Entry) { return 'line-ending-' + $EventName.ToLowerInvariant() }
    return $null
}

function Get-ManagedHooksManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $handlers = New-Object 'System.Collections.Generic.List[object]'
    $notificationHandlers = New-Object 'System.Collections.Generic.List[object]'
    $tokenHandlers = New-Object 'System.Collections.Generic.List[object]'
    $lineEndingHandlers = New-Object 'System.Collections.Generic.List[object]'
    $hooksPath = Join-Path $Root 'hooks.json'
    if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
        $hooksObject = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $hooksObject.hooks) {
            foreach ($property in @($hooksObject.hooks.PSObject.Properties)) {
                foreach ($group in @($property.Value)) {
                    foreach ($entry in @(Get-HookHandlerEntries -Entry $group)) {
                        $handlerId = Get-ManagedHookHandlerId -EventName $property.Name -Entry $entry
                        if ([string]::IsNullOrWhiteSpace($handlerId)) { continue }
                        $managedId = if ($handlerId -eq 'completed-token-toast' -or $handlerId -match 'toast') { $script:ManagedNotificationId } else { $script:ManagedHookManifestId }
                        $managedVersion = if ($managedId -eq $script:ManagedNotificationId) { $script:ManagedNotificationVersion } else { $script:ManagedHookManifestVersion }
                        $descriptor = Get-CanonicalHookHandlerDescriptor -EventName $property.Name -Entry $entry
                        $record = [ordered]@{ event = $property.Name; handlerId = $handlerId; managedId = $managedId; managedVersion = $managedVersion; fingerprint = Get-HookEntryFingerprint -Entry $entry; descriptor = $descriptor }
                        [void]$handlers.Add([pscustomobject]$record)
                        if ($handlerId -match 'toast') { [void]$notificationHandlers.Add([pscustomobject]$record) }
                        elseif ($handlerId -eq 'legacy-token-usage') { [void]$tokenHandlers.Add([pscustomobject]$record) }
                        else { [void]$lineEndingHandlers.Add([pscustomobject]$record) }
                    }
                }
            }
        }
    }
    return [ordered]@{
        managedId = $script:ManagedHookManifestId
        managedVersion = $script:ManagedHookManifestVersion
        handlers = $handlers.ToArray()
        notification = [ordered]@{ managedId = $script:ManagedNotificationId; managedVersion = $script:ManagedNotificationVersion; handlers = $notificationHandlers.ToArray() }
        token = [ordered]@{ handlers = $tokenHandlers.ToArray() }
        lineEnding = [ordered]@{ handlers = $lineEndingHandlers.ToArray() }
    }
}

function Merge-HooksJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TemplateContent,
        [switch]$RemoveManagedGlobalHooks,
        [string[]]$ManagedHookFingerprints = @()
    )

    $existing = if ([string]::IsNullOrWhiteSpace($ExistingContent)) { [pscustomobject]@{ hooks = [pscustomobject]@{} } } else { $ExistingContent | ConvertFrom-Json -ErrorAction Stop }
    if ($null -eq $existing.hooks) { $existing | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
    if ($RemoveManagedGlobalHooks) {
        $existing = (Remove-ManagedGlobalHooksJson -Content ($existing | ConvertTo-Json -Depth 30) -ManagedHookFingerprints $ManagedHookFingerprints) | ConvertFrom-Json -ErrorAction Stop
    }
    $template = $TemplateContent | ConvertFrom-Json -ErrorAction Stop
    foreach ($property in @($template.hooks.PSObject.Properties)) {
        $current = if ($existing.hooks.PSObject.Properties.Name -contains $property.Name) { @($existing.hooks.PSObject.Properties[$property.Name].Value) } else { @() }
        $existing.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue (@($current) + @($property.Value)) -Force
    }
    return ($existing | ConvertTo-Json -Depth 30)
}
