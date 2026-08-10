function Invoke-SerenaCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Command, [Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & $Command @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { [string]$_ }) }
}

function Get-SerenaHome {
    if (-not [string]::IsNullOrWhiteSpace($env:SERENA_HOME)) { return [string]$env:SERENA_HOME }
    return (Join-Path $HOME '.serena')
}

function Get-SerenaVersion([string[]]$Output) {
    $text = $Output -join [Environment]::NewLine
    $match = [regex]::Match($text, '(?i)\b(?:serena\s+)?(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)\b')
    if ($match.Success) { return [string]$match.Groups[1].Value }
    return ''
}

function Test-SerenaUvAvailable {
    return $null -ne (Get-Command uv -ErrorAction SilentlyContinue)
}

$script:SerenaDashboardSettings = @('web_dashboard', 'web_dashboard_open_on_launch')

function Get-SerenaConfigurationState {
    [CmdletBinding()]
    param([string]$Path = (Join-Path (Get-SerenaHome) 'serena_config.yml'))

    $file = Get-TextFileState -Path $Path
    if (-not $file.Exists) {
        return [pscustomobject]@{ Path = $Path; Exists = $false; DashboardConfigPresent = $false; DashboardEnabled = $null; DashboardOpenOnLaunch = $null; DashboardConfigStatus = 'Missing'; NeedsChange = $true; Conflict = $false }
    }

    $values = @{}
    $missing = $false
    $conflict = $false
    foreach ($setting in $script:SerenaDashboardSettings) {
        $pattern = '(?m)^' + [regex]::Escape($setting) + '[^\S\r\n]*:(?<body>[^\r\n]*)(?<lineEnding>\r?\n|$)'
        $matches = [regex]::Matches($file.Content, $pattern)
        if ($matches.Count -eq 0) { $missing = $true; continue }
        if ($matches.Count -gt 1) { $conflict = $true; continue }
        $valueMatch = [regex]::Match($matches[0].Groups['body'].Value, '^(?<leading>[^\S\r\n]*)(?<value>true|false)(?<trailing>(?:[^\S\r\n]+#.*|[^\S\r\n]*))$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $valueMatch.Success) { $conflict = $true; continue }
        $values[$setting] = [string]::Equals($valueMatch.Groups['value'].Value, 'true', [StringComparison]::OrdinalIgnoreCase)
    }
    if ($missing -and $file.Content -match '(?m)^\.\.\.[^\S\r\n]*(?:#.*)?$') { $conflict = $true }
    $enabled = @($values.Values | Where-Object { $_ }).Count -gt 0
    return [pscustomobject]@{
        Path = $Path
        Exists = $true
        DashboardConfigPresent = -not $missing
        DashboardEnabled = $values['web_dashboard']
        DashboardOpenOnLaunch = $values['web_dashboard_open_on_launch']
        DashboardConfigStatus = if ($conflict) { 'Invalid' } elseif ($missing) { 'Missing' } elseif ($enabled) { 'Enabled' } else { 'Disabled' }
        NeedsChange = -not $conflict -and ($missing -or $enabled)
        Conflict = $conflict
    }
}

function Set-SerenaDashboardConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction, [string]$Path = (Join-Path (Get-SerenaHome) 'serena_config.yml'))

    $state = Get-SerenaConfigurationState -Path $Path
    if ($state.Conflict) {
        Save-TransactionFile -Transaction $Transaction -Path $Path
        throw "Serena Dashboard ConfigurationConflict：$Path 包含重複、非純量或不安全的 Dashboard 設定。"
    }
    if (-not $state.NeedsChange) { return [pscustomobject]@{ Changed = $false; Status = 'Unchanged'; State = $state } }

    $before = Get-TextFileState -Path $Path
    $updated = $before.Content
    foreach ($setting in $script:SerenaDashboardSettings) {
        $pattern = '(?m)^' + [regex]::Escape($setting) + '[^\S\r\n]*:(?<body>[^\r\n]*)(?<lineEnding>\r?\n|$)'
        $match = [regex]::Match($updated, $pattern)
        if ($match.Success) {
            $valueMatch = [regex]::Match($match.Groups['body'].Value, '^(?<leading>[^\S\r\n]*)(?<value>true|false)(?<trailing>(?:[^\S\r\n]+#.*|[^\S\r\n]*))$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $body = $valueMatch.Groups['leading'].Value + 'false' + $valueMatch.Groups['trailing'].Value
            $updated = $updated.Substring(0, $match.Groups['body'].Index) + $body + $updated.Substring($match.Groups['body'].Index + $match.Groups['body'].Length)
        } else {
            $separator = if ([string]::IsNullOrEmpty($updated) -or $updated.EndsWith($before.NewLine)) { '' } else { $before.NewLine }
            $updated += $separator + $setting + ': false' + $before.NewLine
        }
    }

    Save-TransactionFile -Transaction $Transaction -Path $Path
    try {
        Write-TextFileState -Path $Path -Content $updated -Encoding $before.Encoding
        $after = Get-SerenaConfigurationState -Path $Path
        if ($after.Conflict -or $after.DashboardConfigStatus -ne 'Disabled') { throw 'Serena Dashboard 設定驗證失敗。' }
    } catch {
        if ($before.Exists) { Write-TextFileState -Path $Path -Content $before.Content -Encoding $before.Encoding }
        else { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
        throw
    }
    return [pscustomobject]@{ Changed = $true; Status = 'Updated'; State = $after }
}

function Get-SerenaInstallationState {
    [CmdletBinding()]
    param()

    if (-not (Test-SerenaUvAvailable)) {
        $dashboard = Get-SerenaConfigurationState
        return [pscustomobject]@{ UvAvailable = $false; UvVersion = ''; ToolPresent = $false; CliPresent = $false; Version = ''; Initialized = $dashboard.Exists; DashboardConfigPresent = $dashboard.DashboardConfigPresent; DashboardOpenOnLaunch = $dashboard.DashboardOpenOnLaunch; DashboardConfigStatus = $dashboard.DashboardConfigStatus }
    }
    $uvVersion = Invoke-SerenaCommand -Command 'uv' -Arguments @('--version')
    if ($uvVersion.ExitCode -ne 0) { throw "無法執行 uv --version：$($uvVersion.Output -join [Environment]::NewLine)" }
    $tools = Invoke-SerenaCommand -Command 'uv' -Arguments @('tool', 'list')
    if ($tools.ExitCode -ne 0) { throw "無法讀取 uv tool 狀態：$($tools.Output -join [Environment]::NewLine)" }
    $cli = if ($null -ne (Get-Command serena -ErrorAction SilentlyContinue)) { Invoke-SerenaCommand -Command 'serena' -Arguments @('--version') } else { $null }
    $dashboard = Get-SerenaConfigurationState
    return [pscustomobject]@{
        UvAvailable = $true
        UvVersion = (Get-SerenaVersion $uvVersion.Output)
        ToolPresent = (($tools.Output -join "`n") -match '(?im)^\s*serena-agent(?:\s|$)')
        CliPresent = $null -ne $cli -and $cli.ExitCode -eq 0
        Version = if ($null -ne $cli -and $cli.ExitCode -eq 0) { Get-SerenaVersion $cli.Output } else { '' }
        Initialized = (Test-Path -LiteralPath (Join-Path (Get-SerenaHome) 'serena_config.yml') -PathType Leaf)
        DashboardConfigPresent = $dashboard.DashboardConfigPresent
        DashboardOpenOnLaunch = $dashboard.DashboardOpenOnLaunch
        DashboardConfigStatus = $dashboard.DashboardConfigStatus
    }
}

function Install-SerenaUv {
    [CmdletBinding()]
    param()

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw '找不到 winget，無法以官方 Windows 方式安裝 uv。請先依 https://docs.astral.sh/uv/ 安裝 uv，重新開啟 PowerShell 後重試。' }
    $install = Invoke-SerenaCommand -Command 'winget' -Arguments @('install', '--id', 'astral-sh.uv', '-e', '--accept-source-agreements', '--accept-package-agreements')
    if ($install.ExitCode -ne 0) { throw "uv 官方安裝失敗：$($install.Output -join [Environment]::NewLine)" }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not [string]::IsNullOrWhiteSpace($userPath) -and -not (($env:Path -split ';') -contains ($userPath -split ';' | Select-Object -First 1))) { $env:Path = $userPath + ';' + $env:Path }
    if (-not (Test-SerenaUvAvailable)) { throw 'uv 已安裝，但目前 PowerShell 尚未解析到 uv。請重新開啟 PowerShell 後重跑安裝器。' }
}

