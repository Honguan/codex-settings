# Source: https://github.com/ccusage/ccusage
# Installed by codex-settings.

# >>> CS CODEX SESSION VIEWER >>>
function global:cs {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Value
    )

    function Invoke-CcusageJson {
        $output = if (Get-Command ccusage -ErrorAction SilentlyContinue) {
            & ccusage codex session --json 2>&1
        } elseif (Get-Command npx -ErrorAction SilentlyContinue) {
            & npx --yes 'ccusage@latest' codex session --json 2>&1
        } else {
            throw 'ccusage and npx were not found. Install Node.js and ccusage first.'
        }

        if ($LASTEXITCODE -ne 0) {
            throw "ccusage failed with exit code $LASTEXITCODE.`n$($output | Out-String)"
        }

        $text = ($output | Out-String) -replace ([char]27 + '\[[0-?]*[ -/]*[@-~]'), ''
        $start = $text.IndexOf('{')
        $end = $text.LastIndexOf('}')
        if ($start -lt 0 -or $end -le $start) {
            throw 'ccusage returned no valid JSON data.'
        }

        return $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
    }

    function Get-Sessions($Report) {
        if ($null -ne $Report.sessions) { return @($Report.sessions) }
        if ($null -ne $Report.codex.sessions) { return @($Report.codex.sessions) }
        if ($null -ne $Report.data.sessions) { return @($Report.data.sessions) }
        return @()
    }

    function Get-Activity($Row) {
        try { return [DateTimeOffset]::Parse([string]$Row.lastActivity) }
        catch { return [DateTimeOffset]::MinValue }
    }

    function Get-SessionId($Row) {
        $pattern = '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        foreach ($source in @([string]$Row.sessionFile, [string]$Row.sessionId)) {
            $match = [regex]::Match($source, $pattern)
            if ($match.Success) { return $match.Value }
        }
        if ($Row.sessionFile) { return [IO.Path]::GetFileNameWithoutExtension([string]$Row.sessionFile) }
        return [string]$Row.sessionId
    }

    function Format-SessionId([string]$Id) {
        if ($Id.Length -gt 17) { return $Id.Substring(0, 8) + '...' + $Id.Substring($Id.Length - 6) }
        return $Id
    }

    function Get-Models($Models) {
        if ($null -eq $Models) { return '' }
        if ($Models -is [string]) { return $Models }
        $names = @($Models.PSObject.Properties | ForEach-Object Name)
        if ($names.Count -gt 0) { return $names -join ', ' }
        return @($Models) -join ', '
    }

    function Get-SessionPath($Row) {
        $candidates = New-Object 'System.Collections.Generic.List[string]'
        if ($Row.sessionId) { [void]$candidates.Add([string]$Row.sessionId) }
        if ($Row.directory -and $Row.sessionFile) {
            [void]$candidates.Add((Join-Path ([string]$Row.directory) ([string]$Row.sessionFile)))
        }
        $activity = Get-Activity $Row
        if ($activity -ne [DateTimeOffset]::MinValue -and $Row.sessionFile) {
            $dir = Join-Path "$env:USERPROFILE\.codex\sessions" $activity.ToLocalTime().ToString('yyyy\MM\dd')
            [void]$candidates.Add((Join-Path $dir ([string]$Row.sessionFile)))
        }
        foreach ($path in $candidates) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { return (Resolve-Path -LiteralPath $path).Path }
        }
        return $null
    }

    function Get-Title($Row) {
        foreach ($field in @('title', 'name', 'prompt')) {
            $value = [string]$Row.$field
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $value = ($value -replace '\s+', ' ').Trim()
                return $value.Substring(0, [Math]::Min(80, $value.Length))
            }
        }

        $path = Get-SessionPath $Row
        if ($path) {
            foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue) {
                try { $item = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                $texts = @(
                    [string]$item.payload.message,
                    [string]$item.payload.text,
                    [string]$item.message,
                    [string]$item.text
                )
                foreach ($text in $texts) {
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        $text = ($text -replace '\s+', ' ').Trim()
                        return $text.Substring(0, [Math]::Min(80, $text.Length))
                    }
                }
            }
        }
        return '(Untitled session)'
    }

    function Format-Number($Number) {
        try { return ([long]$Number).ToString('N0', [Globalization.CultureInfo]::InvariantCulture) }
        catch { return '0' }
    }

    function Format-Cost($Cost) {
        try { return '$' + ([double]$Cost).ToString('N2', [Globalization.CultureInfo]::InvariantCulture) }
        catch { return '$0.00' }
    }

    function Show-Details([object[]]$Rows) {
        @($Rows | ForEach-Object {
            [pscustomobject][ordered]@{
                'Session ID'  = Format-SessionId (Get-SessionId $_)
                Models        = Get-Models $_.models
                Input         = Format-Number $_.inputTokens
                Output        = Format-Number $_.outputTokens
                Reasoning     = Format-Number $_.reasoningOutputTokens
                'Cache Read'  = Format-Number $_.cacheReadTokens
                'Total Tokens'= Format-Number $_.totalTokens
                'Cost (USD)'  = Format-Cost $_.costUSD
                Time          = if ((Get-Activity $_) -eq [DateTimeOffset]::MinValue) { '' } else { (Get-Activity $_).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
            }
        }) | Format-Table -AutoSize -Wrap | Out-Host
    }

    function Select-Rows([object[]]$Records) {
        $Records | Select-Object ID, Title, Models, Time | Format-Table -AutoSize -Wrap | Out-Host
        Write-Host 'Select: 1,3,5-7 or 1 3 5-7. Press Enter to select all.'
        while ($true) {
            $answer = ([string](Read-Host 'Enter ID numbers')).Trim()
            if (-not $answer) { return @($Records.Row) }
            $numbers = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($part in ($answer -split '[,\s]+')) {
                if ($part -match '^(\d+)-(\d+)$') {
                    $from = [Math]::Max(1, [int]$matches[1]); $to = [Math]::Min($Records.Count, [int]$matches[2])
                    if ($from -gt $to) { $tmp = $from; $from = $to; $to = $tmp }
                    for ($i = $from; $i -le $to; $i++) { [void]$numbers.Add($i) }
                } elseif ($part -match '^\d+$' -and [int]$part -ge 1 -and [int]$part -le $Records.Count) {
                    [void]$numbers.Add([int]$part)
                }
            }
            $selected = @($Records | Where-Object { $numbers.Contains([int]$_.ID) } | ForEach-Object Row)
            if ($selected.Count -gt 0) { return $selected }
            Write-Host 'No valid IDs. Please try again.' -ForegroundColor Yellow
        }
    }

    try {
        $report = Invoke-CcusageJson
        $sessions = @(Get-Sessions $report | Where-Object { $null -ne $_ } | Sort-Object @{Expression={ Get-Activity $_ }; Descending=$true})
        if ($sessions.Count -eq 0) { throw 'No Codex sessions were found.' }

        $args = @($Value)
        $count = 10
        if ($args.Count -eq 0 -or ($args.Count -eq 1 -and [int]::TryParse($args[0], [ref]$count))) {
            if ($count -lt 1 -or $count -gt 100) { throw 'The session count must be between 1 and 100.' }
            $recent = @($sessions | Select-Object -First $count)
            $records = @(
                for ($i = 0; $i -lt $recent.Count; $i++) {
                    $row = $recent[$i]
                    [pscustomobject]@{
                        ID = $i + 1
                        Title = Get-Title $row
                        Models = Get-Models $row.models
                        Time = if ((Get-Activity $row) -eq [DateTimeOffset]::MinValue) { '' } else { (Get-Activity $row).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
                        Row = $row
                    }
                }
            )
            Show-Details (Select-Rows $records)
            return
        }

        $matched = @($sessions | Where-Object {
            $id = Get-SessionId $_
            foreach ($query in $args) {
                if ($id -eq $query -or $id.EndsWith($query, [StringComparison]::OrdinalIgnoreCase)) { return $true }
                if ($query -match '^(.+)\.\.\.(.+)$' -and $id.StartsWith($matches[1], [StringComparison]::OrdinalIgnoreCase) -and $id.EndsWith($matches[2], [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
            return $false
        })
        if ($matched.Count -eq 0) { throw 'No matching Codex sessions were found.' }
        Show-Details $matched
    } catch {
        Write-Host "Query failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
# <<< CS CODEX SESSION VIEWER <<<

# >>> CDAILY CODEX DAILY REPORT >>>
function global:cdaily {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateRange(1, 3650)]
        [int]$Days = 7
    )

    try {
        if (Get-Command ccusage -ErrorAction SilentlyContinue) {
            & ccusage codex daily --last $Days --timezone 'Asia/Taipei'
        } elseif (Get-Command npx -ErrorAction SilentlyContinue) {
            & npx --yes 'ccusage@latest' codex daily --last $Days --timezone 'Asia/Taipei'
        } else {
            throw 'ccusage and npx were not found. Install Node.js and ccusage first.'
        }
        if ($LASTEXITCODE -ne 0) { throw "ccusage failed with exit code $LASTEXITCODE." }
    } catch {
        Write-Host "Query failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
# <<< CDAILY CODEX DAILY REPORT <<<
