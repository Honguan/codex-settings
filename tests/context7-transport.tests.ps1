$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$templateContent = [IO.File]::ReadAllText((Join-Path $script:ScriptRoot 'templates\core\config.toml'))
$canonical = (Get-Context7McpTransportState -Content $templateContent).Section.Value.TrimEnd("`r", "`n")
$startMarker = '# >>> CODEX-SETTINGS:Global:CONFIG >>>'
$endMarker = '# <<< CODEX-SETTINGS:Global:CONFIG <<<'

function Merge-TestContext7([string]$Content) {
    return Merge-Context7McpTemplate -ExistingContent $Content -TemplateContent $canonical -StartMarker $startMarker -EndMarker $endMarker -NewLine "`r`n"
}

function Assert-CanonicalContext7([string]$Content) {
    $state = Get-Context7McpTransportState -Content $Content
    if ($state.State -ne 'CurrentRemoteHttp' -or -not $state.HasUrl -or $state.HasCommand -or $state.HasArgs -or $state.HasStdioEnvironmentFields) {
        throw "Context7 is not canonical HTTP: $(Format-Context7McpDiagnostic $state)"
    }
    foreach ($expected in @('enabled = true', 'startup_timeout_sec = 20', 'tool_timeout_sec = 60', 'env_http_headers = { "CONTEXT7_API_KEY" = "CONTEXT7_API_KEY" }')) {
        if (-not $Content.Contains($expected)) { throw "Canonical Context7 setting is missing: $expected" }
    }
}

$fresh = Merge-TestContext7 'user_setting = true'
Assert-CanonicalContext7 $fresh
if (-not $fresh.Contains('user_setting = true')) { throw 'Fresh Context7 installation removed a top-level user setting.' }

$current = $canonical + "`r`n"
if ((Merge-TestContext7 $current) -ne $current) { throw 'Current canonical Context7 configuration was unnecessarily rewritten.' }

$legacySecret = 'secret-must-not-leak'
$legacy = @"
user_setting = true

