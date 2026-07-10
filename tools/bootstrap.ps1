[CmdletBinding()]
param()

function Get-WdtBootstrapDownloadUri {
    return 'https://github.com/0x0bug/windows-diagnostics-toolkit/archive/refs/heads/main.zip'
}

function Test-WdtBootstrapPowerShellVersion {
    param([Parameter(Mandatory = $true)][version]$Version)

    return $Version -ge [version]'5.1'
}

function Get-WdtBootstrapTempBasePath {
    param([Parameter(Mandatory = $true)][string]$TempPath)

    if ([string]::IsNullOrWhiteSpace($TempPath)) {
        throw 'The TEMP environment variable is not available.'
    }

    return [System.IO.Path]::GetFullPath($TempPath)
}

function Get-WdtBootstrapTempRootPath {
    param(
        [Parameter(Mandatory = $true)][string]$TempBasePath,
        [guid]$Identifier = [guid]::NewGuid()
    )

    $name = 'wdt-bootstrap-{0}' -f $Identifier.ToString('N')
    return [System.IO.Path]::GetFullPath((Join-Path -Path $TempBasePath -ChildPath $name))
}

function Test-WdtBootstrapPathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$RootPath
    )

    try {
        $candidateFullPath = [System.IO.Path]::GetFullPath($CandidatePath)
        $rootFullPath = [System.IO.Path]::GetFullPath($RootPath).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        $rootPrefix = $rootFullPath + [System.IO.Path]::DirectorySeparatorChar
        return $candidateFullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Test-WdtBootstrapOwnedTempRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TempBasePath
    )

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $leafName = Split-Path -Path $fullPath -Leaf
        return $leafName -match '^wdt-bootstrap-[0-9a-f]{32}$' -and
            (Test-WdtBootstrapPathWithin -CandidatePath $fullPath -RootPath $TempBasePath)
    }
    catch {
        return $false
    }
}

function Get-WdtBootstrapInitialOutputDirectory {
    param([Parameter(Mandatory = $true)][string]$CallerDirectory)

    if ([string]::IsNullOrWhiteSpace($CallerDirectory)) {
        throw 'The caller working directory is not available.'
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $CallerDirectory -ChildPath 'WindowsDiagnosticsReports'))
}

function Get-WdtBootstrapRequiredFile {
    return @(
        'Invoke-WindowsDiagnostics.ps1'
        'scripts\validate.ps1'
        'scripts\validation-policy.ps1'
        'scripts\tui.ps1'
    )
}

function Get-WdtBootstrapMissingRequiredFile {
    param([AllowEmptyCollection()][string[]]$RelativePaths)

    $normalizedPaths = @($RelativePaths | ForEach-Object { ([string]$_).Replace('/', '\') })
    foreach ($requiredFile in @(Get-WdtBootstrapRequiredFile)) {
        if ($requiredFile -notin $normalizedPaths) {
            Write-Output $requiredFile
        }
    }
}

function Test-WdtBootstrapSingleArchiveRoot {
    param([AllowEmptyCollection()][object[]]$Items)

    return @($Items).Count -eq 1 -and [bool]$Items[0].PSIsContainer
}

function Get-WdtBootstrapArchiveRoot {
    param([Parameter(Mandatory = $true)][string]$ExtractPath)

    $items = @(Get-ChildItem -LiteralPath $ExtractPath -Force -ErrorAction Stop)
    if (-not (Test-WdtBootstrapSingleArchiveRoot -Items $items)) {
        throw 'The downloaded archive must contain exactly one root directory.'
    }

    return $items[0].FullName
}

function Assert-WdtBootstrapToolkitRoot {
    param([Parameter(Mandatory = $true)][string]$ToolkitRoot)

    $presentFiles = New-Object System.Collections.Generic.List[string]
    foreach ($relativePath in @(Get-WdtBootstrapRequiredFile)) {
        $candidatePath = Join-Path -Path $ToolkitRoot -ChildPath $relativePath
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $presentFiles.Add($relativePath)
        }
    }

    $missingFiles = @(Get-WdtBootstrapMissingRequiredFile -RelativePaths @($presentFiles.ToArray()))
    if ($missingFiles.Count -gt 0) {
        throw ('The downloaded toolkit is missing required files: {0}' -f ($missingFiles -join ', '))
    }
}

function Remove-WdtBootstrapTempRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TempBasePath
    )

    if (-not (Test-WdtBootstrapOwnedTempRoot -Path $Path -TempBasePath $TempBasePath)) {
        throw "Refusing to remove a path outside the owned bootstrap workspace: $Path"
    }

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
}

