[CmdletBinding()]
param(
    [ValidateRange(1, 720)]
    [int]$SinceHours = 24,

    [switch]$IncludeWarnings,

    [ValidateRange(1, 500)]
    [int]$MaxEvents = 50
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\..\..\scripts\report-common.ps1

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Write-Host ''
    Write-Host "== $Title =="
}

function ConvertTo-OneLineMessage {
    param(
        [string]$Message,
        [int]$MaxLength = 240
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return 'No message'
    }

    $singleLine = (($Message -replace '\s+', ' ').Trim())

    if ($singleLine.Length -le $MaxLength) {
        return $singleLine
    }

    return ($singleLine.Substring(0, $MaxLength - 3) + '...')
}

function Get-EventSignalRule {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$LogName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ProviderName,
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][int]$Level
    )

    # Microsoft documents Event ID 41 as an unexpected restart without a clean shutdown.
    # https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/event-id-41-restart
    if (
        $LogName -ieq 'System' -and
        $ProviderName -ieq 'Microsoft-Windows-Kernel-Power' -and
        $Id -eq 41 -and
        $Level -eq 1
    ) {
        return [pscustomobject][ordered]@{
            Severity = 'WARN'
            Code     = 'EVENT_UNEXPECTED_SHUTDOWN'
            Message  = 'Windows recorded an unexpected shutdown or restart.'
        }
    }

    # Microsoft documents NTFS Event ID 55 as a corrupt and unusable file-system structure.
    # https://learn.microsoft.com/en-us/services-hub/unified/health/remediation-steps-ad/investigate-a-serious-error-in-the-disk-subsystem
    if (
        $LogName -ieq 'System' -and
        $ProviderName -iin @('Ntfs', 'Microsoft-Windows-Ntfs') -and
        $Id -eq 55 -and
        $Level -eq 2
    ) {
        return [pscustomobject][ordered]@{
            Severity = 'WARN'
            Code     = 'EVENT_FILE_SYSTEM_CORRUPTION'
            Message  = 'Windows recorded an NTFS file-system corruption event.'
        }
    }

    return $null
}

function Group-EventLogEvents {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events,
        [Parameter(Mandatory = $true)][datetime]$Cutoff
    )

    $eventsInWindow = @(
        foreach ($event in @($Events)) {
            if ($null -eq $event -or $null -eq $event.TimeCreated) {
                continue
            }

            if ([datetime]$event.TimeCreated -lt $Cutoff) {
                continue
            }

            $event
        }
    )

    $rawGroups = @($eventsInWindow | Group-Object -Property ProviderName, Id, Level)
    foreach ($rawGroup in $rawGroups) {
        $orderedEvents = @($rawGroup.Group | Sort-Object -Property TimeCreated)
        if ($orderedEvents.Count -eq 0) {
            continue
        }

        $representativeEvent = $orderedEvents[$orderedEvents.Count - 1]
        $providerName = [string]$representativeEvent.ProviderName
        $eventId = [int]$representativeEvent.Id
        $level = [int]$representativeEvent.Level
        $levelDisplayName = [string]$representativeEvent.LevelDisplayName
        if ([string]::IsNullOrWhiteSpace($levelDisplayName)) {
            $levelDisplayName = [string]$level
        }

        $representativeMessage = [string]$representativeEvent.Message
        if ([string]::IsNullOrWhiteSpace($representativeMessage)) {
            $representativeMessage = 'No message'
        }
        else {
            $representativeMessage = (($representativeMessage -replace '\s+', ' ').Trim())
            if ($representativeMessage.Length -gt 240) {
                $representativeMessage = $representativeMessage.Substring(0, 237) + '...'
            }
        }

        $logNames = @(
            $orderedEvents |
                ForEach-Object { [string]$_.LogName } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )

        $signalRule = $null
        foreach ($logName in $logNames) {
            $signalRule = Get-EventSignalRule -LogName $logName -ProviderName $providerName -Id $eventId -Level $level
            if ($null -ne $signalRule) {
                break
            }
        }

        [pscustomobject][ordered]@{
            ProviderName          = $providerName
            Id                    = $eventId
            Level                 = $level
            LevelDisplayName      = $levelDisplayName
            Count                 = $orderedEvents.Count
            FirstOccurrence       = [datetime]$orderedEvents[0].TimeCreated
            LastOccurrence        = [datetime]$representativeEvent.TimeCreated
            RepresentativeMessage = $representativeMessage
            LogNames              = @($logNames)
            IsSignal              = ($null -ne $signalRule)
            SignalSeverity        = if ($null -eq $signalRule) { $null } else { $signalRule.Severity }
            SignalCode            = if ($null -eq $signalRule) { $null } else { $signalRule.Code }
            SignalMessage         = if ($null -eq $signalRule) { $null } else { $signalRule.Message }
        }
    }
}

