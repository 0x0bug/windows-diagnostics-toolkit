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

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$networkScript = Join-Path -Path $repositoryRoot -ChildPath 'modules\network\diagnostic.ps1'
$scriptSource = Get-Content -LiteralPath $networkScript -Raw

Assert-True -Condition $scriptSource.Contains('& netsh.exe winhttp show proxy') -Message 'Network diagnostics must use the exact read-only WinHTTP proxy query.'
Assert-True -Condition (-not $scriptSource.Contains('Get-VpnConnection')) -Message 'Network diagnostics must not call VPN APIs.'
Assert-True -Condition (-not $scriptSource.Contains('tunnel')) -Message 'Network diagnostics must not classify tunnel adapters.'

$previousProtocolMode = $env:WDT_FINDING_PROTOCOL
try {
    $fixtureOutput = @(& {
            function Get-Command {
                [CmdletBinding()]
                param([string]$Name)

                if ($Name -eq 'netsh.exe') {
                    return $null
                }

                return [pscustomobject]@{ Name = $Name }
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
                [pscustomobject]@{ InterfaceIndex = 7; InterfaceMetric = 10 }
            }

            function Get-NetRoute {
                $routes = New-Object System.Collections.Generic.List[object]
                $routes.Add([pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.0.2.1'; InterfaceAlias = 'Fixture Ethernet'; InterfaceIndex = 7; RouteMetric = 40; State = 'Alive' })
                $routes.Add([pscustomobject]@{ DestinationPrefix = '::/0'; NextHop = '2001:db8::1'; InterfaceAlias = 'Fixture Ethernet'; InterfaceIndex = 7; RouteMetric = 5; State = 'Alive' })
                foreach ($number in 1..33) {
                    $routes.Add([pscustomobject]@{ DestinationPrefix = ('10.{0}.0.0/16' -f $number); NextHop = '192.0.2.1'; InterfaceAlias = 'Fixture Ethernet'; InterfaceIndex = 7; RouteMetric = $number; State = 'Alive' })
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

            $env:WDT_FINDING_PROTOCOL = '1'
            & $networkScript -NoExternalNetworkTests 6>&1 | ForEach-Object { [string]$_ }
        })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}

$fixtureText = $fixtureOutput -join "`n"
$destinations = @([System.Text.RegularExpressions.Regex]::Matches($fixtureText, '(?m)^Destination\s+:\s*(.+)$') | ForEach-Object { $_.Groups[1].Value })
Assert-True -Condition ($destinations.Count -eq 30) -Message 'The route output must contain no more than 30 routes.'
Assert-True -Condition ($destinations[0] -eq '::/0' -and $destinations[1] -eq '0.0.0.0/0') -Message 'Default routes must be listed before non-default routes and sorted by effective metric.'
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
foreach ($probeLabel in @('DNS /', 'TCP HTTPS /', 'Optional ICMP /')) {
    Assert-True -Condition (-not $unavailableText.Contains($probeLabel)) -Message ("Disabled external tests unexpectedly ran probe: {0}" -f $probeLabel)
}

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
    Assert-True -Condition ($textContent.IndexOf('== Findings Summary ==', [System.StringComparison]::Ordinal) -lt $textContent.IndexOf('== Network Check ==', [System.StringComparison]::Ordinal)) -Message 'TXT findings summary must precede network details.'
    Assert-True -Condition ($markdownContent.IndexOf('## Findings Summary', [System.StringComparison]::Ordinal) -lt $markdownContent.IndexOf('## Network Check', [System.StringComparison]::Ordinal)) -Message 'Markdown findings summary must precede network details.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value $env:COMPUTERNAME)) -Message 'Privacy Mode leaked the computer name from network diagnostics.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value $env:USERNAME)) -Message 'Privacy Mode leaked the user name from network diagnostics.'
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
