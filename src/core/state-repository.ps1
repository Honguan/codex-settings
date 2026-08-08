function Get-CodexSettingsStateRoot {
    [CmdletBinding()]
    param([string]$Root = '')

    if (-not [string]::IsNullOrWhiteSpace($Root)) { return [IO.Path]::GetFullPath($Root) }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_STATE_ROOT)) { return [IO.Path]::GetFullPath($env:CODEX_SETTINGS_STATE_ROOT) }
    return Join-Path $HOME '.codex\state'
}

function Get-CodexSettingsStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [AllowEmptyString()][string]$Key = '',
        [string]$Root = ''
    )

    $stateRoot = Get-CodexSettingsStateRoot -Root $Root
    $keyText = "$Kind|$Key"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($keyText)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return Join-Path (Join-Path $stateRoot $Kind) ($hash + '.json')
}

function Read-CodexSettingsState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [AllowEmptyString()][string]$Key = '',
        [string]$Root = '',
        [AllowNull()]$DefaultPayload = $null
    )

    $path = Get-CodexSettingsStatePath -Kind $Kind -Key $Key -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return New-CodexSettingsStateEnvelope -Kind $Kind -Key $Key -Payload $DefaultPayload
    }

    try {
        $stored = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        if ($stored.PSObject.Properties.Name -contains 'schemaVersion' -and $stored.PSObject.Properties.Name -contains 'kind' -and $stored.PSObject.Properties.Name -contains 'payload') {
            return $stored
        }
        return New-CodexSettingsStateEnvelope -Kind $Kind -Key $Key -Payload $stored
    } catch {
        $corruptPath = $path + '.corrupt-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff')
        try { Move-Item -LiteralPath $path -Destination $corruptPath -Force -ErrorAction SilentlyContinue } catch {}
        return New-CodexSettingsStateEnvelope -Kind $Kind -Key $Key -Payload $DefaultPayload
    }
}

function Write-CodexSettingsState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [AllowEmptyString()][string]$Key = '',
        [AllowNull()]$Payload = $null,
        [AllowNull()]$Envelope = $null,
        [string]$Root = '',
        [int]$Depth = 16
    )

    $path = Get-CodexSettingsStatePath -Kind $Kind -Key $Key -Root $Root
    $value = if ($null -ne $Envelope) { $Envelope } else { New-CodexSettingsStateEnvelope -Kind $Kind -Key $Key -Payload $Payload }
    if ($value.PSObject.Properties.Name -contains 'updatedAt') { $value.updatedAt = (Get-Date).ToUniversalTime().ToString('o') }
    else { $value = New-CodexSettingsStateEnvelope -Kind $Kind -Key $Key -Payload $value }
    Write-JsonFileAtomic -Path $path -Value $value -Depth $Depth
    return $value
}

function Invoke-CodexSettingsStateLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [AllowEmptyString()][string]$Key = '',
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string]$Root = '',
        [int]$TimeoutMilliseconds = 5000
    )

    $lockPath = (Get-CodexSettingsStatePath -Kind $Kind -Key ($Key + '.lock') -Root $Root) + '.lock'
    New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $stream = $null
    try {
        while ($null -eq $stream -and $stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            try { $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch [IO.IOException] { Start-Sleep -Milliseconds 25 }
        }
        if ($null -eq $stream) { throw "State lock timeout: $Kind/$Key" }
        return & $Action
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Update-CodexSettingsState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [AllowEmptyString()][string]$Key = '',
        [Parameter(Mandatory = $true)][scriptblock]$Update,
        [AllowNull()]$DefaultPayload = $null,
        [string]$Root = ''
    )

    return Invoke-CodexSettingsStateLock -Kind $Kind -Key $Key -Root $Root -Action {
        $current = Read-CodexSettingsState -Kind $Kind -Key $Key -Root $Root -DefaultPayload $DefaultPayload
        $payload = & $Update $current.payload $current
        Write-CodexSettingsState -Kind $Kind -Key $Key -Root $Root -Payload $payload -Envelope (New-CodexSettingsStateEnvelope -Kind $Kind -Key $Key -Payload $payload -SchemaVersion ([int]$current.schemaVersion) -CreatedAt ([string]$current.createdAt))
    }
}

function Remove-CodexSettingsState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Kind, [AllowEmptyString()][string]$Key = '', [string]$Root = '')

    $path = Get-CodexSettingsStatePath -Kind $Kind -Key $Key -Root $Root
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}
