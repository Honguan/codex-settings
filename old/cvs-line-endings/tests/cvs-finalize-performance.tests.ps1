$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$hookScript = Join-Path $repositoryRoot 'src\templates\environments\cvs\hooks\preserve-line-endings.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-settings-cvs-finalize-' + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $testRoot 'project'
$stateRoot = Join-Path $testRoot 'state'
$diagnosticRoot = Join-Path $testRoot 'logs'
$invocationRoot = Join-Path $testRoot 'invocations'
$sessionId = 'finalize-performance'

function Get-TestSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-TestStatePath {
    $key = "$([IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/'))|$sessionId"
    return Join-Path $stateRoot ((Get-TestSha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant() + '.json')
}

function Invoke-FinalizeHook([string]$InputText) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'pwsh'
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $hookScript, '-Mode', 'Finalize')) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['CODEX_SETTINGS_LINE_ENDING_STATE_ROOT'] = $stateRoot
    $startInfo.Environment['CODEX_SETTINGS_HOOK_LOG_ROOT'] = $diagnosticRoot
    $startInfo.Environment['CODEX_SETTINGS_HOOK_INVOCATION_STATE_ROOT'] = $invocationRoot
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.StandardInput.Write($InputText)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Finalize Hook 結束碼不是 0：$($process.ExitCode) - $stderr" }
    try { $null = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { throw "Finalize Hook stdout 不是合法 JSON：$stdout" }
}

try {
    New-Item -ItemType Directory -Path (Join-Path $projectRoot 'CVS'), $stateRoot -Force | Out-Null
    $largeFile = Join-Path $projectRoot 'large.txt'
    [IO.File]::WriteAllText((Join-Path $projectRoot 'CVS\Entries'), '/large.txt/1.1///', [Text.Encoding]::ASCII)
    $bytes = [byte[]]::new(32MB)
    [Array]::Fill($bytes, [byte]0x61)
    [IO.File]::WriteAllBytes($largeFile, $bytes)
    $fileInfo = [IO.FileInfo]::new($largeFile)

    $files = [ordered]@{}
    $files[$largeFile] = [ordered]@{
        lineEnding = 'NONE'
        preferredLineEnding = 'CRLF'
        finalNewline = $false
        finalNewlineStyle = 'NONE'
        bom = 'NONE'
        sha256 = Get-TestSha256 -Bytes $bytes
        verifiedLength = $fileInfo.Length
        verifiedLastWriteTimeUtcTicks = $fileInfo.LastWriteTimeUtc.Ticks
    }
    $state = [ordered]@{ sessionId = $sessionId; projectRoot = $projectRoot; files = $files }
    [IO.File]::WriteAllText((Get-TestStatePath), ($state | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

    $inputText = ([ordered]@{
        session_id = $sessionId
        cwd = $projectRoot
        hook_event_name = 'Stop'
        stop_hook_active = $false
        last_assistant_message = 'done'
    } | ConvertTo-Json -Compress)
    Invoke-FinalizeHook -InputText $inputText

    $diagnostic = Get-Content -LiteralPath (Join-Path $diagnosticRoot "$sessionId.log") -Tail 1 | ConvertFrom-Json
    $elapsedMs = [long]$diagnostic.elapsedMs
    if ($elapsedMs -ge 1500) {
        throw "CVS Finalize 無變更時耗時 $($diagnostic.elapsedMs) ms，應低於 1500 ms。"
    }
    if (Test-Path -LiteralPath (Get-TestStatePath)) { throw 'Finalize 完成後未清理狀態檔。' }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "CVS finalize performance tests passed ($elapsedMs ms)."
