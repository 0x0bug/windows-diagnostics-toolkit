[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$SinceDays = 30,

    [ValidateRange(1, 500)]
    [int]$MaxEvents = 50,

    [switch]$IncludeEventLog
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\..\..\scripts\report-common.ps1

# Confirmed Windows Update failure and reboot semantics are intentionally kept
# narrow. Microsoft references:
# https://learn.microsoft.com/en-us/troubleshoot/windows-server/installing-updates-features-roles/troubleshoot-windows-server-update-guidance
# https://learn.microsoft.com/en-us/troubleshoot/windows-server/installing-updates-features-roles/troubleshoot-windows-update-error-0x80070002
# https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-isysteminformation-get_rebootrequired
# https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-service

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
        $sessionManager = Get-ItemProperty -LiteralPath $sessionManagerPath -ErrorAction Stop
        $hasPendingRenameProperty = $sessionManager.PSObject.Properties.Name -contains $sessionManagerValue
        $pendingRenameValues = if ($hasPendingRenameProperty) { @($sessionManager.$sessionManagerValue) } else { @() }
        $hasPendingRenameValue = @(
            $pendingRenameValues |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        ).Count -gt 0

        if ($hasPendingRenameValue) {
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

function Get-PendingRebootFindingIndicators {
    param([object[]]$Indicators)

    $findingIndicatorNames = @(
        'Component Based Servicing RebootPending',
        'Windows Update Auto Update RebootRequired'
    )

    return @(
        @($Indicators) |
            Where-Object { $findingIndicatorNames -contains [string]$_.Name }
    )
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

function Get-WindowsUpdateInfrastructureState {
    param(
        [object[]]$Services,
        [bool]$InventoryAvailable = $true
    )

    $result = [ordered]@{ State = 'Normal'; Reason = $null; Evidence = $null }
    if (-not $InventoryAvailable) {
        $result.State = 'Indeterminate'
        $result.Reason = 'InventoryUnavailable'
        return [pscustomobject]$result
    }

    $windowsUpdateService = @(
        @($Services) |
            Where-Object { [string]$_.Name -eq 'wuauserv' } |
            Select-Object -First 1
    )

    if ($windowsUpdateService.Count -eq 0) {
        $result.State = 'ConfirmedProblem'
        $result.Reason = 'Missing'
        $result.Evidence = 'wuauserv=Missing'
        return [pscustomobject]$result
    }

    $service = $windowsUpdateService[0]
    if ([string]$service.StartMode -eq 'Disabled') {
        $result.State = 'ConfirmedProblem'
        $result.Reason = 'Disabled'
        $result.Evidence = 'wuauserv={0} ({1})' -f $service.State, $service.StartMode
        return [pscustomobject]$result
    }

    $exitCode = 0L
    try {
        if ($null -ne $service.ExitCode) { $exitCode = [long]$service.ExitCode }
    }
    catch {
        $result.State = 'Indeterminate'
        $result.Reason = 'ExitCodeUnavailable'
        $result.Evidence = 'wuauserv ExitCode={0}' -f [string]$service.ExitCode
        return [pscustomobject]$result
    }

    # Win32_Service ExitCode 1077 means the service has not been started since boot.
    # It is normal for manual and trigger-start services and is not infrastructure damage.
    if ($exitCode -notin @(0, 1077)) {
        $result.State = 'ConfirmedProblem'
        $result.Reason = 'ExitCodeNonZero'
        $result.Evidence = 'wuauserv={0} ({1}), ExitCode={2}' -f $service.State, $service.StartMode, $exitCode
        return [pscustomobject]$result
    }

    $result.Evidence = 'wuauserv={0} ({1}), ExitCode={2}' -f $service.State, $service.StartMode, $exitCode
    return [pscustomobject]$result
}

function ConvertTo-WindowsUpdateFailure {
    param(
        [Parameter(Mandatory = $true)]$Event,
        [switch]$IncludeMessage
    )

    $providerName = [string]$Event.ProviderName
    if ($providerName -ne 'Microsoft-Windows-WindowsUpdateClient') {
        return $null
    }

    $eventIdValue = if ($null -ne $Event.Id) { $Event.Id } else { $Event.EventId }
    $eventId = $eventIdValue -as [int]
    if ($null -eq $eventId) {
        return $null
    }

    $logName = [string]$Event.LogName
    $operationalLog = 'Microsoft-Windows-WindowsUpdateClient/Operational'
    if ($eventId -eq 20) {
        if ($logName -ne 'System') {
            return $null
        }
        $kind = 'Installation'
    }
    elseif ($eventId -eq 31) {
        if ($logName -ne $operationalLog) {
            return $null
        }
        $kind = 'Download'
    }
    else {
        return $null
    }

    $timestampValue = if ($null -ne $Event.TimeCreated) { $Event.TimeCreated } else { $Event.Timestamp }
    if ($null -eq $timestampValue) {
        return $null
    }
    try { $timestamp = [datetime]$timestampValue }
    catch { return $null }

    $propertyValues = @(
        @($Event.Properties) | ForEach-Object {
            if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'Value') { $_.Value } else { $_ }
        }
    )
    $eventVersion = if ($null -ne $Event.PSObject.Properties['Version']) { $Event.Version -as [int] } else { $null }
    $downloadVersionZero = $eventId -eq 31 -and $eventVersion -eq 0
    $titleIndex = if ($eventId -eq 20) { 1 } elseif ($downloadVersionZero) { -1 } else { 0 }
    $errorIndex = if ($eventId -eq 20 -or $downloadVersionZero) { 0 } else { 1 }
    $identifierIndex = if ($downloadVersionZero) { 1 } else { 2 }
    $titleValue = if ($null -ne $Event.Title) { $Event.Title } elseif ($titleIndex -ge 0 -and $propertyValues.Count -gt $titleIndex) { $propertyValues[$titleIndex] } else { 'Unknown update' }
    $errorCodeValue = if ($null -ne $Event.ErrorCode) { $Event.ErrorCode } elseif ($propertyValues.Count -gt $errorIndex) { $propertyValues[$errorIndex] } else { 'Unknown' }
    $updateIdentifierValue = if ($null -ne $Event.UpdateIdentifier) { $Event.UpdateIdentifier } elseif ($propertyValues.Count -gt $identifierIndex) { $propertyValues[$identifierIndex] } else { $null }

    $errorCode = ([string]$errorCodeValue).Trim()
    $numericErrorCode = if ($errorCode -match '^-?\d+$') { $errorCode -as [long] } else { $null }
    if ($null -ne $numericErrorCode) {
        if ($numericErrorCode -lt 0) { $numericErrorCode += 0x100000000L }
        $errorCode = '0x{0:X8}' -f $numericErrorCode
    }
    elseif ($errorCode -match '^0[xX]') {
        $errorCode = '0x' + $errorCode.Substring(2).ToUpperInvariant()
    }
    if ([string]::IsNullOrWhiteSpace($errorCode)) { $errorCode = 'Unknown' }

    return [pscustomobject]@{
        Kind             = $kind
        Timestamp        = $timestamp
        EventSource      = $providerName
        EventId          = $eventId
        LogName          = $logName
        UpdateIdentifier = if ($null -eq $updateIdentifierValue) { $null } else { ([string]$updateIdentifierValue).Trim() }
        Title            = if ($null -eq $titleValue) { 'Unknown update' } else { ([string]$titleValue).Trim() }
        ErrorCode        = $errorCode
        Message          = if ($IncludeMessage) { [string]$Event.Message } else { $null }
    }
}

function Group-WindowsUpdateFailures {
    param(
        [object[]]$Failures,
        [Parameter(Mandatory = $true)][datetime]$Cutoff
    )

    $eligibleFailures = @(
        @($Failures) |
            Where-Object { $null -ne $_ -and [datetime]$_.Timestamp -ge $Cutoff }
    )

    if ($eligibleFailures.Count -eq 0) {
        return @()
    }

    $grouped = @(
        $eligibleFailures |
            Group-Object -Property {
                $identity = if (-not [string]::IsNullOrWhiteSpace([string]$_.UpdateIdentifier)) {
                    [string]$_.UpdateIdentifier
                }
                else {
                    [string]$_.Title
                }

                '{0}{4}{1}{4}{2}{4}{3}' -f ([string]$_.EventSource).ToLowerInvariant(), [int]$_.EventId, $identity.ToLowerInvariant(), ([string]$_.ErrorCode).ToLowerInvariant(), [char]0
            }
    )

    return @(
        foreach ($failureGroup in $grouped) {
            $ordered = @($failureGroup.Group | Sort-Object -Property Timestamp)
            $representative = $ordered[-1]
            [pscustomobject]@{
                Kind                  = $representative.Kind
                Timestamp             = $representative.Timestamp
                EventSource           = $representative.EventSource
                EventId               = $representative.EventId
                UpdateIdentifier      = $representative.UpdateIdentifier
                Title                 = $representative.Title
                ErrorCode             = $representative.ErrorCode
                Count                 = $ordered.Count
                FirstOccurrence       = $ordered[0].Timestamp
                LastOccurrence        = $ordered[-1].Timestamp
                RepresentativeMessage = $representative.Message
            }
        }
    ) | Sort-Object -Property LastOccurrence -Descending
}

function Read-WindowsUpdateEvents {
    param(
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [switch]$IncludeMessage
    )

    $providerName = 'Microsoft-Windows-WindowsUpdateClient'
    $operationalLog = 'Microsoft-Windows-WindowsUpdateClient/Operational'
    # The Microsoft provider manifest maps installation failure 20 to System
    # and download failure 31 to this Operational channel.
    $queries = @(
        [pscustomobject]@{
            LogName = 'System'
            EventIds = @(20)
        },
        [pscustomobject]@{
            LogName = $operationalLog
            EventIds = @(31)
        }
    )

    $failures = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    foreach ($query in $queries) {
        try {
            $filter = @{
                LogName      = $query.LogName
                ProviderName = $providerName
                Id           = $query.EventIds
                StartTime    = $StartTime
            }

            $candidateEvents = @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop)
            foreach ($event in $candidateEvents) {
                $failure = ConvertTo-WindowsUpdateFailure -Event $event -IncludeMessage:$IncludeMessage
                if ($null -ne $failure) {
                    $failures.Add($failure)
                }
            }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like '*NoMatchingEventsFound*') {
                continue
            }

            $errors.Add([pscustomobject]@{
                LogName = $query.LogName
                Error   = $_.Exception.Message
            })
        }
    }

    $sortedFailures = @(
        $failures.ToArray() |
            Sort-Object -Property Timestamp -Descending
    )

    return [pscustomobject]@{
        Logs          = @($queries | ForEach-Object { $_.LogName })
        Failures      = $sortedFailures
        TotalFailures = $failures.Count
        Errors        = @($errors.ToArray())
    }
}

