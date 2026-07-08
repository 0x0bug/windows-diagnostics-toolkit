[CmdletBinding()]
param(
    [ValidateRange(1, 99)]
    [int]$LowFreeSpacePercent = 15
)

$ErrorActionPreference = 'Stop'

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

function Invoke-SafeCommand {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$WarningMessage
    )

    try {
        return & $ScriptBlock
    }
    catch {
        Write-Warning "$WarningMessage $($_.Exception.Message)"
        return $null
    }
}

function Get-PhysicalDiskInfo {
    $physicalDiskCommand = Get-Command -Name Get-PhysicalDisk -ErrorAction SilentlyContinue

    if ($null -ne $physicalDiskCommand) {
        $physicalDisks = Invoke-SafeCommand -WarningMessage 'Could not read physical disks with Get-PhysicalDisk. Some systems require elevated permissions for storage details.' -ScriptBlock {
            Get-PhysicalDisk
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
                }
            }

            return
        }
    }

    Invoke-SafeCommand -WarningMessage 'Could not read physical disks with CIM fallback.' -ScriptBlock {
        Get-CimInstance -ClassName Win32_DiskDrive |
            ForEach-Object {
                [pscustomobject]@{
                    FriendlyName = $_.Caption
                    Model        = $_.Model
                    MediaType    = if ($_.MediaType) { $_.MediaType } else { 'Unknown' }
                    HealthStatus = if ($_.Status) { $_.Status } else { 'Unknown' }
                    Size         = $_.Size
                    Source       = 'Win32_DiskDrive'
                }
            }
    }
}

function Get-VolumeInfo {
    $volumeCommand = Get-Command -Name Get-Volume -ErrorAction SilentlyContinue

    if ($null -ne $volumeCommand) {
        $volumes = Invoke-SafeCommand -WarningMessage 'Could not read volumes with Get-Volume. Some systems require elevated permissions for storage details.' -ScriptBlock {
            Get-Volume | Where-Object { $_.DriveLetter }
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

    Invoke-SafeCommand -WarningMessage 'Could not read logical disks with CIM fallback.' -ScriptBlock {
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
}

Write-Host 'Windows Diagnostics Toolkit - Disk Health'
Write-Host 'Mode: read-only'

$physicalDisks = @(Get-PhysicalDiskInfo)
$volumes = @(Get-VolumeInfo)

Write-Section 'Physical Disks'
if ($physicalDisks.Count -eq 0) {
    Write-Host 'No physical disk information available.'
}
else {
    foreach ($disk in $physicalDisks) {
        Write-Host ('Name         : {0}' -f $disk.FriendlyName)
        Write-Host ('Model        : {0}' -f $disk.Model)
        Write-Host ('Media type   : {0}' -f $disk.MediaType)
        Write-Host ('Health       : {0}' -f $disk.HealthStatus)
        Write-Host ('Size         : {0}' -f (Format-Bytes -Bytes $disk.Size))
        Write-Host ('Source       : {0}' -f $disk.Source)
        Write-Host ''
    }
}

Write-Section 'Volumes'
if ($volumes.Count -eq 0) {
    Write-Host 'No volume information available.'
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
        }

        Write-Host ''
    }
}
