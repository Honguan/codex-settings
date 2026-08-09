$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

foreach ($commandName in @(
    'Invoke-Installer',
    'Get-OptionalInstallationScriptPath',
    'Select-OptionalPonytail',
    'Select-OptionalCodexOrchestration',
    'Select-OptionalSerena',
    'New-PonytailSkippedResult',
    'New-CodexOrchestrationSkippedResult',
    'New-SerenaSkippedResult'
)) {
    if (-not (Get-Command $commandName -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "安裝器載入後缺少公開命令：$commandName"
    }
}

$implementationCommands = [ordered]@{
    Ponytail = 'Invoke-PonytailCodexCommand'
    CodexOrchestration = 'Invoke-CodexOrchestrationCodexCommand'
    Serena = 'Invoke-SerenaCommand'
}
foreach ($commandName in $implementationCommands.Values) {
    if (Get-Command $commandName -CommandType Function -ErrorAction SilentlyContinue) {
        throw "未選用功能時不應載入實作：$commandName"
    }
}

foreach ($name in $implementationCommands.Keys) {
    . (Get-OptionalInstallationScriptPath -Name $name)
    $expectedCommand = $implementationCommands[$name]
    if (-not (Get-Command $expectedCommand -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "明確選用 $name 後未載入實作：$expectedCommand"
    }
}

Write-Host 'Optional integration lazy-load tests passed.'
