# Source: https://github.com/ccusage/ccusage
# Managed by codex-settings. Prefer the installer-managed global ccusage binary; use npx latest only as fallback.

$script:CodexUsageBackendCache = $null
$script:CodexUsageLastCommandText = $null

function global:Get-CodexUsageElapsedMilliseconds($Stopwatch) {
    if ($null -eq $Stopwatch) { return 0 }
    return [long]$Stopwatch.ElapsedMilliseconds
}

function global:Resolve-CodexUsageBackend {
    [CmdletBinding()]
    param([switch]$PreferNpx)

    $pathStamp = [string]$env:PATH
    if (-not $PreferNpx -and $null -ne $script:CodexUsageBackendCache -and $script:CodexUsageBackendCache.PathStamp -eq $pathStamp) {
        $cached = $script:CodexUsageBackendCache
        if ($cached.CommandType -ne 'Application' -or [string]::IsNullOrWhiteSpace([string]$cached.ExecutablePath) -or (Test-Path -LiteralPath $cached.ExecutablePath -PathType Leaf)) {
            return $cached
        }
        $script:CodexUsageBackendCache = $null
    }

    if (-not $PreferNpx) {
        $ccusage = @(Get-Command ccusage -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
        if ($null -ne $ccusage) {
            $backend = [pscustomobject]@{
                Kind = 'ccusage'
                CommandName = [string]$ccusage.Name
                CommandType = [string]$ccusage.CommandType
                ExecutablePath = if ($ccusage.CommandType -eq 'Application') { [string]$ccusage.Source } else { $null }
                PathStamp = $pathStamp
                CommandText = 'ccusage'
            }
            $script:CodexUsageBackendCache = $backend
            return $backend
        }
    }

    $npx = @(Get-Command npx -ErrorAction SilentlyContinue | Select-Object -First 1)[0]
    if ($null -eq $npx) {
        throw 'Neither npx nor ccusage is available. Install Node.js and run the codex-settings global installer.'
    }

    return [pscustomobject]@{
        Kind = 'npx'
        CommandName = [string]$npx.Name
        CommandType = [string]$npx.CommandType
        ExecutablePath = if ($npx.CommandType -eq 'Application') { [string]$npx.Source } else { $null }
        PathStamp = $pathStamp
        CommandText = 'npx --yes ccusage@latest'
    }
}

function global:ConvertFrom-CodexUsageOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Output,
        [Parameter(Mandatory = $true)][string]$CommandText
    )

    $profileEnabled = $env:CODEX_SETTINGS_USAGE_PROFILE -eq '1'
    $stdoutStopwatch = if ($profileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
    $text = ($Output | Out-String).Trim()
    $text = $text -replace ([char]27 + '\[[0-?]*[ -/]*[@-~]'), ''
    $stdoutParseMs = Get-CodexUsageElapsedMilliseconds $stdoutStopwatch
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) {
        $preview = if ($text.Length -gt 800) { $text.Substring(0, 800) + '...' } else { $text }
        throw "ccusage returned no JSON object.`nCommand: $CommandText`nOutput preview:`n$preview"
    }

    $jsonText = $text.Substring($start, $end - $start + 1)
    $jsonStopwatch = if ($profileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
    try {
        $report = $jsonText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "ccusage JSON parsing failed: $($_.Exception.Message)`nCommand: $CommandText"
    }
    $jsonParseMs = Get-CodexUsageElapsedMilliseconds $jsonStopwatch

    return [pscustomobject]@{
        Report = $report
        Raw = $text
        StdoutParseMs = $stdoutParseMs
        JsonParseMs = $jsonParseMs
    }
}

