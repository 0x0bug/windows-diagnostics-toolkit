[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$SinceDays = 30,

    [ValidateRange(1, 500)]
    [int]$MaxEvents = 50,

    [switch]$IncludeEventLog
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\report-common.ps1

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Write-Host ''
    Write-Host "== $Title =="
}

function ConvertTo-SafeSingleLine {
    param(
        [string]$Value,
        [int]$MaxLength = 240
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'No message'
    }

    $singleLine = (($Value -replace '\s+', ' ').Trim())
    if ($singleLine.Length -le $MaxLength) {
        return $singleLine
    }

    return ($singleLine.Substring(0, $MaxLength - 3) + '...')
}

function ConvertTo-DisplayDate {
    param($Value)

    if ($null -eq $Value) {
        return 'Unknown'
    }

    if ($Value -is [datetime]) {
        return $Value
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'Unknown'
    }

    return $text
}

function ConvertTo-DateTimeOrNull {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [datetime]) {
        return $Value
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return [datetime]$text
    }
    catch {
        return $null
    }
}

function Get-WindowsVersionInfo {
    try {
        return [pscustomobject]@{
            OperatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            Error           = $null
        }
    }
    catch {
        return [pscustomobject]@{
            OperatingSystem = $null
            Error           = $_.Exception.Message
        }
    }
}

function Get-RecentHotFixInventory {
    param([Parameter(Mandatory = $true)][datetime]$Cutoff)

    try {
        $updates = New-Object System.Collections.Generic.List[object]
        $unparseableCount = 0

        foreach ($hotFix in @(Get-HotFix -ErrorAction Stop)) {
            $installedOn = ConvertTo-DateTimeOrNull -Value $hotFix.InstalledOn
            if ($null -eq $installedOn) {
                $unparseableCount++
                continue
            }

            if ($installedOn -ge $Cutoff) {
                $updates.Add([pscustomobject]@{
                    HotFixID          = $hotFix.HotFixID
                    Description       = $hotFix.Description
                    InstalledOn       = $installedOn
                    InstalledOnSource = $hotFix.InstalledOn
                    InstalledBy       = $hotFix.InstalledBy
                })
            }
        }

        return [pscustomobject]@{
            Updates          = @($updates.ToArray())
            UnparseableCount = $unparseableCount
            Error            = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Updates          = @()
            UnparseableCount = 0
            Error            = $_.Exception.Message
        }
    }
}

function Test-PendingRebootIndicators {
    $indicators = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    $keyChecks = @(
        [pscustomobject]@{
            Name = 'Component Based Servicing RebootPending'
            Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        },
        [pscustomobject]@{
            Name = 'Windows Update Auto Update RebootRequired'
            Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        }
    )

    foreach ($check in $keyChecks) {
        try {
            if (Test-Path -LiteralPath $check.Path) {
                $indicators.Add([pscustomobject]@{
                    Name   = $check.Name
                    Source = $check.Path
                })
            }
        }
        catch {
            $errors.Add([pscustomobject]@{
                Name   = $check.Name
                Source = $check.Path
                Error  = $_.Exception.Message
            })
        }
    }

    $sessionManagerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $sessionManagerValue = 'PendingFileRenameOperations'

    try {
        $sessionManager = Get-ItemProperty -LiteralPath $sessionManagerPath -Name $sessionManagerValue -ErrorAction SilentlyContinue
        if ($null -ne $sessionManager -and $null -ne $sessionManager.$sessionManagerValue) {
            $indicators.Add([pscustomobject]@{
                Name   = $sessionManagerValue
                Source = ('{0}\{1}' -f $sessionManagerPath, $sessionManagerValue)
            })
        }
    }
    catch {
        $errors.Add([pscustomobject]@{
            Name   = $sessionManagerValue
            Source = ('{0}\{1}' -f $sessionManagerPath, $sessionManagerValue)
            Error  = $_.Exception.Message
        })
    }

    $status = 'No'
    if ($indicators.Count -gt 0) {
        $status = 'Yes'
    }
    elseif ($errors.Count -gt 0) {
        $status = 'Unknown'
    }

    return [pscustomobject]@{
        Status     = $status
        Indicators = @($indicators.ToArray())
        Errors     = @($errors.ToArray())
    }
}

