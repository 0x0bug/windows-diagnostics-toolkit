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

$now = Get-Date

# Event Log fixtures: severity alone is context; exact rules, grouping, cutoff,
# provider identity, and partial source availability are deterministic.
$eventsScript = Join-Path $repositoryRoot 'modules\events\diagnostic.ps1'
Import-TestFunctions $eventsScript @('Get-EventSignalRule','Group-EventLogEvents','Read-EventLog')
Assert-True ($null -eq (Get-EventSignalRule 'Application' 'Fixture-Provider' 1000 2)) 'A generic Error event must remain context.'
Assert-True ($null -eq (Get-EventSignalRule 'System' 'Microsoft-Windows-DistributedCOM' 10016 2)) 'Expected DCOM 10016 noise must remain context.'
Assert-True ($null -eq (Get-EventSignalRule 'System' 'Fixture-Kernel-Power' 41 1)) 'Event ID 41 from another provider must not match.'
Assert-True ($null -eq (Get-EventSignalRule 'System' 'Microsoft-Windows-Kernel-Power' 41 2)) 'Kernel-Power 41 with the wrong level must not match.'
Assert-Equal 'EVENT_UNEXPECTED_SHUTDOWN' (Get-EventSignalRule 'System' 'Microsoft-Windows-Kernel-Power' 41 1).Code 'Kernel-Power 41 must be a documented signal.'
Assert-Equal 'EVENT_FILE_SYSTEM_CORRUPTION' (Get-EventSignalRule 'System' 'Ntfs' 55 2).Code 'NTFS 55 must be a documented signal.'

$eventCutoff = $now.AddHours(-24)
$eventFixtures = @(
    [pscustomobject]@{ ProviderName='Fixture-Provider'; Id=7000; Level=2; LevelDisplayName='Error'; LogName='Application'; TimeCreated=$now.AddHours(-3); Message='first'; RecordId=1 },
    [pscustomobject]@{ ProviderName='Fixture-Provider'; Id=7000; Level=2; LevelDisplayName='Error'; LogName='Application'; TimeCreated=$now.AddHours(-2); Message='second'; RecordId=2 },
    [pscustomobject]@{ ProviderName='Fixture-Provider'; Id=7000; Level=2; LevelDisplayName='Error'; LogName='Application'; TimeCreated=$now.AddHours(-1); Message='representative'; RecordId=3 },
    [pscustomobject]@{ ProviderName='Other-Provider'; Id=7000; Level=2; LevelDisplayName='Error'; LogName='Application'; TimeCreated=$now.AddMinutes(-30); Message='other provider'; RecordId=4 },
    [pscustomobject]@{ ProviderName='Microsoft-Windows-Kernel-Power'; Id=41; Level=1; LevelDisplayName='Critical'; LogName='System'; TimeCreated=$now.AddDays(-2); Message='old signal'; RecordId=5 }
)
$eventGroups = @(Group-EventLogEvents $eventFixtures $eventCutoff)
Assert-Equal 2 $eventGroups.Count 'Different providers with the same Event ID must remain separate, and old events must be excluded.'
$repeatedEventGroup = @($eventGroups | Where-Object { $_.ProviderName -eq 'Fixture-Provider' })[0]
Assert-Equal 3 $repeatedEventGroup.Count 'Repeated events must be grouped.'
Assert-Equal 'representative' $repeatedEventGroup.RepresentativeMessage 'The latest event must provide the representative message.'
Assert-True (-not $repeatedEventGroup.IsSignal) 'A grouped generic Error event must not become a finding.'

function script:Get-WinEvent {
    [CmdletBinding()]
    param([hashtable]$FilterHashtable, [int]$MaxEvents)
    throw 'Fixture event log access denied.'
}
try {
    $unavailableEventLog = Read-EventLog 'Application' $eventCutoff @(1,2) 50
    Assert-True ($null -ne $unavailableEventLog.Error) 'An unavailable event log must be returned as context.'
    Assert-Equal 0 @($unavailableEventLog.Events).Count 'An unavailable event log must not invent events.'
}
finally {
    Remove-Item Function:\Get-WinEvent -ErrorAction SilentlyContinue
}

