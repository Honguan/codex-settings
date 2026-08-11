$script:ManagedHookManifestId = 'codex-settings'
$script:ManagedHookManifestVersion = 3
$script:ManagedNotificationId = 'codex-settings-notification'
$script:ManagedNotificationVersion = 6
$script:WindowsNotificationConfigStartMarker = '# >>> CODEX-SETTINGS:WINDOWS-NOTIFICATIONS:CONFIG >>>'
$script:WindowsNotificationConfigEndMarker = '# <<< CODEX-SETTINGS:WINDOWS-NOTIFICATIONS:CONFIG <<<'
$script:ManagedLineEndingHookSignaturePattern = '(?i)((?:mixed-line-ending-hook|crlf-updated-files|normalize-cvs-crlf|preserve-line-endings)\.ps1|Converting updated files? to CRLF|Normalizing updated files to CRLF|Finalizing CRLF normalization|CodexSettings CRLF (?:track|finalize)|Restoring original line endings)'
$script:PreserveLineEndingHookSignaturePattern = '(?i)(preserve-line-endings\.ps1|Restoring original line endings)'
$script:LegacyCrlfHookSignaturePattern = '(?i)((?:crlf-updated-files|normalize-cvs-crlf)\.ps1|Converting updated files? to CRLF|Normalizing updated files to CRLF|Finalizing CRLF normalization|CodexSettings CRLF (?:track|finalize))'
$script:ManagedNotificationHookSignaturePattern = '(?i)(show-codex-notification\.ps1|CodexSettings Windows notification)'
$script:ManagedTokenHookSignaturePattern = '(?i)(show-turn-token-usage\.ps1|turn-token-usage|CodexSettings turn token usage)'
$script:ManagedGlobalHookSignaturePattern = '(?i)(show-codex-notification\.ps1|CodexSettings Windows notification|show-turn-token-usage\.ps1|turn-token-usage|CodexSettings turn token usage)'
$script:LegacyNotificationHookSignaturePattern = '(?i)(show[-_]?(?:codex|windows|win32|toast|balloon)[-_]?(?:notification|notify|toast|completion|completed)\.ps1|(?:codex|windows|win32|toast|balloon|completion|completed)[-_]?(?:notification|notify|toast|completion|completed)\.ps1|notify[-_]?codex\.ps1|CodexSettings Windows notification|Codex 任務完成|工作已完成|請回到 Codex)'
$script:LegacyTokenHookSignaturePattern = '(?i)(show[-_]?(?:turn[-_]?)?token[-_]?usage\.ps1|turn[-_]?token[-_]?usage|CodexSettings turn token usage)'

function Get-WindowsNotificationCommandConfig([string]$Root, [string]$PreviousNotifyLine = '') {
    $scriptPath = (Join-Path $Root 'hooks\show-codex-notification.ps1').Replace('\', '\\').Replace('"', '\"')
    $previous = if ([string]::IsNullOrWhiteSpace($PreviousNotifyLine)) { '' } else { ', "-PreviousNotifyBase64", "' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PreviousNotifyLine)) + '"' }
    return 'notify = ["pwsh.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "' + $scriptPath + '", "-Type", "Completed"' + $previous + ']'
}

function Get-PreviousWindowsNotificationCommandLine([string]$Content) {
    $match = [regex]::Match($Content, '"-PreviousNotifyBase64"\s*,\s*"(?<value>[A-Za-z0-9+/=]+)"')
    if (-not $match.Success) { return '' }
    try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups['value'].Value)) } catch { return '' }
}

function Remove-WindowsNotificationCommandConfig([string]$Content, [switch]$RestorePrevious) {
    $previous = if ($RestorePrevious) { Get-PreviousWindowsNotificationCommandLine -Content $Content } else { '' }
    $base = Remove-ManagedBlock -Content $Content -StartMarker $script:WindowsNotificationConfigStartMarker -EndMarker $script:WindowsNotificationConfigEndMarker
    if ([string]::IsNullOrWhiteSpace($previous)) { return $base }
    $newLine = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ([string]::IsNullOrWhiteSpace($base)) { return $previous + $newLine }
    return $previous + $newLine + $newLine + $base.TrimStart()
}

