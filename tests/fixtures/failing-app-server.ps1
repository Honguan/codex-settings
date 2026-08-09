$ErrorActionPreference = 'Stop'

while ($null -ne ($line = [Console]::In.ReadLine())) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $request = $line | ConvertFrom-Json
    if ([string]$request.method -eq 'initialize') {
        [Console]::Out.WriteLine((@{ id = $request.id; result = @{ codexHome = $env:CODEX_HOME } } | ConvertTo-Json -Compress))
        continue
    }
    if ([string]$request.method -eq 'hooks/list') {
        [Console]::Out.WriteLine((@{ id = $request.id; error = @{ message = 'intentional Hook trust failure' } } | ConvertTo-Json -Compress))
    }
}
