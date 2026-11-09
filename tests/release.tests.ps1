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
$bootstrapScript = Join-Path -Path $repositoryRoot -ChildPath 'scripts\bootstrap\run.ps1'
$entrypoint = Join-Path -Path $repositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1'
$powerShellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$temporaryRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('wdt-release-tests-' + [System.Guid]::NewGuid().ToString('N'))

Assert-True (Test-Path -LiteralPath $versionPath -PathType Leaf) 'VERSION is missing.'
$version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
$semanticPrereleasePattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*$'
Assert-True ($version -match $semanticPrereleasePattern) 'VERSION is not a valid semantic prerelease version.'
Assert-Equal '0.2.0-beta.2' $version 'Unexpected release version.'
$isolatedRepositoryRoot = Join-Path -Path $temporaryRoot -ChildPath 'repository'
$distDirectory = Join-Path -Path $isolatedRepositoryRoot -ChildPath 'dist'
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
    # The build script writes to the repository containing itself. Stage its release
    # inputs in this unique temporary checkout so the real dist directory is untouched.
    foreach ($relativePath in @('Invoke-WindowsDiagnostics.ps1', 'VERSION', 'modules', 'scripts', 'README.md', 'LICENSE', 'SECURITY.md', 'docs\usage.md', 'docs\report-example.md')) {
        $sourcePath = Join-Path -Path $repositoryRoot -ChildPath $relativePath
        $destinationPath = Join-Path -Path $isolatedRepositoryRoot -ChildPath $relativePath
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
    }
    $buildScript = Join-Path -Path $isolatedRepositoryRoot -ChildPath 'scripts\build-release.ps1'
    $bootstrapScript = Join-Path -Path $isolatedRepositoryRoot -ChildPath 'scripts\bootstrap\run.ps1'
    $isolatedSentinelDirectory = Join-Path -Path $distDirectory -ChildPath 'preexisting-sentinel'
    New-Item -ItemType Directory -Path $isolatedSentinelDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $isolatedSentinelDirectory 'unrelated.zip'), 'sentinel zip')
    [System.IO.File]::WriteAllText((Join-Path $isolatedSentinelDirectory 'unrelated.zip.sha256'), 'sentinel checksum')
    [System.IO.File]::WriteAllText((Join-Path $isolatedSentinelDirectory 'keep.txt'), 'sentinel other dist file')

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
    Assert-Equal 'sentinel zip' ([System.IO.File]::ReadAllText((Join-Path $isolatedSentinelDirectory 'unrelated.zip'))) 'Release build changed a preexisting unrelated ZIP.'
    Assert-Equal 'sentinel checksum' ([System.IO.File]::ReadAllText((Join-Path $isolatedSentinelDirectory 'unrelated.zip.sha256'))) 'Release build changed a preexisting unrelated checksum.'
    Assert-Equal 'sentinel other dist file' ([System.IO.File]::ReadAllText((Join-Path $isolatedSentinelDirectory 'keep.txt'))) 'Release build changed another preexisting dist file.'

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

    foreach ($forbiddenDirectory in @('.git/', '.github/', 'tests/', 'site/', 'dist/', 'docs/superpowers/')) {
        Assert-Equal 0 @($entries | Where-Object { $_.StartsWith($forbiddenDirectory, [System.StringComparison]::OrdinalIgnoreCase) }).Count "Archive contains forbidden directory: $forbiddenDirectory"
    }
    Assert-Equal 0 @($entries | Where-Object { $_ -match '(^|/)(WindowsDiagnostics(?:Report|Comparison|Incident)-.*\.(txt|md)|WindowsDiagnosticsSnapshot-.*\.json|.*\.(tmp|temp))$' }).Count 'Archive contains generated reports, snapshots, or temporary files.'
    Assert-True ($entries -contains 'VERSION') 'Archive has an extra top-level wrapper directory.'

    $extractedRoot = Join-Path -Path $temporaryRoot -ChildPath 'extracted'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractedRoot
    $extractedReportDirectory = Join-Path -Path $temporaryRoot -ChildPath 'extracted-report'
    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File (Join-Path $extractedRoot 'Invoke-WindowsDiagnostics.ps1') -System -ExportMarkdown -OutputDirectory $extractedReportDirectory *> $null
    Assert-Equal 0 $LASTEXITCODE 'Extracted release System report failed.'
    foreach ($extension in @('txt','md')) {
        $extractedReports = @(Get-ChildItem -LiteralPath $extractedReportDirectory -Filter ("WindowsDiagnosticsReport-*.$extension") -File)
        Assert-Equal 1 $extractedReports.Count "Extracted release did not create exactly one $extension report."
        $extractedReportText = Get-Content -LiteralPath $extractedReports[0].FullName -Raw
        Assert-True ($extractedReportText.Contains("Toolkit version : $version")) "Extracted release $extension report has the wrong version."
        Assert-True ($extractedReportText -notmatch '#< CLIXML|<Objs\b') "Extracted release $extension report contains serialized CLIXML."
    }

    $bootstrapTokens = $null
    $bootstrapErrors = $null
    $bootstrapSource = Get-Content -LiteralPath $bootstrapScript -Raw
    $bootstrapAst = [System.Management.Automation.Language.Parser]::ParseFile($bootstrapScript, [ref]$bootstrapTokens, [ref]$bootstrapErrors)
    $expectedBootstrapConstants = @{
        wdtVersion = $version
        wdtArchiveName = $archiveName
        wdtReleaseBaseUri = "https://github.com/0x0bug/windows-diagnostics-toolkit/releases/download/v$version"
    }
    foreach ($constantName in $expectedBootstrapConstants.Keys) {
        $assignments = @($bootstrapAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -ceq $constantName
        }, $true))
        Assert-Equal 1 $assignments.Count "Bootstrap must assign exactly one release constant: $constantName"
        Assert-True ($assignments[0].Right -is [System.Management.Automation.Language.CommandExpressionAst] -and $assignments[0].Right.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) "Bootstrap release constant must be a string literal: $constantName"
        Assert-Equal $expectedBootstrapConstants[$constantName] $assignments[0].Right.Expression.Value "Bootstrap release constant does not match VERSION: $constantName"
    }
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

    foreach ($functionName in $bootstrapFunctionNames) {
        $definition = $bootstrapAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
            }, $true)
        Assert-True ($null -ne $definition) "Missing bootstrap function: $functionName"
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $wdtVersion = $version
    $wdtArchiveName = $archiveName
    $wdtReleaseBaseUri = 'https://github.com/0x0bug/windows-diagnostics-toolkit/releases/download/v0.2.0-beta.2'
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
    Assert-Equal 'https://github.com/0x0bug/windows-diagnostics-toolkit/releases/download/v0.2.0-beta.2' $downloadReferences[0] 'Bootstrap references an unapproved download host or path.'
    Assert-True ($bootstrapSource -notmatch '(?i)(/main/|/master/|raw\.githubusercontent\.com|gist\.github(?:usercontent)?\.com)') 'Bootstrap contains a forbidden branch, raw, or gist download reference.'
    Assert-True ($bootstrapSource -notmatch '(?m)^\s*exit\b') 'Bootstrap must not use exit.'
    Assert-True ($bootstrapSource -notmatch '\bStart-Process\b') 'Bootstrap must launch the child PowerShell process in the current console.'

    & {
        $requestCalls = New-Object System.Collections.Generic.List[object]
        $timeoutUri = $null
        function Invoke-WebRequest {
            [CmdletBinding()]
            param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [int]$TimeoutSec, [int]$OperationTimeoutSeconds)
            [void]$requestCalls.Add([pscustomobject]@{ Uri = $Uri; OutFile = $OutFile; UseBasicParsing = [bool]$UseBasicParsing; TimeoutSec = $TimeoutSec; OperationTimeoutSeconds = $OperationTimeoutSeconds; Progress = [string]$ProgressPreference })
            [System.IO.File]::WriteAllText($OutFile, 'offline download fixture')
            if ($Uri -eq $timeoutUri) {
                throw [System.Net.WebException]::new('Offline request timeout fixture.', [System.Net.WebExceptionStatus]::Timeout)
            }
        }

        Invoke-WdtDownloadFile -Uri $wdtArchiveUri -Destination (Join-Path $temporaryRoot 'download-archive.zip')
        Invoke-WdtDownloadFile -Uri $wdtChecksumUri -Destination (Join-Path $temporaryRoot 'download-archive.zip.sha256')
        Assert-Equal 2 $requestCalls.Count 'Bootstrap downloader did not request both fixed release files.'
        Assert-Equal $wdtArchiveUri $requestCalls[0].Uri 'Bootstrap downloader changed the fixed archive URL.'
        Assert-Equal $wdtChecksumUri $requestCalls[1].Uri 'Bootstrap downloader changed the fixed checksum URL.'
        foreach ($request in $requestCalls) {
            Assert-Equal 60 $request.TimeoutSec 'Bootstrap downloader must apply a 60-second request timeout.'
            Assert-Equal 60 $request.OperationTimeoutSeconds 'Bootstrap downloader must apply a 60-second stream read timeout when supported.'
            Assert-True $request.UseBasicParsing 'Bootstrap downloader must preserve basic parsing for Windows PowerShell.'
        }
        $unapprovedDownload = Join-Path $temporaryRoot 'unapproved-download.zip'
        $unapprovedError = $null
        try { Invoke-WdtDownloadFile -Uri 'https://example.invalid/unapproved.zip' -Destination $unapprovedDownload }
        catch { $unapprovedError = $_.Exception.Message }
        Assert-Equal 'Refusing unapproved download URL: https://example.invalid/unapproved.zip' $unapprovedError 'Bootstrap downloader accepted an unapproved URL.'
        Assert-Equal 2 $requestCalls.Count 'Bootstrap downloader sent an unapproved URL to Invoke-WebRequest.'
        Assert-True (-not (Test-Path -LiteralPath $unapprovedDownload)) 'Bootstrap downloader wrote an unapproved download.'

        $extractCalls = New-Object System.Collections.Generic.List[string]
        $launchCalls = New-Object System.Collections.Generic.List[string]
        $cleanupProgress = New-Object System.Collections.Generic.List[string]
        function Expand-Archive {
            param($LiteralPath, $DestinationPath)
            [void]$extractCalls.Add($LiteralPath)
        }
        function Get-WdtCurrentPowerShellPath {
            [void]$launchCalls.Add('launch')
            throw 'A timed-out bootstrap must not prepare to launch PowerShell.'
        }
        function Remove-Item {
            param([string]$LiteralPath, [switch]$Recurse, [switch]$Force)
            $resolvedPath = (Resolve-Path -LiteralPath $LiteralPath).Path
            $fixtureRoot = [System.IO.Path]::GetFullPath($temporaryRoot).TrimEnd('\') + '\'
            Assert-True ($resolvedPath.StartsWith($fixtureRoot, [System.StringComparison]::OrdinalIgnoreCase)) 'Timeout cleanup escaped the owned fixture root.'
            [void]$cleanupProgress.Add([string]$ProgressPreference)
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $resolvedPath -Recurse:$Recurse -Force:$Force
        }

        foreach ($timeoutUri in @($wdtArchiveUri, $wdtChecksumUri)) {
            $requestCalls.Clear()
            $cleanupProgress.Clear()
            $timeoutPhase = if ($timeoutUri -eq $wdtArchiveUri) { 'archive' } else { 'checksum' }
            $timeoutDirectory = Join-Path $temporaryRoot ("bootstrap-timeout-$timeoutPhase")
            $previousProgressPreference = $ProgressPreference
            $timeoutError = $null
            try {
                $ProgressPreference = 'Continue'
                try {
                    Invoke-WdtBootstrap -NewTemporaryDirectory {
                        New-Item -ItemType Directory -Path $timeoutDirectory -ErrorAction Stop | Out-Null
                        return $timeoutDirectory
                    }
                }
                catch { $timeoutError = $_.Exception }
                Assert-True ($timeoutError -is [System.Net.WebException]) "The $timeoutPhase request timeout was not propagated."
                Assert-Equal ([System.Net.WebExceptionStatus]::Timeout) $timeoutError.Status "The $timeoutPhase request timeout status changed."
                Assert-Equal 'Offline request timeout fixture.' $timeoutError.Message "The $timeoutPhase request timeout was replaced by a later error."
                Assert-Equal 'Continue' ([string]$ProgressPreference) "The $timeoutPhase timeout changed the caller progress preference."
            }
            finally {
                $ProgressPreference = $previousProgressPreference
            }
            $expectedRequestCount = if ($timeoutPhase -eq 'archive') { 1 } else { 2 }
            Assert-Equal $expectedRequestCount $requestCalls.Count "The $timeoutPhase timeout did not stop subsequent downloads."
            Assert-Equal $wdtArchiveUri $requestCalls[0].Uri 'A timeout fixture changed the fixed archive URL.'
            Assert-Equal $timeoutUri $requestCalls[$requestCalls.Count - 1].Uri 'A timeout fixture did not reach the intended request.'
            foreach ($request in $requestCalls) {
                Assert-Equal 60 $request.TimeoutSec 'A bootstrap timeout fixture lost its bounded request timeout.'
                Assert-Equal 60 $request.OperationTimeoutSeconds 'A bootstrap timeout fixture lost its bounded stream read timeout.'
                Assert-Equal 'SilentlyContinue' $request.Progress 'Bootstrap did not suppress progress while downloading.'
            }
            Assert-Equal 0 $extractCalls.Count "The $timeoutPhase timeout allowed archive extraction."
            Assert-Equal 0 $launchCalls.Count "The $timeoutPhase timeout allowed child launch preparation."
            Assert-Equal 1 $cleanupProgress.Count "The $timeoutPhase timeout did not clean exactly its owned temporary directory."
            Assert-Equal 'Continue' $cleanupProgress[0] "The $timeoutPhase timeout did not restore progress before cleanup."
            Assert-True (-not (Test-Path -LiteralPath $timeoutDirectory)) "The $timeoutPhase timeout left partial downloads behind."
        }
    }

    & {
        $legacyRequests = New-Object System.Collections.Generic.List[object]
        function Invoke-WebRequest {
            [CmdletBinding()]
            param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [int]$TimeoutSec)
            [void]$legacyRequests.Add([pscustomobject]@{ Uri = $Uri; TimeoutSec = $TimeoutSec; UseBasicParsing = [bool]$UseBasicParsing })
        }
        Assert-True (-not (Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) 'Legacy downloader fixture unexpectedly supports stream read timeouts.'
        Invoke-WdtDownloadFile -Uri $wdtArchiveUri -Destination (Join-Path $temporaryRoot 'legacy-archive.zip')
        Invoke-WdtDownloadFile -Uri $wdtChecksumUri -Destination (Join-Path $temporaryRoot 'legacy-archive.zip.sha256')
        Assert-Equal 2 $legacyRequests.Count 'Bootstrap downloader did not support the legacy Invoke-WebRequest signature.'
        Assert-Equal $wdtArchiveUri $legacyRequests[0].Uri 'Legacy downloader changed the fixed archive URL.'
        Assert-Equal $wdtChecksumUri $legacyRequests[1].Uri 'Legacy downloader changed the fixed checksum URL.'
        foreach ($request in $legacyRequests) {
            Assert-Equal 60 $request.TimeoutSec 'Legacy downloader lost its bounded request timeout.'
            Assert-True $request.UseBasicParsing 'Legacy downloader lost basic parsing.'
        }
    }

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
        $resolvedTemporaryRoot = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $systemTemporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolvedTemporaryRoot.StartsWith($systemTemporaryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a path outside the temporary root: $resolvedTemporaryRoot"
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}

Write-Host ("Release tests passed with PowerShell {0}." -f $PSVersionTable.PSVersion)
