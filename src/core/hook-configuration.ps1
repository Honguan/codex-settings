$script:ManagedLineEndingHookSignaturePattern = '(?i)((?:crlf-updated-files|normalize-cvs-crlf|preserve-line-endings)\.ps1|Converting updated files? to CRLF|Normalizing updated files to CRLF|Finalizing CRLF normalization|CodexSettings CRLF (?:track|finalize)|Restoring original line endings)'
$script:PreserveLineEndingHookSignaturePattern = '(?i)(preserve-line-endings\.ps1|Restoring original line endings)'
$script:LegacyCrlfHookSignaturePattern = '(?i)((?:crlf-updated-files|normalize-cvs-crlf)\.ps1|Converting updated files? to CRLF|Normalizing updated files to CRLF|Finalizing CRLF normalization|CodexSettings CRLF (?:track|finalize))'
$script:ManagedNotificationHookSignaturePattern = '(?i)(show-codex-notification\.ps1|CodexSettings Windows notification)'
$script:ManagedTokenUsageHookSignaturePattern = '(?i)(show-turn-token-usage\.ps1|CodexSettings turn token usage)'
$script:ManagedGlobalHookSignaturePattern = '(?i)(show-(?:codex-notification|turn-token-usage)\.ps1|CodexSettings (?:Windows notification|turn token usage))'

function Test-ManagedLineEndingHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    return (($Entry | ConvertTo-Json -Depth 20 -Compress) -match $script:ManagedLineEndingHookSignaturePattern)
}

function Test-ManagedGlobalHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    return (($Entry | ConvertTo-Json -Depth 20 -Compress) -match $script:ManagedGlobalHookSignaturePattern)
}

function Test-ManagedNotificationHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    return (($Entry | ConvertTo-Json -Depth 20 -Compress) -match $script:ManagedNotificationHookSignaturePattern)
}

function Remove-ManagedNotificationHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }
    $object = $Content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $object.hooks) { return $Content }
    foreach ($property in @($object.hooks.PSObject.Properties)) {
        $filtered = @($property.Value | Where-Object { -not (Test-ManagedNotificationHookEntry $_) })
        if ($filtered.Count -eq 0) { $object.hooks.PSObject.Properties.Remove($property.Name) }
        else { $object.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $filtered -Force }
    }
    return ($object | ConvertTo-Json -Depth 30)
}

function Test-ManagedTokenUsageHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    return (($Entry | ConvertTo-Json -Depth 20 -Compress) -match $script:ManagedTokenUsageHookSignaturePattern)
}

function Remove-ManagedTokenUsageHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }
    $object = $Content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $object.hooks) { return $Content }
    foreach ($property in @($object.hooks.PSObject.Properties)) {
        $filtered = @($property.Value | Where-Object { -not (Test-ManagedTokenUsageHookEntry $_) })
        if ($filtered.Count -eq 0) { $object.hooks.PSObject.Properties.Remove($property.Name) }
        else { $object.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $filtered -Force }
    }
    return ($object | ConvertTo-Json -Depth 30)
}

function Remove-ManagedLineEndingHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }
    $object = $Content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $object.hooks) { return $Content }
    foreach ($property in @($object.hooks.PSObject.Properties)) {
        $filtered = @($property.Value | Where-Object { -not (Test-ManagedLineEndingHookEntry $_) })
        if ($filtered.Count -eq 0) {
            $object.hooks.PSObject.Properties.Remove($property.Name)
        } else {
            $object.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $filtered -Force
        }
    }
    return ($object | ConvertTo-Json -Depth 30)
}

function Merge-LineEndingHooksJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TemplateContent
    )

    $cleaned = Remove-ManagedLineEndingHooksJson -Content $ExistingContent
    $existing = if ([string]::IsNullOrWhiteSpace($cleaned)) { [pscustomobject]@{ hooks = [pscustomobject]@{} } } else { $cleaned | ConvertFrom-Json -ErrorAction Stop }
    if ($null -eq $existing.hooks) { $existing | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
    $template = $TemplateContent | ConvertFrom-Json -ErrorAction Stop
    foreach ($property in @($template.hooks.PSObject.Properties)) {
        $current = if ($existing.hooks.PSObject.Properties.Name -contains $property.Name) { @($existing.hooks.PSObject.Properties[$property.Name].Value) } else { @() }
        $existing.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue (@($current) + @($property.Value)) -Force
    }
    return ($existing | ConvertTo-Json -Depth 30)
}

function Merge-HooksJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TemplateContent,
        [switch]$RemoveManagedGlobalHooks
    )

    $existing = if ([string]::IsNullOrWhiteSpace($ExistingContent)) { [pscustomobject]@{ hooks = [pscustomobject]@{} } } else { $ExistingContent | ConvertFrom-Json -ErrorAction Stop }
    if ($null -eq $existing.hooks) { $existing | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
    if ($RemoveManagedGlobalHooks) {
        foreach ($property in @($existing.hooks.PSObject.Properties)) {
            $filtered = @($property.Value | Where-Object { -not (Test-ManagedGlobalHookEntry $_) })
            if ($filtered.Count -eq 0) { $existing.hooks.PSObject.Properties.Remove($property.Name) }
            else { $existing.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $filtered -Force }
        }
    }
    $template = $TemplateContent | ConvertFrom-Json -ErrorAction Stop
    foreach ($property in @($template.hooks.PSObject.Properties)) {
        $current = if ($existing.hooks.PSObject.Properties.Name -contains $property.Name) { @($existing.hooks.PSObject.Properties[$property.Name].Value) } else { @() }
        $existing.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue (@($current) + @($property.Value)) -Force
    }
    return ($existing | ConvertTo-Json -Depth 30)
}
