[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw ("$Message Expected=$Expected Actual=$Actual") } }

function Import-TestFunctions {
    param([string]$Path, [string[]]$Names)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 @($errors).Count "Parser errors in $Path."
    foreach ($name in $Names) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        Assert-True ($null -ne $definition) "Missing function $name in $Path."
        $scriptDefinition = $definition.Extent.Text -replace ('^function\s+' + [regex]::Escape($name)), ('function script:' + $name)
        Invoke-Expression $scriptDefinition
    }
}

$moduleScripts = @(
    'system-info.ps1', 'security-posture.ps1', 'performance-snapshot.ps1', 'network-check.ps1',
    'time-sync-diagnostics.ps1', 'disk-health.ps1', 'crash-hang-diagnostics.ps1', 'event-log-check.ps1',
    'services-check.ps1', 'windows-update-check.ps1'
)
foreach ($script in $moduleScripts) {
    $path = Join-Path $repositoryRoot "scripts\$script"
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing module $script."
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 @($errors).Count "Module $script must parse."
}

Import-TestFunctions (Join-Path $repositoryRoot 'scripts\services-check.ps1') @('Get-ServiceDiagnosticState')
Assert-Equal 'Indeterminate' (Get-ServiceDiagnosticState ([pscustomobject]@{ StartMode='Auto'; State='Stopped'; ExitCode=0 })) 'Auto + Stopped must be neutral.'
Assert-Equal 'WarnPending' (Get-ServiceDiagnosticState ([pscustomobject]@{ StartMode='Auto'; State='Start Pending'; ExitCode=0 })) 'Pending service state must be distinct.'

Import-TestFunctions (Join-Path $repositoryRoot 'scripts\network-check.ps1') @('Get-NetworkReachabilityClassification')
Assert-Equal 'Reachable' (Get-NetworkReachabilityClassification $true 'Present' 'Resolved: 1.2.3.4' 'Reachable' 'Not reachable' $true) 'Blocked ICMP must not override working DNS/TCP.'
Assert-Equal 'Reachable' (Get-NetworkReachabilityClassification $true 'Unavailable' 'Resolved: 1.2.3.4' 'Reachable' 'Not reachable' $true) 'Unavailable route inventory must not override working DNS/TCP.'
Assert-Equal 'Unreachable' (Get-NetworkReachabilityClassification $true 'Absent' 'Failed: fixture' 'Unreachable: fixture' 'Not reachable' $true) 'Confirmed absent route plus failed probes must be unreachable.'
Assert-Equal 'NotTested' (Get-NetworkReachabilityClassification $false 'Unavailable' 'NotTested' 'NotTested' 'NotTested' $false) 'Disabled external tests must be explicit.'

Import-TestFunctions (Join-Path $repositoryRoot 'scripts\performance-snapshot.ps1') @('Get-ProcessCpuActivity')
$activity = @(Get-ProcessCpuActivity @([pscustomobject]@{Id=1;Name='kept';CpuTime=10;StartTime=[datetime]'2024-01-01'}) @([pscustomobject]@{Id=2;Name='new';CpuTime=1;StartTime=[datetime]'2024-01-01'}) 1 4)
Assert-Equal 0 $activity.Count 'Exited and newly-created processes must be ignored safely.'
$activity = @(Get-ProcessCpuActivity @([pscustomobject]@{Id=1;Name='old-name';CpuTime=10;StartTime=[datetime]'2024-01-01'}) @([pscustomobject]@{Id=1;Name='new-name';CpuTime=12;StartTime=[datetime]'2024-01-01'}) 1 4)
Assert-Equal 0 $activity.Count 'A reused PID with a different process name must not match.'
$activity = @(Get-ProcessCpuActivity @([pscustomobject]@{Id=1;Name='kept';CpuTime=10;StartTime=[datetime]'2024-01-01'}) @([pscustomobject]@{Id=1;Name='kept';CpuTime=12;StartTime=[datetime]'2024-01-02'}) 1 4)
Assert-Equal 0 $activity.Count 'A reused PID with a different start time must not match.'
$activity = @(Get-ProcessCpuActivity @([pscustomobject]@{Id=1;Name='kept';CpuTime=10;StartTime=[datetime]'2024-01-01'}) @([pscustomobject]@{Id=1;Name='KEPT';CpuTime=12;StartTime=[datetime]'2024-01-01'}) 1 4)
Assert-Equal 50 ([int]$activity[0].CpuActivityPercent) 'CPU delta must be normalized by logical processor count.'