Write-Host 'Windows Diagnostics Toolkit - Windows Update Check'
Write-Host 'Mode: read-only'

$cutoff = (Get-Date).AddDays(-1 * $SinceDays)
$windowsVersion = Get-WindowsVersionInfo
$pendingReboot = Test-PendingRebootIndicators
$recentUpdates = Get-RecentHotFixInventory -Cutoff $cutoff
$updateServices = Get-WindowsUpdateServices
$eventLogStatus = if ($IncludeEventLog) { 'Detection and representative details included' } else { 'Detection included; representative details omitted' }
$eventInventory = Read-WindowsUpdateEvents -StartTime $cutoff -IncludeMessage:$IncludeEventLog
$failureGroups = @(Group-WindowsUpdateFailures -Failures $eventInventory.Failures -Cutoff $cutoff)
$failureGroupsToShow = @($failureGroups | Select-Object -First $MaxEvents)
$pendingRebootFindingIndicators = @(Get-PendingRebootFindingIndicators -Indicators $pendingReboot.Indicators)
$infrastructureState = Get-WindowsUpdateInfrastructureState -Services $updateServices.Services -InventoryAvailable ($null -eq $updateServices.Error)

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
foreach ($errorItem in @($eventInventory.Errors)) {
    $unavailableSources.Add(('Event log/{0}: {1}' -f $errorItem.LogName, (ConvertTo-SafeSingleLine -Value $errorItem.Error)))
}

