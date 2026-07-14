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

. $PSScriptRoot\..\..\scripts\report-common.ps1

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
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][datetime]$EndTime,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    try {
        return [pscustomobject]@{
            Records = @(Get-WinEvent -FilterHashtable @{
                    LogName      = $LogName
                    ProviderName = $ProviderName
                    Id           = $Id
                    StartTime    = $StartTime
                    EndTime      = $EndTime
                } -MaxEvents $Limit -ErrorAction Stop)
            Error   = $null
        }
    }
    catch {
        if ($_.FullyQualifiedErrorId -like '*NoMatchingEventsFound*') {
            return [pscustomobject]@{ Records = @(); Error = $null }
        }
        return [pscustomobject]@{ Records = @(); Error = $_.Exception.Message }
    }
}

function Read-ReliabilityRecords {
    param(
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][datetime]$EndTime,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    try {
        $startUtc = ([datetimeoffset]$StartTime).UtcDateTime
        $endUtc = ([datetimeoffset]$EndTime).UtcDateTime
        $dmtfStart = $startUtc.ToString('yyyyMMddHHmmss.ffffff+000', [Globalization.CultureInfo]::InvariantCulture)
        $records = @(Get-CimInstance -Namespace 'root\cimv2' -ClassName 'Win32_ReliabilityRecords' -Filter ("TimeGenerated >= '{0}'" -f $dmtfStart) -ErrorAction Stop |
                Where-Object {
                    $source = [string]$_.SourceName
                    $id = [int]$_.EventIdentifier
                    $time = [datetime]$_.TimeGenerated
                    $time = if ($time.Kind -eq [DateTimeKind]::Unspecified) {
                        ([datetimeoffset]($time.ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + 'Z')).UtcDateTime
                    }
                    else { ([datetimeoffset]$time).UtcDateTime }
                    $known = ($source -eq 'Application Error' -and $id -eq 1000) -or
                        ($source -eq 'Windows Error Reporting' -and $id -eq 1001) -or
                        ($source -eq 'Application Hang' -and $id -eq 1002) -or
                        ($source -eq 'Microsoft-Windows-WER-SystemErrorReporting' -and $id -eq 1001)
                    $known -and $time -ge $startUtc -and $time -le $endUtc
                } |
                Sort-Object -Property TimeGenerated -Descending |
                Select-Object -First ($Limit * 4))
        return [pscustomobject]@{ Records = $records; Error = $null }
    }
    catch {
        return [pscustomobject]@{ Records = @(); Error = $_.Exception.Message }
    }
}

