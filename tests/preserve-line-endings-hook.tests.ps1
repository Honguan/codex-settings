$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$hookScript = Join-Path $repositoryRoot 'src\templates\environments\cvs\hooks\preserve-line-endings.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-line-endings-' + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $testRoot 'project'
$stateRoot = Join-Path $testRoot 'state'
$diagnosticRoot = Join-Path $testRoot 'logs'

function Write-TestBytes([string]$Name, [byte[]]$Bytes) {
    $path = Join-Path $projectRoot $Name
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllBytes($path, $Bytes)
}

function Assert-Bytes([string]$Name, [byte[]]$Expected) {
    $actual = [IO.File]::ReadAllBytes((Join-Path $projectRoot $Name))
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$actual, [byte[]]$Expected)) { throw "位元組內容不符：$Name" }
}

function Invoke-Hook([ValidateSet('Track', 'Restore', 'Finalize')][string]$Mode, [string]$SessionId, [string]$InputText) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $hookScript, '-Mode', $Mode)) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['CODEX_SETTINGS_LINE_ENDING_STATE_ROOT'] = $stateRoot
    $startInfo.Environment['CODEX_SETTINGS_HOOK_LOG_ROOT'] = $diagnosticRoot
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Write($InputText)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "$Mode Hook 結束碼不是 0：$($process.ExitCode) - $stderr" }
    try { $output = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { throw "$Mode Hook stdout 不是合法 JSON：$stdout" }
    return [pscustomobject]@{ Output = $output; Stdout = $stdout; Stderr = $stderr }
}

function New-HookInput([string]$EventName, [string]$SessionId, [string]$ToolName = 'apply_patch', [string]$Command = '*** Begin Patch') {
    return ([ordered]@{
        session_id = $SessionId
        cwd = $projectRoot
        hook_event_name = $EventName
        tool_name = $ToolName
        tool_input = [ordered]@{ command = $Command }
    } | ConvertTo-Json -Depth 5 -Compress)
}

