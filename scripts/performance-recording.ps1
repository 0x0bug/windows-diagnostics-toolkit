[CmdletBinding()]
param()

. $PSScriptRoot\report-common.ps1

function Get-WdtPerformanceCounters {
    $counters = [pscustomobject]@{
        CpuPercent = $null
        CpuStatus = 'Unavailable (query failed)'
        MemoryAvailableMiB = $null
        MemoryAvailablePercent = $null
        MemoryStatus = 'Unavailable (query failed)'
        DiskRaw = $null
        DiskStatus = 'Unavailable (query failed)'
    }

    try {
        $cpu = @(Get-CimInstance -ClassName 'Win32_PerfFormattedData_Counters_ProcessorInformation' -Filter "Name = '_Total'" -Property 'PercentProcessorTime' -OperationTimeoutSec 2 -ErrorAction Stop)
        $counters.CpuStatus = 'Unavailable (invalid counter data)'
        if ($cpu.Count -eq 1 -and $null -ne $cpu[0].PercentProcessorTime -and $cpu[0].PercentProcessorTime -ge 0 -and $cpu[0].PercentProcessorTime -le 100) {
            $counters.CpuPercent = [double]$cpu[0].PercentProcessorTime
            $counters.CpuStatus = 'Measured'
        }
    }
    catch { # Keep provider errors out of the report.
    }

    try {
        $memory = @(Get-CimInstance -ClassName 'Win32_OperatingSystem' -Property 'TotalVisibleMemorySize','FreePhysicalMemory' -OperationTimeoutSec 2 -ErrorAction Stop)
        $counters.MemoryStatus = 'Unavailable (invalid counter data)'
        if ($memory.Count -eq 1) {
            $available = Get-WdtAvailablePercent -Available $memory[0].FreePhysicalMemory -Total $memory[0].TotalVisibleMemorySize
            if ($null -ne $available) {
                $counters.MemoryAvailableMiB = [double]$memory[0].FreePhysicalMemory / 1024
                $counters.MemoryAvailablePercent = $available
                $counters.MemoryStatus = 'Measured'
            }
        }
    }
    catch { # Keep provider errors out of the report.
    }

    try {
        $disk = @(Get-CimInstance -ClassName 'Win32_PerfRawData_PerfDisk_PhysicalDisk' -Filter "Name = '_Total'" -Property 'AvgDiskSecPerTransfer','AvgDiskSecPerTransfer_Base','Frequency_PerfTime','Timestamp_PerfTime' -OperationTimeoutSec 2 -ErrorAction Stop)
        $counters.DiskStatus = 'Unavailable (invalid counter data)'
        if ($disk.Count -eq 1 -and $null -ne $disk[0].AvgDiskSecPerTransfer -and $null -ne $disk[0].AvgDiskSecPerTransfer_Base -and
            $disk[0].Frequency_PerfTime -gt 0 -and $disk[0].Timestamp_PerfTime -gt 0) {
            $counters.DiskRaw = [pscustomobject]@{
                Ticks = [decimal]$disk[0].AvgDiskSecPerTransfer
                Transfers = [decimal]$disk[0].AvgDiskSecPerTransfer_Base
                Frequency = [double]$disk[0].Frequency_PerfTime
                Timestamp = [uint64]$disk[0].Timestamp_PerfTime
            }
            $counters.DiskStatus = 'Measured'
        }
    }
    catch { # Keep provider errors out of the report.
    }

    return $counters
}

function Get-WdtPerformanceDiskInterval {
    param($Previous, $Current, [string]$CurrentStatus)

    $result = [pscustomobject]@{ LatencyMs = $null; Status = $CurrentStatus }
    if ($null -eq $Current) { return $result }
    if ($null -eq $Previous) {
        $result.Status = 'Baseline needed'
        return $result
    }

    $ticks = $Current.Ticks - $Previous.Ticks
    $transfers = $Current.Transfers - $Previous.Transfers
    if ($ticks -lt 0 -or $transfers -lt 0 -or $Current.Frequency -ne $Previous.Frequency -or $Current.Timestamp -lt $Previous.Timestamp) {
        $result.Status = 'Unavailable (counter reset or wrap)'
    }
    elseif ($Current.Timestamp -eq $Previous.Timestamp) {
        $result.Status = 'Unavailable (stale counter sample)'
    }
    elseif ($transfers -eq 0) {
        $result.Status = 'No completed transfers'
    }
    else {
        # PERF_AVERAGE_TIMER: divide elapsed ticks by their frequency and the transfer count.
        $result.LatencyMs = 1000 * ([double]$ticks / $Current.Frequency) / [double]$transfers
        $result.Status = 'Measured'
    }
    return $result
}

