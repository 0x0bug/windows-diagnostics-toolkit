[CmdletBinding()]
param(
    [string]$DnsTestName = 'www.microsoft.com',
    [string]$HttpsEndpoint = 'https://www.microsoft.com/',
    [Alias('InternetTestHost')]
    [string]$IcmpTarget = '1.1.1.1',
    [switch]$NoExternalNetworkTests,
    [int]$TimeoutSeconds = 3
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\report-common.ps1

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)

    Write-Host ''
    Write-Host "== $Title =="
}

function Join-ValuesOrNone {
    param([object[]]$Values)

    $filteredValues = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($filteredValues.Count -eq 0) {
        return 'None'
    }

    return ($filteredValues -join ', ')
}

function Protect-ProxyText {
    param([AllowEmptyString()][string]$Text)

    $protectedText = Protect-WdtSensitiveUrlText -Text $Text
    return [System.Text.RegularExpressions.Regex]::Replace(
        $protectedText,
        '(?i)(?<![\w.-])[^@\s;:/\\]+:[^@\s;]+@',
        '<REDACTED>@'
    )
}

function Get-CimAdapterConfiguration {
    try {
        return [pscustomobject]@{
            Adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop)
            Error    = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Adapters = @()
            Error    = $_.Exception.Message
        }
    }
}

function ConvertTo-CimAdapterRecord {
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [AllowEmptyString()][string]$SearchList = 'None'
    )

    return [pscustomobject]@{
        Name          = $Adapter.Description
        Description   = $Adapter.Description
        Status        = 'Up'
        MacAddress    = Join-ValuesOrNone -Values $Adapter.MACAddress
        IPv4          = Join-ValuesOrNone -Values ($Adapter.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
        IPv6          = Join-ValuesOrNone -Values ($Adapter.IPAddress | Where-Object { $_ -notmatch '^\d{1,3}(\.\d{1,3}){3}$' })
        Gateway       = Join-ValuesOrNone -Values $Adapter.DefaultIPGateway
        DnsServers    = Join-ValuesOrNone -Values $Adapter.DNSServerSearchOrder
        Dhcp          = if ($Adapter.DHCPEnabled) { 'Enabled' } else { 'Disabled' }
        DhcpServer    = Join-ValuesOrNone -Values $Adapter.DHCPServer
        DnsSuffix     = Join-ValuesOrNone -Values $Adapter.DNSDomain
        DnsSearchList = $SearchList
        Source        = 'Win32_NetworkAdapterConfiguration'
    }
}