if ($pendingRebootFindingIndicators.Count -gt 0) {
    $pendingRebootEvidence = @($pendingRebootFindingIndicators | ForEach-Object { $_.Name }) -join '; '
    Write-WdtFinding -Severity WARN -Code 'PENDING_REBOOT' -Message 'Windows reports that a reboot is pending.' -Evidence $pendingRebootEvidence
}

if ($infrastructureState.State -eq 'ConfirmedProblem') {
    Write-WdtFinding -Severity WARN -Code 'WINDOWS_UPDATE_INFRASTRUCTURE_UNAVAILABLE' -Message 'The core Windows Update service is missing, disabled, or reports an actionable non-zero exit code.' -Evidence $infrastructureState.Evidence
}

foreach ($failureKind in @('Installation', 'Download')) {
    $kindGroups = @($failureGroups | Where-Object { $_.Kind -eq $failureKind })
    if ($kindGroups.Count -eq 0) {
        continue
    }

    $latestGroup = $kindGroups | Sort-Object -Property LastOccurrence -Descending | Select-Object -First 1
    $earliestGroup = $kindGroups | Sort-Object -Property FirstOccurrence | Select-Object -First 1
    $eventCount = ($kindGroups | Measure-Object -Property Count -Sum).Sum
    $updateLabel = if (-not [string]::IsNullOrWhiteSpace([string]$latestGroup.UpdateIdentifier)) {
        [string]$latestGroup.UpdateIdentifier
    }
    else {
        [string]$latestGroup.Title
    }

    $evidenceParts = New-Object System.Collections.Generic.List[string]
    $evidenceParts.Add(('Timestamp={0:o}' -f $latestGroup.Timestamp))
    $evidenceParts.Add(('Source={0}' -f $latestGroup.EventSource))
    $evidenceParts.Add(('EventId={0}' -f $latestGroup.EventId))
    $evidenceParts.Add(('Update={0}' -f (ConvertTo-SafeSingleLine -Value $updateLabel)))
    $evidenceParts.Add(('Title={0}' -f (ConvertTo-SafeSingleLine -Value $latestGroup.Title)))
    $evidenceParts.Add(('ErrorCode={0}' -f $latestGroup.ErrorCode))
    $evidenceParts.Add(('Groups={0}' -f $kindGroups.Count))
    $evidenceParts.Add(('Count={0}' -f $eventCount))
    $evidenceParts.Add(('First={0:o}' -f $earliestGroup.FirstOccurrence))
    $evidenceParts.Add(('Last={0:o}' -f $latestGroup.LastOccurrence))
    if ($IncludeEventLog -and -not [string]::IsNullOrWhiteSpace([string]$latestGroup.RepresentativeMessage)) {
        $evidenceParts.Add(('Message={0}' -f (ConvertTo-SafeSingleLine -Value $latestGroup.RepresentativeMessage)))
    }

    $findingCode = if ($failureKind -eq 'Download') { 'WINDOWS_UPDATE_DOWNLOAD_FAILURE' } else { 'WINDOWS_UPDATE_INSTALL_FAILURE' }
    $failureDescription = if ($failureKind -eq 'Download') { 'download' } else { 'installation' }
    Write-WdtFinding -Severity WARN -Code $findingCode -Message ('Windows Update reported confirmed {0} failures in {1} group(s).' -f $failureDescription, $kindGroups.Count) -Evidence (@($evidenceParts.ToArray()) -join '; ')
}

