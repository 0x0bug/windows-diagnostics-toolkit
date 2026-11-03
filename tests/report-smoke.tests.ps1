[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$entrypoint = Join-Path $repositoryRoot 'Invoke-WindowsDiagnostics.ps1'
$toolkitVersion=(Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()
. (Join-Path $repositoryRoot 'scripts\report-common.ps1')
. (Join-Path $repositoryRoot 'scripts\module-registry.ps1')
. (Join-Path $repositoryRoot 'scripts\process-runner.ps1')
. (Join-Path $repositoryRoot 'scripts\snapshot-compare.ps1')
. (Join-Path $repositoryRoot 'scripts\incident.ps1')
. (Join-Path $repositoryRoot 'scripts\tui.ps1')
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }

$tokens=$null; $errors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile($entrypoint,[ref]$tokens,[ref]$errors)
Assert-Equal 0 @($errors).Count 'Entrypoint parser errors were found.'
$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) -join ','
$expectedParameterNames = 'All,System,Security,Performance,Network,Time,Disk,Crashes,Events,Services,Updates,OutputDirectory,ExportMarkdown,PrivacyMode,Interactive,ModuleTimeoutSeconds,NoExternalNetworkTests,NetworkDnsTestName,NetworkHttpsEndpoint,NetworkIcmpTarget,Module,SaveSnapshot,BeforeSnapshot,AfterSnapshot,IncidentSymptom,IncidentAt,IncidentBeforeMinutes,IncidentAfterMinutes'
Assert-Equal $expectedParameterNames $parameterNames 'Public parameter order changed; existing implicit positional bindings must remain stable.'
foreach ($definition in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) { . ([scriptblock]::Create($definition.Extent.Text)) }
$registrySnapshot = Get-WdtModuleRegistry -ModuleRoot (Join-Path $repositoryRoot 'modules')

$output = Join-Path $env:TEMP ('wdt-report-smoke-' + [guid]::NewGuid().ToString('N'))
try {
    $state = New-WdtTuiState -RegistrySnapshot $registrySnapshot -OutputDirectory $output
    foreach ($diagnostic in $state.Diagnostics) { $diagnostic.Selected = ($diagnostic.Id -eq 'Network') }
    $parameters = ConvertTo-WdtReportParameters -State $state -RegistrySnapshot $registrySnapshot -ModuleTimeoutSeconds 17 -NoExternalNetworkTests $true -NetworkDnsTestName 'dns.interactive.fixture' -NetworkHttpsEndpoint 'https://interactive.fixture/' -NetworkIcmpTarget '192.0.2.55'
    $result = Invoke-WdtReport @parameters
    Assert-Equal 0 $result.ExitCode 'Interactive parameter forwarding smoke failed.'
    $report = Get-Content -LiteralPath $result.TextReportPath -Raw
    Assert-True ($report.Contains('External tests: NotTested (-NoExternalNetworkTests)')) 'NoExternalNetworkTests did not reach the network module.'
}
finally { if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force } }

$cliOutput = Join-Path $env:TEMP ('wdt-cli-module-smoke-' + [guid]::NewGuid().ToString('N'))
try {
    & $entrypoint -Module System,Network -NoExternalNetworkTests -ModuleTimeoutSeconds 17 -OutputDirectory $cliOutput
    $cliReport = @(Get-ChildItem -LiteralPath $cliOutput -Filter 'WindowsDiagnosticsReport-*.txt' -File)
    Assert-True ($cliReport.Count -eq 1) 'Generic -Module smoke did not create a report.'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $cliOutput -Filter 'WindowsDiagnosticsReport-*.md' -File).Count 'A report without -ExportMarkdown must not create a Markdown file.'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $cliOutput -Filter '*.json' -File).Count 'A legacy report must not create JSON without SaveSnapshot.'
    $cliText = Get-Content -LiteralPath $cliReport[0].FullName -Raw
    Assert-True ($cliText.Contains('Selected      : System Information, Network Check')) 'Generic -Module selection or registry order changed.'
    Assert-True ($cliText.Contains('External tests: NotTested (-NoExternalNetworkTests)')) 'Generic -Module options did not reach Network.'
}
finally { if (Test-Path -LiteralPath $cliOutput) { Remove-Item -LiteralPath $cliOutput -Recurse -Force } }

$legacyOutput = Join-Path $env:TEMP ('wdt-cli-legacy-smoke-' + [guid]::NewGuid().ToString('N'))
try {
    & $entrypoint -System -Network -NoExternalNetworkTests -ModuleTimeoutSeconds 17 -OutputDirectory $legacyOutput
    $legacyReport = @(Get-ChildItem -LiteralPath $legacyOutput -Filter 'WindowsDiagnosticsReport-*.txt' -File)
    Assert-True ($legacyReport.Count -eq 1) 'Legacy selector smoke did not create a report.'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $legacyOutput -Filter 'WindowsDiagnosticsReport-*.md' -File).Count 'A legacy report without -ExportMarkdown must not create a Markdown file.'
    $legacyText = Get-Content -LiteralPath $legacyReport[0].FullName -Raw
    Assert-True ($legacyText.Contains('Selected      : System Information, Network Check')) 'Legacy selector union or registry order changed.'
}
finally { if (Test-Path -LiteralPath $legacyOutput) { Remove-Item -LiteralPath $legacyOutput -Recurse -Force } }

