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
Assert-Equal 'Reachable' (Get-NetworkReachabilityClassification $true $true 'Resolved: 1.2.3.4' 'Reachable' 'Not reachable' $true) 'Blocked ICMP must not override working DNS/TCP.'
Assert-Equal 'NotTested' (Get-NetworkReachabilityClassification $true $true 'NotTested' 'NotTested' 'NotTested' $false) 'Disabled external tests must be explicit.'

Import-TestFunctions (Join-Path $repositoryRoot 'scripts\performance-snapshot.ps1') @('Get-ProcessCpuActivity')
$activity = @(Get-ProcessCpuActivity @([pscustomobject]@{Id=1;Name='kept';CpuTime=10}) @([pscustomobject]@{Id=2;Name='new';CpuTime=1}) 1 4)
Assert-Equal 0 $activity.Count 'Exited and newly-created processes must be ignored safely.'
$activity = @(Get-ProcessCpuActivity @([pscustomobject]@{Id=1;Name='kept';CpuTime=10}) @([pscustomobject]@{Id=1;Name='kept';CpuTime=12}) 1 4)
Assert-Equal 50 ([int]$activity[0].CpuActivityPercent) 'CPU delta must be normalized by logical processor count.'

Import-TestFunctions (Join-Path $repositoryRoot 'scripts\disk-health.ps1') @('Get-StorageReliabilityData')
$storage = Get-StorageReliabilityData $null
Assert-Equal $false $storage.Available 'A disk without reliability counters is not a failure.'

. (Join-Path $repositoryRoot 'scripts\report-common.ps1')
Import-TestFunctions (Join-Path $repositoryRoot 'Invoke-WindowsDiagnostics.ps1') @('Get-RelativeDisplayPath','Convert-TextToLines','ConvertTo-CommandArgument','Stop-WdtProcessTree','Invoke-DiagnosticScript')
$powerShellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$cyrillicTest = ([string][char]0x442) + [char]0x435 + [char]0x441 + [char]0x442
$fixtureRoot = Join-Path $env:TEMP ('WDT ' + $cyrillicTest + ' space ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
try {
    $streamFixture = Join-Path $fixtureRoot 'streams.ps1'
    [System.IO.File]::WriteAllText($streamFixture, "1..4000 | ForEach-Object { Write-Output ('out-' + `$_); [Console]::Error.WriteLine('err-' + `$_) }", [Text.Encoding]::UTF8)
    $streamResult = Invoke-DiagnosticScript 'Streams' $streamFixture $powerShellPath $repositoryRoot 30
    Assert-Equal 'Success' $streamResult.Status 'Concurrent stdout/stderr collection must complete.'
    Assert-True ($streamResult.OutputLines.Count -ge 4000) 'stdout was truncated.'
    Assert-True ($streamResult.ErrorLines.Count -ge 4000) 'stderr was truncated.'

    $timeoutFixture = Join-Path $fixtureRoot 'timeout.ps1'
    [System.IO.File]::WriteAllText($timeoutFixture, "`$child = Start-Process -FilePath '$powerShellPath' -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 60' -PassThru; Write-Output ('CHILD_PID=' + `$child.Id); Start-Sleep -Seconds 60", [Text.Encoding]::UTF8)
    $timeoutResult = Invoke-DiagnosticScript 'Timeout' $timeoutFixture $powerShellPath $repositoryRoot 1
    Assert-Equal 'Timeout' $timeoutResult.Status 'Timeout must be classified separately.'
    Assert-True (@($timeoutResult.Findings | Where-Object Code -eq 'MODULE_EXECUTION_TIMEOUT').Count -eq 1) 'Timeout finding code is missing.'
    $pidLine = @($timeoutResult.OutputLines | Where-Object { $_ -match '^CHILD_PID=' } | Select-Object -First 1)
    if ($pidLine.Count -eq 1) {
        $childPid = [int]($pidLine[0] -replace '^CHILD_PID=', '')
        Assert-True ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'Timed-out child process was left running.'
    }
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Diagnostic reliability tests passed.'
