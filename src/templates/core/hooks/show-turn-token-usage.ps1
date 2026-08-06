[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-HookOutput($Value) {
    [Console]::Out.Write(($Value | ConvertTo-Json -Depth 8 -Compress))
}

function Get-StateRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT)) {
        return [IO.Path]::GetFullPath($env:CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT)
    }
    return Join-Path $HOME '.codex\state\token-usage'
}

function Get-Settings([string]$Root) {
    $defaults = [ordered]@{
        enabled = $true
        showAfterEachTurn = $true
        showSessionId = $true
        showCost = $true
        showModel = $true
        firstTurnMode = 'session-total'
        mainSessionOnly = $true
    }
    $path = Join-Path $Root 'settings.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        [IO.File]::WriteAllText($path, (($defaults | ConvertTo-Json) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]$defaults
    }
    try {
        $stored = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in $defaults.Keys) {
            if ($stored.PSObject.Properties.Name -notcontains $property) { $stored | Add-Member -NotePropertyName $property -NotePropertyValue $defaults[$property] }
        }
        return $stored
    } catch { return [pscustomobject]$defaults }
}

function Get-SessionStatePath([string]$Root, [string]$SessionId) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $name = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($SessionId)))).Replace('-', '').ToLowerInvariant() + '.json' }
    finally { $sha.Dispose() }
    return Join-Path $Root $name
}

function Invoke-CcSessionsJson([string]$SessionId) {
    $lastError = $null
    foreach ($attempt in 1..2) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND)) {
                $output = & pwsh -NoLogo -NoProfile -File $env:CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND -SessionId $SessionId 2>&1
            } else {
                foreach ($profilePath in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique) {
                    if (Test-Path -LiteralPath $profilePath -PathType Leaf) { . $profilePath *> $null }
                    if (Get-Command ccsessions -ErrorAction SilentlyContinue) { break }
                }
                if (-not (Get-Command ccsessions -ErrorAction SilentlyContinue)) { throw 'ccsessions not found' }
                $output = & ccsessions -Json $SessionId 2>&1
            }
            $text = ($output | Out-String).Trim()
            $start = $text.IndexOf('{')
            $end = $text.LastIndexOf('}')
            if ($start -lt 0 -or $end -le $start) { throw 'ccsessions returned invalid JSON' }
            $result = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json -ErrorAction Stop
            if ($result -is [array]) { $result = @($result | Where-Object { [string]$_.sessionId -eq $SessionId })[0] }
            if ($null -eq $result -or -not [bool]$result.success) { throw $(if ($result.error) { [string]$result.error } else { 'ccsessions returned no matching session' }) }
            if ([string]$result.sessionId -ne $SessionId) { throw 'ccsessions returned a different session' }
            return $result
        } catch {
            $lastError = $_
            if ($_.Exception.Message -match 'ccsessions not found' -or $attempt -eq 2) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
    throw $lastError
}

