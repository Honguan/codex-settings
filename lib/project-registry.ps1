$script:CodexProjectRegistryPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexSettings\projects.json'

function Get-CodexProjectRegistryPath {
    [CmdletBinding()]
    param()

    return $script:CodexProjectRegistryPath
}

function Normalize-CodexProjectPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireExisting
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Project path cannot be empty.'
    }

    $normalized = if ($RequireExisting) {
        (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } else {
        [IO.Path]::GetFullPath($Path)
    }

    return $normalized.TrimEnd([char[]]'\/')
}

function Read-CodexProjectRegistry {
    [CmdletBinding()]
    param()

    $path = Get-CodexProjectRegistryPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            Version = 1
            UpdatedAt = $null
            Projects = @()
        }
    }

    try {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Invalid project registry: $path`n$($_.Exception.Message)"
    }

    $projects = New-Object 'System.Collections.Generic.List[object]'
    foreach ($project in @($data.Projects)) {
        $type = [string]$project.Type
        $projectPath = [string]$project.Path
        if ($type -notin @('Git', 'CVS') -or [string]::IsNullOrWhiteSpace($projectPath)) {
            continue
        }

        $duplicate = $false
        foreach ($existing in $projects) {
            if ([string]::Equals([string]$existing.Path, $projectPath, [StringComparison]::OrdinalIgnoreCase)) {
                $duplicate = $true
                break
            }
        }
        if ($duplicate) { continue }

        [void]$projects.Add([pscustomobject]@{
            Type = $type
            Path = $projectPath
            RegisteredAt = [string]$project.RegisteredAt
            LastInstalledAt = [string]$project.LastInstalledAt
        })
    }

    return [pscustomobject]@{
        Version = 1
        UpdatedAt = [string]$data.UpdatedAt
        Projects = @($projects)
    }
}

function Write-CodexProjectRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Registry)

    $path = Get-CodexProjectRegistryPath
    $directory = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $payload = [ordered]@{
        Version = 1
        UpdatedAt = (Get-Date).ToString('o')
        Projects = @($Registry.Projects | Sort-Object Type, Path)
    }

    $temporaryPath = Join-Path $directory ('.projects-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            ($payload | ConvertTo-Json -Depth 8),
            (New-Object Text.UTF8Encoding($false))
        )
        Move-Item -LiteralPath $temporaryPath -Destination $path -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }

    return $path
}

function Register-CodexProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Git', 'CVS')][string]$Type,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $normalizedPath = Normalize-CodexProjectPath -Path $Path -RequireExisting
    $registry = Read-CodexProjectRegistry
    $now = (Get-Date).ToString('o')
    $projects = New-Object 'System.Collections.Generic.List[object]'
    $registered = $null

    foreach ($project in @($registry.Projects)) {
        if ([string]::Equals([string]$project.Path, $normalizedPath, [StringComparison]::OrdinalIgnoreCase)) {
            $registeredAt = [string]$project.RegisteredAt
            if ([string]::IsNullOrWhiteSpace($registeredAt)) { $registeredAt = $now }
            $registered = [pscustomobject]@{
                Type = $Type
                Path = $normalizedPath
                RegisteredAt = $registeredAt
                LastInstalledAt = $now
            }
            [void]$projects.Add($registered)
        } else {
            [void]$projects.Add($project)
        }
    }

    if ($null -eq $registered) {
        $registered = [pscustomobject]@{
            Type = $Type
            Path = $normalizedPath
            RegisteredAt = $now
            LastInstalledAt = $now
        }
        [void]$projects.Add($registered)
    }

    $registry.Projects = @($projects)
    [void](Write-CodexProjectRegistry -Registry $registry)
    return $registered
}

function Unregister-CodexProject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalizedPath = Normalize-CodexProjectPath -Path $Path
    $registry = Read-CodexProjectRegistry
    $remaining = @($registry.Projects | Where-Object {
        -not [string]::Equals([string]$_.Path, $normalizedPath, [StringComparison]::OrdinalIgnoreCase)
    })

    if ($remaining.Count -eq @($registry.Projects).Count) {
        return $false
    }

    $registry.Projects = $remaining
    [void](Write-CodexProjectRegistry -Registry $registry)
    return $true
}

function Get-RegisteredCodexProjects {
    [CmdletBinding()]
    param()

    return @((Read-CodexProjectRegistry).Projects | Sort-Object Type, Path)
}