function Get-WdtPerformanceProcessSnapshot {
    $processes = @{}
    $unreadable = 0

    try { $inventory = @(Get-Process -ErrorAction Stop) }
    catch { return $null }

    foreach ($process in $inventory) {
        try {
            if ($process.Id -eq 0) { continue } # The idle pseudo-process is not CPU work.
            $startTime = $process.StartTime
            $cpuTime = $process.TotalProcessorTime
            $processName = $process.ProcessName
            if ($null -eq $startTime -or $null -eq $cpuTime -or [string]::IsNullOrWhiteSpace($processName)) {
                $unreadable++
                continue
            }

            $processes[$process.Id] = [pscustomobject]@{
                Id = $process.Id
                Name = $processName
                StartTicks = $startTime.Ticks
                CpuSeconds = $cpuTime.TotalSeconds
            }
        }
        catch { $unreadable++ }
        finally { $process.Dispose() }
    }

    return [pscustomobject]@{ Processes = $processes; Unreadable = $unreadable }
}

function Get-WdtPerformanceProcessInterval {
    param($Previous, $Current, [double]$IntervalSeconds)

    $result = [pscustomobject]@{ Top = @(); Measured = 0; Unreadable = 0; Unmatched = 0; Regressed = 0; Status = 'Unavailable (query failed)' }
    if ($null -eq $Current) { return $result }
    $result.Unreadable = $Current.Unreadable
    if ($Previous) { $result.Unreadable += $Previous.Unreadable }
    if ($null -eq $Previous -or $IntervalSeconds -le 0) {
        $result.Status = 'Baseline needed'
        return $result
    }

    $activity = New-Object System.Collections.Generic.List[object]
    foreach ($process in $Current.Processes.Values) {
        $before = $Previous.Processes[$process.Id]
        if ($null -eq $before -or $before.StartTicks -ne $process.StartTicks) {
            $result.Unmatched++
            continue
        }

        $delta = $process.CpuSeconds - $before.CpuSeconds
        if ($delta -lt 0) {
            $result.Regressed++
            continue
        }
        $result.Measured++
        if ($delta -eq 0) { continue }

        $activity.Add([pscustomobject]@{
            Id = $process.Id
            Name = $process.Name
            StartTicks = $process.StartTicks
            DeltaSeconds = $delta
            CpuPercent = 100 * $delta / $IntervalSeconds
        })
    }
    if ($result.Measured -gt 0) {
        $result.Status = 'Measured'
        $result.Top = @($activity | Sort-Object -Property @{ Expression = 'CpuPercent'; Descending = $true }, 'Id' | Select-Object -First 5)
    }
    else { $result.Status = 'Unavailable (no comparable process reads)' }
    return $result
}

function Get-WdtPerformanceMarkerKey {
    try {
        if ([System.Console]::IsInputRedirected) { return 'Unavailable' }
        if ([System.Console]::KeyAvailable) {
            $key = [System.Console]::ReadKey($true)
            if ($key.Key -eq [System.ConsoleKey]::M) { return 'Marked' }
        }
        return 'Pending'
    }
    catch { return 'Unavailable' }
}

function Wait-WdtPerformanceCapturePoint {
    param($Clock, [double]$TargetSeconds, [int]$DurationSeconds, $Marker, [bool]$Quiet)

    while ($true) {
        $elapsed = $Clock.Elapsed.TotalSeconds
        if ($Marker.Status -eq 'Pending' -and $elapsed -lt $DurationSeconds) {
            $Marker.Status = Get-WdtPerformanceMarkerKey
            if ($Marker.Status -eq 'Marked') {
                $Marker.ElapsedSeconds = $Clock.Elapsed.TotalSeconds
                $Marker.TimestampUtc = [datetime]::UtcNow
                if (-not $Quiet) { Write-Host 'Symptom marked.' }
            }
            elseif ($Marker.Status -eq 'Unavailable' -and -not $Quiet) {
                Write-Host 'Symptom marking is unavailable in this console. Recording continues.'
            }
        }

        $elapsed = $Clock.Elapsed.TotalSeconds
        if ($elapsed -ge $TargetSeconds) {
            return [pscustomobject]@{ ElapsedSeconds = $elapsed; TimestampUtc = [datetime]::UtcNow }
        }
        $waitMilliseconds = ($TargetSeconds - $elapsed) * 1000
        if ($Marker.Status -eq 'Pending') { $waitMilliseconds = [Math]::Min(100, $waitMilliseconds) }
        Start-Sleep -Milliseconds ([Math]::Max(1, [int]$waitMilliseconds))
    }
}

