[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\..\..\scripts\report-common.ps1
. $PSScriptRoot\..\..\scripts\diagnostic-data.ps1

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

function Get-DisplayAdapterSource {
    param(
        [Parameter(Mandatory = $true)][string]$ClassName,
        [string]$Filter
    )

    $query = @{ ClassName = $ClassName; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
    if ($Filter) { $query.Filter = $Filter }

    $rows = New-Object System.Collections.Generic.List[object]
    $state = 'Complete'
    try {
        Get-CimInstance @query | ForEach-Object { $rows.Add($_) }
    }
    catch {
        # Provider diagnostics can contain raw device identifiers.
        $state = if ($rows.Count -gt 0) { 'Partial' } else { 'Unavailable' }
    }

    return [pscustomobject]@{ Name = $ClassName; State = $state; Rows = $rows.ToArray() }
}

function Get-DisplayAdapterText {
    param([string]$Value)

    $text = ($Value -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', ' ').Trim()
    # A provider can return a PnP path as a name when no friendly name is available.
    if ($text -and $text -notmatch '\\') { return $text }
}

function Get-DisplayAdapterProblemCode {
    param([string]$Value)

    if ($Value -match '^[0-9]{1,10}$' -and [uint64]$Value -le [uint32]::MaxValue) {
        return [uint32]$Value
    }
}

function Get-DisplayAdapterInventory {
    $classGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'
    $pnp = Get-DisplayAdapterSource -ClassName 'Win32_PnPEntity' -Filter "ClassGuid='$classGuid'"
    $video = Get-DisplayAdapterSource -ClassName 'Win32_VideoController'
    $drivers = Get-DisplayAdapterSource -ClassName 'Win32_PnPSignedDriver' -Filter "ClassGuid='$classGuid' OR DeviceClass='DISPLAY'"

    # Correlate by device instance, since multiple adapters can share a friendly name.
    $byInstanceId = @{}
    $adapters = New-Object System.Collections.Generic.List[object]
    foreach ($device in $pnp.Rows) {
        $instanceId = [string]$device.DeviceID
        if (-not $instanceId) { $instanceId = [string]$device.PNPDeviceID }
        if ($instanceId -and $byInstanceId.ContainsKey($instanceId)) { continue }

        $presence = 'Presence unknown'
        if ($device.Present -is [bool]) {
            $presence = if ($device.Present) { 'Present' } else { 'Previously enumerated / non-present' }
        }
        $adapter = [pscustomobject]@{
            Name           = Get-DisplayAdapterText $device.Name
            Presence       = $presence
            DriverProvider = $null
            DriverVersion  = $null
            ProblemCode    = Get-DisplayAdapterProblemCode $device.ConfigManagerErrorCode
        }
        $adapters.Add($adapter)
        if ($instanceId) { $byInstanceId[$instanceId] = $adapter }
    }

    foreach ($controller in $video.Rows) {
        $instanceId = [string]$controller.PNPDeviceID
        $adapter = if ($instanceId) { $byInstanceId[$instanceId] }
        if ($null -eq $adapter) {
            $adapter = [pscustomobject]@{
                Name           = $null
                Presence       = 'Presence unknown'
                DriverProvider = $null
                DriverVersion  = $null
                ProblemCode    = $null
            }
            $adapters.Add($adapter)
            if ($instanceId) { $byInstanceId[$instanceId] = $adapter }
        }
        if (-not $adapter.Name) { $adapter.Name = Get-DisplayAdapterText $controller.Name }
        if (-not $adapter.DriverVersion) { $adapter.DriverVersion = Get-DisplayAdapterText $controller.DriverVersion }
        if ($null -eq $adapter.ProblemCode) { $adapter.ProblemCode = Get-DisplayAdapterProblemCode $controller.ConfigManagerErrorCode }
    }

    foreach ($group in @($drivers.Rows | Where-Object { $_.DeviceID } | Group-Object -Property DeviceID)) {
        $adapter = $byInstanceId[$group.Name]
        # Leave ambiguous driver records unresolved for this instance.
        if ($null -eq $adapter -or $group.Count -ne 1) { continue }

        $driver = $group.Group[0]
        $adapter.DriverProvider = Get-DisplayAdapterText $driver.DriverProviderName
        $version = Get-DisplayAdapterText $driver.DriverVersion
        if ($version) { $adapter.DriverVersion = $version }
    }

    return [pscustomobject]@{ Adapters = $adapters.ToArray(); Sources = @($pnp, $video, $drivers) }
}

function Write-DisplayAdapterInventory {
    $inventory = Get-DisplayAdapterInventory

    Write-Section 'Graphics Adapters'
    foreach ($source in $inventory.Sources) {
        Write-Host ('{0}: {1} ({2} records)' -f $source.Name, $source.State, $source.Rows.Count)
    }

    if ($inventory.Adapters.Count -eq 0) {
        if ($inventory.Sources[0].State -eq 'Complete' -and $inventory.Sources[1].State -eq 'Complete') {
            Write-Host 'No display adapter records returned by Windows.'
        }
        else {
            Write-Host 'No display adapter records available from the collected sources.'
            Write-WdtFinding -Severity 'WARN' -Code 'SYSTEM_GPU_UNAVAILABLE' -Message 'Graphics adapter inventory could not be completed.' -Evidence 'Sources: Win32_PnPEntity, Win32_VideoController'
        }
        return
    }

    foreach ($presence in @('Present', 'Previously enumerated / non-present', 'Presence unknown')) {
        $adapters = @($inventory.Adapters | Where-Object { $_.Presence -eq $presence } | Sort-Object -Property Name)
        Write-Host ''
        Write-Host ('{0}: {1} reported' -f $presence, $adapters.Count)
        foreach ($adapter in $adapters) {
            $name = if ($adapter.Name) { $adapter.Name } else { 'Unnamed display adapter' }
            $provider = if ($adapter.DriverProvider) { $adapter.DriverProvider } else { 'Unknown' }
            $version = if ($adapter.DriverVersion) { $adapter.DriverVersion } else { 'Unknown' }
            $code = if ($null -ne $adapter.ProblemCode) { $adapter.ProblemCode } else { 'Unknown' }
            Write-Host ('  GPU             : {0}' -f $name)
            Write-Host ('  Driver provider : {0}' -f $provider)
            Write-Host ('  Driver version  : {0}' -f $version)
            Write-Host ('  Problem code    : {0}' -f $code)

            if ($presence -eq 'Present' -and $null -ne $adapter.ProblemCode -and $adapter.ProblemCode -ne 0) {
                Write-WdtFinding -Severity 'WARN' -Code 'SYSTEM_GPU_PROBLEM' -Message 'Windows reported a device problem code for a present display adapter.' -Evidence ('Adapter={0}; ConfigManagerErrorCode={1}' -f $name, $code)
            }
        }
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
$dataRequest = Get-WdtDataRequest
if ($dataRequest.Enabled) {
    $available = if ($null -ne $os) { 'Available' } else { 'Unavailable' }
    $knownVersion = $null -ne $os -and -not [string]::IsNullOrWhiteSpace([string]$os.Version) -and -not [string]::IsNullOrWhiteSpace([string]$os.BuildNumber)
    $source = New-WdtDataSource -Id 'os' -Kind Configuration -Scope 'Win32_OperatingSystem.Version.BuildNumber' -Availability $available -QueryComplete ($null -ne $os) -Coverage CurrentState
    $fact = New-WdtDataFact -Id f1 -Type OsVersion -Key 'windows-version' -ValueState $(if ($knownVersion) { 'Known' } else { 'Unknown' }) -Values @{Version=$(if ($knownVersion) {[string]$os.Version} else {$null}); Build=$(if ($knownVersion) {[string]$os.BuildNumber} else {$null})} -Comparison Configuration -SourceIds @('os')
    Write-WdtDiagnosticData (New-WdtDiagnosticData -ModuleId System -Sources @($source) -Facts @($fact))
}
$computer = Get-CimData -ClassName 'Win32_ComputerSystem'
$processor = Get-CimData -ClassName 'Win32_Processor' | Select-Object -First 1
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

Write-DisplayAdapterInventory

Write-Section 'System Drive'
if ($null -ne $systemDisk) {
    Write-Host ('Drive         : {0}' -f $systemDisk.DeviceID)
    Write-Host ('File system   : {0}' -f $systemDisk.FileSystem)
    Write-Host ('Size          : {0}' -f (Format-Bytes -Bytes $systemDisk.Size))
    Write-Host ('Free space    : {0}' -f (Format-Bytes -Bytes $systemDisk.FreeSpace))

    $freePercent = Get-WdtAvailablePercent -Available $systemDisk.FreeSpace -Total $systemDisk.Size
    $freePercentText = if ($null -eq $freePercent) { 'Unknown' } else { '{0:N1}%' -f $freePercent }
    Write-Host ('Free percent  : {0}' -f $freePercentText)
}
else {
    Write-Host 'System drive details: unavailable'
    Write-WdtFinding -Severity 'WARN' -Code 'SYSTEM_DRIVE_UNAVAILABLE' -Message 'System drive details are unavailable.' -Evidence 'Source: Win32_LogicalDisk'
}