function Read-EventLog {
    param(
        [Parameter(Mandatory = $true)][string]$LogName,
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][int[]]$Levels,
        [Parameter(Mandatory = $true)][int]$EventLimit
    )

    try {
        $filter = @{
            LogName   = $LogName
            Level     = $Levels
            StartTime = $StartTime
        }

        return [pscustomobject]@{
            LogName = $LogName
            Events  = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $EventLimit -ErrorAction Stop)
            Error   = $null
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like '*NoMatchingEventsFound*') {
            return [pscustomobject]@{
                LogName = $LogName
                Events  = @()
                Error   = $null
            }
        }

        return [pscustomobject]@{
            LogName = $LogName
            Events  = @()
            Error   = $_.Exception.Message
        }
    }
}

function Read-HighSignalEvents {
    param([Parameter(Mandatory = $true)][datetime]$Cutoff)

    try {
        $candidateEvents = @(
            Get-WinEvent -FilterHashtable @{
                LogName   = 'System'
                Id        = @(41, 55)
                StartTime = $Cutoff
            } -ErrorAction Stop
        )

        $signalEvents = @(
            $candidateEvents |
                Where-Object {
                    $null -ne (Get-EventSignalRule -LogName ([string]$_.LogName) -ProviderName ([string]$_.ProviderName) -Id ([int]$_.Id) -Level ([int]$_.Level))
                }
        )

        return [pscustomobject]@{
            Events = $signalEvents
            Error  = $null
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like '*NoMatchingEventsFound*') {
            return [pscustomobject]@{
                Events = @()
                Error  = $null
            }
        }

        return [pscustomobject]@{
            Events = @()
            Error  = $_.Exception.Message
        }
    }
}

Write-Host 'Windows Diagnostics Toolkit - Event Log Check'
Write-Host 'Mode: read-only'

$startTime = (Get-Date).AddHours(-1 * $SinceHours)
$levels = @(1, 2)
$levelNames = @('Critical', 'Error')

if ($IncludeWarnings) {
    $levels += 3
    $levelNames += 'Warning'
}

$logs = @('System', 'Application')
$logResults = foreach ($log in $logs) {
    Read-EventLog -LogName $log -StartTime $startTime -Levels $levels -EventLimit $MaxEvents
}
$signalResult = Read-HighSignalEvents -Cutoff $startTime

$contextEvents = @(
    $logResults |
        ForEach-Object { $_.Events }
)

$events = New-Object System.Collections.Generic.List[object]
$seenEvents = @{}
$eventKeySeparator = [string][char]0
foreach ($event in @($contextEvents + @($signalResult.Events))) {
    $recordId = [string]$event.RecordId
    if (-not [string]::IsNullOrWhiteSpace($recordId)) {
        $eventKey = (@('Record', [string]$event.LogName, $recordId) -join $eventKeySeparator)
    }
    else {
        $eventTime = if ($null -eq $event.TimeCreated) { '' } else { ([datetime]$event.TimeCreated).ToString('o') }
        $eventKey = @(
            'Value',
            [string]$event.LogName,
            [string]$event.ProviderName,
            [string]$event.Id,
            [string]$event.Level,
            $eventTime,
            [string]$event.Message
        ) -join $eventKeySeparator
    }

    if ($seenEvents.ContainsKey($eventKey)) {
        continue
    }

    $seenEvents[$eventKey] = $true
    $events.Add($event)
}