function Merge-WindowsNotificationCommandConfig([string]$Content, [string]$Root, [string]$NewLine = "`r`n") {
    $chainedNotify = Get-PreviousWindowsNotificationCommandLine -Content $Content
    $base = Remove-WindowsNotificationCommandConfig -Content $Content
    $shape = Get-TomlShape -Content $base
    $previousNotify = if ($shape.TopLevelKeys.Contains('notify')) { Get-WindowsNotificationCommandLine -Content $base } else { $chainedNotify }
    if ($shape.TopLevelKeys.Contains('notify') -and [string]::IsNullOrWhiteSpace($previousNotify)) { throw 'config.toml 已有無法安全串接的 notify；無法安裝 Windows 完成通知。' }
    if (-not [string]::IsNullOrWhiteSpace($previousNotify)) { $base = [regex]::Replace($base, '(?m)^' + [regex]::Escape($previousNotify) + '\r?\n?', '', 1) }
    $block = $script:WindowsNotificationConfigStartMarker + $NewLine + (Get-WindowsNotificationCommandConfig -Root $Root -PreviousNotifyLine $previousNotify) + $NewLine + $script:WindowsNotificationConfigEndMarker
    if ([string]::IsNullOrWhiteSpace($base)) { return $block + $NewLine }
    return $block + $NewLine + $NewLine + $base.Trim() + $NewLine
}

function Test-WindowsNotificationCommandConfig([string]$Content, [string]$Root) {
    return (Get-WindowsNotificationCommandConfigState -Content $Content -Root $Root) -eq 'CurrentManagedBlock'
}

function Test-TomlDelimiterBalance([string]$Content) {
    $cleaned = [regex]::Replace($Content, '"(?:\\.|[^"\\])*"|''[^'']*''|(?m)#.*$', '')
    foreach ($pair in @(@('[', ']'), @('{', '}'))) {
        $depth = 0
        foreach ($character in $cleaned.ToCharArray()) {
            if ($character -eq $pair[0]) { $depth++ }
            elseif ($character -eq $pair[1] -and --$depth -lt 0) { return $false }
        }
        if ($depth -ne 0) { return $false }
    }
    return $true
}

function Get-WindowsNotificationCommandLine([string]$Content) {
    foreach ($line in ($Content -split '\r?\n')) {
        if ($line.Trim() -match '^\[') { return '' }
        if ($line -match '^\s*notify\s*=\s*\[[^\r\n]*\]\s*(?:#.*)?$') { return $line }
    }
    return ''
}

function Test-KnownWindowsNotificationCommand([string]$Content, [string]$Root) {
    $line = Get-WindowsNotificationCommandLine -Content $Content
    if ([string]::IsNullOrWhiteSpace($line)) { return $false }
    if ($line.Trim() -ceq (Get-WindowsNotificationCommandConfig -Root $Root)) { return $true }
    return $line -match '(?i)pwsh(?:\.exe)?' -and $line -match '(?i)(show-codex-notification|show-windows-notification|notify-codex)\.ps1' -and $line -match '(?i)(-Type"?\s*,?\s*"?Completed|Completed)'
}

function Remove-RepairableWindowsNotificationCommandConfig([string]$Content, [string]$Root) {
    $base = Remove-WindowsNotificationCommandConfig -Content $Content
    $markerPattern = '(?m)^\s*(?:' + [regex]::Escape($script:WindowsNotificationConfigStartMarker) + '|' + [regex]::Escape($script:WindowsNotificationConfigEndMarker) + ')\s*\r?\n?'
    $base = [regex]::Replace($base, $markerPattern, '')
    $ownedNotify = Get-WindowsNotificationCommandLine -Content $base
    if (-not [string]::IsNullOrWhiteSpace($ownedNotify) -and (Test-KnownWindowsNotificationCommand -Content $base -Root $Root)) {
        $base = [regex]::Replace($base, '(?m)^' + [regex]::Escape($ownedNotify) + '\r?\n?', '', 1)
    }
    return $base.TrimEnd()
}

