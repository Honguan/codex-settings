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
            $sourcePath = [IO.Path]::GetFullPath((Join-Path $env:CODEX_SETTINGS_PONYTAIL_TEST_SOURCE 'hooks\claude-codex-hooks.json'))
            $status = if ($trusted) { 'trusted' } else { 'untrusted' }
            $hooks = @(
                @{ key = 'ponytail:session_start'; sourcePath = $sourcePath; currentHash = 'sha256:session'; trustStatus = $status },
                @{ key = 'ponytail:user_prompt_submit'; sourcePath = $sourcePath; currentHash = 'sha256:prompt'; trustStatus = $status },
                @{ key = 'ponytail:subagent_start'; sourcePath = $sourcePath; currentHash = 'sha256:subagent'; trustStatus = $status }
            )
            $data = @($request.params.cwds | ForEach-Object { @{ cwd = [string]$_; hooks = $hooks; warnings = @(); errors = @() } })
            [Console]::Out.WriteLine((@{ id = $request.id; result = @{ data = $data } } | ConvertTo-Json -Depth 10 -Compress))
        }
        'config/batchWrite' {
            $trusted = $true
            [Console]::Out.WriteLine((@{ id = $request.id; result = @{} } | ConvertTo-Json -Compress))
        }
    }
}
