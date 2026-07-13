[CmdletBinding()]
param(
    [ValidateRange(1, 99)]
    [int]$LowFreeSpacePercent = 15
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

function Get-PhysicalDiskInfo {
    $physicalDiskCommand = Get-Command -Name Get-PhysicalDisk -ErrorAction SilentlyContinue

    if ($null -ne $physicalDiskCommand) {
        $physicalDisks = $null
        try {
            $physicalDisks = Get-PhysicalDisk
        }
        catch {
            Write-Warning "Could not read physical disks with Get-PhysicalDisk. Some systems require elevated permissions for storage details. $($_.Exception.Message)"
        }

        if ($null -ne $physicalDisks) {
            foreach ($disk in $physicalDisks) {
                [pscustomobject]@{
                    FriendlyName = $disk.FriendlyName
                    Model        = if ($disk.Model) { $disk.Model } else { $disk.FriendlyName }
                    MediaType    = $disk.MediaType
                    HealthStatus = $disk.HealthStatus
                    Size         = $disk.Size
                    Source       = 'Get-PhysicalDisk'
                    StorageObject = $disk
                }
            }

            return
        }
    }

    try {
        Get-CimInstance -ClassName Win32_DiskDrive |
            ForEach-Object {
                [pscustomobject]@{
                    FriendlyName = $_.Caption
                    Model        = $_.Model
                    MediaType    = if ($_.MediaType) { $_.MediaType } else { 'Unknown' }
                    HealthStatus = if ($_.Status) { $_.Status } else { 'Unknown' }
                    Size         = $_.Size
                    Source       = 'Win32_DiskDrive'
                    StorageObject = $null
                }
            }
    }
    catch {
        Write-Warning "Could not read physical disks with CIM fallback. $($_.Exception.Message)"
        return $null
    }
}

function Get-StorageReliabilityData {
    param($StorageObject)
    if ($null -eq $StorageObject) {
        return [pscustomobject]@{ Available = $false; Data = $null; Note = 'Reliability counters are not exposed by this storage source.' }
    }
    if ($null -eq (Get-Command Get-StorageReliabilityCounter -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; Data = $null; Note = 'Get-StorageReliabilityCounter is unavailable.' }
    }
    try {
        $data = $StorageObject | Get-StorageReliabilityCounter -ErrorAction Stop
        if ($null -eq $data) { return [pscustomobject]@{ Available = $false; Data = $null; Note = 'The storage API returned no reliability counters.' } }
        return [pscustomobject]@{ Available = $true; Data = $data; Note = $null }
    }
    catch { return [pscustomobject]@{ Available = $false; Data = $null; Note = ('Reliability counters could not be read: {0}' -f $_.Exception.Message) } }
}

function Get-VolumeInfo {
    $volumeCommand = Get-Command -Name Get-Volume -ErrorAction SilentlyContinue

    if ($null -ne $volumeCommand) {
        $volumes = $null
        try {
            $volumes = Get-Volume | Where-Object { $_.DriveLetter }
        }
        catch {
            Write-Warning "Could not read volumes with Get-Volume. Some systems require elevated permissions for storage details. $($_.Exception.Message)"
        }

        if ($null -ne $volumes) {
            foreach ($volume in $volumes) {
                $size = $volume.Size
                $free = $volume.SizeRemaining
                $freePercent = $null

                if ($size -gt 0) {
                    $freePercent = ($free / $size) * 100
                }

                [pscustomobject]@{
                    DriveLetter = "$($volume.DriveLetter):"
                    Label       = $volume.FileSystemLabel
                    FileSystem  = $volume.FileSystem
                    Size        = $size
                    Free        = $free
                    FreePercent = $freePercent
                    Source      = 'Get-Volume'
                }
            }

            return
        }
    }

    try {
        Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' |
            ForEach-Object {
                $size = $_.Size
                $free = $_.FreeSpace
                $freePercent = $null

                if ($size -gt 0) {
                    $freePercent = ($free / $size) * 100
                }

                [pscustomobject]@{
                    DriveLetter = $_.DeviceID
                    Label       = $_.VolumeName
                    FileSystem  = $_.FileSystem
                    Size        = $size
                    Free        = $free
                    FreePercent = $freePercent
                    Source      = 'Win32_LogicalDisk'
                }
            }
    }
    catch {
        Write-Warning "Could not read logical disks with CIM fallback. $($_.Exception.Message)"
        return $null
    }
}

Write-Host 'Windows Diagnostics Toolkit - Storage Status'
Write-Host 'Mode: read-only'
Write-Host 'Scope: Windows-reported storage status, available reliability counters, and volume free space; not a complete SMART/NVMe diagnostic.'

$physicalDisks = @(Get-PhysicalDiskInfo)
$volumes = @(Get-VolumeInfo)

Write-Section 'Physical Disks'
if ($physicalDisks.Count -eq 0) {
    Write-Host 'No physical disk information available.'
    Write-Host 'Data availability: physical disk status is unavailable.'
}
else {
    foreach ($disk in $physicalDisks) {
        Write-Host ('Name         : {0}' -f $disk.FriendlyName)
        Write-Host ('Model        : {0}' -f $disk.Model)
        Write-Host ('Media type   : {0}' -f $disk.MediaType)
        Write-Host ('Health       : {0}' -f $disk.HealthStatus)
        Write-Host ('Size         : {0}' -f (Format-Bytes -Bytes $disk.Size))
        Write-Host ('Source       : {0}' -f $disk.Source)
        $reliability = Get-StorageReliabilityData -StorageObject $disk.StorageObject
        if ($reliability.Available) {
            Write-Host ('Reliability : Available')
            foreach ($metric in @('Temperature', 'Wear', 'ReadErrorsTotal', 'WriteErrorsTotal', 'PowerOnHours')) {
                if ($null -ne $reliability.Data.$metric) { Write-Host ('{0,-12}: {1}' -f $metric, $reliability.Data.$metric) }
            }
        }
        else {
            Write-Host 'Reliability : Unavailable (normal for some USB, RAID, virtual, and controller-backed disks)'
            if (-not [string]::IsNullOrWhiteSpace([string]$reliability.Note)) { Write-Host ('Collection note: {0}' -f $reliability.Note) }
        }

        $healthStatus = [string]$disk.HealthStatus
        if ([string]::IsNullOrWhiteSpace($healthStatus) -or $healthStatus -eq 'Unknown') {
            Write-Host ('Windows-reported state: Indeterminate (source: {0})' -f $disk.Source)
        }
        elseif ($healthStatus -eq 'Warning') {
            Write-WdtFinding -Severity 'WARN' -Code 'DISK_HEALTH_WARNING' -Message "Disk '$($disk.FriendlyName)' reports a warning health state." -Evidence "Health status: $healthStatus"
        }
        elseif ($healthStatus -notin @('Healthy', 'OK')) {
            Write-WdtFinding -Severity 'ERROR' -Code 'DISK_UNHEALTHY' -Message "Disk '$($disk.FriendlyName)' reports an unhealthy state." -Evidence "Health status: $healthStatus"
        }

        Write-Host ''
    }
}

Write-Section 'Volumes'
if ($volumes.Count -eq 0) {
    Write-Host 'No volume information available.'
    Write-Host 'Data availability: volume free-space data is unavailable.'
}
else {
    foreach ($volume in $volumes) {
        $freePercentText = if ($null -ne $volume.FreePercent) { '{0:N1}%' -f $volume.FreePercent } else { 'Unknown' }

        Write-Host ('Drive        : {0}' -f $volume.DriveLetter)
        Write-Host ('Label        : {0}' -f $volume.Label)
        Write-Host ('File system  : {0}' -f $volume.FileSystem)
        Write-Host ('Size         : {0}' -f (Format-Bytes -Bytes $volume.Size))
        Write-Host ('Free space   : {0}' -f (Format-Bytes -Bytes $volume.Free))
        Write-Host ('Free percent : {0}' -f $freePercentText)
        Write-Host ('Source       : {0}' -f $volume.Source)

        if ($null -ne $volume.FreePercent -and $volume.FreePercent -lt $LowFreeSpacePercent) {
            Write-Warning ("Drive {0} has less than {1}% free space." -f $volume.DriveLetter, $LowFreeSpacePercent)
            Write-WdtFinding -Severity 'WARN' -Code 'VOLUME_LOW_FREE_SPACE' -Message ("Drive {0} has less than {1}% free space." -f $volume.DriveLetter, $LowFreeSpacePercent) -Evidence ('Free space: {0:N1}%' -f $volume.FreePercent)
        }

        Write-Host ''
    }
}