$previousProtocolMode = $env:WDT_FINDING_PROTOCOL
try {
    $eventModuleOutput = @(& {
            function Get-WinEvent {
                [CmdletBinding()]
                param([hashtable]$FilterHashtable, [int]$MaxEvents)

                $recent = Get-Date
                if ($FilterHashtable.LogName -eq 'Application') { throw 'Fixture application log access denied.' }
                if ($FilterHashtable.ContainsKey('Id')) {
                    return [pscustomobject]@{ ProviderName='Microsoft-Windows-Kernel-Power'; Id=41; Level=1; LevelDisplayName='Critical'; LogName='System'; TimeCreated=$recent; Message='fixture unexpected restart'; RecordId=42 }
                }
                return @(
                    [pscustomobject]@{ ProviderName='Fixture-Provider'; Id=1000; Level=2; LevelDisplayName='Error'; LogName='System'; TimeCreated=$recent; Message='generic error'; RecordId=41 },
                    [pscustomobject]@{ ProviderName='Microsoft-Windows-Kernel-Power'; Id=41; Level=1; LevelDisplayName='Critical'; LogName='System'; TimeCreated=$recent; Message='fixture unexpected restart'; RecordId=42 }
                )
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $eventsScript -SinceHours 24 6>&1 | ForEach-Object { [string]$_ }
        })

    $eventAssessmentUnavailableOutput = @(& {
            function Get-WinEvent {
                [CmdletBinding()]
                param([hashtable]$FilterHashtable, [int]$MaxEvents)

                throw 'Fixture all event sources unavailable.'
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $eventsScript -SinceHours 24 6>&1 | ForEach-Object { [string]$_ }
        })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}
$eventModuleText = $eventModuleOutput -join "`n"
Assert-True ($eventModuleText.Contains('EVENT_UNEXPECTED_SHUTDOWN')) 'A documented high-signal event must emit a finding.'
Assert-True (-not $eventModuleText.Contains('RECENT_ERROR_EVENTS')) 'A generic Error event must not emit the legacy blanket finding.'
Assert-True (-not $eventModuleText.Contains('EVENT_LOG_SOURCE_UNAVAILABLE')) 'Partial event-log access must remain context.'
Assert-True (-not $eventModuleText.Contains('EVENT_LOG_ASSESSMENT_UNAVAILABLE')) 'One unavailable Event Log source with working fallbacks must remain context.'
Assert-True (-not ($eventModuleText -match '"Severity":"ERROR"')) 'Partial event-log access must not create ERROR.'
$eventAssessmentUnavailableText = $eventAssessmentUnavailableOutput -join "`n"
Assert-Equal 1 ([regex]::Matches($eventAssessmentUnavailableText, '@@WDT_FINDING@@').Count) 'Complete Event Log source loss must emit exactly one finding.'
Assert-Equal 1 ([regex]::Matches($eventAssessmentUnavailableText, 'EVENT_LOG_ASSESSMENT_UNAVAILABLE').Count) 'Complete Event Log source loss must emit one assessment-level code.'
Assert-True ($eventAssessmentUnavailableText.Contains('assessment could not be completed')) 'Event Log availability message must describe an incomplete assessment.'
Assert-True ($eventAssessmentUnavailableText.Contains('"Severity":"WARN"')) 'Event Log assessment availability must emit WARN.'
Assert-True (-not ($eventAssessmentUnavailableText -match '"Severity":"ERROR"')) 'Event Log availability must never create ERROR.'

# Windows Update fixtures: only confirmed event templates, update-specific reboot
# indicators, and explicit core-infrastructure failures create findings.
$updatesScript = Join-Path $repositoryRoot 'modules\updates\diagnostic.ps1'
Import-TestFunctions $updatesScript @('Get-PendingRebootFindingIndicators','Get-WindowsUpdateInfrastructureState','ConvertTo-WindowsUpdateFailure','Group-WindowsUpdateFailures','Read-WindowsUpdateEvents')
$manualUpdateService = [pscustomobject]@{ Name='wuauserv'; State='Stopped'; StartMode='Manual'; ExitCode=0 }
Assert-Equal 'Normal' (Get-WindowsUpdateInfrastructureState @($manualUpdateService) $true).State 'A stopped manual update service must remain context.'
$notStartedUpdateService = [pscustomobject]@{ Name='wuauserv'; State='Stopped'; StartMode='Manual'; ExitCode=1077 }
Assert-Equal 'Normal' (Get-WindowsUpdateInfrastructureState @($notStartedUpdateService) $true).State 'ExitCode 1077 must not turn an idle update service into a finding.'
Assert-Equal 'ConfirmedProblem' (Get-WindowsUpdateInfrastructureState @([pscustomobject]@{ Name='wuauserv'; State='Stopped'; StartMode='Disabled'; ExitCode=0 }) $true).State 'A disabled core update service must be explicit infrastructure damage.'
Assert-Equal 'ConfirmedProblem' (Get-WindowsUpdateInfrastructureState @() $true).State 'A missing core update service must be explicit infrastructure damage.'
Assert-Equal 'Indeterminate' (Get-WindowsUpdateInfrastructureState @() $false).State 'Unavailable service inventory must remain indeterminate.'

$pendingIndicators = @(
    [pscustomobject]@{ Name='PendingFileRenameOperations' },
    [pscustomobject]@{ Name='Windows Update Auto Update RebootRequired' }
)
$findingIndicators = @(Get-PendingRebootFindingIndicators $pendingIndicators)
Assert-Equal 1 $findingIndicators.Count 'Only an update-specific reboot indicator must create PENDING_REBOOT.'
Assert-Equal 'Windows Update Auto Update RebootRequired' $findingIndicators[0].Name 'The update-specific reboot indicator was not selected.'
Assert-Equal 0 @(Get-PendingRebootFindingIndicators @([pscustomobject]@{ Name='PendingFileRenameOperations' })).Count 'A generic pending file rename must remain context.'

$updateGuid = '11111111-2222-3333-4444-555555555555'
$installFailure = ConvertTo-WindowsUpdateFailure ([pscustomobject]@{
        ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=20; Version=1; LogName='System'; TimeCreated=$now.AddHours(-2)
        Properties=@(-2147024894, 'Fixture cumulative update', $updateGuid, 1); Message='fixture install failure'
    }) -IncludeMessage
Assert-Equal 'Installation' $installFailure.Kind 'Event 20 must be classified as an installation failure.'
Assert-Equal '0x80070002' $installFailure.ErrorCode 'A signed Windows Update error code must be normalized.'
Assert-Equal $updateGuid $installFailure.UpdateIdentifier 'Event 20 update identifier was not extracted.'

$downloadV0 = ConvertTo-WindowsUpdateFailure ([pscustomobject]@{
        ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=31; Version=0; LogName='Microsoft-Windows-WindowsUpdateClient/Operational'; TimeCreated=$now.AddHours(-1)
        Properties=@('0x80240017', $updateGuid, 7)
    })
Assert-Equal 'Download' $downloadV0.Kind 'Event 31 must be classified as a download failure.'
Assert-Equal 'Unknown update' $downloadV0.Title 'Event 31 version 0 has no title field.'
Assert-Equal '0x80240017' $downloadV0.ErrorCode 'Event 31 version 0 error code was not extracted.'
Assert-Equal $updateGuid $downloadV0.UpdateIdentifier 'Event 31 version 0 update identifier was not extracted.'

$downloadV1 = ConvertTo-WindowsUpdateFailure ([pscustomobject]@{
        ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=31; Version=1; LogName='Microsoft-Windows-WindowsUpdateClient/Operational'; TimeCreated=$now.AddMinutes(-30)
        Properties=@('Fixture feature update', '0x80240017', $updateGuid, 7)
    })
Assert-Equal 'Fixture feature update' $downloadV1.Title 'Event 31 version 1 title was not extracted.'
Assert-True ($null -eq (ConvertTo-WindowsUpdateFailure ([pscustomobject]@{ ProviderName='Fixture-Provider'; Id=20; LogName='System'; TimeCreated=$now }))) 'An Event 20 from another provider must remain context.'
Assert-True ($null -eq (ConvertTo-WindowsUpdateFailure ([pscustomobject]@{ ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=20; LogName='Microsoft-Windows-WindowsUpdateClient/Operational'; TimeCreated=$now }))) 'Event 20 outside its manifest-defined System channel must remain context.'
Assert-True ($null -eq (ConvertTo-WindowsUpdateFailure ([pscustomobject]@{ ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=31; LogName='System'; TimeCreated=$now }))) 'Event 31 outside its manifest-defined Operational channel must remain context.'

$repeatedFailure = $installFailure.PSObject.Copy()
$repeatedFailure.Timestamp = $now.AddHours(-1)
$oldFailure = $installFailure.PSObject.Copy()
$oldFailure.Timestamp = $now.AddDays(-40)
$failureGroups = @(Group-WindowsUpdateFailures @($installFailure, $repeatedFailure, $oldFailure, $downloadV1) $now.AddDays(-30))
Assert-Equal 2 $failureGroups.Count 'Different Windows Update failure types must remain separate and old failures must be excluded.'
$installGroup = @($failureGroups | Where-Object { $_.Kind -eq 'Installation' })[0]
Assert-Equal 2 $installGroup.Count 'Repeated Windows Update failures must be grouped.'

function script:Get-WinEvent {
    [CmdletBinding()]
    param([hashtable]$FilterHashtable)
    throw 'Fixture Windows Update event log unavailable.'
}
try {
    $unavailableUpdateLog = Read-WindowsUpdateEvents $now.AddDays(-30)
    Assert-Equal 2 @($unavailableUpdateLog.Errors).Count 'Both unavailable update logs must be retained as context.'
    Assert-Equal 0 @($unavailableUpdateLog.Failures).Count 'Unavailable update logs must not invent failures.'
}
finally {
    Remove-Item Function:\Get-WinEvent -ErrorAction SilentlyContinue
}

try {
    $updateModuleOutput = @(& {
            function Get-CimInstance {
                [CmdletBinding()]
                param([string]$ClassName)
                if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ Caption='Fixture Windows'; Version='10.0'; BuildNumber='1'; InstallDate=$null; LastBootUpTime=(Get-Date).AddHours(-2) } }
                return [pscustomobject]@{ Name='wuauserv'; DisplayName='Windows Update'; State='Stopped'; StartMode='Manual'; ExitCode=1077 }
            }
            function Get-HotFix { [CmdletBinding()] param(); return @() }
            function Test-Path {
                [CmdletBinding()]
                param([string]$LiteralPath)
                return $LiteralPath -like '*WindowsUpdate\Auto Update\RebootRequired'
            }
            function Get-ItemProperty { [CmdletBinding()] param([string]$LiteralPath); return [pscustomobject]@{} }
            function Get-WinEvent {
                [CmdletBinding()]
                param([hashtable]$FilterHashtable)
                if ($FilterHashtable.LogName -ne 'System') { return @() }
                return @(
                    [pscustomobject]@{
                        ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=20; Version=1; LogName='System'; TimeCreated=(Get-Date).AddMinutes(-20)
                        Properties=@(-2147024894, 'Fixture cumulative update', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 1); Message='fixture install failure one'
                    },
                    [pscustomobject]@{
                        ProviderName='Microsoft-Windows-WindowsUpdateClient'; Id=20; Version=1; LogName='System'; TimeCreated=(Get-Date).AddMinutes(-10)
                        Properties=@(-2147024894, 'Second fixture update', 'ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee', 1); Message='fixture install failure two'
                    }
                )
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $updatesScript -SinceDays 30 -MaxEvents 1 6>&1 | ForEach-Object { [string]$_ }
        })

    $partialUpdateAvailabilityOutput = @(& {
            function Get-CimInstance {
                [CmdletBinding()]
                param([string]$ClassName)
                if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ Caption='Fixture Windows'; Version='10.0'; BuildNumber='1'; InstallDate=$null; LastBootUpTime=(Get-Date).AddHours(-2) } }
                return [pscustomobject]@{ Name='wuauserv'; DisplayName='Windows Update'; State='Stopped'; StartMode='Manual'; ExitCode=0 }
            }
            function Get-HotFix { [CmdletBinding()] param(); return @() }
            function Test-Path { [CmdletBinding()] param([string]$LiteralPath); return $false }
            function Get-ItemProperty { [CmdletBinding()] param([string]$LiteralPath); return [pscustomobject]@{} }
            function Get-WinEvent {
                [CmdletBinding()]
                param([hashtable]$FilterHashtable)
                if ($FilterHashtable.LogName -eq 'System') { throw 'Fixture System update log unavailable.' }
                return @()
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $updatesScript -SinceDays 30 6>&1 | ForEach-Object { [string]$_ }
        })

    $updateAssessmentUnavailableOutput = @(& {
            function Get-CimInstance {
                [CmdletBinding()]
                param([string]$ClassName)
                if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ Caption='Fixture Windows'; Version='10.0'; BuildNumber='1'; InstallDate=$null; LastBootUpTime=(Get-Date).AddHours(-2) } }
                throw 'Fixture update service inventory unavailable.'
            }
            function Get-HotFix { [CmdletBinding()] param(); return @() }
            function Test-Path { [CmdletBinding()] param([string]$LiteralPath); throw 'Fixture reboot indicator unavailable.' }
            function Get-ItemProperty { [CmdletBinding()] param([string]$LiteralPath); throw 'Fixture pending rename unavailable.' }
            function Get-WinEvent { [CmdletBinding()] param([hashtable]$FilterHashtable); throw 'Fixture update event log unavailable.' }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $updatesScript -SinceDays 30 6>&1 | ForEach-Object { [string]$_ }
        })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}
