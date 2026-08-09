$ErrorActionPreference = 'Stop'
$trusted = $false

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $request = $line | ConvertFrom-Json
    switch ([string]$request.method) {
        'initialize' {
            [Console]::Out.WriteLine((@{ id = $request.id; result = @{ codexHome = $env:CODEX_HOME } } | ConvertTo-Json -Compress))
        }
        'hooks/list' {
            $hooksPath = [IO.Path]::GetFullPath((Join-Path $env:CODEX_HOME 'hooks.json'))
            $status = if ($trusted) { 'trusted' } else { 'untrusted' }
            $hooks = @(
                @{ key = "$hooksPath`:pre_tool_use:0:0"; sourcePath = $hooksPath; command = 'show-codex-notification.ps1 -Type QuestionRequired'; currentHash = 'sha256:question'; trustStatus = $status; enabled = $true },
                @{ key = "$hooksPath`:permission_request:0:0"; sourcePath = $hooksPath; command = 'show-codex-notification.ps1 -Type PermissionRequired'; currentHash = 'sha256:permission'; trustStatus = $status; enabled = $true },
                @{ key = "$hooksPath`:stop:0:0"; sourcePath = $hooksPath; command = 'show-codex-notification.ps1 -Type Completed'; currentHash = 'sha256:completed'; trustStatus = $status; enabled = $true }
            )
            if ((Get-Content -LiteralPath $hooksPath -Raw) -match 'preserve-line-endings') {
                $hooks += @(
                    @{ key = "$hooksPath`:pre_tool_use:1:0"; sourcePath = $hooksPath; command = 'preserve-line-endings.ps1 -Mode Track'; currentHash = 'sha256:track'; trustStatus = $status; enabled = $true },
                    @{ key = "$hooksPath`:post_tool_use:0:0"; sourcePath = $hooksPath; command = 'preserve-line-endings.ps1 -Mode Restore'; currentHash = 'sha256:restore'; trustStatus = $status; enabled = $true },
                    @{ key = "$hooksPath`:stop:1:0"; sourcePath = $hooksPath; command = 'preserve-line-endings.ps1 -Mode Finalize'; currentHash = 'sha256:finalize'; trustStatus = $status; enabled = $true }
                )
            }
            $data = @($request.params.cwds | ForEach-Object { @{ cwd = [string]$_; hooks = $hooks; warnings = @(); errors = @() } })
            [Console]::Out.WriteLine((@{ id = $request.id; result = @{ data = $data } } | ConvertTo-Json -Depth 10 -Compress))
        }
        'config/batchWrite' {
            $trusted = $true
            [Console]::Out.WriteLine((@{ id = $request.id; result = @{} } | ConvertTo-Json -Compress))
        }
    }
}
