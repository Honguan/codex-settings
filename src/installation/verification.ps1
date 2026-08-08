function Get-InstallationVerificationResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Result)

    $errors = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-CodexSettingsContract -InputObject $Result -Kind InstallationResult)) { [void]$errors.Add('InstallationResult contract is incomplete.') }
    if ([string]::IsNullOrWhiteSpace([string]$Result.Root) -or -not (Test-Path -LiteralPath $Result.Root -PathType Container)) { [void]$errors.Add("Installation result root is missing: $($Result.Root)") }
    foreach ($file in @($Result.Files)) {
        if (-not (Test-CodexSettingsContract -InputObject $file -Kind InstallFileResult)) { [void]$errors.Add("InstallFileResult contract is incomplete: $($file.Path)"); continue }
        if ([string]$file.Status -ne 'Failed' -and -not [string]::IsNullOrWhiteSpace([string]$file.Path)) {
            $path = Join-Path $Result.Root ([string]$file.RelativePath)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { [void]$errors.Add("Installed file is missing: $path") }
        }
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        valid = $errors.Count -eq 0
        checkedAt = (Get-Date).ToUniversalTime().ToString('o')
        errors = $errors.ToArray()
    }
}

function Test-InstallationResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Result)

    return [bool](Get-InstallationVerificationResult -Result $Result).Valid
}