$updateModuleText = $updateModuleOutput -join "`n"
Assert-True ($updateModuleText.Contains('WINDOWS_UPDATE_INSTALL_FAILURE')) 'A confirmed recent update failure must emit WARN.'
Assert-Equal 1 ([regex]::Matches($updateModuleText, 'WINDOWS_UPDATE_INSTALL_FAILURE').Count) 'Different installation failure groups must aggregate into one finding.'
Assert-True ($updateModuleText.Contains('Displayed groups  : 1')) 'MaxEvents must limit the detailed Windows Update group list.'
Assert-True ($updateModuleText.Contains('PENDING_REBOOT')) 'An update-specific reboot indicator must emit its own finding.'
Assert-True (-not $updateModuleText.Contains('WINDOWS_UPDATE_INFRASTRUCTURE_UNAVAILABLE')) 'Stopped Manual wuauserv with ExitCode 1077 must not emit WARN.'
$partialUpdateAvailabilityText = $partialUpdateAvailabilityOutput -join "`n"
Assert-True (-not $partialUpdateAvailabilityText.Contains('WINDOWS_UPDATE_ASSESSMENT_UNAVAILABLE')) 'One unavailable update channel with working source groups must remain context.'
Assert-True (-not $partialUpdateAvailabilityText.Contains('@@WDT_FINDING@@')) 'Partial Windows Update source availability must not emit a finding without a failure signal.'
$updateAssessmentUnavailableText = $updateAssessmentUnavailableOutput -join "`n"
Assert-Equal 1 ([regex]::Matches($updateAssessmentUnavailableText, '@@WDT_FINDING@@').Count) 'Complete Windows Update source-group loss must emit exactly one finding.'
Assert-Equal 1 ([regex]::Matches($updateAssessmentUnavailableText, 'WINDOWS_UPDATE_ASSESSMENT_UNAVAILABLE').Count) 'Complete Windows Update source-group loss must emit one assessment-level code.'
Assert-True ($updateAssessmentUnavailableText.Contains('assessment could not be completed')) 'Windows Update availability message must describe an incomplete assessment.'
Assert-True ($updateAssessmentUnavailableText.Contains('"Severity":"WARN"')) 'Windows Update assessment availability must emit WARN.'
Assert-True (-not ($updateAssessmentUnavailableText -match '"Severity":"ERROR"')) 'Windows Update availability must never create ERROR.'