function Get-WindowsUpdateServices {
    $targetServiceNames = @('wuauserv', 'bits', 'cryptsvc', 'trustedinstaller', 'usosvc')

    try {
        $services = @(
            Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
                Where-Object { $targetServiceNames -contains $_.Name } |
                Sort-Object -Property Name
        )

        $foundNames = @($services | ForEach-Object { $_.Name })
        $missingNames = @($targetServiceNames | Where-Object { $foundNames -notcontains $_ })

        return [pscustomobject]@{
            Services = $services
            Missing  = $missingNames
            Error    = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Services = @()
            Missing  = @()
            Error    = $_.Exception.Message
        }
    }
}

function Read-WindowsUpdateEvents {
    param(
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][int]$EventLimit
    )

    $logs = @('System', 'Application')
    $keywords = @(
        'WindowsUpdateClient',
        'Windows Update Agent',
        'Microsoft-Windows-WindowsUpdateClient',
        'Servicing',
        'CBS',
        'DISM'
    )

    $events = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    foreach ($log in $logs) {
        try {
            $filter = @{
                LogName   = $log
                StartTime = $StartTime
            }

            $candidateEvents = @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop)
            foreach ($event in $candidateEvents) {
                $providerName = [string]$event.ProviderName
                $message = [string]$event.Message
                $matchesKeyword = $false

                foreach ($keyword in $keywords) {
                    if ($providerName -like ('*' + $keyword + '*') -or $message -like ('*' + $keyword + '*')) {
                        $matchesKeyword = $true
                        break
                    }
                }

                if ($matchesKeyword) {
                    $events.Add($event)
                }
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like '*NoMatchingEventsFound*') {
                continue
            }

            $errors.Add([pscustomobject]@{
                LogName = $log
                Error   = $_.Exception.Message
            })
        }
    }

    $sortedEvents = @(
        $events.ToArray() |
            Sort-Object -Property TimeCreated -Descending |
            Select-Object -First $EventLimit
    )

    return [pscustomobject]@{
        Logs        = $logs
        Events      = $sortedEvents
        TotalEvents = $events.Count
        Errors      = @($errors.ToArray())
    }
}

Write-Host 'Windows Diagnostics Toolkit - Windows Update Check'
Write-Host 'Mode: read-only'

$cutoff = (Get-Date).AddDays(-1 * $SinceDays)
$windowsVersion = Get-WindowsVersionInfo
$pendingReboot = Test-PendingRebootIndicators
$recentUpdates = Get-RecentHotFixInventory -Cutoff $cutoff
$updateServices = Get-WindowsUpdateServices
$eventLogStatus = if ($IncludeEventLog) { 'Included' } else { 'Skipped' }
$eventInventory = $null

if ($IncludeEventLog) {
    $eventInventory = Read-WindowsUpdateEvents -StartTime $cutoff -EventLimit $MaxEvents
}

$unavailableSources = New-Object System.Collections.Generic.List[string]
if ($null -ne $windowsVersion.Error) {
    $unavailableSources.Add(('Windows version: {0}' -f (ConvertTo-SafeSingleLine -Value $windowsVersion.Error)))
}
if ($null -ne $recentUpdates.Error) {
    $unavailableSources.Add(('Installed updates: {0}' -f (ConvertTo-SafeSingleLine -Value $recentUpdates.Error)))
}
foreach ($errorItem in @($pendingReboot.Errors)) {
    $unavailableSources.Add(('Pending reboot/{0}: {1}' -f $errorItem.Name, (ConvertTo-SafeSingleLine -Value $errorItem.Error)))
}
if ($null -ne $updateServices.Error) {
    $unavailableSources.Add(('Update services: {0}' -f (ConvertTo-SafeSingleLine -Value $updateServices.Error)))
}
if ($IncludeEventLog) {
    foreach ($errorItem in @($eventInventory.Errors)) {
        $unavailableSources.Add(('Event log/{0}: {1}' -f $errorItem.LogName, (ConvertTo-SafeSingleLine -Value $errorItem.Error)))
    }
}

