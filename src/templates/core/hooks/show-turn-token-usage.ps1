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
}

function ConvertTo-Snapshot($Usage, [string]$SessionId) {
    return [pscustomobject][ordered]@{
        sessionId = $SessionId
        models = @($Usage.models)
        inputTokens = [long]$Usage.inputTokens
        cachedInputTokens = [long]$Usage.cachedInputTokens
        outputTokens = [long]$Usage.outputTokens
        totalTokens = [long]$Usage.totalTokens
        costUsd = [decimal]$Usage.costUsd
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
        models = @($Snapshot.models)
        inputTokens = $Snapshot.inputTokens
        cachedInputTokens = $Snapshot.cachedInputTokens
        outputTokens = $Snapshot.outputTokens
        totalTokens = $Snapshot.totalTokens
        costUsd = $Snapshot.costUsd
        snapshotHash = $Hash
        turnId = $TurnId
        updatedAt = [DateTimeOffset]::Now.ToString('o')
    }
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporaryPath, (($value | ConvertTo-Json -Depth 6) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Format-Number([long]$Value, [bool]$Delta) {
    $prefix = if ($Delta) { '+' } else { '' }
    return $prefix + $Value.ToString('N0', [Globalization.CultureInfo]::InvariantCulture)
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

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'session ID could not be resolved' }
    $inputObject = $raw | ConvertFrom-Json -ErrorAction Stop
    $sessionId = [string]$inputObject.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'session ID could not be resolved' }
    $root = Get-StateRoot
    $settings = Get-Settings -Root $root
    if (-not [bool]$settings.enabled -or -not [bool]$settings.showAfterEachTurn) { Write-HookOutput ([pscustomobject]@{}); return }

    $usage = Invoke-CcSessionsJson -SessionId $sessionId
    $current = ConvertTo-Snapshot -Usage $usage -SessionId $sessionId
    $hash = Get-SnapshotHash -Snapshot $current
    $statePath = Get-SessionStatePath -Root $root -SessionId $sessionId
    $previous = Read-PreviousState -Path $statePath
    if ($null -ne $previous -and [string]$previous.snapshotHash -eq $hash) { Write-HookOutput ([pscustomobject]@{}); return }

    $isDelta = $null -ne $previous
    if ($isDelta) {
        foreach ($property in @('inputTokens', 'cachedInputTokens', 'outputTokens', 'totalTokens', 'costUsd')) {
            if ([decimal]$current.$property -lt [decimal]$previous.$property) { $isDelta = $false; break }
        }
    }
    $shown = if ($isDelta) {
        [pscustomobject]@{
            inputTokens = [long]$current.inputTokens - [long]$previous.inputTokens
            cachedInputTokens = [long]$current.cachedInputTokens - [long]$previous.cachedInputTokens
            outputTokens = [long]$current.outputTokens - [long]$previous.outputTokens
            totalTokens = [long]$current.totalTokens - [long]$previous.totalTokens
            costUsd = [decimal]$current.costUsd - [decimal]$previous.costUsd
        }
    } else { $current }
    Save-State -Path $statePath -Snapshot $current -Hash $hash -TurnId ([string]$inputObject.turn_id)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('────────────────────────────')
    [void]$lines.Add($(if ($isDelta) { 'Turn token usage' } else { 'Token usage since session start' }))
    [void]$lines.Add(('Input           {0}' -f (Format-Number $shown.inputTokens $isDelta)))
    [void]$lines.Add(('Cached input    {0}' -f (Format-Number $shown.cachedInputTokens $isDelta)))
    [void]$lines.Add(('Output          {0}' -f (Format-Number $shown.outputTokens $isDelta)))
    [void]$lines.Add(('Total           {0}' -f (Format-Number $shown.totalTokens $isDelta)))
    if ([bool]$settings.showCost) { [void]$lines.Add(('Cost            {0}' -f (Format-Cost $shown.costUsd $isDelta))) }
    if ([bool]$settings.showModel -and @($current.models).Count -gt 0) { [void]$lines.Add(('Model           {0}' -f (@($current.models) -join ', '))) }
    if ([bool]$settings.showSessionId) { [void]$lines.Add(('Session         {0}' -f (Format-SessionId $sessionId))) }
    [void]$lines.Add('────────────────────────────')
    Write-HookOutput ([pscustomobject]@{ systemMessage = $lines -join [Environment]::NewLine })
} catch {
    $reason = if ($_.Exception.Message -match 'ccsessions not found') { 'ccsessions not found' } elseif ($_.Exception.Message -match 'session ID') { 'session ID could not be resolved' } else { 'usage data could not be read' }
    Write-HookOutput ([pscustomobject]@{ systemMessage = "Token usage unavailable: $reason" })
}