function Get-AdapterConfiguration {
    $netAdapterCommand = Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue
    $netIpConfigurationCommand = Get-Command -Name Get-NetIPConfiguration -ErrorAction SilentlyContinue
    $dnsClientCommand = Get-Command -Name Get-DnsClient -ErrorAction SilentlyContinue
    $dnsClientGlobalSettingCommand = Get-Command -Name Get-DnsClientGlobalSetting -ErrorAction SilentlyContinue

    if ($null -eq $netAdapterCommand -or $null -eq $netIpConfigurationCommand) {
        $cimResult = Get-CimAdapterConfiguration
        if ($null -ne $cimResult.Error) {
            Write-WdtFinding -Severity WARN -Code 'NETWORK_ADAPTERS_UNAVAILABLE' -Message 'Active network adapter configuration is unavailable.' -Evidence $cimResult.Error
            return @()
        }

        $searchList = 'None'
        $searchListValues = @($cimResult.Adapters | ForEach-Object { $_.DNSDomainSuffixSearchOrder } | Where-Object { $null -ne $_ })
        if ($searchListValues.Count -gt 0) {
            $searchList = Join-ValuesOrNone -Values $searchListValues
        }

        return @($cimResult.Adapters | ForEach-Object { ConvertTo-CimAdapterRecord -Adapter $_ -SearchList $searchList })
    }

    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    }
    catch {
        $cimResult = Get-CimAdapterConfiguration
        if ($null -ne $cimResult.Error) {
            Write-WdtFinding -Severity WARN -Code 'NETWORK_ADAPTERS_UNAVAILABLE' -Message 'Active network adapter configuration is unavailable.' -Evidence ("Get-NetAdapter failed: {0}; CIM fallback failed: {1}" -f $_.Exception.Message, $cimResult.Error)
            return @()
        }

        Write-WdtFinding -Severity WARN -Code 'NETWORK_ADAPTERS_PRIMARY_UNAVAILABLE' -Message 'Get-NetAdapter is unavailable; CIM adapter data was used.' -Evidence $_.Exception.Message
        return @($cimResult.Adapters | ForEach-Object { ConvertTo-CimAdapterRecord -Adapter $_ })
    }

    $searchList = 'None'
    if ($null -eq $dnsClientGlobalSettingCommand) {
        Write-WdtFinding -Severity WARN -Code 'NETWORK_DNS_SEARCH_LIST_UNAVAILABLE' -Message 'The DNS suffix search list source is unavailable.'
    }
    else {
        try {
            $searchList = Join-ValuesOrNone -Values (Get-DnsClientGlobalSetting -ErrorAction Stop).SuffixSearchList
        }
        catch {
            Write-WdtFinding -Severity WARN -Code 'NETWORK_DNS_SEARCH_LIST_UNAVAILABLE' -Message 'The DNS suffix search list is unavailable.' -Evidence $_.Exception.Message
        }
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($adapter in $adapters) {
        try {
            $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction Stop
        }
        catch {
            Write-WdtFinding -Severity WARN -Code 'NETWORK_ADAPTER_CONFIGURATION_UNAVAILABLE' -Message 'IP configuration for an active adapter is unavailable.' -Evidence ("Adapter={0}; {1}" -f $adapter.Name, $_.Exception.Message)
            continue
        }

        $cimConfiguration = $null
        try {
            $cimConfiguration = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter ("InterfaceIndex={0}" -f $adapter.ifIndex) -ErrorAction Stop | Select-Object -First 1
        }
        catch {
            Write-WdtFinding -Severity WARN -Code 'NETWORK_DHCP_UNAVAILABLE' -Message 'DHCP status or server information is unavailable.' -Evidence ("Adapter={0}; {1}" -f $adapter.Name, $_.Exception.Message)
        }

        $dnsSuffix = 'None'
        if ($null -eq $dnsClientCommand) {
            if ($null -ne $cimConfiguration) {
                $dnsSuffix = Join-ValuesOrNone -Values $cimConfiguration.DNSDomain
            }
            else {
                $dnsSuffix = 'Unavailable'
                Write-WdtFinding -Severity WARN -Code 'NETWORK_DNS_SUFFIX_UNAVAILABLE' -Message 'The DNS suffix for an active adapter is unavailable.' -Evidence ("Adapter={0}" -f $adapter.Name)
            }
        }
        else {
            try {
                $dnsSuffix = Join-ValuesOrNone -Values (Get-DnsClient -InterfaceIndex $adapter.ifIndex -ErrorAction Stop).ConnectionSpecificSuffix
            }
            catch {
                if ($null -ne $cimConfiguration) {
                    $dnsSuffix = Join-ValuesOrNone -Values $cimConfiguration.DNSDomain
                }
                else {
                    $dnsSuffix = 'Unavailable'
                    Write-WdtFinding -Severity WARN -Code 'NETWORK_DNS_SUFFIX_UNAVAILABLE' -Message 'The DNS suffix for an active adapter is unavailable.' -Evidence ("Adapter={0}; {1}" -f $adapter.Name, $_.Exception.Message)
                }
            }
        }

        $dhcpState = if ($null -ne $cimConfiguration) {
            if ($cimConfiguration.DHCPEnabled) { 'Enabled' } else { 'Disabled' }
        }
        else {
            'Unavailable'
        }
        $dhcpServer = if ($null -ne $cimConfiguration) {
            Join-ValuesOrNone -Values $cimConfiguration.DHCPServer
        }
        else {
            'Unavailable'
        }

        $records.Add([pscustomobject]@{
                Name          = $adapter.Name
                Description   = $adapter.InterfaceDescription
                Status        = $adapter.Status
                MacAddress    = Join-ValuesOrNone -Values $adapter.MacAddress
                IPv4          = Join-ValuesOrNone -Values $ipConfig.IPv4Address.IPAddress
                IPv6          = Join-ValuesOrNone -Values $ipConfig.IPv6Address.IPAddress
                Gateway       = Join-ValuesOrNone -Values $ipConfig.IPv4DefaultGateway.NextHop
                DnsServers    = Join-ValuesOrNone -Values $ipConfig.DNSServer.ServerAddresses
                Dhcp          = $dhcpState
                DhcpServer    = $dhcpServer
                DnsSuffix     = $dnsSuffix
                DnsSearchList = $searchList
                Source        = 'NetTCPIP and DnsClient'
            })
    }

    return @($records.ToArray())
}