function Get-DumpMetadata {
    param(
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    $dumps = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $directories = @(
        if (-not [string]::IsNullOrWhiteSpace([string]$env:SystemRoot)) {
            [pscustomobject]@{ Path = Join-Path $env:SystemRoot 'Minidump'; Source = 'System Minidump' }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) {
            [pscustomobject]@{ Path = Join-Path $env:LOCALAPPDATA 'CrashDumps'; Source = 'User CrashDumps' }
        }
    )

    foreach ($directory in $directories) {
        if (-not (Test-Path -LiteralPath $directory.Path -PathType Container)) {
            continue
        }
        try {
            foreach ($item in @(Get-ChildItem -LiteralPath $directory.Path -Filter '*.dmp' -File -ErrorAction Stop)) {
                if ($item.LastWriteTime -ge $StartTime) {
                    [void]$dumps.Add([pscustomobject]@{
                            Name = $item.Name; LastWriteTime = $item.LastWriteTime
                            Size = $item.Length; Source = $directory.Source
                        })
                }
            }
        }
        catch {
            [void]$errors.Add(('{0}: {1}' -f $directory.Source, $_.Exception.Message))
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$env:SystemRoot)) {
        $memoryDump = Join-Path $env:SystemRoot 'MEMORY.DMP'
        if (Test-Path -LiteralPath $memoryDump -PathType Leaf) {
            try {
                $item = Get-Item -LiteralPath $memoryDump -ErrorAction Stop
                if ($item.LastWriteTime -ge $StartTime) {
                    [void]$dumps.Add([pscustomobject]@{
                            Name = $item.Name; LastWriteTime = $item.LastWriteTime
                            Size = $item.Length; Source = 'System MEMORY.DMP'
                        })
                }
            }
            catch {
                [void]$errors.Add(('System MEMORY.DMP: {0}' -f $_.Exception.Message))
            }
        }
    }

    return [pscustomobject]@{
        Dumps = @($dumps | Sort-Object LastWriteTime -Descending | Select-Object -First $Limit)
        Errors = @($errors.ToArray())
    }
}

function ConvertTo-CrashRecord {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [ValidateSet('Auto', 'EventLog', 'Reliability')][string]$Origin = 'Auto'
    )

    $provider = if ($null -ne $InputObject.PSObject.Properties['ProviderName']) { [string]$InputObject.ProviderName }
    elseif ($null -ne $InputObject.PSObject.Properties['SourceName']) { [string]$InputObject.SourceName }
    else { '' }
    $id = if ($null -ne $InputObject.PSObject.Properties['Id']) { [int]$InputObject.Id }
    elseif ($null -ne $InputObject.PSObject.Properties['EventIdentifier']) { [int]$InputObject.EventIdentifier }
    else { 0 }
    if ($Origin -eq 'Auto') {
        $Origin = if ($null -ne $InputObject.PSObject.Properties['SourceName']) { 'Reliability' } else { 'EventLog' }
    }

    $values = @()
    if ($null -ne $InputObject.PSObject.Properties['Properties']) {
        foreach ($property in @($InputObject.Properties)) {
            if ($null -ne $property) {
                $values += if ($null -ne $property.PSObject.Properties['Value']) { [string]$property.Value } else { [string]$property }
            }
        }
    }
    if ($null -ne $InputObject.PSObject.Properties['InsertionStrings']) {
        $values += @($InputObject.InsertionStrings | ForEach-Object { [string]$_ })
    }
    $message = ''
    if ($null -ne $InputObject.PSObject.Properties['Message']) {
        try { $message = [string]$InputObject.Message } catch { $message = '' }
    }
    $werText = (@($message) + $values) -join "`n"

    $kind = if ($null -ne $InputObject.PSObject.Properties['Kind']) { [string]$InputObject.Kind } else { '' }
    if ($kind -notin @('Crash', 'Hang', 'BugCheck')) {
        if ($provider -eq 'Application Error' -and $id -eq 1000) { $kind = 'Crash' }
        elseif ($provider -eq 'Application Hang' -and $id -eq 1002) { $kind = 'Hang' }
        elseif ($provider -eq 'Microsoft-Windows-WER-SystemErrorReporting' -and $id -eq 1001) { $kind = 'BugCheck' }
        elseif ($provider -eq 'Windows Error Reporting' -and $id -eq 1001) {
            if ($werText -match '(?i)\bAppHang[A-Z0-9_]*\b') { $kind = 'Hang' }
            elseif ($werText -match '(?i)\b(?:BlueScreen|BugCheck)\b') { $kind = 'BugCheck' }
            elseif ($werText -match '(?i)\b(?:APPCRASH|MoAppCrash|BEX64|BEX|CLR20r3)\b') { $kind = 'Crash' }
        }
    }
    if ($kind -notin @('Crash', 'Hang', 'BugCheck')) {
        return $null
    }

    $timeValue = if ($null -ne $InputObject.PSObject.Properties['TimeCreated']) { $InputObject.TimeCreated } else { $InputObject.TimeGenerated }
    try { $time = [datetime]$timeValue } catch { return $null }
    $time = if ($Origin -eq 'Reliability' -and $time.Kind -eq [DateTimeKind]::Unspecified) {
        ([datetimeoffset]($time.ToString('yyyy-MM-ddTHH:mm:ss.fffffff') + 'Z')).UtcDateTime
    }
    else { ([datetimeoffset]$time).UtcDateTime }

    $component = if ($null -ne $InputObject.PSObject.Properties['Component']) { [string]$InputObject.Component } else { '' }
    if ([string]::IsNullOrWhiteSpace($component)) {
        if ($kind -eq 'BugCheck') { $component = 'Windows' }
        elseif ($provider -in @('Application Error', 'Application Hang') -and $values.Count -gt 0) { $component = $values[0] }
        elseif ($provider -eq 'Windows Error Reporting' -and $values.Count -gt 5) { $component = $values[5] }
        elseif ($null -ne $InputObject.PSObject.Properties['ProductName']) { $component = [string]$InputObject.ProductName }
    }
    if ([string]::IsNullOrWhiteSpace($component) -and $message -match '(?im)Faulting application name:\s*(?<App>[^,\r\n]+)') {
        $component = $matches['App']
    }
    if ($component -match '[\\/]') {
        $leaf = Split-Path -LiteralPath $component -Leaf
        if (-not [string]::IsNullOrWhiteSpace($leaf)) { $component = $leaf }
    }
    $component = (($component -replace '[\r\n]+', ' ') -replace '\s{2,}', ' ').Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($component)) { $component = if ($kind -eq 'BugCheck') { 'Windows' } else { 'Unknown application' } }
    if ($component.Length -gt 120) { $component = $component.Substring(0, 120) }

    $failure = if ($null -ne $InputObject.PSObject.Properties['FailureCode']) { [string]$InputObject.FailureCode } else { '' }
    if ([string]::IsNullOrWhiteSpace($failure)) {
        if ($kind -eq 'Crash') {
            if ($provider -eq 'Application Error' -and $values.Count -gt 6) { $failure = $values[6] }
            elseif ($provider -eq 'Windows Error Reporting' -and $values.Count -gt 11) { $failure = $values[11] }
            elseif ($message -match '(?im)Exception code:\s*(?<Code>0x[0-9a-f]+|[0-9a-f]{8})') { $failure = $matches['Code'] }
        }
        elseif ($kind -eq 'Hang') {
            if ($message -match '(?im)Hang type:\s*(?<Code>[^\r\n]+)') { $failure = $matches['Code'] }
            elseif ($provider -eq 'Application Hang' -and $values.Count -gt 9) { $failure = $values[9] }
            elseif ($werText -match '(?i)\b(?<Code>AppHang[A-Z0-9_]*)\b') { $failure = $matches['Code'] }
        }
        elseif ($message -match '(?i)bugcheck (?:was|code(?: is)?)[:\s]+(?<Code>0x[0-9a-f]+)') { $failure = $matches['Code'] }
        elseif ($provider -eq 'Microsoft-Windows-WER-SystemErrorReporting' -and $values.Count -gt 0) { $failure = $values[0] }
        elseif ($provider -eq 'Windows Error Reporting' -and $values.Count -gt 5) { $failure = $values[5] }
    }
    $failure = (($failure -replace '[\r\n]+', ' ') -replace '\s{2,}', ' ').Trim()
    if ($failure -match '(?i)0x[0-9a-f]{1,16}') { $failure = $matches[0].ToLowerInvariant() }
    elseif ($kind -eq 'BugCheck' -and $failure -match '(?i)^[0-9a-f]{1,8}$') { $failure = '0x' + $failure.ToLowerInvariant() }
    elseif ($kind -eq 'Crash' -and $failure -match '(?i)^[0-9a-f]{8}$') { $failure = '0x' + $failure.ToLowerInvariant() }
    elseif ([string]::IsNullOrWhiteSpace($failure) -or $failure -match '[\\/]') { $failure = 'Unknown' }
    if ($failure.Length -gt 80) { $failure = $failure.Substring(0, 80) }

    $reportId = if ($null -ne $InputObject.PSObject.Properties['ReportId']) { [string]$InputObject.ReportId } else { '' }
    if ([string]::IsNullOrWhiteSpace($reportId) -and $message -match '(?im)Report Id:\s*(?<Id>[0-9a-f-]{36})') { $reportId = $matches['Id'] }
    if ([string]::IsNullOrWhiteSpace($reportId)) {
        $reportIndex = if ($provider -eq 'Application Error') { 12 } elseif ($provider -eq 'Application Hang') { 6 } elseif ($provider -eq 'Microsoft-Windows-WER-SystemErrorReporting') { 2 } else { -1 }
        if ($reportIndex -ge 0 -and $values.Count -gt $reportIndex) { $reportId = $values[$reportIndex] }
    }
    if ([string]::IsNullOrWhiteSpace($reportId)) {
        foreach ($value in $values) {
            $guid = [guid]::Empty
            if ([System.Guid]::TryParse([string]$value, [ref]$guid)) { $reportId = $guid.ToString('D'); break }
        }
    }
    $reportId = $reportId.Trim().Trim('{').Trim('}').ToLowerInvariant()

    $source = if ($null -ne $InputObject.PSObject.Properties['Source'] -and -not [string]::IsNullOrWhiteSpace([string]$InputObject.Source)) {
        ([string]$InputObject.Source).Trim()
    }
    elseif ($Origin -eq 'Reliability') { 'Reliability Monitor/{0}' -f $provider }
    else { 'Event Log/{0}' -f $provider }
    $evidence = if ($null -ne $InputObject.PSObject.Properties['Evidence'] -and -not [string]::IsNullOrWhiteSpace([string]$InputObject.Evidence)) {
        (([string]$InputObject.Evidence -replace '[\r\n]+', ' ') -replace '\s{2,}', ' ').Trim()
    }
    else { 'Source={0}; Id={1}; Component={2}; Kind={3}; FailureCode={4}' -f $source, $id, $component, $kind, $failure }
    if ($evidence.Length -gt 240) { $evidence = $evidence.Substring(0, 240) }

    return [pscustomobject][ordered]@{
        TimeCreated = $time; Component = $component; Kind = $kind; FailureCode = $failure
        ReportId = $reportId; Source = $source; Evidence = $evidence
    }
}

