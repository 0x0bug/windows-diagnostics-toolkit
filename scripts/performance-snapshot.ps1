[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$TopProcessCount = 10,

    [ValidateRange(1, 99)]
    [int]$LowMemoryPercent = 15,

    [ValidateRange(1, 100)]
    [int]$HighCpuPercent = 95
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'report-common.ps1')

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

function Write-PerformanceFindings {
    param(
        [Nullable[double]]$MemoryAvailablePercent,
        [Nullable[double]]$CpuPercent,
        [Nullable[double]]$PagefilePercent,
        [Parameter(Mandatory = $true)][int]$MemoryWarningPercent,
        [Parameter(Mandatory = $true)][int]$CpuWarningPercent,
        [string[]]$UnavailableSources = @()
    )

    foreach ($source in @($UnavailableSources)) {
        switch ($source) {
            'Memory' {
                Write-WdtFinding -Severity WARN -Code 'PERFORMANCE_MEMORY_UNAVAILABLE' -Message 'Memory availability is unavailable.'
            }
            'Cpu' {
                Write-WdtFinding -Severity WARN -Code 'PERFORMANCE_CPU_UNAVAILABLE' -Message 'CPU snapshot is unavailable.'
            }
            'Pagefile' {
                Write-WdtFinding -Severity WARN -Code 'PERFORMANCE_PAGEFILE_UNAVAILABLE' -Message 'Pagefile usage is unavailable.'
            }
            'Processes' {
                Write-WdtFinding -Severity WARN -Code 'PERFORMANCE_PROCESS_LIST_UNAVAILABLE' -Message 'Process snapshot is unavailable.'
            }
        }
    }

    if ($null -ne $MemoryAvailablePercent) {
        if ($MemoryAvailablePercent -lt 5) {
            Write-WdtFinding -Severity ERROR -Code 'PERFORMANCE_MEMORY_CRITICAL' -Message 'Available physical memory is below 5 percent.' -Evidence ('Available={0:N1}%' -f $MemoryAvailablePercent)
        }
        elseif ($MemoryAvailablePercent -lt $MemoryWarningPercent) {
            Write-WdtFinding -Severity WARN -Code 'PERFORMANCE_MEMORY_LOW' -Message 'Available physical memory is below the warning threshold.' -Evidence ('Available={0:N1}%; Threshold={1}%' -f $MemoryAvailablePercent, $MemoryWarningPercent)
        }
    }

    if ($null -ne $CpuPercent -and $CpuPercent -ge $CpuWarningPercent) {
        Write-WdtFinding -Severity WARN -Code 'PERFORMANCE_CPU_HIGH' -Message 'CPU snapshot is at or above the warning threshold.' -Evidence ('CPU={0:N1}%; Threshold={1}%' -f $CpuPercent, $CpuWarningPercent)
    }

    if ($null -ne $PagefilePercent -and $PagefilePercent -ge 80) {
        Write-WdtFinding -Severity WARN -Code 'PERFORMANCE_PAGEFILE_HIGH' -Message 'Pagefile usage is at or above 80 percent.' -Evidence ('Pagefile={0:N1}%' -f $PagefilePercent)
    }
}

function Get-MemorySnapshot {
    try {
        $operatingSystem = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
        $totalKilobytes = [double]$operatingSystem.TotalVisibleMemorySize
        $freeKilobytes = [double]$operatingSystem.FreePhysicalMemory
        if ($totalKilobytes -le 0) {
            throw 'Win32_OperatingSystem reported no visible memory.'
        }

        return [pscustomobject]@{
            TotalBytes       = $totalKilobytes * 1KB
            AvailableBytes   = $freeKilobytes * 1KB
            AvailablePercent = ($freeKilobytes / $totalKilobytes) * 100
            Error            = $null
        }
    }
    catch {
        return [pscustomobject]@{
            TotalBytes       = $null
            AvailableBytes   = $null
            AvailablePercent = $null
            Error            = $_.Exception.Message
        }
    }
}

function Get-CpuSnapshot {
    try {
        $samples = @(Get-CimInstance -ClassName 'Win32_Processor' -ErrorAction Stop |
                ForEach-Object { $_.LoadPercentage } |
                Where-Object { $null -ne $_ })
        if ($samples.Count -eq 0) {
            throw 'Win32_Processor returned no CPU load samples.'
        }

        return [pscustomobject]@{
            Percent = ($samples | Measure-Object -Average).Average
            Error   = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Percent = $null
            Error   = $_.Exception.Message
        }
    }
}

function Get-PagefileSnapshot {
    try {
        $pagefiles = @(Get-CimInstance -ClassName 'Win32_PageFileUsage' -ErrorAction Stop)
        if ($pagefiles.Count -eq 0) {
            throw 'No pagefile usage records were returned.'
        }

        $allocatedMegabytes = [double](($pagefiles | Measure-Object -Property AllocatedBaseSize -Sum).Sum)
        $usedMegabytes = [double](($pagefiles | Measure-Object -Property CurrentUsage -Sum).Sum)
        if ($allocatedMegabytes -le 0) {
            throw 'Pagefile allocation is zero.'
        }

        return [pscustomobject]@{
            AllocatedMegabytes = $allocatedMegabytes
            UsedMegabytes      = $usedMegabytes
            UsedPercent        = ($usedMegabytes / $allocatedMegabytes) * 100
            Error              = $null
        }
    }
    catch {
        return [pscustomobject]@{
            AllocatedMegabytes = $null
            UsedMegabytes      = $null
            UsedPercent        = $null
            Error              = $_.Exception.Message
        }
    }
}

