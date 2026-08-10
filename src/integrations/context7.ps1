function Get-Context7McpTransportState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $sectionPattern = '(?ms)^[ \t]*\[mcp_servers\.context7\][^\S\r\n]*(?:#[^\r\n]*)?(?:\r?\n|$).*?(?=^[ \t]*\[[^\]]+\][^\S\r\n]*(?:#[^\r\n]*)?(?:\r?\n|$)|\z)'
    $sections = [regex]::Matches($Content, $sectionPattern)
    if ($sections.Count -eq 0) {
        return [pscustomobject][ordered]@{ State = 'NotConfigured'; Ownership = 'None'; TransportDetected = 'None'; Section = $null; HasUrl = $false; HasCommand = $false; HasArgs = $false; HasEnvHttpHeaders = $false; HasStdioEnvironmentFields = $false; MigrationRequired = $false; RepairRequired = $false; ValidationReason = '' }
    }

    $section = $sections[0].Value
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $duplicateKeys = New-Object 'System.Collections.Generic.List[string]'
    $assignments = [regex]::Matches($section, '(?m)^[ \t]*([A-Za-z0-9_.-]+)[ \t]*=.*(?:\r?\n|$)')
    foreach ($match in $assignments) {
        $key = $match.Groups[1].Value
        if (-not $keys.Add($key)) { [void]$duplicateKeys.Add($key) }
    }
    $replaceLength = if ($assignments.Count -gt 0) { $assignments[$assignments.Count - 1].Index + $assignments[$assignments.Count - 1].Length } else { $section.Length }
    $replaceSection = [pscustomobject]@{ Index = $sections[0].Index; Length = $replaceLength; Value = $section.Substring(0, $replaceLength) }
    $stdioKeys = @('command', 'args', 'env', 'env_vars', 'cwd', 'experimental_environment')
    $httpKeys = @('url', 'bearer_token_env_var', 'http_headers', 'env_http_headers')
    $canonicalKeys = @('url', 'enabled', 'startup_timeout_sec', 'tool_timeout_sec', 'env_http_headers')
    $knownKeys = @($stdioKeys + $httpKeys + @('enabled', 'startup_timeout_sec', 'tool_timeout_sec'))
    $hasCommand = $keys.Contains('command')
    $hasArgs = $keys.Contains('args')
    $hasUrl = $keys.Contains('url')
    $hasEnvHttpHeaders = $keys.Contains('env_http_headers')
    $hasStdioEnvironment = @($stdioKeys | Where-Object { $_ -notin @('command', 'args') -and $keys.Contains($_) }).Count -gt 0
    $hasStdio = @($stdioKeys | Where-Object { $keys.Contains($_) }).Count -gt 0
    $hasHttp = @($httpKeys | Where-Object { $keys.Contains($_) }).Count -gt 0
    $hasCustomHttpAuthentication = $keys.Contains('bearer_token_env_var') -or $keys.Contains('http_headers')
    $unknownKeys = @($keys | Where-Object { $_ -notin $knownKeys })
    $knownUrl = $section -match '(?m)^[ \t]*url[ \t]*=[ \t]*["'']https://mcp\.context7\.com/mcp["''][ \t]*(?:#.*)?\r?$'
    $knownCommand = $section -match '(?m)^[ \t]*command[ \t]*=[ \t]*["'']npx(?:\.cmd)?["''][ \t]*(?:#.*)?\r?$'
    $knownPackage = $section -match '(?m)^[ \t]*args[ \t]*=.*["'']@upstash/context7-mcp(?:@[^"'']+)?["'']'
    $canonical = $knownUrl -and $section -match '(?m)^[ \t]*enabled[ \t]*=[ \t]*true[ \t]*(?:#.*)?\r?$' -and $section -match '(?m)^[ \t]*startup_timeout_sec[ \t]*=[ \t]*20[ \t]*(?:#.*)?\r?$' -and $section -match '(?m)^[ \t]*tool_timeout_sec[ \t]*=[ \t]*60[ \t]*(?:#.*)?\r?$' -and $section -match '(?m)^[ \t]*env_http_headers[ \t]*=[ \t]*\{[ \t]*["'']CONTEXT7_API_KEY["''][ \t]*=[ \t]*["'']CONTEXT7_API_KEY["''][ \t]*\}[ \t]*(?:#.*)?\r?$' -and $keys.Count -eq $canonicalKeys.Count
    $knownManaged = $unknownKeys.Count -eq 0 -and -not $hasCustomHttpAuthentication -and (($knownCommand -and $knownPackage) -or $knownUrl)
    $mixed = $hasStdio -and $hasHttp
    $transport = if ($mixed) { 'Mixed' } elseif ($hasStdio) { 'Stdio' } elseif ($hasHttp) { 'Http' } else { 'None' }
    $state = if ($sections.Count -gt 1 -or $duplicateKeys.Count -gt 0) {
        'Unknown'
    } elseif ($mixed -and $knownManaged) {
        'MixedInvalidTransport'
    } elseif ($mixed) {
        'UserOwnedConflict'
    } elseif ($hasStdio -and $knownCommand -and $knownPackage -and $unknownKeys.Count -eq 0) {
        'LegacyStdio'
    } elseif ($hasStdio) {
        'UserOwnedConflict'
    } elseif ($hasHttp -and $canonical) {
        'CurrentRemoteHttp'
    } elseif ($hasHttp -and $knownUrl -and $unknownKeys.Count -eq 0 -and -not $hasCustomHttpAuthentication) {
        'RemoteNeedsUpdate'
    } elseif ($hasHttp) {
        'UserOwnedConflict'
    } else {
        'Unknown'
    }

    return [pscustomobject][ordered]@{
        State = $state
        Ownership = if ($knownManaged) { 'KnownContext7' } elseif ($state -eq 'NotConfigured') { 'None' } else { 'UserOwnedOrUnknown' }
        TransportDetected = $transport
        Section = $replaceSection
        HasUrl = $hasUrl
        HasCommand = $hasCommand
        HasArgs = $hasArgs
        HasEnvHttpHeaders = $hasEnvHttpHeaders
        HasStdioEnvironmentFields = $hasStdioEnvironment
        MigrationRequired = $state -in @('LegacyStdio', 'RemoteNeedsUpdate')
        RepairRequired = $state -eq 'MixedInvalidTransport'
        ValidationReason = if ($mixed) { 'url-is-not-supported-for-stdio' } elseif ($sections.Count -gt 1) { 'duplicate-context7-sections' } elseif ($duplicateKeys.Count -gt 0) { 'duplicate-context7-keys' } else { '' }
    }
}