Write-Section 'Summary'
Write-Host ('Time window         : Last {0} day(s)' -f $SinceDays)
Write-Host ('Pending reboot     : {0}' -f $pendingReboot.Status)
Write-Host ('Confirmed failures : {0} group(s), {1} event(s)' -f $failureGroups.Count, $eventInventory.TotalFailures)
if ($null -eq $recentUpdates.Error) {
    Write-Host ('Recent updates     : {0}' -f $recentUpdates.Updates.Count)
}
else {
    Write-Host ('Recent updates     : Unknown')
}
Write-Host ('Event log check    : {0}' -f $eventLogStatus)
Write-Host ('Unavailable sources: {0} (context only)' -f $unavailableSources.Count)
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
        $indicatorRole = if (@($pendingRebootFindingIndicators | Where-Object { $_.Name -eq $indicator.Name }).Count -gt 0) { 'Finding' } else { 'Context only' }
        Write-Host ('- {0}: {1} [{2}]' -f $indicator.Name, $indicator.Source, $indicatorRole)
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
    Write-Host ('Unavailable (context only): {0}' -f $updateServices.Error)
}
else {
    Write-Host ('Core infrastructure state: {0}' -f $infrastructureState.State)
    Write-Host 'A stopped update-related service is context only; Windows can start services on demand or by trigger.'
    Write-Host ''

    if ($updateServices.Services.Count -eq 0) {
        Write-Host 'No target Windows Update related services found.'
    }
    else {
        foreach ($service in $updateServices.Services) {
            Write-Host ('Name       : {0}' -f $service.Name)
            Write-Host ('DisplayName: {0}' -f $service.DisplayName)
            Write-Host ('State      : {0}' -f $service.State)
            Write-Host ('StartMode  : {0}' -f $service.StartMode)
            Write-Host ('ExitCode   : {0}' -f $service.ExitCode)
            Write-Host ''
        }
    }

    foreach ($missingService in @($updateServices.Missing)) {
        Write-Host ('Missing service: {0}' -f $missingService)
    }
}