$script:SerenaMcpSectionPattern = '(?ms)^\[mcp_servers\.serena\][^\S\r\n]*(?:#[^\r\n]*)?(?:\r?\n|$).*?(?=^\[[^\]]+\][^\r\n]*(?:\r?\n|$)|\z)'

function Get-SerenaMcpSection {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Content)

    $match = [regex]::Match($Content, $script:SerenaMcpSectionPattern)
    if (-not $match.Success) { return '' }
    return $match.Value
}

function Set-SerenaMcpSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$NewLine
    )

    $normalizedSection = ([regex]::Replace($Section, '\r\n|\r|\n', $NewLine)).TrimEnd() + $NewLine
    $match = [regex]::Match($Content, $script:SerenaMcpSectionPattern)
    if ($match.Success) {
        return $Content.Substring(0, $match.Index) + $normalizedSection + $Content.Substring($match.Index + $match.Length)
    }
    if ([string]::IsNullOrEmpty($Content)) { return $normalizedSection }
    $separator = if ($Content.EndsWith($NewLine + $NewLine)) { '' } elseif ($Content.EndsWith($NewLine)) { $NewLine } else { $NewLine + $NewLine }
    return $Content + $separator + $normalizedSection
}

function Set-SerenaMcpTimeouts {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Section, [Parameter(Mandatory = $true)][string]$NewLine)

    $updated = $Section.TrimEnd("`r", "`n")
    foreach ($entry in ([ordered]@{ startup_timeout_sec = 30; tool_timeout_sec = 120 }).GetEnumerator()) {
        $pattern = '(?m)^\s*' + [regex]::Escape($entry.Key) + '\s*=.*$'
        if ([regex]::Matches($updated, $pattern).Count -gt 1) { throw "Serena MCP 設定包含重複的 $($entry.Key)。" }
        if ([regex]::IsMatch($updated, $pattern)) { $updated = [regex]::Replace($updated, $pattern, "$($entry.Key) = $($entry.Value)") }
        else { $updated += $NewLine + "$($entry.Key) = $($entry.Value)" }
    }
    return $updated + $NewLine
}

