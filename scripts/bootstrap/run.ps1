& {
$ErrorActionPreference = 'Stop'

$wdtVersion = '0.1.0-beta'
$wdtArchiveName = 'windows-diagnostics-toolkit-v0.1.0-beta.zip'
$wdtReleaseBaseUri = 'https://github.com/0x0bug/windows-diagnostics-toolkit/releases/download/v0.1.0-beta'
$wdtArchiveUri = "$wdtReleaseBaseUri/$wdtArchiveName"
$wdtChecksumUri = "$wdtArchiveUri.sha256"

function Get-WdtExpectedChecksum {
    param([Parameter(Mandatory = $true)][string]$ChecksumText)

    $matches = @([System.Text.RegularExpressions.Regex]::Matches($ChecksumText, '(?im)(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])'))
    if ($matches.Count -ne 1) {
        throw 'The checksum file must contain exactly one valid SHA-256 value.'
    }

    return $matches[0].Value.ToLowerInvariant()
}

function Test-WdtArchiveHash {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    $actualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
    return [string]::Equals($actualHash, $ExpectedHash, [System.StringComparison]::OrdinalIgnoreCase)
}

function New-WdtTemporaryDirectory {
    $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('wdt-bootstrap-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Invoke-WdtDownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if ($Uri -notin @($wdtArchiveUri, $wdtChecksumUri)) {
        throw "Refusing unapproved download URL: $Uri"
    }

    Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
}

function Assert-WdtPackageLayout {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    foreach ($relativePath in @('Invoke-WindowsDiagnostics.ps1', 'VERSION')) {
        if (-not (Test-Path -LiteralPath (Join-Path -Path $PackageRoot -ChildPath $relativePath) -PathType Leaf)) {
            throw "The release package is missing: $relativePath"
        }
    }
    foreach ($relativePath in @('scripts', 'modules')) {
        if (-not (Test-Path -LiteralPath (Join-Path -Path $PackageRoot -ChildPath $relativePath) -PathType Container)) {
            throw "The release package is missing: $relativePath"
        }
    }

    $packagedVersion = (Get-Content -LiteralPath (Join-Path -Path $PackageRoot -ChildPath 'VERSION') -Raw).Trim()
    if ($packagedVersion -cne $wdtVersion) {
        throw "Unexpected packaged version: $packagedVersion"
    }
}

function Get-WdtCurrentPowerShellPath {
    $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([string]::IsNullOrWhiteSpace($processPath)) {
        throw 'Unable to determine the current PowerShell executable.'
    }
    return $processPath
}

function Invoke-WdtBootstrap {
    param(
        [scriptblock]$DownloadFile = ${function:Invoke-WdtDownloadFile},
        [scriptblock]$NewTemporaryDirectory = ${function:New-WdtTemporaryDirectory}
    )

    $temporaryDirectory = $null
    $previousProgressPreference = $ProgressPreference
    try {
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }

        $temporaryDirectory = & $NewTemporaryDirectory
        $archivePath = Join-Path -Path $temporaryDirectory -ChildPath $wdtArchiveName
        $checksumPath = "$archivePath.sha256"
        $packageRoot = Join-Path -Path $temporaryDirectory -ChildPath 'package'

        $ProgressPreference = 'SilentlyContinue'
        & $DownloadFile $wdtArchiveUri $archivePath
        & $DownloadFile $wdtChecksumUri $checksumPath
        $ProgressPreference = $previousProgressPreference

        $expectedHash = Get-WdtExpectedChecksum -ChecksumText (Get-Content -LiteralPath $checksumPath -Raw)
        if (-not (Test-WdtArchiveHash -ArchivePath $archivePath -ExpectedHash $expectedHash)) {
            throw 'Release archive SHA-256 verification failed. Nothing was extracted or executed.'
        }

        New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
        Expand-Archive -LiteralPath $archivePath -DestinationPath $packageRoot
        Assert-WdtPackageLayout -PackageRoot $packageRoot

        $entrypoint = Join-Path -Path $packageRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1'
        $powerShellPath = Get-WdtCurrentPowerShellPath
        & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $entrypoint
        $childExitCode = $LASTEXITCODE
        if ($childExitCode -ne 0) {
            throw "Windows Diagnostics Toolkit exited with code $childExitCode."
        }
    }
    finally {
        $ProgressPreference = $previousProgressPreference
        if (-not [string]::IsNullOrWhiteSpace($temporaryDirectory) -and (Test-Path -LiteralPath $temporaryDirectory)) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }
}

Invoke-WdtBootstrap
}