function Merge-DuplicateCrashRecords {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records,
        [datetime]$Cutoff = [datetime]::MinValue
    )

    $Cutoff = ([datetimeoffset]$Cutoff).UtcDateTime
    $bucketTicks = ([timespan]'00:05:00').Ticks
    $merged = @{}

    foreach ($record in @($Records | Sort-Object TimeCreated, Source)) {
        $time = [datetime]$record.TimeCreated
        $time = ([datetimeoffset]$time).UtcDateTime
        if ($time -lt $Cutoff -or [string]$record.Kind -notin @('Crash', 'Hang', 'BugCheck')) { continue }

        $component = if ([string]::IsNullOrWhiteSpace([string]$record.Component)) { 'Unknown application' } else { [string]$record.Component }
        $reportId = ([string]$record.ReportId).Trim().ToLowerInvariant()
        $failure = if ([string]::IsNullOrWhiteSpace([string]$record.FailureCode)) { 'Unknown' } else { [string]$record.FailureCode }
        $key = if (-not [string]::IsNullOrWhiteSpace($reportId)) { 'report|' + $reportId }
        else {
            $bucket = [long][math]::Floor($time.Ticks / [double]$bucketTicks)
            'incident|{0}|{1}|{2}|{3}' -f $component.ToLowerInvariant(), ([string]$record.Kind).ToLowerInvariant(), $failure.ToLowerInvariant(), $bucket
        }

        $recordSources = if ($null -ne $record.PSObject.Properties['Sources']) { @($record.Sources) } else { @($record.Source) }
        if (-not $merged.ContainsKey($key)) {
            $sources = @($recordSources | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
            $merged[$key] = [pscustomobject][ordered]@{
                TimeCreated = $time; Component = $component; Kind = [string]$record.Kind; FailureCode = $failure
                ReportId = $reportId; Source = $sources -join ', '; Sources = $sources
                Evidence = [string]$record.Evidence; DedupKey = $key
            }
            continue
        }

        $existing = $merged[$key]
        $sources = @(@($existing.Sources) + $recordSources | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        $existing.Sources = $sources
        $existing.Source = $sources -join ', '
        if ($existing.FailureCode -eq 'Unknown' -and $failure -ne 'Unknown') { $existing.FailureCode = $failure }
        if ($existing.Component -eq 'Unknown application' -and $component -ne 'Unknown application') { $existing.Component = $component }
        if ($time -ge $existing.TimeCreated) {
            $existing.TimeCreated = $time
            if (-not [string]::IsNullOrWhiteSpace([string]$record.Evidence)) { $existing.Evidence = [string]$record.Evidence }
        }
    }

    return @($merged.Values | Sort-Object TimeCreated -Descending)
}

function Group-CrashRecords {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records)

    $groups = @{}
    $seen = @{}
    foreach ($record in @($Records | Sort-Object TimeCreated)) {
        $failure = if ([string]::IsNullOrWhiteSpace([string]$record.FailureCode)) { 'Unknown' } else { [string]$record.FailureCode }
        $key = '{0}|{1}|{2}' -f ([string]$record.Component).ToLowerInvariant(), ([string]$record.Kind).ToLowerInvariant(), $failure.ToLowerInvariant()
        $incident = if ($null -ne $record.PSObject.Properties['DedupKey']) { [string]$record.DedupKey } else { '{0:o}|{1}' -f $record.TimeCreated, $record.Source }
        $seenKey = $key + [char]0 + $incident
        if ($seen.ContainsKey($seenKey)) { continue }
        $seen[$seenKey] = $true

        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject][ordered]@{
                Component = [string]$record.Component; Kind = [string]$record.Kind; FailureCode = $failure; Count = 0
                FirstOccurrence = [datetime]$record.TimeCreated; LastOccurrence = [datetime]$record.TimeCreated
                MostRecentEvidence = [string]$record.Evidence; Source = ''; Sources = @()
            }
        }
        $group = $groups[$key]
        $group.Count++
        if ($record.TimeCreated -lt $group.FirstOccurrence) { $group.FirstOccurrence = $record.TimeCreated }
        if ($record.TimeCreated -ge $group.LastOccurrence) {
            $group.LastOccurrence = $record.TimeCreated
            $group.MostRecentEvidence = [string]$record.Evidence
        }
        $groupSources = if ($null -ne $record.PSObject.Properties['Sources']) { @($record.Sources) } else { @($record.Source) }
        $group.Sources = @(@($group.Sources) + $groupSources | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        $group.Source = $group.Sources -join ', '
    }

    return @($groups.Values | Sort-Object LastOccurrence -Descending)
}

