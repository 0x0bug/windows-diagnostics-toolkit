[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\report-common.ps1')
. (Join-Path $repositoryRoot 'scripts\process-runner.ps1')
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
$failedSummary = Get-WdtProcessCleanupSummary @([pscustomobject]@{Status='TerminationFailed'}) @('fixture') $false
Assert-Equal $false $failedSummary.Success 'Failed cleanup must be explicit.'

$powerShellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$fixtureStarted = Get-Date
$fixtureRoot = Join-Path $env:TEMP ('wdt-runtime-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$heldChildPid = $null
$timeoutChildPid = $null
$timeoutRootPid = $null
try {
    $streamFixture = Join-Path $fixtureRoot 'stream.ps1'
    [IO.File]::WriteAllText($streamFixture, "Write-Output 'out'; [Console]::Error.WriteLine('err')", [Text.Encoding]::UTF8)
    $missingExecutable = Join-Path $fixtureRoot 'missing-powershell.exe'
    $launch = Invoke-DiagnosticScript 'Launch' $streamFixture $missingExecutable $repositoryRoot 5
    Assert-Equal 'LaunchError' $launch.Status 'Missing executable must return LaunchError.'
    Assert-True (($launch.ErrorLines -join "`n").Contains('Failed to run script:')) 'Original launch message is missing.'
    Assert-True (-not (($launch.ErrorLines -join "`n").Contains('No process is associated'))) 'Secondary process error masked launch error.'

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
    $argumentSource = "param([string]`$Value1, [string]`$Value2, [string]`$Value3, [string]`$Value4, [string]`$Value5, [string]`$Value6, [string]`$Value7, [string]`$Value8)`r`nforeach (`$value in @(`$Value1, `$Value2, `$Value3, `$Value4, `$Value5, `$Value6, `$Value7, `$Value8)) {`r`n    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(`$value))`r`n}"
    [IO.File]::WriteAllText($argumentFixture, $argumentSource, [Text.Encoding]::UTF8)
    $unicodeValue = 'Unicode: ' + (-join @([char]0x041F, [char]0x0440, [char]0x0438, [char]0x0432, [char]0x0435, [char]0x0442, [char]0x0020, [char]0x96EA))
    $argumentValues = @('', 'plain value', $unicodeValue, 'double"quote', 'trailing\', "single'quote", '$dollar; & ampersand', 'back`tick')
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
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Process runner tests passed.'
