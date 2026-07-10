[CmdletBinding()]
param(
    [string]$DnsTestName = 'github.com',
    [string]$InternetTestHost = '8.8.8.8',
    [int]$TimeoutSeconds = 3
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'report-common.ps1')

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Write-Host ''
    Write-Host "== $Title =="
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

function Join-ValuesOrNone {
    param([object[]]$Values)

    $filteredValues = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    if ($filteredValues.Count -eq 0) {
        return 'None'
    }

    return ($filteredValues -join ', ')
}

function Get-AdapterConfiguration {
    $netAdapterCommand = Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue

    if ($null -ne $netAdapterCommand) {
        $adapters = Invoke-SafeCommand -WarningMessage 'Could not read network adapters.' -ScriptBlock {
            Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        }

        if ($null -ne $adapters) {
            foreach ($adapter in $adapters) {
                $ipConfig = Invoke-SafeCommand -WarningMessage "Could not read IP configuration for adapter '$($adapter.Name)'." -ScriptBlock {
                    Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex
                }

                [pscustomobject]@{
                    Name        = $adapter.Name
                    Description = $adapter.InterfaceDescription
                    Status      = $adapter.Status
                    MacAddress  = Join-ValuesOrNone -Values $adapter.MacAddress
                    IPv4        = Join-ValuesOrNone -Values $ipConfig.IPv4Address.IPAddress
                    IPv6        = Join-ValuesOrNone -Values $ipConfig.IPv6Address.IPAddress
                    Gateway     = Join-ValuesOrNone -Values $ipConfig.IPv4DefaultGateway.NextHop
                    DnsServers  = Join-ValuesOrNone -Values $ipConfig.DNSServer.ServerAddresses
                }
            }
        }

        return
    }

    Invoke-SafeCommand -WarningMessage 'Get-NetAdapter is unavailable. Falling back to CIM network configuration failed.' -ScriptBlock {
        Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' |
            ForEach-Object {
                [pscustomobject]@{
                    Name        = $_.Description
                    Description = $_.Description
                    Status      = 'Up'
                    MacAddress  = Join-ValuesOrNone -Values $_.MACAddress
                    IPv4        = Join-ValuesOrNone -Values ($_.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
                    IPv6        = Join-ValuesOrNone -Values ($_.IPAddress | Where-Object { $_ -notmatch '^\d{1,3}(\.\d{1,3}){3}$' })
                    Gateway     = Join-ValuesOrNone -Values $_.DefaultIPGateway
                    DnsServers  = Join-ValuesOrNone -Values $_.DNSServerSearchOrder
                }
            }
    }
}

function Test-HostReachability {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$Timeout = 3
    )

    if ([string]::IsNullOrWhiteSpace($Target) -or $Target -eq 'None') {
        return 'Skipped'
    }

    $testConnectionCommand = Get-Command -Name Test-Connection -ErrorAction SilentlyContinue
    if ($null -eq $testConnectionCommand) {
        return 'Unavailable'
    }

    try {
        $parameters = @{
            ComputerName = $Target
            Count        = 1
            Quiet        = $true
            ErrorAction  = 'Stop'
        }

        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $parameters.TimeoutSeconds = $Timeout
        }

        if (Test-Connection @parameters) {
            return 'Reachable'
        }

        return 'Not reachable'
    }
    catch {
        return "Failed: $($_.Exception.Message)"
    }
}

function Test-DnsResolution {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'Skipped'
    }

    $resolveDnsCommand = Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue
    if ($null -ne $resolveDnsCommand) {
        try {
            $records = Resolve-DnsName -Name $Name -ErrorAction Stop
            $addresses = $records |
                Where-Object { $_.IPAddress } |
                Select-Object -ExpandProperty IPAddress -Unique

            if ($addresses) {
                return "Resolved: $($addresses -join ', ')"
            }

            return 'Resolved without address records'
        }
        catch {
            return "Failed: $($_.Exception.Message)"
        }
    }

    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($Name) | ForEach-Object { $_.IPAddressToString }
        if ($addresses) {
            return "Resolved: $($addresses -join ', ')"
        }

        return 'Failed: no address records'
    }
    catch {
        return "Failed: $($_.Exception.Message)"
    }
}

Write-Host 'Windows Diagnostics Toolkit - Network Check'
Write-Host 'Mode: read-only'

$adapterConfigurations = @(Get-AdapterConfiguration)

Write-Section 'Active Network Adapters'
if ($adapterConfigurations.Count -eq 0) {
    Write-Host 'No active network adapters found.'
    Write-WdtFinding -Severity 'WARN' -Code 'NETWORK_NO_ACTIVE_ADAPTER' -Message 'No active network adapters were found.'
}
else {
    foreach ($adapter in $adapterConfigurations) {
        Write-Host ('Name        : {0}' -f $adapter.Name)
        Write-Host ('Description : {0}' -f $adapter.Description)
        Write-Host ('Status      : {0}' -f $adapter.Status)
        Write-Host ('MAC         : {0}' -f $adapter.MacAddress)
        Write-Host ('IPv4        : {0}' -f $adapter.IPv4)
        Write-Host ('IPv6        : {0}' -f $adapter.IPv6)
        Write-Host ('Gateway     : {0}' -f $adapter.Gateway)
        Write-Host ('DNS servers : {0}' -f $adapter.DnsServers)
        Write-Host ''
    }
}

Write-Section 'Gateway Reachability'
$gateways = $adapterConfigurations |
    ForEach-Object { $_.Gateway -split ', ' } |
    Where-Object { $_ -and $_ -ne 'None' } |
    Select-Object -Unique

if ($gateways) {
    foreach ($gateway in $gateways) {
        $gatewayResult = Test-HostReachability -Target $gateway -Timeout $TimeoutSeconds
        Write-Host ('{0}: {1}' -f $gateway, $gatewayResult)

        if ($gatewayResult -ne 'Reachable') {
            Write-WdtFinding -Severity 'WARN' -Code 'NETWORK_GATEWAY_UNREACHABLE' -Message "The default gateway '$gateway' is not reachable." -Evidence $gatewayResult
        }
    }
}
else {
    Write-Host 'No IPv4 gateway detected.'
    Write-WdtFinding -Severity 'WARN' -Code 'NETWORK_NO_GATEWAY' -Message 'No IPv4 default gateway was detected.'
}

Write-Section 'DNS Resolution'
$dnsResult = Test-DnsResolution -Name $DnsTestName
Write-Host ('{0}: {1}' -f $DnsTestName, $dnsResult)

if ($dnsResult -ne 'Skipped' -and $dnsResult -notmatch '^Resolved:') {
    Write-WdtFinding -Severity 'WARN' -Code 'NETWORK_DNS_FAILED' -Message "DNS resolution failed for '$DnsTestName'." -Evidence $dnsResult
}

Write-Section 'Internet Connectivity'
$internetResult = Test-HostReachability -Target $InternetTestHost -Timeout $TimeoutSeconds
Write-Host ('{0}: {1}' -f $InternetTestHost, $internetResult)

if ($internetResult -ne 'Reachable' -and $internetResult -ne 'Skipped') {
    Write-WdtFinding -Severity 'WARN' -Code 'NETWORK_INTERNET_UNREACHABLE' -Message "The internet connectivity target '$InternetTestHost' is not reachable." -Evidence $internetResult
}
