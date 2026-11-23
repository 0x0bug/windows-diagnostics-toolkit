[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\performance-recording.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected '$Expected', got '$Actual'." }
}

function New-DiskCounterFixture {
    param([decimal]$Ticks, [decimal]$Transfers, [uint64]$Timestamp)
    [pscustomobject]@{ Ticks=$Ticks; Transfers=$Transfers; Frequency=1000000.0; Timestamp=$Timestamp }
}

$diskBefore = New-DiskCounterFixture 100000 10 100
$diskAfter = New-DiskCounterFixture 250000 20 200
Assert-Equal 15 (Get-WdtPerformanceDiskInterval $diskBefore $diskAfter 'Measured').LatencyMs 'Disk latency must use the deltas, transfer count and timer frequency.'
$idleDisk = Get-WdtPerformanceDiskInterval $diskAfter (New-DiskCounterFixture 250000 20 300) 'Measured'
Assert-Equal 'No completed transfers' $idleDisk.Status 'Idle disk status was lost.'
Assert-True ($null -eq $idleDisk.LatencyMs) 'An idle disk must not fabricate zero latency.'
$instantDisk = Get-WdtPerformanceDiskInterval $diskAfter (New-DiskCounterFixture 250000 25 300) 'Measured'
Assert-Equal 0 $instantDisk.LatencyMs 'A valid zero-latency measurement was discarded.'
Assert-Equal 'Baseline needed' (Get-WdtPerformanceDiskInterval $null $diskAfter 'Measured').Status 'A disk gap must require a new baseline.'
Assert-Equal 'Unavailable (counter reset or wrap)' (Get-WdtPerformanceDiskInterval $diskAfter $diskBefore 'Measured').Status 'A reset counter yielded a latency.'
Assert-Equal 'Unavailable (stale counter sample)' (Get-WdtPerformanceDiskInterval $diskAfter $diskAfter 'Measured').Status 'A duplicate timestamp was treated as new evidence.'

$counters = & {
    function Get-CimInstance {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter, [string[]]$Property, [int]$OperationTimeoutSec)
        Assert-Equal 2 $OperationTimeoutSec 'A performance query must have an operation timeout.'
        switch ($ClassName) {
            'Win32_PerfFormattedData_Counters_ProcessorInformation' {
                Assert-Equal "Name = '_Total'" $Filter 'CPU counter must be aggregated.'
                [pscustomobject]@{ PercentProcessorTime = [uint64]0 }
            }
            'Win32_OperatingSystem' {
                [pscustomobject]@{ TotalVisibleMemorySize = 10240; FreePhysicalMemory = 4096 }
            }
            'Win32_PerfRawData_PerfDisk_PhysicalDisk' {
                Assert-Equal "Name = '_Total'" $Filter 'Disk counter must be aggregated.'
                [pscustomobject]@{ AvgDiskSecPerTransfer = 100000; AvgDiskSecPerTransfer_Base = 10; Frequency_PerfTime = 1000000; Timestamp_PerfTime = 100 }
            }
            default { throw 'Unexpected fixture CIM class.' }
        }
    }

    Get-WdtPerformanceCounters
}
Assert-Equal 0 $counters.CpuPercent 'A valid zero CPU usage sample was discarded.'
Assert-Equal 'Measured' $counters.CpuStatus 'A valid zero CPU sample lost its status.'
Assert-Equal 4 $counters.MemoryAvailableMiB 'Available RAM conversion is wrong.'
Assert-Equal 40 $counters.MemoryAvailablePercent 'Available RAM percentage is wrong.'
Assert-Equal 100000 $counters.DiskRaw.Ticks 'Disk raw timing data did not survive projection.'

$unreadableCounters = & {
    function Get-CimInstance {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter, [string[]]$Property, [int]$OperationTimeoutSec)
        if ($ClassName -eq 'Win32_PerfRawData_PerfDisk_PhysicalDisk') { throw 'C:\Users\PrivateFixture\provider details' }
    }

    Get-WdtPerformanceCounters
}
Assert-Equal 'Unavailable (invalid counter data)' $unreadableCounters.CpuStatus 'Empty CPU results must be explicitly unavailable.'
Assert-Equal 'Unavailable (query failed)' $unreadableCounters.DiskStatus 'Provider errors must be represented without private exception details.'
Assert-True ($null -eq $unreadableCounters.DiskRaw) 'A failed disk provider must not supply raw timing data.'

function New-ProcessCounterFixture {
    param([int]$Id, [string]$Name, [long]$StartTicks, [double]$CpuSeconds)
    [pscustomobject]@{ Id=$Id; Name=$Name; StartTicks=$StartTicks; CpuSeconds=$CpuSeconds }
}