Import-TestFunctions (Join-Path $repositoryRoot 'scripts\disk-health.ps1') @('Get-StorageReliabilityData')
$storage = Get-StorageReliabilityData $null
Assert-Equal $false $storage.Available 'A disk without reliability counters is not a failure.'

. (Join-Path $repositoryRoot 'scripts\report-common.ps1')
Import-TestFunctions (Join-Path $repositoryRoot 'Invoke-WindowsDiagnostics.ps1') @(
    'Get-RelativeDisplayPath','Convert-TextToLines','ConvertTo-CommandArgument',
    'Get-WdtExecutionCompleteness','Get-WdtCollectionCompleteness',
    'New-WdtStreamCaptureState','Read-WdtCompletedStreamChunks',
    'Get-WdtProcessCreationKey','Test-WdtProcessIdentity','Get-WdtProcessTreeSnapshot',
    'Test-WdtSnapshotMembership','Get-WdtProcessCleanupSummary','Stop-WdtProcessTree','Invoke-DiagnosticScript'
)

$executionCompleteness = @{
    Success = 'Complete'; NonZeroExit = 'Partial'; Timeout = 'Partial'; LaunchError = 'Unavailable'; Cancelled = 'Unavailable'
}
foreach ($status in $executionCompleteness.Keys) {
    Assert-Equal $executionCompleteness[$status] (Get-WdtExecutionCompleteness -Status $status) "Execution completeness is wrong for $status."
}
foreach ($left in $executionCompleteness.Keys) {
    foreach ($right in $executionCompleteness.Keys) {
        $expected = if ($executionCompleteness[$left] -eq 'Unavailable' -and $executionCompleteness[$right] -eq 'Unavailable') {
            'Unavailable'
        }
        elseif ($executionCompleteness[$left] -eq 'Complete' -and $executionCompleteness[$right] -eq 'Complete') {
            'Complete'
        }
        else {
            'Partial'
        }
        $actual = Get-WdtCollectionCompleteness -Results @([pscustomobject]@{Status=$left}, [pscustomobject]@{Status=$right})
        Assert-Equal $expected $actual "Collection completeness is wrong for $left + $right."
    }
}

$missingIdentity = Test-WdtProcessIdentity -Expected ([pscustomobject]@{ ProcessId=987654; ParentProcessId=1; IsRoot=$false; CreationKey='missing' }) -Current $null
Assert-Equal 'NotFound' $missingIdentity 'A nonexistent PID must be classified without throwing.'
$rootEntry = [pscustomobject]@{ ProcessId=100; ParentProcessId=1; Depth=0; IsRoot=$true; CreationKey='2024-01-01T00:00:00.0000000'; StartTime=[datetime]'2024-01-01' }
$childEntry = [pscustomobject]@{ ProcessId=200; ParentProcessId=100; Depth=1; IsRoot=$false; CreationKey='2024-01-01T00:00:01.0000000'; StartTime=[datetime]'2024-01-01T00:00:01' }
$snapshotById = @{ 100=$rootEntry; 200=$childEntry }
$membershipStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$exitedChildMembership = & {
    function Get-CimInstance { [CmdletBinding()] param($ClassName, $Filter, $OperationTimeoutSec) return @() }
    Test-WdtSnapshotMembership -Entry $childEntry -SnapshotById $snapshotById -CleanupStopwatch $membershipStopwatch -CleanupTimeoutMilliseconds 500
}
$membershipStopwatch.Stop()
Assert-Equal 'TargetNotFound' $exitedChildMembership 'An already-exited descendant must be a safe cleanup outcome.'
$ancestorStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$missingAncestorMembership = & {
    function Get-CimInstance {
        [CmdletBinding()] param($ClassName, $Filter, $OperationTimeoutSec)
        if ($Filter -eq 'ProcessId=200') { return [pscustomobject]@{ ProcessId=200; ParentProcessId=100; CreationDate=[datetime]'2024-01-01T00:00:01' } }
        return @()
    }
    Test-WdtSnapshotMembership -Entry $childEntry -SnapshotById $snapshotById -CleanupStopwatch $ancestorStopwatch -CleanupTimeoutMilliseconds 500
}
$ancestorStopwatch.Stop()
Assert-Equal 'AncestorNotFound' $missingAncestorMembership 'A missing ancestor must not be treated as an exited target.'
$alreadyExitedCleanup = Get-WdtProcessCleanupSummary -Items @([pscustomobject]@{ Status='AlreadyExited' }) -Errors @() -TimedOut $false
Assert-Equal $true $alreadyExitedCleanup.Success 'An already-exited descendant must not make cleanup fail.'
$failedCleanup = Get-WdtProcessCleanupSummary -Items @([pscustomobject]@{ Status='TerminationFailed' }) -Errors @('fixture failure') -TimedOut $false
Assert-Equal $false $failedCleanup.Success 'An unsuccessful cleanup must not be reported as successful.'

$powerShellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$cyrillicTest = ([string][char]0x442) + [char]0x435 + [char]0x441 + [char]0x442
$fixtureRoot = Join-Path $env:TEMP ('WDT ' + $cyrillicTest + ' space ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$heldChildPid = $null
try {
    $streamFixture = Join-Path $fixtureRoot 'streams.ps1'
    [System.IO.File]::WriteAllText($streamFixture, "1..4000 | ForEach-Object { Write-Output ('out-' + `$_); [Console]::Error.WriteLine('err-' + `$_) }", [Text.Encoding]::UTF8)
    $streamResult = Invoke-DiagnosticScript 'Streams' $streamFixture $powerShellPath $repositoryRoot 30
    Assert-Equal 'Success' $streamResult.Status 'Concurrent stdout/stderr collection must complete.'
    Assert-True ($streamResult.OutputLines.Count -ge 4000) 'stdout was truncated.'
    Assert-True ($streamResult.ErrorLines.Count -ge 4000) 'stderr was truncated.'

    $heldPipeFixture = Join-Path $fixtureRoot 'held-pipe.ps1'
    $heldPipeSource = "`$child = Start-Process -FilePath '$powerShellPath' -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 15' -NoNewWindow -PassThru; Write-Output ('HELD_CHILD_PID=' + `$child.Id); Write-Output 'stdout-before-held-pipe'; [Console]::Error.WriteLine('stderr-before-held-pipe')"
    [System.IO.File]::WriteAllText($heldPipeFixture, $heldPipeSource, [Text.Encoding]::UTF8)
    $heldPipeStarted = Get-Date
    $heldPipeResult = Invoke-DiagnosticScript 'HeldPipe' $heldPipeFixture $powerShellPath $repositoryRoot 10
    $heldPipeDuration = ((Get-Date) - $heldPipeStarted).TotalSeconds
    Assert-Equal 'Success' $heldPipeResult.Status 'Parent exit must retain its execution status when a child holds pipe handles.'
    Assert-Equal $false $heldPipeResult.OutputComplete 'Held pipe handles must report incomplete output.'
    Assert-True ($heldPipeDuration -lt 8) 'Held pipe drain exceeded its bounded runtime.'
    Assert-True (($heldPipeResult.OutputLines -join "`n").Contains('stdout-before-held-pipe')) 'Available stdout was not preserved.'
    Assert-True (($heldPipeResult.ErrorLines -join "`n").Contains('stderr-before-held-pipe')) 'Available stderr was not preserved.'
    Assert-True (($heldPipeResult.ErrorLines -join "`n").Contains('stream drain did not finish')) 'Incomplete stream drain was not reported.'
    $heldChildLine = @($heldPipeResult.OutputLines | Where-Object { $_ -match '^HELD_CHILD_PID=' } | Select-Object -First 1)
    if ($heldChildLine.Count -eq 1) {
        $heldChildPid = [int]($heldChildLine[0] -replace '^HELD_CHILD_PID=', '')
    }

    $timeoutFixture = Join-Path $fixtureRoot 'timeout.ps1'
    [System.IO.File]::WriteAllText($timeoutFixture, "`$child = Start-Process -FilePath '$powerShellPath' -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 60' -PassThru; Write-Output ('CHILD_PID=' + `$child.Id); Start-Sleep -Seconds 60", [Text.Encoding]::UTF8)
    $timeoutResult = Invoke-DiagnosticScript 'Timeout' $timeoutFixture $powerShellPath $repositoryRoot 1
    Assert-Equal 'Timeout' $timeoutResult.Status 'Timeout must be classified separately.'
    Assert-True (@($timeoutResult.Findings | Where-Object Code -eq 'MODULE_EXECUTION_TIMEOUT').Count -eq 1) 'Timeout finding code is missing.'
    Assert-True ($null -ne $timeoutResult.Cleanup) 'Timeout cleanup result is missing.'
    Assert-Equal $true $timeoutResult.Cleanup.Success 'Verified timeout cleanup must report success.'
    $cleanupDepths = @($timeoutResult.Cleanup.Items | ForEach-Object { [int]$_.Depth })
    for ($depthIndex = 1; $depthIndex -lt $cleanupDepths.Count; $depthIndex++) {
        Assert-True ($cleanupDepths[$depthIndex - 1] -ge $cleanupDepths[$depthIndex]) 'Cleanup did not process descendants from deepest to root.'
    }
    $pidLine = @($timeoutResult.OutputLines | Where-Object { $_ -match '^CHILD_PID=' } | Select-Object -First 1)
    if ($pidLine.Count -eq 1) {
        $childPid = [int]($pidLine[0] -replace '^CHILD_PID=', '')
        Assert-True ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'Timed-out child process was left running.'
    }

    $findingFixture = Join-Path $fixtureRoot 'finding.ps1'
    $escapedReportCommon = (Join-Path $repositoryRoot 'scripts\report-common.ps1').Replace("'", "''")
    [System.IO.File]::WriteAllText($findingFixture, ". '$escapedReportCommon'; Write-WdtFinding -Severity WARN -Code 'FIXTURE_SOURCE_UNAVAILABLE' -Message 'Fixture source unavailable.'", [Text.Encoding]::UTF8)
    $findingResult = Invoke-DiagnosticScript 'Finding' $findingFixture $powerShellPath $repositoryRoot 10
    Assert-Equal 'Success' $findingResult.Status 'Fixture finding process must succeed.'
    Assert-Equal 'Complete' $findingResult.Completeness 'Finding code names must not change execution completeness.'

    $missingExecutable = Join-Path $fixtureRoot 'missing-powershell.exe'
    $launchResult = Invoke-DiagnosticScript 'LaunchError' $streamFixture $missingExecutable $repositoryRoot 5
    Assert-Equal 'LaunchError' $launchResult.Status 'Missing executable must return LaunchError.'
    Assert-Equal 'Unavailable' $launchResult.Completeness 'LaunchError completeness must be unavailable.'
    $launchErrorText = $launchResult.ErrorLines -join "`n"
    Assert-True ($launchErrorText.Contains('Failed to run script:')) 'Primary launch error message is missing.'
    Assert-True ($launchErrorText -match '(?i)(missing-powershell\.exe|cannot find|system cannot find)') 'Original missing-executable error was not preserved.'
    Assert-True (-not $launchErrorText.Contains('No process is associated')) 'A secondary process-state error masked the launch failure.'

    $exitedProcess = Start-Process -FilePath $powerShellPath -ArgumentList '-NoProfile -Command exit 0' -PassThru
    $exitedProcess.WaitForExit()
    $exitedCleanup = Stop-WdtProcessTree -RootProcess $exitedProcess -CleanupTimeoutMilliseconds 500
    Assert-Equal $false $exitedCleanup.Success 'An exited root must not claim that descendant cleanup was verified.'
    $exitedProcess.Dispose()

    $unstartedProcess = New-Object System.Diagnostics.Process
    $failedCleanupStarted = Get-Date
    $unstartedCleanup = Stop-WdtProcessTree -RootProcess $unstartedProcess -CleanupTimeoutMilliseconds 100
    $failedCleanupDuration = ((Get-Date) - $failedCleanupStarted).TotalSeconds
    Assert-Equal $false $unstartedCleanup.Success 'Cleanup without a process identity must fail explicitly.'
    Assert-True ($unstartedCleanup.Errors.Count -gt 0) 'Cleanup failure details are missing.'
    Assert-True ($failedCleanupDuration -lt 3) 'Failed cleanup did not respect a bounded runtime.'
    $unstartedProcess.Dispose()
}
finally {
    if ($null -ne $heldChildPid) { Stop-Process -Id $heldChildPid -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Diagnostic reliability tests passed.'