$groupSort = @(
    @{ Expression = { if ($_.IsSignal) { 0 } else { 1 } }; Ascending = $true },
    @{ Expression = { $_.LastOccurrence }; Descending = $true },
    @{ Expression = { $_.Count }; Descending = $true },
    @{ Expression = { $_.ProviderName }; Ascending = $true },
    @{ Expression = { $_.Id }; Ascending = $true }
)
$eventGroups = @(
    Group-EventLogEvents -Events @($events.ToArray()) -Cutoff $startTime |
        Sort-Object -Property $groupSort
)
$displayedGroups = @($eventGroups | Select-Object -First $MaxEvents)
$totalEventCount = 0
foreach ($group in $eventGroups) {
    $totalEventCount += $group.Count
}

$sourceGroups = @(
    $events.ToArray() |
        Group-Object -Property ProviderName |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Ascending = $true } |
        Select-Object -First 10
)

$unavailableLogs = @($logResults | Where-Object { $null -ne $_.Error })
$dataAvailability = if ($unavailableLogs.Count -eq 0 -and $null -eq $signalResult.Error) {
    'Available'
}
elseif ($unavailableLogs.Count -eq $logs.Count -and $null -ne $signalResult.Error) {
    'Unavailable'
}
else {
    'Partial'
}

foreach ($group in @($eventGroups | Where-Object { $_.IsSignal })) {
    $findingEvidence = 'Count={0}; First={1:o}; Last={2:o}; Provider={3}; Id={4}; Level={5}; Logs={6}' -f
        $group.Count,
        $group.FirstOccurrence,
        $group.LastOccurrence,
        $group.ProviderName,
        $group.Id,
        $group.Level,
        ($group.LogNames -join ', ')

    Write-WdtFinding -Severity $group.SignalSeverity -Code $group.SignalCode -Message $group.SignalMessage -Evidence $findingEvidence
}

Write-Section 'Summary'
Write-Host ('Time window     : Last {0} hour(s), since {1}' -f $SinceHours, $startTime)
Write-Host ('Logs checked    : {0}' -f ($logs -join ', '))
Write-Host ('Levels included : {0}' -f ($levelNames -join ', '))
Write-Host ('Data availability: {0}' -f $dataAvailability)
Write-Host ('Total events    : {0}' -f $totalEventCount)
Write-Host ('Event groups    : {0}' -f $eventGroups.Count)
Write-Host ('Displayed groups: {0}' -f $displayedGroups.Count)

foreach ($result in $logResults) {
    if ($null -eq $result.Error) {
        Write-Host ('{0,-15}: {1} context event(s)' -f $result.LogName, $result.Events.Count)
    }
    else {
        Write-Host ('{0,-15}: unavailable - {1}' -f $result.LogName, (ConvertTo-OneLineMessage -Message $result.Error))
    }
}

if ($null -eq $signalResult.Error) {
    Write-Host ('High-signal query: {0} event(s)' -f $signalResult.Events.Count)
}
else {
    Write-Host ('High-signal query: unavailable - {0}' -f (ConvertTo-OneLineMessage -Message $signalResult.Error))
}

Write-Section 'Top Sources'
if ($sourceGroups.Count -eq 0) {
    Write-Host 'No matching event sources found.'
}
else {
    foreach ($group in $sourceGroups) {
        $providerName = if ([string]::IsNullOrWhiteSpace($group.Name)) { 'Unknown' } else { $group.Name }
        Write-Host ('{0,-50} {1,5}' -f $providerName, $group.Count)
    }
}

Write-Section 'Recent Events'
if ($displayedGroups.Count -eq 0) {
    Write-Host 'No matching events found.'
}
else {
    foreach ($group in $displayedGroups) {
        Write-Host ('ProviderName          : {0}' -f $group.ProviderName)
        Write-Host ('Id                    : {0}' -f $group.Id)
        Write-Host ('Level                 : {0}' -f $group.LevelDisplayName)
        Write-Host ('LogNames              : {0}' -f ($group.LogNames -join ', '))
        Write-Host ('Count                 : {0}' -f $group.Count)
        Write-Host ('First occurrence      : {0}' -f $group.FirstOccurrence)
        Write-Host ('Last occurrence       : {0}' -f $group.LastOccurrence)
        Write-Host ('Representative message: {0}' -f $group.RepresentativeMessage)
        if ($group.IsSignal) {
            Write-Host ('Signal                : {0}' -f $group.SignalCode)
        }
        Write-Host ''
    }
}
