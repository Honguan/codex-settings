$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:ScriptRoot = Join-Path $repositoryRoot 'src'
. (Join-Path $script:ScriptRoot 'load-installation.ps1')

$script:commands = New-Object 'System.Collections.Generic.List[string]'
$script:allowMarketplaceMutation = $false
$script:failPluginAdd = $false
function Invoke-PonytailCodexCommand {
    param([string[]]$Arguments)

    $command = $Arguments -join ' '
    [void]$script:commands.Add($command)
    switch ($command) {
        'plugin marketplace list --json' {
            return [pscustomobject]@{
                ExitCode = 0
                Output = @('{"marketplaces":[{"name":"ponytail","root":"C:\\cache\\ponytail"}]}')
            }
        }
        'plugin list --json' {
            return [pscustomobject]@{
                ExitCode = 0
                Output = @('{"installed":[{"pluginId":"ponytail@ponytail","version":"1.2.3","source":{"path":"C:\\cache\\ponytail\\plugins\\ponytail"},"marketplaceSource":{"sourceType":"git","source":"https://github.com/DietrichGebert/ponytail.git"}}]}')
            }
        }
        'plugin marketplace upgrade ponytail --json' {
            return [pscustomobject]@{ ExitCode = 0; Output = @('{"status":"updated"}') }
        }
        'plugin add ponytail@ponytail --json' {
            if ($script:failPluginAdd) { return [pscustomobject]@{ ExitCode = 1; Output = @('simulated plugin failure') } }
            return [pscustomobject]@{ ExitCode = 0; Output = @('{"status":"unchanged"}') }
        }
        'plugin remove ponytail@ponytail' {
            return [pscustomobject]@{ ExitCode = 0; Output = @('removed') }
        }
        default {
            if ($command -like 'plugin marketplace add *') {
                if ($script:allowMarketplaceMutation) { return [pscustomobject]@{ ExitCode = 0; Output = @('{"status":"added"}') } }
                return [pscustomobject]@{ ExitCode = 1; Output = @("Error: marketplace 'ponytail' is already added from a different source") }
            }
            if ($command -eq 'plugin marketplace remove ponytail --json') {
                if ($script:allowMarketplaceMutation) { return [pscustomobject]@{ ExitCode = 0; Output = @('{"status":"removed"}') } }
            }
            throw "未預期的 Codex 指令：$command"
        }
    }
}

function Get-PonytailHookState {
    param($State, [string]$Root, [string]$Cwd = $Root)
    return [pscustomobject]@{ DetectedCount = 2; TrustedCount = 2; Hooks = @(); Error = '' }
}

$state = Get-PonytailInstallationState
if (-not $state.MarketplacePresent) { throw 'JSON discovery 應辨識已存在的 ponytail marketplace。' }
if ($state.MarketplaceCanonicalSource -ne 'github.com/dietrichgebert/ponytail') { throw "等價 GitHub URL 未 canonicalize：$($state.MarketplaceCanonicalSource)" }
if ($state.SourceRelationship -ne 'Equivalent') { throw "等價來源應標示 Equivalent：$($state.SourceRelationship)" }

$result = Invoke-PonytailInstallation -State $state -Root $repositoryRoot
if ($script:commands -contains 'plugin marketplace add DietrichGebert/ponytail --json') { throw '已存在且來源等價時不得再次 add marketplace。' }
if ($script:commands -notcontains 'plugin marketplace upgrade ponytail --json') { throw '已存在且來源等價時應沿用 alias 並 upgrade。' }
if ($result.ValidationStatus -ne 'Validated') { throw '等價來源安裝後應完成 Hook 驗證。' }

$conflictState = $state.PSObject.Copy()
$conflictState.MarketplaceSource = 'some-other/source'
$conflictState.MarketplaceCanonicalSource = 'github.com/some-other/source'
$conflictState.SourceRelationship = 'Conflict'
$conflictState.SourceMatchesExpected = $false
$script:commands.Clear()
$preserved = Invoke-PonytailInstallation -State $conflictState -Root $repositoryRoot -MarketplaceAction Preserve
if (@($script:commands | Where-Object { $_ -match '^plugin (?:marketplace|add|remove)' }).Count -ne 0) { throw '保留衝突來源時不得修改 marketplace 或 plugin。' }
if ($preserved.MarketplaceStatus -ne 'PreservedConflict' -or $preserved.ValidationStatus -ne 'Validated') { throw '保留可驗證的既有 Ponytail 時應成功且標示 PreservedConflict。' }

