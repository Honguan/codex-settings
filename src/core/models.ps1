function Get-CodexSettingsPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $Default
}

function New-HookInvocationContext {
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [string]$HookSource = 'global', [string]$StartedAt = '')

    $started = if ([string]::IsNullOrWhiteSpace($StartedAt)) { (Get-Date).ToUniversalTime().ToString('o') } else { $StartedAt }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        eventName = [string](Get-CodexSettingsPropertyValue -InputObject $InputObject -Names @('hook_event_name', 'eventName') -Default '')
        sessionId = [string](Get-CodexSettingsPropertyValue -InputObject $InputObject -Names @('session_id', 'sessionId') -Default '')
        turnId = [string](Get-CodexSettingsPropertyValue -InputObject $InputObject -Names @('turn_id', 'turnId') -Default '')
        cwd = [string](Get-CodexSettingsPropertyValue -InputObject $InputObject -Names @('cwd', 'workingDirectory') -Default '')
        toolName = [string](Get-CodexSettingsPropertyValue -InputObject $InputObject -Names @('tool_name', 'toolName') -Default '')
        toolInput = Get-CodexSettingsPropertyValue -InputObject $InputObject -Names @('tool_input', 'toolInput')
        hookSource = $HookSource
        processId = [int]$PID
        parentProcessId = 0
        startedAt = $started
        payload = $InputObject
    }
}

function New-HookHandlerDescriptor {
    [CmdletBinding()]
    param(
        [string]$ManagedId = '',
        [string]$ManagedVersion = '1',
        [string]$HandlerId = '',
        [string]$Kind = '',
        [string]$EventName = '',
        $Matcher = '*',
        [string]$Command = '',
        [string]$CommandWindows = '',
        [int]$Timeout = 0,
        [string]$Fingerprint = '',
        [bool]$Legacy = $false
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        managedId = $ManagedId
        managedVersion = $ManagedVersion
        handlerId = $HandlerId
        kind = $Kind
        eventName = $EventName
        matcher = $Matcher
        command = $Command
        commandWindows = $CommandWindows
        timeout = $Timeout
        fingerprint = $Fingerprint
        legacy = $Legacy
    }
}

function New-UsageSnapshot {
    [CmdletBinding()]
    param(
        [string]$SessionId = '',
        [string]$Source = '',
        [object]$Models = @(),
        [AllowNull()]$InputTokens,
        [AllowNull()]$OutputTokens,
        [AllowNull()]$ReasoningTokens,
        [AllowNull()]$CacheReadTokens,
        [AllowNull()]$CacheWriteTokens,
        [AllowNull()]$TotalTokens,
        [AllowNull()]$CostUsd,
        [string]$ActivityTime = '',
        [string[]]$PresentFields = @(),
        [string]$CapturedAt = ''
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        sessionId = $SessionId
        source = $Source
        models = @($Models)
        inputTokens = $InputTokens
        outputTokens = $OutputTokens
        reasoningTokens = $ReasoningTokens
        cacheReadTokens = $CacheReadTokens
        cacheWriteTokens = $CacheWriteTokens
        totalTokens = $TotalTokens
        costUsd = $CostUsd
        activityTime = $ActivityTime
        presentFields = @($PresentFields)
        capturedAt = if ([string]::IsNullOrWhiteSpace($CapturedAt)) { (Get-Date).ToUniversalTime().ToString('o') } else { $CapturedAt }
    }
}

function New-UsageDelta {
    [CmdletBinding()]
    param([AllowNull()]$Current, [AllowNull()]$Previous, [string]$ModelFallback = '')

    $fields = @('inputTokens', 'outputTokens', 'reasoningTokens', 'cacheReadTokens', 'cacheWriteTokens', 'totalTokens', 'costUsd')
    $delta = [ordered]@{
        schemaVersion = 1
        model = $ModelFallback
        current = $Current
        previous = $Previous
    }
    foreach ($field in $fields) {
        $currentValue = if ($null -ne $Current) { $Current.$field } else { $null }
        $previousValue = if ($null -ne $Previous) { $Previous.$field } else { $null }
        $delta[$field] = if ($null -eq $currentValue -or $null -eq $previousValue) { $null } else { [decimal]$currentValue - [decimal]$previousValue }
    }
    return [pscustomobject]$delta
}

