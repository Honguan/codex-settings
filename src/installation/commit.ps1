function Complete-Installation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Results,
        [Parameter(Mandatory = $true)]$Transaction,
        [AllowNull()]$External = $null,
        [AllowNull()]$Ownership = $null,
        [switch]$FinalizeTransaction
    )

    foreach ($result in @($Results)) {
        $verification = Get-InstallationVerificationResult -Result $result
        $result.validation = $verification
        if (-not [bool]$verification.Valid) { throw "安裝結果驗證失敗：$($verification.errors -join '; ')" }
        Save-InstallationManifest -Result $result -Transaction $Transaction -External $(if ($result.Mode -eq 'Global') { $External } else { $null }) -Ownership $(if ($result.Mode -eq 'Global') { $Ownership } else { $null })
    }
    if ($FinalizeTransaction) { Complete-FileTransaction -Transaction $Transaction }
    return @($Results)
}