function Invoke-WdtBootstrap {
    [CmdletBinding()]
    param()

    $exitCode = 0
    $stage = 'checking prerequisites'
    $tempBasePath = $null
    $tempRootPath = $null
    $tlsChanged = $false
    $originalSecurityProtocol = $null

    try {
        if (-not (Test-WdtBootstrapPowerShellVersion -Version $PSVersionTable.PSVersion)) {
            throw ('PowerShell 5.1 or later is required. Current version: {0}' -f $PSVersionTable.PSVersion)
        }

        $callerDirectory = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path
        $outputDirectory = Get-WdtBootstrapInitialOutputDirectory -CallerDirectory $callerDirectory

        $stage = 'creating the temporary workspace'
        $tempBasePath = Get-WdtBootstrapTempBasePath -TempPath $env:TEMP
        $tempRootPath = Get-WdtBootstrapTempRootPath -TempBasePath $tempBasePath
        if (-not (Test-WdtBootstrapOwnedTempRoot -Path $tempRootPath -TempBasePath $tempBasePath)) {
            throw 'The temporary workspace path is outside TEMP.'
        }
        if (Test-WdtBootstrapPathWithin -CandidatePath $outputDirectory -RootPath $tempRootPath) {
            throw 'The report output directory must be outside the temporary bootstrap workspace.'
        }

        New-Item -ItemType Directory -Path $tempRootPath -ErrorAction Stop | Out-Null

        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $originalSecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol
            $tls12 = [System.Net.SecurityProtocolType]::Tls12
            if (($originalSecurityProtocol -band $tls12) -ne $tls12) {
                [System.Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol -bor $tls12
                $tlsChanged = $true
            }
        }

        $archivePath = Join-Path -Path $tempRootPath -ChildPath 'toolkit.zip'
        $extractPath = Join-Path -Path $tempRootPath -ChildPath 'toolkit'

        Write-Host 'Downloading Windows Diagnostics Toolkit from GitHub...'
        Write-Host 'No reports or diagnostic data are uploaded.'
        $stage = 'downloading the toolkit from GitHub'
        $downloadUri = Get-WdtBootstrapDownloadUri
        Invoke-RestMethod -Uri $downloadUri -OutFile $archivePath -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or (Get-Item -LiteralPath $archivePath).Length -le 0) {
            throw 'The toolkit ZIP was not downloaded.'
        }

        $stage = 'expanding the downloaded archive'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force -ErrorAction Stop

        $stage = 'checking the downloaded archive'
        $toolkitRoot = Get-WdtBootstrapArchiveRoot -ExtractPath $extractPath
        Assert-WdtBootstrapToolkitRoot -ToolkitRoot $toolkitRoot

        $validationPath = Join-Path -Path $toolkitRoot -ChildPath 'scripts\validate.ps1'
        $entrypointPath = Join-Path -Path $toolkitRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1'

        Write-Host 'Validating downloaded toolkit...'
        $stage = 'validating the downloaded toolkit'
        $LASTEXITCODE = 0
        & $validationPath
        if ($LASTEXITCODE -ne 0) {
            throw ("Downloaded toolkit validation failed with exit code {0}." -f $LASTEXITCODE)
        }

        Write-Host 'Starting interactive diagnostics...'
        $stage = 'starting interactive diagnostics'
        $LASTEXITCODE = 0
        & $entrypointPath -Interactive -OutputDirectory $outputDirectory
        if ($LASTEXITCODE -ne 0) {
            $exitCode = $LASTEXITCODE
        }
    }
    catch {
        $exitCode = 1
        $detail = $_.Exception.Message -replace '\s*\r?\n\s*', ' '
        Write-Host ("Bootstrap failed while {0}: {1}" -f $stage, $detail) -ForegroundColor Red
    }
    finally {
        if ($tlsChanged) {
            try {
                [System.Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
            }
            catch {
                $exitCode = 1
                Write-Warning ('Failed to restore the process TLS setting: {0}' -f $_.Exception.Message)
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($tempRootPath)) {
            try {
                Remove-WdtBootstrapTempRoot -Path $tempRootPath -TempBasePath $tempBasePath
            }
            catch {
                $exitCode = 1
                Write-Warning ('Failed to remove the temporary bootstrap workspace: {0}' -f $_.Exception.Message)
            }
        }
    }

    return $exitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    $bootstrapExitCode = Invoke-WdtBootstrap
    if ($bootstrapExitCode -ne 0) {
        exit $bootstrapExitCode
    }
}
