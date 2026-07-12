[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }
function Import-TestFunctions {
    param([string]$Path, [string[]]$Names)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    foreach ($name in $Names) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        $scriptDefinition = $definition.Extent.Text -replace ('^function\s+' + [regex]::Escape($name)), ('function script:' + $name)
        Invoke-Expression $scriptDefinition
    }
}

Import-TestFunctions (Join-Path $repositoryRoot 'scripts\services-check.ps1') @('Get-ServiceDiagnosticState')
Assert-Equal 'Indeterminate' (Get-ServiceDiagnosticState ([pscustomobject]@{ StartMode='Auto'; State='Stopped'; ExitCode=0 })) 'Stopped automatic service must remain neutral.'
Assert-Equal 'WarnPending' (Get-ServiceDiagnosticState ([pscustomobject]@{ StartMode='Auto'; State='Start Pending'; ExitCode=0 })) 'Pending state must remain distinct.'

Import-TestFunctions (Join-Path $repositoryRoot 'scripts\network-check.ps1') @('Get-NetworkReachabilityClassification','Test-TcpEndpointConnection')
Assert-Equal 'Reachable' (Get-NetworkReachabilityClassification $true 'Unavailable' 'Resolved: 1.2.3.4' 'Reachable' $true) 'Unavailable route inventory must not override working DNS/TCP.'
Assert-Equal 'Unreachable' (Get-NetworkReachabilityClassification $true 'Absent' 'Failed: fixture' 'Unreachable: fixture' $true) 'Confirmed absent route plus failed probes must be unreachable.'
Assert-Equal 'NotTested' (Get-NetworkReachabilityClassification $false 'Unavailable' 'NotTested' 'NotTested' $false) 'Disabled external tests must be explicit.'
Assert-True ((Test-TcpEndpointConnection 'not a uri').StartsWith('Indeterminate:')) 'Invalid endpoint must be indeterminate.'

Import-TestFunctions (Join-Path $repositoryRoot 'scripts\performance-snapshot.ps1') @('Get-ProcessCpuActivity')
$activity = @(Get-ProcessCpuActivity @([pscustomobject]@{Id=1;Name='old';CpuTime=10;StartTime=[datetime]'2024-01-01'}) @([pscustomobject]@{Id=1;Name='new';CpuTime=12;StartTime=[datetime]'2024-01-01'}) 1 4)
Assert-Equal 0 $activity.Count 'Same PID with a different process name must not match.'

Import-TestFunctions (Join-Path $repositoryRoot 'scripts\disk-health.ps1') @('Get-StorageReliabilityData')
$storage = Get-StorageReliabilityData $null
Assert-Equal $false $storage.Available 'Missing reliability counters must be unavailable.'
Assert-True (-not ($storage.PSObject.Properties.Name -contains 'Error')) 'Unused storage Error field must not return.'
$storageSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'scripts\disk-health.ps1') -Raw
Assert-True ($storageSource.Contains('Data availability:')) 'Storage availability wording is missing.'
Assert-True (-not $storageSource.Contains('Completeness: Partial')) 'Storage must not redefine execution completeness.'

Write-Host 'Diagnostic classification tests passed.'
