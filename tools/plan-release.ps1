[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Architecture', 'Feature', 'Fix')]
    [string]$ChangeType,

    [string]$CurrentVersion
)

$ErrorActionPreference = 'Stop'
$versionPattern = '^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'

function ConvertTo-VersionParts {
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )

    if ($Version -notmatch $versionPattern) {
        throw "版本格式無效：$Version。必須使用 v主版.次版.修訂版，例如 v1.3.0。"
    }

    [pscustomobject]@{
        Major = [uint64]$Matches[1]
        Minor = [uint64]$Matches[2]
        Patch = [uint64]$Matches[3]
    }
}

if ([string]::IsNullOrWhiteSpace($CurrentVersion)) {
    $versions = @(git tag --list 'v*' | ForEach-Object {
        if ($_ -match $versionPattern) {
            [pscustomobject]@{
                Tag   = $_
                Major = [uint64]$Matches[1]
                Minor = [uint64]$Matches[2]
                Patch = [uint64]$Matches[3]
            }
        }
    })

    if ($LASTEXITCODE -ne 0) {
        throw '無法讀取 Git 版本標籤。'
    }

    $latest = $versions | Sort-Object Major, Minor, Patch -Descending | Select-Object -First 1
    $current = if ($latest) {
        [pscustomobject]@{ Major = $latest.Major; Minor = $latest.Minor; Patch = $latest.Patch }
    } else {
        [pscustomobject]@{ Major = [uint64]0; Minor = [uint64]0; Patch = [uint64]0 }
    }
} else {
    $current = ConvertTo-VersionParts -Version $CurrentVersion
}

switch ($ChangeType) {
    Architecture {
        $current.Major++
        $current.Minor = 0
        $current.Patch = 0
    }
    Feature {
        $current.Minor++
        $current.Patch = 0
    }
    Fix {
        $current.Patch++
    }
}

"v$($current.Major).$($current.Minor).$($current.Patch)"
