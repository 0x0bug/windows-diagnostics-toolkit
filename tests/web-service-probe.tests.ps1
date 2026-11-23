[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$networkScript = Join-Path $repositoryRoot 'scripts\network-check.ps1'
. (Join-Path $repositoryRoot 'scripts\report-common.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) { throw $Message }
}

function Invoke-FixtureNetworkCheck {
    param([string]$Url, [switch]$Disable, [int]$Timeout = 3)

    function Get-Command { [CmdletBinding()] param([string]$Name); return [pscustomobject]@{ Name = $Name } }
    function Get-NetAdapter { return @() }
    function Get-NetIPInterface { return @() }
    function Get-NetRoute { return @() }
    function Get-DnsClientGlobalSetting { [pscustomobject]@{ SuffixSearchList = @() } }
    function Join-Path { param([AllowEmptyString()][string]$Path, [string]$ChildPath); return $ChildPath }
    function Test-Path { return $false }
    function Get-ItemProperty { [pscustomobject]@{ ProxyEnable = 0; ProxyServer = $null; AutoConfigURL = $null } }
    function Resolve-DnsName { throw 'UNRELATED_DNS_PROBE' }
    function Test-Connection { throw 'UNRELATED_ICMP_PROBE' }

    # The wrapper is the standalone entry point. Use an invalid baseline TCP
    # endpoint so a regression never causes a public connection in this test.
    $output = & $networkScript -WebServiceUrl $Url -NoExternalNetworkTests:$Disable -TimeoutSeconds $Timeout -DnsTestName 'unused.example.invalid' -HttpsEndpoint 'http://unused.example.invalid/' 6>&1
    return (@($output | ForEach-Object { [string]$_ }) -join "`n")
}

$fixtureServer = {
    param($Listener, [string]$Response, [int]$DelayMs, $Certificate)

    $ErrorActionPreference = 'Stop'
    $client = $Listener.AcceptTcpClient()
    $stream = $null
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $stream.WriteTimeout = 5000
        if ($null -ne $Certificate) {
            $stream = [System.Net.Security.SslStream]::new($stream)
            try {
                $stream.AuthenticateAsServer($Certificate, $false, [System.Security.Authentication.SslProtocols]::None, $false)
            }
            catch [System.Management.Automation.MethodInvocationException] {
                return
            }
        }

        $reader = [System.IO.StreamReader]::new($stream)
        try {
            do { $line = $reader.ReadLine(); if ($line) { $line } } while ($line)
            if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($Response)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        catch [System.Management.Automation.MethodInvocationException] {
            # Certificate rejection or the test timeout can close the connection
            # before the server can read a request or finish writing a response.
            if ($null -eq $Certificate -and $DelayMs -eq 0) { throw }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
    }
}

function Invoke-WebFixture {
    param(
        [string]$Response,
        [int]$DelayMs,
        [int]$Timeout = 3,
        [switch]$UseDns,
        $Certificate
    )

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $server = [powershell]::Create()
    try {
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $name = if ($UseDns -or $null -ne $Certificate) { 'localhost' } else { '127.0.0.1' }
        $scheme = if ($null -ne $Certificate) { 'https' } else { 'http' }
        $url = '{0}://{1}:{2}/health/private-path-marker?custom=private-query-marker%23value' -f $scheme, $name, $port
        $responseText = $Response.Replace('FIXTURE_PORT', [string]$port)
        $null = $server.AddScript($fixtureServer).AddArgument($listener).AddArgument($responseText).AddArgument($DelayMs).AddArgument($Certificate)
        $worker = $server.BeginInvoke()

        $output = Invoke-FixtureNetworkCheck -Url $url -Timeout $Timeout
        Assert-True ($worker.AsyncWaitHandle.WaitOne(6000)) 'The loopback fixture did not finish.'
        $requestLines = @($server.EndInvoke($worker))
        if ($server.HadErrors) { throw $server.Streams.Error[0] }

        Assert-True (-not $listener.Pending()) 'The collector made a second connection to the service.'
        Assert-True ($output -match '(?m)^== Web Service Probe ==$') 'The explicit probe section is missing.'
        Assert-True ($output -match 'External tests: NotTested \(web service target selected\)') 'The focused probe ran unrelated network probes.'
        Assert-True ($output -match 'Overall reachability: NotTested') 'The service result altered overall reachability.'
        Assert-True ($output -notmatch 'UNRELATED_|unused\.example\.invalid|private-\w+-marker') 'Unrelated probes or private URL data appeared in the report.'
        Assert-True ($output -match '(?m)^TCP\s+: Connected to 127\.0\.0\.1$') 'TCP did not connect to the loopback service.'
        if ($UseDns) {
            Assert-True ($output -match '(?m)^DNS\s+: Resolved: .*127\.0\.0\.1') 'The named target was not resolved by the system resolver.'
        }
        elseif ($null -eq $Certificate) {
            Assert-True ($output -match '(?m)^DNS\s+: NotApplicable \(IP literal\)$') 'The literal target incorrectly reported DNS activity.'
        }
        if ($null -eq $Certificate) {
            Assert-True ($output -match '(?m)^TLS\s+: NotApplicable \(HTTP\)$') 'The HTTP target incorrectly reported TLS activity.'
            Assert-True ($requestLines[0] -ceq 'GET /health/private-path-marker?custom=private-query-marker%23value HTTP/1.1') 'The HTTP request did not use the given path and query.'
            Assert-True ($requestLines[1] -ceq ('Host: {0}:{1}' -f $name, $port)) 'The HTTP Host header did not specify the configured authority.'
            Assert-True (($requestLines -join ' ') -notmatch '(?i)Authorization:|Cookie:|#') 'The request contained unexpected credentials or fragment data.'
        }
        else {
            Assert-True ($requestLines.Count -eq 0) 'The collector transmitted an HTTP request after receiving an untrusted certificate.'
        }

        return $output
    }
    finally {
        $listener.Stop()
        $server.Dispose()
    }
}

foreach ($status in @(200, 401, 403, 503)) {
    $response = "HTTP/1.1 $status private-status-marker`r`nContent-Length: 19`r`n`r`nprivate-body-marker"
    if ($status -eq 200) { $response = "HTTP/1.1 103 Early Hints`r`n`r`n" + $response }
    $output = Invoke-WebFixture -Response $response -UseDns:($status -eq 200)
    $expected = switch ($status) {
        401 { 'HTTP 401 Unauthorized' }
        403 { 'HTTP 403 Forbidden' }
        503 { 'HTTP 503 Service Unavailable' }
        default { 'HTTP 200' }
    }
    Assert-True ($output -match ('(?m)^HTTP\s+: {0}$' -f $expected)) "Unexpected HTTP classification for $status."
}

$redirect = Invoke-WebFixture -Response "HTTP/1.1 302 Found`r`nLocation: http://127.0.0.1:FIXTURE_PORT/private-redirect-marker`r`nContent-Length: 0`r`n`r`n"
Assert-True ($redirect -match '(?m)^HTTP\s+: HTTP 302 \(redirection response; no follow-up request\)$') 'The collector did not report the original redirect status.'

$slow = Invoke-WebFixture -Response "HTTP/1.1 200 OK`r`n`r`n" -DelayMs 1700 -Timeout 1
Assert-True ($slow -match '(?m)^HTTP\s+: TimedOut$') 'The collector did not enforce the HTTP timeout.'

$oversized = Invoke-WebFixture -Response ('HTTP/1.1 200 OK' + "`r`nX-Large: " + ('z' * 17000) + "`r`n`r`n")
Assert-True ($oversized -match '(?m)^HTTP\s+: HeadersTooLarge$') 'The collector did not cap HTTP response headers.'

$rsa = if ($PSVersionTable.PSEdition -eq 'Desktop') {
    [System.Security.Cryptography.RSACng]::new(2048)
}
else {
    [System.Security.Cryptography.RSA]::Create(2048)
}
try {
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=localhost', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $names = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $names.AddDnsName('localhost')
    $request.CertificateExtensions.Add($names.Build())
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
    try {
        $untrusted = Invoke-WebFixture -Response "HTTP/1.1 200 OK`r`n`r`n" -Certificate $certificate
        Assert-True ($untrusted -match '(?m)^TLS\s+: Failed \(handshake or certificate validation\)$') 'The collector accepted an untrusted server certificate.'
        Assert-True ($untrusted -match '(?m)^HTTP\s+: NotTested$') 'HTTP was incorrectly tested after failed TLS.'
    }
    finally {
        $certificate.Dispose()
    }
}
finally {
    $rsa.Dispose()
}

$credentialUrl = 'https://private-user-marker:private-password-marker@example.invalid/private-path-marker?custom=private-query-marker'
$invalid = Invoke-FixtureNetworkCheck -Url $credentialUrl
Assert-True ($invalid -match 'NETWORK_WEB_SERVICE_INVALID_TARGET' -and $invalid -notmatch 'private-\w+-marker|example\.invalid') 'Invalid service URLs must be rejected without echoing input.'
foreach ($invalidUrl in @('example.invalid/path', 'ftp://example.invalid/', 'https://@example.invalid/', 'http://host:0/', "http://example.invalid/line`nbreak", 'http://example.invalid\other/', 'http://example.invalid/#', 'http://example.invalid/#private-fragment-marker')) {
    Assert-True ($null -eq (ConvertTo-WdtWebServiceUri -Value $invalidUrl)) 'The shared validator accepted a malformed or unsupported URL.'
}

$disabled = Invoke-FixtureNetworkCheck -Url $credentialUrl -Disable
Assert-True ($disabled -match 'Web service tests: NotTested \(-NoExternalNetworkTests\)' -and $disabled -notmatch 'INVALID_TARGET|private-\w+-marker') 'The external tests switch must skip the service before examining the URL.'

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
try {
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $disabled = Invoke-FixtureNetworkCheck -Url "http://127.0.0.1:$port/health" -Disable
    Assert-True (-not $listener.Pending()) 'The explicit service was contacted while external probes were disabled.'
}
finally {
    $listener.Stop()
}

$empty = Invoke-FixtureNetworkCheck -Url ''
Assert-True ($empty -match 'NETWORK_WEB_SERVICE_INVALID_TARGET' -and $empty -notmatch 'UNRELATED_|unused\.example\.invalid') 'An explicit empty URL must fail without falling back to unrelated probes.'

Write-Host 'Web service probe tests passed.'
