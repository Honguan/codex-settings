function Restore-ExternalTransactionState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Metadata)

    if ($Metadata.PSObject.Properties.Name -contains 'CcusageBefore' -and $null -ne $Metadata.CcusageBefore) {
        Restore-CcusageState -State $Metadata.CcusageBefore
    }

    if ($Metadata.PSObject.Properties.Name -contains 'Context7Before' -and $null -ne $Metadata.Context7Before) {
        if ([bool]$Metadata.Context7Before.WasPresent) {
            $value = Unprotect-LocalSecret -ProtectedValue ([string]$Metadata.Context7Before.ProtectedValue)
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $value, 'User')
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $value, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'User')
            [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'Process')
        }
    } elseif (($Metadata.PSObject.Properties.Name -contains 'Context7InstallerMayCreate') -and [bool]$Metadata.Context7InstallerMayCreate -and
        (-not [bool]$Metadata.Context7KeyWasPresent)) {
        [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'User')
        [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'Process')
    }
}

function Repair-PendingTransactions {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupRoot)

    $recovered = New-Object 'System.Collections.Generic.List[string]'
    foreach ($directory in @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue)) {
        $metadataPath = Join-Path $directory.FullName 'backup-meta.json'
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { continue }
        try { $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }
        if ([string]$metadata.Status -ne 'InProgress' -or $null -eq $metadata.Files) { continue }

        for ($index = @($metadata.Files).Count - 1; $index -ge 0; $index--) {
            $entry = @($metadata.Files)[$index]
            if ([bool]$entry.Existed) {
                if (-not (Test-Path -LiteralPath ([string]$entry.BackupPath) -PathType Leaf)) {
                    throw "Pending transaction backup is missing: $($entry.BackupPath)"
                }
                Copy-FileAtomic -Source ([string]$entry.BackupPath) -Destination ([string]$entry.Path)
            } else {
                Remove-Item -LiteralPath ([string]$entry.Path) -Force -ErrorAction SilentlyContinue
            }
        }
        Restore-ExternalTransactionState -Metadata $metadata
        $metadata.Status = 'Recovered'
        $metadata | Add-Member -NotePropertyName RecoveredAt -NotePropertyValue (Get-Date).ToString('o') -Force
        Write-JsonFileAtomic -Path $metadataPath -Value $metadata -Depth 14
        [void]$recovered.Add($directory.FullName)
    }
    return $recovered.ToArray()
}
