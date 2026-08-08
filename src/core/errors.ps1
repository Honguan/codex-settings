function New-CodexSettingsError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()]$Details = $null,
        [bool]$Recoverable = $false,
        [AllowNull()]$Context = $null,
        [AllowNull()]$InnerError = $null
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        code = $Code
        component = $Component
        operation = $Operation
        message = $Message
        details = $Details
        recoverable = $Recoverable
        context = $Context
        innerError = $InnerError
    }
}

function ConvertTo-CodexSettingsError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [string]$Code = 'UNEXPECTED_ERROR',
        [string]$Component = 'unknown',
        [string]$Operation = 'unknown',
        [AllowNull()]$Context = $null
    )

    $message = if ($null -ne $ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    return New-CodexSettingsError -Code $Code -Component $Component -Operation $Operation -Message $message -Context $Context -InnerError $ErrorRecord
}

function Throw-CodexSettingsError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ErrorModel
    )

    $exception = [InvalidOperationException]::new([string]$ErrorModel.message)
    $exception.Data['CodexSettingsError'] = $ErrorModel
    throw $exception
}
