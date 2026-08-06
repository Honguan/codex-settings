$script:CodexSettingsStateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexSettings'

function Enter-CodexSettingsLock {
    [CmdletBinding()]
    param([string]$Name = 'settings')

    New-Item -ItemType Directory -Path $script:CodexSettingsStateRoot -Force | Out-Null
    $path = Join-Path $script:CodexSettingsStateRoot ("$Name.lock")
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $stream = New-Object IO.FileStream($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $payload = [ordered]@{
                ProcessId = $PID
                ProcessStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
                CreatedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress
            $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($payload)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            return [pscustomobject]@{ Path = $path; Stream = $stream }
        } catch [IO.IOException] {
            $active = $true
            try {
                $existing = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $process = Get-Process -Id ([int]$existing.ProcessId) -ErrorAction SilentlyContinue
                $active = $null -ne $process -and $process.StartTime.ToUniversalTime().ToString('o') -eq [string]$existing.ProcessStartUtc
            } catch { $active = $true }
            if ($active) { throw "Another codex-settings operation is running. Lock: $path" }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
    throw "Unable to acquire codex-settings lock: $path"
}

function Exit-CodexSettingsLock {
    [CmdletBinding()]
    param($Lock)

    if ($null -eq $Lock) { return }
    try { $Lock.Stream.Dispose() } finally { Remove-Item -LiteralPath $Lock.Path -Force -ErrorAction SilentlyContinue }
}

function New-FileTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Mode = 'Operation'
    )

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $transaction = [pscustomobject]@{
        Root = $Root
        CreatedAt = (Get-Date).ToString('o')
        Entries = New-Object 'System.Collections.Generic.List[object]'
        Seen = @{}
        Metadata = [ordered]@{ Mode = $Mode; Status = 'InProgress' }
    }
    Save-TransactionMetadata -Transaction $transaction -Metadata @{}
    return $transaction
}

function Save-TransactionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Transaction,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($Transaction.Seen.ContainsKey($fullPath)) { return }
    $Transaction.Seen[$fullPath] = $true
    $hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath))
    $name = ([BitConverter]::ToString($hashBytes)).Replace('-', '')
    $backupPath = Join-Path $Transaction.Root ('files\' + $name)
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    if ($exists) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
        Copy-FileAtomic -Source $fullPath -Destination $backupPath
    }
    [void]$Transaction.Entries.Add([pscustomobject]@{ Path = $fullPath; Existed = $exists; BackupPath = if ($exists) { $backupPath } else { $null } })
    Save-TransactionMetadata -Transaction $Transaction -Metadata @{}
}

function Undo-FileTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)

    for ($index = $Transaction.Entries.Count - 1; $index -ge 0; $index--) {
        $entry = $Transaction.Entries[$index]
        if ([bool]$entry.Existed) {
            Copy-FileAtomic -Source ([string]$entry.BackupPath) -Destination ([string]$entry.Path)
        } else {
            Remove-Item -LiteralPath ([string]$entry.Path) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-TransactionMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Transaction,
        [Parameter(Mandatory = $true)][hashtable]$Metadata
    )

    foreach ($key in $Metadata.Keys) { $Transaction.Metadata[$key] = $Metadata[$key] }
    $payload = [ordered]@{
        Version = 3
        CreatedAt = $Transaction.CreatedAt
        UpdatedAt = (Get-Date).ToString('o')
        Files = $Transaction.Entries.ToArray()
    }
    foreach ($key in $Transaction.Metadata.Keys) { $payload[$key] = $Transaction.Metadata[$key] }
    Write-JsonFileAtomic -Path (Join-Path $Transaction.Root 'backup-meta.json') -Value $payload -Depth 14
}

function Complete-FileTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)

    Save-TransactionMetadata -Transaction $Transaction -Metadata @{ Status = 'Completed'; CompletedAt = (Get-Date).ToString('o') }
}