$initialProcesses = @{}
$laterProcesses = @{}
foreach ($id in 10..16) {
    $initialProcesses[$id] = New-ProcessCounterFixture $id 'fixture' 100 10
    $laterProcesses[$id] = New-ProcessCounterFixture $id 'fixture' 100 (10 + $id)
}
$initialProcesses[1] = New-ProcessCounterFixture 1 'reused' 100 2
$laterProcesses[1] = New-ProcessCounterFixture 1 'reused' 200 1000
$initialProcesses[2] = New-ProcessCounterFixture 2 'regressed' 100 20
$laterProcesses[2] = New-ProcessCounterFixture 2 'regressed' 100 1
$initialProcesses[3] = New-ProcessCounterFixture 3 'idle' 100 2
$laterProcesses[3] = New-ProcessCounterFixture 3 'idle' 100 2
$processBefore = [pscustomobject]@{ Processes=$initialProcesses; Unreadable=1 }
$processAfter = [pscustomobject]@{ Processes=$laterProcesses; Unreadable=2 }
$activity = Get-WdtPerformanceProcessInterval $processBefore $processAfter 4
Assert-Equal 'Measured' $activity.Status 'Valid process intervals were not measured.'
Assert-Equal 8 $activity.Measured 'Zero and positive CPU deltas must count as measured.'
Assert-Equal 5 $activity.Top.Count 'Top process results must remain bounded.'
Assert-Equal 1 $activity.Unmatched 'A reused PID must not inherit its preceding process counter.'
Assert-Equal 1 $activity.Regressed 'A regressed CPU counter must be counted as unavailable.'
Assert-Equal 3 $activity.Unreadable 'Unreadable endpoint counts must remain visible.'
Assert-Equal 16 $activity.Top[0].Id 'Process ranking by CPU delta is wrong.'
Assert-Equal 16 $activity.Top[0].DeltaSeconds 'The highest CPU-time delta changed.'
Assert-Equal 400 $activity.Top[0].CpuPercent 'CPU percentage must use the actual interval, with 100 percent per logical CPU.'
Assert-Equal 'Baseline needed' (Get-WdtPerformanceProcessInterval $null $processAfter 4).Status 'A process gap must require a new baseline.'
Assert-Equal 'Unavailable (query failed)' (Get-WdtPerformanceProcessInterval $processBefore $null 4).Status 'A failed process query must remain unavailable.'

& {
    $fixtureKey = [pscustomobject]@{ Value = 'Marked' }
    function Get-WdtPerformanceMarkerKey { $fixtureKey.Value }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $marker = [pscustomobject]@{ Status='Pending'; TimestampUtc=$null; ElapsedSeconds=$null }
    $null = Wait-WdtPerformanceCapturePoint $clock 0 60 $marker $true
    Assert-Equal 'Marked' $marker.Status 'The recording did not handle the marker key.'
    Assert-Equal ([System.DateTimeKind]::Utc) $marker.TimestampUtc.Kind 'The marker must store a UTC timestamp.'
    $markedAt = $marker.ElapsedSeconds

    $fixtureKey.Value = 'Unavailable'
    $null = Wait-WdtPerformanceCapturePoint $clock 0 60 $marker $true
    Assert-Equal $markedAt $marker.ElapsedSeconds 'The first marker must survive subsequent polling.'
    $marker.Status = 'Pending'
    $null = Wait-WdtPerformanceCapturePoint $clock 0 60 $marker $true
    Assert-Equal 'Unavailable' $marker.Status 'A missing console must not stop collection.'
}

function Invoke-RecordingFixture {
    param([ValidateSet('Complete','Partial','Unavailable')]$Mode)

    $fixture = [pscustomobject]@{ Mode=$Mode; Index=0; Epoch=[datetime]'2026-01-05T12:00:00Z' }
    $fixture.Epoch = $fixture.Epoch.ToUniversalTime()
    function Wait-WdtPerformanceCapturePoint {
        param($Clock, [double]$TargetSeconds, [int]$DurationSeconds, $Marker, [bool]$Quiet)
        $fixture.Index = [int]($TargetSeconds / 2)
        if ($Marker.Status -eq 'Pending' -and $TargetSeconds -eq 10) {
            $Marker.Status = 'Marked'
            $Marker.TimestampUtc = $fixture.Epoch.AddSeconds($TargetSeconds)
            $Marker.ElapsedSeconds = $TargetSeconds
        }
        [pscustomobject]@{ ElapsedSeconds=$TargetSeconds; TimestampUtc=$fixture.Epoch.AddSeconds($TargetSeconds) }
    }

    function Get-WdtPerformanceProcessSnapshot {
        if ($fixture.Mode -eq 'Unavailable') { return $null }
        $process = New-ProcessCounterFixture 91234 "FixtureSecretProc`nname" 1725000000 $fixture.Index
        [pscustomobject]@{ Processes=@{ 91234=$process }; Unreadable=0 }
    }

    function Get-WdtPerformanceCounters {
        $cpu = if ($fixture.Mode -eq 'Unavailable') { $null } else { 25 }
        $memory = if ($fixture.Mode -eq 'Unavailable') { $null } else { 60 }
        $disk = if ($fixture.Mode -ne 'Unavailable') { New-DiskCounterFixture (500000 + 20000 * $fixture.Index) (500 + 2 * $fixture.Index) (100 + $fixture.Index) }
        if ($fixture.Mode -eq 'Partial' -and $fixture.Index -eq 2) { $disk = $null }
        switch ($fixture.Index) {
            4 { if ($null -ne $cpu) { $cpu = 90 } }
            6 { if ($null -ne $cpu) { $cpu = 99 } }
            20 { if ($null -ne $cpu) { $cpu = 100 } }
        }
        [pscustomobject]@{
            CpuPercent = $cpu
            CpuStatus = if ($null -eq $cpu) { 'Unavailable (query failed)' } else { 'Measured' }
            MemoryAvailableMiB = if ($null -ne $memory) { 3000 }
            MemoryAvailablePercent = $memory
            MemoryStatus = if ($null -eq $memory) { 'Unavailable (query failed)' } else { 'Measured' }
            DiskRaw = $disk
            DiskStatus = if ($null -eq $disk) { 'Unavailable (query failed)' } else { 'Measured' }
        }
    }

    Invoke-WdtPerformanceRecording -InteractiveMarker -Quiet
}

