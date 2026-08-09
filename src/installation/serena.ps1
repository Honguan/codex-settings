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

function Get-SerenaInstallationState {
    [CmdletBinding()]
    param()

    if (-not (Test-SerenaUvAvailable)) {
        return [pscustomobject]@{ UvAvailable = $false; UvVersion = ''; ToolPresent = $false; CliPresent = $false; Version = ''; Initialized = (Test-Path -LiteralPath (Join-Path (Get-SerenaHome) 'serena_config.yml') -PathType Leaf) }
    }
    $uvVersion = Invoke-SerenaCommand -Command 'uv' -Arguments @('--version')
    if ($uvVersion.ExitCode -ne 0) { throw "無法執行 uv --version：$($uvVersion.Output -join [Environment]::NewLine)" }
    $tools = Invoke-SerenaCommand -Command 'uv' -Arguments @('tool', 'list')
    if ($tools.ExitCode -ne 0) { throw "無法讀取 uv tool 狀態：$($tools.Output -join [Environment]::NewLine)" }
    $cli = if ($null -ne (Get-Command serena -ErrorAction SilentlyContinue)) { Invoke-SerenaCommand -Command 'serena' -Arguments @('--version') } else { $null }
    return [pscustomobject]@{
        UvAvailable = $true
        UvVersion = (Get-SerenaVersion $uvVersion.Output)
        ToolPresent = (($tools.Output -join "`n") -match '(?im)^\s*serena-agent(?:\s|$)')
        CliPresent = $null -ne $cli -and $cli.ExitCode -eq 0
        Version = if ($null -ne $cli -and $cli.ExitCode -eq 0) { Get-SerenaVersion $cli.Output } else { '' }
        Initialized = (Test-Path -LiteralPath (Join-Path (Get-SerenaHome) 'serena_config.yml') -PathType Leaf)
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

function Remove-SerenaMcpSection {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Content)

    $pattern = '(?ms)^\[mcp_servers\.serena\]\s*\r?\n.*?(?=^\[[^\]]+\]|\z)'
    return [regex]::Replace($Content, $pattern, '').Trim()
}

function Test-SerenaCodexMcpConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $false }
    $content = Get-Content -LiteralPath $ConfigPath -Raw
    $shape = Get-TomlShape -Content $content
    if ($shape.Duplicates.Count -gt 0 -or -not $shape.Sections.Contains($script:SerenaMcpSection)) { return $false }
    $section = [regex]::Match($content, '(?ms)^\[mcp_servers\.serena\]\s*\r?\n(.*?)(?=^\[[^\]]+\]|\z)').Groups[1].Value
    return $section -match '(?m)^\s*command\s*=\s*"serena"\s*$' -and $section -match '(?m)^\s*args\s*=\s*\[.*"start-mcp-server".*"--context=codex".*"--project-from-cwd".*\]'
}

function Invoke-SerenaCodexSetup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)]$Transaction)

    $configPath = Join-Path $Root 'config.toml'
    $before = Get-TextFileState -Path $configPath
    Save-TransactionFile -Transaction $Transaction -Path $configPath
    $previousCodexHome = $env:CODEX_HOME
    try {
        $env:CODEX_HOME = $Root
        $setup = Invoke-SerenaCommand -Command 'serena' -Arguments @('setup', 'codex')
    } finally {
        $env:CODEX_HOME = $previousCodexHome
    }
    if ($setup.ExitCode -ne 0) { throw "Serena Codex MCP 設定失敗：$($setup.Output -join [Environment]::NewLine)" }
    $after = Get-TextFileState -Path $configPath
    if ((Remove-SerenaMcpSection $before.Content) -ne (Remove-SerenaMcpSection $after.Content)) {
        Write-TextFileState -Path $configPath -Content $before.Content -Encoding $before.Encoding
        throw 'serena setup codex 嘗試修改非 Serena MCP 設定；已還原 config.toml。'
    }
    if (-not (Test-SerenaCodexMcpConfiguration -ConfigPath $configPath)) { throw 'Serena MCP 設定驗證失敗：缺少官方 Codex 啟動參數或 TOML 結構無效。' }
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
    if ($tool.ExitCode -ne 0) { throw "Serena $action 失敗：$($tool.Output -join [Environment]::NewLine)" }
    $after = Get-SerenaInstallationState
    if (-not $after.CliPresent -or [string]::IsNullOrWhiteSpace($after.Version)) { throw 'Serena 安裝後驗證失敗：serena --version 無法成功執行或解析版本。' }
    $initializationStatus = if ($before.Initialized) { 'Existing' } else {
        $init = Invoke-SerenaCommand -Command 'serena' -Arguments @('init')
        if ($init.ExitCode -ne 0) { throw "Serena 初始化失敗：$($init.Output -join [Environment]::NewLine)" }
        if (-not (Test-Path -LiteralPath (Join-Path (Get-SerenaHome) 'serena_config.yml') -PathType Leaf)) { throw 'Serena init 未建立預期的全域設定檔。' }
        'Initialized'
    }
    $mcpStatus = Invoke-SerenaCodexSetup -Root $Root -Transaction $Transaction
    return [pscustomobject]@{
        Managed = $true
        SelectedByUser = $true
        UvAvailable = $true
        UvVersion = $after.UvVersion
        VersionBefore = $before.Version
        VersionAfter = $after.Version
        InstalledNow = -not $before.ToolPresent
        UpdatedNow = $before.ToolPresent -and (($tool.Output -join "`n") -notmatch '(?i)unchanged|already up.to.date|current')
        ToolStatus = if (-not $before.ToolPresent) { 'Installed' } elseif (($tool.Output -join "`n") -match '(?i)unchanged|already up.to.date|current') { 'Current' } else { 'Updated' }
        InitializationStatus = $initializationStatus
        CodexMcpStatus = $mcpStatus
        RuntimeStatus = 'RestartRequired'
    }
}