function Get-ProcessSnapshot {
    try {
        $processes = New-Object System.Collections.Generic.List[object]
        foreach ($process in @(Get-Process -ErrorAction Stop)) {
            $workingSet = $null
            $cpuTime = $null

            try {
                $workingSet = [int64]$process.WorkingSet64
            }
            catch {
                # Some protected processes do not expose all counters.
            }

            try {
                if ($null -ne $process.CPU) {
                    $cpuTime = [double]$process.CPU
                }
            }
            catch {
                # Keep the process name while omitting an inaccessible CPU value.
            }

            $processes.Add([pscustomobject]@{
                    Name       = $process.ProcessName
                    WorkingSet = $workingSet
                    CpuTime    = $cpuTime
                })
        }

        return [pscustomobject]@{
            Processes = @($processes.ToArray())
            Error     = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Processes = @()
            Error     = $_.Exception.Message
        }
    }
}

function Write-ProcessList {
    param(
        [Parameter(Mandatory = $true)][object[]]$Processes,
        [Parameter(Mandatory = $true)][string]$Metric,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    $shown = @($Processes |
            Where-Object { $null -ne $_.$Metric } |
            Sort-Object -Property @{ Expression = $Metric; Descending = $true } |
            Select-Object -First $Limit)

    if ($shown.Count -eq 0) {
        Write-Host 'No process values are available.'
        return
    }

    foreach ($process in $shown) {
        if ($Metric -eq 'WorkingSet') {
            Write-Host ('{0,-32} {1,14}' -f $process.Name, (Format-Bytes -Bytes $process.WorkingSet))
        }
        else {
            Write-Host ('{0,-32} {1,14:N2} s' -f $process.Name, $process.CpuTime)
        }
    }
}

function Invoke-PerformanceSnapshot {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessLimit,
        [Parameter(Mandatory = $true)][int]$MemoryWarningPercent,
        [Parameter(Mandatory = $true)][int]$CpuWarningPercent
    )

    Write-Host 'Windows Diagnostics Toolkit - Performance Snapshot'
    Write-Host 'Mode: read-only'

    $memory = Get-MemorySnapshot
    $cpu = Get-CpuSnapshot
    $pagefile = Get-PagefileSnapshot
    $processes = Get-ProcessSnapshot

    Write-Section 'Memory'
    if ($null -ne $memory.Error) {
        Write-Host ('Unavailable: {0}' -f $memory.Error)
    }
    else {
        Write-Host ('Total physical memory : {0}' -f (Format-Bytes -Bytes $memory.TotalBytes))
        Write-Host ('Available memory      : {0}' -f (Format-Bytes -Bytes $memory.AvailableBytes))
        Write-Host ('Available percent     : {0:N1}%' -f $memory.AvailablePercent)
    }

    Write-Section 'CPU Snapshot'
    if ($null -ne $cpu.Error) {
        Write-Host ('Unavailable: {0}' -f $cpu.Error)
    }
    else {
        Write-Host ('Total CPU load : {0:N1}%' -f $cpu.Percent)
    }

    Write-Section 'Pagefile Usage'
    if ($null -ne $pagefile.Error) {
        Write-Host ('Unavailable: {0}' -f $pagefile.Error)
    }
    else {
        Write-Host ('Allocated : {0:N0} MB' -f $pagefile.AllocatedMegabytes)
        Write-Host ('Used      : {0:N0} MB' -f $pagefile.UsedMegabytes)
        Write-Host ('Usage     : {0:N1}%' -f $pagefile.UsedPercent)
    }

    Write-Section 'Top Processes by Working Set'
    Write-ProcessList -Processes $processes.Processes -Metric 'WorkingSet' -Limit $ProcessLimit

    Write-Section 'Top Processes by CPU Time'
    Write-ProcessList -Processes $processes.Processes -Metric 'CpuTime' -Limit $ProcessLimit

    $unavailableSources = New-Object System.Collections.Generic.List[string]
    if ($null -ne $memory.Error) {
        $unavailableSources.Add('Memory')
    }
    if ($null -ne $cpu.Error) {
        $unavailableSources.Add('Cpu')
    }
    if ($null -ne $pagefile.Error) {
        $unavailableSources.Add('Pagefile')
    }
    if ($null -ne $processes.Error) {
        $unavailableSources.Add('Processes')
    }

    Write-PerformanceFindings `
        -MemoryAvailablePercent $memory.AvailablePercent `
        -CpuPercent $cpu.Percent `
        -PagefilePercent $pagefile.UsedPercent `
        -MemoryWarningPercent $MemoryWarningPercent `
        -CpuWarningPercent $CpuWarningPercent `
        -UnavailableSources @($unavailableSources.ToArray())
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PerformanceSnapshot -ProcessLimit $TopProcessCount -MemoryWarningPercent $LowMemoryPercent -CpuWarningPercent $HighCpuPercent
}