function Get-CrashGroupSeverity {
    param(
        [Parameter(Mandatory = $true)]$Group,
        [Parameter(Mandatory = $true)][datetime]$Now
    )

    $Now = ([datetimeoffset]$Now).UtcDateTime
    $lastOccurrence = ([datetimeoffset]([datetime]$Group.LastOccurrence)).UtcDateTime
    $recent = $lastOccurrence -ge $Now.AddHours(-24) -and $lastOccurrence -le $Now
    if ($Group.Kind -eq 'BugCheck' -and $Group.Count -ge 2 -and $recent) { return 'ERROR' }
    if ($Group.Kind -eq 'BugCheck' -and ($Group.Count -ge 2 -or $recent)) { return 'WARN' }
    if ($Group.Kind -in @('Crash', 'Hang') -and ($Group.Count -ge 2 -or $recent)) { return 'WARN' }
    return 'None'
}

Write-Host 'Windows Diagnostics Toolkit - Crash and Hang Diagnostics'
Write-Host 'Mode: read-only'

$now = Get-Date
$nowUtc = ([datetimeoffset]$now).UtcDateTime
$startTime = $now.AddDays(-1 * $SinceDays)
$cutoffUtc = ([datetimeoffset]$startTime).UtcDateTime

# Event 1000 is the application crash; WER 1001 supplies supporting report data.
# https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-application-service-crashing-behavior
$sources = @(
    [pscustomobject]@{ Name = 'Application Error/1000'; Result = Read-CrashEvents 'Application' 'Application Error' 1000 $startTime $now $MaxEvents },
    [pscustomobject]@{ Name = 'Windows Error Reporting/1001'; Result = Read-CrashEvents 'Application' 'Windows Error Reporting' 1001 $startTime $now $MaxEvents },
    [pscustomobject]@{ Name = 'Application Hang/1002'; Result = Read-CrashEvents 'Application' 'Application Hang' 1002 $startTime $now $MaxEvents },
    # SystemErrorReporting confirms a bug check, but does not identify its cause.
    # https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-unexpected-reboots-system-event-logs
    [pscustomobject]@{ Name = 'SystemErrorReporting/1001'; Result = Read-CrashEvents 'System' 'Microsoft-Windows-WER-SystemErrorReporting' 1001 $startTime $now $MaxEvents }
)