function New-LineEndingFileState {
    [CmdletBinding()]
    param(
        [string]$Path = '',
        [long]$Length = 0,
        [string]$LastWriteTimeUtc = '',
        [string]$Sha256 = '',
        [bool]$Binary = $false,
        [string]$Bom = 'None',
        [string]$LineEnding = 'NONE',
        [string]$PreferredLineEnding = 'LF',
        [bool]$FinalNewline = $false,
        [string]$FinalNewlineStyle = 'LF',
        [long]$VerifiedLength = 0,
        [string]$VerifiedLastWriteTimeUtc = ''
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        path = $Path
        length = $Length
        lastWriteTimeUtc = $LastWriteTimeUtc
        optionalSha256 = $Sha256
        binary = $Binary
        bom = $Bom
        lineEnding = $LineEnding
        preferredLineEnding = $PreferredLineEnding
        finalNewline = $FinalNewline
        finalNewlineStyle = $FinalNewlineStyle
        verifiedLength = $VerifiedLength
        verifiedLastWriteTimeUtc = $VerifiedLastWriteTimeUtc
    }
}

function New-InstallTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$TemplateRoot,
        [AllowEmptyString()][string]$EnvironmentTemplateRoot = '',
        [AllowEmptyString()][string]$DevelopmentEnvironment = '',
        [AllowEmptyString()][string]$Cwd = '',
        [bool]$InstallWindowsNotifications = $false,
        [bool]$ManageWindowsNotifications = $true,
        [bool]$EnableDefaultModeRequestUserInput = $false,
        [AllowEmptyString()][string]$SourceRoot = ''
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        id = $Id
        mode = $Mode
        root = $Root
        templateRoot = $TemplateRoot
        environmentTemplateRoot = if ([string]::IsNullOrWhiteSpace($EnvironmentTemplateRoot)) { $null } else { $EnvironmentTemplateRoot }
        developmentEnvironment = if ([string]::IsNullOrWhiteSpace($DevelopmentEnvironment)) { $null } else { $DevelopmentEnvironment }
        cwd = if ([string]::IsNullOrWhiteSpace($Cwd)) { $null } else { $Cwd }
        installWindowsNotifications = [bool]$InstallWindowsNotifications
        manageWindowsNotifications = [bool]$ManageWindowsNotifications
        enableDefaultModeRequestUserInput = [bool]$EnableDefaultModeRequestUserInput
        sourceRoot = if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $null } else { $SourceRoot }
    }
}

function New-InstallFileResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$RelativePath = '',
        [string]$Strategy = 'replace',
        [bool]$ExistedBefore = $false,
        [bool]$Changed = $false,
        [bool]$Created = $false,
        [bool]$Updated = $false,
        [string]$Sha256Before = '',
        [string]$Sha256After = '',
        [string]$TemplateSha256 = '',
        [long]$FileLength = 0,
        [long]$LastWriteTimeUtcTicks = 0,
        [AllowEmptyString()][string]$BackupPath = '',
        [AllowNull()]$ValidationResult = $null,
        [string]$Status = 'Unchanged',
        [AllowEmptyString()][string]$StartMarker = '',
        [AllowEmptyString()][string]$EndMarker = '',
        [string]$OriginalEncoding = 'utf-8',
        [int]$OriginalCodePage = 65001
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        path = $Path
        relativePath = if ([string]::IsNullOrWhiteSpace($RelativePath)) { $Path } else { $RelativePath }
        strategy = $Strategy
        existedBefore = $ExistedBefore
        changed = $Changed
        created = $Created
        updated = $Updated
        sha256Before = if ([string]::IsNullOrWhiteSpace($Sha256Before)) { $null } else { $Sha256Before }
        sha256After = if ([string]::IsNullOrWhiteSpace($Sha256After)) { $null } else { $Sha256After }
        sha256 = if ([string]::IsNullOrWhiteSpace($Sha256After)) { $null } else { $Sha256After }
        templateSha256 = if ([string]::IsNullOrWhiteSpace($TemplateSha256)) { $null } else { $TemplateSha256 }
        fileLength = $FileLength
        lastWriteTimeUtcTicks = $LastWriteTimeUtcTicks
        backupPath = if ([string]::IsNullOrWhiteSpace($BackupPath)) { $null } else { $BackupPath }
        validationResult = $ValidationResult
        status = $Status
        startMarker = if ([string]::IsNullOrWhiteSpace($StartMarker)) { $null } else { $StartMarker }
        endMarker = if ([string]::IsNullOrWhiteSpace($EndMarker)) { $null } else { $EndMarker }
        originalEncoding = $OriginalEncoding
        originalCodePage = $OriginalCodePage
    }
}