$parallelOutput = Join-Path $env:TEMP ('wdt-parallel-report-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $parallelOutput -Force | Out-Null
$parallelProcesses = @()
try {
    $existingBaseName = 'WindowsDiagnosticsReport-20000101-000000'
    $existingTextPath = Join-Path $parallelOutput ($existingBaseName + '.txt')
    $existingMarkdownPath = Join-Path $parallelOutput ($existingBaseName + '.md')
    [IO.File]::WriteAllText($existingTextPath, 'existing TXT must survive')
    [IO.File]::WriteAllText($existingMarkdownPath, 'existing Markdown must survive')
    $powershellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    for ($parallelIndex = 0; $parallelIndex -lt 2; $parallelIndex++) {
        $parallelProcesses += Start-Process -FilePath $powershellPath -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $entrypoint),
            '-System', '-ExportMarkdown', '-OutputDirectory', ('"{0}"' -f $parallelOutput)
        ) -PassThru -WindowStyle Hidden
    }
    foreach ($parallelProcess in $parallelProcesses) {
        if (-not $parallelProcess.WaitForExit(90000)) {
            throw 'A parallel report process exceeded its 90-second test bound.'
        }
    }
    foreach ($parallelProcess in $parallelProcesses) {
        Assert-Equal 0 $parallelProcess.ExitCode 'A parallel report process failed.'
    }
    $reportTextFiles = @(Get-ChildItem -LiteralPath $parallelOutput -Filter 'WindowsDiagnosticsReport-*.txt' -File)
    $reportMarkdownFiles = @(Get-ChildItem -LiteralPath $parallelOutput -Filter 'WindowsDiagnosticsReport-*.md' -File)
    Assert-Equal 3 $reportTextFiles.Count 'Parallel reports overwrote or lost a TXT report.'
    Assert-Equal 3 $reportMarkdownFiles.Count 'Parallel reports overwrote or lost a Markdown report.'
    foreach ($textFile in @($reportTextFiles | Where-Object { $_.BaseName -ne $existingBaseName })) {
        Assert-True (Test-Path -LiteralPath (Join-Path $parallelOutput ($textFile.BaseName + '.md')) -PathType Leaf) 'A TXT report has no same-base Markdown pair.'
    }
    Assert-Equal 'existing TXT must survive' ([IO.File]::ReadAllText($existingTextPath)) 'The preexisting TXT report changed.'
    Assert-Equal 'existing Markdown must survive' ([IO.File]::ReadAllText($existingMarkdownPath)) 'The preexisting Markdown report changed.'
}
finally {
    foreach ($parallelProcess in $parallelProcesses) {
        if ($null -ne $parallelProcess -and $null -ne $parallelProcess.Id) {
            try {
                if (-not $parallelProcess.HasExited) {
                    Stop-Process -Id $parallelProcess.Id -Force -ErrorAction SilentlyContinue
                    [void]$parallelProcess.WaitForExit(5000)
                }
            }
            finally { $parallelProcess.Dispose() }
        }
    }
    $resolvedParallelOutput = (Resolve-Path -LiteralPath $parallelOutput).Path
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedParallelOutput.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a path outside the temporary root: $resolvedParallelOutput"
    }
    Remove-Item -LiteralPath $resolvedParallelOutput -Recurse -Force
}
$global:LASTEXITCODE = 0

