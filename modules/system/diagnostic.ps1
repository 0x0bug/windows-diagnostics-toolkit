[CmdletBinding()]
param()

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

function Get-CimData {
    param(
        [Parameter(Mandatory = $true)][string]$ClassName,
        [string]$Filter
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Filter)) {
            return Get-CimInstance -ClassName $ClassName
        }

        return Get-CimInstance -ClassName $ClassName -Filter $Filter
    }
    catch {
        Write-Warning "Could not read $ClassName. $($_.Exception.Message)"
        return $null
    }
}

function Convert-CimDateTime {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [datetime]) {
        return $Value
    }

    try {
        return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Value)
    }
    catch {
        Write-Warning "Could not parse CIM date value. $($_.Exception.Message)"
        Write-WdtFinding -Severity 'WARN' -Code 'SYSTEM_BOOT_TIME_UNAVAILABLE' -Message 'The last boot time could not be parsed, so uptime is unavailable.' -Evidence $_.Exception.Message
        return $null
    }
}

Write-Host 'Windows Diagnostics Toolkit - System Information'
Write-Host 'Mode: read-only'

$os = Get-CimData -ClassName 'Win32_OperatingSystem'
$computer = Get-CimData -ClassName 'Win32_ComputerSystem'
$processor = Get-CimData -ClassName 'Win32_Processor' | Select-Object -First 1
$gpuList = Get-CimData -ClassName 'Win32_VideoController'
$systemDrive = $env:SystemDrive
$systemDisk = $null

if (-not [string]::IsNullOrWhiteSpace($systemDrive)) {
    $driveLetter = $systemDrive.TrimEnd(':')
    $systemDisk = Get-CimData -ClassName 'Win32_LogicalDisk' -Filter "DeviceID='$($driveLetter):'"
}

Write-Section 'Windows'
if ($null -ne $os) {
    Write-Host ('Computer name : {0}' -f $env:COMPUTERNAME)
    Write-Host ('Caption       : {0}' -f $os.Caption)
    Write-Host ('Version       : {0}' -f $os.Version)
    Write-Host ('Build number  : {0}' -f $os.BuildNumber)

    $lastBoot = Convert-CimDateTime -Value $os.LastBootUpTime
    if ($null -ne $lastBoot) {
        $uptime = (Get-Date) - $lastBoot
        Write-Host ('Last boot     : {0}' -f $lastBoot)
        Write-Host ('Uptime        : {0} days, {1:00}:{2:00}:{3:00}' -f $uptime.Days, $uptime.Hours, $uptime.Minutes, $uptime.Seconds)
    }
}
else {
    Write-Host 'Windows details: unavailable'
    Write-WdtFinding -Severity 'WARN' -Code 'SYSTEM_OS_UNAVAILABLE' -Message 'Windows operating system details are unavailable.' -Evidence 'Source: Win32_OperatingSystem'
}

Write-Section 'Hardware'
if ($null -ne $processor) {
    Write-Host ('CPU           : {0}' -f $processor.Name)
}
else {
    Write-Host 'CPU           : unavailable'
    Write-WdtFinding -Severity 'WARN' -Code 'SYSTEM_CPU_UNAVAILABLE' -Message 'Processor details are unavailable.' -Evidence 'Source: Win32_Processor'
}

if ($null -ne $computer) {
    Write-Host ('Memory        : {0}' -f (Format-Bytes -Bytes $computer.TotalPhysicalMemory))
}
else {
    Write-Host 'Memory        : unavailable'
    Write-WdtFinding -Severity 'WARN' -Code 'SYSTEM_MEMORY_UNAVAILABLE' -Message 'Physical memory details are unavailable.' -Evidence 'Source: Win32_ComputerSystem'
}

if ($null -ne $gpuList) {
    foreach ($gpu in $gpuList) {
        Write-Host ('GPU           : {0}' -f $gpu.Name)
    }
}
else {
    Write-Host 'GPU           : unavailable'
    Write-WdtFinding -Severity 'WARN' -Code 'SYSTEM_GPU_UNAVAILABLE' -Message 'Graphics adapter details are unavailable.' -Evidence 'Source: Win32_VideoController'
}

Write-Section 'System Drive'
if ($null -ne $systemDisk) {
    Write-Host ('Drive         : {0}' -f $systemDisk.DeviceID)
    Write-Host ('File system   : {0}' -f $systemDisk.FileSystem)
    Write-Host ('Size          : {0}' -f (Format-Bytes -Bytes $systemDisk.Size))
    Write-Host ('Free space    : {0}' -f (Format-Bytes -Bytes $systemDisk.FreeSpace))

    if ($systemDisk.Size -gt 0) {
        $freePercent = ($systemDisk.FreeSpace / $systemDisk.Size) * 100
        Write-Host ('Free percent  : {0:N1}%' -f $freePercent)
    }
}
else {
    Write-Host 'System drive details: unavailable'
    Write-WdtFinding -Severity 'WARN' -Code 'SYSTEM_DRIVE_UNAVAILABLE' -Message 'System drive details are unavailable.' -Evidence 'Source: Win32_LogicalDisk'
}