function Test-SerenaCodexMcpContent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $shape = Get-TomlShape -Content $Content
    if ($shape.Duplicates.Count -gt 0 -or -not $shape.Sections.Contains($script:SerenaMcpSection)) { return $false }
    $section = Get-SerenaMcpSection -Content $Content
    return $section -match '(?m)^\s*command\s*=\s*"serena"\s*$' -and
        $section -match '(?m)^\s*args\s*=\s*\[.*"start-mcp-server".*"--context=codex".*"--project-from-cwd".*\]' -and
        $section -match '(?m)^\s*startup_timeout_sec\s*=\s*30\s*$' -and
        $section -match '(?m)^\s*tool_timeout_sec\s*=\s*120\s*$'
}

function Test-SerenaCodexMcpConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $false }
    return Test-SerenaCodexMcpContent -Content ([IO.File]::ReadAllText($ConfigPath))
}

function Invoke-SerenaCodexSetupInStagingHome {
    [CmdletBinding()]
    param()

    $stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-serena-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    try {
        $previousCodexHome = $env:CODEX_HOME
        try {
            $env:CODEX_HOME = $stagingRoot
            $setup = Invoke-SerenaCommand -Command 'serena' -Arguments @('setup', 'codex')
        } finally {
            $env:CODEX_HOME = $previousCodexHome
        }
        if ($setup.ExitCode -ne 0) { throw "Serena Codex MCP 設定失敗：$($setup.Output -join [Environment]::NewLine)" }
        $stagedConfigPath = Join-Path $stagingRoot 'config.toml'
        $section = Set-SerenaMcpTimeouts -Section (Get-SerenaMcpSection -Content ([IO.File]::ReadAllText($stagedConfigPath))) -NewLine "`n"
        if (-not (Test-SerenaCodexMcpContent -Content $section)) { throw 'Serena MCP 設定驗證失敗：缺少官方 Codex 啟動參數、timeout 或 TOML 結構無效。' }
        return $section
    } finally {
        if (Test-Path -LiteralPath $stagingRoot) { [IO.Directory]::Delete($stagingRoot, $true) }
    }
}

function Invoke-SerenaCodexSetup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)]$Transaction)

    $configPath = Join-Path $Root 'config.toml'
    $before = Get-TextFileState -Path $configPath
    $serenaSection = Invoke-SerenaCodexSetupInStagingHome
    $updatedContent = Set-SerenaMcpSection -Content $before.Content -Section $serenaSection -NewLine $before.NewLine
    if (-not (Test-SerenaCodexMcpContent -Content $updatedContent)) { throw 'Serena MCP 設定驗證失敗：缺少官方 Codex 啟動參數或 TOML 結構無效。' }
    Save-TransactionFile -Transaction $Transaction -Path $configPath
    try {
        Write-TextFileState -Path $configPath -Content $updatedContent -Encoding $before.Encoding
        if (-not (Test-SerenaCodexMcpConfiguration -ConfigPath $configPath)) { throw 'Serena MCP 設定驗證失敗：缺少官方 Codex 啟動參數或 TOML 結構無效。' }
    } catch {
        if ($before.Exists) { Write-TextFileState -Path $configPath -Content $before.Content -Encoding $before.Encoding }
        else { Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue }
        throw
    }
    return 'Configured'
}

