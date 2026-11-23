[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$systemScript = Join-Path $root 'modules\system\diagnostic.ps1'
. (Join-Path $root 'scripts\diagnostic-data.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-SystemFixture {
    param([string]$Scenario)

    function Get-CimInstance {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter)

        $presentId = 'PCI\VEN_1234&DEV_0001\PRIVATE-CURRENT'
        $historicalId = 'PCI\VEN_1234&DEV_0001\PRIVATE-HISTORICAL'
        $otherId = 'PCI\VEN_1234&DEV_0001\PRIVATE-OTHER'
        switch ($ClassName) {
            'Win32_OperatingSystem' { [pscustomobject]@{ Caption = 'Fixture Windows'; Version = '10.0'; BuildNumber = '26100' } }
            'Win32_ComputerSystem' { [pscustomobject]@{ TotalPhysicalMemory = 4294967296 } }
            'Win32_Processor' { [pscustomobject]@{ Name = 'Fixture CPU' } }
            'Win32_LogicalDisk' { [pscustomobject]@{ DeviceID = 'C:'; FileSystem = 'NTFS'; Size = 1000000; FreeSpace = 200000 } }
            'Win32_PnPEntity' {
                Assert-True ($Filter -eq "ClassGuid='{4d36e968-e325-11ce-bfc1-08002be10318}'") 'PnP inventory must be scoped to the Display setup class.'
                if ($Scenario -eq 'Mixed') {
                    [pscustomobject]@{ Name = 'Shared GPU'; DeviceID = $presentId; Present = $true; ConfigManagerErrorCode = [uint32]43 }
                    [pscustomobject]@{ Name = 'Working GPU'; DeviceID = $otherId; Present = $true; ConfigManagerErrorCode = [uint32]0 }
                    [pscustomobject]@{ Name = $otherId; DeviceID = 'ROOT\DISPLAY\PRIVATE-UNNAMED'; Present = $null; Status = 'OK' }
                }
                if ($Scenario -in @('Mixed', 'HistoricalOnly')) {
                    [pscustomobject]@{ Name = 'Shared GPU'; DeviceID = $historicalId; Present = $false; ConfigManagerErrorCode = [uint32]45 }
                }
                if ($Scenario -eq 'Partial') {
                    [pscustomobject]@{ Name = 'Collected before error'; DeviceID = $presentId; Present = $true }
                }
                if ($Scenario -in @('Partial', 'Fallback', 'Unavailable')) { throw "Failed to read device $presentId" }
            }
            'Win32_VideoController' {
                if ($Scenario -eq 'Mixed') {
                    [pscustomobject]@{ Name = 'Controller alias'; PNPDeviceID = $presentId.ToLowerInvariant(); ConfigManagerErrorCode = 0; DriverVersion = 'old version' }
                    [pscustomobject]@{ Name = 'Controller alias'; PNPDeviceID = $otherId; ConfigManagerErrorCode = 22; DriverVersion = '3.1.0.0'; AdapterCompatibility = 'GPU manufacturer' }
                }
                if ($Scenario -eq 'Fallback') {
                    [pscustomobject]@{ Name = 'Fallback GPU'; PNPDeviceID = $otherId; DriverVersion = '4.0.0.0'; ConfigManagerErrorCode = 31; Status = 'Error' }
                }
                if ($Scenario -eq 'Unavailable') { throw "Failed to read device $otherId" }
            }
            'Win32_PnPSignedDriver' {
                if ($Scenario -eq 'Mixed') {
                    [pscustomobject]@{ DeviceID = $historicalId; DriverProviderName = 'Historical Provider'; DriverVersion = '1.2.0.0' }
                    [pscustomobject]@{ DeviceID = $presentId.ToLowerInvariant(); DriverProviderName = 'Current Provider'; DriverVersion = '2.4.0.0' }
                    [pscustomobject]@{ DeviceID = 'ROOT\DISPLAY\PRIVATE-ORPHAN'; DeviceName = 'Driver-only Ghost'; DriverProviderName = 'Wrong Provider'; DriverVersion = '7.5.0.0' }
                }
                if ($Scenario -in @('Partial', 'Unavailable')) { throw "Failed to read driver for $presentId" }
            }
        }
    }

    return ((& $systemScript 3>&1 6>&1 | ForEach-Object { [string]$_ }) -join "`n")
}

