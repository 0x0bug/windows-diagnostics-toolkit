[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$SinceDays = 7,

    [ValidateRange(1, 100)]
    [int]$MaxEvents = 20,

    [switch]$IncludeTimeServiceEvents
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\..\..\scripts\report-common.ps1

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)

    Write-Host ''
    Write-Host "== $Title =="
}

function Get-W32TimeService {
    try {
        return [pscustomobject]@{
            Service = Get-CimInstance -ClassName Win32_Service -Filter "Name='W32Time'" -ErrorAction Stop
            Error   = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Service = $null
            Error   = $_.Exception.Message
        }
    }
}

function Get-DomainMembership {
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        return [pscustomobject]@{
            PartOfDomain = [bool]$computerSystem.PartOfDomain
            Error        = $null
        }
    }
    catch {
        return [pscustomobject]@{
            PartOfDomain = $null
            Error        = $_.Exception.Message
        }
    }
}

function Get-TimezoneInformation {
    $getTimeZoneCommand = Get-Command -Name 'Get-TimeZone' -ErrorAction SilentlyContinue
    if ($null -ne $getTimeZoneCommand) {
        try {
            $timezone = Get-TimeZone -ErrorAction Stop
            return [pscustomobject]@{
                Timezone = $timezone
                Source   = 'Get-TimeZone'
                Error    = $null
            }
        }
        catch {
            $getTimeZoneError = $_.Exception.Message
        }
    }
    else {
        $getTimeZoneError = 'Get-TimeZone is unavailable.'
    }

    try {
        $timezone = Get-CimInstance -ClassName Win32_TimeZone -ErrorAction Stop
        return [pscustomobject]@{
            Timezone = $timezone
            Source   = 'Win32_TimeZone'
            Error    = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Timezone = $null
            Source   = $null
            Error    = ('{0} CIM fallback failed: {1}' -f $getTimeZoneError, $_.Exception.Message)
        }
    }
}

function Get-WdtOemEncoding {
    $oemCodePage = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
    return [System.Text.Encoding]::GetEncoding($oemCodePage)
}

function ConvertFrom-WdtOemBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [System.Text.Encoding]$Encoding = $(Get-WdtOemEncoding)
    )

    return $Encoding.GetString($Bytes)
}