[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp"]
env_vars = { "CONTEXT7_API_KEY" = "$legacySecret" }

# Preserve this unrelated MCP comment.
[mcp_servers.other]
command = "other"
"@
$legacyState = Get-Context7McpTransportState -Content $legacy
if ($legacyState.State -ne 'LegacyStdio' -or -not $legacyState.MigrationRequired) { throw 'Known legacy Context7 STDIO was not discovered as a migration.' }
$migrated = Merge-TestContext7 $legacy
Assert-CanonicalContext7 $migrated
if ($migrated.Contains($legacySecret) -or -not $migrated.Contains('# Preserve this unrelated MCP comment.') -or -not $migrated.Contains('[mcp_servers.other]') -or -not $migrated.Contains('user_setting = true')) { throw 'Legacy migration leaked a secret or changed unrelated configuration.' }

foreach ($mixed in @(
    "[mcp_servers.context7]`r`ncommand = `"npx`"`r`nargs = [`"-y`", `"@upstash/context7-mcp`"]`r`nurl = `"https://mcp.context7.com/mcp`"`r`n",
    "[mcp_servers.context7]`r`ncommand = `"npx`"`r`nurl = `"https://mcp.context7.com/mcp`"`r`nenv_http_headers = { `"CONTEXT7_API_KEY`" = `"CONTEXT7_API_KEY`" }`r`n"
)) {
    $before = Get-Context7McpTransportState -Content $mixed
    if ($before.State -ne 'MixedInvalidTransport' -or $before.ValidationReason -ne 'url-is-not-supported-for-stdio' -or -not $before.RepairRequired) { throw 'Known invalid mixed transport was not discovered as repairable.' }
    Assert-CanonicalContext7 (Merge-TestContext7 $mixed)
}

$outdatedRemote = "[mcp_servers.context7]`r`nurl = `"https://mcp.context7.com/mcp`"`r`n"
if ((Get-Context7McpTransportState -Content $outdatedRemote).State -ne 'RemoteNeedsUpdate') { throw 'Known outdated remote Context7 was not discovered.' }
Assert-CanonicalContext7 (Merge-TestContext7 $outdatedRemote)

$customStdio = "[mcp_servers.context7]`r`ncommand = `"custom-proxy`"`r`nargs = [`"serve`"]`r`n"
$customRemote = "[mcp_servers.context7]`r`nurl = `"https://context7.example.test/mcp`"`r`nhttp_headers = { `"X-Custom`" = `"value`" }`r`n"
$customOfficialUrl = "[mcp_servers.context7]`r`nurl = `"https://mcp.context7.com/mcp`"`r`nhttp_headers = { `"X-Custom`" = `"value`" }`r`n"
foreach ($custom in @($customStdio, $customRemote, $customOfficialUrl)) {
    $merged = Merge-TestContext7 $custom
    if (-not $merged.Contains($custom.Trim()) -or ([regex]::Matches($merged, '(?m)^\[mcp_servers\.context7\]\s*$').Count -ne 1)) { throw 'User-owned Context7 transport was changed or duplicated.' }
}

$customMixedSecret = 'do-not-print-this-secret'
$customMixed = "[mcp_servers.context7]`r`ncommand = `"custom-proxy`"`r`nurl = `"https://context7.example.test/mcp`"`r`nenv = { `"TOKEN`" = `"$customMixedSecret`" }`r`n"
try {
    Merge-TestContext7 $customMixed | Out-Null
    throw 'User-owned mixed Context7 transport did not fail safely.'
} catch {
    $message = $_.Exception.Message
    foreach ($field in @('context7State=UserOwnedConflict', 'transportDetected=Mixed', 'hasUrl=True', 'hasCommand=True', 'validationReason=url-is-not-supported-for-stdio')) {
        if (-not $message.Contains($field)) { throw "Context7 conflict diagnostic is missing: $field" }
    }
    if ($message.Contains($customMixedSecret)) { throw 'Context7 conflict diagnostic exposed a secret.' }
}

$twice = Merge-TestContext7 $migrated
if ($twice -ne $migrated) { throw 'Context7 migration is not idempotent.' }

$duplicate = $canonical + "`r`n`r`n" + $canonical
try { Merge-TestContext7 $duplicate | Out-Null; throw 'Duplicate Context7 tables did not fail safely.' } catch {
    if (-not $_.Exception.Message.Contains('duplicate-context7-sections')) { throw }
}
$duplicateKey = $canonical.Replace('enabled = true', "enabled = true`r`nenabled = false")
try { Merge-TestContext7 $duplicateKey | Out-Null; throw 'Duplicate Context7 keys did not fail safely.' } catch {
    if (-not $_.Exception.Message.Contains('duplicate-context7-keys')) { throw }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-context7-' + [guid]::NewGuid().ToString('N'))
try {
    $globalRoot = Join-Path $testRoot '.codex'
    New-Item -ItemType Directory -Path $globalRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $globalRoot 'config.toml'), $legacy, [Text.UTF8Encoding]::new($false))
    $transaction = New-FileTransaction -Root (Join-Path $testRoot 'transaction') -Mode 'Context7Test'
    $target = New-InstallTarget -Id 'context7-global' -Mode 'Global' -TemplateRoot (Join-Path $script:ScriptRoot 'templates\core') -EnvironmentTemplateRoot (Join-Path $script:ScriptRoot 'templates\environments\git') -DevelopmentEnvironment Git -Root $globalRoot -InstallWindowsNotifications $false -SourceRoot $script:ScriptRoot
    $result = Invoke-TargetInstallation -Target $target -Transaction $transaction
    Complete-FileTransaction -Transaction $transaction
    $installed = [IO.File]::ReadAllText((Join-Path $globalRoot 'config.toml'))
    Assert-CanonicalContext7 $installed
    if (-not $installed.Contains('[mcp_servers.other]') -or -not $installed.Contains('user_setting = true') -or -not (@($result.Files | Where-Object Path -eq 'config.toml')[0].Changed)) { throw 'Windows global installation did not preserve unrelated configuration while repairing Context7.' }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Context7 MCP transport reconciliation tests passed.'