function Invoke-SerenaInstallation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)]$Transaction, [switch]$InstallUv)

    if (-not (Test-SerenaUvAvailable)) {
        if (-not $InstallUv) { throw 'Serena 需要 uv。請在互動式流程同意官方 uv 安裝，或先依 https://docs.astral.sh/uv/ 安裝 uv 後重試。' }
        Install-SerenaUv
    }
    $before = Get-SerenaInstallationState
    $action = if ($before.ToolPresent) { 'upgrade' } else { 'install' }
    $arguments = if ($action -eq 'upgrade') { @('tool', 'upgrade', $script:SerenaPackageName) } else { @('tool', 'install', '-p', '3.13', $script:SerenaPackageName) }
    $tool = Invoke-SerenaCommand -Command 'uv' -Arguments $arguments
    $toolFailure = "Serena $action 失敗：$($tool.Output -join [Environment]::NewLine)"
    $upgradeDeferred = $false
    if ($tool.ExitCode -ne 0) {
        $after = if ($action -eq 'upgrade') { try { Get-SerenaInstallationState } catch { $null } } else { $null }
        if ($null -eq $after -or -not $after.ToolPresent -or -not $after.CliPresent -or [string]::IsNullOrWhiteSpace($after.Version)) { throw $toolFailure }
        $upgradeDeferred = $true
    } else {
        $after = Get-SerenaInstallationState
    }
    if (-not $after.CliPresent -or [string]::IsNullOrWhiteSpace($after.Version)) { throw 'Serena 安裝後驗證失敗：serena --version 無法成功執行或解析版本。' }
    $initializationStatus = if ($before.Initialized) { 'Existing' } else {
        $init = Invoke-SerenaCommand -Command 'serena' -Arguments @('init')
        if ($init.ExitCode -ne 0) { throw "Serena 初始化失敗：$($init.Output -join [Environment]::NewLine)" }
        if (-not (Test-Path -LiteralPath (Join-Path (Get-SerenaHome) 'serena_config.yml') -PathType Leaf)) { throw 'Serena init 未建立預期的全域設定檔。' }
        'Initialized'
    }
    $dashboard = Set-SerenaDashboardConfiguration -Transaction $Transaction
    $mcpStatus = Invoke-SerenaCodexSetup -Root $Root -Transaction $Transaction
    if ((Get-SerenaConfigurationState).DashboardConfigStatus -ne 'Disabled') { throw 'Serena Codex MCP 設定後，Dashboard 不再是 Disabled。' }
    return [pscustomobject]@{
        Managed = $true
        SelectedByUser = $true
        UvAvailable = $true
        UvVersion = $after.UvVersion
        VersionBefore = $before.Version
        VersionAfter = $after.Version
        InstalledNow = -not $before.ToolPresent
        UpdatedNow = -not $upgradeDeferred -and $before.ToolPresent -and (($tool.Output -join "`n") -notmatch '(?i)unchanged|already up.to.date|current')
        ToolStatus = if ($upgradeDeferred) { 'UpgradeDeferred' } elseif (-not $before.ToolPresent) { 'Installed' } elseif (($tool.Output -join "`n") -match '(?i)unchanged|already up.to.date|current') { 'Current' } else { 'Updated' }
        InitializationStatus = $initializationStatus
        DashboardStatus = 'Disabled'
        DashboardAutoOpenStatus = 'Disabled'
        DashboardConfigStatus = $dashboard.Status
        CodexMcpStatus = $mcpStatus
        RuntimeStatus = 'RestartRequired'
    }
}

function Invoke-SerenaUninstall([string]$Root, $Transaction) {
    $configPath = Join-Path $Root 'config.toml'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $state = Get-TextFileState -Path $configPath
        $content = [regex]::Replace($state.Content, $script:SerenaMcpSectionPattern, '').TrimEnd()
        if ($content -ne $state.Content.TrimEnd()) {
            Save-TransactionFile -Transaction $Transaction -Path $configPath
            Write-TextFileState -Path $configPath -Content $(if ($content) { $content + $state.NewLine } else { '' }) -Encoding $state.Encoding
        }
    }
    $before = Get-SerenaInstallationState
    if ($before.ToolPresent) {
        $remove = Invoke-SerenaCommand -Command 'uv' -Arguments @('tool', 'uninstall', $script:SerenaPackageName)
        if ($remove.ExitCode -ne 0) { throw "Serena 解除安裝失敗：$($remove.Output -join [Environment]::NewLine)" }
    }
    $result = New-SerenaSkippedResult
    $result.ToolStatus = $(if ($before.ToolPresent) { 'Uninstalled' } else { 'Unchanged' })
    $result.CodexMcpStatus = 'Uninstalled'
    return $result
}
