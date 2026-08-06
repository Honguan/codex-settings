$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$hookScript = Join-Path $repositoryRoot 'src\templates\core\hooks\show-turn-token-usage.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-token-usage-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $testRoot 'state'
$snapshotPath = Join-Path $testRoot 'snapshot.json'
$mockPath = Join-Path $testRoot 'mock-ccsessions.ps1'

function Set-Snapshot([string]$SessionId, [long]$InputTokens, [long]$CachedInputTokens, [long]$OutputTokens, [long]$TotalTokens, [decimal]$CostUsd, [string[]]$Models = @('gpt-5.6-sol')) {
    $value = [ordered]@{ success = $true; sessionId = $SessionId; models = $Models; inputTokens = $InputTokens; cachedInputTokens = $CachedInputTokens; outputTokens = $OutputTokens; totalTokens = $TotalTokens; costUsd = $CostUsd }
    [IO.File]::WriteAllText($snapshotPath, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}

function Invoke-TokenHook([string]$SessionId, [string]$TurnId) {
    $inputText = [ordered]@{ session_id = $SessionId; turn_id = $TurnId; cwd = $repositoryRoot; hook_event_name = 'Stop'; stop_hook_active = $false } | ConvertTo-Json -Compress
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $hookScript)) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Write($inputText)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Token Hook 失敗：exit=$($process.ExitCode) stderr=$stderr" }
    try { return $stdout | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Token Hook 輸出不是有效 JSON：$stdout" }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    [IO.File]::WriteAllText($mockPath, "param([string]`$SessionId)`r`nGet-Content -LiteralPath `$env:CODEX_SETTINGS_CCSESSIONS_SNAPSHOT -Raw`r`n", [Text.UTF8Encoding]::new($false))
    $env:CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT = $stateRoot
    $env:CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND = $mockPath
    $env:CODEX_SETTINGS_CCSESSIONS_SNAPSHOT = $snapshotPath

    $sessionA = '019fd65b-39b0-7d60-99fc-deb09469413b'
    Set-Snapshot -SessionId $sessionA -InputTokens 120000 -CachedInputTokens 80000 -OutputTokens 12000 -TotalTokens 212000 -CostUsd 0.18
    $first = Invoke-TokenHook -SessionId $sessionA -TurnId 'turn-1'
    if ($first.systemMessage -notmatch 'Token usage since session start' -or $first.systemMessage -notmatch '120,000' -or $first.systemMessage -notmatch '019fd65b\.\.\.69413b') { throw '新 Session 第一輪未顯示完整累積用量。' }

    $duplicate = Invoke-TokenHook -SessionId $sessionA -TurnId 'turn-1-duplicate'
    if (@($duplicate.PSObject.Properties).Count -ne 0) { throw '相同用量 snapshot 被重複顯示。' }

    Set-Snapshot -SessionId $sessionA -InputTokens 145000 -CachedInputTokens 96000 -OutputTokens 15500 -TotalTokens 256500 -CostUsd 0.22 -Models @('gpt-5.6-sol', 'gpt-5.6-terra')
    $second = Invoke-TokenHook -SessionId $sessionA -TurnId 'turn-2'
    foreach ($expected in @('Turn token usage', '+25,000', '+16,000', '+3,500', '+44,500', '+$0.04', 'gpt-5.6-sol, gpt-5.6-terra')) {
        if (-not $second.systemMessage.Contains($expected)) { throw "第二輪差值缺少：$expected" }
    }

    $sessionB = '019fd65b-39b0-7d60-99fc-deb094699999'
    Set-Snapshot -SessionId $sessionB -InputTokens 10 -CachedInputTokens 2 -OutputTokens 3 -TotalTokens 15 -CostUsd 0.001
    $other = Invoke-TokenHook -SessionId $sessionB -TurnId 'turn-b1'
    if ($other.systemMessage -notmatch 'Token usage since session start') { throw '不同 Session 未使用獨立基準。' }
    $sessionStates = @(Get-ChildItem -LiteralPath $stateRoot -Filter '*.json' | Where-Object Name -ne 'settings.json')
    if ($sessionStates.Count -ne 2) { throw "多 Session 狀態檔數量錯誤：$($sessionStates.Count)" }

    $stateA = @($sessionStates | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).sessionId -eq $sessionA })[0]
    [IO.File]::WriteAllText($stateA.FullName, '{invalid', [Text.UTF8Encoding]::new($false))
    Set-Snapshot -SessionId $sessionA -InputTokens 150000 -CachedInputTokens 97000 -OutputTokens 16000 -TotalTokens 263000 -CostUsd 0.23
    $rebuilt = Invoke-TokenHook -SessionId $sessionA -TurnId 'turn-3'
    if ($rebuilt.systemMessage -notmatch 'Token usage since session start' -or @(Get-ChildItem -LiteralPath $stateRoot -Filter '*.corrupt-*').Count -ne 1) { throw '損壞狀態未備份並重建。' }

    $settingsPath = Join-Path $stateRoot 'settings.json'
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $settings.enabled = $false
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $disabled = Invoke-TokenHook -SessionId $sessionA -TurnId 'turn-4'
    if (@($disabled.PSObject.Properties).Count -ne 0) { throw '停用 Token 統計後仍顯示內容。' }

    Write-Host 'Turn token usage hook tests passed.'
} finally {
    Remove-Item Env:\CODEX_SETTINGS_TOKEN_USAGE_STATE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_TEST_COMMAND -ErrorAction SilentlyContinue
    Remove-Item Env:\CODEX_SETTINGS_CCSESSIONS_SNAPSHOT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
