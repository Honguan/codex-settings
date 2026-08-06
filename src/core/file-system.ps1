function Write-BytesAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = Join-Path $directory ('.codex-settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                [IO.File]::Replace($temporaryPath, $Path, $null, $true)
            } catch {
                Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
            }
        } else {
            Move-Item -LiteralPath $temporaryPath -Destination $Path
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Copy-FileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Write-BytesAtomic -Path $Destination -Bytes ([IO.File]::ReadAllBytes($Source))
}

function Write-JsonFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 12
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    Write-BytesAtomic -Path $Path -Bytes ((New-Object Text.UTF8Encoding($false)).GetBytes($json))
}

function Get-LegacyTextEncoding {
    [CmdletBinding()]
    param()

    try {
        [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
    } catch {
        # Windows PowerShell already exposes legacy code pages.
    }

    $codePage = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    if ($codePage -in @(0, 65001, 1200, 1201)) {
        throw "The current Windows ANSI code page is not suitable for legacy text detection: $codePage"
    }

    try {
        return [Text.Encoding]::GetEncoding(
            $codePage,
            [Text.EncoderExceptionFallback]::new(),
            [Text.DecoderExceptionFallback]::new()
        )
    } catch {
        throw "Unable to load Windows ANSI code page $codePage. $($_.Exception.Message)"
    }
}

function Get-TextFileState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Content = ''
            Encoding = New-Object Text.UTF8Encoding($false, $true)
            EncodingName = 'utf-8'
            CodePage = 65001
            NewLine = "`r`n"
        }
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    $encoding = $null
    $encodingName = $null

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object Text.UTF8Encoding($true, $true)
        $encodingName = 'utf-8-bom'
        $offset = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object Text.UnicodeEncoding($false, $true, $true)
        $encodingName = 'utf-16-le'
        $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object Text.UnicodeEncoding($true, $true, $true)
        $encodingName = 'utf-16-be'
        $offset = 2
    } else {
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        try {
            [void]$utf8.GetString($bytes)
            $encoding = $utf8
            $encodingName = 'utf-8'
        } catch [Text.DecoderFallbackException] {
            $encoding = Get-LegacyTextEncoding
            $encodingName = "windows-$($encoding.CodePage)"
        }
    }

    try {
        $content = if ($bytes.Length -gt $offset) {
            $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
        } else {
            ''
        }
    } catch [Text.DecoderFallbackException] {
        throw "Unable to decode text file without data loss: $Path. Detected encoding: $encodingName"
    }

    $newLine = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    return [pscustomobject]@{
        Exists = $true
        Content = $content
        Encoding = $encoding
        EncodingName = $encodingName
        CodePage = $encoding.CodePage
        NewLine = $newLine
    }
}

function Write-TextFileState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory = $true)]$Encoding
    )

    try {
        $body = $Encoding.GetBytes($Content)
    } catch [Text.EncoderFallbackException] {
        throw "The updated text cannot be represented by code page $($Encoding.CodePage): $Path"
    }

    $preamble = $Encoding.GetPreamble()
    if ($preamble.Length -gt 0) {
        $bytes = New-Object byte[] ($preamble.Length + $body.Length)
        [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
        [Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    } else {
        $bytes = $body
    }

    Write-BytesAtomic -Path $Path -Bytes $bytes
}

function Protect-LocalSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Local secret backup is supported only on Windows.'
    }
    $secure = ConvertTo-SecureString -String $Value -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $secure
}

function Unprotect-LocalSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProtectedValue)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Local secret restore is supported only on Windows.'
    }
    $secure = ConvertTo-SecureString -String $ProtectedValue
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}


function Test-DirectoryWritable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $testPath = Join-Path $Path ('.codex-settings-write-test-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($testPath, 'test', (New-Object Text.UTF8Encoding($false))) }
    finally { Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue }
}