function New-WdtW32tmResult {
    param([string]$Stdout, [string]$Stderr, [int]$ExitCode)

    $output = @($Stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($ExitCode -ne 0) {
        $errorDetail = if ([string]::IsNullOrWhiteSpace($Stderr)) { $Stdout.Trim() } else { $Stderr.Trim() }
        return [pscustomobject]@{
            Output   = @($output)
            Error    = ('w32tm.exe exited with code {0}: {1}' -f $ExitCode, $errorDetail)
            ExitCode = $ExitCode
        }
    }

    return [pscustomobject]@{
        Output   = @($output)
        Error    = $(if ([string]::IsNullOrWhiteSpace($Stderr)) { $null } else { $Stderr.Trim() })
        ExitCode = $ExitCode
    }
}

function Resolve-WdtSystemExecutablePath {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $systemDirectory = [System.Environment]::SystemDirectory
    if ([System.Environment]::Is64BitOperatingSystem -and -not [System.Environment]::Is64BitProcess) {
        $windowsDirectory = [System.IO.Directory]::GetParent($systemDirectory).FullName
        $systemDirectory = Join-Path -Path $windowsDirectory -ChildPath 'Sysnative'
    }

    $candidatePath = Join-Path -Path $systemDirectory -ChildPath $FileName
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($candidatePath)
}

function Invoke-W32tmQuery {
    param([Parameter(Mandatory = $true)][ValidateSet('Source', 'Status')][string]$Query)

    $commandPath = Resolve-WdtSystemExecutablePath -FileName 'w32tm.exe'
    if ([string]::IsNullOrWhiteSpace($commandPath)) {
        return [pscustomobject]@{
            Output   = @()
            Error    = 'w32tm.exe is unavailable.'
            ExitCode = $null
        }
    }

    $process = $null
    $stdoutReader = $null
    $stderrReader = $null
    try {
        $oemEncoding = Get-WdtOemEncoding
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $commandPath
        $startInfo.Arguments = if ($Query -eq 'Source') { '/query /source' } else { '/query /status /verbose' }
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = $oemEncoding
        $startInfo.StandardErrorEncoding = $oemEncoding

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $stdoutReader = $process.StandardOutput
        $stderrReader = $process.StandardError
        $stdout = $stdoutReader.ReadToEnd()
        $stderr = $stderrReader.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        return New-WdtW32tmResult -Stdout $stdout -Stderr $stderr -ExitCode $exitCode
    }
    catch {
        return [pscustomobject]@{
            Output   = @()
            Error    = $_.Exception.Message
            ExitCode = $null
        }
    }
    finally {
        if ($null -ne $stdoutReader) { $stdoutReader.Dispose() }
        if ($null -ne $stderrReader) { $stderrReader.Dispose() }
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Get-TimeServiceEvents {
    param(
        [Parameter(Mandatory = $true)][datetime]$StartTime,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    try {
        return [pscustomobject]@{
            Events = @(Get-WinEvent -FilterHashtable @{
                    LogName   = 'Microsoft-Windows-Time-Service/Operational'
                    StartTime = $StartTime
                    Level     = @(2, 3)
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

function Test-LocalClockSource {
    param([AllowEmptyString()][string]$Source)

    if ([string]::IsNullOrWhiteSpace($Source)) {
        return $false
    }

    return $Source -match '(?i)\b(Local (CMOS )?Clock|Free-running System Clock)\b'
}

Write-Host 'Windows Diagnostics Toolkit - Time Sync Diagnostics'
Write-Host 'Mode: read-only'

$timeService = Get-W32TimeService
$domainMembership = Get-DomainMembership
$timezoneInformation = Get-TimezoneInformation
$localTime = Get-Date
$utcTime = [datetime]::UtcNow
$sourceQuery = Invoke-W32tmQuery -Query Source
$statusQuery = Invoke-W32tmQuery -Query Status

Write-Section 'Windows Time Service'
if ($null -ne $timeService.Error -or $null -eq $timeService.Service) {
    $errorMessage = if ($null -ne $timeService.Error) { $timeService.Error } else { 'W32Time service was not found.' }
    Write-Host ('Unavailable: {0}' -f $errorMessage)
    Write-WdtFinding -Severity WARN -Code 'TIME_SERVICE_UNAVAILABLE' -Message 'The Windows Time service status is unavailable.' -Evidence $errorMessage
}
else {
    Write-Host ('Name      : {0}' -f $timeService.Service.Name)
    Write-Host ('State     : {0}' -f $timeService.Service.State)
    Write-Host ('Start mode: {0}' -f $timeService.Service.StartMode)

    if ($domainMembership.PartOfDomain -eq $true -and $timeService.Service.State -ne 'Running') {
        Write-WdtFinding -Severity WARN -Code 'TIME_SERVICE_STOPPED' -Message 'The Windows Time service is not running on a domain-joined computer.' -Evidence ('State={0}' -f $timeService.Service.State)
    }
}

if ($null -ne $domainMembership.Error) {
    Write-Host ('Domain membership unavailable: {0}' -f $domainMembership.Error)
    Write-WdtFinding -Severity WARN -Code 'TIME_DOMAIN_MEMBERSHIP_UNAVAILABLE' -Message 'Domain membership could not be determined.' -Evidence $domainMembership.Error
}
else {
    Write-Host ('Domain joined: {0}' -f $domainMembership.PartOfDomain)
}

Write-Section 'Timezone and Clock'
Write-Host ('Local time: {0}' -f $localTime.ToString('o'))
Write-Host ('UTC time  : {0}' -f $utcTime.ToString('o'))
if ($null -eq $timezoneInformation.Timezone) {
    Write-Host ('Timezone unavailable: {0}' -f $timezoneInformation.Error)
    Write-WdtFinding -Severity WARN -Code 'TIME_TIMEZONE_UNAVAILABLE' -Message 'Timezone information is unavailable.' -Evidence $timezoneInformation.Error
}
else {
    $timezoneId = if ($null -ne $timezoneInformation.Timezone.Id) { $timezoneInformation.Timezone.Id } else { $timezoneInformation.Timezone.StandardName }
    $timezoneName = if ($null -ne $timezoneInformation.Timezone.DisplayName) { $timezoneInformation.Timezone.DisplayName } else { $timezoneInformation.Timezone.StandardName }
    Write-Host ('Timezone : {0}' -f $timezoneId)
    Write-Host ('Name     : {0}' -f $timezoneName)
    Write-Host ('Source   : {0}' -f $timezoneInformation.Source)
}

Write-Section 'Time Source'
if ($null -ne $sourceQuery.Error) {
    Write-Host ('Unavailable: {0}' -f $sourceQuery.Error)
    Write-WdtFinding -Severity WARN -Code 'TIME_SOURCE_UNAVAILABLE' -Message 'The configured Windows Time source is unavailable.' -Evidence $sourceQuery.Error
}
else {
    $source = ($sourceQuery.Output -join ' ').Trim()
    Write-Host ('Source: {0}' -f $source)
    if (Test-LocalClockSource -Source $source) {
        Write-WdtFinding -Severity WARN -Code 'TIME_SOURCE_LOCAL_CLOCK' -Message 'Windows Time is using a local clock source.' -Evidence $source
    }
}

Write-Section 'W32tm Status'
if ($null -ne $statusQuery.Error) {
    Write-Host ('Unavailable: {0}' -f $statusQuery.Error)
    Write-WdtFinding -Severity WARN -Code 'TIME_STATUS_UNAVAILABLE' -Message 'Detailed Windows Time status is unavailable.' -Evidence $statusQuery.Error
}
elseif ($statusQuery.Output.Count -eq 0) {
    Write-Host 'No status output was returned.'
    Write-WdtFinding -Severity WARN -Code 'TIME_STATUS_UNAVAILABLE' -Message 'Detailed Windows Time status returned no output.'
}
else {
    foreach ($line in $statusQuery.Output) {
        Write-Host $line
    }
}

if ($IncludeTimeServiceEvents) {
    $timeServiceEvents = Get-TimeServiceEvents -StartTime $localTime.AddDays(-1 * $SinceDays) -Limit $MaxEvents

    Write-Section 'Recent Time-Service Warnings and Errors'
    Write-Host ('Time window: Last {0} day(s)' -f $SinceDays)
    Write-Host ('Event limit: {0}' -f $MaxEvents)
    if ($null -ne $timeServiceEvents.Error) {
        Write-Host ('Unavailable: {0}' -f $timeServiceEvents.Error)
        Write-WdtFinding -Severity WARN -Code 'TIME_EVENTS_UNAVAILABLE' -Message 'Time-Service warning and error events are unavailable.' -Evidence $timeServiceEvents.Error
    }
    elseif ($timeServiceEvents.Events.Count -eq 0) {
        Write-Host 'No Time-Service warning or error events were found.'
    }
    else {
        foreach ($event in $timeServiceEvents.Events) {
            Write-Host ('TimeCreated: {0}' -f $event.TimeCreated)
            Write-Host ('Id         : {0}' -f $event.Id)
            Write-Host ('Level      : {0}' -f $event.LevelDisplayName)
            Write-Host ('Provider   : {0}' -f $event.ProviderName)
            Write-Host ''
        }
    }
}
