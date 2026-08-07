$script:ManagedLineEndingHookSignaturePattern = '(?i)((?:crlf-updated-files|normalize-cvs-crlf|preserve-line-endings)\.ps1|Converting updated files? to CRLF|Normalizing updated files to CRLF|Finalizing CRLF normalization|CodexSettings CRLF (?:track|finalize)|Restoring original line endings)'
$script:PreserveLineEndingHookSignaturePattern = '(?i)(preserve-line-endings\.ps1|Restoring original line endings)'
$script:LegacyCrlfHookSignaturePattern = '(?i)((?:crlf-updated-files|normalize-cvs-crlf)\.ps1|Converting updated files? to CRLF|Normalizing updated files to CRLF|Finalizing CRLF normalization|CodexSettings CRLF (?:track|finalize))'
$script:ManagedNotificationHookSignaturePattern = '(?i)(show-codex-notification\.ps1|CodexSettings Windows notification)'
$script:ManagedTokenHookSignaturePattern = '(?i)(show-turn-token-usage\.ps1|turn-token-usage|CodexSettings turn token usage)'
$script:ManagedGlobalHookSignaturePattern = '(?i)(show-codex-notification\.ps1|CodexSettings Windows notification|show-turn-token-usage\.ps1|turn-token-usage|CodexSettings turn token usage)'

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

function Get-ManagedHookEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)][string]$SignaturePattern)

    $hookProperty = $Entry.PSObject.Properties['hooks']
    if ($null -ne $hookProperty) {
        return @($hookProperty.Value | Where-Object { (($_ | ConvertTo-Json -Depth 20 -Compress) -match $SignaturePattern) })
    }
    if (($Entry | ConvertTo-Json -Depth 20 -Compress) -match $SignaturePattern) { return @($Entry) }
    return @()
}

function Remove-ManagedHookEntriesJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$SignaturePattern
    )

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }
    $object = $Content | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $object.hooks) { return $Content }
    foreach ($property in @($object.hooks.PSObject.Properties)) {
        $keptGroups = New-Object 'System.Collections.Generic.List[object]'
        foreach ($group in @($property.Value)) {
            $hookProperty = $group.PSObject.Properties['hooks']
            if ($null -ne $hookProperty) {
                $keptHooks = @($hookProperty.Value | Where-Object { (($_ | ConvertTo-Json -Depth 20 -Compress) -notmatch $SignaturePattern) })
                if ($keptHooks.Count -gt 0) {
                    $group | Add-Member -NotePropertyName hooks -NotePropertyValue $keptHooks -Force
                    [void]$keptGroups.Add($group)
                }
            } elseif (($group | ConvertTo-Json -Depth 20 -Compress) -notmatch $SignaturePattern) {
                [void]$keptGroups.Add($group)
            }
        }
        if ($keptGroups.Count -eq 0) { $object.hooks.PSObject.Properties.Remove($property.Name) }
        else { $object.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue $keptGroups.ToArray() -Force }
    }
    return ($object | ConvertTo-Json -Depth 30)
}

function Remove-ManagedNotificationHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    return Remove-ManagedHookEntriesJson -Content $Content -SignaturePattern $script:ManagedNotificationHookSignaturePattern
}

function Remove-ManagedLineEndingHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    return Remove-ManagedHookEntriesJson -Content $Content -SignaturePattern $script:ManagedLineEndingHookSignaturePattern
}

function Remove-ManagedGlobalHooksJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    return Remove-ManagedHookEntriesJson -Content $Content -SignaturePattern $script:ManagedGlobalHookSignaturePattern
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
        $existing = (Remove-ManagedGlobalHooksJson -Content ($existing | ConvertTo-Json -Depth 30)) | ConvertFrom-Json -ErrorAction Stop
    }
    $template = $TemplateContent | ConvertFrom-Json -ErrorAction Stop
    foreach ($property in @($template.hooks.PSObject.Properties)) {
        $current = if ($existing.hooks.PSObject.Properties.Name -contains $property.Name) { @($existing.hooks.PSObject.Properties[$property.Name].Value) } else { @() }
        $existing.hooks | Add-Member -NotePropertyName $property.Name -NotePropertyValue (@($current) + @($property.Value)) -Force
    }
    return ($existing | ConvertTo-Json -Depth 30)
}