Write-Section 'Confirmed Windows Update Failures'
Write-Host ('Logs checked      : {0}' -f ($eventInventory.Logs -join ', '))
Write-Host ('Failure events    : {0}' -f $eventInventory.TotalFailures)
Write-Host ('Failure groups    : {0}' -f $failureGroups.Count)
Write-Host ('Displayed groups  : {0}' -f $failureGroupsToShow.Count)
Write-Host ('Representative text: {0}' -f $(if ($IncludeEventLog) { 'Included' } else { 'Omitted; use -IncludeEventLog' }))

foreach ($errorItem in @($eventInventory.Errors)) {
    Write-Host ('Unavailable source (context only): {0} - {1}' -f $errorItem.LogName, $errorItem.Error)
}

if ($failureGroupsToShow.Count -eq 0) {
    Write-Host 'No confirmed Windows Update installation or download failures were found in the selected time window.'
}
else {
    foreach ($failureGroup in $failureGroupsToShow) {
        Write-Host ('Timestamp       : {0}' -f $failureGroup.Timestamp)
        Write-Host ('EventSource     : {0}' -f $failureGroup.EventSource)
        Write-Host ('EventId         : {0}' -f $failureGroup.EventId)
        Write-Host ('FailureType     : {0}' -f $failureGroup.Kind)
        Write-Host ('UpdateIdentifier: {0}' -f $(if ([string]::IsNullOrWhiteSpace([string]$failureGroup.UpdateIdentifier)) { 'Unknown' } else { $failureGroup.UpdateIdentifier }))
        Write-Host ('Title           : {0}' -f $failureGroup.Title)
        Write-Host ('ErrorCode       : {0}' -f $failureGroup.ErrorCode)
        Write-Host ('Count           : {0}' -f $failureGroup.Count)
        Write-Host ('FirstOccurrence : {0}' -f $failureGroup.FirstOccurrence)
        Write-Host ('LastOccurrence  : {0}' -f $failureGroup.LastOccurrence)
        if ($IncludeEventLog) {
            Write-Host ('Message         : {0}' -f (ConvertTo-SafeSingleLine -Value $failureGroup.RepresentativeMessage))
        }
        Write-Host ''
    }
}

if ($failureGroups.Count -gt $failureGroupsToShow.Count) {
    Write-Host ('Showing {0} of {1} confirmed failure group(s).' -f $failureGroupsToShow.Count, $failureGroups.Count)
}