if ($unavailableSources.Count -gt 0) {
    Write-WdtFinding -Severity WARN -Code 'WINDOWS_UPDATE_SOURCE_UNAVAILABLE' -Message ('{0} Windows Update diagnostic source(s) could not be read.' -f $unavailableSources.Count) -Evidence (@($unavailableSources.ToArray()) -join '; ')
}

if ($pendingReboot.Status -eq 'Yes') {
    $pendingRebootEvidence = @($pendingReboot.Indicators | ForEach-Object { $_.Name }) -join '; '
    Write-WdtFinding -Severity WARN -Code 'PENDING_REBOOT' -Message 'Windows reports that a reboot is pending.' -Evidence $pendingRebootEvidence
}

if ($null -eq $updateServices.Error) {
    $problematicUpdateServices = @(
        $updateServices.Services |
            Where-Object {
                ($_.StartMode -eq 'Auto' -and $_.State -ne 'Running') -or
                $_.State -notin @('Running', 'Stopped')
            }
    )

    if ($problematicUpdateServices.Count -gt 0 -or $updateServices.Missing.Count -gt 0) {
        $updateServiceEvidence = New-Object System.Collections.Generic.List[string]
        foreach ($service in @($problematicUpdateServices | Select-Object -First 10)) {
            $updateServiceEvidence.Add(('{0}={1} ({2})' -f $service.Name, $service.State, $service.StartMode))
        }
        foreach ($missingService in @($updateServices.Missing | Select-Object -First 10)) {
            $updateServiceEvidence.Add(('{0}=Missing' -f $missingService))
        }

        Write-WdtFinding -Severity WARN -Code 'WINDOWS_UPDATE_SERVICE_ISSUES' -Message ('{0} Windows Update service(s) have a problematic state and {1} expected service(s) are missing.' -f $problematicUpdateServices.Count, $updateServices.Missing.Count) -Evidence (@($updateServiceEvidence.ToArray()) -join '; ')
    }
}

if ($IncludeEventLog) {
    $problematicUpdateEvents = @(
        $eventInventory.Events |
            Where-Object {
                $_.Level -in @(1, 2) -or
                $_.LevelDisplayName -in @('Critical', 'Error')
            }
    )

    if ($problematicUpdateEvents.Count -gt 0) {
        $updateEventEvidence = @(
            $problematicUpdateEvents |
                Select-Object -First 5 |
                ForEach-Object { '{0}/{1}/{2}' -f $_.LogName, $_.ProviderName, $_.Id }
        ) -join '; '

        Write-WdtFinding -Severity WARN -Code 'WINDOWS_UPDATE_EVENT_ISSUES' -Message ('{0} recent Windows Update Critical or Error event(s) were found.' -f $problematicUpdateEvents.Count) -Evidence $updateEventEvidence
    }
}

Write-Section 'Summary'
Write-Host ('Time window         : Last {0} day(s)' -f $SinceDays)
Write-Host ('Pending reboot     : {0}' -f $pendingReboot.Status)
if ($null -eq $recentUpdates.Error) {
    Write-Host ('Recent updates     : {0}' -f $recentUpdates.Updates.Count)
}
else {
    Write-Host ('Recent updates     : Unknown')
}
Write-Host ('Event log check    : {0}' -f $eventLogStatus)
if ($null -eq $updateServices.Error) {
    Write-Host ('Services checked   : {0}' -f $updateServices.Services.Count)
}
else {
    Write-Host 'Services checked   : Unknown'
}

Write-Section 'Windows Version'
if ($null -ne $windowsVersion.Error) {
    Write-Host ('Unavailable: {0}' -f $windowsVersion.Error)
}
else {
    $os = $windowsVersion.OperatingSystem
    Write-Host ('Caption       : {0}' -f $os.Caption)
    Write-Host ('Version       : {0}' -f $os.Version)
    Write-Host ('BuildNumber   : {0}' -f $os.BuildNumber)
    if ($null -ne $os.InstallDate) {
        Write-Host ('InstallDate   : {0}' -f (ConvertTo-DisplayDate -Value $os.InstallDate))
    }
    Write-Host ('LastBootUpTime: {0}' -f (ConvertTo-DisplayDate -Value $os.LastBootUpTime))
}