# Service fixtures: idle and optional inventories remain context; only reviewed
# exit codes and the one curated critical-service rule create findings.
$servicesScript = Join-Path $repositoryRoot 'modules\services\diagnostic.ps1'
Import-TestFunctions $servicesScript @('Get-ServiceDiagnosticState')
Assert-Equal 'Indeterminate' (Get-ServiceDiagnosticState ([pscustomobject]@{ Name='Fixture'; StartMode='Auto'; State='Stopped'; ExitCode=0 })) 'Stopped automatic service must remain neutral.'
Assert-Equal 'Suspicious' (Get-ServiceDiagnosticState ([pscustomobject]@{ Name='Fixture'; StartMode='Auto'; State='Start Pending'; ExitCode=0 })) 'Pending state must remain suspicious context.'
Assert-Equal 'Normal' (Get-ServiceDiagnosticState ([pscustomobject]@{ Name='Fixture'; StartMode='Manual'; State='Stopped'; ExitCode=1077 })) 'ExitCode 1077 must remain normal context.'
Assert-Equal 'ConfirmedProblem' (Get-ServiceDiagnosticState ([pscustomobject]@{ Name='Fixture'; StartMode='Manual'; State='Stopped'; ExitCode=1066 })) 'An actionable non-zero ExitCode must be confirmed.'
Assert-Equal 'ConfirmedProblem' (Get-ServiceDiagnosticState ([pscustomobject]@{ Name='RpcSs'; StartMode='Disabled'; State='Stopped'; ExitCode=0 })) 'The curated disabled critical-service rule must be confirmed.'
Assert-Equal 'Normal' (Get-ServiceDiagnosticState ([pscustomobject]@{ Name='CustomRpcLikeName'; StartMode='Disabled'; State='Stopped'; ExitCode=0 })) 'An unknown custom service must not be judged by its name.'

