[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$SinceDays = 7,

    [ValidateRange(1, 500)]
    [int]$MaxEvents = 50,

    [ValidateRange(1, 100)]
    [int]$MaxDumpFiles = 20
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\report-common.ps1

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)

    Write-Host ''
    Write-Host "== $Title =="
}

function Format-Bytes {
    param([Nullable[double]]$Bytes)

    if ($null -eq $Bytes) {
        return 'Unknown'
    }

    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $value = [double]$Bytes
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }

    return ('{0:N2} {1}' -f $value, $units[$index])
}

function Read-CrashEvents {
    param(
        [Parameter(Mandatory = $true)][string]$LogName,
        [Parameter(Mandatory = $true)][int[]]$Ids,
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    try {
        return [pscustomobject]@{
            Events = @(Get-WinEvent -FilterHashtable @{
                    LogName   = $LogName
                    Id        = $Ids
                    StartTime = $StartTime
                } -MaxEvents $Limit -ErrorAction Stop)
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

function Get-DumpMetadata {
    param(
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    $dumps = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $systemRoot = [string]$env:SystemRoot
    $localAppData = [string]$env:LOCALAPPDATA

    $directories = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
        $directories.Add([pscustomobject]@{
                Path   = Join-Path -Path $systemRoot -ChildPath 'Minidump'
                Source = 'System Minidump'
            })
    }
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $directories.Add([pscustomobject]@{
                Path   = Join-Path -Path $localAppData -ChildPath 'CrashDumps'
                Source = 'User CrashDumps'
            })
    }

    foreach ($directory in $directories) {
        if (-not (Test-Path -LiteralPath $directory.Path -PathType Container)) {
            continue
        }

        try {
            foreach ($item in @(Get-ChildItem -LiteralPath $directory.Path -Filter '*.dmp' -File -ErrorAction Stop)) {
                if ($item.LastWriteTime -lt $StartTime) {
                    continue
                }

                $dumps.Add([pscustomobject]@{
                        Name          = $item.Name
                        LastWriteTime = $item.LastWriteTime
                        Size          = $item.Length
                        Source        = $directory.Source
                    })
            }
        }
        catch {
            $errors.Add(('{0}: {1}' -f $directory.Source, $_.Exception.Message))
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
        $memoryDump = Join-Path -Path $systemRoot -ChildPath 'MEMORY.DMP'
        if (Test-Path -LiteralPath $memoryDump -PathType Leaf) {
            try {
                $item = Get-Item -LiteralPath $memoryDump -ErrorAction Stop
                if ($item.LastWriteTime -ge $StartTime) {
                    $dumps.Add([pscustomobject]@{
                            Name          = $item.Name
                            LastWriteTime = $item.LastWriteTime
                            Size          = $item.Length
                            Source        = 'System MEMORY.DMP'
                        })
                }
            }
            catch {
                $errors.Add(('System MEMORY.DMP: {0}' -f $_.Exception.Message))
            }
        }
    }

    return [pscustomobject]@{
        Dumps  = @($dumps | Sort-Object -Property LastWriteTime -Descending | Select-Object -First $Limit)
        Errors = @($errors.ToArray())
    }
}

function Get-ApplicationEventKind {
    param([Parameter(Mandatory = $true)][int]$Id)

    switch ($Id) {
        1000 { return 'Application Error' }
        1001 { return 'Windows Error Reporting' }
        1002 { return 'Application Hang' }
        default { return 'Application Event' }
    }
}

Write-Host 'Windows Diagnostics Toolkit - Crash and Hang Diagnostics'
Write-Host 'Mode: read-only'

$startTime = (Get-Date).AddDays(-1 * $SinceDays)
$applicationEvents = Read-CrashEvents -LogName 'Application' -Ids @(1000, 1001, 1002) -StartTime $startTime -Limit $MaxEvents
$systemEvents = Read-CrashEvents -LogName 'System' -Ids @(1001) -StartTime $startTime -Limit $MaxEvents
$dumpMetadata = Get-DumpMetadata -StartTime $startTime -Limit $MaxDumpFiles

$allEvents = New-Object System.Collections.Generic.List[object]
foreach ($event in $applicationEvents.Events) {
    $allEvents.Add([pscustomobject]@{
            TimeCreated = $event.TimeCreated
            LogName     = $event.LogName
            Id          = $event.Id
            Provider    = $event.ProviderName
            Kind        = Get-ApplicationEventKind -Id $event.Id
        })
}
foreach ($event in $systemEvents.Events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting' -or $_.ProviderName -like '*BugCheck*' }) {
    $allEvents.Add([pscustomobject]@{
            TimeCreated = $event.TimeCreated
            LogName     = $event.LogName
            Id          = $event.Id
            Provider    = $event.ProviderName
            Kind        = 'BugCheck'
        })
}
$displayedEvents = @($allEvents | Sort-Object -Property TimeCreated -Descending | Select-Object -First $MaxEvents)
$displayedApplicationEvents = @($displayedEvents | Where-Object { $_.Kind -ne 'BugCheck' })
$displayedBugCheckEvents = @($displayedEvents | Where-Object { $_.Kind -eq 'BugCheck' })

Write-Section 'Summary'
Write-Host ('Time window       : Last {0} day(s)' -f $SinceDays)
Write-Host ('Event limit       : {0}' -f $MaxEvents)
Write-Host ('Dump metadata limit: {0}' -f $MaxDumpFiles)
Write-Host ('Application events: {0}' -f $displayedApplicationEvents.Count)
Write-Host ('BugCheck events   : {0}' -f $displayedBugCheckEvents.Count)
Write-Host ('Recent dump files : {0}' -f $dumpMetadata.Dumps.Count)

Write-Section 'Application Crash and Hang Events'
if ($null -ne $applicationEvents.Error) {
    Write-Host ('Unavailable: {0}' -f $applicationEvents.Error)
    Write-WdtFinding -Severity WARN -Code 'CRASH_APPLICATION_EVENTS_UNAVAILABLE' -Message 'Application crash and hang events are unavailable.' -Evidence $applicationEvents.Error
}
elseif ($displayedApplicationEvents.Count -eq 0) {
    Write-Host 'No matching application crash or hang events were found.'
}
else {
    foreach ($event in $displayedApplicationEvents) {
        Write-Host ('TimeCreated : {0}' -f $event.TimeCreated)
        Write-Host ('Kind        : {0}' -f $event.Kind)
        Write-Host ('LogName     : {0}' -f $event.LogName)
        Write-Host ('Id          : {0}' -f $event.Id)
        Write-Host ('Provider    : {0}' -f $event.Provider)
        Write-Host ''
    }
    Write-WdtFinding -Severity WARN -Code 'CRASH_APPLICATION_FAILURES_DETECTED' -Message 'Recent application crash or hang events were found.' -Evidence ('Count={0}' -f $displayedApplicationEvents.Count)
}

Write-Section 'BugCheck Events'
if ($null -ne $systemEvents.Error) {
    Write-Host ('Unavailable: {0}' -f $systemEvents.Error)
    Write-WdtFinding -Severity WARN -Code 'CRASH_BUGCHECK_EVENTS_UNAVAILABLE' -Message 'System BugCheck events are unavailable.' -Evidence $systemEvents.Error
}
elseif ($displayedBugCheckEvents.Count -eq 0) {
    Write-Host 'No matching BugCheck events were found.'
}
else {
    foreach ($event in $displayedBugCheckEvents) {
        Write-Host ('TimeCreated : {0}' -f $event.TimeCreated)
        Write-Host ('LogName     : {0}' -f $event.LogName)
        Write-Host ('Id          : {0}' -f $event.Id)
        Write-Host ('Provider    : {0}' -f $event.Provider)
        Write-Host ''
    }
    Write-WdtFinding -Severity ERROR -Code 'CRASH_BUGCHECK_DETECTED' -Message 'Recent Windows BugCheck events were found.' -Evidence ('Count={0}' -f $displayedBugCheckEvents.Count)
}

Write-Section 'Recent Dump Metadata'
if ($dumpMetadata.Errors.Count -gt 0) {
    foreach ($errorItem in $dumpMetadata.Errors) {
        Write-Host ('Unavailable: {0}' -f $errorItem)
    }
    Write-WdtFinding -Severity WARN -Code 'CRASH_DUMP_METADATA_UNAVAILABLE' -Message 'One or more dump metadata sources are unavailable.' -Evidence ($dumpMetadata.Errors -join '; ')
}
if ($dumpMetadata.Dumps.Count -eq 0) {
    Write-Host 'No recent dump files were found.'
}
else {
    foreach ($dump in $dumpMetadata.Dumps) {
        Write-Host ('Name          : {0}' -f $dump.Name)
        Write-Host ('LastWriteTime : {0}' -f $dump.LastWriteTime)
        Write-Host ('Size          : {0}' -f (Format-Bytes -Bytes $dump.Size))
        Write-Host ('Source        : {0}' -f $dump.Source)
        Write-Host ''
    }
    Write-WdtFinding -Severity WARN -Code 'CRASH_RECENT_DUMPS_FOUND' -Message 'Recent crash dump files were found.' -Evidence ('Count={0}' -f $dumpMetadata.Dumps.Count)
}