function Get-CidrPrefixLength {
    param([Parameter(Mandatory = $true)][string]$SubnetMask)

    try {
        $bits = 0
        foreach ($byte in ([System.Net.IPAddress]$SubnetMask).GetAddressBytes()) {
            $value = [int]$byte
            while ($value -gt 0) {
                $bits += $value -band 1
                $value = $value -shr 1
            }
        }

        return $bits
    }
    catch {
        return $null
    }
}

function Get-DisplayNetworkRoutes {
    param([object[]]$Routes)

    return @($Routes |
            Sort-Object -Property @{ Expression = { $_.IsDefaultRoute }; Descending = $true }, @{ Expression = { $_.EffectiveMetric }; Descending = $false }, @{ Expression = { $_.DestinationPrefix }; Descending = $false } |
            Select-Object -First 30)
}

function Get-NetworkRoutes {
    $getNetRouteCommand = Get-Command -Name Get-NetRoute -ErrorAction SilentlyContinue
    $getNetIpInterfaceCommand = Get-Command -Name Get-NetIPInterface -ErrorAction SilentlyContinue

    if ($null -ne $getNetRouteCommand) {
        try {
            $interfaceMetrics = @{}
            if ($null -ne $getNetIpInterfaceCommand) {
                foreach ($interface in @(Get-NetIPInterface -ErrorAction Stop)) {
                    $interfaceMetrics[[int]$interface.InterfaceIndex] = [double]$interface.InterfaceMetric
                }
            }

            $routes = New-Object System.Collections.Generic.List[object]
            foreach ($route in @(Get-NetRoute -ErrorAction Stop)) {
                if ($null -ne $route.State -and [string]$route.State -ne 'Alive') {
                    continue
                }

                $destinationPrefix = [string]$route.DestinationPrefix
                $isDefaultRoute = $destinationPrefix -in @('0.0.0.0/0', '::/0')
                $routeMetric = if ($null -ne $route.RouteMetric) { [double]$route.RouteMetric } else { 0 }
                $interfaceMetric = if ($interfaceMetrics.ContainsKey([int]$route.InterfaceIndex)) { [double]$interfaceMetrics[[int]$route.InterfaceIndex] } else { 0 }
                $routes.Add([pscustomobject]@{
                        DestinationPrefix = $destinationPrefix
                        NextHop           = [string]$route.NextHop
                        Interface         = if ($null -ne $route.InterfaceAlias) { [string]$route.InterfaceAlias } else { [string]$route.InterfaceIndex }
                        EffectiveMetric   = $routeMetric + $interfaceMetric
                        IsDefaultRoute    = $isDefaultRoute
                        Source            = 'Get-NetRoute'
                    })
            }

            return [pscustomobject]@{
                Routes = Get-DisplayNetworkRoutes -Routes $routes.ToArray()
                Error  = $null
            }
        }
        catch {
            $netRouteError = $_.Exception.Message
        }
    }
    else {
        $netRouteError = 'Get-NetRoute is unavailable.'
    }

    try {
        $routes = New-Object System.Collections.Generic.List[object]
        foreach ($route in @(Get-CimInstance -ClassName Win32_IP4RouteTable -ErrorAction Stop)) {
            $prefixLength = Get-CidrPrefixLength -SubnetMask ([string]$route.Mask)
            $destinationPrefix = if ($null -ne $prefixLength) { '{0}/{1}' -f $route.Destination, $prefixLength } else { [string]$route.Destination }
            $routes.Add([pscustomobject]@{
                    DestinationPrefix = $destinationPrefix
                    NextHop           = [string]$route.NextHop
                    Interface         = [string]$route.InterfaceIndex
                    EffectiveMetric   = if ($null -ne $route.Metric1) { [double]$route.Metric1 } else { 0 }
                    IsDefaultRoute    = ([string]$route.Destination -eq '0.0.0.0' -and [string]$route.Mask -eq '0.0.0.0')
                    Source            = 'Win32_IP4RouteTable'
                })
        }

        Write-WdtFinding -Severity WARN -Code 'NETWORK_ROUTES_PRIMARY_UNAVAILABLE' -Message 'Get-NetRoute is unavailable; CIM route data was used.' -Evidence $netRouteError
        return [pscustomobject]@{
            Routes = Get-DisplayNetworkRoutes -Routes $routes.ToArray()
            Error  = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Routes = @()
            Error  = ('{0} CIM fallback failed: {1}' -f $netRouteError, $_.Exception.Message)
        }
    }
}