try {
    $serviceModuleOutput = @(& {
            function Get-CimInstance {
                [CmdletBinding()]
                param([string]$ClassName)
                return [pscustomobject]@{ Name='FixtureService'; DisplayName='Fixture Service'; State='Stopped'; StartMode='Auto'; ExitCode=0; ProcessId=0 }
            }
            function Test-Path { [CmdletBinding()] param([string]$LiteralPath); return $true }
            function Get-ItemProperty { [CmdletBinding()] param([string]$LiteralPath); return [pscustomobject]@{ FixtureStartup='C:\Fixture\app.exe' } }
            function Get-Command { [CmdletBinding()] param([string]$Name); return [pscustomobject]@{ Name=$Name } }
            function Get-ScheduledTask { [CmdletBinding()] param(); return [pscustomobject]@{ TaskName='FixtureTask'; TaskPath='\'; State='Ready' } }
            function Get-ScheduledTaskInfo { [CmdletBinding()] param([string]$TaskName, [string]$TaskPath); return [pscustomobject]@{ LastRunTime=(Get-Date); LastTaskResult=1; NextRunTime=(Get-Date).AddDays(1) } }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $servicesScript -IncludeStartup -IncludeScheduledTasks 6>&1 | ForEach-Object { [string]$_ }
        })

    $serviceInventoryUnavailableOutput = @(& {
            function Get-CimInstance { [CmdletBinding()] param([string]$ClassName); throw 'Fixture Win32_Service inventory unavailable.' }
            function Test-Path { [CmdletBinding()] param([string]$LiteralPath); throw 'Fixture startup source unavailable.' }
            function Get-Command { [CmdletBinding()] param([string]$Name); return $null }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $servicesScript -IncludeStartup -IncludeScheduledTasks 6>&1 | ForEach-Object { [string]$_ }
        })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}
$serviceModuleText = $serviceModuleOutput -join "`n"
Assert-True (-not $serviceModuleText.Contains('@@WDT_FINDING@@')) 'Startup entries and scheduled task results without a confirmed service signal must not emit WARN.'
$serviceInventoryUnavailableText = $serviceInventoryUnavailableOutput -join "`n"
Assert-Equal 1 ([regex]::Matches($serviceInventoryUnavailableText, '@@WDT_FINDING@@').Count) 'Unavailable core service inventory must emit exactly one finding even when optional sources are unavailable.'
Assert-Equal 1 ([regex]::Matches($serviceInventoryUnavailableText, 'SERVICE_INVENTORY_UNAVAILABLE').Count) 'Unavailable Win32_Service inventory must emit the core availability code once.'
Assert-True (-not $serviceInventoryUnavailableText.Contains('STARTUP_SOURCE_UNAVAILABLE')) 'Unavailable startup inventory must remain context only.'
Assert-True (-not $serviceInventoryUnavailableText.Contains('SCHEDULED_TASK_SOURCE_UNAVAILABLE')) 'Unavailable scheduled-task inventory must remain context only.'
Assert-True ($serviceInventoryUnavailableText.Contains('assessment could not be completed')) 'Services availability message must describe an incomplete assessment.'
Assert-True ($serviceInventoryUnavailableText.Contains('"Severity":"WARN"')) 'Unavailable core service inventory must emit WARN.'
Assert-True (-not ($serviceInventoryUnavailableText -match '"Severity":"ERROR"')) 'Service inventory availability must never create ERROR.'

Import-TestFunctions (Join-Path $repositoryRoot 'modules\network\diagnostic.ps1') @('Get-NetworkReachabilityClassification','Test-TcpEndpointConnection')
Assert-Equal 'Reachable' (Get-NetworkReachabilityClassification $true 'Unavailable' 'Resolved: 1.2.3.4' 'Reachable' $true) 'Unavailable route inventory must not override working DNS/TCP.'
Assert-Equal 'Unreachable' (Get-NetworkReachabilityClassification $true 'Absent' 'Failed: fixture' 'Unreachable: fixture' $true) 'Confirmed absent route plus failed probes must be unreachable.'
Assert-Equal 'NotTested' (Get-NetworkReachabilityClassification $false 'Unavailable' 'NotTested' 'NotTested' $false) 'Disabled external tests must be explicit.'
Assert-True ((Test-TcpEndpointConnection 'not a uri').StartsWith('Indeterminate:')) 'Invalid endpoint must be indeterminate.'

Import-TestFunctions (Join-Path $repositoryRoot 'modules\performance\diagnostic.ps1') @('Get-ProcessCpuActivity')
$activity = @(Get-ProcessCpuActivity @([pscustomobject]@{Id=1;Name='old';CpuTime=10;StartTime=[datetime]'2024-01-01'}) @([pscustomobject]@{Id=1;Name='new';CpuTime=12;StartTime=[datetime]'2024-01-01'}) 1 4)
Assert-Equal 0 $activity.Count 'Same PID with a different process name must not match.'

Import-TestFunctions (Join-Path $repositoryRoot 'modules\disk\diagnostic.ps1') @('Get-StorageReliabilityData')
$storage = Get-StorageReliabilityData $null
Assert-Equal $false $storage.Available 'Missing reliability counters must be unavailable.'
Assert-True (-not ($storage.PSObject.Properties.Name -contains 'Error')) 'Unused storage Error field must not return.'
$storageSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'modules\disk\diagnostic.ps1') -Raw
Assert-True ($storageSource.Contains('Data availability:')) 'Storage availability wording is missing.'
Assert-True (-not $storageSource.Contains('Completeness: Partial')) 'Storage must not redefine execution completeness.'

Write-Host 'Diagnostic classification tests passed.'