foreach ($source in @(
    'DietrichGebert/ponytail',
    'https://github.com/DietrichGebert/ponytail',
    'https://github.com/DietrichGebert/ponytail.git',
    'git@github.com:DietrichGebert/ponytail.git',
    'ssh://git@github.com/DietrichGebert/ponytail.git'
)) {
    if ((ConvertTo-PonytailCanonicalMarketplaceSource $source) -ne 'github.com/dietrichgebert/ponytail') { throw "來源正規化失敗：$source" }
}

$script:commands.Clear()
1..10 | ForEach-Object { [void](Invoke-PonytailInstallation -State $state -Root $repositoryRoot) }
if (@($script:commands | Where-Object { $_ -like 'plugin marketplace add *' }).Count -ne 0) { throw '重複安裝 10 次不得再次 add marketplace。' }

$script:allowMarketplaceMutation = $true
$switchState = $conflictState.PSObject.Copy()
$switchState.MarketplacePluginIds = @('ponytail@ponytail')
$script:commands.Clear()
$switched = Invoke-PonytailInstallation -State $switchState -Root $repositoryRoot -MarketplaceAction Switch
if ($switched.MarketplaceStatus -ne 'Switched' -or -not $switched.MarketplaceSwitchedNow) { throw '使用者確認後的安全 source 切換狀態錯誤。' }
if ($script:commands -notcontains 'plugin marketplace remove ponytail --json' -or $script:commands -notcontains 'plugin marketplace add DietrichGebert/ponytail --json') { throw '安全切換未執行預期 remove/add。' }

$blockedState = $conflictState.PSObject.Copy()
$blockedState.MarketplacePluginIds = @('ponytail@ponytail', 'other@ponytail')
$script:commands.Clear()
$blocked = $false
try { [void](Invoke-PonytailInstallation -State $blockedState -Root $repositoryRoot -MarketplaceAction Switch) } catch { $blocked = $_.Exception.Message -match 'other@ponytail' }
if (-not $blocked -or $script:commands.Count -ne 0) { throw '有其他 plugin 使用 marketplace 時必須在 mutation 前阻止切換。' }

$script:commands.Clear()
Undo-PonytailInstallation -Result $switched
if ($script:commands -notcontains 'plugin marketplace add some-other/source --json') { throw '切換後 rollback 應恢復使用者原 marketplace source。' }

$script:commands.Clear()
Undo-PonytailInstallation -Result $preserved
if ($script:commands.Count -ne 0) { throw 'rollback 不得修改原本就存在且被保留的 marketplace。' }

$missingState = $state.PSObject.Copy()
$missingState.MarketplacePresent = $false
$missingState.MarketplaceSource = ''
$missingState.MarketplaceCanonicalSource = ''
$missingState.SourceRelationship = 'Missing'
$missingState.SourceMatchesExpected = $false
$missingState.MarketplacePluginIds = @()
$missingState.PluginPresent = $false
$missingState.PluginSourcePath = ''
$script:commands.Clear()
$installed = Invoke-PonytailInstallation -State $missingState -Root $repositoryRoot
if (-not $installed.InstalledNow -or -not $installed.MarketplaceAddedNow) { throw '全新安裝應記錄本次新增 plugin 與 marketplace。' }
if ($script:commands -notcontains 'plugin marketplace add DietrichGebert/ponytail --json') { throw '全新安裝缺少 marketplace add。' }
$script:commands.Clear()
Undo-PonytailInstallation -Result $installed
if ($script:commands -notcontains 'plugin remove ponytail@ponytail' -or $script:commands -notcontains 'plugin marketplace remove ponytail --json') { throw '全新安裝 rollback 應只移除本次新增的 plugin 與 marketplace。' }

$script:failPluginAdd = $true
$script:commands.Clear()
$failedInstall = $false
try { [void](Invoke-PonytailInstallation -State $missingState -Root $repositoryRoot) } catch { $failedInstall = $_.Exception.Message -match 'simulated plugin failure' }
$script:failPluginAdd = $false
if (-not $failedInstall) { throw '模擬 plugin 安裝失敗應回傳原始錯誤。' }
if ($script:commands -notcontains 'plugin marketplace remove ponytail --json') { throw 'plugin 安裝失敗時應立即移除本次新增的 marketplace。' }

Write-Host 'Ponytail marketplace tests passed.'
