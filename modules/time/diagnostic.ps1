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
. $PSScriptRoot\..\..\scripts\process-runner.ps1

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
    param(
        [string]$Stdout,
        [string]$Stderr,
        [Nullable[int]]$ExitCode,
        [string]$CaptureError,
        [bool]$OutputComplete = $true
    )

    $output = @($Stdout -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $errors = @()
    if (-not [string]::IsNullOrWhiteSpace($CaptureError)) { $errors += $CaptureError }
    if ($null -ne $ExitCode -and $ExitCode -ne 0) {
        $errorDetail = if ([string]::IsNullOrWhiteSpace($Stderr)) { $Stdout.Trim() } else { $Stderr.Trim() }
        $errors += ('w32tm.exe exited with code {0}: {1}' -f $ExitCode, $errorDetail)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Stderr)) { $errors += $Stderr.Trim() }

    return [pscustomobject]@{
        Output         = @($output)
        Error          = $(if ($errors.Count -eq 0) { $null } else { $errors -join '; ' })
        ExitCode       = $ExitCode
        OutputComplete = $OutputComplete
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
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Source', 'Status')][string]$Query,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10
    )

    $commandPath = Resolve-WdtSystemExecutablePath -FileName 'w32tm.exe'
    if ([string]::IsNullOrWhiteSpace($commandPath)) {
        return New-WdtW32tmResult -ExitCode $null -CaptureError 'w32tm.exe is unavailable.' -OutputComplete $false
    }

    $process = $null
    $processStarted = $false
    $processExited = $false
    $stdoutState = $null
    $stderrState = $null
    $exitCode = $null
    $errors = New-Object System.Collections.Generic.List[string]
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
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
        $processStarted = $true
        $stdoutState = New-WdtStreamCaptureState -Reader $process.StandardOutput
        $stderrState = New-WdtStreamCaptureState -Reader $process.StandardError
        while (-not $processExited -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            [void](Read-WdtCompletedStreamChunks -State $stdoutState)
            [void](Read-WdtCompletedStreamChunks -State $stderrState)
            $processExited = $process.WaitForExit(25)
        }

        if (-not $processExited) {
            $errors.Add(('w32tm.exe exceeded timeout of {0} second(s).' -f $TimeoutSeconds))
            try {
                $cleanup = Stop-WdtProcessTree -RootProcess $process -CleanupTimeoutMilliseconds 2000
                if (-not $cleanup.Success) { $errors.Add(('Process-tree cleanup was incomplete: {0}' -f (($cleanup.Errors | Select-Object -First 5) -join '; '))) }
            }
            catch { $errors.Add(('Process-tree cleanup failed: {0}' -f $_.Exception.Message)) }
        }
        else { $exitCode = $process.ExitCode }

        $drainStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ((-not $stdoutState.Complete -or -not $stderrState.Complete) -and $drainStopwatch.ElapsedMilliseconds -lt 2000) {
            $stdoutProgress = Read-WdtCompletedStreamChunks -State $stdoutState
            $stderrProgress = Read-WdtCompletedStreamChunks -State $stderrState
            if (-not $stdoutProgress -and -not $stderrProgress) { Start-Sleep -Milliseconds 10 }
        }
        $drainStopwatch.Stop()
        [void](Read-WdtCompletedStreamChunks -State $stdoutState)
        [void](Read-WdtCompletedStreamChunks -State $stderrState)
        if (-not $stdoutState.Complete -or -not $stderrState.Complete) {
            $errors.Add('Captured output is incomplete because stream drain did not finish within 2 seconds.')
        }
    }
    catch {
        $errors.Add($_.Exception.Message)
        if ($processStarted -and -not $processExited) {
            try {
                $cleanup = Stop-WdtProcessTree -RootProcess $process -CleanupTimeoutMilliseconds 2000
                if (-not $cleanup.Success) { $errors.Add(('Process-tree cleanup was incomplete: {0}' -f (($cleanup.Errors | Select-Object -First 5) -join '; '))) }
            }
            catch { $errors.Add(('Process-tree cleanup failed: {0}' -f $_.Exception.Message)) }
        }
    }
    finally {
        $stopwatch.Stop()
        foreach ($state in @($stdoutState, $stderrState)) {
            if ($null -ne $state) {
                try { $state.Reader.Dispose() }
                catch { $errors.Add(('Failed to close a stream reader: {0}' -f $_.Exception.Message)) }
            }
        }
        if ($null -ne $process) {
            try { $process.Dispose() }
            catch { $errors.Add(('Failed to dispose the child process handle: {0}' -f $_.Exception.Message)) }
        }
    }

    foreach ($state in @($stdoutState, $stderrState)) {
        if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace([string]$state.Error)) { $errors.Add([string]$state.Error) }
    }
    $stdout = if ($null -eq $stdoutState) { '' } else { $stdoutState.Text.ToString() }
    $stderr = if ($null -eq $stderrState) { '' } else { $stderrState.Text.ToString() }
    $outputComplete = $processExited -and $null -ne $stdoutState -and $null -ne $stderrState -and $stdoutState.Complete -and $stderrState.Complete -and $errors.Count -eq 0
    return New-WdtW32tmResult -Stdout $stdout -Stderr $stderr -ExitCode $exitCode -CaptureError ($errors -join '; ') -OutputComplete $outputComplete
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
    param([AllowEmptyString()][string]$Source, [string[]]$StatusOutput = @())

    if ($Source.Trim() -match '^(?i:Local (?:CMOS )?Clock|Free-running System Clock)$') { return $true }

    # MS-W32T exposes the runtime reference ID; MS-SNTP defines LOCL.
    # w32tm prints a quoted clock name for this ID. Requiring the pair avoids
    # confusing the same numeric IPv4 reference (76.79.67.76) with a clock.
    $referenceLines = @($StatusOutput | Where-Object { $_ -match '^\s*[^:]+:\s*0x[0-9A-Fa-f]{8}(?:\s|$)' })
    if ($referenceLines.Count -eq 1) {
        return $referenceLines[0] -match '^\s*[^:]+:\s*0x4C4F434C\s+\([^\r\n()]*"(?:LOCL|LOCAL)"\s*\)\s*$'
    }
    return $false
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
    if ($sourceQuery.Output.Count -gt 0) {
        Write-Host 'Partial output:'
        foreach ($line in $sourceQuery.Output) { Write-Host $line }
    }
    Write-Host ('Unavailable: {0}' -f $sourceQuery.Error)
    Write-WdtFinding -Severity WARN -Code 'TIME_SOURCE_UNAVAILABLE' -Message 'The configured Windows Time source is unavailable.' -Evidence $sourceQuery.Error
}
else {
    $source = ($sourceQuery.Output -join ' ').Trim()
    Write-Host ('Source: {0}' -f $source)
    $statusEvidence = if ($null -eq $statusQuery.Error -and $statusQuery.ExitCode -eq 0 -and $statusQuery.OutputComplete) { @($statusQuery.Output) } else { @() }
    if ([string]::IsNullOrWhiteSpace($source)) {
        Write-WdtFinding -Severity WARN -Code 'TIME_SOURCE_UNAVAILABLE' -Message 'The Windows Time source query returned no output.'
    }
    elseif (Test-LocalClockSource -Source $source -StatusOutput $statusEvidence) {
        Write-WdtFinding -Severity WARN -Code 'TIME_SOURCE_LOCAL_CLOCK' -Message 'Windows Time is using a local clock source.' -Evidence $source
    }
}

Write-Section 'W32tm Status'
if ($null -ne $statusQuery.Error) {
    if ($statusQuery.Output.Count -gt 0) {
        Write-Host 'Partial output:'
        foreach ($line in $statusQuery.Output) { Write-Host $line }
    }
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