try {
    $hooksTemplate = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\templates\environments\cvs\hooks.json') -Raw | ConvertFrom-Json
    foreach ($eventName in @('PreToolUse', 'PostToolUse')) {
        $entry = @($hooksTemplate.hooks.$eventName)[0]
        if ($entry.matcher -ne '*' -or $entry.hooks[0].PSObject.Properties.Name -contains 'statusMessage') { throw "$eventName matcher 或 UI 狀態設定錯誤。" }
    }
    if (@($hooksTemplate.hooks.Stop)[0].hooks[0].PSObject.Properties.Name -contains 'statusMessage') { throw 'Stop Hook 不應持續顯示執行狀態。' }

    New-Item -ItemType Directory -Path (Join-Path $testRoot 'CVS'), (Join-Path $projectRoot 'CVS'), $stateRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $testRoot 'CVS\Entries'), '', [Text.Encoding]::ASCII)
    $trackedFiles = @('crlf.txt', 'lf.txt', 'mixed.txt', 'no-final.txt', 'with-final.txt', 'utf8-bom.txt', 'ansi.txt', 'unchanged.txt', 'binary.bin', '.codex\ignored.txt')
    $entries = @($trackedFiles | Where-Object { $_ -notmatch '\\' } | ForEach-Object { "/$_/1.1///" }) + 'D/.codex////'
    [IO.File]::WriteAllLines((Join-Path $projectRoot 'CVS\Entries'), $entries, [Text.Encoding]::ASCII)

    Write-TestBytes 'crlf.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nend`r`n"))
    Write-TestBytes 'lf.txt' ([Text.Encoding]::ASCII.GetBytes("before`nend`n"))
    Write-TestBytes 'mixed.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nmiddle`r`nend`n"))
    Write-TestBytes 'no-final.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nend"))
    Write-TestBytes 'with-final.txt' ([Text.Encoding]::ASCII.GetBytes("before`nend`n"))
    Write-TestBytes 'utf8-bom.txt' ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("before`r`nend`r`n"))
    Write-TestBytes 'ansi.txt' ([byte[]](0xE9, 0x0A, 0xE8, 0x0A))
    Write-TestBytes 'unchanged.txt' ([Text.Encoding]::ASCII.GetBytes("same`r`n"))
    Write-TestBytes 'binary.bin' ([byte[]](0x00, 0x41, 0x0D, 0x0A, 0x42, 0x0A))
    Write-TestBytes '.codex\ignored.txt' ([Text.Encoding]::ASCII.GetBytes("ignored`r`n"))
    New-Item -ItemType Directory -Path (Join-Path $projectRoot '.codex\CVS') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $projectRoot '.codex\CVS\Entries'), '/ignored.txt/1.1///', [Text.Encoding]::ASCII)
    $unchangedTime = [IO.File]::GetLastWriteTimeUtc((Join-Path $projectRoot 'unchanged.txt'))

    $escapedMixedPath = (Join-Path $projectRoot 'mixed.txt').Replace('\', '\\')
    $nestedPatchCommand = 'const patch = "*** Begin Patch\n*** Update File: ' + $escapedMixedPath + '\n@@\n-old\n+new\n*** End Patch"; text(await tools.apply_patch(patch));'
    $missingStateInput = New-HookInput -EventName PostToolUse -SessionId 'session-without-state' -ToolName exec -Command $nestedPatchCommand
    Invoke-Hook -Mode Restore -SessionId 'session-without-state' -InputText $missingStateInput | Out-Null
    Assert-Bytes 'mixed.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nmiddle`r`nend`r`n"))
    Write-TestBytes 'mixed.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nmiddle`r`nend`n"))

    $sessionA = 'session-A'
    $execCommand = 'const patch = getPatch(); text(await tools.apply_patch(patch));'
    $trackInput = New-HookInput -EventName PreToolUse -SessionId $sessionA -ToolName exec -Command $execCommand
    Invoke-Hook -Mode Track -SessionId $sessionA -InputText $trackInput | Out-Null
    $statePathA = Join-Path $stateRoot 'session-A.json'
    if (-not (Test-Path -LiteralPath $statePathA -PathType Leaf)) { throw 'PreToolUse 未建立 session 狀態檔。' }
    $firstStateContent = Get-Content -LiteralPath $statePathA -Raw
    $stateA = $firstStateContent | ConvertFrom-Json
    if (@($stateA.files.PSObject.Properties).Count -ne 8) { throw 'PreToolUse 未正確記錄 CVS 追蹤檔或錯誤包含管理目錄。' }
    $crlfState = $stateA.files.PSObject.Properties[(Join-Path $projectRoot 'crlf.txt')].Value
    $mixedState = $stateA.files.PSObject.Properties[(Join-Path $projectRoot 'mixed.txt')].Value
    $noFinalState = $stateA.files.PSObject.Properties[(Join-Path $projectRoot 'no-final.txt')].Value
    $bomState = $stateA.files.PSObject.Properties[(Join-Path $projectRoot 'utf8-bom.txt')].Value
    if ($crlfState.lineEnding -ne 'CRLF' -or $mixedState.lineEnding -ne 'MIXED' -or $mixedState.preferredLineEnding -ne 'CRLF' -or -not [bool]$crlfState.finalNewline -or $noFinalState.finalNewline -ne $false -or $bomState.bom -ne 'UTF8-BOM') { throw 'PreToolUse 狀態內容不完整或錯誤。' }

    Write-TestBytes 'crlf.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nend`r`nadded1`nadded2`nadded3`n"))
    Write-TestBytes 'lf.txt' ([Text.Encoding]::ASCII.GetBytes("before`nend`nadded1`r`nadded2`r`nadded3`r`n"))
    Write-TestBytes 'mixed.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nmiddle`nend`nadded`n"))
    Write-TestBytes 'no-final.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nend`r`nadded`n"))
    Write-TestBytes 'with-final.txt' ([Text.Encoding]::ASCII.GetBytes("before`nend`r`n`r`n"))
    Write-TestBytes 'utf8-bom.txt' ([Text.Encoding]::UTF8.GetBytes("before`r`nend`nadded`n"))
    Write-TestBytes 'ansi.txt' ([byte[]](0xE9, 0x0D, 0x0A, 0xE8, 0x0D, 0x0A))
    Write-TestBytes 'binary.bin' ([byte[]](0x00, 0x41, 0x0A, 0x42, 0x0D, 0x0A))

    $postInput = New-HookInput -EventName PostToolUse -SessionId $sessionA -ToolName exec -Command $execCommand
    Invoke-Hook -Mode Restore -SessionId $sessionA -InputText $postInput | Out-Null
    if (-not (Test-Path -LiteralPath $statePathA -PathType Leaf)) { throw 'PostToolUse 過早清理 session 狀態檔。' }
    $restoreDiagnostic = @(Get-Content -LiteralPath (Join-Path $diagnosticRoot 'session-A.log') | ForEach-Object { $_ | ConvertFrom-Json }) | Where-Object { $_.mode -eq 'Restore' } | Select-Object -Last 1
    if ($restoreDiagnostic.event -ne 'PostToolUse' -or $restoreDiagnostic.handler -ne 'preserve-line-endings' -or $restoreDiagnostic.result -ne 'success' -or $restoreDiagnostic.changedFileCount -ne 7 -or @($restoreDiagnostic.changedFiles).Count -ne 7) {
        throw '換行 Hook 未寫入可診斷的還原紀錄。'
    }

    Assert-Bytes 'crlf.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nend`r`nadded1`r`nadded2`r`nadded3`r`n"))
    Assert-Bytes 'lf.txt' ([Text.Encoding]::ASCII.GetBytes("before`nend`nadded1`nadded2`nadded3`n"))
    Assert-Bytes 'mixed.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nmiddle`r`nend`r`nadded`r`n"))
    Assert-Bytes 'no-final.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nend`r`nadded"))
    Assert-Bytes 'with-final.txt' ([Text.Encoding]::ASCII.GetBytes("before`nend`n"))
    Assert-Bytes 'utf8-bom.txt' ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("before`r`nend`r`nadded`r`n"))
    Assert-Bytes 'ansi.txt' ([byte[]](0xE9, 0x0A, 0xE8, 0x0A))

    Invoke-Hook -Mode Track -SessionId $sessionA -InputText $trackInput | Out-Null
    $stateAfterSecondTrack = Get-Content -LiteralPath $statePathA -Raw
    if ($stateAfterSecondTrack -ne $firstStateContent) { throw '同一 session 的第二次 Track 覆寫原始狀態。' }

    Write-TestBytes 'no-final.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nend`r`nadded`nsecond`n"))
    $directPatchInput = New-HookInput -EventName PostToolUse -SessionId $sessionA -ToolName apply_patch -Command '*** Update File: no-final.txt'
    Invoke-Hook -Mode Restore -SessionId $sessionA -InputText $directPatchInput | Out-Null
    Assert-Bytes 'no-final.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nend`r`nadded`r`nsecond"))

    $sessionB = 'session-B'
    Invoke-Hook -Mode Track -SessionId $sessionB -InputText (New-HookInput -EventName PreToolUse -SessionId $sessionB) | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'session-B.json'))) { throw '不同 session 未建立獨立狀態檔。' }

    Write-TestBytes 'crlf.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nend`r`nadded1`nfinal`n"))
    $malformedStopInput = [ordered]@{
        session_id = $sessionA
        cwd = $projectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = '已刪除 "activity_config.php" 註解'
    } | ConvertTo-Json -Compress
    $malformedStopInput = $malformedStopInput.Replace('\"activity_config.php\"', '"activity_config.php"')
    Invoke-Hook -Mode Finalize -SessionId $sessionA -InputText $malformedStopInput | Out-Null
    if (Test-Path -LiteralPath $statePathA) { throw 'Stop Hook 未清理完成的 session 狀態檔。' }
    if (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'session-B.json'))) { throw 'Stop Hook 誤刪其他 session 狀態檔。' }

    Assert-Bytes 'crlf.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nend`r`nadded1`r`nfinal`r`n"))
    Assert-Bytes 'lf.txt' ([Text.Encoding]::ASCII.GetBytes("before`nend`nadded1`nadded2`nadded3`n"))
    Assert-Bytes 'mixed.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nmiddle`r`nend`r`nadded`r`n"))
    Assert-Bytes 'no-final.txt' ([Text.Encoding]::ASCII.GetBytes("before`r`nend`r`nadded`r`nsecond"))
    Assert-Bytes 'with-final.txt' ([Text.Encoding]::ASCII.GetBytes("before`nend`n"))
    Assert-Bytes 'utf8-bom.txt' ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("before`r`nend`r`nadded`r`n"))
    Assert-Bytes 'ansi.txt' ([byte[]](0xE9, 0x0A, 0xE8, 0x0A))
    Assert-Bytes 'binary.bin' ([byte[]](0x00, 0x41, 0x0A, 0x42, 0x0D, 0x0A))
    if ([IO.File]::GetLastWriteTimeUtc((Join-Path $projectRoot 'unchanged.txt')) -ne $unchangedTime) { throw 'Stop Hook 重寫了未修改檔案。' }

    $truncatedStopInput = ([ordered]@{
        session_id = $sessionB
        cwd = $projectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'unfinished'
    } | ConvertTo-Json -Compress)
    $truncatedStopInput = $truncatedStopInput.Substring(0, $truncatedStopInput.IndexOf('unfinished') + 'unfinished'.Length)
    Invoke-Hook -Mode Finalize -SessionId $sessionB -InputText $truncatedStopInput | Out-Null
    if (Test-Path -LiteralPath (Join-Path $stateRoot 'session-B.json')) { throw '截斷的 Stop payload 未完成換行修復與狀態清理。' }

    $invalid = Invoke-Hook -Mode Track -SessionId 'invalid' -InputText '{invalid-json'
    if ([string]::IsNullOrWhiteSpace([string]$invalid.Output.systemMessage)) { throw '無效 payload 沒有回傳清楚錯誤。' }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Preserve line endings hook tests passed.'
