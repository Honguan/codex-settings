$script:LongRunningAsyncWaitPolicyVersion = 1
$script:LongRunningAsyncWaitPolicyStartMarker = '<!-- >>> CODEX-SETTINGS:OTHER:LONG-RUNNING-ASYNC-WAIT:v1 >>> -->'
$script:LongRunningAsyncWaitPolicyEndMarker = '<!-- <<< CODEX-SETTINGS:OTHER:LONG-RUNNING-ASYNC-WAIT:v1 <<< -->'

function Get-LongRunningAsyncWaitPolicyTemplate([string]$SourceRoot) {
    return [IO.File]::ReadAllText((Join-Path $SourceRoot 'templates\optional\long-running-async-wait.md'))
}

function Get-LongRunningAsyncWaitPolicyState([string]$Content, [string]$ManagedContent) {
    $startCount = [regex]::Matches($Content, '(?m)^\s*' + [regex]::Escape($script:LongRunningAsyncWaitPolicyStartMarker) + '\s*$').Count
    $endCount = [regex]::Matches($Content, '(?m)^\s*' + [regex]::Escape($script:LongRunningAsyncWaitPolicyEndMarker) + '\s*$').Count
    if ($startCount -eq 0 -and $endCount -eq 0) { return [pscustomobject]@{ Status = 'NotInstalled'; Version = 0; ManagedBlockPresent = $false; Content = '' } }
    if ($startCount -ne 1 -or $endCount -ne 1) { return [pscustomobject]@{ Status = 'Conflict'; Version = 0; ManagedBlockPresent = $false; Content = '' } }
    $match = [regex]::Match($Content, '(?ms)^\s*' + [regex]::Escape($script:LongRunningAsyncWaitPolicyStartMarker) + '\r?\n(?<content>.*?)^\s*' + [regex]::Escape($script:LongRunningAsyncWaitPolicyEndMarker) + '\s*$')
    if (-not $match.Success) { return [pscustomobject]@{ Status = 'Conflict'; Version = 0; ManagedBlockPresent = $false; Content = '' } }
    $current = ($match.Groups['content'].Value -replace '\r\n?', "`n").Trim()
    $expected = ($ManagedContent -replace '\r\n?', "`n").Trim()
    return [pscustomobject]@{ Status = $(if ($current -eq $expected) { 'InstalledCurrent' } else { 'InstalledNeedsUpdate' }); Version = $script:LongRunningAsyncWaitPolicyVersion; ManagedBlockPresent = $true; Content = $match.Groups['content'].Value.Trim() }
}

function Set-LongRunningAsyncWaitPolicy([string]$Content, [string]$ManagedContent, [ValidateSet('Install', 'Remove')][string]$Action, [string]$NewLine = "`r`n") {
    $state = Get-LongRunningAsyncWaitPolicyState -Content $Content -ManagedContent $ManagedContent
    if ($state.Status -eq 'Conflict') { throw 'AGENTS.md 的 long-running async wait managed block 不完整或重複，無法安全修改。' }
    if ($Action -eq 'Remove') { return Remove-ManagedBlock -Content $Content -StartMarker $script:LongRunningAsyncWaitPolicyStartMarker -EndMarker $script:LongRunningAsyncWaitPolicyEndMarker }
    return Merge-ManagedBlock -ExistingContent $Content -ManagedContent $ManagedContent -StartMarker $script:LongRunningAsyncWaitPolicyStartMarker -EndMarker $script:LongRunningAsyncWaitPolicyEndMarker -NewLine $NewLine
}
