function Read-CodexAppServerResponse($Process, [int]$RequestId, [int]$TimeoutMilliseconds = 15000) {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        $remaining = [Math]::Max(1, $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds)
        $readTask = $Process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) { break }
        $line = $readTask.Result
        if ($null -eq $line) { break }
        try { $message = $line | ConvertFrom-Json -ErrorAction Stop }
        catch { continue }
        if ($null -ne $message.id -and [int]$message.id -eq $RequestId) {
            if ($null -ne $message.error) {
                $details = if ($null -ne $message.error.message) { [string]$message.error.message } else { $message.error | ConvertTo-Json -Compress }
                throw "Codex app-server request $RequestId failed: $details"
            }
            return $message.result
        }
    }
    throw "Codex app-server request $RequestId timed out."
}

function Set-CodexSettingsHookTrust([string]$Root, [string]$Cwd = (Get-Location).Path) {
    $hooksPath = [IO.Path]::GetFullPath((Join-Path $Root 'hooks.json'))
    if (-not (Test-Path -LiteralPath $hooksPath -PathType Leaf)) { throw "找不到 Hook 設定：$hooksPath" }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SETTINGS_APP_SERVER_TEST_COMMAND)) {
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $env:CODEX_SETTINGS_APP_SERVER_TEST_COMMAND)) { $startInfo.ArgumentList.Add($argument) }
    } else {
        $codexCommand = Get-Command codex -ErrorAction Stop
        $codexPath = [string]$codexCommand.Source
        if ([string]::IsNullOrWhiteSpace($codexPath)) { throw 'Codex command does not resolve to an executable file.' }

        switch ([IO.Path]::GetExtension($codexPath).ToLowerInvariant()) {
            { $_ -in @('.cmd', '.bat') } {
                $startInfo.FileName = $env:ComSpec
                foreach ($argument in @('/d', '/s', '/c', 'call', $codexPath, 'app-server', '--stdio')) { $startInfo.ArgumentList.Add($argument) }
            }
            '.ps1' {
                $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
                foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $codexPath, 'app-server', '--stdio')) { $startInfo.ArgumentList.Add($argument) }
            }
            default {
                $startInfo.FileName = $codexPath
                foreach ($argument in @('app-server', '--stdio')) { $startInfo.ArgumentList.Add($argument) }
            }
        }
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['CODEX_HOME'] = [IO.Path]::GetFullPath($Root)

    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $initialize = [ordered]@{
            method = 'initialize'
            id = 1
            params = [ordered]@{
                clientInfo = [ordered]@{ name = 'codex_settings'; title = 'Codex Settings'; version = '1.0.0' }
            }
        }
        $process.StandardInput.WriteLine(($initialize | ConvertTo-Json -Depth 8 -Compress))
        $process.StandardInput.Flush()
        [void](Read-CodexAppServerResponse -Process $process -RequestId 1)
        $process.StandardInput.WriteLine((@{ method = 'initialized'; params = @{} } | ConvertTo-Json -Compress))

        $listRequest = [ordered]@{ method = 'hooks/list'; id = 2; params = [ordered]@{ cwds = @([IO.Path]::GetFullPath($Cwd)) } }
        $process.StandardInput.WriteLine(($listRequest | ConvertTo-Json -Depth 8 -Compress))
        $process.StandardInput.Flush()
        $listResult = Read-CodexAppServerResponse -Process $process -RequestId 2
        $cwdResult = @($listResult.data | Where-Object { [IO.Path]::GetFullPath([string]$_.cwd) -eq [IO.Path]::GetFullPath($Cwd) } | Select-Object -First 1)[0]
        if ($null -eq $cwdResult) { throw 'Codex app-server did not return Hook information for the installation directory.' }
        $discoveryErrors = @($cwdResult.errors | Where-Object { $null -ne $_ } | ForEach-Object {
            if ($null -ne $_.PSObject.Properties['message']) { [string]$_.message } else { [string]$_ }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($discoveryErrors.Count -gt 0) { throw "Codex Hook discovery failed: $($discoveryErrors -join '; ')" }

        $managedHooks = @(@($cwdResult.hooks) | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.sourcePath) -and
            [string]::Equals([IO.Path]::GetFullPath([string]$_.sourcePath), $hooksPath, [StringComparison]::OrdinalIgnoreCase) -and
            ((Test-ManagedGlobalHookEntry $_) -or (Test-ManagedLineEndingHookEntry $_))
        })
        if ($managedHooks.Count -eq 0) {
            return [pscustomobject]@{ TrustedCount = 0; UpdatedCount = 0; Verified = $true }
        }

        $pendingHooks = @($managedHooks | Where-Object { [string]$_.trustStatus -ne 'trusted' })
        if ($pendingHooks.Count -gt 0) {
            $trustValues = [ordered]@{}
            foreach ($hook in $pendingHooks) {
                if ([string]::IsNullOrWhiteSpace([string]$hook.key) -or [string]::IsNullOrWhiteSpace([string]$hook.currentHash)) {
                    throw 'Codex app-server returned an invalid managed Hook identity.'
                }
                $trustValues[[string]$hook.key] = [ordered]@{ trusted_hash = [string]$hook.currentHash }
            }
            $writeRequest = [ordered]@{
                method = 'config/batchWrite'
                id = 3
                params = [ordered]@{
                    edits = @([ordered]@{ keyPath = 'hooks.state'; value = $trustValues; mergeStrategy = 'upsert' })
                    reloadUserConfig = $true
                }
            }
            $process.StandardInput.WriteLine(($writeRequest | ConvertTo-Json -Depth 20 -Compress))
            $process.StandardInput.Flush()
            [void](Read-CodexAppServerResponse -Process $process -RequestId 3)
        }

        $verifyRequest = [ordered]@{ method = 'hooks/list'; id = 4; params = [ordered]@{ cwds = @([IO.Path]::GetFullPath($Cwd)) } }
        $process.StandardInput.WriteLine(($verifyRequest | ConvertTo-Json -Depth 8 -Compress))
        $process.StandardInput.Flush()
        $verifyResult = Read-CodexAppServerResponse -Process $process -RequestId 4
        $verifiedCwd = @($verifyResult.data | Where-Object { [IO.Path]::GetFullPath([string]$_.cwd) -eq [IO.Path]::GetFullPath($Cwd) } | Select-Object -First 1)[0]
        $verifiedHooks = @(@($verifiedCwd.hooks) | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.sourcePath) -and
            [string]::Equals([IO.Path]::GetFullPath([string]$_.sourcePath), $hooksPath, [StringComparison]::OrdinalIgnoreCase) -and
            ((Test-ManagedGlobalHookEntry $_) -or (Test-ManagedLineEndingHookEntry $_))
        })
        if ($verifiedHooks.Count -ne $managedHooks.Count -or @($verifiedHooks | Where-Object { [string]$_.trustStatus -ne 'trusted' }).Count -gt 0) {
            throw 'Codex Settings Hook trust verification failed.'
        }
        return [pscustomobject]@{ TrustedCount = $verifiedHooks.Count; UpdatedCount = $pendingHooks.Count; Verified = $true }
    } finally {
        if ($null -ne $process) {
            try { $process.StandardInput.Close() } catch {}
            if (-not $process.WaitForExit(1000)) { $process.Kill($true) }
            $process.Dispose()
        }
    }
}