function global:Invoke-CodexUsageJson {
    [CmdletBinding()]
    param(
        [ValidateSet('session', 'daily')][string]$ReportKind = 'session',
        [ValidateRange(1, 3650)][int]$Days = 7
    )

    $profileEnabled = $env:CODEX_SETTINGS_USAGE_PROFILE -eq '1'
    $totalStopwatch = if ($profileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
    $backendStopwatch = if ($profileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
    $backend = Resolve-CodexUsageBackend
    $backendResolveMs = Get-CodexUsageElapsedMilliseconds $backendStopwatch
    $attemptErrors = New-Object 'System.Collections.Generic.List[string]'
    $attemptedFallback = $false

    while ($null -ne $backend) {
        $arguments = if ($ReportKind -eq 'session') {
            @('codex', 'session', '--timezone', 'Asia/Taipei', '--json')
        } else {
            @('codex', 'daily', '--last', [string]$Days, '--timezone', 'Asia/Taipei', '--json')
        }
        $commandText = if ($backend.Kind -eq 'ccusage') {
            $backend.CommandText + ' ' + ($arguments -join ' ')
        } else {
            $backend.CommandText + ' ' + ($arguments -join ' ')
        }
        $script:CodexUsageLastCommandText = $commandText

        $processStopwatch = if ($profileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
        if ($backend.Kind -eq 'ccusage') {
            $output = & $backend.CommandName @arguments 2>&1
        } else {
            $output = & $backend.CommandName '--yes' 'ccusage@latest' @arguments 2>&1
        }
        $processMs = Get-CodexUsageElapsedMilliseconds $processStopwatch
        $exitCode = [int]$LASTEXITCODE
        if ($exitCode -ne 0) {
            $raw = ($output | Out-String).Trim()
            $details = if ([string]::IsNullOrWhiteSpace($raw)) { '(no command output)' } else { $raw }
            [void]$attemptErrors.Add("$commandText exited with code $exitCode. Output: $details")
        } else {
            try {
                $parsed = ConvertFrom-CodexUsageOutput -Output @($output) -CommandText $commandText
                $metrics = [ordered]@{
                    backendResolveMs = [long]$backendResolveMs
                    processLaunchMs = [long]$processMs
                    ccusageMs = [long]$processMs
                    stdoutParseMs = [long]$parsed.StdoutParseMs
                    jsonParseMs = [long]$parsed.JsonParseMs
                    normalizeMs = 0
                    filterMs = 0
                    sortMs = 0
                    renderMs = 0
                    fallbackUsed = [bool]$attemptedFallback
                    totalMs = Get-CodexUsageElapsedMilliseconds $totalStopwatch
                }
                return [pscustomobject]@{
                    Report = $parsed.Report
                    CommandText = $commandText
                    Raw = $parsed.Raw
                    Metrics = [pscustomobject]$metrics
                }
            } catch {
                [void]$attemptErrors.Add($_.Exception.Message)
            }
        }

        if ($backend.Kind -ne 'ccusage' -or $attemptedFallback) { break }
        $script:CodexUsageBackendCache = $null
        try {
            $backend = Resolve-CodexUsageBackend -PreferNpx
            $attemptedFallback = $true
        } catch {
            $backend = $null
            [void]$attemptErrors.Add($_.Exception.Message)
        }
    }

    throw "ccusage query failed.`n$($attemptErrors -join "`n")"
}

function global:Write-CodexUsageProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Metrics)

    if ($env:CODEX_SETTINGS_USAGE_PROFILE -ne '1') { return }
    $line = $Metrics | ConvertTo-Json -Compress -Depth 6
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_USAGE_PROFILE_LOG)) {
        Add-Content -LiteralPath $env:CODEX_SETTINGS_USAGE_PROFILE_LOG -Value $line -Encoding UTF8
    } else {
        Write-Verbose "usage-profile $line"
    }
}

# >>> CS CODEX SESSION VIEWER >>>
Remove-Item -LiteralPath Alias:\ccsessions -Force -ErrorAction SilentlyContinue
function global:ccsessions {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Value,
        [switch]$Json
    )

    $commandContext = [pscustomobject]@{ Text = $null; Raw = $null }

    function Get-Sessions($Report) {
        if ($null -ne $Report.sessions) { return @($Report.sessions) }
        if ($null -ne $Report.codex -and $null -ne $Report.codex.sessions) { return @($Report.codex.sessions) }
        if ($null -ne $Report.data -and $null -ne $Report.data.sessions) { return @($Report.data.sessions) }

        $properties = @($Report.PSObject.Properties.Name)
        $propertyText = if ($properties.Count -gt 0) { $properties -join ', ' } else { '(none)' }
        throw "Unsupported ccusage JSON schema. Root properties: $propertyText"
    }

    function Get-Activity($Row) {
        $value = $Row.lastActivity
        if ($value -is [DateTimeOffset]) { return $value }
        if ($value -is [DateTime]) { return [DateTimeOffset]::new($value) }
        try { return [DateTimeOffset]::Parse([string]$value) }
        catch { return [DateTimeOffset]::MinValue }
    }

    function Format-SessionTime($Row) {
        $activity = Get-Activity $Row
        if ($activity -eq [DateTimeOffset]::MinValue) { return '' }
        return ([TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($activity, 'Taipei Standard Time')).ToString('MM-dd hh:mm tt', [Globalization.CultureInfo]::InvariantCulture)
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

    function Test-SessionMatch($Row, [string[]]$Queries) {
        $id = Get-SessionId $Row
        foreach ($query in $Queries) {
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if ($id -eq $query -or $id.EndsWith($query, [StringComparison]::OrdinalIgnoreCase)) { return $true }
            if ($query -match '^(.+)\.\.\.(.+)$' -and $id.StartsWith($matches[1], [StringComparison]::OrdinalIgnoreCase) -and $id.EndsWith($matches[2], [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    function Format-SessionId([string]$Id) {
        if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
        if ($Id.Length -gt 17) { return $Id.Substring(0, 8) + '...' + $Id.Substring($Id.Length - 6) }
        return $Id
    }

    function Get-Models($Models) {
        if ($null -eq $Models) { return '' }
        if ($Models -is [string]) { return $Models }
        $names = @($Models.PSObject.Properties | ForEach-Object Name)
        if ($names.Count -gt 0) { return $names -join [Environment]::NewLine }
        return @($Models) -join [Environment]::NewLine
    }

    function Format-Number($Number) {
        try { return ([long]$Number).ToString('N0', [Globalization.CultureInfo]::InvariantCulture) }
        catch { return '0' }
    }

    function Format-TokenCount($Number) {
        try {
            $value = [double]$Number
            $units = @(
                [pscustomobject]@{ Limit = 1000000000; Divisor = 1000000000; Suffix = 'B' },
                [pscustomobject]@{ Limit = 1000000; Divisor = 1000000; Suffix = 'M' },
                [pscustomobject]@{ Limit = 1000; Divisor = 1000; Suffix = 'K' }
            )
            foreach ($unit in $units) {
                if ([Math]::Abs($value) -lt $unit.Limit) { continue }
                $scaled = $value / $unit.Divisor
                $decimals = if ([Math]::Abs($scaled) -ge 100) { 0 } elseif ([Math]::Abs($scaled) -ge 10) { 1 } else { 2 }
                $text = $scaled.ToString("F$decimals", [Globalization.CultureInfo]::InvariantCulture).TrimEnd('0').TrimEnd('.')
                return "$text$($unit.Suffix)"
            }
            return ([long][Math]::Round($value)).ToString([Globalization.CultureInfo]::InvariantCulture)
        } catch { return '0' }
    }

    function Format-Cost($Cost) {
        try { return '$' + ([double]$Cost).ToString('N2', [Globalization.CultureInfo]::InvariantCulture) }
        catch { return '$0.00' }
    }

    function Get-TableWidth([string]$Header, [object[]]$Rows, [string]$Property) {
        $width = $Header.Length
        foreach ($row in @($Rows)) {
            foreach ($line in [regex]::Split([string]$row.PSObject.Properties[$Property].Value, "`r?`n")) {
                $width = [Math]::Max($width, $line.Length)
            }
        }
        return $width
    }

    function New-TableBorder([string]$Left, [string]$Middle, [string]$Right, [int[]]$Widths) {
        $segments = @($Widths | ForEach-Object { '─' * ($_ + 2) })
        return $Left + ($segments -join $Middle) + $Right
    }

    function Write-TableRow([object[]]$Values, [int[]]$Widths, [int[]]$RightAlignedColumns = @()) {
        $lineGroups = New-Object 'System.Collections.Generic.List[object]'
        $height = 1
        foreach ($value in $Values) {
            $lines = @([regex]::Split([string]$value, "`r?`n"))
            [void]$lineGroups.Add($lines)
            $height = [Math]::Max($height, $lines.Count)
        }
        for ($lineIndex = 0; $lineIndex -lt $height; $lineIndex++) {
            $cells = New-Object 'System.Collections.Generic.List[string]'
            for ($column = 0; $column -lt $Widths.Count; $column++) {
                $lines = @($lineGroups[$column])
                $text = if ($lineIndex -lt $lines.Count) { [string]$lines[$lineIndex] } else { '' }
                if ($RightAlignedColumns -contains $column) {
                    [void]$cells.Add($text.PadLeft($Widths[$column]))
                } else {
                    [void]$cells.Add($text.PadRight($Widths[$column]))
                }
            }
            Write-Host ('│ ' + ($cells -join ' │ ') + ' │')
        }
    }

    function Write-ReportTitle([string]$Title) {
        $innerWidth = [Math]::Max(44, $Title.Length + 2)
        $leftPadding = [Math]::Floor(($innerWidth - $Title.Length) / 2)
        $rightPadding = $innerWidth - $Title.Length - $leftPadding
        Write-Host ('╭' + ('─' * $innerWidth) + '╮')
        Write-Host ('│' + (' ' * $innerWidth) + '│')
        Write-Host ('│' + (' ' * $leftPadding) + $Title + (' ' * $rightPadding) + '│')
        Write-Host ('│' + (' ' * $innerWidth) + '│')
        Write-Host ('╰' + ('─' * $innerWidth) + '╯')
    }

    function Get-SessionTotals([object[]]$Rows) {
        $totals = [ordered]@{}
        foreach ($field in @('inputTokens', 'outputTokens', 'reasoningOutputTokens', 'cacheReadTokens', 'totalTokens', 'costUSD')) {
            $sum = 0.0
            foreach ($row in @($Rows)) { $sum += [double]$row.$field }
            $totals[$field] = $sum
        }
        return [pscustomobject]$totals
    }

    function ConvertTo-UsageRow($Row) {
        $modelValue = $Row.models
        $models = if ($null -eq $modelValue) { @() } elseif ($modelValue -is [string]) { @($modelValue) } elseif (@($modelValue.PSObject.Properties).Count -gt 0) { @($modelValue.PSObject.Properties.Name) } else { @($modelValue) }
        return [pscustomobject][ordered]@{
            success = $true
            sessionId = Get-SessionId $Row
            models = $models
            inputTokens = [long]$Row.inputTokens
            outputTokens = [long]$Row.outputTokens
            reasoningTokens = [long]$Row.reasoningOutputTokens
            cacheTokens = [long]$Row.cacheReadTokens
            totalTokens = [long]$Row.totalTokens
            costUsd = [decimal]$Row.costUSD
            time = Format-SessionTime $Row
        }
    }

    function Show-Details([object[]]$Rows) {
        $tableRows = @($Rows | ForEach-Object {
            [pscustomobject][ordered]@{
                'Session ID'   = Format-SessionId (Get-SessionId $_)
                Models         = Get-Models $_.models
                In             = Format-TokenCount $_.inputTokens
                Out            = Format-TokenCount $_.outputTokens
                Think          = Format-TokenCount $_.reasoningOutputTokens
                Cache          = Format-TokenCount $_.cacheReadTokens
                Total          = Format-TokenCount $_.totalTokens
                Cost           = Format-Cost $_.costUSD
                Time           = Format-SessionTime $_
            }
        })
        $totals = Get-SessionTotals $Rows
        $tableRows += [pscustomobject][ordered]@{
            'Session ID' = 'Total'
            Models       = ''
            In           = Format-TokenCount $totals.inputTokens
            Out          = Format-TokenCount $totals.outputTokens
            Think        = Format-TokenCount $totals.reasoningOutputTokens
            Cache        = Format-TokenCount $totals.cacheReadTokens
            Total        = Format-TokenCount $totals.totalTokens
            Cost         = Format-Cost $totals.costUSD
            Time         = ''
        }
        $columns = @('Session ID', 'Models', 'In', 'Out', 'Think', 'Cache', 'Total', 'Cost', 'Time')
        $widths = @($columns | ForEach-Object { Get-TableWidth -Header $_ -Rows $tableRows -Property $_ })
        $rightAlignedColumns = @(2, 3, 4, 5, 6, 7, 8)

        Write-ReportTitle 'Codex Token Usage Report - Session'
        Write-Host ''
        Write-Host (New-TableBorder '╭' '┬' '╮' $widths)
        Write-TableRow -Values $columns -Widths $widths -RightAlignedColumns $rightAlignedColumns
        Write-Host (New-TableBorder '├' '┼' '┤' $widths)
        for ($index = 0; $index -lt $tableRows.Count; $index++) {
            $row = $tableRows[$index]
            $values = @($columns | ForEach-Object { $row.PSObject.Properties[$_].Value })
            Write-TableRow -Values $values -Widths $widths -RightAlignedColumns $rightAlignedColumns
            if ($index -lt ($tableRows.Count - 1)) { Write-Host (New-TableBorder '├' '┼' '┤' $widths) }
        }
        Write-Host (New-TableBorder '╰' '┴' '╯' $widths)
    }

    $usageProfileEnabled = $env:CODEX_SETTINGS_USAGE_PROFILE -eq '1'
    $usageProfileStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
    $usageProfile = [ordered]@{
        backendResolveMs = 0
        processLaunchMs = 0
        ccusageMs = 0
        stdoutParseMs = 0
        jsonParseMs = 0
        normalizeMs = 0
        filterMs = 0
        sortMs = 0
        renderMs = 0
        fallbackUsed = $false
        totalMs = 0
    }

    try {
        $usageResult = Invoke-CodexUsageJson -ReportKind 'session'
        $commandContext.Text = $usageResult.CommandText
        foreach ($metric in $usageResult.Metrics.PSObject.Properties) { $usageProfile[$metric.Name] = $metric.Value }

        $normalizeStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
        $sessions = @(Get-Sessions $usageResult.Report | Where-Object { $null -ne $_ })
        $usageProfile.normalizeMs += Get-CodexUsageElapsedMilliseconds $normalizeStopwatch
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
            $sortStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
            $sessions = @($sessions | Sort-Object @{ Expression = { Get-Activity $_ }; Descending = $true })
            $usageProfile.sortMs += Get-CodexUsageElapsedMilliseconds $sortStopwatch
            $recent = @($sessions | Select-Object -First $count)
            if ($Json) {
                $normalizeStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
                $jsonRows = @($recent | ForEach-Object { ConvertTo-UsageRow $_ })
                $usageProfile.normalizeMs += Get-CodexUsageElapsedMilliseconds $normalizeStopwatch
                Write-Output (ConvertTo-Json -InputObject $jsonRows -Depth 6 -Compress)
                return
            }
            $renderStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
            Show-Details $recent
            $usageProfile.renderMs += Get-CodexUsageElapsedMilliseconds $renderStopwatch
            return
        }

        $shouldSort = -not ($Json -and $arguments.Count -eq 1)
        if ($shouldSort) {
            $sortStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
            $sessions = @($sessions | Sort-Object @{ Expression = { Get-Activity $_ }; Descending = $true })
            $usageProfile.sortMs += Get-CodexUsageElapsedMilliseconds $sortStopwatch
        }

        $filterStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
        $matched = @($sessions | Where-Object { Test-SessionMatch $_ $arguments })
        $usageProfile.filterMs += Get-CodexUsageElapsedMilliseconds $filterStopwatch
        if ($matched.Count -eq 0) { throw "No matching Codex sessions were found for: $($arguments -join ', ')" }
        if ($Json) {
            $normalizeStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
            $usageRows = @($matched | ForEach-Object { ConvertTo-UsageRow $_ })
            $usageProfile.normalizeMs += Get-CodexUsageElapsedMilliseconds $normalizeStopwatch
            Write-Output $(if ($usageRows.Count -eq 1) { $usageRows[0] | ConvertTo-Json -Depth 6 -Compress } else { ConvertTo-Json -InputObject $usageRows -Depth 6 -Compress })
            return
        }
        $renderStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
        Show-Details $matched
        $usageProfile.renderMs += Get-CodexUsageElapsedMilliseconds $renderStopwatch
    } catch {
        if ($Json) {
            Write-Output ([pscustomobject]@{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress)
            return
        }
        Write-Host 'ccsessions 執行失敗。' -ForegroundColor Red
        Write-Host "原因：$($_.Exception.Message)" -ForegroundColor Red
        if ([string]::IsNullOrWhiteSpace($commandContext.Text)) { $commandContext.Text = $script:CodexUsageLastCommandText }
        if (-not [string]::IsNullOrWhiteSpace($commandContext.Text)) { Write-Host "指令：$($commandContext.Text)" }
        Write-Host "設定檔：$($PROFILE.CurrentUserAllHosts)"
    } finally {
        $usageProfile.totalMs = Get-CodexUsageElapsedMilliseconds $usageProfileStopwatch
        Write-CodexUsageProfile -Metrics ([pscustomobject]$usageProfile)
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

    function Format-DailyTokenCount($Number) {
        try {
            $value = [double]$Number
            $units = @(
                [pscustomobject]@{ Limit = 1000000000; Divisor = 1000000000; Suffix = 'B' },
                [pscustomobject]@{ Limit = 1000000; Divisor = 1000000; Suffix = 'M' },
                [pscustomobject]@{ Limit = 1000; Divisor = 1000; Suffix = 'K' }
            )
            foreach ($unit in $units) {
                if ([Math]::Abs($value) -lt $unit.Limit) { continue }
                $scaled = $value / $unit.Divisor
                $decimals = if ([Math]::Abs($scaled) -ge 100) { 0 } elseif ([Math]::Abs($scaled) -ge 10) { 1 } else { 2 }
                $text = $scaled.ToString("F$decimals", [Globalization.CultureInfo]::InvariantCulture).TrimEnd('0').TrimEnd('.')
                return "$text$($unit.Suffix)"
            }
            return ([long][Math]::Round($value)).ToString([Globalization.CultureInfo]::InvariantCulture)
        } catch { return '0' }
    }

    function Format-DailyCost($Cost) {
        try { return '$' + ([double]$Cost).ToString('N2', [Globalization.CultureInfo]::InvariantCulture) }
        catch { return '$0.00' }
    }

    function Get-DailyModels($Models) {
        if ($null -eq $Models) { return '' }
        $names = @($Models.PSObject.Properties | ForEach-Object Name)
        if ($names.Count -gt 0) { return $names | ForEach-Object { "- $_" } | Join-String -Separator ([Environment]::NewLine) }
        return [string]$Models
    }

    function Get-DailyTableWidth([string]$Header, [object[]]$Rows, [string]$Property) {
        $width = $Header.Length
        foreach ($row in @($Rows)) {
            foreach ($line in [regex]::Split([string]$row.PSObject.Properties[$Property].Value, "`r?`n")) {
                $width = [Math]::Max($width, $line.Length)
            }
        }
        return $width
    }

    function New-DailyTableBorder([string]$Left, [string]$Middle, [string]$Right, [int[]]$Widths) {
        $segments = @($Widths | ForEach-Object { '─' * ($_ + 2) })
        return $Left + ($segments -join $Middle) + $Right
    }

    function Write-DailyTableRow([object[]]$Values, [int[]]$Widths, [int[]]$RightAlignedColumns = @()) {
        $lineGroups = New-Object 'System.Collections.Generic.List[object]'
        $height = 1
        foreach ($value in $Values) {
            $lines = @([regex]::Split([string]$value, "`r?`n"))
            [void]$lineGroups.Add($lines)
            $height = [Math]::Max($height, $lines.Count)
        }
        for ($lineIndex = 0; $lineIndex -lt $height; $lineIndex++) {
            $cells = New-Object 'System.Collections.Generic.List[string]'
            for ($column = 0; $column -lt $Widths.Count; $column++) {
                $lines = @($lineGroups[$column])
                $text = if ($lineIndex -lt $lines.Count) { [string]$lines[$lineIndex] } else { '' }
                if ($RightAlignedColumns -contains $column) {
                    [void]$cells.Add($text.PadLeft($Widths[$column]))
                } else {
                    [void]$cells.Add($text.PadRight($Widths[$column]))
                }
            }
            Write-Host ('│ ' + ($cells -join ' │ ') + ' │')
        }
    }

    function Show-DailyDetails([object[]]$DailyRows, $Totals) {
        $tableRows = @($DailyRows | ForEach-Object {
            [pscustomobject][ordered]@{
                Date      = [string]$_.date
                Models    = Get-DailyModels $_.models
                Input     = Format-DailyTokenCount $_.inputTokens
                Output    = Format-DailyTokenCount $_.outputTokens
                Reasoning = Format-DailyTokenCount $_.reasoningOutputTokens
                'Cache Read' = Format-DailyTokenCount $_.cacheReadTokens
                'Total Tokens' = Format-DailyTokenCount $_.totalTokens
                'Cost (USD)' = Format-DailyCost $_.costUSD
            }
        })
        if ($null -ne $Totals) {
            $tableRows += [pscustomobject][ordered]@{
                Date      = 'Total'
                Models    = ''
                Input     = Format-DailyTokenCount $Totals.inputTokens
                Output    = Format-DailyTokenCount $Totals.outputTokens
                Reasoning = Format-DailyTokenCount $Totals.reasoningOutputTokens
                'Cache Read' = Format-DailyTokenCount $Totals.cacheReadTokens
                'Total Tokens' = Format-DailyTokenCount $Totals.totalTokens
                'Cost (USD)' = Format-DailyCost $Totals.costUSD
            }
        }

        $columns = @('Date', 'Models', 'Input', 'Output', 'Reasoning', 'Cache Read', 'Total Tokens', 'Cost (USD)')
        $widths = @($columns | ForEach-Object { Get-DailyTableWidth -Header $_ -Rows $tableRows -Property $_ })
        $rightAlignedColumns = @(2, 3, 4, 5, 6, 7)
        $title = 'Codex Token Usage Report - Daily'
        $innerWidth = [Math]::Max(44, $title.Length + 2)
        $leftPadding = [Math]::Floor(($innerWidth - $title.Length) / 2)
        $rightPadding = $innerWidth - $title.Length - $leftPadding
        Write-Host ('╭' + ('─' * $innerWidth) + '╮')
        Write-Host ('│' + (' ' * $innerWidth) + '│')
        Write-Host ('│' + (' ' * $leftPadding) + $title + (' ' * $rightPadding) + '│')
        Write-Host ('│' + (' ' * $innerWidth) + '│')
        Write-Host ('╰' + ('─' * $innerWidth) + '╯')
        Write-Host ''
        Write-Host (New-DailyTableBorder '╭' '┬' '╮' $widths)
        Write-DailyTableRow -Values $columns -Widths $widths -RightAlignedColumns $rightAlignedColumns
        Write-Host (New-DailyTableBorder '├' '┼' '┤' $widths)
        for ($index = 0; $index -lt $tableRows.Count; $index++) {
            $row = $tableRows[$index]
            $values = @($columns | ForEach-Object { $row.PSObject.Properties[$_].Value })
            Write-DailyTableRow -Values $values -Widths $widths -RightAlignedColumns $rightAlignedColumns
            if ($index -lt ($tableRows.Count - 1)) { Write-Host (New-DailyTableBorder '├' '┼' '┤' $widths) }
        }
        Write-Host (New-DailyTableBorder '╰' '┴' '╯' $widths)
    }

    $usageProfileEnabled = $env:CODEX_SETTINGS_USAGE_PROFILE -eq '1'
    $usageProfileStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
    $usageProfile = [ordered]@{
        backendResolveMs = 0
        processLaunchMs = 0
        ccusageMs = 0
        stdoutParseMs = 0
        jsonParseMs = 0
        normalizeMs = 0
        filterMs = 0
        sortMs = 0
        renderMs = 0
        fallbackUsed = $false
        totalMs = 0
    }

    try {
        $usageResult = Invoke-CodexUsageJson -ReportKind 'daily' -Days $Days
        foreach ($metric in $usageResult.Metrics.PSObject.Properties) { $usageProfile[$metric.Name] = $metric.Value }
        $commandText = $usageResult.CommandText
        $normalizeStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
        $report = $usageResult.Report
        $dailyRows = if ($null -ne $report.daily) { @($report.daily) } elseif ($null -ne $report.data.daily) { @($report.data.daily) } else { @() }
        $usageProfile.normalizeMs += Get-CodexUsageElapsedMilliseconds $normalizeStopwatch
        if ($dailyRows.Count -eq 0) { throw 'No daily Codex usage rows were returned.' }
        $renderStopwatch = if ($usageProfileEnabled) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
        Show-DailyDetails -DailyRows $dailyRows -Totals $report.totals
        $usageProfile.renderMs += Get-CodexUsageElapsedMilliseconds $renderStopwatch
    } catch {
        if ([string]::IsNullOrWhiteSpace($commandText)) { $commandText = $script:CodexUsageLastCommandText }
        Write-Host 'cdaily 執行失敗。' -ForegroundColor Red
        Write-Host "原因：$($_.Exception.Message)" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($commandText)) { Write-Host "指令：$commandText" }
        Write-Host "設定檔：$($PROFILE.CurrentUserAllHosts)"
    } finally {
        $usageProfile.totalMs = Get-CodexUsageElapsedMilliseconds $usageProfileStopwatch
        Write-CodexUsageProfile -Metrics ([pscustomobject]$usageProfile)
    }
}
# <<< CDAILY CODEX DAILY REPORT <<<