function Get-WinInetProxy {
    try {
        $settings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        return [pscustomobject]@{
            Enabled       = if ([int]$settings.ProxyEnable -ne 0) { 'Enabled' } else { 'Disabled' }
            ProxyServer   = Protect-ProxyText -Text ([string]$settings.ProxyServer)
            AutoConfigUrl = Protect-ProxyText -Text ([string]$settings.AutoConfigURL)
            Error         = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Enabled       = 'Unavailable'
            ProxyServer   = 'Unavailable'
            AutoConfigUrl = 'Unavailable'
            Error         = $_.Exception.Message
        }
    }
}

function Get-WinHttpProxy {
    if ($null -eq (Get-Command -Name 'netsh.exe' -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Output = @()
            Error  = 'netsh.exe is unavailable.'
        }
    }

    try {
        $output = @(& netsh.exe winhttp show proxy 2>&1 | ForEach-Object { Protect-ProxyText -Text ([string]$_) })
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{
                Output = @($output)
                Error  = ('netsh.exe exited with code {0}: {1}' -f $LASTEXITCODE, ($output -join ' '))
            }
        }

        return [pscustomobject]@{
            Output = @($output)
            Error  = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Output = @()
            Error  = $_.Exception.Message
        }
    }
}

function Test-HostReachability {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Target,
        [int]$Timeout = 3
    )

    if ([string]::IsNullOrWhiteSpace($Target) -or $Target -eq 'None') {
        return 'Skipped'
    }

    if ($null -eq (Get-Command -Name Test-Connection -ErrorAction SilentlyContinue)) {
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
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'Skipped'
    }

    if ($null -ne (Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue)) {
        try {
            $records = Resolve-DnsName -Name $Name -ErrorAction Stop
            $addresses = $records | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique
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

function Test-HttpsTcpConnection {
    param([Parameter(Mandatory = $true)][string]$Endpoint, [int]$Timeout = 3)

    try {
        $uri = New-Object System.Uri -ArgumentList $Endpoint
        if ($uri.Scheme -ne 'https') { return 'Indeterminate: endpoint must use HTTPS' }
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($uri.Host, $(if ($uri.IsDefaultPort) { 443 } else { $uri.Port }))
            if (-not $task.Wait($Timeout * 1000)) { return 'Unreachable: TCP timeout' }
            if ($client.Connected) { return 'Reachable' }
            return 'Unreachable'
        }
        finally { $client.Dispose() }
    }
    catch { return "BlockedOrFiltered: $($_.Exception.Message)" }
}

function Get-NetworkReachabilityClassification {
    param(
        [bool]$HasAdapter,
        [ValidateSet('Present', 'Absent', 'Unavailable')][string]$DefaultRouteState,
        [string]$DnsStatus,
        [string]$TcpStatus,
        [string]$IcmpStatus,
        [bool]$ExternalTestsEnabled
    )
    if (-not $ExternalTestsEnabled) { return 'NotTested' }
    if ($TcpStatus -eq 'Reachable' -and $DnsStatus -match '^Resolved') { return 'Reachable' }
    if (-not $HasAdapter -or $DefaultRouteState -eq 'Absent') { return 'Unreachable' }
    if ($TcpStatus -eq 'Reachable') { return 'BlockedOrFiltered' }
    if ($DnsStatus -match '^Resolved' -and $TcpStatus -match '^(Unreachable|BlockedOrFiltered)') { return 'BlockedOrFiltered' }
    if ($DnsStatus -match '^Failed' -and $TcpStatus -match '^Unreachable') { return 'Unreachable' }
    return 'Indeterminate'
}

Write-Host 'Windows Diagnostics Toolkit - Network Check'
Write-Host 'Mode: read-only'

$adapterConfigurations = @(Get-AdapterConfiguration)
$routeResult = Get-NetworkRoutes
$winInetProxy = Get-WinInetProxy
$winHttpProxy = Get-WinHttpProxy

Write-Section 'Active Network Adapters'
if ($adapterConfigurations.Count -eq 0) {
    Write-Host 'No active network adapters found.'
    Write-WdtFinding -Severity WARN -Code 'NETWORK_NO_ACTIVE_ADAPTER' -Message 'No active network adapters were found.'
}
else {
    foreach ($adapter in $adapterConfigurations) {
        Write-Host ('Name            : {0}' -f $adapter.Name)
        Write-Host ('Description     : {0}' -f $adapter.Description)
        Write-Host ('Status          : {0}' -f $adapter.Status)
        Write-Host ('MAC             : {0}' -f $adapter.MacAddress)
        Write-Host ('IPv4            : {0}' -f $adapter.IPv4)
        Write-Host ('IPv6            : {0}' -f $adapter.IPv6)
        Write-Host ('Gateway         : {0}' -f $adapter.Gateway)
        Write-Host ('DNS servers     : {0}' -f $adapter.DnsServers)
        Write-Host ('DHCP            : {0}' -f $adapter.Dhcp)
        Write-Host ('DHCP server     : {0}' -f $adapter.DhcpServer)
        Write-Host ('DNS suffix      : {0}' -f $adapter.DnsSuffix)
        Write-Host ('DNS search list : {0}' -f $adapter.DnsSearchList)
        Write-Host ('Source          : {0}' -f $adapter.Source)
        Write-Host ''
    }
}

Write-Section 'Active Routes (Default First)'
if ($null -ne $routeResult.Error) {
    Write-Host ('Unavailable: {0}' -f $routeResult.Error)
    Write-WdtFinding -Severity WARN -Code 'NETWORK_ROUTES_UNAVAILABLE' -Message 'Active route information is unavailable.' -Evidence $routeResult.Error
}
elseif ($routeResult.Routes.Count -eq 0) {
    Write-Host 'No active routes were found.'
    Write-WdtFinding -Severity WARN -Code 'NETWORK_NO_ACTIVE_ROUTE' -Message 'No active routes were found.'
}
else {
    foreach ($route in $routeResult.Routes) {
        $routeType = if ($route.IsDefaultRoute) { 'Default' } else { 'Active' }
        Write-Host ('Type             : {0}' -f $routeType)
        Write-Host ('Destination      : {0}' -f $route.DestinationPrefix)
        Write-Host ('Next hop         : {0}' -f $route.NextHop)
        Write-Host ('Interface        : {0}' -f $route.Interface)
        Write-Host ('Effective metric : {0}' -f $route.EffectiveMetric)
        Write-Host ('Source           : {0}' -f $route.Source)
        Write-Host ''
    }
}

Write-Section 'WinINET Proxy'
if ($null -ne $winInetProxy.Error) {
    Write-Host ('Unavailable: {0}' -f $winInetProxy.Error)
    Write-WdtFinding -Severity WARN -Code 'NETWORK_WININET_PROXY_UNAVAILABLE' -Message 'WinINET proxy settings are unavailable.' -Evidence $winInetProxy.Error
}
else {
    Write-Host ('Enabled        : {0}' -f $winInetProxy.Enabled)
    Write-Host ('Proxy server   : {0}' -f (Join-ValuesOrNone -Values $winInetProxy.ProxyServer))
    Write-Host ('Auto config URL: {0}' -f (Join-ValuesOrNone -Values $winInetProxy.AutoConfigUrl))
}

Write-Section 'WinHTTP Proxy'
if ($null -ne $winHttpProxy.Error) {
    Write-Host ('Unavailable: {0}' -f $winHttpProxy.Error)
    Write-WdtFinding -Severity WARN -Code 'NETWORK_WINHTTP_PROXY_UNAVAILABLE' -Message 'WinHTTP proxy settings are unavailable.' -Evidence $winHttpProxy.Error
}
else {
    foreach ($line in $winHttpProxy.Output) {
        Write-Host $line
    }
}

Write-Section 'Default Gateway and Route'
$gateways = $adapterConfigurations |
    ForEach-Object { $_.Gateway -split ', ' } |
    Where-Object { $_ -and $_ -ne 'None' } |
    Select-Object -Unique

if ($gateways) {
    foreach ($gateway in $gateways) {
        $gatewayResult = Test-HostReachability -Target $gateway -Timeout $TimeoutSeconds
        Write-Host ('{0}: {1}' -f $gateway, $gatewayResult)
        if ($gatewayResult -ne 'Reachable') { Write-Host 'ICMP may be blocked; route presence is evaluated independently.' }
    }
}
else {
    Write-Host 'No IPv4 gateway detected.'
    Write-WdtFinding -Severity WARN -Code 'NETWORK_NO_GATEWAY' -Message 'No IPv4 default gateway was detected.'
}

Write-Section 'External Network Tests'
$dnsResult = 'NotTested'
$tcpResult = 'NotTested'
$icmpResult = 'NotTested'
if ($NoExternalNetworkTests) {
    Write-Host 'External tests: NotTested (-NoExternalNetworkTests)'
}
else {
    $dnsResult = Test-DnsResolution -Name $DnsTestName
    $tcpResult = Test-HttpsTcpConnection -Endpoint $HttpsEndpoint -Timeout $TimeoutSeconds
    $icmpResult = Test-HostReachability -Target $IcmpTarget -Timeout $TimeoutSeconds
    Write-Host ('DNS / {0}: {1}' -f $DnsTestName, $dnsResult)
    Write-Host ('TCP HTTPS / {0}: {1}' -f $HttpsEndpoint, $tcpResult)
    Write-Host ('Optional ICMP / {0}: {1}' -f $IcmpTarget, $icmpResult)
}
$defaultRouteState = if ($null -ne $routeResult.Error) {
    'Unavailable'
}
elseif (@($routeResult.Routes | Where-Object { $_.IsDefaultRoute }).Count -gt 0) {
    'Present'
}
else {
    'Absent'
}
Write-Host ('Default route state: {0}' -f $defaultRouteState)
$classification = Get-NetworkReachabilityClassification -HasAdapter ($adapterConfigurations.Count -gt 0) -DefaultRouteState $defaultRouteState -DnsStatus $dnsResult -TcpStatus $tcpResult -IcmpStatus $icmpResult -ExternalTestsEnabled (-not $NoExternalNetworkTests)
Write-Host ('Overall reachability: {0}' -f $classification)
if ($classification -eq 'Unreachable') {
    Write-WdtFinding -Severity WARN -Code 'NETWORK_CONNECTIVITY_UNREACHABLE' -Message 'Multiple independent network signals indicate connectivity is unavailable.' -Evidence ("Adapter={0}; DefaultRoute={1}; DNS={2}; TCP={3}; ICMP={4}" -f ($adapterConfigurations.Count -gt 0), $defaultRouteState, $dnsResult, $tcpResult, $icmpResult)
}