# Reliability Monitor is optional and may be disabled or unavailable on Server Core.
# https://learn.microsoft.com/en-us/previous-versions/windows/desktop/racwmiprov/win32-reliabilityrecords
$reliability = Read-ReliabilityRecords $startTime $now $MaxEvents
$dumpMetadata = Get-DumpMetadata $startTime $MaxDumpFiles
$records = New-Object System.Collections.Generic.List[object]
foreach ($source in $sources) {
    foreach ($item in @($source.Result.Records)) {
        $record = ConvertTo-CrashRecord $item EventLog
        if ($null -ne $record) { [void]$records.Add($record) }
    }
}
foreach ($item in @($reliability.Records)) {
    $record = ConvertTo-CrashRecord $item Reliability
    if ($null -ne $record) { [void]$records.Add($record) }
}

$incidents = @(Merge-DuplicateCrashRecords @($records.ToArray()) $cutoffUtc)
$groups = @(Group-CrashRecords $incidents)
$applicationGroups = @($groups | Where-Object { $_.Kind -in @('Crash', 'Hang') })
$bugCheckGroups = @($groups | Where-Object { $_.Kind -eq 'BugCheck' })
$unavailableCrashEventSources = @($sources | Where-Object { $null -ne $_.Result.Error })

if ($unavailableCrashEventSources.Count -eq $sources.Count -and $null -ne $reliability.Error) {
    Write-WdtFinding -Severity WARN -Code 'CRASH_ASSESSMENT_UNAVAILABLE' -Message 'Crash and hang assessment could not be completed because all primary event and reliability sources were unavailable.' -Evidence ('EventSources={0}/{1} unavailable; ReliabilityMonitor=Unavailable' -f $unavailableCrashEventSources.Count, $sources.Count)
}