function Invoke-WdtPerformanceRecording {
    [CmdletBinding()]
    param(
        [ValidateRange(60, 120)][int]$DurationSeconds = 60,
        [switch]$InteractiveMarker,
        [switch]$Quiet
    )

    $intervalSeconds = 2
    $expectedSamples = [int][Math]::Floor(($DurationSeconds - 1) / $intervalSeconds) + 1
    $marker = [pscustomobject]@{
        Status = if ($InteractiveMarker) { 'Pending' } else { 'Not requested' }
        TimestampUtc = $null
        ElapsedSeconds = $null
    }
    if (-not $Quiet) {
        Write-Host ('Recording performance for {0} seconds.' -f $DurationSeconds)
        if ($InteractiveMarker) { Write-Host 'Press M when the symptom occurs to mark its time.' }
    }

    $startedAtUtc = [datetime]::UtcNow
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $samples = New-Object System.Collections.Generic.List[object]
    $previousSeconds = 0.0
    $previousProcesses = $null
    $previousDisk = $null
    $nextSeconds = 0
    $measured = 0
    $hasSourceGaps = $false
    while ($nextSeconds -lt $DurationSeconds) {
        $point = Wait-WdtPerformanceCapturePoint -Clock $clock -TargetSeconds $nextSeconds -DurationSeconds $DurationSeconds -Marker $marker -Quiet ([bool]$Quiet)
        if ($point.ElapsedSeconds -ge $DurationSeconds) { break }

        $processes = Get-WdtPerformanceProcessSnapshot
        $counters = Get-WdtPerformanceCounters
        $processInterval = Get-WdtPerformanceProcessInterval -Previous $previousProcesses -Current $processes -IntervalSeconds ($point.ElapsedSeconds - $previousSeconds)
        $diskInterval = Get-WdtPerformanceDiskInterval -Previous $previousDisk -Current $counters.DiskRaw -CurrentStatus $counters.DiskStatus
        $samples.Add([pscustomobject]@{
            TimestampUtc = $point.TimestampUtc
            ElapsedSeconds = $point.ElapsedSeconds
            CpuPercent = $counters.CpuPercent
            CpuStatus = $counters.CpuStatus
            MemoryAvailableMiB = $counters.MemoryAvailableMiB
            MemoryAvailablePercent = $counters.MemoryAvailablePercent
            MemoryStatus = $counters.MemoryStatus
            DiskLatencyMs = $diskInterval.LatencyMs
            DiskStatus = $diskInterval.Status
            ProcessActivity = $processInterval
        })
        $statuses = @($counters.CpuStatus, $counters.MemoryStatus, $diskInterval.Status, $processInterval.Status)
        $measured += @($statuses | Where-Object { $_ -eq 'Measured' }).Count
        if (@($statuses | Where-Object { $_ -like 'Unavailable*' }).Count -gt 0 -or $processInterval.Unreadable -gt 0 -or $processInterval.Regressed -gt 0) {
            $hasSourceGaps = $true
        }
        $previousDisk = $counters.DiskRaw
        $previousProcesses = $processes
        $previousSeconds = $point.ElapsedSeconds
        # Skip missed slots after a slow provider instead of issuing burst queries.
        $nextAlignedSeconds = ([Math]::Floor($clock.Elapsed.TotalSeconds / $intervalSeconds) + 1) * $intervalSeconds
        $nextSeconds = [Math]::Max($nextSeconds + $intervalSeconds, $nextAlignedSeconds)
    }

    $finished = Wait-WdtPerformanceCapturePoint -Clock $clock -TargetSeconds $DurationSeconds -DurationSeconds $DurationSeconds -Marker $marker -Quiet ([bool]$Quiet)
    if ($marker.Status -eq 'Pending') { $marker.Status = 'Not marked' }
    $completeness = if ($measured -eq 0) { 'Unavailable' }
        elseif ($hasSourceGaps -or $samples.Count -lt $expectedSamples) { 'Partial' }
        else { 'Complete' }

    return [pscustomobject]@{
        StartedAtUtc = $startedAtUtc
        FinishedAtUtc = $finished.TimestampUtc
        ElapsedSeconds = $finished.ElapsedSeconds
        DurationSeconds = $DurationSeconds
        IntervalSeconds = $intervalSeconds
        ExpectedSamples = $expectedSamples
        Marker = $marker
        Samples = @($samples.ToArray())
        Completeness = $completeness
        ExitCode = if ($completeness -eq 'Unavailable') { 1 } else { 0 }
    }
}