$savedEnvironment = @{}
foreach ($name in @('WDT_FINDING_PROTOCOL', 'WDT_FINDING_NONCE', 'SystemDrive', 'WDT_DATA_PROTOCOL', 'WDT_DATA_NONCE', 'WDT_DATA_MODULE', 'WDT_DATA_START_UTC', 'WDT_DATA_END_UTC')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$consoleWriter = [Console]::Out
$frameWriter = New-Object System.IO.StringWriter
$dataNonce = '0123456789abcdef0123456789abcdef'
try {
    $env:WDT_FINDING_PROTOCOL = '1'
    $env:WDT_FINDING_NONCE = $null
    $env:SystemDrive = 'C:'
    $env:WDT_DATA_PROTOCOL = $null
    $mixed = Invoke-SystemFixture 'Mixed'
    $historical = Invoke-SystemFixture 'HistoricalOnly'
    $partial = Invoke-SystemFixture 'Partial'
    $fallback = Invoke-SystemFixture 'Fallback'
    $empty = Invoke-SystemFixture 'Empty'
    $unavailable = Invoke-SystemFixture 'Unavailable'

    $env:WDT_DATA_PROTOCOL = '1'
    $env:WDT_DATA_NONCE = $dataNonce
    $env:WDT_DATA_MODULE = 'System'
    $env:WDT_DATA_START_UTC = $null
    $env:WDT_DATA_END_UTC = $null
    [Console]::SetOut($frameWriter)
    $unavailableWithData = Invoke-SystemFixture 'Unavailable'
}
finally {
    [Console]::SetOut($consoleWriter)
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
}
$frames = @($frameWriter.ToString() -split '\r?\n' | Where-Object { $_ })
$frameWriter.Dispose()
$snapshot = Resolve-WdtDiagnosticData -OutputLines $frames -Nonce $dataNonce -ExpectedModuleId 'System'

Assert-True ($mixed -match 'Present: 2 reported') 'Present display adapters must be counted without duplicating matching video controller records.'
Assert-True ($mixed -match 'Previously enumerated / non-present: 1 reported') 'A non-present PnP adapter must be listed in its own group.'
Assert-True ($mixed -match 'Presence unknown: 1 reported') 'A missing presence flag must remain unknown even with an OK status.'
Assert-True ($mixed -match 'GPU\s+: Shared GPU\n  Driver provider : Current Provider\n  Driver version  : 2\.4\.0\.0\n  Problem code    : 43') 'The present adapter must receive its exact matching driver details and PnP problem code.'
Assert-True ($mixed -match 'GPU\s+: Shared GPU\n  Driver provider : Historical Provider\n  Driver version  : 1\.2\.0\.0\n  Problem code    : 45') 'Historical driver data must stay associated with the correct instance despite equal display names.'
Assert-True ($mixed -match 'GPU\s+: Working GPU\n  Driver provider : Unknown\n  Driver version  : 3\.1\.0\.0\n  Problem code    : 0') 'Video version may fill a gap, but hardware manufacturer cannot stand in for the provider and a known zero cannot be overwritten.'
Assert-True ($mixed -match 'GPU\s+: Unnamed display adapter\n  Driver provider : Unknown\n  Driver version  : Unknown\n  Problem code    : Unknown') 'A raw device ID cannot be used as a name, and undefined properties must remain unknown.'
Assert-True ($mixed -notmatch 'Controller alias|Driver-only Ghost|Wrong Provider') 'Supplemental sources duplicated records or emitted a driver-only device.'
Assert-True (([regex]::Matches($mixed, 'SYSTEM_GPU_PROBLEM')).Count -eq 1) 'Only the confirmed problem of a present device may produce a GPU problem finding.'
Assert-True ($historical -notmatch 'SYSTEM_GPU_PROBLEM|SYSTEM_GPU_UNAVAILABLE') 'Historical device codes alone do not indicate a current GPU problem.'

Assert-True ($partial -match 'Win32_PnPEntity: Partial' -and $partial -match 'Win32_PnPSignedDriver: Unavailable') 'A source failure after yielding a record must be distinct from a source that failed entirely.'
Assert-True ($partial -match 'Present: 1 reported' -and $partial -match 'Collected before error') 'A source failure must preserve the usable records already read.'
Assert-True ($fallback -match 'Win32_PnPEntity: Unavailable' -and $fallback -match 'Presence unknown: 1 reported') 'A video controller with no PnP match must remain visible with unknown presence.'
Assert-True ($fallback -match 'Driver version  : 4\.0\.0\.0' -and $fallback -match 'Problem code    : 31' -and $fallback -notmatch 'SYSTEM_GPU_PROBLEM') 'A video controller problem code must remain context when presence is unknown.'

Assert-True ($empty -match 'No display adapter records returned by Windows\.' -and $empty -notmatch 'SYSTEM_GPU_UNAVAILABLE') 'Complete but empty inventory must be reported without a failure warning.'
Assert-True ($unavailable -match 'No display adapter records available from the collected sources\.' -and $unavailable -match 'SYSTEM_GPU_UNAVAILABLE') 'An unavailable inventory must retain the legacy diagnostic finding.'
Assert-True (($mixed + $partial + $fallback + $unavailable) -notmatch 'PRIVATE-|VEN_1234') 'Reports and findings must exclude device instance identifiers, including those in provider error messages.'
Assert-True ($mixed -match 'Fixture Windows' -and $mixed -match 'Fixture CPU' -and $mixed -match '== System Drive ==') 'GPU reporting must preserve the other System checks.'
Assert-True ($unavailableWithData -eq $unavailable) 'Collecting snapshot data must preserve the rendered System checks.'
Assert-True ($snapshot.DataStatus -eq 'Available' -and $snapshot.Data.Sources.Count -eq 1 -and $snapshot.Data.Facts.Count -eq 1) 'GPU provider failures must not change the System snapshot contract.'
Assert-True ($snapshot.Data.Facts[0].Type -eq 'OsVersion' -and $snapshot.Data.Facts[0].Values.Build -eq '26100') 'The legacy OS version fact must still be available.'

Write-Host 'System graphics adapter tests passed.'
