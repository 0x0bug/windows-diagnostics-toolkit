[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-ContainsLiteral {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Text.IndexOf($Value, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}
. (Join-Path $PSScriptRoot 'privacy-identity.helpers.ps1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$networkScript = Join-Path -Path $repositoryRoot -ChildPath 'modules\network\diagnostic.ps1'
$scriptSource = Get-Content -LiteralPath $networkScript -Raw

Assert-True -Condition $scriptSource.Contains('& $netshPath winhttp show proxy') -Message 'Network diagnostics must use the exact read-only WinHTTP proxy query through the system executable path.'
Assert-True -Condition $scriptSource.Contains("-ChildPath 'Sysnative'") -Message 'Network diagnostics must use Sysnative from a 32-bit process on 64-bit Windows.'
Assert-True -Condition ($scriptSource -notmatch "Get-Command\s+-Name\s+'netsh\.exe'") -Message 'Network diagnostics must not fall back to resolving netsh.exe through PATH.'
Assert-True -Condition (-not $scriptSource.Contains('Get-VpnConnection')) -Message 'Network diagnostics must not call VPN APIs.'
Assert-True -Condition (-not $scriptSource.Contains('tunnel')) -Message 'Network diagnostics must not classify tunnel adapters.'

$previousProtocolMode = $env:WDT_FINDING_PROTOCOL
try {
    $fixtureOutput = @(& {
            function Get-Command {
                [CmdletBinding()]
                param([string]$Name)

                return [pscustomobject]@{ Name = $Name }
            }
            function Test-Path {
                [CmdletBinding()]
                param([string]$LiteralPath, [string]$PathType)

                return $false
            }


            function Get-NetAdapter {
                [pscustomobject]@{
                    Name                 = 'Fixture Ethernet'
                    InterfaceDescription = 'Fixture Adapter'
                    Status               = 'Up'
                    MacAddress           = '00-11-22-33-44-55'
                    ifIndex              = 7
                }
            }

            function Get-NetIPConfiguration {
                [pscustomobject]@{
                    IPv4Address        = @([pscustomobject]@{ IPAddress = '192.0.2.10' })
                    IPv6Address        = @([pscustomobject]@{ IPAddress = '2001:db8::10' })
                    IPv4DefaultGateway = @([pscustomobject]@{ NextHop = '192.0.2.1' })
                    DNSServer          = [pscustomobject]@{ ServerAddresses = @('192.0.2.53') }
                }
            }

            function Get-DnsClientGlobalSetting {
                [pscustomobject]@{ SuffixSearchList = @('fixture.example') }
            }

            function Get-DnsClient {
                [pscustomobject]@{ ConnectionSpecificSuffix = 'fixture.example' }
            }

            function Get-CimInstance {
                [CmdletBinding()]
                param([string]$ClassName, [string]$Filter)

                if ($ClassName -eq 'Win32_NetworkAdapterConfiguration') {
                    return [pscustomobject]@{
                        DHCPEnabled = $true
                        DHCPServer  = '192.0.2.254'
                        DNSDomain   = 'fixture.example'
                    }
                }

                throw "Unexpected CIM class: $ClassName"
            }

            function Get-NetIPInterface {
                [pscustomobject]@{ InterfaceIndex = 7; AddressFamily = 'IPv6'; InterfaceMetric = 50 }
                [pscustomobject]@{ InterfaceIndex = 7; AddressFamily = 'IPv4'; InterfaceMetric = 10 }
            }

            function Get-NetRoute {
                $routes = New-Object System.Collections.Generic.List[object]
                $routes.Add([pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; AddressFamily = 'IPv4'; NextHop = '192.0.2.1'; InterfaceAlias = 'Fixture Ethernet'; InterfaceIndex = 7; RouteMetric = 5; State = 'Alive' })
                $routes.Add([pscustomobject]@{ DestinationPrefix = '::/0'; AddressFamily = 'IPv6'; NextHop = '2001:db8::1'; InterfaceAlias = 'Fixture Ethernet'; InterfaceIndex = 7; RouteMetric = 5; State = 'Alive' })
                foreach ($number in 1..33) {
                    $routes.Add([pscustomobject]@{ DestinationPrefix = ('10.{0}.0.0/16' -f $number); AddressFamily = 'IPv4'; NextHop = '192.0.2.1'; InterfaceAlias = 'Fixture Ethernet'; InterfaceIndex = 7; RouteMetric = $number; State = 'Alive' })
                }

                return $routes.ToArray()
            }

            function Get-ItemProperty {
                [pscustomobject]@{
                    ProxyEnable   = 1
                    ProxyServer   = 'http=fixtureuser:fixturepassword@proxy.fixture:8080?token=fixturetoken'
                    AutoConfigURL = 'https://proxy.fixture/config.pac?access_token=fixturetoken'
                }
            }

            function Test-Connection { return $true }
            function Resolve-DnsName { return [pscustomobject]@{ IPAddress = '192.0.2.53' } }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $networkScript -DnsTestName 'fixture.example' -InternetTestHost '192.0.2.200' 6>&1 | ForEach-Object { [string]$_ }
        })

    $unavailableOutput = @(& {
            function Get-Command {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                return $null
            }

            function Get-CimInstance {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                throw 'Fixture network source unavailable.'
            }

            function Get-ItemProperty {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                throw 'Fixture proxy source unavailable.'
            }

            function Test-Path {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                return $false
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $networkScript -NoExternalNetworkTests 6>&1 | ForEach-Object { [string]$_ }
        })

    $partialAdapterOutput = @(& {
            function Get-Command { [CmdletBinding()] param([string]$Name); return [pscustomobject]@{ Name=$Name } }
            function Test-Path { [CmdletBinding()] param([string]$LiteralPath, [string]$PathType); return $false }
            function Get-NetAdapter { [pscustomobject]@{ Name='Fixture adapter'; InterfaceDescription='Synthetic'; Status='Up'; ifIndex=7 } }
            function Get-NetIPConfiguration { throw 'Fixture IP configuration unavailable.' }
            function Get-NetIPInterface { return @() }
            function Get-NetRoute { [pscustomobject]@{ DestinationPrefix='0.0.0.0/0'; AddressFamily='IPv4'; NextHop='192.0.2.1'; InterfaceAlias='Fixture adapter'; InterfaceIndex=7; RouteMetric=1; State='Alive' } }
            function Get-CimInstance { [CmdletBinding()] param([string]$ClassName, [string]$Filter); throw 'Fixture CIM adapter fallback unavailable.' }
            function Get-ItemProperty { throw 'Fixture proxy setting unavailable.' }
            $env:WDT_FINDING_PROTOCOL = '1'
            & $networkScript -NoExternalNetworkTests 6>&1 | ForEach-Object { [string]$_ }
        })

    $emptyAdapterOutput = @(& {
            function Get-Command { [CmdletBinding()] param([string]$Name); return [pscustomobject]@{ Name=$Name } }
            function Test-Path { [CmdletBinding()] param([string]$LiteralPath, [string]$PathType); return $false }
            function Get-NetAdapter { return @() }
            function Get-NetIPConfiguration { throw 'Must not be called for an empty adapter inventory.' }
            function Get-NetIPInterface { return @() }
            function Get-NetRoute { return @() }
            function Get-CimInstance { [CmdletBinding()] param([string]$ClassName, [string]$Filter); throw 'Unexpected CIM access.' }
            function Get-ItemProperty { throw 'Fixture proxy setting unavailable.' }
            $env:WDT_FINDING_PROTOCOL = '1'
            & $networkScript -NoExternalNetworkTests 6>&1 | ForEach-Object { [string]$_ }
        })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}

$fixtureText = $fixtureOutput -join "`n"

# Test the actual WinHTTP collector with synthetic native output. The source tag
# must protect every display language, including arbitrary labels and errors.
. (Join-Path $repositoryRoot 'scripts\report-common.ps1')
$networkTokens = $null
$networkErrors = $null
$networkAst = [System.Management.Automation.Language.Parser]::ParseFile($networkScript, [ref]$networkTokens, [ref]$networkErrors)
Assert-True -Condition (@($networkErrors).Count -eq 0) -Message 'Network module did not parse for WinHTTP privacy fixtures.'
foreach ($name in @('Protect-ProxyText', 'Get-WinHttpProxy')) {
    $definition = $networkAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Assert-True -Condition ($null -ne $definition) -Message "Missing WinHTTP collector function: $name"
    . ([scriptblock]::Create($definition.Extent.Text))
}
$localizedLabel = -join @([char]0x041F,[char]0x0440,[char]0x043E,[char]0x043A,[char]0x0441,[char]0x0438)
$winHttpFixtures = @(
    @{ Lines = @('Current WinHTTP proxy settings:', 'Proxy Server(s) : proxy.en.private.test:8080', 'Bypass List : *.en.private.test'); ExitCode = 0 },
    @{ Lines = @($localizedLabel + ' : proxy.ru.private.test:9090', $localizedLabel + ' : *.ru.private.test'); ExitCode = 0 },
    @{ Lines = @('arbitrary unknown-language label : proxy.other.private.test:7070', 'Direct access (no proxy server).'); ExitCode = 0 },
    @{ Lines = @($localizedLabel + " : proxy.error.private.test:6060`r`ncontinuation private-error-detail"); ExitCode = 5 }
)
foreach ($fixture in $winHttpFixtures) {
    $proxyResult = & {
        function Resolve-WdtSystemExecutablePath { param($FileName); return 'Invoke-FixtureNetsh' }
        function Invoke-FixtureNetsh {
            param($Mode, $Action, $Setting)
            Assert-True -Condition ($Mode -eq 'winhttp' -and $Action -eq 'show' -and $Setting -eq 'proxy') -Message 'WinHTTP fixture changed the native query.'
            $global:LASTEXITCODE = $fixture.ExitCode
            $fixture.Lines
        }
        Get-WinHttpProxy
    }
    foreach ($line in $proxyResult.Output) {
        Assert-True -Condition ($line -match '^WinHTTP proxy details: ') -Message 'A raw WinHTTP line is missing the language-independent source tag.'
    }
    $rawProxyText = (@($proxyResult.Output) + @($proxyResult.Error)) -join "`n"
    Assert-True -Condition ($rawProxyText.Contains('private.test') -or $rawProxyText.Contains('no proxy server')) -Message 'Ordinary WinHTTP output lost its original diagnostic details.'
    $proxyContext = New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile ''
    $safeProxyText = Protect-WdtText -Text $rawProxyText -Context $proxyContext
    Assert-True -Condition ($safeProxyText -notmatch 'private\.test|private-error-detail|no proxy server') -Message 'Localized WinHTTP details leaked from output or source Error.'
    if ($fixture.ExitCode -ne 0) {
        Assert-True -Condition $safeProxyText.Contains('netsh.exe exited with code 5') -Message 'Privacy masking hid the technical WinHTTP exit code.'
        $marker = ConvertTo-WdtFindingMarker -Severity WARN -Code NETWORK_WINHTTP_PROXY_UNAVAILABLE -Message 'WinHTTP proxy settings are unavailable.' -Evidence $proxyResult.Error -FindingNonce ''
        $finding = ConvertFrom-WdtFindingLine -Line $marker -FindingNonce ''
        $safeEvidence = Protect-WdtText -Text $finding.Evidence -Context $proxyContext
        Assert-True -Condition ($safeEvidence -notmatch 'private\.test|private-error-detail') -Message 'Localized WinHTTP failure details leaked from finding Evidence.'
        $crlfError = "Query status: Unavailable`r`n" + $proxyResult.Error + "`r`nDNS / www.microsoft.com: NotTested"
        $safeCrlfError = Protect-WdtText -Text $crlfError -Context $proxyContext
        Assert-True -Condition ($safeCrlfError -notmatch 'private\.test|private-error-detail' -and $safeCrlfError.Contains("netsh.exe exited with code 5; WinHTTP proxy details: <ID-") -and $safeCrlfError.EndsWith("`r`nDNS / www.microsoft.com: NotTested")) -Message 'CRLF WinHTTP Error masking must protect only the details and preserve the following line.'
    }
}
$throwingProxy = & {
    function Resolve-WdtSystemExecutablePath { param($FileName); return 'Invoke-FixtureNetsh' }
    function Invoke-FixtureNetsh { throw "localized proxy.catch.private.test`r`nprivate-catch-continuation" }
    Get-WinHttpProxy
}
$safeCatch = Protect-WdtText -Text $throwingProxy.Error -Context (New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile '')
Assert-True -Condition ($safeCatch -notmatch 'proxy\.catch\.private\.test|private-catch-continuation') -Message 'WinHTTP exception details bypassed source-aware privacy masking.'
$missingProxy = & {
    function Resolve-WdtSystemExecutablePath { param($FileName); return $null }
    Get-WinHttpProxy
}
Assert-True -Condition ($missingProxy.Error -eq 'netsh.exe is unavailable.' -and @($missingProxy.Output).Count -eq 0) -Message 'Missing netsh must retain its explicit unavailable state.'
Assert-True -Condition ((Protect-WdtText -Text $missingProxy.Error -Context (New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile '')) -eq 'netsh.exe is unavailable.') -Message 'Privacy masking must retain the known netsh-unavailable reason.'
$global:LASTEXITCODE = 0

$safeFixtureNetwork = Protect-WdtText -Text $fixtureText -Context (New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile '')
Assert-True -Condition ($safeFixtureNetwork -notmatch '(?m)^DNS (?:suffix|search list)\s+: fixture\.example|^Proxy server\s+: .*proxy\.fixture|^Auto config URL\s*:\s*.*proxy\.fixture') -Message 'Collected DNS/proxy/PAC settings leaked in Privacy Mode.'
Assert-True -Condition $safeFixtureNetwork.Contains('DNS / fixture.example: Resolved') -Message 'Privacy masking removed the independently configured public probe.'
$destinations = @([System.Text.RegularExpressions.Regex]::Matches($fixtureText, '(?m)^Destination\s+:\s*(.+)$') | ForEach-Object { $_.Groups[1].Value })
Assert-True -Condition ($destinations.Count -eq 30) -Message 'The route output must contain no more than 30 routes.'
Assert-True -Condition ($destinations[0] -eq '0.0.0.0/0' -and $destinations[1] -eq '::/0') -Message 'Default routes must be listed before non-default routes and sorted by effective metric.'
$defaultMetricLines = @([System.Text.RegularExpressions.Regex]::Matches($fixtureText, '(?s)Type\s+: Default.*?Effective metric\s+: (\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
Assert-True -Condition ($defaultMetricLines.Count -eq 2 -and $defaultMetricLines[0] -eq 15 -and $defaultMetricLines[1] -eq 55) -Message 'IPv4 and IPv6 interface metrics must be joined by interface and family, independent of input order.'
foreach ($sensitiveValue in @('fixtureuser', 'fixturepassword', 'fixturetoken')) {
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $fixtureText -Value $sensitiveValue)) -Message ("Proxy credential or sensitive query value leaked: {0}" -f $sensitiveValue)
}
Assert-True -Condition $fixtureText.Contains('NETWORK_WINHTTP_PROXY_UNAVAILABLE') -Message 'Unavailable WinHTTP proxy source did not emit a WARN finding.'

$unavailableText = $unavailableOutput -join "`n"
foreach ($code in @('NETWORK_ADAPTERS_UNAVAILABLE', 'NETWORK_ROUTES_UNAVAILABLE', 'NETWORK_WININET_PROXY_UNAVAILABLE', 'NETWORK_WINHTTP_PROXY_UNAVAILABLE')) {
    Assert-True -Condition $unavailableText.Contains($code) -Message ("Unavailable fixture did not emit '{0}'." -f $code)
}
Assert-True -Condition ($unavailableText -notmatch '"Severity":"ERROR"') -Message 'Unavailable network sources must not create ERROR findings.'
Assert-True -Condition $unavailableText.Contains('Overall reachability: NotTested') -Message 'Disabled external tests must report NotTested.'
Assert-True -Condition $unavailableText.Contains('Query status: Unavailable') -Message 'A failed WinHTTP query must retain canonical availability in the text report.'
foreach ($probeLabel in @('DNS /', 'TCP HTTPS /', 'Optional ICMP /')) {
    Assert-True -Condition (-not $unavailableText.Contains($probeLabel)) -Message ("Disabled external tests unexpectedly ran probe: {0}" -f $probeLabel)
}

$partialAdapterText = $partialAdapterOutput -join "`n"
Assert-True -Condition $partialAdapterText.Contains('NETWORK_ADAPTER_CONFIGURATION_UNAVAILABLE') -Message 'An active adapter with an unreadable IP configuration must report incomplete inventory.'
Assert-True -Condition $partialAdapterText.Contains('Default route state: Present') -Message 'Partial adapter inventory fixture must retain the confirmed default route.'
foreach ($falseFailure in @('NETWORK_NO_ACTIVE_ADAPTER','NETWORK_NO_GATEWAY','NETWORK_CONNECTIVITY_UNREACHABLE')) {
    Assert-True -Condition (-not $partialAdapterText.Contains($falseFailure)) -Message ("Partial adapter inventory must not assert '{0}'." -f $falseFailure)
}
Assert-True -Condition $partialAdapterText.Contains('Overall reachability: NotTested') -Message 'Disabled external tests must remain disabled with a partial adapter inventory.'

$emptyAdapterText = $emptyAdapterOutput -join "`n"
Assert-True -Condition $emptyAdapterText.Contains('NETWORK_NO_ACTIVE_ADAPTER') -Message 'A successfully queried empty adapter inventory must still report no active adapter.'
Assert-True -Condition $emptyAdapterText.Contains('NETWORK_NO_GATEWAY') -Message 'A successfully queried empty adapter inventory must still report no gateway.'

$standaloneOutput = @(& $networkScript -DnsTestName '' -InternetTestHost '' 6>&1 | ForEach-Object { [string]$_ })
foreach ($section in @('Active Network Adapters', 'Active Routes (Default First)', 'WinINET Proxy', 'WinHTTP Proxy')) {
    Assert-True -Condition (($standaloneOutput -join "`n").Contains(("== {0} ==" -f $section))) -Message ("Standalone network output is missing '{0}'." -f $section)
}

$temporaryRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetFullPath($env:RUNNER_TEMP)
}
else {
    [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
}
$temporaryRootPrefix = $temporaryRoot.TrimEnd('\') + '\'
$outputDirectory = Join-Path -Path $temporaryRoot -ChildPath ('wdt-network-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    & (Join-Path -Path $repositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1') -Network -PrivacyMode -ExportMarkdown -OutputDirectory $outputDirectory *> $null

    $textReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.txt' -File | Select-Object -First 1
    $markdownReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.md' -File | Select-Object -First 1
    Assert-True -Condition ($null -ne $textReport) -Message 'Network runner smoke test did not create a TXT report.'
    Assert-True -Condition ($null -ne $markdownReport) -Message 'Network runner smoke test did not create a Markdown report.'

    $textContent = Get-Content -LiteralPath $textReport.FullName -Raw
    $markdownContent = Get-Content -LiteralPath $markdownReport.FullName -Raw
    $combinedContent = $textContent + "`n" + $markdownContent

    Assert-True -Condition ($textContent -match '(?m)^Selected\s+: Network Check\r?$') -Message 'Network runner selected the wrong module.'
    Assert-True -Condition $textContent.Contains('== Network Check ==') -Message 'TXT report is missing the Network Check section.'
    Assert-True -Condition $markdownContent.Contains('## Network Check') -Message 'Markdown report is missing the Network Check section.'
    $textSummaryIndex = $textContent.IndexOf('== Findings Summary ==', [System.StringComparison]::Ordinal)
    $textDetailsIndex = $textContent.IndexOf('== Network Check ==', [System.StringComparison]::Ordinal)
    Assert-True -Condition ($textSummaryIndex -ge 0 -and $textDetailsIndex -ge 0 -and $textSummaryIndex -lt $textDetailsIndex) -Message 'TXT findings summary must exist before network details.'
    $markdownSummaryIndex = $markdownContent.IndexOf('## Findings Summary', [System.StringComparison]::Ordinal)
    $markdownDetailsIndex = $markdownContent.IndexOf('## Network Check', [System.StringComparison]::Ordinal)
    Assert-True -Condition ($markdownSummaryIndex -ge 0 -and $markdownDetailsIndex -ge 0 -and $markdownSummaryIndex -lt $markdownDetailsIndex) -Message 'Markdown findings summary must exist before network details.'
    Assert-True -Condition (-not (Test-IdentityFieldLeak -Text $combinedContent -ComputerName $env:COMPUTERNAME -UserName $env:USERNAME)) -Message 'Privacy Mode leaked a computer or user identity field from network diagnostics.'
    Assert-True -Condition ($combinedContent -notmatch '@@WDT_FINDING@@') -Message 'Network report leaked an internal finding marker.'

    Write-Host 'Network context tests passed.'
}
finally {
    if (Test-Path -LiteralPath $outputDirectory) {
        $resolvedOutputDirectory = (Resolve-Path -LiteralPath $outputDirectory).Path
        if (-not $resolvedOutputDirectory.StartsWith($temporaryRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a path outside the temporary root: $resolvedOutputDirectory"
        }

        Remove-Item -LiteralPath $resolvedOutputDirectory -Recurse -Force
    }
}

if (Test-Path -LiteralPath $outputDirectory) {
    throw 'Network context smoke-test output directory was not removed.'
}
