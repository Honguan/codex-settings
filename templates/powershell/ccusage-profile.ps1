# Source: https://github.com/ccusage/ccusage
# Managed by codex-settings. Commands intentionally use ccusage@latest.

# >>> CS CODEX SESSION VIEWER >>>
function global:cs {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Value
    )

    $commandContext = [pscustomobject]@{ Text = $null; Raw = $null }

    function Invoke-CcusageJson {
        if (Get-Command npx -ErrorAction SilentlyContinue) {
            $commandContext.Text = 'npx --yes ccusage@latest codex session --json'
            $output = & npx --yes 'ccusage@latest' codex session --json 2>&1
        } elseif (Get-Command ccusage -ErrorAction SilentlyContinue) {
            $commandContext.Text = 'ccusage codex session --json'
            $output = & ccusage codex session --json 2>&1
        } else {
            throw 'Neither npx nor ccusage is available. Install Node.js and run the codex-settings global installer.'
        }

        $exitCode = $LASTEXITCODE
        $commandContext.Raw = ($output | Out-String).Trim()
        if ($exitCode -ne 0) {
            $details = if ([string]::IsNullOrWhiteSpace($commandContext.Raw)) { '(no command output)' } else { $commandContext.Raw }
            throw "ccusage exited with code $exitCode.`nCommand: $commandContext.Text`nOutput:`n$details"
        }

        $text = $commandContext.Raw -replace ([char]27 + '\[[0-?]*[ -/]*[@-~]'), ''
        $start = $text.IndexOf('{')
        $end = $text.LastIndexOf('}')
        if ($start -lt 0 -or $end -le $start) {
            $preview = if ($text.Length -gt 800) { $text.Substring(0, 800) + '...' } else { $text }
            throw "ccusage returned no JSON object.`nCommand: $commandContext.Text`nOutput preview:`n$preview"
        }

        $jsonText = $text.Substring($start, $end - $start + 1)
        try {
            return $jsonText | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "ccusage JSON parsing failed: $($_.Exception.Message)`nCommand: $commandContext.Text"
        }
    }

    function Get-Sessions($Report) {
        if ($null -ne $Report.sessions) { return @($Report.sessions) }
        if ($null -ne $Report.codex -and $null -ne $Report.codex.sessions) { return @($Report.codex.sessions) }
        if ($null -ne $Report.data -and $null -ne $Report.data.sessions) { return @($Report.data.sessions) }

        $properties = @($Report.PSObject.Properties.Name)
        $propertyText = if ($properties.Count -gt 0) { $properties -join ', ' } else { '(none)' }
        throw "Unsupported ccusage JSON schema. Root properties: $propertyText"
    }

    function Get-Activity($Row) {
        try { return [DateTimeOffset]::Parse([string]$Row.lastActivity) }
        catch { return [DateTimeOffset]::MinValue }
    }

    function Get-SessionId($Row) {
        $pattern = '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        foreach ($source in @([string]$Row.sessionFile, [string]$Row.sessionId)) {
            if ([string]::IsNullOrWhiteSpace($source)) { continue }
            $match = [regex]::Match($source, $pattern)
            if ($match.Success) { return $match.Value }
        }
        if ($Row.sessionFile) { return [IO.Path]::GetFileNameWithoutExtension([string]$Row.sessionFile) }
        return [string]$Row.sessionId
    }

    function Format-SessionId([string]$Id) {
        if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
        if ($Id.Length -gt 6) { return $Id.Substring($Id.Length - 6) }
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
                'Session ID'   = Format-SessionId (Get-SessionId $_)
                Models         = Get-Models $_.models
                Input          = Format-Number $_.inputTokens
                Output         = Format-Number $_.outputTokens
                Reasoning      = Format-Number $_.reasoningOutputTokens
                'Cache Read'   = Format-Number $_.cacheReadTokens
                'Total Tokens' = Format-Number $_.totalTokens
                'Cost (USD)'   = Format-Cost $_.costUSD
                Time           = if ((Get-Activity $_) -eq [DateTimeOffset]::MinValue) { '' } else { (Get-Activity $_).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
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
                    $from = [int]$matches[1]
                    $to = [int]$matches[2]
                    if ($from -gt $to) { $temporary = $from; $from = $to; $to = $temporary }
                    $from = [Math]::Max(1, $from)
                    $to = [Math]::Min($Records.Count, $to)
                    for ($number = $from; $number -le $to; $number++) { [void]$numbers.Add($number) }
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
        $sessions = @(Get-Sessions $report | Where-Object { $null -ne $_ } | Sort-Object @{ Expression = { Get-Activity $_ }; Descending = $true })
        if ($sessions.Count -eq 0) {
            $sessionRoot = Join-Path $env:USERPROFILE '.codex\sessions'
            throw "No Codex sessions were returned. Expected local data under: $sessionRoot"
        }

        $arguments = @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $count = 10
        $parsedCount = 0
        $listMode = $arguments.Count -eq 0
        if ($arguments.Count -eq 1 -and [int]::TryParse($arguments[0], [ref]$parsedCount)) {
            $count = $parsedCount
            $listMode = $true
        }

        if ($listMode) {
            if ($count -lt 1 -or $count -gt 100) { throw 'The session count must be between 1 and 100.' }
            $recent = @($sessions | Select-Object -First $count)
            Show-Details $recent
            return
        }

        $matched = @($sessions | Where-Object {
            $id = Get-SessionId $_
            foreach ($query in $arguments) {
                if ([string]::IsNullOrWhiteSpace($id)) { continue }
                if ($id -eq $query -or $id.EndsWith($query, [StringComparison]::OrdinalIgnoreCase)) { return $true }
                if ($query -match '^(.+)\.\.\.(.+)$' -and $id.StartsWith($matches[1], [StringComparison]::OrdinalIgnoreCase) -and $id.EndsWith($matches[2], [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
            return $false
        })
        if ($matched.Count -eq 0) { throw "No matching Codex sessions were found for: $($arguments -join ', ')" }
        Show-Details $matched
    } catch {
        Write-Host 'cs failed.' -ForegroundColor Red
        Write-Host "Reason : $($_.Exception.Message)" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($commandContext.Text)) { Write-Host "Command: $($commandContext.Text)" }
        Write-Host "Profile: $($PROFILE.CurrentUserAllHosts)"
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
        if (Get-Command npx -ErrorAction SilentlyContinue) {
            $commandText = "npx --yes ccusage@latest codex daily --last $Days --timezone Asia/Taipei"
            $output = & npx --yes 'ccusage@latest' codex daily --last $Days --timezone 'Asia/Taipei' 2>&1
        } elseif (Get-Command ccusage -ErrorAction SilentlyContinue) {
            $commandText = "ccusage codex daily --last $Days --timezone Asia/Taipei"
            $output = & ccusage codex daily --last $Days --timezone 'Asia/Taipei' 2>&1
        } else {
            throw 'Neither npx nor ccusage is available. Install Node.js and run the codex-settings global installer.'
        }

        $exitCode = $LASTEXITCODE
        $output | Out-Host
        if ($exitCode -ne 0) {
            throw "ccusage exited with code $exitCode.`nCommand: $commandText`nOutput:`n$($output | Out-String)"
        }
    } catch {
        Write-Host 'cdaily failed.' -ForegroundColor Red
        Write-Host "Reason : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Profile: $($PROFILE.CurrentUserAllHosts)"
    }
}
# <<< CDAILY CODEX DAILY REPORT <<<