Write-Section 'Summary'
Write-Host ('Time window         : Last {0} day(s)' -f $SinceDays)
Write-Host ('Event limit         : {0} per source' -f $MaxEvents)
Write-Host ('Dump metadata limit : {0}' -f $MaxDumpFiles)
Write-Host ('Normalized incidents: {0}' -f $incidents.Count)
Write-Host ('Application groups  : {0}' -f $applicationGroups.Count)
Write-Host ('BugCheck groups     : {0}' -f $bugCheckGroups.Count)
Write-Host ('Recent dump files   : {0}' -f $dumpMetadata.Dumps.Count)

Write-Section 'Data Source Availability'
foreach ($source in $sources) {
    if ($null -ne $source.Result.Error) { Write-Host ('{0}: Unavailable ({1})' -f $source.Name, $source.Result.Error) }
    else { Write-Host ('{0}: Available; Records={1}' -f $source.Name, @($source.Result.Records).Count) }
}
if ($null -ne $reliability.Error) { Write-Host ('Reliability Monitor: Unavailable ({0}); Event Log fallback remains active.' -f $reliability.Error) }
else { Write-Host ('Reliability Monitor: Available; Records={0}' -f @($reliability.Records).Count) }

Write-Section 'Application Crash and Hang Events'
if ($applicationGroups.Count -eq 0) { Write-Host 'No recognized application crash or hang groups were found.' }
foreach ($group in @($applicationGroups | Select-Object -First $MaxEvents)) {
    Write-Host ('Component            : {0}' -f $group.Component)
    Write-Host ('Kind                 : {0}' -f $group.Kind)
    Write-Host ('Failure code         : {0}' -f $group.FailureCode)
    Write-Host ('Count                : {0}' -f $group.Count)
    Write-Host ('First occurrence     : {0:u}' -f $group.FirstOccurrence)
    Write-Host ('Last occurrence      : {0:u}' -f $group.LastOccurrence)
    Write-Host ('Sources              : {0}' -f $group.Source)
    Write-Host ('Most recent evidence : {0}' -f $group.MostRecentEvidence)
    Write-Host ''
}
$applicationFindings = @($applicationGroups | Where-Object { (Get-CrashGroupSeverity $_ $nowUtc) -eq 'WARN' })
if ($applicationFindings.Count -gt 0) {
    $latest = $applicationFindings | Sort-Object LastOccurrence -Descending | Select-Object -First 1
    $count = ($applicationFindings | Measure-Object Count -Sum).Sum
    Write-WdtFinding -Severity WARN -Code 'CRASH_APPLICATION_FAILURES_DETECTED' -Message 'Recent or repeated application crash or hang groups were found.' -Evidence ('Groups={0}; Incidents={1}; MostRecentComponent={2}; Kind={3}; FailureCode={4}; Last={5:u}' -f $applicationFindings.Count, $count, $latest.Component, $latest.Kind, $latest.FailureCode, $latest.LastOccurrence)
}