function Format-WdtPerformanceProcessLabel {
    param($Process, $Context)

    if ($null -ne $Context) {
        return Get-WdtRedactionToken -Context $Context -Category ID -Value ('process:{0}:{1}' -f $Process.Id, $Process.StartTicks)
    }
    $name = ConvertTo-WdtSingleLineText ($Process.Name -replace '[\p{Cc}\p{Cf}]', ' ')
    return '{0} (PID {1})' -f $name, $Process.Id
}

function Get-WdtPerformancePeakLines {
    param([object[]]$Samples, $Context)

    if ($Samples.Count -eq 0) { return '  No samples in this window.' }

    $cpuPeak = $Samples | Where-Object { $null -ne $_.CpuPercent } | Sort-Object -Property CpuPercent -Descending | Select-Object -First 1
    $ramPeak = $Samples | Where-Object { $null -ne $_.MemoryAvailablePercent } | Sort-Object -Property MemoryAvailablePercent | Select-Object -First 1
    $diskPeak = $Samples | Where-Object { $null -ne $_.DiskLatencyMs } | Sort-Object -Property DiskLatencyMs -Descending | Select-Object -First 1
    $processPeak = $null
    $processPeakTime = $null
    foreach ($sample in $Samples) {
        if ($sample.ProcessActivity.Top.Count -eq 0) { continue }
        $topProcess = $sample.ProcessActivity.Top[0]
        if ($null -eq $processPeak -or $topProcess.CpuPercent -gt $processPeak.CpuPercent) {
            $processPeak = $topProcess
            $processPeakTime = $sample.TimestampUtc
        }
    }

    if ($cpuPeak) { '  Highest CPU: {0:0.0}% at {1:o}' -f $cpuPeak.CpuPercent, $cpuPeak.TimestampUtc }
    else { '  Highest CPU: no measurement' }
    if ($ramPeak) { '  Lowest available RAM: {0:0.0}% ({1:0.0} MiB) at {2:o}' -f $ramPeak.MemoryAvailablePercent, $ramPeak.MemoryAvailableMiB, $ramPeak.TimestampUtc }
    else { '  Lowest available RAM: no measurement' }
    if ($diskPeak) { '  Highest disk latency: {0:0.000} ms at {1:o}' -f $diskPeak.DiskLatencyMs, $diskPeak.TimestampUtc }
    else { '  Highest disk latency: no measurement' }
    if ($processPeak) {
        $label = Format-WdtPerformanceProcessLabel -Process $processPeak -Context $Context
        '  Highest process CPU: {0}, {1:0.0}% of one logical CPU ({2:0.000} CPU s) at {3:o}' -f $label, $processPeak.CpuPercent, $processPeak.DeltaSeconds, $processPeakTime
    }
    else { '  Highest process CPU: no positive process CPU delta measured' }
}

