$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-architecture-' + [guid]::NewGuid().ToString('N'))
try {
    $inputObject = [pscustomobject]@{
        hook_event_name = 'Stop'
        session_id = 'session-contract'
        turn_id = 'turn-contract'
        cwd = $testRoot
        tool_name = 'exec'
        tool_input = [pscustomobject]@{ command = 'Get-Content README.md' }
    }
    $invocation = New-HookInvocationContext -InputObject $inputObject -HookSource 'global'
    if (-not (Test-CodexSettingsContract -InputObject $invocation -Kind HookInvocationContext) -or $invocation.eventName -ne 'Stop' -or $invocation.sessionId -ne 'session-contract') {
        throw 'HookInvocationContext contract normalization failed.'
    }

    $descriptor = New-HookHandlerDescriptor -ManagedId 'codex-settings' -HandlerId 'completed-token-toast' -Kind notification -EventName Stop -Command 'show-codex-notification.ps1'
    if (-not (Test-CodexSettingsContract -InputObject $descriptor -Kind HookHandlerDescriptor) -or $descriptor.handlerId -ne 'completed-token-toast') {
        throw 'HookHandlerDescriptor contract failed.'
    }

    $snapshot = New-UsageSnapshot -SessionId 'session-contract' -Source ccsessions -Models @('gpt-5') -InputTokens 10 -OutputTokens 5 -ReasoningTokens 1 -CacheReadTokens 2 -TotalTokens 18 -CostUsd 0.01 -PresentFields @('inputTokens', 'outputTokens')
    $delta = New-UsageDelta -Current $snapshot -Previous (New-UsageSnapshot -SessionId 'session-contract' -Source ccsessions -InputTokens 4 -OutputTokens 2 -ReasoningTokens 1 -CacheReadTokens 1 -TotalTokens 8 -CostUsd 0.005)
    if (-not (Test-CodexSettingsContract -InputObject $snapshot -Kind UsageSnapshot) -or -not (Test-CodexSettingsContract -InputObject $delta -Kind UsageDelta) -or $delta.inputTokens -ne 6) {
        throw 'UsageSnapshot/UsageDelta contract failed.'
    }

    $fileState = New-LineEndingFileState -Path (Join-Path $testRoot 'sample.txt') -Length 10 -LineEnding CRLF -PreferredLineEnding CRLF -FinalNewline $true
    if (-not (Test-CodexSettingsContract -InputObject $fileState -Kind LineEndingFileState) -or $fileState.preferredLineEnding -ne 'CRLF') {
        throw 'LineEndingFileState contract failed.'
    }

    $target = New-InstallTarget -Id 'contract-target' -Mode Global -Root $testRoot -TemplateRoot $script:ScriptRoot -DevelopmentEnvironment Git -SourceRoot $script:ScriptRoot
    foreach ($propertyName in @('schemaVersion', 'id', 'mode', 'root', 'templateRoot', 'environmentTemplateRoot', 'developmentEnvironment', 'cwd', 'installWindowsNotifications', 'enableDefaultModeRequestUserInput', 'longRunningAsyncWaitAction')) {
        if ($target.PSObject.Properties.Name -notcontains $propertyName) { throw "InstallTarget 缺少欄位：$propertyName" }
    }
    if (-not (Test-CodexSettingsContract -InputObject $target -Kind InstallTarget)) { throw 'InstallTarget contract failed.' }

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $state = Write-CodexSettingsState -Kind 'contract-state' -Key 'one' -Root $testRoot -Payload ([ordered]@{ value = 1 })
    $read = Read-CodexSettingsState -Kind 'contract-state' -Key 'one' -Root $testRoot
    if (-not (Test-CodexSettingsContract -InputObject $state -Kind StateEnvelope) -or $read.payload.value -ne 1) { throw 'State repository read/write failed.' }
    $updated = Update-CodexSettingsState -Kind 'contract-state' -Key 'one' -Root $testRoot -Update { param($payload, $envelope) $payload.value = [int]$payload.value + 1; return $payload }
    if ($updated.payload.value -ne 2) { throw 'State repository update failed.' }
    $corruptPath = Get-CodexSettingsStatePath -Kind 'corrupt-state' -Key 'one' -Root $testRoot
    New-Item -ItemType Directory -Path (Split-Path -Parent $corruptPath) -Force | Out-Null
    [IO.File]::WriteAllText($corruptPath, '{invalid', [Text.UTF8Encoding]::new($false))
    $recovered = Read-CodexSettingsState -Kind 'corrupt-state' -Key 'one' -Root $testRoot -DefaultPayload ([ordered]@{ recovered = $true })
    if (-not [bool]$recovered.payload.recovered) { throw 'Corrupt state recovery failed.' }

    $hooks = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'templates\core\hooks.json') -Raw | ConvertFrom-Json
    if ($null -ne $hooks.hooks.PSObject.Properties['Stop']) { throw 'Completed notification must not use generic Stop.' }
    $notificationConfig = Merge-WindowsNotificationCommandConfig -Content '' -Root 'C:\Users\fixture\.codex'
    if (-not (Test-WindowsNotificationCommandConfig -Content $notificationConfig -Root 'C:\Users\fixture\.codex') -or $notificationConfig -notmatch 'notify\s*=.*Completed') { throw 'Canonical agent-turn-complete notification config is invalid.' }

    $runtimeCore = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'templates\core\hooks\runtime-core.ps1') -Raw
    $notificationSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'templates\core\hooks\show-codex-notification.ps1') -Raw
    $lineEndingSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'templates\environments\cvs\hooks\preserve-line-endings.ps1') -Raw
    $usageSource = Get-Content -LiteralPath (Join-Path $script:ScriptRoot 'templates\profile\usage-commands.ps1') -Raw
    foreach ($expected in @('Read-CodexHookInvocation', 'Write-CodexHookState', 'Get-CodexHookInvocationCounts', 'Get-CodexToolImpactClassification', 'Test-CodexMainSession')) {
        if ($runtimeCore -notmatch [regex]::Escape($expected)) { throw "Runtime core 缺少函式：$expected" }
    }
    if ($notificationSource -notmatch 'runtime-core\.ps1' -or $lineEndingSource -notmatch 'runtime-core\.ps1') { throw 'Hook entrypoint 未載入共用 runtime core。' }
    . (Join-Path $script:ScriptRoot 'templates\core\hooks\runtime-core.ps1')
    $hookState = Write-CodexHookState -Kind 'contract-hook-state' -Key 'one' -Root (Join-Path $testRoot 'hook-state') -Payload ([ordered]@{ value = 1 })
    $hookStateRead = Read-CodexHookState -Kind 'contract-hook-state' -Key 'one' -Root (Join-Path $testRoot 'hook-state')
    if ($hookState.payload.value -ne 1 -or $hookStateRead.payload.value -ne 1) { throw 'Lazy Hook state runtime read/write failed.' }
    foreach ($expected in @('New-CodexUsageQuery', 'Invoke-CodexUsageQuery', 'Resolve-CodexUsageBackend')) {
        if ($usageSource -notmatch [regex]::Escape($expected)) { throw "Usage query layer 缺少函式：$expected" }
    }

    Write-Host 'Architecture contract tests passed.'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