function Get-UsageValue($Usage, [string[]]$Names, $Default = 0) {
    if ($null -eq $Usage) { return $Default }
    foreach ($name in $Names) {
        $property = $Usage.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $Default
}

function Get-RealtimeUsage($InputObject) {
    $directUsage = Get-UsageValue -Usage $InputObject -Names @('last_token_usage') -Default $null
    if ($null -ne $directUsage) { return $directUsage }

    $transcriptPath = [string](Get-UsageValue -Usage $InputObject -Names @('transcript_path') -Default '')
    if ([string]::IsNullOrWhiteSpace($transcriptPath) -or -not (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) { return $null }
    try {
        $event = Get-Content -LiteralPath $transcriptPath -Tail 512 | ForEach-Object {
            try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        } | Where-Object {
            $_.type -eq 'event_msg' -and $_.payload.type -eq 'token_count' -and $null -ne $_.payload.info.last_token_usage
        } | Select-Object -Last 1
        if ($null -ne $event) { return $event.payload.info.last_token_usage }
    } catch {}
    return $null
}

function ConvertTo-Snapshot($Usage, [string]$SessionId, [string]$Source = 'ccsessions', $Previous = $null) {
    $isRealtime = $Source -eq 'realtime'
    $models = if ($isRealtime -and $null -ne $Previous) { @($Previous.models) } else { @((Get-UsageValue -Usage $Usage -Names @('models') -Default @())) }
    $hasCost = -not $isRealtime
    return [pscustomobject][ordered]@{
        sessionId = $SessionId
        source = $Source
        models = $models
        inputTokens = [long](Get-UsageValue -Usage $Usage -Names @('inputTokens', 'input_tokens'))
        cachedInputTokens = [long](Get-UsageValue -Usage $Usage -Names @('cachedInputTokens', 'cached_input_tokens'))
        cacheWriteTokens = [long](Get-UsageValue -Usage $Usage -Names @('cacheWriteTokens', 'cache_write_input_tokens'))
        outputTokens = [long](Get-UsageValue -Usage $Usage -Names @('outputTokens', 'output_tokens'))
        totalTokens = [long](Get-UsageValue -Usage $Usage -Names @('totalTokens', 'total_tokens'))
        hasCost = $hasCost
        costUsd = if ($hasCost) { [decimal](Get-UsageValue -Usage $Usage -Names @('costUsd', 'cost_usd')) } else { [decimal]0 }
    }
}

function Get-SnapshotHash($Snapshot) {
    $json = $Snapshot | ConvertTo-Json -Depth 6 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-PreviousState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch {
        $backup = "$Path.corrupt-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
        Move-Item -LiteralPath $Path -Destination $backup -Force
        return $null
    }
}

function Save-State([string]$Path, $Snapshot, [string]$Hash, [string]$TurnId) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $value = [ordered]@{
        sessionId = $Snapshot.sessionId
        source = $Snapshot.source
        models = @($Snapshot.models)
        inputTokens = $Snapshot.inputTokens
        cachedInputTokens = $Snapshot.cachedInputTokens
        cacheWriteTokens = $Snapshot.cacheWriteTokens
        outputTokens = $Snapshot.outputTokens
        totalTokens = $Snapshot.totalTokens
        hasCost = $Snapshot.hasCost
        costUsd = $Snapshot.costUsd
        snapshotHash = $Hash
        turnId = $TurnId
        updatedAt = [DateTimeOffset]::Now.ToString('o')
    }
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporaryPath, (($value | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Format-TokenCount([long]$Value, [bool]$Delta) {
    $prefix = if ($Delta) { '+' } else { '' }
    $units = @(
        [pscustomobject]@{ Limit = 1000000000; Divisor = 1000000000; Suffix = 'B' },
        [pscustomobject]@{ Limit = 1000000; Divisor = 1000000; Suffix = 'M' },
        [pscustomobject]@{ Limit = 1000; Divisor = 1000; Suffix = 'K' }
    )
    foreach ($unit in $units) {
        if ([Math]::Abs($Value) -lt $unit.Limit) { continue }
        $scaled = [double]$Value / $unit.Divisor
        $decimals = if ([Math]::Abs($scaled) -ge 100) { 0 } elseif ([Math]::Abs($scaled) -ge 10) { 1 } else { 2 }
        $text = $scaled.ToString("F$decimals", [Globalization.CultureInfo]::InvariantCulture)
        if ($decimals -gt 0) { $text = $text.TrimEnd('0').TrimEnd('.') }
        return $prefix + $text + $unit.Suffix
    }
    return $prefix + $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Format-Cost([decimal]$Value, [bool]$Delta) {
    $prefix = if ($Delta) { '+' } else { '' }
    $text = $Value.ToString('0.0000', [Globalization.CultureInfo]::InvariantCulture).TrimEnd('0').TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($text)) { $text = '0' }
    return $prefix + '$' + $text
}

function Format-SessionId([string]$SessionId) {
    if ($SessionId.Length -le 17) { return $SessionId }
    return $SessionId.Substring(0, 8) + '...' + $SessionId.Substring($SessionId.Length - 6)
}

function Format-Percentage([decimal]$Value) {
    return $Value.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) + '%'
}

$inputObject = $null
$stopwatch = [Diagnostics.Stopwatch]::StartNew()

function Write-HookDiagnostic($HookInput, [string]$Result, [string]$Details) {
    try {
        $root = if ([string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_HOOK_LOG_ROOT)) { Join-Path $HOME '.codex\logs\hooks' } else { $env:CODEX_SETTINGS_HOOK_LOG_ROOT }
        $sessionId = [string](Get-UsageValue -Usage $HookInput -Names @('session_id') -Default 'unknown')
        $safeSessionId = [regex]::Replace($sessionId, '[^A-Za-z0-9._-]', '_')
        $entry = [ordered]@{
            timestamp = [DateTimeOffset]::Now.ToString('o')
            event = 'Stop'
            handler = 'turn-token-usage'
            result = $Result
            sessionId = $sessionId
            turnId = [string](Get-UsageValue -Usage $HookInput -Names @('turn_id') -Default '')
            tool = [string](Get-UsageValue -Usage $HookInput -Names @('tool_name') -Default '')
            changedFileCount = 0
            changedFiles = @()
            elapsedMs = $stopwatch.ElapsedMilliseconds
            details = $Details
        }
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::AppendAllText((Join-Path $root ($safeSessionId + '.log')), (($entry | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    } catch {}
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'session ID could not be resolved' }
    $inputObject = $raw | ConvertFrom-Json -ErrorAction Stop
    $sessionId = [string]$inputObject.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'session ID could not be resolved' }
    $root = Get-StateRoot
    $settings = Get-Settings -Root $root
    if (-not [bool]$settings.enabled -or -not [bool]$settings.showAfterEachTurn) { Write-HookOutput ([pscustomobject]@{}); return }

    $statePath = Get-SessionStatePath -Root $root -SessionId $sessionId
    $previous = Read-PreviousState -Path $statePath
    $realtimeUsage = Get-RealtimeUsage -InputObject $inputObject
    if ($null -ne $realtimeUsage) {
        $current = ConvertTo-Snapshot -Usage $realtimeUsage -SessionId $sessionId -Source 'realtime' -Previous $previous
    } else {
        $usage = Invoke-CcSessionsJson -SessionId $sessionId
        $current = ConvertTo-Snapshot -Usage $usage -SessionId $sessionId -Previous $previous
    }
    $hash = Get-SnapshotHash -Snapshot $current
    if ($null -ne $previous -and [string]$previous.snapshotHash -eq $hash) { Write-HookOutput ([pscustomobject]@{}); return }

    $isRealtime = $current.source -eq 'realtime'
    $isDelta = $false
    if (-not $isRealtime -and $null -ne $previous -and [string]$previous.source -eq 'ccsessions' -and $previous.PSObject.Properties.Name -contains 'cacheWriteTokens') {
        $isDelta = $true
        foreach ($property in @('inputTokens', 'cachedInputTokens', 'cacheWriteTokens', 'outputTokens', 'totalTokens', 'costUsd')) {
            if ([decimal]$current.$property -lt [decimal]$previous.$property) { $isDelta = $false; break }
        }
    }
    $shown = if ($isDelta) {
        [pscustomobject]@{
            inputTokens = [long]$current.inputTokens - [long]$previous.inputTokens
            cachedInputTokens = [long]$current.cachedInputTokens - [long]$previous.cachedInputTokens
            cacheWriteTokens = [long]$current.cacheWriteTokens - [long]$previous.cacheWriteTokens
            outputTokens = [long]$current.outputTokens - [long]$previous.outputTokens
            totalTokens = [long]$current.totalTokens - [long]$previous.totalTokens
            costUsd = [decimal]$current.costUsd - [decimal]$previous.costUsd
        }
    } else { $current }
    Save-State -Path $statePath -Snapshot $current -Hash $hash -TurnId ([string]$inputObject.turn_id)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('────────────────────────────')
    [void]$lines.Add($(if ($isRealtime -or $isDelta) { 'Turn token usage' } else { 'Token usage since session start' }))
    if ([bool]$settings.showSessionId) { [void]$lines.Add(('Session         {0}' -f (Format-SessionId $sessionId))) }
    if ([bool]$settings.showModel -and @($current.models).Count -gt 0) { [void]$lines.Add(('Model           {0}' -f (@($current.models) -join ', '))) }
    [void]$lines.Add(('Input           {0}' -f (Format-TokenCount $shown.inputTokens $isDelta)))
    [void]$lines.Add(('Output          {0}' -f (Format-TokenCount $shown.outputTokens $isDelta)))
    [void]$lines.Add(('Cache           {0}' -f (Format-TokenCount $shown.cachedInputTokens $isDelta)))
    [void]$lines.Add(('Total           {0}' -f (Format-TokenCount $shown.totalTokens $isDelta)))
    $cacheTotal = [decimal]$shown.cachedInputTokens + [decimal]$shown.cacheWriteTokens + [decimal]$shown.inputTokens
    $cacheHitRate = if ($cacheTotal -gt 0) { ([decimal]$shown.cachedInputTokens / $cacheTotal) * 100 } else { 0 }
    [void]$lines.Add(('Cache hit rate  {0}' -f (Format-Percentage $cacheHitRate)))
    if ([bool]$settings.showCost -and [bool]$current.hasCost) { [void]$lines.Add(('Cost            {0}' -f (Format-Cost $shown.costUsd $isDelta))) }
    if ([bool]$settings.showCost -and [bool]$current.hasCost) { [void]$lines.Add(('Estimated usage {0}' -f (Format-Percentage (([decimal]$shown.costUsd / [decimal]1.3) * 1)))) }
    [void]$lines.Add('────────────────────────────')
    Write-HookDiagnostic -HookInput $inputObject -Result 'success' -Details ("source={0}; displayedDelta={1}" -f $current.source, $isDelta)
    Write-HookOutput ([pscustomobject]@{ systemMessage = $lines -join [Environment]::NewLine })
} catch {
    $reason = if ($_.Exception.Message -match 'ccsessions not found') { 'ccsessions not found' } elseif ($_.Exception.Message -match 'session ID') { 'session ID could not be resolved' } else { 'usage data could not be read' }
    Write-HookDiagnostic -HookInput $inputObject -Result 'error' -Details $_.Exception.Message
    Write-HookOutput ([pscustomobject]@{ systemMessage = "Token usage unavailable: $reason" })
}