function Get-WindowsNotificationCommandConfigState([string]$Content, [string]$Root) {
    $startCount = [regex]::Matches($Content, '(?m)^\s*' + [regex]::Escape($script:WindowsNotificationConfigStartMarker) + '\s*$').Count
    $endCount = [regex]::Matches($Content, '(?m)^\s*' + [regex]::Escape($script:WindowsNotificationConfigEndMarker) + '\s*$').Count
    $contentWithoutManagedBlocks = Remove-WindowsNotificationCommandConfig -Content $Content
    if (-not (Test-TomlDelimiterBalance -Content $contentWithoutManagedBlocks)) { return 'MalformedUserContent' }
    try { $shape = Get-TomlShape -Content $Content } catch { return 'MalformedManagedBlock' }
    if ($startCount -eq 0 -and $endCount -eq 0) { return $(if ($shape.TopLevelKeys.Contains('notify')) { 'UnmanagedNotifyConflict' } else { 'MissingManagedBlock' }) }
    if ($startCount -ne 1 -or $endCount -ne 1) { return 'MalformedManagedBlock' }
    $pattern = '(?ms)^\s*' + [regex]::Escape($script:WindowsNotificationConfigStartMarker) + '\s*\r?\n(?<block>.*?)^\s*' + [regex]::Escape($script:WindowsNotificationConfigEndMarker) + '\s*$'
    $managed = [regex]::Match($Content, $pattern)
    if (-not $managed.Success) { return 'MalformedManagedBlock' }
    try { $baseShape = Get-TomlShape -Content (Remove-WindowsNotificationCommandConfig -Content $Content) } catch { return 'MalformedManagedBlock' }
    if ($baseShape.TopLevelKeys.Contains('notify')) { return 'UnmanagedNotifyConflict' }
    $notify = [regex]::Match($managed.Groups['block'].Value, '(?m)^\s*notify\s*=\s*\[(?<items>[^\r\n]*)\]\s*$')
    if (-not $notify.Success) { return $(if ($managed.Groups['block'].Value -match '(?m)^\s*notify\s*=') { 'MalformedManagedBlock' } else { 'OutdatedManagedBlock' }) }
    $actual = @([regex]::Matches($notify.Groups['items'].Value, '"(?:\\.|[^"\\])*"') | ForEach-Object Value)
    $expected = [regex]::Match((Get-WindowsNotificationCommandConfig -Root $Root), '\[(?<items>.*)\]')
    $expectedItems = @([regex]::Matches($expected.Groups['items'].Value, '"(?:\\.|[^"\\])*"') | ForEach-Object Value)
    $prefixMatches = $actual.Count -ge $expectedItems.Count -and ($actual[0..($expectedItems.Count - 1)] -join "`0") -ceq ($expectedItems -join "`0")
    $chained = $actual.Count -eq ($expectedItems.Count + 2) -and $actual[$expectedItems.Count] -ceq '"-PreviousNotifyBase64"' -and -not [string]::IsNullOrWhiteSpace((Get-PreviousWindowsNotificationCommandLine -Content $managed.Groups['block'].Value))
    return $(if ($prefixMatches -and ($actual.Count -eq $expectedItems.Count -or $chained)) { 'CurrentManagedBlock' } else { 'OutdatedManagedBlock' })
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
            'Stop' { 'completed-toast' }
            default { 'notification-toast' }
        }
    } elseif (($command + ' ' + $commandWindows) -match '(?i)(?:mixed-line-ending-hook|preserve-line-endings)\.ps1') {
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
            'Stop' { return 'completed-toast' }
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
                        $managedId = if ($handlerId -match 'toast') { $script:ManagedNotificationId } else { $script:ManagedHookManifestId }
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