Write-Section 'BugCheck Events'
if ($bugCheckGroups.Count -eq 0) { Write-Host 'No recognized BugCheck groups were found.' }
foreach ($group in @($bugCheckGroups | Select-Object -First $MaxEvents)) {
    Write-Host ('Failure code         : {0}' -f $group.FailureCode)
    Write-Host ('Count                : {0}' -f $group.Count)
    Write-Host ('First occurrence     : {0:u}' -f $group.FirstOccurrence)
    Write-Host ('Last occurrence      : {0:u}' -f $group.LastOccurrence)
    Write-Host ('Sources              : {0}' -f $group.Source)
    Write-Host ('Most recent evidence : {0}' -f $group.MostRecentEvidence)
    Write-Host ''
}
$bugCheckFindings = @($bugCheckGroups | Where-Object { (Get-CrashGroupSeverity $_ $nowUtc) -ne 'None' })
if ($bugCheckFindings.Count -gt 0) {
    $severity = if (@($bugCheckFindings | Where-Object { (Get-CrashGroupSeverity $_ $nowUtc) -eq 'ERROR' }).Count -gt 0) { 'ERROR' } else { 'WARN' }
    $latest = $bugCheckFindings | Sort-Object LastOccurrence -Descending | Select-Object -First 1
    $count = ($bugCheckFindings | Measure-Object Count -Sum).Sum
    $message = if ($severity -eq 'ERROR') { 'Repeated recent Windows BugCheck events were found.' } else { 'A recent or repeated Windows BugCheck event was found.' }
    Write-WdtFinding -Severity $severity -Code 'CRASH_BUGCHECK_DETECTED' -Message $message -Evidence ('Groups={0}; Incidents={1}; StopCode={2}; Last={3:u}' -f $bugCheckFindings.Count, $count, $latest.FailureCode, $latest.LastOccurrence)
}

Write-Section 'Recent Dump Metadata'
foreach ($errorItem in $dumpMetadata.Errors) { Write-Host ('Unavailable: {0}' -f $errorItem) }
if ($dumpMetadata.Dumps.Count -eq 0) { Write-Host 'No recent dump files were found.' }
foreach ($dump in $dumpMetadata.Dumps) {
    Write-Host ('Name          : {0}' -f $dump.Name)
    Write-Host ('LastWriteTime : {0}' -f $dump.LastWriteTime)
    Write-Host ('Size          : {0}' -f (Format-Bytes $dump.Size))
    Write-Host ('Source        : {0}' -f $dump.Source)
    Write-Host ''
}