function Format-WdtPerformanceRecording {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Recording,
        [switch]$PrivacyMode,
        $Context
    )

    if ($PrivacyMode -and $null -eq $Context) { $Context = New-WdtRedactionContext }
    $samples = $Recording.Samples
    $sampleCount = $samples.Count
    $marker = $Recording.Marker

    'Performance Recording'
    ''
    'Started (UTC): {0:o}' -f $Recording.StartedAtUtc
    'Finished (UTC): {0:o}' -f $Recording.FinishedAtUtc
    'Requested duration: {0} s' -f $Recording.DurationSeconds
    'Recorded duration: {0:0.0} s' -f $Recording.ElapsedSeconds
    'Sample interval: {0} s' -f $Recording.IntervalSeconds
    'Samples collected: {0}/{1}' -f $sampleCount, $Recording.ExpectedSamples
    'Completeness: {0}' -f $Recording.Completeness
    if ($marker.Status -eq 'Marked') { 'Symptom marker: {0:o} (+{1:0.000} s)' -f $marker.TimestampUtc, $marker.ElapsedSeconds }
    else { 'Symptom marker: {0}' -f $marker.Status }

    ''
    '== Source Coverage =='
    'CPU: {0}/{1} measured (Windows processor counter, total busy time)' -f @($samples | Where-Object { $_.CpuStatus -eq 'Measured' }).Count, $sampleCount
    'RAM: {0}/{1} measured (Windows available physical memory)' -f @($samples | Where-Object { $_.MemoryStatus -eq 'Measured' }).Count, $sampleCount
    'Disk latency: {0}/{1} measured (average completed physical disk transfer, all disks)' -f @($samples | Where-Object { $_.DiskStatus -eq 'Measured' }).Count, $sampleCount
    'Processes: {0}/{1} comparable intervals (up to 5 positive CPU deltas; 100% = one logical CPU)' -f @($samples | Where-Object { $_.ProcessActivity.Status -eq 'Measured' }).Count, $sampleCount
    if ($sampleCount -lt $Recording.ExpectedSamples) { 'Missed sample slots: {0}' -f ($Recording.ExpectedSamples - $sampleCount) }
    'Latency and CPU deltas need two readings. A disk interval with no completed transfers has no latency value.'
    'Process deltas require a matching PID and start time at both sample points.'

    ''
    '== Recording Peaks =='
    Get-WdtPerformancePeakLines -Samples $samples -Context $Context

    if ($marker.Status -eq 'Marked') {
        $before = @($samples | Where-Object { $_.ElapsedSeconds -ge ($marker.ElapsedSeconds - 10) -and $_.ElapsedSeconds -lt $marker.ElapsedSeconds })
        $after = @($samples | Where-Object { $_.ElapsedSeconds -ge $marker.ElapsedSeconds -and $_.ElapsedSeconds -le ($marker.ElapsedSeconds + 10) })
        ''
        '== Peaks Around Symptom Marker =='
        'Before marker (up to 10 s; {0} samples)' -f $before.Count
        Get-WdtPerformancePeakLines -Samples $before -Context $Context
        'At and after marker (up to 10 s; {0} samples)' -f $after.Count
        Get-WdtPerformancePeakLines -Samples $after -Context $Context
    }

    ''
    '== Timestamped Samples =='
    foreach ($sample in $samples) {
        $elapsed = $sample.ElapsedSeconds.ToString('0.000', [System.Globalization.CultureInfo]::InvariantCulture)
        '{0:o} (+{1} s)' -f $sample.TimestampUtc, $elapsed
        $cpu = if ($null -ne $sample.CpuPercent) { '{0:0.0}%' -f $sample.CpuPercent } else { $sample.CpuStatus }
        $ram = if ($null -ne $sample.MemoryAvailablePercent) { '{0:0.0}% ({1:0.0} MiB)' -f $sample.MemoryAvailablePercent, $sample.MemoryAvailableMiB } else { $sample.MemoryStatus }
        $disk = if ($null -ne $sample.DiskLatencyMs) { '{0:0.000} ms' -f $sample.DiskLatencyMs } else { $sample.DiskStatus }
        '  CPU: {0} | Available RAM: {1} | Disk latency: {2}' -f $cpu, $ram, $disk
        $processes = $sample.ProcessActivity
        '  Processes: {0} ({1} comparable, {2} unreadable reads, {3} without matching baseline, {4} regressed counters)' -f $processes.Status, $processes.Measured, $processes.Unreadable, $processes.Unmatched, $processes.Regressed
        foreach ($process in $processes.Top) {
            $label = Format-WdtPerformanceProcessLabel -Process $process -Context $Context
            '    {0}: {1:0.0}% of one logical CPU (+{2:0.000} CPU s)' -f $label, $process.CpuPercent, $process.DeltaSeconds
        }
    }
}
