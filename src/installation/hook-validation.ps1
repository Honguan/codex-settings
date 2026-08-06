function Remove-GlobalLineEndingHooks([string]$Root, $Transaction) {
    $hooksPath = Join-Path $Root 'hooks.json'
    if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
        $state = Get-TextFileState $hooksPath
        $cleaned = Remove-ManagedLineEndingHooksJson -Content $state.Content
        if ($cleaned -ne $state.Content) {
            Save-TransactionFile -Transaction $Transaction -Path $hooksPath
            Write-TextFileState -Path $hooksPath -Content $cleaned -Encoding $state.Encoding
        }
    }

    foreach ($scriptName in @('crlf-updated-files.ps1', 'normalize-cvs-crlf.ps1', 'preserve-line-endings.ps1')) {
        $scriptPath = Join-Path $Root ("hooks\$scriptName")
        if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
            Save-TransactionFile -Transaction $Transaction -Path $scriptPath
            Remove-Item -LiteralPath $scriptPath -Force
        }
    }
    $hooksRoot = Join-Path $Root 'hooks'
    if ((Test-Path -LiteralPath $hooksRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $hooksRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $hooksRoot -Force
    }
}

function Assert-GlobalLineEndingHook([ValidateSet('Git', 'CVS')][string]$DevelopmentEnvironment, [string]$Root, [bool]$InstallWindowsNotifications, [bool]$InstallTokenUsageInterface) {
    $hooksPath = Join-Path $Root 'hooks.json'
    $hookContent = if (Test-Path -LiteralPath $hooksPath -PathType Leaf) { [IO.File]::ReadAllText($hooksPath) } else { '' }
    $trackHookCount = 0
    $restoreHookCount = 0
    $finalizeHookCount = 0
    $legacyHookCount = 0
    $notificationQuestionHookCount = 0
    $notificationPermissionHookCount = 0
    $notificationCompletedHookCount = 0
    $tokenUsageHookCount = 0
    if (-not [string]::IsNullOrWhiteSpace($hookContent)) {
        $hookObject = $hookContent | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $hookObject.hooks) {
            foreach ($property in @($hookObject.hooks.PSObject.Properties)) {
                foreach ($entry in @($property.Value)) {
                    $entryJson = $entry | ConvertTo-Json -Depth 20 -Compress
                    if ($entryJson -match $script:PreserveLineEndingHookSignaturePattern) {
                        if ($property.Name -eq 'PreToolUse') { $trackHookCount++ }
                        if ($property.Name -eq 'PostToolUse') { $restoreHookCount++ }
                        if ($property.Name -eq 'Stop') { $finalizeHookCount++ }
                    }
                    if ($entryJson -match $script:LegacyCrlfHookSignaturePattern) { $legacyHookCount++ }
                    if ($entryJson -match $script:ManagedNotificationHookSignaturePattern) {
                        if ($property.Name -eq 'PreToolUse') { $notificationQuestionHookCount++ }
                        if ($property.Name -eq 'PermissionRequest') { $notificationPermissionHookCount++ }
                        if ($property.Name -eq 'Stop') { $notificationCompletedHookCount++ }
                    }
                    if ($property.Name -eq 'Stop' -and $entryJson -match $script:ManagedTokenUsageHookSignaturePattern) { $tokenUsageHookCount++ }
                }
            }
        }
    }
    $preserveScriptCount = if (Test-Path -LiteralPath (Join-Path $Root 'hooks\preserve-line-endings.ps1') -PathType Leaf) { 1 } else { 0 }
    $notificationScriptCount = if (Test-Path -LiteralPath (Join-Path $Root 'hooks\show-codex-notification.ps1') -PathType Leaf) { 1 } else { 0 }
    $tokenUsageScriptCount = if (Test-Path -LiteralPath (Join-Path $Root 'hooks\show-turn-token-usage.ps1') -PathType Leaf) { 1 } else { 0 }
    $expectedNotificationCount = if ($InstallWindowsNotifications) { 1 } else { 0 }
    $expectedTokenUsageCount = if ($InstallTokenUsageInterface) { 1 } else { 0 }
    if ($notificationQuestionHookCount -ne $expectedNotificationCount -or $notificationPermissionHookCount -ne $expectedNotificationCount -or $notificationCompletedHookCount -ne $expectedNotificationCount -or $notificationScriptCount -ne $expectedNotificationCount) {
        throw "Windows 通知安裝檢查失敗：Expected=$expectedNotificationCount QuestionHookCount=$notificationQuestionHookCount PermissionHookCount=$notificationPermissionHookCount CompletedHookCount=$notificationCompletedHookCount NotificationScriptCount=$notificationScriptCount"
    }
    if ($tokenUsageHookCount -ne $expectedTokenUsageCount -or $tokenUsageScriptCount -ne $expectedTokenUsageCount) {
        throw "每輪 Token 統計安裝檢查失敗：Expected=$expectedTokenUsageCount TokenUsageHookCount=$tokenUsageHookCount TokenUsageScriptCount=$tokenUsageScriptCount"
    }
    if ($DevelopmentEnvironment -eq 'CVS') {
        if ($trackHookCount -ne 1 -or $restoreHookCount -ne 1 -or $finalizeHookCount -ne 1 -or $preserveScriptCount -ne 1 -or $legacyHookCount -ne 0) {
            throw "CVS 換行保護安裝檢查失敗：TrackHookCount=$trackHookCount RestoreHookCount=$restoreHookCount FinalizeHookCount=$finalizeHookCount PreserveLineEndingScriptCount=$preserveScriptCount LegacyCrlfHookCount=$legacyHookCount"
        }
    } elseif ($trackHookCount -ne 0 -or $restoreHookCount -ne 0 -or $finalizeHookCount -ne 0 -or $preserveScriptCount -ne 0 -or $legacyHookCount -ne 0) {
        throw 'Git 全域設定仍包含 CVS 換行保護 Hook。'
    }
}
