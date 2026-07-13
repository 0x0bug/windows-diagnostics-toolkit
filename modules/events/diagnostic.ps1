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

$events = @(
    $logResults |
        ForEach-Object { $_.Events } |
        Sort-Object -Property TimeCreated -Descending
)

$recentEvents = @($events | Select-Object -First $MaxEvents)
$sourceGroups = @(
    $events |
        Group-Object -Property ProviderName |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Ascending = $true } |
        Select-Object -First 10
)

$unavailableLogs = @($logResults | Where-Object { $null -ne $_.Error })
if ($unavailableLogs.Count -gt 0) {
    $unavailableLogEvidence = @(
        $unavailableLogs |
            ForEach-Object { '{0}: {1}' -f $_.LogName, (ConvertTo-OneLineMessage -Message $_.Error) }
    ) -join '; '

    Write-WdtFinding -Severity WARN -Code 'EVENT_LOG_SOURCE_UNAVAILABLE' -Message ('{0} event log source(s) could not be read.' -f $unavailableLogs.Count) -Evidence $unavailableLogEvidence
}

$criticalEvents = @($events | Where-Object { $_.Level -eq 1 })
if ($criticalEvents.Count -gt 0) {
    $criticalEventEvidence = @(
        $criticalEvents |
            Select-Object -First 5 |
            ForEach-Object { '{0}/{1}/{2}' -f $_.LogName, $_.ProviderName, $_.Id }
    ) -join '; '

    Write-WdtFinding -Severity ERROR -Code 'RECENT_CRITICAL_EVENTS' -Message ('{0} Critical event(s) were found in the last {1} hour(s).' -f $criticalEvents.Count, $SinceHours) -Evidence $criticalEventEvidence
}

$errorEvents = @($events | Where-Object { $_.Level -eq 2 })
if ($errorEvents.Count -gt 0) {
    $errorEventEvidence = @(
        $errorEvents |
            Select-Object -First 5 |
            ForEach-Object { '{0}/{1}/{2}' -f $_.LogName, $_.ProviderName, $_.Id }
    ) -join '; '

    Write-WdtFinding -Severity WARN -Code 'RECENT_ERROR_EVENTS' -Message ('{0} Error event(s) were found in the last {1} hour(s).' -f $errorEvents.Count, $SinceHours) -Evidence $errorEventEvidence
}

Write-Section 'Summary'
Write-Host ('Time window     : Last {0} hour(s), since {1}' -f $SinceHours, $startTime)
Write-Host ('Logs checked    : {0}' -f ($logs -join ', '))
Write-Host ('Levels included : {0}' -f ($levelNames -join ', '))
Write-Host ('Total events    : {0}' -f $events.Count)
Write-Host ('Displayed events: {0}' -f $recentEvents.Count)

foreach ($result in $logResults) {
    if ($null -eq $result.Error) {
        Write-Host ('{0,-15}: {1} event(s)' -f $result.LogName, $result.Events.Count)
    }
    else {
        Write-Host ('{0,-15}: unavailable - {1}' -f $result.LogName, $result.Error)
    }
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
if ($recentEvents.Count -eq 0) {
    Write-Host 'No matching events found.'
}
else {
    foreach ($event in $recentEvents) {
        Write-Host ('TimeCreated    : {0}' -f $event.TimeCreated)
        Write-Host ('LogName        : {0}' -f $event.LogName)
        Write-Host ('Level          : {0}' -f $event.LevelDisplayName)
        Write-Host ('Id             : {0}' -f $event.Id)
        Write-Host ('ProviderName   : {0}' -f $event.ProviderName)
        Write-Host ('Message        : {0}' -f (ConvertTo-OneLineMessage -Message $event.Message))
        Write-Host ''
    }
}