function New-InstallationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [string]$Root = '',
        [string]$DevelopmentEnvironment = '',
        [object[]]$Files = @(),
        [AllowNull()]$Integrations = $null,
        [AllowNull()]$Validation = $null,
        [AllowEmptyString()][string]$TransactionId = '',
        [string]$StartedAt = '',
        [string]$CompletedAt = '',
        [AllowNull()]$Previous = $null,
        [bool]$HookChanged = $false
    )

    $summary = [ordered]@{ Created = 0; Updated = 0; Unchanged = 0; Failed = 0; Installed = 0 }
    foreach ($file in @($Files)) {
        if ([string]$file.Status -eq 'Failed') { $summary.Failed++; continue }
        if ([bool]$file.Created -or (-not [bool]$file.ExistedBefore)) { $summary.Created++; $summary.Installed++; continue }
        if ([bool]$file.Updated -or ([bool]$file.ExistedBefore -and [bool]$file.Changed)) { $summary.Updated++; continue }
        $summary.Unchanged++
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        mode = $Mode
        root = $Root
        developmentEnvironment = if ([string]::IsNullOrWhiteSpace($DevelopmentEnvironment)) { $null } else { $DevelopmentEnvironment }
        files = @($Files)
        summary = [pscustomobject]$summary
        integrations = $Integrations
        validation = $Validation
        transactionId = if ([string]::IsNullOrWhiteSpace($TransactionId)) { $null } else { $TransactionId }
        startedAt = if ([string]::IsNullOrWhiteSpace($StartedAt)) { (Get-Date).ToUniversalTime().ToString('o') } else { $StartedAt }
        completedAt = if ([string]::IsNullOrWhiteSpace($CompletedAt)) { (Get-Date).ToUniversalTime().ToString('o') } else { $CompletedAt }
        previous = $Previous
        hookChanged = $HookChanged
    }
}

function New-CodexSettingsStateEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [AllowEmptyString()][string]$Key = '',
        [AllowNull()]$Payload = $null,
        [int]$SchemaVersion = 1,
        [AllowEmptyString()][string]$SessionId = '',
        [AllowEmptyString()][string]$TurnId = '',
        [AllowEmptyString()][string]$CreatedAt = '',
        [AllowEmptyString()][string]$UpdatedAt = ''
    )

    $now = (Get-Date).ToUniversalTime().ToString('o')
    return [pscustomobject][ordered]@{
        schemaVersion = $SchemaVersion
        kind = $Kind
        key = $Key
        createdAt = if ([string]::IsNullOrWhiteSpace($CreatedAt)) { $now } else { $CreatedAt }
        updatedAt = if ([string]::IsNullOrWhiteSpace($UpdatedAt)) { $now } else { $UpdatedAt }
        sessionId = if ([string]::IsNullOrWhiteSpace($SessionId)) { $null } else { $SessionId }
        turnId = if ([string]::IsNullOrWhiteSpace($TurnId)) { $null } else { $TurnId }
        payload = $Payload
    }
}

function Test-CodexSettingsContract {
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [Parameter(Mandatory = $true)][ValidateSet('HookInvocationContext', 'HookHandlerDescriptor', 'UsageSnapshot', 'UsageDelta', 'LineEndingFileState', 'InstallTarget', 'InstallFileResult', 'InstallationResult', 'StateEnvelope')][string]$Kind)

    if ($null -eq $InputObject) { return $false }
    $required = switch ($Kind) {
        'HookInvocationContext' { @('schemaVersion', 'eventName', 'sessionId', 'turnId', 'payload') }
        'HookHandlerDescriptor' { @('schemaVersion', 'managedId', 'handlerId', 'eventName', 'command', 'fingerprint') }
        'UsageSnapshot' { @('schemaVersion', 'sessionId', 'source', 'presentFields', 'capturedAt') }
        'UsageDelta' { @('schemaVersion', 'current', 'previous') }
        'LineEndingFileState' { @('schemaVersion', 'path', 'binary', 'lineEnding', 'finalNewline') }
        'InstallTarget' { @('schemaVersion', 'id', 'mode', 'root', 'templateRoot', 'installWindowsNotifications') }
        'InstallFileResult' { @('schemaVersion', 'path', 'relativePath', 'strategy', 'existedBefore', 'changed', 'status') }
        'InstallationResult' { @('schemaVersion', 'mode', 'root', 'files', 'summary', 'validation', 'transactionId', 'startedAt', 'completedAt') }
        'StateEnvelope' { @('schemaVersion', 'kind', 'createdAt', 'updatedAt', 'payload') }
    }
    foreach ($propertyName in $required) {
        if ($InputObject.PSObject.Properties.Name -notcontains $propertyName) { return $false }
    }
    return $true
}
