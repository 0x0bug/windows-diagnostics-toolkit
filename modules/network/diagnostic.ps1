[CmdletBinding()]
param(
    [string]$DnsTestName = 'www.microsoft.com',
    [string]$HttpsEndpoint = 'https://www.microsoft.com/',
    [Alias('InternetTestHost')]
    [string]$IcmpTarget = '1.1.1.1',
    [switch]$NoExternalNetworkTests,
    [int]$TimeoutSeconds = 3,
    [string]$WebServiceUrl
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\..\..\scripts\report-common.ps1

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
            return [pscustomobject]@{ Available = $false; Complete = $false; Adapters = @() }
        }

        $searchList = 'None'
        $searchListValues = @($cimResult.Adapters | ForEach-Object { $_.DNSDomainSuffixSearchOrder } | Where-Object { $null -ne $_ })
        if ($searchListValues.Count -gt 0) {
            $searchList = Join-ValuesOrNone -Values $searchListValues
        }

        return [pscustomobject]@{ Available = $true; Complete = $true; Adapters = @($cimResult.Adapters | ForEach-Object { ConvertTo-CimAdapterRecord -Adapter $_ -SearchList $searchList }) }
    }

    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    }
    catch {
        $cimResult = Get-CimAdapterConfiguration
        if ($null -ne $cimResult.Error) {
            Write-WdtFinding -Severity WARN -Code 'NETWORK_ADAPTERS_UNAVAILABLE' -Message 'Active network adapter configuration is unavailable.' -Evidence ("Get-NetAdapter failed: {0}; CIM fallback failed: {1}" -f $_.Exception.Message, $cimResult.Error)
            return [pscustomobject]@{ Available = $false; Complete = $false; Adapters = @() }
        }

        Write-WdtFinding -Severity WARN -Code 'NETWORK_ADAPTERS_PRIMARY_UNAVAILABLE' -Message 'Get-NetAdapter is unavailable; CIM adapter data was used.' -Evidence $_.Exception.Message
        return [pscustomobject]@{ Available = $true; Complete = $true; Adapters = @($cimResult.Adapters | ForEach-Object { ConvertTo-CimAdapterRecord -Adapter $_ }) }
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
    $configurationComplete = $true
    foreach ($adapter in $adapters) {
        try {
            $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction Stop
        }
        catch {
            $configurationComplete = $false
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
                Gateway       = Join-ValuesOrNone -Values (@($ipConfig.IPv4DefaultGateway.NextHop) + @($ipConfig.IPv6DefaultGateway.NextHop))
                DnsServers    = Join-ValuesOrNone -Values $ipConfig.DNSServer.ServerAddresses
                Dhcp          = $dhcpState
                DhcpServer    = $dhcpServer
                DnsSuffix     = $dnsSuffix
                DnsSearchList = $searchList
                Source        = 'NetTCPIP and DnsClient'
            })
    }

    return [pscustomobject]@{ Available = $true; Complete = $configurationComplete; Adapters = @($records.ToArray()) }
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
                    $family = [string]$interface.AddressFamily
                    $interfaceMetrics[(('{0}|{1}' -f [int]$interface.InterfaceIndex, $family).ToLowerInvariant())] = [double]$interface.InterfaceMetric
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
                $family = [string]$route.AddressFamily
                if ([string]::IsNullOrWhiteSpace($family)) { $family = if ($destinationPrefix -like '*:*') { 'IPv6' } else { 'IPv4' } }
                $interfaceMetricKey = ('{0}|{1}' -f [int]$route.InterfaceIndex, $family).ToLowerInvariant()
                $interfaceMetric = if ($interfaceMetrics.ContainsKey($interfaceMetricKey)) { [double]$interfaceMetrics[$interfaceMetricKey] } else { 0 }
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
                Routes   = Get-DisplayNetworkRoutes -Routes $routes.ToArray()
                Complete = $true
                Error    = $null
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

        Write-WdtFinding -Severity WARN -Code 'NETWORK_ROUTES_PRIMARY_UNAVAILABLE' -Message 'Get-NetRoute is unavailable; only IPv4 routes were collected by CIM.' -Evidence $netRouteError
        return [pscustomobject]@{
            Routes   = Get-DisplayNetworkRoutes -Routes $routes.ToArray()
            Complete = $false
            Error    = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Routes   = @()
            Complete = $false
            Error    = ('{0} CIM fallback failed: {1}' -f $netRouteError, $_.Exception.Message)
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

function Resolve-WdtSystemExecutablePath {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $systemDirectory = [System.Environment]::SystemDirectory
    if ([System.Environment]::Is64BitOperatingSystem -and -not [System.Environment]::Is64BitProcess) {
        $windowsDirectory = [System.IO.Directory]::GetParent($systemDirectory).FullName
        $systemDirectory = Join-Path -Path $windowsDirectory -ChildPath 'Sysnative'
    }

    $candidatePath = Join-Path -Path $systemDirectory -ChildPath $FileName
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($candidatePath)
}

function Get-WinHttpProxy {
    $netshPath = Resolve-WdtSystemExecutablePath -FileName 'netsh.exe'
    if ([string]::IsNullOrWhiteSpace($netshPath)) {
        return [pscustomobject]@{
            Output = @()
            Error  = 'netsh.exe is unavailable.'
        }
    }

    try {
        # Keep raw native details under an explicit source label. Combined-report
        # privacy can then protect any display language, including error text.
        $output = @(& $netshPath winhttp show proxy 2>&1 | ForEach-Object {
                'WinHTTP proxy details: ' + (ConvertTo-WdtSingleLineText -Text (Protect-ProxyText -Text ([string]$_)))
            })
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{
                Output = @($output)
                Error  = ('netsh.exe exited with code {0}; {1}' -f $LASTEXITCODE, ($output -join ' '))
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
            Error  = 'WinHTTP proxy details: ' + (ConvertTo-WdtSingleLineText -Text $_.Exception.Message)
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

function Test-TcpEndpointConnection {
    param([Parameter(Mandatory = $true)][string]$Endpoint, [int]$Timeout = 3)

    try {
        $uri = New-Object System.Uri -ArgumentList $Endpoint
    }
    catch { return "Indeterminate: invalid endpoint - $($_.Exception.Message)" }
    if ($uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)) { return 'Indeterminate: endpoint must be an absolute HTTPS URI' }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($uri.Host, $(if ($uri.IsDefaultPort) { 443 } else { $uri.Port }))
        if (-not $task.Wait($Timeout * 1000)) { return 'BlockedOrFiltered: TCP connect timed out' }
        if ($client.Connected) { return 'Reachable' }
        return 'Unreachable: TCP connect did not establish a connection'
    }
    catch [System.AggregateException] { return "Unreachable: TCP connect failed - $($_.Exception.InnerException.Message)" }
    catch { return "Indeterminate: TCP test failed internally - $($_.Exception.Message)" }
    finally { $client.Dispose() }
}

function Read-WdtWebServiceHttpStatus {
    param([System.IO.Stream]$Stream, [uri]$Uri, [int]$TimeoutMilliseconds)

    $httpClock = [System.Diagnostics.Stopwatch]::StartNew()
    $authority = if ($Uri.HostNameType -eq 'IPv6') { $Uri.Host } else { $Uri.IdnHost }
    if (-not $Uri.IsDefaultPort) { $authority = '{0}:{1}' -f $authority, $Uri.Port }
    $requestText = "GET {0} HTTP/1.1`r`nHost: {1}`r`nConnection: close`r`n`r`n" -f $Uri.PathAndQuery, $authority
    $requestBytes = [System.Text.Encoding]::ASCII.GetBytes($requestText)
    try {
        $writeTask = $Stream.WriteAsync($requestBytes, 0, $requestBytes.Length)
        if (-not $writeTask.Wait($TimeoutMilliseconds)) { return 'TimedOut' }

        # Read only as far as the final headers. A shared deadline and byte cap
        # bound partial headers, slow responses and repeated interim 1xx responses.
        $headerLimit = 16384
        $responseBuffer = [byte[]]::new(1024)
        $received = 0
        $responseText = ''
        while ($received -lt $headerLimit) {
            $remaining = $TimeoutMilliseconds - $httpClock.ElapsedMilliseconds
            if ($remaining -le 0) { return 'TimedOut' }

            $readSize = [Math]::Min($responseBuffer.Length, $headerLimit - $received)
            $readTask = $Stream.ReadAsync($responseBuffer, 0, $readSize)
            if (-not $readTask.Wait([int]$remaining)) { return 'TimedOut' }
            $readCount = $readTask.Result
            if ($readCount -eq 0) { return 'InvalidResponse' }

            $received += $readCount
            $responseText += [System.Text.Encoding]::ASCII.GetString($responseBuffer, 0, $readCount)
            $headerEnd = $responseText.IndexOf("`r`n`r`n", [System.StringComparison]::Ordinal)
            while ($headerEnd -ge 0) {
                $headers = $responseText.Substring(0, $headerEnd)
                if ($headers -cnotmatch '^HTTP/1\.[01] ([1-5][0-9]{2})(?: [^\r\n]*)?(?:\r\n|$)') { return 'InvalidResponse' }

                $status = [int]$Matches[1]
                if ($status -ge 200 -or $status -eq 101) { return $status }

                $responseText = $responseText.Substring($headerEnd + 4)
                $headerEnd = $responseText.IndexOf("`r`n`r`n", [System.StringComparison]::Ordinal)
            }
        }

        return 'HeadersTooLarge'
    }
    catch {
        return 'TransportFailed'
    }
}

function Test-WdtWebService {
    param([uri]$Uri, [int]$Timeout)

    $timeoutMilliseconds = [int][Math]::Min(1000L * $Timeout, [int]::MaxValue)
    $hostName = $Uri.IdnHost
    $result = [pscustomobject]@{
        Dns  = 'NotTested'
        Tcp  = 'NotTested'
        Tls  = if ($Uri.Scheme -eq 'https') { 'NotTested' } else { 'NotApplicable (HTTP)' }
        Http = 'NotTested'
    }

    $literalAddress = $null
    if ($Uri.HostNameType -in @('IPv4', 'IPv6')) {
        if (-not [System.Net.IPAddress]::TryParse($hostName, [ref]$literalAddress)) {
            $result.Dns = 'Failed (the IP literal could not be used)'
            return $result
        }
        $addresses = @($literalAddress)
        $result.Dns = 'NotApplicable (IP literal)'
    }
    else {
        try {
            $dnsTask = [System.Net.Dns]::GetHostAddressesAsync($hostName)
            if (-not $dnsTask.Wait($timeoutMilliseconds)) {
                $result.Dns = 'TimedOut'
                return $result
            }
            $addresses = @($dnsTask.Result)
            if ($addresses.Count -eq 0) {
                $result.Dns = 'Failed (no addresses returned)'
                return $result
            }
            $result.Dns = 'Resolved: {0}' -f ($addresses -join ', ')
        }
        catch {
            $result.Dns = 'Failed (system resolver could not resolve the host)'
            return $result
        }
    }

    $tcpClock = [System.Diagnostics.Stopwatch]::StartNew()
    $client = $null
    $result.Tcp = 'Unreachable (no resolved address accepted the connection)'
    foreach ($address in $addresses) {
        $remaining = $timeoutMilliseconds - $tcpClock.ElapsedMilliseconds
        if ($remaining -le 0) {
            $result.Tcp = 'TimedOut'
            break
        }

        $candidate = $null
        try {
            $candidate = [System.Net.Sockets.TcpClient]::new($address.AddressFamily)
            $connectTask = $candidate.ConnectAsync($address, $Uri.Port)
            if (-not $connectTask.Wait([int]$remaining)) {
                $result.Tcp = 'TimedOut'
                break
            }
            $client = $candidate
            $candidate = $null
            $result.Tcp = 'Connected to {0}' -f $address
            break
        }
        catch {
            # Try the next address within the same connection deadline.
        }
        finally {
            if ($null -ne $candidate) { $candidate.Dispose() }
        }
    }
    if ($null -eq $client) { return $result }

    $tlsStream = $null
    try {
        $stream = $client.GetStream()
        if ($Uri.Scheme -eq 'https') {
            $result.Tls = 'Failed (handshake or certificate validation)'
            $tlsStream = [System.Net.Security.SslStream]::new($stream)
            $tlsHost = if ($Uri.HostNameType -eq 'IPv6') { $Uri.Host.Trim([char[]]'[]') } else { $hostName }
            # The runtime validates the certificate chain and the URL host. No
            # callback overrides trust and the probe does not request revocation checks.
            $tlsTask = $tlsStream.AuthenticateAsClientAsync($tlsHost, $null, [System.Security.Authentication.SslProtocols]::None, $false)
            if (-not $tlsTask.Wait($timeoutMilliseconds)) {
                $result.Tls = 'TimedOut'
                return $result
            }
            $result.Tls = 'Established (certificate validated)'
            $stream = $tlsStream
        }
        $result.Http = Read-WdtWebServiceHttpStatus -Stream $stream -Uri $Uri -TimeoutMilliseconds $timeoutMilliseconds
    }
    catch {
        if ($result.Tls -ne 'Failed (handshake or certificate validation)') { $result.Http = 'TransportFailed' }
    }
    finally {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        $client.Dispose()
    }

    return $result
}

function Write-WdtWebServiceProbe {
    param([AllowEmptyString()][string]$Value, [int]$Timeout, [switch]$Disabled)

    Write-Section 'Web Service Probe'
    if ($Disabled) {
        Write-Host 'Web service tests: NotTested (-NoExternalNetworkTests)'
        return
    }

    $uri = ConvertTo-WdtWebServiceUri -Value $Value
    if ($null -eq $uri) {
        Write-WdtFinding -Severity WARN -Code 'NETWORK_WEB_SERVICE_INVALID_TARGET' -Message 'The web service target must be an absolute HTTP or HTTPS URL without credentials or a fragment.'
        return
    }
    if ($Timeout -le 0) {
        Write-WdtFinding -Severity WARN -Code 'NETWORK_WEB_SERVICE_INVALID_TIMEOUT' -Message 'The web service probe requires a positive timeout.'
        return
    }

    $result = Test-WdtWebService -Uri $uri -Timeout $Timeout
    $httpText = switch ($result.Http) {
        401 { 'HTTP 401 Unauthorized'; break }
        403 { 'HTTP 403 Forbidden'; break }
        503 { 'HTTP 503 Service Unavailable'; break }
        { $_ -is [int] -and $_ -ge 300 -and $_ -lt 400 } {
            'HTTP {0} (redirection response; no follow-up request)' -f $_
            break
        }
        { $_ -is [int] } { 'HTTP {0}' -f $_; break }
        default { [string]$_ }
    }
    $displayHost = if ($uri.HostNameType -eq 'IPv6') { $uri.Host } else { $uri.IdnHost }
    Write-Host ('Host      : {0}' -f $displayHost)
    Write-Host ('Port      : {0}' -f $uri.Port)
    Write-Host ('Protocol  : {0}' -f $uri.Scheme)
    Write-Host ('DNS       : {0}' -f $result.Dns)
    Write-Host ('TCP       : {0}' -f $result.Tcp)
    Write-Host ('TLS       : {0}' -f $result.Tls)
    Write-Host ('HTTP      : {0}' -f $httpText)

    if ($result.Dns -match '^(Failed|TimedOut)') {
        Write-WdtFinding -Severity WARN -Code 'NETWORK_WEB_SERVICE_DNS_FAILED' -Message 'Name resolution for the web service did not complete successfully.' -Evidence $result.Dns
    }
    elseif ($result.Tcp -match '^(Unreachable|TimedOut)') {
        Write-WdtFinding -Severity WARN -Code 'NETWORK_WEB_SERVICE_TCP_FAILED' -Message 'A TCP connection to the web service could not be established.' -Evidence $result.Tcp
    }
    elseif ($result.Tls -match '^(Failed|TimedOut)') {
        Write-WdtFinding -Severity WARN -Code 'NETWORK_WEB_SERVICE_TLS_FAILED' -Message 'A validated TLS connection to the web service could not be established.' -Evidence $result.Tls
    }
    elseif ($result.Http -isnot [int]) {
        Write-WdtFinding -Severity WARN -Code 'NETWORK_WEB_SERVICE_HTTP_FAILED' -Message 'The web service did not return a complete HTTP status in the probe.' -Evidence $httpText
    }
    elseif ($result.Http -ge 400 -or $result.Http -eq 101) {
        Write-WdtFinding -Severity WARN -Code 'NETWORK_WEB_SERVICE_HTTP_STATUS' -Message 'The web service responded with an HTTP status that requires attention.' -Evidence $httpText
    }
}

function Get-NetworkReachabilityClassification {
    param(
        [bool]$HasAdapter,
        [ValidateSet('Present', 'Absent', 'Partial', 'Unavailable')][string]$DefaultRouteState,
        [string]$DnsStatus,
        [string]$TcpStatus,
        [bool]$ExternalTestsEnabled,
        [ValidateSet('Available', 'Partial', 'Unavailable')][string]$AdapterInventoryState = 'Available'
    )
    if (-not $ExternalTestsEnabled) { return 'NotTested' }
    if ($TcpStatus -eq 'Reachable') {
        if ($DnsStatus -match '^Resolved:') { return 'Reachable' }
        return 'BlockedOrFiltered'
    }
    if (($AdapterInventoryState -eq 'Available' -and -not $HasAdapter) -or $DefaultRouteState -eq 'Absent') { return 'Unreachable' }
    if ($DnsStatus -match '^Resolved:' -and $TcpStatus -match '^(Unreachable|BlockedOrFiltered)') { return 'BlockedOrFiltered' }
    if ($DnsStatus -match '^Failed' -and $TcpStatus -match '^Unreachable') { return 'Unreachable' }
    return 'Indeterminate'
}

Write-Host 'Windows Diagnostics Toolkit - Network Check'
Write-Host 'Mode: read-only'

$adapterResult = Get-AdapterConfiguration
$adapterConfigurations = @($adapterResult.Adapters)
$routeResult = Get-NetworkRoutes
$winInetProxy = Get-WinInetProxy
$winHttpProxy = Get-WinHttpProxy

Write-Section 'Active Network Adapters'
if (-not $adapterResult.Available) {
    Write-Host 'Active network adapter inventory is unavailable.'
}
elseif (-not $adapterResult.Complete -and $adapterConfigurations.Count -eq 0) {
    Write-Host 'Active network adapter inventory is incomplete.'
}
elseif ($adapterResult.Complete -and $adapterConfigurations.Count -eq 0) {
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
    if ($routeResult.Complete) {
        Write-Host 'No active routes were found.'
        Write-WdtFinding -Severity WARN -Code 'NETWORK_NO_ACTIVE_ROUTE' -Message 'No active routes were found.'
    }
    else { Write-Host 'No active IPv4 routes were found. IPv6 route data is unavailable.' }
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
    Write-Host 'Query status: Unavailable'
    Write-Host ('Unavailable: {0}' -f $winHttpProxy.Error)
    Write-WdtFinding -Severity WARN -Code 'NETWORK_WINHTTP_PROXY_UNAVAILABLE' -Message 'WinHTTP proxy settings are unavailable.' -Evidence $winHttpProxy.Error
}
else {
    # Query success does not establish whether a proxy is configured.
    Write-Host 'Query status: Available'
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
elseif ($adapterResult.Available -and $adapterResult.Complete) {
    Write-Host 'No IPv4 or IPv6 gateway detected.'
    Write-WdtFinding -Severity WARN -Code 'NETWORK_NO_GATEWAY' -Message 'No IPv4 or IPv6 default gateway was detected.'
}

Write-Section 'External Network Tests'
$dnsResult = 'NotTested'
$tcpResult = 'NotTested'
$icmpResult = 'NotTested'
$hasWebServiceTarget = $PSBoundParameters.ContainsKey('WebServiceUrl')
if ($NoExternalNetworkTests) {
    Write-Host 'External tests: NotTested (-NoExternalNetworkTests)'
}
elseif ($hasWebServiceTarget) {
    Write-Host 'External tests: NotTested (web service target selected)'
}
else {
    $dnsResult = Test-DnsResolution -Name $DnsTestName
    $tcpResult = Test-TcpEndpointConnection -Endpoint $HttpsEndpoint -Timeout $TimeoutSeconds
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
elseif (-not $routeResult.Complete) {
    'Partial'
}
else {
    'Absent'
}
Write-Host ('Default route state: {0}' -f $defaultRouteState)
$adapterInventoryState = if (-not $adapterResult.Available) { 'Unavailable' } elseif (-not $adapterResult.Complete) { 'Partial' } else { 'Available' }
$classification = Get-NetworkReachabilityClassification -HasAdapter ($adapterConfigurations.Count -gt 0) -DefaultRouteState $defaultRouteState -DnsStatus $dnsResult -TcpStatus $tcpResult -ExternalTestsEnabled (-not $NoExternalNetworkTests -and -not $hasWebServiceTarget) -AdapterInventoryState $adapterInventoryState
Write-Host ('Overall reachability: {0}' -f $classification)
if ($classification -eq 'Unreachable') {
    Write-WdtFinding -Severity WARN -Code 'NETWORK_CONNECTIVITY_UNREACHABLE' -Message 'Multiple independent network signals indicate connectivity is unavailable.' -Evidence ("Adapter={0}; AdapterInventory={1}; DefaultRoute={2}; DNS={3}; TCP={4}; ICMP={5}" -f ($adapterConfigurations.Count -gt 0), $adapterInventoryState, $defaultRouteState, $dnsResult, $tcpResult, $icmpResult)
}

if ($hasWebServiceTarget) {
    Write-WdtWebServiceProbe -Value $WebServiceUrl -Timeout $TimeoutSeconds -Disabled:$NoExternalNetworkTests
}
