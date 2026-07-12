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
$fixtureRoot = Join-Path $env:TEMP ('wdt-runtime-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$heldChildPid = $null
try {
    $streamFixture = Join-Path $fixtureRoot 'stream.ps1'
    [IO.File]::WriteAllText($streamFixture, "Write-Output 'out'; [Console]::Error.WriteLine('err')", [Text.Encoding]::UTF8)
    $missingExecutable = Join-Path $fixtureRoot 'missing-powershell.exe'
    $launch = Invoke-DiagnosticScript 'Launch' $streamFixture $missingExecutable $repositoryRoot 5
    Assert-Equal 'LaunchError' $launch.Status 'Missing executable must return LaunchError.'
    Assert-True (($launch.ErrorLines -join "`n").Contains('Failed to run script:')) 'Original launch message is missing.'
    Assert-True (-not (($launch.ErrorLines -join "`n").Contains('No process is associated'))) 'Secondary process error masked launch error.'

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

    $timeoutFixture = Join-Path $fixtureRoot 'timeout.ps1'
    [IO.File]::WriteAllText($timeoutFixture, 'Start-Sleep -Seconds 60', [Text.Encoding]::UTF8)
    $timeout = Invoke-DiagnosticScript 'Timeout' $timeoutFixture $powerShellPath $repositoryRoot 1
    Assert-Equal 'Timeout' $timeout.Status 'Timeout classification failed.'
    Assert-True ($null -ne $timeout.Cleanup) 'Timeout cleanup result is missing.'

    $unstarted = New-Object Diagnostics.Process
    $cleanupStarted = Get-Date
    $cleanup = Stop-WdtProcessTree $unstarted 100
    Assert-Equal $false $cleanup.Success 'Cleanup without identity must fail.'
    Assert-True (((Get-Date)-$cleanupStarted).TotalSeconds -lt 3) 'Failed cleanup was not bounded.'
    $unstarted.Dispose()
}
finally {
    if ($null -ne $heldChildPid) { Stop-Process -Id $heldChildPid -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Process runner tests passed.'