function Format-Context7McpDiagnostic($State) {
    return "context7State=$($State.State) context7Ownership=$($State.Ownership) transportDetected=$($State.TransportDetected) hasUrl=$($State.HasUrl) hasCommand=$($State.HasCommand) hasArgs=$($State.HasArgs) hasEnvHttpHeaders=$($State.HasEnvHttpHeaders) hasStdioEnvironmentFields=$($State.HasStdioEnvironmentFields) migrationRequired=$($State.MigrationRequired) repairRequired=$($State.RepairRequired) validationReason=$($State.ValidationReason)"
}

function Merge-Context7McpTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExistingContent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TemplateContent,
        [Parameter(Mandatory = $true)][string]$StartMarker,
        [Parameter(Mandatory = $true)][string]$EndMarker,
        [string]$NewLine = "`r`n"
    )

    $state = Get-Context7McpTransportState -Content $ExistingContent
    if ($state.State -eq 'Unknown' -or ($state.State -eq 'UserOwnedConflict' -and $state.TransportDetected -eq 'Mixed')) {
        throw "Context7 MCP transport conflict: $(Format-Context7McpDiagnostic $state)"
    }

    $base = $ExistingContent
    if ($state.State -in @('LegacyStdio', 'MixedInvalidTransport', 'RemoteNeedsUpdate')) {
        $templateState = Get-Context7McpTransportState -Content $TemplateContent
        if ($templateState.State -ne 'CurrentRemoteHttp') { throw 'Built-in Context7 MCP template is not canonical HTTP configuration.' }
        $base = $base.Remove($state.Section.Index, $state.Section.Length).Insert($state.Section.Index, $templateState.Section.Value.TrimEnd("`r", "`n") + $NewLine)
        Write-Verbose (Format-Context7McpDiagnostic $state)
    }

    $result = Merge-TomlTemplate -ExistingContent $base -TemplateContent $TemplateContent -StartMarker $StartMarker -EndMarker $EndMarker -NewLine $NewLine
    $finalState = Get-Context7McpTransportState -Content $result
    if ($finalState.TransportDetected -eq 'Mixed') { throw "Context7 MCP reconciliation failed: $(Format-Context7McpDiagnostic $finalState)" }
    return $result
}

function Set-Context7EnvironmentState {
    [CmdletBinding()]
    param([switch]$Skip, $PreviousManifest)

    $name = 'CONTEXT7_API_KEY'
    $userBefore = [Environment]::GetEnvironmentVariable($name, 'User')
    $processBefore = [Environment]::GetEnvironmentVariable($name, 'Process')
    $createdNow = $false

    if ([string]::IsNullOrWhiteSpace($userBefore) -and -not $Skip) {
        Write-Host ''
        Write-Host 'Context7 API Key 為選填；設定後可提高使用額度。'
        $secure = Read-Host '輸入 Context7 API Key，或直接按 Enter 略過' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if (-not [string]::IsNullOrWhiteSpace($plain)) {
            [Environment]::SetEnvironmentVariable($name, $plain, 'User')
            [Environment]::SetEnvironmentVariable($name, $plain, 'Process')
            $createdNow = $true
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($userBefore)) {
        [Environment]::SetEnvironmentVariable($name, $userBefore, 'Process')
        Write-Host '使用既有的 CONTEXT7_API_KEY。'
    }

    $managedBefore = $false
    if ($null -ne $PreviousManifest -and $null -ne $PreviousManifest.External -and $null -ne $PreviousManifest.External.Context7) {
        $managedBefore = [bool]$PreviousManifest.External.Context7.CreatedByInstaller
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        CreatedNow = $createdNow
        CreatedByInstaller = $managedBefore -or $createdNow
        UserBefore = $userBefore
        ProcessBefore = $processBefore
    }
}