$complete = Invoke-RecordingFixture Complete
Assert-Equal 'Complete' $complete.Completeness 'Expected first-read baselines must not make an otherwise complete recording partial.'
Assert-Equal 'Marked' $complete.Marker.Status 'The marker should retain its collection time.'
Assert-Equal 30 $complete.Samples.Count 'A default recording must sample every two seconds before the sixty-second deadline.'
Assert-Equal 58 $complete.Samples[-1].ElapsedSeconds 'The last sample should begin before the recording finishes.'
Assert-Equal 60 $complete.ElapsedSeconds 'The recording should wait to its deadline after the last sample.'

$partial = Invoke-RecordingFixture Partial
Assert-Equal 'Partial' $partial.Completeness 'A single missing source must make a successful recording partial.'
Assert-Equal 0 $partial.ExitCode 'Partial results should still be written as a successful capture.'
Assert-Equal 'Unavailable (query failed)' $partial.Samples[2].DiskStatus 'The failed sample must keep the source gap.'
Assert-Equal 'Baseline needed' $partial.Samples[3].DiskStatus 'Recovery must not calculate disk latency across the failed sample.'
Assert-Equal 'Measured' $partial.Samples[4].DiskStatus 'Disk collection did not recover after the second valid sample.'

$normalReport = @(Format-WdtPerformanceRecording -Recording $partial) -join "`n"
Assert-True ($normalReport.Contains('FixtureSecretProc name (PID 91234)')) 'Process labels should remain on one line.'
$privacyReport = @(Format-WdtPerformanceRecording -Recording $partial -PrivacyMode) -join "`n"
Assert-True ($privacyReport -notmatch 'FixtureSecretProc|91234|1725000000') 'A privacy recording leaked a process identifier.'
Assert-True ($privacyReport.Contains('<ID-1>')) 'Process activity should retain a consistent pseudonym within the recording.'
Assert-True ($privacyReport.Contains('Symptom marker: 2026-01-05T12:00:10.0000000Z')) 'The report is missing the absolute marker timestamp.'
Assert-True ($privacyReport.Contains('Before marker (up to 10 s; 5 samples)')) 'The pre-marker window is wrong.'
Assert-True ($privacyReport.Contains('At and after marker (up to 10 s; 6 samples)')) 'The post-marker window is wrong.'
$sections = $privacyReport -split '(?m)^== (?:Recording Peaks|Peaks Around Symptom Marker|Timestamped Samples) ==$'
Assert-True ($sections[1].Contains(('Highest CPU: {0:0.0}%' -f 100))) 'The overall peak was lost.'
Assert-True ($sections[2].Contains(('Highest CPU: {0:0.0}%' -f 90))) 'The pre-marker CPU peak was lost.'
Assert-True ($sections[2].Contains(('Highest CPU: {0:0.0}%' -f 99))) 'The post-marker CPU peak was lost.'
Assert-True (-not $sections[2].Contains(('Highest CPU: {0:0.0}%' -f 100))) 'A distant unrelated peak appeared in the marker window.'
Assert-Equal 30 ([regex]::Matches($sections[3], '(?m)^\d{4}-\d{2}-\d{2}T\S+Z \(\+\d+\.\d{3} s\)$').Count) 'The timestamped timeline lost samples.'

$unavailable = Invoke-RecordingFixture Unavailable
Assert-Equal 'Unavailable' $unavailable.Completeness 'Completely unavailable metrics must be explicit.'
Assert-Equal 1 $unavailable.ExitCode 'Completely unavailable metrics must be detectable by callers.'
$unavailableReport = @(Format-WdtPerformanceRecording -Recording $unavailable) -join "`n"
Assert-True ($unavailableReport.Contains('CPU: 0/30 measured')) 'Missing CPU must be visible in source coverage.'
Assert-True ($unavailableReport.Contains('CPU: Unavailable (query failed) | Available RAM: Unavailable (query failed)')) 'Missing readings must remain distinct from zero.'

foreach ($seconds in @(59, 121)) {
    $rejected = $false
    try { Invoke-WdtPerformanceRecording -DurationSeconds $seconds -Quiet | Out-Null }
    catch [System.Management.Automation.ParameterBindingException] { $rejected = $true }
    Assert-True $rejected 'Recording duration must be bounded between 60 and 120 seconds.'
}

Write-Host 'Performance recording tests passed.'
