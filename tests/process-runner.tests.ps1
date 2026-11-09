[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\report-common.ps1')
. (Join-Path $repositoryRoot 'scripts\process-runner.ps1')
. (Join-Path $repositoryRoot 'scripts\module-registry.ps1')
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }

Assert-Equal 'Complete' (Get-WdtExecutionCompleteness Success $true) 'Complete success classification failed.'
Assert-Equal 'Partial' (Get-WdtExecutionCompleteness Success $false) 'Incomplete success classification failed.'
foreach ($status in @('NonZeroExit','Timeout')) { Assert-Equal 'Partial' (Get-WdtExecutionCompleteness $status) "$status classification failed." }
foreach ($status in @('LaunchError','Cancelled')) { Assert-Equal 'Unavailable' (Get-WdtExecutionCompleteness $status) "$status classification failed." }
$tokens = $null; $parseErrors = $null
$entrypointAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'Invoke-WindowsDiagnostics.ps1'), [ref]$tokens, [ref]$parseErrors)
$collectionDefinition = $entrypointAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-WdtCollectionCompleteness' }, $true)
. ([scriptblock]::Create($collectionDefinition.Extent.Text))
foreach ($case in @(
    [pscustomobject]@{ Values=@('Unavailable','Unavailable'); Expected='Unavailable' },
    [pscustomobject]@{ Values=@('Complete','Complete'); Expected='Complete' },
    [pscustomobject]@{ Values=@('Complete','Partial'); Expected='Partial' },
    [pscustomobject]@{ Values=@('Complete','Unavailable'); Expected='Partial' },
    [pscustomobject]@{ Values=@('Partial','Unavailable'); Expected='Partial' }
)) {
    $results = @($case.Values | ForEach-Object { [pscustomobject]@{ Status='ignored'; Completeness=$_ } })
    Assert-Equal $case.Expected (Get-WdtCollectionCompleteness $results) "Collection aggregation failed for $($case.Values -join ',')."
}

$missingIdentity = Test-WdtProcessIdentity -Expected ([pscustomobject]@{ ProcessId=987654; ParentProcessId=1; IsRoot=$false; CreationKey='missing' }) -Current $null
Assert-Equal 'NotFound' $missingIdentity.Status 'A nonexistent PID must be structured as NotFound.'
Assert-True (-not ($missingIdentity -is [string])) 'Identity result must not use a string contract.'
$rootEntry = [pscustomobject]@{ ProcessId=100; ParentProcessId=1; Depth=0; IsRoot=$true; CreationKey='2024-01-01T00:00:00.0000000'; StartTime=[datetime]'2024-01-01' }
$childEntry = [pscustomobject]@{ ProcessId=200; ParentProcessId=100; Depth=1; IsRoot=$false; CreationKey='2024-01-01T00:00:01.0000000'; StartTime=[datetime]'2024-01-01T00:00:01' }
$watch = [Diagnostics.Stopwatch]::StartNew()
$membership = & { function Get-CimInstance { param($ClassName,$Filter,$OperationTimeoutSec) @() }; Test-WdtSnapshotMembership $childEntry @{100=$rootEntry;200=$childEntry} $watch 500 }
Assert-Equal 'TargetNotFound' $membership.Status 'An exited descendant must be safe.'
$nullParentWatch = [Diagnostics.Stopwatch]::StartNew()
$nullParentMembership = & { function Get-CimInstance { param($ClassName,$Filter,$OperationTimeoutSec) [pscustomobject]@{ ProcessId=200; ParentProcessId=100; CreationDate=[datetime]'2024-01-01T00:00:01' } }; Test-WdtSnapshotMembership $childEntry @{100=$null;200=$childEntry} $nullParentWatch 500 }
Assert-True ($null -ne $nullParentMembership) 'A null parent snapshot value must still produce a structured result.'
Assert-Equal 'SnapshotParentMissing' $nullParentMembership.Status 'A null parent snapshot value must be structured as SnapshotParentMissing.'
$failedSummary = Get-WdtProcessCleanupSummary @([pscustomobject]@{Status='TerminationFailed'}) @('fixture') $false
Assert-Equal $false $failedSummary.Success 'Failed cleanup must be explicit.'

$powerShellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$fixtureStarted = Get-Date
$runtimeTemporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$fixtureRoot = Join-Path $runtimeTemporaryRoot ('wdt-runtime-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$heldChildPid = $null
$timeoutChildPid = $null
$timeoutRootPid = $null
try {
    # Run the real report aggregator and CLI with child scripts that actually
    # exit unsuccessfully; findings alone must not change execution success.
    foreach ($definition in @($entrypointAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $toolkitVersion = 'fixture'
    $exitFixture = Join-Path $fixtureRoot 'module-exit.ps1'
    $exitSource = @'
param([int]$Code=0, [string]$CommonPath, [switch]$HealthError)
. $CommonPath
Write-Output 'synthetic module output'
if ($HealthError) { Write-WdtFinding -Severity ERROR -Code FIXTURE_HEALTH_ERROR -Message 'Synthetic health finding.' }
exit $Code
'@
    [IO.File]::WriteAllText($exitFixture, $exitSource, [Text.Encoding]::UTF8)
    foreach ($failedModules in @(0, 1, 2)) {
        $definitions = @(for ($moduleIndex = 0; $moduleIndex -lt 2; $moduleIndex++) {
            [pscustomobject]@{ Id=('Fixture' + $moduleIndex); Title=('Fixture ' + $moduleIndex); EntryPoint=$exitFixture; OptionBindings=@{}; DefaultArguments=@('-Code', $(if ($moduleIndex -lt $failedModules) { '7' } else { '0' }), '-CommonPath', (Join-Path $repositoryRoot 'scripts\report-common.ps1')) }
        })
        $reportResult = Invoke-WdtReport -ModuleDefinitions $definitions -CoreOptions @{} -OutputDirectory (Join-Path $fixtureRoot ('report-' + $failedModules)) -SuppressConsoleOutput $true
        Assert-Equal $(if ($failedModules -eq 0) { 0 } else { 1 }) $reportResult.ExitCode "Report exit code was wrong for $failedModules failed modules."
        $reportText = [IO.File]::ReadAllText($reportResult.TextReportPath)
        Assert-Equal $failedModules ([regex]::Matches($reportText, 'Execution: NonZeroExit').Count) 'Report lost actual child failure statuses.'
        Assert-Equal $failedModules ([regex]::Matches($reportText, '(?m)^Exit code: [1-9][0-9]*\r?$').Count) 'Report lost nonzero child process exit codes.'
    }
    $healthDefinition = [pscustomobject]@{ Id='Health'; Title='Health'; EntryPoint=$exitFixture; OptionBindings=@{}; DefaultArguments=@('-CommonPath', (Join-Path $repositoryRoot 'scripts\report-common.ps1'), '-HealthError') }
    $healthReport = Invoke-WdtReport -ModuleDefinitions @($healthDefinition) -CoreOptions @{} -OutputDirectory (Join-Path $fixtureRoot 'health-only') -SuppressConsoleOutput $true
    Assert-Equal 0 $healthReport.ExitCode 'An ERROR finding from a successful child must not fail report execution.'
    Assert-Equal 1 $healthReport.ErrorCount 'The successful child health finding disappeared from the report.'

    $cliRoot = Join-Path $fixtureRoot 'cli-repository'
    New-Item -ItemType Directory -Path $cliRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'Invoke-WindowsDiagnostics.ps1'), (Join-Path $repositoryRoot 'VERSION') -Destination $cliRoot
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts'), (Join-Path $repositoryRoot 'modules') -Destination $cliRoot -Recurse
    foreach ($failedModules in @(0, 1, 2)) {
        $moduleIndex = 0
        foreach ($moduleName in @('system', 'security')) {
            $code = if ($moduleIndex -lt $failedModules) { 7 } else { 0 }
            [IO.File]::WriteAllText((Join-Path $cliRoot ('modules\' + $moduleName + '\diagnostic.ps1')), ('Write-Output ''synthetic CLI child''; exit ' + $code), [Text.Encoding]::UTF8)
            $moduleIndex++
        }
        $cliOutput = Join-Path $fixtureRoot ('cli-' + $failedModules)
        $cliResult = Invoke-DiagnosticScript 'CLI exit regression' (Join-Path $cliRoot 'Invoke-WindowsDiagnostics.ps1') $powerShellPath $cliRoot 30 @('-System', '-Security', '-OutputDirectory', $cliOutput)
        Assert-Equal $(if ($failedModules -eq 0) { 0 } else { 1 }) $cliResult.ExitCode "CLI exit code was wrong for $failedModules failed modules."
        $cliReports = @(Get-ChildItem -LiteralPath $cliOutput -Filter 'WindowsDiagnosticsReport-*.txt' -File)
        Assert-Equal 1 $cliReports.Count 'CLI execution did not preserve exactly one report.'
        Assert-Equal $failedModules ([regex]::Matches([IO.File]::ReadAllText($cliReports[0].FullName), 'Execution: NonZeroExit').Count) 'CLI report did not preserve child failures.'
    }
    [IO.File]::WriteAllText((Join-Path $cliRoot 'modules\system\diagnostic.ps1'), ". `$PSScriptRoot\..\..\scripts\report-common.ps1; Write-WdtFinding -Severity ERROR -Code CLI_HEALTH_ERROR -Message 'Synthetic health finding.'", [Text.Encoding]::UTF8)
    $healthCliOutput = Join-Path $fixtureRoot 'cli-health-only'
    $healthCli = Invoke-DiagnosticScript 'CLI health finding' (Join-Path $cliRoot 'Invoke-WindowsDiagnostics.ps1') $powerShellPath $cliRoot 30 @('-System', '-OutputDirectory', $healthCliOutput)
    Assert-Equal 0 $healthCli.ExitCode 'An ERROR health finding must not fail the CLI.'
    Assert-True (([IO.File]::ReadAllText(@(Get-ChildItem -LiteralPath $healthCliOutput -Filter '*.txt' -File)[0].FullName)).Contains('CLI_HEALTH_ERROR')) 'CLI health finding was not written.'

    # All CLI fixtures remain synthetic even if a future validation regression
    # accidentally dispatches a module. A marker proves no collector was run.
    foreach ($moduleDirectory in @(Get-ChildItem -LiteralPath (Join-Path $cliRoot 'modules') -Directory)) {
        $modulePath = Join-Path $moduleDirectory.FullName 'diagnostic.ps1'
        $moduleTokens = $null; $moduleErrors = $null
        $moduleAst = [Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$moduleTokens, [ref]$moduleErrors)
        $moduleParameters = if ($null -ne $moduleAst.ParamBlock) { $moduleAst.ParamBlock.Extent.Text } else { 'param()' }
        $markerSource = $moduleParameters + "`n[IO.File]::WriteAllText((Join-Path `$PSScriptRoot '..\..\collector-called.txt'), 'called')"
        [IO.File]::WriteAllText($modulePath, $markerSource, [Text.Encoding]::UTF8)
    }
    $invalidRequests = @(
        @('-Module', 'MissingModule'),
        @('-SaveSnapshot'),
        @('-SaveSnapshot', '-Network'),
        @('-IncidentSymptom', 'AppFailure'),
        @('-IncidentSymptom', 'AppFailure', '-IncidentAt', '2025-11-02T10:00:00Z', '-System'),
        @('-BeforeSnapshot', 'missing.json')
    )
    for ($invalidIndex = 0; $invalidIndex -lt $invalidRequests.Count; $invalidIndex++) {
        $invalidOutput = Join-Path $fixtureRoot ('invalid-cli-' + $invalidIndex)
        $invalidCli = Invoke-DiagnosticScript 'Invalid CLI' (Join-Path $cliRoot 'Invoke-WindowsDiagnostics.ps1') $powerShellPath $cliRoot 10 (@($invalidRequests[$invalidIndex]) + @('-OutputDirectory', $invalidOutput))
        Assert-True ($invalidCli.ExitCode -ne 0) 'Invalid CLI options were accepted.'
        Assert-True (-not (Test-Path -LiteralPath $invalidOutput)) 'Invalid CLI options created output before semantic validation.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $cliRoot 'collector-called.txt'))) 'Invalid CLI options invoked a collector.'
    }

    $streamFixture = Join-Path $fixtureRoot 'stream.ps1'
    [IO.File]::WriteAllText($streamFixture, "Write-Output 'out'; [Console]::Error.WriteLine('err')", [Text.Encoding]::UTF8)
    $missingExecutable = Join-Path $fixtureRoot 'missing-powershell.exe'
    $launch = Invoke-DiagnosticScript 'Launch' $streamFixture $missingExecutable $repositoryRoot 5
    Assert-Equal 'LaunchError' $launch.Status 'Missing executable must return LaunchError.'
    Assert-True (($launch.ErrorLines -join "`n").Contains('Failed to run script:')) 'Original launch message is missing.'
    Assert-True (-not (($launch.ErrorLines -join "`n").Contains('No process is associated'))) 'Secondary process error masked launch error.'

    foreach ($captureFailure in @('Faulted', 'Cancelled')) {
        $captureResult = & {
            param($failureMode, $fixturePath, $executablePath, $rootPath)
            $script:captureFactoryCall = 0
            function New-WdtStreamCaptureState {
                param([System.IO.StreamReader]$Reader)
                $script:captureFactoryCall++
                if ($script:captureFactoryCall -eq 1) {
                    $completion = New-Object 'System.Threading.Tasks.TaskCompletionSource[int]'
                    if ($failureMode -eq 'Faulted') {
                        $completion.SetException((New-Object System.InvalidOperationException 'fixture stream read fault'))
                    }
                    else {
                        $completion.SetCanceled()
                    }
                    return [pscustomobject]@{
                        Reader = $Reader; Buffer = (New-Object char[] 4096); Task = $completion.Task
                        Text = New-Object System.Text.StringBuilder; Complete = $false; Error = $null
                    }
                }
                $buffer = New-Object char[] 4096
                return [pscustomobject]@{
                    Reader = $Reader; Buffer = $buffer; Task = $Reader.ReadAsync($buffer, 0, $buffer.Length)
                    Text = New-Object System.Text.StringBuilder; Complete = $false; Error = $null
                }
            }
            Invoke-DiagnosticScript ('Capture' + $failureMode) $fixturePath $executablePath $rootPath 10
        } $captureFailure $streamFixture $powerShellPath $repositoryRoot
        Assert-Equal 'Success' $captureResult.Status "$captureFailure stream capture failure must preserve process success."
        Assert-Equal 0 $captureResult.ExitCode "$captureFailure stream capture failure changed the process exit code."
        Assert-Equal $false $captureResult.OutputComplete "$captureFailure stream capture failure must mark captured output incomplete."
        Assert-Equal 'Partial' $captureResult.Completeness "$captureFailure stream capture failure must make completeness partial."
        Assert-True (($captureResult.ErrorLines -join "`n").Contains('Stream read')) "$captureFailure stream capture failure details were not retained."
        Assert-True (-not (($captureResult.ErrorLines -join "`n").Contains('stream drain did not finish'))) "$captureFailure stream capture failure must not be mislabeled as a drain timeout."
    }

    $ansiFixture = Join-Path $fixtureRoot 'ansi-stream.ps1'
    $ansiSource = @'
$esc = [char]27
Write-Output ("${esc}[32mstdout-colored${esc}[0m")
[Console]::Error.WriteLine(("${esc}[33;1mWARNING: colored warning${esc}[0m"))
'@
    [IO.File]::WriteAllText($ansiFixture, $ansiSource, [Text.Encoding]::UTF8)
    $ansiResult = Invoke-DiagnosticScript 'AnsiStream' $ansiFixture $powerShellPath $repositoryRoot 10
    Assert-Equal 'Success' $ansiResult.Status 'ANSI fixture must succeed.'
    Assert-True ($ansiResult.OutputLines -contains 'stdout-colored') 'ANSI stripping changed stdout content.'
    Assert-True ($ansiResult.ErrorLines -contains 'WARNING: colored warning') 'ANSI stripping changed stderr warning content.'
    Assert-True (-not (($ansiResult.OutputLines -join "`n").Contains([string][char]27))) 'ANSI escape codes must not remain in stdout.'
    Assert-True (-not (($ansiResult.ErrorLines -join "`n").Contains([string][char]27))) 'ANSI escape codes must not remain in stderr/report errors.'

    $progressFixture = Join-Path $fixtureRoot 'progress-stream.ps1'
    $progressSource = @'
Write-Progress -Activity 'WDT fixture progress' -Status 'Collecting' -PercentComplete 50
Write-Output 'progress-output-ok'
'@
    [IO.File]::WriteAllText($progressFixture, $progressSource, [Text.Encoding]::UTF8)
    $progressResult = Invoke-DiagnosticScript 'ProgressStream' $progressFixture $powerShellPath $repositoryRoot 10
    Assert-Equal 'Success' $progressResult.Status 'Progress fixture must succeed.'
    Assert-True ($progressResult.OutputLines -contains 'progress-output-ok') 'Progress fixture stdout was lost.'
    Assert-Equal 0 @($progressResult.ErrorLines).Count 'PowerShell progress records must not leak into stderr/report errors.'
    Assert-True (-not (($progressResult.ErrorLines -join "`n") -match '#< CLIXML|<Objs\b')) 'Serialized CLIXML progress must not appear in report errors.'

    $informationFixture = Join-Path $fixtureRoot 'information-stream.ps1'
    $informationSource = @'
param([int]$Code=0)
. '__COMMON__'
. '__DATA__'
$text = 'stream-' + (-join @([char]0x041F,[char]0x0440,[char]0x0438,[char]0x0432,[char]0x0435,[char]0x0442,[char]0x96EA))
Write-Host ('host-' + $text)
Write-Information ('information-' + $text) -InformationAction Continue
Write-Warning ('warning-' + $text)
Write-Error ('error-' + $text) -ErrorAction Continue
Write-Output ('output-' + $text)
[Console]::Error.WriteLine('stderr-' + $text)
Write-WdtFinding -Severity WARN -Code STREAM_FINDING -Message ('finding-' + $text)
if ((Get-WdtDataRequest).Enabled) {
    $source = New-WdtDataSource -Id os -Kind Configuration -Scope 'Win32_OperatingSystem.Version.BuildNumber' -Coverage CurrentState
    $fact = New-WdtDataFact -Id f1 -Type OsVersion -Key windows-version -Values @{Version='10.0';Build='26000'} -Comparison Configuration -SourceIds @('os')
    Write-WdtDiagnosticData (New-WdtDiagnosticData -ModuleId System -Sources @($source) -Facts @($fact))
}
exit $Code
'@
    $informationSource = $informationSource.Replace('__COMMON__', (Join-Path $repositoryRoot 'scripts\report-common.ps1').Replace("'", "''")).Replace('__DATA__', (Join-Path $repositoryRoot 'scripts\diagnostic-data.ps1').Replace("'", "''"))
    [IO.File]::WriteAllText($informationFixture, $informationSource, [Text.Encoding]::UTF8)
    $streamText = 'stream-' + (-join @([char]0x041F,[char]0x0440,[char]0x0438,[char]0x0432,[char]0x0435,[char]0x0442,[char]0x96EA))
    # Both command transports map a nonzero script exit to the shell's 1.
    foreach ($code in @(0,1,2)) {
        $informationResult = Invoke-DiagnosticScript 'InformationStream' $informationFixture $powerShellPath $repositoryRoot 10 @('-Code', [string]$code) -CollectData -ModuleId System
        Assert-Equal $(if ($code -eq 0) { 0 } else { 1 }) $informationResult.ExitCode 'Information-stream capture changed the shell exit code.'
        Assert-Equal $(if ($code -eq 0) { 'Success' } else { 'NonZeroExit' }) $informationResult.Status 'Information-stream capture changed execution status.'
        Assert-Equal $(if ($code -eq 0) { 'Complete' } else { 'Partial' }) $informationResult.Completeness 'Information-stream capture changed execution completeness.'
        Assert-True $informationResult.OutputComplete 'Information-stream capture failed to drain a stream.'
        $allStreamText = (@($informationResult.OutputLines) + @($informationResult.ErrorLines)) -join "`n"
        Assert-True ($allStreamText -notmatch '#< CLIXML|<Objs\b') 'Information, warning, and error records must remain readable text rather than serialized CLIXML.'
        foreach ($prefix in @('host-','information-','output-')) {
            Assert-Equal 1 @($informationResult.OutputLines | Where-Object { $_ -ceq ($prefix + $streamText) }).Count "Information-stream capture lost or duplicated $prefix text or Unicode."
        }
        Assert-True ($allStreamText.Contains('warning-' + $streamText)) 'PowerShell warning text was lost.'
        Assert-True (($informationResult.ErrorLines -join '').Contains('error-' + $streamText)) 'Nonterminating PowerShell error text must remain readable in stderr after joining display wraps.'
        Assert-True ($informationResult.ErrorLines -contains ('stderr-' + $streamText)) 'Native stderr text or Unicode was lost.'
        Assert-Equal 1 @($informationResult.Findings | Where-Object { $_.Code -ceq 'STREAM_FINDING' }).Count 'Information-stream capture lost the authenticated finding.'
        Assert-Equal $(if ($code -eq 0) { 'Available' } else { 'Partial' }) $informationResult.DataStatus 'Information-stream capture changed structured data status.'
        Assert-Equal '26000' $informationResult.Data.Facts[0].Values.Build 'Information-stream capture lost structured protocol data.'
        Assert-True (($informationResult | ConvertTo-Json -Depth 12) -notmatch '@@WDT_(?:FINDING|DATA)@@[A-Fa-f0-9]{32}:') 'Active nonce protocol frames leaked from the resolved result.'
    }

    $largeStreamFixture = Join-Path $fixtureRoot 'large-streams.ps1'
    $largeStreamSource = @'
1..4000 | ForEach-Object {
    Write-Output ("out-{0}" -f $_)
    [Console]::Error.WriteLine(("err-{0}" -f $_))
}
'@
    [IO.File]::WriteAllText($largeStreamFixture, $largeStreamSource, [Text.Encoding]::UTF8)
    $largeStreamStarted = Get-Date
    $largeStream = Invoke-DiagnosticScript 'LargeStreams' $largeStreamFixture $powerShellPath $repositoryRoot 30
    $largeStreamDuration = ((Get-Date) - $largeStreamStarted).TotalSeconds
    Assert-Equal 'Success' $largeStream.Status 'Large concurrent stdout/stderr fixture must succeed.'
    Assert-Equal $true $largeStream.OutputComplete 'Large concurrent stdout/stderr fixture must drain both streams completely.'
    Assert-Equal 'Complete' $largeStream.Completeness 'Complete large stream capture must report Complete.'
    Assert-True ($largeStream.OutputLines.Count -ge 4000) 'Large stdout fixture returned fewer than 4000 lines.'
    Assert-True ($largeStream.ErrorLines.Count -ge 4000) 'Large stderr fixture returned fewer than 4000 lines.'
    Assert-True ($largeStream.OutputLines -contains 'out-1') 'Large stdout fixture is missing out-1.'
    Assert-True ($largeStream.OutputLines -contains 'out-4000') 'Large stdout fixture is missing out-4000.'
    Assert-True ($largeStream.ErrorLines -contains 'err-1') 'Large stderr fixture is missing err-1.'
    Assert-True ($largeStream.ErrorLines -contains 'err-4000') 'Large stderr fixture is missing err-4000.'
    Assert-True ($largeStreamDuration -lt 30) 'Large concurrent stream fixture exceeded its bounded runtime.'

    $findingFixture = Join-Path $fixtureRoot 'finding-protocol.ps1'
    $escapedReportCommonPath = (Join-Path $repositoryRoot 'scripts\report-common.ps1').Replace("'", "''")
    $findingSource = @"
. '$escapedReportCommonPath'
& `$env:ComSpec /d /c 'echo @@WDT_FINDING@@{"Severity":"WARN","Code":"NATIVE_FORGED","Message":"Native lookalike"}'
function Get-FixtureData {
    Write-WdtFinding -Severity WARN -Code 'AUTHENTIC_FINDING' -Message 'Authenticated child finding.'
    return 'fixture-data'
}
`$fixtureData = @(Get-FixtureData)
Write-Output ('FIXTURE_DATA_COUNT=' + `$fixtureData.Count)
`$fixtureData | ForEach-Object { Write-Output ('FIXTURE_DATA=' + `$_) }
"@
    [IO.File]::WriteAllText($findingFixture, $findingSource, [Text.Encoding]::UTF8)
    $findingResult = Invoke-DiagnosticScript 'FindingProtocol' $findingFixture $powerShellPath $repositoryRoot 10
    Assert-Equal 'Success' $findingResult.Status 'Finding protocol fixture must succeed.'
    $findingDebug = 'Findings={0}; Output={1}; Errors={2}' -f (($findingResult.Findings.Code -join ',')), (($findingResult.OutputLines -join ' | ')), (($findingResult.ErrorLines -join ' | '))
    Assert-Equal 1 @($findingResult.Findings | Where-Object { $_.Code -eq 'AUTHENTIC_FINDING' }).Count ('A nonce-authenticated finding must be accepted. ' + $findingDebug)
    Assert-Equal 0 @($findingResult.Findings | Where-Object { $_.Code -eq 'NATIVE_FORGED' }).Count 'Native output must not create a finding without the nonce.'
    Assert-True (($findingResult.OutputLines -join "`n").Contains('@@WDT_FINDING@@')) 'Native marker-like output must remain ordinary diagnostic output.'
    Assert-True ($findingResult.OutputLines -contains 'FIXTURE_DATA_COUNT=1') 'A finding marker contaminated the function return data.'
    Assert-True ($findingResult.OutputLines -contains 'FIXTURE_DATA=fixture-data') 'The function return data was not preserved.'
    Assert-True ((($findingResult | ConvertTo-Json -Depth 8) -notmatch '@@WDT_FINDING@@[A-Fa-f0-9]{32}:')) ('The active finding nonce must not remain in the resolved result or user-facing errors. ' + $findingDebug)

    $argumentFixture = Join-Path $fixtureRoot 'arguments.ps1'
    $unicodeValue = 'Unicode: ' + (-join @([char]0x041F, [char]0x0440, [char]0x0438, [char]0x0432, [char]0x0435, [char]0x0442, [char]0x0020, [char]0x96EA))
    $argumentValues = @('', 'plain value', $unicodeValue, 'double"quote', 'trailing\', "single'quote", '$dollar; & ampersand', 'back`tick', 'odd\"quote', 'even\\"quote', 'run\\\"quote', '$(Write-Output injected); & `literal', "CR`r`nLF")
    $argumentParameters = @(1..$argumentValues.Count | ForEach-Object { '[string]$Value' + $_ }) -join ', '
    $argumentVariables = @(1..$argumentValues.Count | ForEach-Object { '$Value' + $_ }) -join ', '
    $argumentSource = "param($argumentParameters)`r`nforeach (`$value in @($argumentVariables)) {`r`n    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(`$value))`r`n}"
    [IO.File]::WriteAllText($argumentFixture, $argumentSource, [Text.Encoding]::UTF8)
    $scriptArguments = @()
    for ($argumentIndex = 0; $argumentIndex -lt $argumentValues.Count; $argumentIndex++) {
        $scriptArguments += '-Value' + ($argumentIndex + 1)
        $scriptArguments += $argumentValues[$argumentIndex]
    }
    $argumentResult = Invoke-DiagnosticScript 'Arguments' $argumentFixture $powerShellPath $repositoryRoot 10 $scriptArguments
    Assert-Equal 'Success' $argumentResult.Status 'Complex arguments must survive process launch.'
    $expectedArguments = @($argumentValues | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) })
    Assert-Equal $expectedArguments.Count $argumentResult.OutputLines.Count 'The argument fixture returned an unexpected number of values.'
    for ($argumentIndex = 0; $argumentIndex -lt $expectedArguments.Count; $argumentIndex++) {
        Assert-Equal $expectedArguments[$argumentIndex] $argumentResult.OutputLines[$argumentIndex] "Argument $argumentIndex did not round-trip exactly."
    }

    # PowerShell also treats smart single quotes as string delimiters. Exercise
    # each in a real script path and argument, including inert command text.
    foreach ($quoteCode in @(0x0027, 0x2018, 0x2019, 0x201A, 0x201B)) {
        $quote = [string][char]$quoteCode
        $quotedFixture = Join-Path $fixtureRoot ('quote' + $quote + 'fixture.ps1')
        $quotedSource = @'
param([string]$Value, [string]$Other)
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PSCommandPath))
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Other))
'@
        [IO.File]::WriteAllText($quotedFixture, $quotedSource, [Text.Encoding]::UTF8)
        $literal = 'literal' + $quote + '; Write-Output QUOTE_TEXT_EXECUTED; #' + $quote + ' tail'
        $quoted = Invoke-DiagnosticScript 'Quoted literal' $quotedFixture $powerShellPath $repositoryRoot 10 @('-Value', $literal, '-Other', 'after quote')
        Assert-Equal 'Success' $quoted.Status ('Quote U+{0:X4} broke a child script path or argument.' -f $quoteCode)
        Assert-Equal 3 @($quoted.OutputLines).Count 'Quoted argument text executed or changed output cardinality.'
        $quotedValues = @($quotedFixture, $literal, 'after quote')
        for ($quoteIndex = 0; $quoteIndex -lt $quotedValues.Count; $quoteIndex++) {
            Assert-Equal ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($quotedValues[$quoteIndex]))) $quoted.OutputLines[$quoteIndex] 'A quoted path or argument did not round-trip literally.'
        }
    }

    $heldFixture = Join-Path $fixtureRoot 'held.ps1'
    [IO.File]::WriteAllText($heldFixture, "`$child=Start-Process -FilePath '$powerShellPath' -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 15' -NoNewWindow -PassThru; 'HELD_CHILD_PID='+`$child.Id; 'stdout-held'; [Console]::Error.WriteLine('stderr-held')", [Text.Encoding]::UTF8)
    $started = Get-Date
    $held = Invoke-DiagnosticScript 'Held' $heldFixture $powerShellPath $repositoryRoot 10
    Assert-Equal 'Success' $held.Status 'Held pipe must retain execution status.'
    Assert-Equal $false $held.OutputComplete 'Held pipe output must be incomplete.'
    Assert-Equal 'Partial' $held.Completeness 'Incomplete successful output must be partial.'
    Assert-True (((Get-Date)-$started).TotalSeconds -lt 8) 'Held pipe drain was not bounded.'
    Assert-True (($held.OutputLines -join "`n").Contains('stdout-held')) 'Available stdout was lost.'
    Assert-True (($held.ErrorLines -join "`n").Contains('stream drain did not finish')) 'Incomplete drain note is missing.'
    $pidLine = @($held.OutputLines | Where-Object { $_ -match '^HELD_CHILD_PID=' } | Select-Object -First 1)
    if ($pidLine.Count) { $heldChildPid = [int]($pidLine[0] -replace '^HELD_CHILD_PID=','') }

    $timeoutFixture = Join-Path $fixtureRoot 'process-tree-timeout.ps1'
    $escapedPowerShellPath = $powerShellPath.Replace("'", "''")
    $timeoutSource = "`$child = Start-Process -FilePath '$escapedPowerShellPath' -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 60' -PassThru; Write-Output ('CHILD_PID=' + `$child.Id); Start-Sleep -Seconds 60"
    [IO.File]::WriteAllText($timeoutFixture, $timeoutSource, [Text.Encoding]::UTF8)
    $timeoutStarted = Get-Date
    $timeout = Invoke-DiagnosticScript 'Timeout' $timeoutFixture $powerShellPath $repositoryRoot 1
    $timeoutDuration = ((Get-Date) - $timeoutStarted).TotalSeconds
    Assert-Equal 'Timeout' $timeout.Status 'Timeout classification failed.'
    Assert-True (@($timeout.Findings | Where-Object { $_.Code -eq 'MODULE_EXECUTION_TIMEOUT' }).Count -eq 1) 'Timeout finding is missing.'
    Assert-True ($null -ne $timeout.Cleanup) 'Timeout cleanup result is missing.'
    $timeoutChildLine = @($timeout.OutputLines | Where-Object { $_ -match '^CHILD_PID=\d+$' } | Select-Object -First 1)
    if ($timeoutChildLine.Count -eq 1) { $timeoutChildPid = [int]($timeoutChildLine[0] -replace '^CHILD_PID=', '') }
    $timeoutRootItem = @($timeout.Cleanup.Items | Where-Object { [int]$_.Depth -eq 0 } | Select-Object -First 1)
    if ($timeoutRootItem.Count -eq 1) { $timeoutRootPid = [int]$timeoutRootItem[0].ProcessId }
    $cleanupDetails = @($timeout.Cleanup.Errors) + @($timeout.Cleanup.Items | Where-Object { $_.Status -notin @('Terminated', 'AlreadyExited') } | ForEach-Object { 'PID {0} depth {1}: {2} - {3}' -f $_.ProcessId, $_.Depth, $_.Status, $_.Message })
    Assert-Equal $true $timeout.Cleanup.Success ('Real process-tree cleanup must succeed. Details: ' + ($cleanupDetails -join '; '))
    Assert-True (@($timeout.Cleanup.Items | Where-Object { [int]$_.Depth -gt 0 }).Count -ge 1) 'Cleanup did not include a descendant process.'
    $cleanupDepths = @($timeout.Cleanup.Items | ForEach-Object { [int]$_.Depth })
    for ($index = 1; $index -lt $cleanupDepths.Count; $index++) {
        Assert-True ($cleanupDepths[$index - 1] -ge $cleanupDepths[$index]) 'Cleanup items are not ordered from greater depth to lesser depth.'
    }
    Assert-Equal 1 $timeoutChildLine.Count 'Timeout fixture did not report exactly one child PID.'
    Assert-Equal 1 $timeoutRootItem.Count 'Cleanup result does not contain the root process.'
    Assert-True ($null -eq (Get-Process -Id $timeoutChildPid -ErrorAction SilentlyContinue)) 'Child process still exists after cleanup.'
    Assert-True ($null -eq (Get-Process -Id $timeoutRootPid -ErrorAction SilentlyContinue)) 'Root fixture process still exists after cleanup.'
    Assert-True ($timeoutDuration -lt 20) 'Real process-tree timeout fixture exceeded its bounded runtime.'

    $unstarted = New-Object Diagnostics.Process
    $cleanupStarted = Get-Date
    $cleanup = Stop-WdtProcessTree $unstarted 100
    Assert-Equal $false $cleanup.Success 'Cleanup without identity must fail.'
    Assert-True (((Get-Date)-$cleanupStarted).TotalSeconds -lt 3) 'Failed cleanup was not bounded.'
    $unstarted.Dispose()
}
finally {
    foreach ($fixturePid in @($heldChildPid, $timeoutChildPid, $timeoutRootPid)) {
        if ($null -eq $fixturePid) { continue }
        $fixtureProcess = Get-Process -Id $fixturePid -ErrorAction SilentlyContinue
        if ($null -ne $fixtureProcess -and
            $fixtureProcess.ProcessName -eq [IO.Path]::GetFileNameWithoutExtension($powerShellPath) -and
            $fixtureProcess.StartTime -ge $fixtureStarted) {
            Stop-Process -Id $fixturePid -Force -ErrorAction SilentlyContinue
        }
    }
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolvedFixtureRoot.StartsWith($runtimeTemporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe process runner fixture cleanup.' }
    Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Process runner tests passed.'
