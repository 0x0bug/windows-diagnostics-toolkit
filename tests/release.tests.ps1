[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$versionPath = Join-Path -Path $repositoryRoot -ChildPath 'VERSION'
$buildScript = Join-Path -Path $repositoryRoot -ChildPath 'scripts\build-release.ps1'
$bootstrapScript = Join-Path -Path $repositoryRoot -ChildPath 'site\run.ps1'
$entrypoint = Join-Path -Path $repositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1'
$powerShellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$temporaryRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('wdt-release-tests-' + [System.Guid]::NewGuid().ToString('N'))

Assert-True (Test-Path -LiteralPath $versionPath -PathType Leaf) 'VERSION is missing.'
$version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
$semanticPrereleasePattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*$'
Assert-True ($version -match $semanticPrereleasePattern) 'VERSION is not a valid semantic prerelease version.'
Assert-Equal '0.1.0-beta' $version 'Unexpected release version.'
$distDirectory = Join-Path -Path $repositoryRoot -ChildPath 'dist'
$archiveName = "windows-diagnostics-toolkit-v$version.zip"
$archivePath = Join-Path -Path $distDirectory -ChildPath $archiveName
$checksumPath = "$archivePath.sha256"
$distDirectoryExisted = Test-Path -LiteralPath $distDirectory -PathType Container
$releaseBuildStarted = $false

foreach ($scriptPath in @($buildScript, $bootstrapScript)) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-Equal 0 @($parseErrors).Count "Script does not parse in $($PSVersionTable.PSVersion): $scriptPath"
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $sourceReportDirectory = Join-Path -Path $temporaryRoot -ChildPath 'source-report'
    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $entrypoint -System -ExportMarkdown -OutputDirectory $sourceReportDirectory *> $null
    Assert-Equal 0 $LASTEXITCODE 'Source checkout System report failed.'

    $textReport = @(Get-ChildItem -LiteralPath $sourceReportDirectory -Filter 'WindowsDiagnosticsReport-*.txt' -File)
    $markdownReport = @(Get-ChildItem -LiteralPath $sourceReportDirectory -Filter 'WindowsDiagnosticsReport-*.md' -File)
    Assert-Equal 1 $textReport.Count 'Expected exactly one TXT report.'
    Assert-Equal 1 $markdownReport.Count 'Expected exactly one Markdown report.'
    Assert-True ((Get-Content -LiteralPath $textReport[0].FullName -Raw).Contains("Toolkit version : $version")) 'TXT report is missing the toolkit version.'
    Assert-True ((Get-Content -LiteralPath $markdownReport[0].FullName -Raw).Contains("Toolkit version : $version")) 'Markdown report is missing the toolkit version.'

    $releaseBuildStarted = $true
    & $buildScript *> $null
    Assert-True (Test-Path -LiteralPath $archivePath -PathType Leaf) 'Release build did not create the expected ZIP.'
    Assert-True (Test-Path -LiteralPath $checksumPath -PathType Leaf) 'Release build did not create the checksum file.'

    $checksumText = Get-Content -LiteralPath $checksumPath -Raw
    $checksumMatch = [regex]::Match($checksumText, '^(?<Hash>[0-9a-f]{64})  (?<Name>[^\r\n]+)\r?\n?$')
    Assert-True $checksumMatch.Success 'Checksum file is not in conventional SHA-256 format.'
    Assert-Equal $archiveName $checksumMatch.Groups['Name'].Value 'Checksum filename does not match the ZIP.'
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $actualHash $checksumMatch.Groups['Hash'].Value 'Checksum does not match the ZIP.'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entries = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    }
    finally {
        $archive.Dispose()
    }

    foreach ($requiredFile in @('Invoke-WindowsDiagnostics.ps1', 'VERSION', 'README.md', 'LICENSE', 'SECURITY.md', 'docs/usage.md', 'docs/report-example.md', 'scripts/build-release.ps1')) {
        Assert-True ($entries -contains $requiredFile) "Archive is missing: $requiredFile"
    }
    foreach ($requiredDirectory in @('modules/', 'scripts/')) {
        Assert-True (@($entries | Where-Object { $_.StartsWith($requiredDirectory, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) "Archive is missing directory content: $requiredDirectory"
    }

    foreach ($forbiddenDirectory in @('.git/', '.github/', 'tests/', 'site/', 'dist/')) {
        Assert-Equal 0 @($entries | Where-Object { $_.StartsWith($forbiddenDirectory, [System.StringComparison]::OrdinalIgnoreCase) }).Count "Archive contains forbidden directory: $forbiddenDirectory"
    }
    Assert-Equal 0 @($entries | Where-Object { $_ -match '(^|/)(WindowsDiagnosticsReport-.*\.(txt|md)|.*\.(tmp|temp))$' }).Count 'Archive contains generated reports or temporary files.'
    Assert-True ($entries -contains 'VERSION') 'Archive has an extra top-level wrapper directory.'

    $extractedRoot = Join-Path -Path $temporaryRoot -ChildPath 'extracted'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractedRoot
    $extractedReportDirectory = Join-Path -Path $temporaryRoot -ChildPath 'extracted-report'
    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $extractedRoot 'Invoke-WindowsDiagnostics.ps1') -System -OutputDirectory $extractedReportDirectory *> $null
    Assert-Equal 0 $LASTEXITCODE 'Extracted release System report failed.'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $extractedReportDirectory -Filter 'WindowsDiagnosticsReport-*.txt' -File).Count 'Extracted release did not create a TXT report.'

    $bootstrapTokens = $null
    $bootstrapErrors = $null
    $bootstrapSource = Get-Content -LiteralPath $bootstrapScript -Raw
    $bootstrapAst = [System.Management.Automation.Language.Parser]::ParseFile($bootstrapScript, [ref]$bootstrapTokens, [ref]$bootstrapErrors)
    Assert-Equal 0 @($bootstrapErrors).Count 'Bootstrap AST parse failed.'

    $bootstrapFunctionNames = @('Get-WdtExpectedChecksum', 'Test-WdtArchiveHash', 'New-WdtTemporaryDirectory', 'Invoke-WdtDownloadFile', 'Assert-WdtPackageLayout', 'Get-WdtCurrentPowerShellPath', 'Invoke-WdtBootstrap')
    $bootstrapVariableNames = @('WdtVersion', 'WdtArchiveName', 'WdtReleaseBaseUri', 'WdtArchiveUri', 'WdtChecksumUri')
    foreach ($functionName in $bootstrapFunctionNames) {
        Assert-True ($null -eq (Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue)) "Bootstrap scope fixture requires an undefined function: $functionName"
    }
    foreach ($variableName in $bootstrapVariableNames) {
        Assert-True ($null -eq (Get-Variable -Name $variableName -Scope Script -ErrorAction SilentlyContinue)) "Bootstrap scope fixture requires an undefined variable: $variableName"
    }

    $scopeFixtureDirectory = Join-Path -Path $temporaryRoot -ChildPath 'scope-bootstrap'
    $escapedScopeFixtureDirectory = $scopeFixtureDirectory.Replace("'", "''")
    $offlineScopeInvocation = @"
Invoke-WdtBootstrap -NewTemporaryDirectory {
    New-Item -ItemType Directory -Path '$escapedScopeFixtureDirectory' -Force | Out-Null
    return '$escapedScopeFixtureDirectory'
} -DownloadFile { throw 'Offline scope fixture.' }
"@
    $scopeBootstrapSource = [regex]::Replace(
        $bootstrapSource,
        '(?m)^Invoke-WdtBootstrap\s*$',
        [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $offlineScopeInvocation }
    )
    Assert-True ($scopeBootstrapSource -cne $bootstrapSource) 'Bootstrap scope fixture did not replace the terminal invocation.'
    $callerErrorActionPreference = $ErrorActionPreference
    $scopeFixtureError = $null
    try {
        $ErrorActionPreference = 'Continue'
        try { Invoke-Expression $scopeBootstrapSource }
        catch { $scopeFixtureError = $_.Exception.Message }
        Assert-Equal 'Continue' $ErrorActionPreference 'IEX-like bootstrap execution changed the caller ErrorActionPreference.'
        foreach ($functionName in $bootstrapFunctionNames) {
            Assert-True ($null -eq (Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue)) "IEX-like bootstrap execution leaked a function: $functionName"
        }
        foreach ($variableName in $bootstrapVariableNames) {
            Assert-True ($null -eq (Get-Variable -Name $variableName -Scope Script -ErrorAction SilentlyContinue)) "IEX-like bootstrap execution leaked a variable: $variableName"
        }
    }
    finally {
        $ErrorActionPreference = $callerErrorActionPreference
    }
    Assert-Equal 'Offline scope fixture.' $scopeFixtureError 'IEX-like bootstrap scope fixture did not use the offline downloader.'
    Assert-True (-not (Test-Path -LiteralPath $scopeFixtureDirectory)) 'IEX-like bootstrap scope fixture did not clean its temporary directory.'

    foreach ($functionName in @('Get-WdtExpectedChecksum', 'Test-WdtArchiveHash', 'New-WdtTemporaryDirectory', 'Assert-WdtPackageLayout', 'Get-WdtCurrentPowerShellPath', 'Invoke-WdtBootstrap')) {
        $definition = $bootstrapAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
            }, $true)
        Assert-True ($null -ne $definition) "Missing bootstrap function: $functionName"
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $wdtVersion = $version
    $wdtArchiveName = $archiveName
    $wdtReleaseBaseUri = 'https://github.com/0x0bug/windows-diagnostics-toolkit/releases/download/v0.1.0-beta'
    $wdtArchiveUri = "$wdtReleaseBaseUri/$wdtArchiveName"
    $wdtChecksumUri = "$wdtArchiveUri.sha256"

    Assert-Equal $actualHash (Get-WdtExpectedChecksum -ChecksumText $checksumText) 'Bootstrap checksum parser rejected the release checksum.'
    $multipleChecksumError = $null
    try { Get-WdtExpectedChecksum -ChecksumText ($actualHash + "`n" + $actualHash) | Out-Null }
    catch { $multipleChecksumError = $_.Exception.Message }
    Assert-True (-not [string]::IsNullOrWhiteSpace($multipleChecksumError)) 'Bootstrap checksum parser accepted more than one SHA-256 value.'
    Assert-True (Test-WdtArchiveHash -ArchivePath $archivePath -ExpectedHash $actualHash) 'Bootstrap hash validation rejected the correct hash.'
    $modifiedArchive = Join-Path -Path $temporaryRoot -ChildPath 'modified.zip'
    Copy-Item -LiteralPath $archivePath -Destination $modifiedArchive
    Add-Content -LiteralPath $modifiedArchive -Value 'modified'
    Assert-True (-not (Test-WdtArchiveHash -ArchivePath $modifiedArchive -ExpectedHash $actualHash)) 'Bootstrap hash validation accepted a modified archive.'

    $downloadReferences = @([regex]::Matches($bootstrapSource, '(?i)https?://[^''"\s]+') | ForEach-Object Value)
    Assert-Equal 1 $downloadReferences.Count 'Bootstrap must contain exactly one fixed URL base.'
    Assert-Equal 'https://github.com/0x0bug/windows-diagnostics-toolkit/releases/download/v0.1.0-beta' $downloadReferences[0] 'Bootstrap references an unapproved download host or path.'
    Assert-True ($bootstrapSource -notmatch '(?i)(/main/|/master/|raw\.githubusercontent\.com|gist\.github(?:usercontent)?\.com)') 'Bootstrap contains a forbidden branch, raw, or gist download reference.'
    Assert-True ($bootstrapSource -notmatch '(?m)^\s*exit\b') 'Bootstrap must not use exit.'
    Assert-True ($bootstrapSource -notmatch '\bStart-Process\b') 'Bootstrap must launch the child PowerShell process in the current console.'

    $offlinePackageRoot = Join-Path -Path $temporaryRoot -ChildPath 'offline-bootstrap-package'
    $offlineArchive = Join-Path -Path $temporaryRoot -ChildPath 'offline-bootstrap.zip'
    $offlineChecksum = "$offlineArchive.sha256"
    New-Item -ItemType Directory -Path (Join-Path $offlinePackageRoot 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $offlinePackageRoot 'modules') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $offlinePackageRoot 'VERSION'), $version, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $offlinePackageRoot 'scripts\fixture.txt'), 'fixture', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $offlinePackageRoot 'modules\fixture.txt'), 'fixture', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText(
        (Join-Path $offlinePackageRoot 'Invoke-WindowsDiagnostics.ps1'),
        "`$initialLocation = (Get-Location).Path`r`n[System.IO.File]::WriteAllText(`$env:WDT_BOOTSTRAP_TEST_CWD_FILE, `$initialLocation, [System.Text.Encoding]::UTF8)`r`nSet-Location -LiteralPath ([System.IO.Path]::GetTempPath())`r`nexit 23`r`n",
        [System.Text.Encoding]::UTF8
    )
    Compress-Archive -Path (Join-Path $offlinePackageRoot '*') -DestinationPath $offlineArchive
    $offlineHash = (Get-FileHash -LiteralPath $offlineArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText($offlineChecksum, ($offlineHash + "  $archiveName`r`n"), [System.Text.Encoding]::UTF8)

    $offlineDownloads = New-Object System.Collections.Generic.List[string]
    $originalLocation = (Get-Location).Path
    $childWorkingDirectoryPath = Join-Path -Path $temporaryRoot -ChildPath 'child-working-directory.txt'
    $childWorkingDirectoryVariable = 'WDT_BOOTSTRAP_TEST_CWD_FILE'
    $previousChildWorkingDirectoryOutput = [System.Environment]::GetEnvironmentVariable($childWorkingDirectoryVariable, 'Process')
    $previousLastExitCode = $global:LASTEXITCODE
    $childExitError = $null
    try {
        [System.Environment]::SetEnvironmentVariable($childWorkingDirectoryVariable, $childWorkingDirectoryPath, 'Process')
        try {
            Invoke-WdtBootstrap -DownloadFile {
                param($Uri, $Destination)
                [void]$offlineDownloads.Add($Uri)
                $source = if ($Destination.EndsWith('.sha256')) { $offlineChecksum } else { $offlineArchive }
                Copy-Item -LiteralPath $source -Destination $Destination
            }
        }
        catch {
            $childExitError = $_.Exception.Message
        }
        Assert-Equal 'Windows Diagnostics Toolkit exited with code 23.' $childExitError 'Bootstrap did not propagate the child process exit code.'
        Assert-Equal $originalLocation (Get-Location).Path 'Bootstrap changed the caller working directory.'
        Assert-True (Test-Path -LiteralPath $childWorkingDirectoryPath -PathType Leaf) 'Bootstrap child did not record its initial working directory.'
        Assert-Equal $originalLocation (Get-Content -LiteralPath $childWorkingDirectoryPath -Raw) 'Bootstrap child did not inherit the caller working directory.'
        Assert-Equal 2 $offlineDownloads.Count 'Offline bootstrap fixture did not handle both downloads locally.'
        Assert-True ($offlineDownloads -contains $wdtArchiveUri) 'Offline bootstrap fixture did not receive the release archive URL.'
        Assert-True ($offlineDownloads -contains $wdtChecksumUri) 'Offline bootstrap fixture did not receive the checksum URL.'
    }
    finally {
        [System.Environment]::SetEnvironmentVariable($childWorkingDirectoryVariable, $previousChildWorkingDirectoryOutput, 'Process')
        $global:LASTEXITCODE = $previousLastExitCode
    }

    $cleanupDirectory = Join-Path -Path $temporaryRoot -ChildPath 'bootstrap-cleanup'
    $cleanupError = $null
    try {
        Invoke-WdtBootstrap -NewTemporaryDirectory {
            New-Item -ItemType Directory -Path $cleanupDirectory -Force | Out-Null
            return $cleanupDirectory
        } -DownloadFile { throw 'Offline cleanup fixture.' }
    }
    catch {
        $cleanupError = $_.Exception.Message
    }
    Assert-Equal 'Offline cleanup fixture.' $cleanupError 'Bootstrap cleanup fixture did not fail at the injected download.'
    Assert-True (-not (Test-Path -LiteralPath $cleanupDirectory)) 'Bootstrap did not remove its temporary directory after failure.'
}
finally {
    if ($releaseBuildStarted) {
        foreach ($releaseArtifactPath in @($archivePath, $checksumPath)) {
            if (Test-Path -LiteralPath $releaseArtifactPath -PathType Leaf) {
                Remove-Item -LiteralPath $releaseArtifactPath -Force
            }
        }
    }
    if (-not $distDirectoryExisted -and (Test-Path -LiteralPath $distDirectory -PathType Container)) {
        $remainingDistItems = @(Get-ChildItem -LiteralPath $distDirectory -Force)
        if ($remainingDistItems.Count -eq 0) {
            Remove-Item -LiteralPath $distDirectory -Force
        }
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host ("Release tests passed with PowerShell {0}." -f $PSVersionTable.PSVersion)