$snapshotOutput=Join-Path $env:TEMP ('wdt-cli-snapshot-smoke-'+[guid]::NewGuid().ToString('N'))
try {
    & $entrypoint -Module system -SaveSnapshot -PrivacyMode -ExportMarkdown -OutputDirectory $snapshotOutput
    $saved=@(Get-ChildItem -LiteralPath $snapshotOutput -Filter 'WindowsDiagnosticsSnapshot-*.json' -File)
    Assert-Equal 1 $saved.Count 'Case-insensitive System selection did not save one snapshot.'
    $snapshot=Read-WdtSnapshot $saved[0].FullName
    Assert-True ($null -eq $snapshot.Modules[0].Data.WindowStartUtc) 'Current OS data was assigned a historical window.'
    Assert-Equal 7 (([datetimeoffset]$snapshot.WindowEndUtc)-([datetimeoffset]$snapshot.WindowStartUtc)).TotalDays 'Snapshot default history window changed.'
    $originalSnapshot=[IO.File]::ReadAllText($saved[0].FullName)
    & $entrypoint -BeforeSnapshot $saved[0].FullName -AfterSnapshot $saved[0].FullName -ExportMarkdown -OutputDirectory $snapshotOutput
    Assert-Equal $originalSnapshot ([IO.File]::ReadAllText($saved[0].FullName)) 'Offline CLI rewrote an input.'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $snapshotOutput -Filter 'WindowsDiagnosticsComparison-*.txt').Count 'Offline comparison did not create TXT.'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $snapshotOutput -Filter 'WindowsDiagnosticsComparison-*.md').Count 'Offline comparison did not create Markdown.'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $snapshotOutput -Filter 'WindowsDiagnosticsSnapshot-*.json').Count 'Offline comparison launched live collection.'
    $comparisonText=Get-Content -LiteralPath @(Get-ChildItem -LiteralPath $snapshotOutput -Filter 'WindowsDiagnosticsComparison-*.txt')[0].FullName -Raw
    Assert-True ($comparisonText -match 'machine identity is not verified') 'Offline report lacks the selected-pair assumption.'

    foreach ($arguments in @(@{SaveSnapshot=$true},@{SaveSnapshot=$true;All=$true},@{SaveSnapshot=$true;Module=@('Network')},@{BeforeSnapshot=$saved[0].FullName},@{BeforeSnapshot=$saved[0].FullName;AfterSnapshot=$saved[0].FullName;System=$true})) {
        $invalidOutput=Join-Path $snapshotOutput ([guid]::NewGuid().ToString('N'))
        $threw=$false;try { & $entrypoint @arguments -OutputDirectory $invalidOutput } catch { $threw=$true }
        Assert-True $threw 'Invalid snapshot CLI combination was accepted.'
        Assert-True (-not (Test-Path -LiteralPath $invalidOutput)) 'Invalid snapshot options wrote output before validation.'
    }

    # No live collector can be invoked by the offline helper.
    function Invoke-DiagnosticScript { throw 'Live collection must not run offline.' }
    Invoke-WdtSnapshotComparison -BeforePath $saved[0].FullName -AfterPath $saved[0].FullName -OutputDirectory $snapshotOutput -PrivacyMode $true

    # A child can succeed while omitting the requested machine protocol.
    $snapshotFixtureData=$null;$snapshotFixtureErrors=@('Diagnostic data did not include a complete end marker.');$snapshotFixtureStatus='Unavailable'
    function Invoke-DiagnosticScript {
        [pscustomobject]@{Title='Fixture';Command='fixture';ExitCode=0;OutputLines=@('fixture');ErrorLines=@();Findings=@();Status='Success';Duration=[timespan]::Zero;Completeness='Complete';OutputComplete=$true;Data=$snapshotFixtureData;DataStatus=$snapshotFixtureStatus;DataErrors=@($snapshotFixtureErrors)}
    }
    $invalidProtocol=Invoke-WdtReport -ModuleDefinitions @($registrySnapshot.ById['System']) -CoreOptions @{} -OutputDirectory $snapshotOutput -SaveSnapshot $true -SuppressConsoleOutput $true
    Assert-Equal 1 $invalidProtocol.ExitCode 'Missing requested data protocol was silently successful.'
    Assert-True (Test-Path -LiteralPath $invalidProtocol.SnapshotPath) 'Protocol failure discarded useful explicit unavailable metadata.'
    $snapshotFixtureData=New-WdtDiagnosticData -ModuleId System -Sources @((New-WdtDataSource -Id os -Kind Configuration -Scope 'Win32_OperatingSystem.Version.BuildNumber' -Availability Unavailable -QueryComplete $false -Error 'fixture unavailable'))
    $snapshotFixtureErrors=@()
    $unavailableSource=Invoke-WdtReport -ModuleDefinitions @($registrySnapshot.ById['System']) -CoreOptions @{} -OutputDirectory $snapshotOutput -SaveSnapshot $true -SuppressConsoleOutput $true
    Assert-Equal 0 $unavailableSource.ExitCode 'Valid unavailable source data became a protocol/execution failure.'
    $snapshotFixtureData.Sources[0].Availability='Partial';$snapshotFixtureStatus='Partial';$snapshotFixtureErrors=@('Invalid diagnostic data frame discarded.')
    $damagedProtocol=Invoke-WdtReport -ModuleDefinitions @($registrySnapshot.ById['System']) -CoreOptions @{} -OutputDirectory $snapshotOutput -SaveSnapshot $true -SuppressConsoleOutput $true
    Assert-Equal 1 $damagedProtocol.ExitCode 'Malformed protocol with non-null partial data was silently successful.'
}
finally {
    . (Join-Path $repositoryRoot 'scripts\process-runner.ps1')
    $resolvedSnapshotOutput=[IO.Path]::GetFullPath($snapshotOutput)
    if (-not $resolvedSnapshotOutput.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe snapshot smoke cleanup.' }
    if (Test-Path -LiteralPath $resolvedSnapshotOutput) { Remove-Item -LiteralPath $resolvedSnapshotOutput -Recurse -Force }
}
$global:LASTEXITCODE = 0

Write-Host 'Live report smoke tests passed.'