Write-Section 'Pending Reboot'
Write-Host ('Pending reboot: {0}' -f $pendingReboot.Status)

if ($pendingReboot.Indicators.Count -eq 0) {
    Write-Host 'Indicators found: None'
}
else {
    Write-Host 'Indicators found:'
    foreach ($indicator in $pendingReboot.Indicators) {
        Write-Host ('- {0}: {1}' -f $indicator.Name, $indicator.Source)
    }
}

if ($pendingReboot.Errors.Count -gt 0) {
    Write-Host 'Unavailable indicators:'
    foreach ($errorItem in $pendingReboot.Errors) {
        Write-Host ('- {0}: {1}' -f $errorItem.Name, $errorItem.Error)
    }
}

Write-Section 'Recent Installed Updates'
if ($null -ne $recentUpdates.Error) {
    Write-Host ('Unavailable: {0}' -f $recentUpdates.Error)
}
else {
    $updatesToShow = @(
        $recentUpdates.Updates |
            Sort-Object -Property InstalledOn -Descending |
            Select-Object -First 50
    )

    if ($recentUpdates.Updates.Count -gt $updatesToShow.Count) {
        Write-Host ('Showing {0} of {1} update(s).' -f $updatesToShow.Count, $recentUpdates.Updates.Count)
        Write-Host ''
    }

    if ($updatesToShow.Count -eq 0) {
        Write-Host 'No installed updates found in the selected time window.'
    }
    else {
        foreach ($update in $updatesToShow) {
            Write-Host ('HotFixID   : {0}' -f $update.HotFixID)
            Write-Host ('Description: {0}' -f $update.Description)
            Write-Host ('InstalledOn: {0}' -f (ConvertTo-DisplayDate -Value $update.InstalledOnSource))
            Write-Host ('InstalledBy: {0}' -f $update.InstalledBy)
            Write-Host ''
        }
    }

    if ($recentUpdates.UnparseableCount -gt 0) {
        Write-Host ('InstalledOn values not parsed: {0}' -f $recentUpdates.UnparseableCount)
    }
}

Write-Section 'Windows Update Services'
if ($null -ne $updateServices.Error) {
    Write-Host ('Unavailable: {0}' -f $updateServices.Error)
}
else {
    if ($updateServices.Services.Count -eq 0) {
        Write-Host 'No target Windows Update related services found.'
    }
    else {
        foreach ($service in $updateServices.Services) {
            Write-Host ('Name       : {0}' -f $service.Name)
            Write-Host ('DisplayName: {0}' -f $service.DisplayName)
            Write-Host ('State      : {0}' -f $service.State)
            Write-Host ('StartMode  : {0}' -f $service.StartMode)
            Write-Host ''
        }
    }

    foreach ($missingService in @($updateServices.Missing)) {
        Write-Host ('Missing service: {0}' -f $missingService)
    }
}

Write-Section 'Windows Update Events'
if (-not $IncludeEventLog) {
    Write-Host 'Skipped. Use -IncludeEventLog to include recent Windows Update related events.'
}
else {
    Write-Host ('Logs checked    : {0}' -f ($eventInventory.Logs -join ', '))
    Write-Host ('Total events    : {0}' -f $eventInventory.TotalEvents)
    Write-Host ('Displayed events: {0}' -f $eventInventory.Events.Count)

    foreach ($errorItem in @($eventInventory.Errors)) {
        Write-Warning ('Windows Update event log unavailable: {0} - {1}' -f $errorItem.LogName, $errorItem.Error)
    }

    if ($eventInventory.Events.Count -eq 0) {
        Write-Host 'No matching Windows Update related events found.'
    }
    else {
        foreach ($event in $eventInventory.Events) {
            Write-Host ('TimeCreated    : {0}' -f $event.TimeCreated)
            Write-Host ('LogName        : {0}' -f $event.LogName)
            Write-Host ('Level          : {0}' -f $event.LevelDisplayName)
            Write-Host ('Id             : {0}' -f $event.Id)
            Write-Host ('ProviderName   : {0}' -f $event.ProviderName)
            Write-Host ('Message        : {0}' -f (ConvertTo-SafeSingleLine -Value $event.Message))
            Write-Host ''
        }
    }
}
