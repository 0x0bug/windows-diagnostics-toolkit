[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('wdt-package-check-' + [guid]::NewGuid().ToString('N'))
$enginePath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$previousLastExitCode = $global:LASTEXITCODE

function Assert-PackageCondition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    $archivePathResolved = (Resolve-Path -LiteralPath $ArchivePath).ProviderPath
    $sourceRootResolved = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath
    $checksum = [IO.File]::ReadAllText($archivePathResolved + '.sha256')
    $checksumMatch = [regex]::Match($checksum, '^(?<Hash>[0-9a-f]{64})  (?<Name>[^\r\n]+)\r?\n?$')
    Assert-PackageCondition $checksumMatch.Success 'Package checksum format is invalid.'
    Assert-PackageCondition ($checksumMatch.Groups['Name'].Value -ceq [IO.Path]::GetFileName($archivePathResolved)) 'Package checksum names a different archive.'
    Assert-PackageCondition ((Get-FileHash -LiteralPath $archivePathResolved -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $checksumMatch.Groups['Hash'].Value) 'Package checksum does not match the archive.'

    $packageRoot = Join-Path $temporaryRoot 'package'
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    Expand-Archive -LiteralPath $archivePathResolved -DestinationPath $packageRoot
    $packageFiles = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File)
    foreach ($file in $packageFiles) {
        $relativePath = $file.FullName.Substring($packageRoot.Length + 1)
        $sourcePath = Join-Path $sourceRootResolved $relativePath
        Assert-PackageCondition (Test-Path -LiteralPath $sourcePath -PathType Leaf) ('Packaged file has no reviewed source: ' + $relativePath)
        Assert-PackageCondition ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) ('Packaged file differs from source: ' + $relativePath)
    }

    foreach ($document in @($packageFiles | Where-Object { $_.Extension -eq '.md' })) {
        foreach ($link in [regex]::Matches([IO.File]::ReadAllText($document.FullName), '\]\((?<Target>[^)\r\n]+)\)')) {
            $target = ($link.Groups['Target'].Value -split '#', 2)[0]
            if ([string]::IsNullOrWhiteSpace($target) -or $target -match '^(?:https?://|mailto:)') { continue }
            Assert-PackageCondition (Test-Path -LiteralPath (Join-Path $document.DirectoryName $target)) ('Broken packaged documentation link: ' + $document.Name + ' -> ' + $target)
        }
    }

    $entrypoint = Join-Path $packageRoot 'Invoke-WindowsDiagnostics.ps1'
    $version = ([IO.File]::ReadAllText((Join-Path $packageRoot 'VERSION'))).Trim()
    $commonArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entrypoint)
    $liveDirectory = Join-Path $temporaryRoot 'live'
    & $enginePath @commonArguments -Time -Performance -PrivacyMode -ExportMarkdown -OutputDirectory $liveDirectory *> $null
    Assert-PackageCondition ($LASTEXITCODE -eq 0) 'Packaged Time/Performance workflow failed.'

    $snapshots = @()
    foreach ($capture in @('before', 'after')) {
        $captureDirectory = Join-Path $temporaryRoot $capture
        & $enginePath @commonArguments -System -SaveSnapshot -PrivacyMode -ExportMarkdown -OutputDirectory $captureDirectory *> $null
        Assert-PackageCondition ($LASTEXITCODE -eq 0) ('Packaged snapshot workflow failed: ' + $capture)
        $jsonFiles = @(Get-ChildItem -LiteralPath $captureDirectory -Filter '*.json' -File)
        Assert-PackageCondition ($jsonFiles.Count -eq 1) 'Packaged snapshot workflow did not create one JSON file.'
        $snapshots += $jsonFiles[0].FullName
    }
    $beforeHash = (Get-FileHash -LiteralPath $snapshots[0] -Algorithm SHA256).Hash
    $afterHash = (Get-FileHash -LiteralPath $snapshots[1] -Algorithm SHA256).Hash
    & $enginePath @commonArguments -BeforeSnapshot $snapshots[0] -AfterSnapshot $snapshots[1] -PrivacyMode -ExportMarkdown -OutputDirectory (Join-Path $temporaryRoot 'comparison') *> $null
    Assert-PackageCondition ($LASTEXITCODE -eq 0) 'Packaged offline comparison workflow failed.'
    Assert-PackageCondition ($beforeHash -ceq (Get-FileHash -LiteralPath $snapshots[0] -Algorithm SHA256).Hash) 'Comparison changed its before snapshot.'
    Assert-PackageCondition ($afterHash -ceq (Get-FileHash -LiteralPath $snapshots[1] -Algorithm SHA256).Hash) 'Comparison changed its after snapshot.'

    $incidentAt = [datetimeoffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    & $enginePath @commonArguments -IncidentSymptom AppFailure -IncidentAt $incidentAt -PrivacyMode -ExportMarkdown -OutputDirectory (Join-Path $temporaryRoot 'incident') *> $null
    Assert-PackageCondition ($LASTEXITCODE -eq 0) 'Packaged incident workflow failed.'

    $reports = @(Get-ChildItem -LiteralPath $temporaryRoot -Recurse -File | Where-Object { $_.Extension -in @('.txt', '.md') -and -not $_.FullName.StartsWith($packageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) })
    Assert-PackageCondition ($reports.Count -eq 10) 'Package workflows did not produce five TXT/Markdown report pairs.'
    foreach ($report in $reports) {
        $text = [IO.File]::ReadAllText($report.FullName)
        Assert-PackageCondition (-not [string]::IsNullOrWhiteSpace($text)) 'Packaged workflow wrote an empty report.'
        Assert-PackageCondition ($text -notmatch '#< CLIXML|<Objs\b') 'Packaged report contains raw CLIXML.'
    }
    Write-Host ('Verified {0} packaged files against source; version {1}; all four package workflows passed in PowerShell {2}.' -f $packageFiles.Count, $version, $PSVersionTable.PSVersion)
}
finally {
    $global:LASTEXITCODE = $previousLastExitCode
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
