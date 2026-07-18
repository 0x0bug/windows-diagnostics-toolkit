[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$versionPath = Join-Path -Path $repositoryRoot -ChildPath 'VERSION'
if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    throw "Release packaging requires VERSION: $versionPath"
}

$version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
$semanticPrereleasePattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*$'
if ($version -notmatch $semanticPrereleasePattern) {
    throw "VERSION must be a valid semantic prerelease version: $version"
}

$distDirectory = Join-Path -Path $repositoryRoot -ChildPath 'dist'
$archiveName = "windows-diagnostics-toolkit-v$version.zip"
$archivePath = Join-Path -Path $distDirectory -ChildPath $archiveName
$checksumPath = "$archivePath.sha256"
$stagingDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('wdt-release-' + [System.Guid]::NewGuid().ToString('N'))

$releasePaths = @(
    'Invoke-WindowsDiagnostics.ps1',
    'VERSION',
    'modules',
    'scripts',
    'README.md',
    'LICENSE',
    'SECURITY.md',
    'docs\usage.md',
    'docs\report-example.md'
)

try {
    New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null
    Remove-Item -LiteralPath $archivePath, $checksumPath -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null

    foreach ($relativePath in $releasePaths) {
        $sourcePath = Join-Path -Path $repositoryRoot -ChildPath $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Required release path is missing: $relativePath"
        }

        $destinationPath = Join-Path -Path $stagingDirectory -ChildPath $relativePath
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
    }

    Compress-Archive -Path (Join-Path -Path $stagingDirectory -ChildPath '*') -DestinationPath $archivePath -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumLine = '{0}  {1}' -f $hash, $archiveName
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($checksumPath, $checksumLine + [Environment]::NewLine, $utf8WithoutBom)

    Write-Host ("Release archive : {0}" -f $archivePath)
    Write-Host ("SHA-256         : {0}" -f $hash)
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}
