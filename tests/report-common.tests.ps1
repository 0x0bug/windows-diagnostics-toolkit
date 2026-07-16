[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $repositoryRoot -ChildPath 'scripts\report-common.ps1')

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-TestDiagnosticResult {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [int]$ExitCode = 0,
        [string[]]$OutputLines = @()
    )

    return [pscustomobject][ordered]@{
        Title       = $Title
        Command     = 'test command'
        ExitCode    = $ExitCode
        OutputLines = @($OutputLines)
        ErrorLines  = @()
    }
}

$previousProtocolMode = $env:WDT_FINDING_PROTOCOL
try {
    $env:WDT_FINDING_PROTOCOL = '1'
    $protocolOutput = @(Write-WdtFinding -Severity WARN -Code 'PROTOCOL_WARNING' -Message 'Protocol output.' 6>&1 | ForEach-Object { [string]$_ })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}

Assert-Equal -Expected 1 -Actual $protocolOutput.Count -Message 'Protocol mode must emit exactly one finding marker.'
Assert-True -Condition (Test-WdtFindingLine -Line $protocolOutput[0]) -Message 'Protocol mode must emit a parseable finding marker.'

$warningMarker = ConvertTo-WdtFindingMarker -Severity WARN -Code 'TEST_WARNING' -Message 'A warning was detected.' -Evidence 'Value=1'
$warningResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'Warning Module' -OutputLines @('detail line', $warningMarker, $warningMarker))

Assert-Equal -Expected 0 -Actual $warningResult.ExitCode -Message 'Findings must not change the module exit code.'
Assert-Equal -Expected 1 -Actual $warningResult.OutputLines.Count -Message 'Finding markers must be removed from diagnostic detail output.'
Assert-Equal -Expected 'detail line' -Actual $warningResult.OutputLines[0] -Message 'Non-marker output must be preserved.'

$warningSummary = Get-WdtFindingsSummary -Results @($warningResult)
Assert-Equal -Expected 'WARN' -Actual $warningSummary.OverallStatus -Message 'A warning must set WARN overall status.'
Assert-Equal -Expected 1 -Actual $warningSummary.WarningCount -Message 'Duplicate findings must be removed from the summary.'
Assert-Equal -Expected 0 -Actual $warningSummary.ErrorCount -Message 'A warning-only result must not add errors.'

$multilineMarker = ConvertTo-WdtFindingMarker -Severity WARN -Code 'MULTILINE_WARNING' -Message "First line`r`nSecond line" -Evidence "Value one`nValue two"
$multilineFinding = ConvertFrom-WdtFindingLine -Line $multilineMarker
Assert-Equal -Expected 'First line Second line' -Actual $multilineFinding.Message -Message 'Finding messages must be normalized to one line.'
Assert-Equal -Expected 'Value one Value two' -Actual $multilineFinding.Evidence -Message 'Finding evidence must be normalized to one line.'

$errorMarker = ConvertTo-WdtFindingMarker -Severity ERROR -Code 'TEST_ERROR' -Message 'An error was detected.'
$errorResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'Error Module' -OutputLines @($errorMarker))
$okResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'OK Module' -OutputLines @('normal output'))
$mixedSummary = Get-WdtFindingsSummary -Results @($warningResult, $errorResult, $okResult)

Assert-Equal -Expected 'ERROR' -Actual $mixedSummary.OverallStatus -Message 'ERROR must take precedence over WARN and OK.'
Assert-Equal -Expected 1 -Actual $mixedSummary.ErrorCount -Message 'The error count is incorrect.'
Assert-Equal -Expected 1 -Actual $mixedSummary.WarningCount -Message 'The warning count is incorrect.'
Assert-Equal -Expected 1 -Actual $mixedSummary.OkModuleCount -Message 'A clean module must produce one OK item.'
Assert-Equal -Expected 'ERROR' -Actual $mixedSummary.Items[0].Severity -Message 'Errors must be listed before warnings and OK modules.'
Assert-Equal -Expected 'WARN' -Actual $mixedSummary.Items[1].Severity -Message 'Warnings must be listed after errors.'
Assert-Equal -Expected 'OK' -Actual $mixedSummary.Items[2].Severity -Message 'OK modules must be listed last.'

$invalidResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'Invalid Marker Module' -OutputLines @('@@WDT_FINDING@@{invalid json'))
$invalidSummary = Get-WdtFindingsSummary -Results @($invalidResult)

Assert-Equal -Expected 'ERROR' -Actual $invalidSummary.OverallStatus -Message 'An invalid marker must produce an ERROR summary.'
Assert-Equal -Expected 'FINDING_PROTOCOL_INVALID' -Actual $invalidSummary.Items[0].Code -Message 'An invalid marker must use the protocol error code.'
Assert-Equal -Expected 0 -Actual $invalidResult.OutputLines.Count -Message 'Invalid internal markers must not appear in report details.'

$failedResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'Failed Module' -ExitCode 7)
$failedSummary = Get-WdtFindingsSummary -Results @($failedResult)

Assert-Equal -Expected 'MODULE_EXECUTION_FAILED' -Actual $failedSummary.Items[0].Code -Message 'A non-zero exit code must create a module execution finding.'
Assert-Equal -Expected 7 -Actual $failedResult.ExitCode -Message 'Result processing must preserve the original exit code.'
Assert-True -Condition (@($failedSummary.Items | Where-Object { $_.Severity -eq 'OK' }).Count -eq 0) -Message 'A failed module must not be marked OK.'

$redactionContext = New-WdtRedactionContext `
    -ComputerName 'WORKSTATION-42' `
    -UserName 'Alice' `
    -UserDomain 'CONTOSO' `
    -UserProfile 'C:\Users\Alice'
$redactionFixture = @'
Host: WORKSTATION-42
User: CONTOSO\Alice
InstalledBy: Alice
Profile: C:\Users\Alice\Documents\report.txt
IPv4: 192.0.2.10, repeated: 192.0.2.10, second: 198.51.100.20
IPv6: 2001:db8::10 and fe80::20%12
MAC: 00-11-22-33-44-55 and 00:11:22:33:44:66
SID: S-1-5-21-111111111-222222222-333333333-1001
GUID: {12345678-1234-5678-9ABC-1234567890AB}
Devices: PCI\VEN_1234&DEV_5678\1 and USB\VID_1234&PID_5678\ABCDEF
Process: example.exe, Alice.exe, and WORKSTATION-42.exe
Application: Alice Photo Editor
Message: The computer WORKSTATION-42 was restarted by user Alice.
Message: Faulting application name: Alice Photo Editor.exe, version: 1.0
Message: Process Alice Helper failed for user Alice.
Custom path: D:\Exports\Alice\report.txt
InstalledBy: CONTOSO\Bob
Timestamp: 2026-07-10T12:34:56
Clock: 12:34:56
OS version: 10.0.22631.3155
CommandLine: Alice.exe --token secret-value
'@

$protectedFixture = Protect-WdtText -Text $redactionFixture -Context $redactionContext
foreach ($sensitiveValue in @(
    'CONTOSO\Alice',
    'C:\Users\Alice',
    '192.0.2.10',
    '198.51.100.20',
    '2001:db8::10',
    'fe80::20%12',
    '00-11-22-33-44-55',
    '00:11:22:33:44:66',
    'S-1-5-21-111111111-222222222-333333333-1001',
    '{12345678-1234-5678-9ABC-1234567890AB}',
    'PCI\VEN_1234&DEV_5678\1',
    'USB\VID_1234&PID_5678\ABCDEF'
)) {
    Assert-True -Condition (-not $protectedFixture.Contains($sensitiveValue)) -Message "Sensitive value '$sensitiveValue' was not redacted."
}

Assert-True -Condition (-not $protectedFixture.Contains('Host: WORKSTATION-42')) -Message 'A host name in a host field must be redacted.'
Assert-True -Condition ([regex]::IsMatch($protectedFixture, 'IPv4: (?<Token><IP-\d+>), repeated: \k<Token>')) -Message 'A repeated value must use the same token.'
Assert-True -Condition ([regex]::Matches($protectedFixture, '<IP-\d+>').Count -ge 4) -Message 'Different IP values must receive category tokens.'
Assert-True -Condition $protectedFixture.Contains('<USER-1>\Documents\report.txt') -Message 'A user-profile prefix must use the current user token.'
Assert-True -Condition (-not $protectedFixture.Contains('InstalledBy: Alice')) -Message 'A bare user name in an identity field must be redacted.'
Assert-True -Condition $protectedFixture.Contains('Process: example.exe, Alice.exe, and WORKSTATION-42.exe') -Message 'Process and application names must be preserved.'
Assert-True -Condition $protectedFixture.Contains('Application: Alice Photo Editor') -Message 'An application name without a file extension must be preserved in an application field.'
Assert-True -Condition (-not $protectedFixture.Contains('The computer WORKSTATION-42 was restarted by user Alice')) -Message 'Known host and user names in event-style free text must be redacted.'
Assert-True -Condition (-not $protectedFixture.Contains('computer WORKSTATION-42')) -Message 'A known host name in free text must be redacted.'
Assert-True -Condition (-not $protectedFixture.Contains('by user Alice.')) -Message 'A known user name in free text must be redacted.'
Assert-True -Condition $protectedFixture.Contains('Faulting application name: Alice Photo Editor.exe') -Message 'An application name inside an event-style message must be preserved.'
Assert-True -Condition $protectedFixture.Contains('Process Alice Helper failed') -Message 'A process name inside an event-style message must be preserved.'
Assert-True -Condition (-not $protectedFixture.Contains('for user Alice.')) -Message 'A user mentioned after a process name must still be redacted.'
Assert-True -Condition (-not $protectedFixture.Contains('D:\Exports\Alice\report.txt')) -Message 'A known user name in a non-standard path must be redacted.'
Assert-True -Condition (-not $protectedFixture.Contains('InstalledBy: CONTOSO\Bob')) -Message 'A different qualified user in an identity field must be redacted.'
Assert-True -Condition $protectedFixture.Contains('2026-07-10T12:34:56') -Message 'Timestamps must not be over-redacted as IPv6 addresses.'
Assert-True -Condition $protectedFixture.Contains('Clock: 12:34:56') -Message 'Clock values must not be over-redacted as IPv6 addresses.'
Assert-True -Condition $protectedFixture.Contains('10.0.22631.3155') -Message 'OS versions must not be over-redacted as IPv4 addresses.'
Assert-True -Condition (-not $protectedFixture.Contains('secret-value')) -Message 'A labelled process command line must be redacted.'
Assert-Equal -Expected $protectedFixture -Actual (Protect-WdtText -Text $protectedFixture -Context $redactionContext) -Message 'Redaction must be idempotent for an existing context.'

$pathBoundaryContext = New-WdtRedactionContext -ComputerName '' -UserName 'Ann' -UserDomain '' -UserProfile 'C:\Users\Ann'
$pathBoundaryResult = Protect-WdtText -Text 'Other profile: C:\Users\Anna\report.txt' -Context $pathBoundaryContext
Assert-True -Condition $pathBoundaryResult.Contains('C:\Users\<USER-1>\report.txt') -Message 'A longer user-profile name must be redacted as its own profile instead of a partial literal match.'

$canonicalContext = New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile ''
$canonicalResult = Protect-WdtText -Text @'
IPv4 forms: 192.0.2.10. 192.0.2.10:443 192.0.2.10/24
IPv6 forms: [2001:db8::10]:443 and 2001:0db8:0:0:0:0:0:10
IPv6 byte groups: 20:01:0d:b8:00:00:00:01
MAC forms: 00-11-22-33-44-55 and 00:11:22:33:44:55
GUID forms: {12345678-1234-5678-9ABC-1234567890AB} and (12345678-1234-5678-9abc-1234567890ab)
'@ -Context $canonicalContext
Assert-True -Condition ([regex]::IsMatch($canonicalResult, 'IPv4 forms: (?<Token><IP-\d+>)\. \k<Token>:443 \k<Token>/24')) -Message 'IPv4 punctuation, port, and CIDR forms must share one stable token.'
Assert-True -Condition ([regex]::IsMatch($canonicalResult, 'IPv6 forms: \[(?<Token><IP-\d+>)\]:443 and \k<Token>')) -Message 'Equivalent IPv6 spellings must share one stable token.'
Assert-True -Condition ([regex]::IsMatch($canonicalResult, 'IPv6 byte groups: <IP-\d+>')) -Message 'A valid IPv6 address with eight two-digit groups must use an IP token, not a MAC token.'
Assert-True -Condition ([regex]::IsMatch($canonicalResult, 'MAC forms: (?<Token><MAC-\d+>) and \k<Token>')) -Message 'Equivalent MAC spellings must share one stable token.'
Assert-True -Condition ([regex]::IsMatch($canonicalResult, 'GUID forms: (?<Token><ID-\d+>) and \k<Token>')) -Message 'Equivalent GUID spellings must share one stable token.'

$euiContext = New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile ''
$euiResult = Protect-WdtText -Text "PhysicalAddress: 00-11-22-33-44-55-66-77`nMAC: 00:11:22:33:44:55:66:77`nExpanded IPv6: 20:01:0d:b8:00:00:00:01" -Context $euiContext
Assert-Equal -Expected 2 -Actual ([regex]::Matches($euiResult, '<MAC-1>').Count) -Message 'Equivalent labelled EUI-64 formats must share a MAC token.'
Assert-True -Condition $euiResult.Contains('Expanded IPv6: <IP-1>') -Message 'An unlabelled expanded IPv6 address must use an IP token.'

$resetContext = New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile ''
$resetResult = Protect-WdtText -Text 'Addresses: 203.0.113.7:443, 203.0.113.8/24, and 203.0.113.9.' -Context $resetContext
Assert-True -Condition $resetResult.Contains('<IP-1>') -Message 'A new context must reset token numbering.'
Assert-True -Condition $resetResult.Contains('<IP-2>') -Message 'Different values in a new context must increment token numbering.'
Assert-True -Condition $resetResult.Contains('<IP-1>:443') -Message 'An IPv4 address followed by a port must be redacted without removing its port.'
Assert-True -Condition $resetResult.Contains('<IP-2>/24') -Message 'An IPv4 address followed by CIDR must be redacted without removing its prefix length.'
Assert-True -Condition $resetResult.Contains('<IP-3>.') -Message 'Sentence punctuation after an IPv4 address must be preserved.'

$edgeContext = New-WdtRedactionContext -ComputerName 'BUILD' -UserName 'Alice' -UserDomain 'CONTOSO' -UserProfile 'C:\Users\Ann'
$edgeFixture = 'Host: BUILD; apps: BUILD.exe, Alice.exe, Alice.dmp; other profile: C:\Users\Anna\file.txt; IPv6: [::ffff:192.0.2.128]:443 and [fe80::1%12]/64'
$protectedEdgeFixture = Protect-WdtText -Text $edgeFixture -Context $edgeContext
Assert-True -Condition $protectedEdgeFixture.Contains('Host: <HOST-1>') -Message 'A local computer name in an identity field must be redacted.'
Assert-True -Condition $protectedEdgeFixture.Contains('BUILD.exe, Alice.exe, Alice.dmp') -Message 'Computer and user names inside app or dump filenames must be preserved.'
Assert-True -Condition $protectedEdgeFixture.Contains('C:\Users\<USER-1>\file.txt') -Message 'A different profile name must be redacted as a complete path segment.'
Assert-True -Condition $protectedEdgeFixture.Contains('[<IP-1>]:443') -Message 'A bracketed mapped IPv6 address must be redacted without removing its port.'
Assert-True -Condition $protectedEdgeFixture.Contains('[<IP-2>]/64') -Message 'A scoped IPv6 address must be redacted without removing its CIDR prefix length.'

$canonicalContext = New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile ''
$canonicalResult = Protect-WdtText -Text "MAC: 00-11-22-33-44-55 / 00:11:22:33:44:55`nIPv6: 2001:0db8::1 / 2001:db8::1`nGUID: {12345678-1234-5678-9ABC-1234567890AB} / 12345678-1234-5678-9abc-1234567890ab`nLabel : Backup Drive" -Context $canonicalContext
Assert-Equal -Expected 2 -Actual ([regex]::Matches($canonicalResult, '<MAC-1>').Count) -Message 'Equivalent MAC formats must use one stable token.'
Assert-Equal -Expected 2 -Actual ([regex]::Matches($canonicalResult, '<IP-1>').Count) -Message 'Equivalent IPv6 formats must use one stable token.'
Assert-Equal -Expected 2 -Actual ([regex]::Matches($canonicalResult, '<ID-1>').Count) -Message 'Equivalent GUID formats must use one stable token.'
Assert-True -Condition $canonicalResult.Contains('Label : <ID-2>') -Message 'A volume label must be redacted as an identifier.'

$deviceMessageContext = New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile ''
$protectedDeviceMessage = Protect-WdtText -Text 'Message: device (ROOT\NET\0000) failed to start.' -Context $deviceMessageContext
Assert-True -Condition (-not $protectedDeviceMessage.Contains('ROOT\NET\0000')) -Message 'A ROOT device identifier inside free text must be redacted.'
Assert-True -Condition $protectedDeviceMessage.Contains('<ID-1>') -Message 'A ROOT device identifier must use an ID token.'

$emptyLabelContext = New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile ''
$emptyLabelResult = Protect-WdtText -Text 'Label        : ' -Context $emptyLabelContext
Assert-Equal -Expected 'Label        : ' -Actual $emptyLabelResult -Message 'An empty volume label must remain empty and must not consume an ID token.'

$proxyFixture = 'Proxy=proxy-user:proxy-password@proxy.example.test:8443/path?token=top-secret&mode=direct&api_key=second-secret&client_secret=third-secret&refresh_token=fourth-secret&x-amz-signature=fifth-secret'
$protectedProxyFixture = Protect-WdtSensitiveUrlText -Text $proxyFixture
Assert-True -Condition (-not $protectedProxyFixture.Contains('proxy-user:proxy-password')) -Message 'Proxy credentials must be removed independently of Privacy Mode.'
Assert-True -Condition (-not $protectedProxyFixture.Contains('top-secret')) -Message 'A sensitive proxy query value must be removed independently of Privacy Mode.'
Assert-True -Condition (-not $protectedProxyFixture.Contains('second-secret')) -Message 'All sensitive proxy query values must be removed independently of Privacy Mode.'
Assert-True -Condition (-not $protectedProxyFixture.Contains('third-secret')) -Message 'OAuth client secrets must be removed independently of Privacy Mode.'
Assert-True -Condition (-not $protectedProxyFixture.Contains('fourth-secret')) -Message 'Refresh tokens must be removed independently of Privacy Mode.'
Assert-True -Condition (-not $protectedProxyFixture.Contains('fifth-secret')) -Message 'Signed proxy query values must be removed independently of Privacy Mode.'
Assert-True -Condition $protectedProxyFixture.Contains('proxy.example.test:8443/path') -Message 'Proxy host and path must remain useful after credential removal.'
Assert-True -Condition $protectedProxyFixture.Contains('mode=direct') -Message 'Non-sensitive proxy query parameters must remain visible.'

$labelledProxyFixture = Protect-WdtSensitiveUrlText -Text 'WinHTTP Proxy Server(s) : domain\user:password@proxy.example.test:8080'
Assert-True -Condition (-not $labelledProxyFixture.Contains('domain\user:password')) -Message 'Credentials in a labelled proxy value without a URL scheme must be removed.'
Assert-True -Condition $labelledProxyFixture.Contains('proxy.example.test:8080') -Message 'A labelled proxy host must remain visible after credential removal.'

foreach ($proxyLabel in @('Proxy URL:', 'ProxyServer:')) {
    $proxyLabelResult = Protect-WdtSensitiveUrlText -Text ("{0} user:password@proxy.example.test:8080" -f $proxyLabel)
    Assert-True -Condition (-not $proxyLabelResult.Contains('user:password')) -Message ("Credentials were not removed from '{0}'." -f $proxyLabel)
}

$semicolonCredentialFixture = Protect-WdtSensitiveUrlText -Text 'Endpoint=https://user:pa;ss@example.test/path'
Assert-True -Condition (-not $semicolonCredentialFixture.Contains('user:pa;ss')) -Message 'Semicolons in URI userinfo must not bypass credential redaction.'
Assert-True -Condition $semicolonCredentialFixture.Contains('https://<REDACTED>@example.test/path') -Message 'URI host and path must remain visible after semicolon credential redaction.'

$fragmentSecretFixture = Protect-WdtSensitiveUrlText -Text 'https://example.test/callback#access_token=fragment-secret&mode=ok'
Assert-True -Condition (-not $fragmentSecretFixture.Contains('fragment-secret')) -Message 'Sensitive URL fragment values must be redacted.'
Assert-True -Condition $fragmentSecretFixture.Contains('#access_token=<REDACTED>&mode=ok') -Message 'Non-sensitive URL fragment context must remain visible.'

$commandSecretFixtures = @(
    [pscustomobject]@{ Input = 'tool.exe --api-token alpha --mode safe'; Secrets = @('alpha'); Preserved = @('tool.exe', '--mode safe') },
    [pscustomobject]@{ Input = 'tool.exe --api-token=bravo --token charlie --token=delta'; Secrets = @('bravo', 'charlie', 'delta'); Preserved = @('tool.exe') },
    [pscustomobject]@{ Input = 'tool.exe --password "quoted secret" --secret=''single secret'''; Secrets = @('quoted secret', 'single secret'); Preserved = @('tool.exe', '--password "<REDACTED>"', "--secret='<REDACTED>'") },
    [pscustomobject]@{ Input = "tool.exe`t-Key`tEcho-Secret`t/ToKeN:slash-secret --KEY=last-secret"; Secrets = @('Echo-Secret', 'slash-secret', 'last-secret'); Preserved = @('tool.exe') },
    [pscustomobject]@{ Input = 'tool.exe "--token=outer-secret" --password trailing\ --verbose'; Secrets = @('outer-secret', 'trailing\'); Preserved = @('tool.exe', '--verbose') }
)
foreach ($fixture in $commandSecretFixtures) {
    $actual = Protect-WdtCommandLineSecrets -Text $fixture.Input
    foreach ($secretValue in $fixture.Secrets) {
        Assert-True -Condition (-not $actual.Contains($secretValue)) -Message "Command secret '$secretValue' was disclosed on PowerShell $($PSVersionTable.PSVersion)."
    }
    foreach ($preservedValue in $fixture.Preserved) {
        Assert-True -Condition $actual.Contains($preservedValue) -Message "Useful command text '$preservedValue' was removed on PowerShell $($PSVersionTable.PSVersion)."
    }
}

$commandNegativeFixtures = @(
    'tool.exe --mode safe --monkey banana',
    'tool.exe /endpoint:https://example.test/path -KeyboardLayout en-US',
    'tool.exe --tokenizer enabled --password-policy strict'
)
foreach ($fixture in $commandNegativeFixtures) {
    Assert-Equal -Expected $fixture -Actual (Protect-WdtCommandLineSecrets -Text $fixture) -Message "A non-secret command argument changed on PowerShell $($PSVersionTable.PSVersion)."
}

$encodedUrlFixtures = @(
    [pscustomobject]@{ Input = 'https://example.test/?api%5Ftoken=query-secret&mode=ok'; Secret = 'query-secret'; Preserved = 'mode=ok' },
    [pscustomobject]@{ Input = 'https://example.test/#access%2Dtoken=fragment-secret&view=summary'; Secret = 'fragment-secret'; Preserved = 'view=summary' },
    [pscustomobject]@{ Input = 'https://example.test/?client%5Fsecret=client-value&api%2Dkey=key-value'; Secret = 'client-value'; SecondSecret = 'key-value'; Preserved = 'example.test' },
    [pscustomobject]@{ Input = 'https://client%5Fsecret:userinfo-value@example.test/path'; Secret = 'userinfo-value'; Preserved = 'example.test/path' }
)
foreach ($fixture in $encodedUrlFixtures) {
    $actual = Protect-WdtSensitiveUrlText -Text $fixture.Input
    Assert-True -Condition (-not $actual.Contains($fixture.Secret)) -Message "Encoded URL key or userinfo secret '$($fixture.Secret)' was disclosed on PowerShell $($PSVersionTable.PSVersion)."
    if ($fixture.PSObject.Properties.Name -contains 'SecondSecret') {
        Assert-True -Condition (-not $actual.Contains($fixture.SecondSecret)) -Message "Repeated encoded URL secret '$($fixture.SecondSecret)' was disclosed on PowerShell $($PSVersionTable.PSVersion)."
    }
    Assert-True -Condition $actual.Contains($fixture.Preserved) -Message "Non-secret URL context '$($fixture.Preserved)' was removed on PowerShell $($PSVersionTable.PSVersion)."
}

$encodedUrlNegativeFixtures = @(
    'https://example.test/?api%255Ftoken=not-double-decoded&mode=ok',
    'https://example.test/?public%5Fkey=visible-value&access%5Flevel=reader',
    'https://example.test/?caption=client%5Fsecret&mode=ok'
)
foreach ($fixture in $encodedUrlNegativeFixtures) {
    Assert-Equal -Expected $fixture -Actual (Protect-WdtSensitiveUrlText -Text $fixture) -Message "A non-sensitive or double-encoded URL parameter changed on PowerShell $($PSVersionTable.PSVersion)."
}

$privacyCommandContext = New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile ''
$privacyCommand = Protect-WdtText -Text 'CommandLine: tool.exe --token report-secret --mode diagnose' -Context $privacyCommandContext
Assert-True -Condition (-not $privacyCommand.Contains('report-secret')) -Message 'Privacy Mode leaked a command-line secret.'
Assert-True -Condition $privacyCommand.Contains('CommandLine: tool.exe --token <REDACTED> --mode diagnose') -Message 'Privacy Mode removed diagnostically useful command text.'

$findingNonce = '0123456789abcdef0123456789abcdef'
$otherNonce = 'fedcba9876543210fedcba9876543210'
$nonceMarker = ConvertTo-WdtFindingMarker -Severity WARN -Code 'NONCE_WARNING' -Message 'Authenticated protocol output.' -FindingNonce $findingNonce
$legacyMarker = ConvertTo-WdtFindingMarker -Severity WARN -Code 'FORGED_LEGACY' -Message 'Untrusted legacy-looking output.' -FindingNonce ''
$otherNonceMarker = ConvertTo-WdtFindingMarker -Severity WARN -Code 'FORGED_OTHER_NONCE' -Message 'Untrusted nonce-looking output.' -FindingNonce $otherNonce
$nonceResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'Nonce Module' -OutputLines @($legacyMarker, $nonceMarker, $otherNonceMarker)) -FindingNonce $findingNonce
$nonceSummary = Get-WdtFindingsSummary -Results @($nonceResult)
Assert-Equal -Expected 1 -Actual $nonceSummary.WarningCount -Message 'Only the marker carrying the per-process nonce may become a finding.'
Assert-Equal -Expected 'NONCE_WARNING' -Actual $nonceSummary.Items[0].Code -Message 'The authenticated marker was not parsed.'
Assert-Equal -Expected 2 -Actual $nonceResult.OutputLines.Count -Message 'Legacy and foreign-nonce marker lookalikes must remain ordinary output.'
Assert-True -Condition ($nonceResult.OutputLines -contains $legacyMarker) -Message 'A forged legacy marker was removed from ordinary output.'
Assert-True -Condition ($nonceResult.OutputLines -contains $otherNonceMarker) -Message 'A foreign-nonce marker was removed from ordinary output.'

$invalidNonceMarker = (Get-WdtFindingPrefix -FindingNonce $findingNonce) + '{invalid json'
$invalidNonceResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'Invalid Nonce Marker' -OutputLines @($invalidNonceMarker)) -FindingNonce $findingNonce
$invalidNonceSummary = Get-WdtFindingsSummary -Results @($invalidNonceResult)
Assert-Equal -Expected 'FINDING_PROTOCOL_INVALID' -Actual $invalidNonceSummary.Items[0].Code -Message 'An invalid authenticated marker must remain a protocol error.'
Assert-Equal -Expected 0 -Actual $invalidNonceResult.OutputLines.Count -Message 'An invalid authenticated marker must not appear in report details.'
$entrypointPath = Join-Path -Path $repositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1'
$entrypointTokens = $null
$entrypointErrors = $null
$entrypointAst = [System.Management.Automation.Language.Parser]::ParseFile($entrypointPath, [ref]$entrypointTokens, [ref]$entrypointErrors)
Assert-Equal -Expected 0 -Actual @($entrypointErrors).Count -Message 'Entrypoint did not parse for report hardening tests.'
foreach ($functionName in @('Add-MarkdownSection')) {
    $definition = $entrypointAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
    Assert-True -Condition ($null -ne $definition) -Message "Missing report hardening function: $functionName"
    . ([scriptblock]::Create($definition.Extent.Text))
}
$optionalFenceDefinition = $entrypointAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-WdtMarkdownFence' }, $true)
if ($null -ne $optionalFenceDefinition) {
    . ([scriptblock]::Create($optionalFenceDefinition.Extent.Text))
}

$wrongNonceError = ''
try { ConvertFrom-WdtFindingLine -Line $nonceMarker -FindingNonce $otherNonce }
catch { $wrongNonceError = $_.Exception.Message }
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($wrongNonceError)) -Message 'A wrong nonce must reject the finding marker.'
Assert-True -Condition (-not $wrongNonceError.Contains($findingNonce)) -Message 'A user-facing protocol error disclosed the finding nonce.'

$serializationResult = [pscustomobject]@{
    Title = 'Nonce serialization fixture'
    Command = 'fixture'
    ExitCode = 0
    Status = 'Success'
    Duration = [timespan]::Zero
    Completeness = 'Complete'
    OutputLines = @($nonceResult.OutputLines)
    ErrorLines = @()
}
$textSerialization = New-Object System.Collections.Generic.List[string]
$markdownSerialization = New-Object System.Collections.Generic.List[string]
$addTextDefinition = $entrypointAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Add-TextSection' }, $true)
. ([scriptblock]::Create($addTextDefinition.Extent.Text))
Add-TextSection -Lines $textSerialization -Result $serializationResult
Add-MarkdownSection -Lines $markdownSerialization -Result $serializationResult
Assert-True -Condition (-not (($textSerialization -join "`n").Contains($findingNonce))) -Message 'TXT serialization disclosed the active finding nonce.'
Assert-True -Condition (-not (($markdownSerialization -join "`n").Contains($findingNonce))) -Message 'Markdown serialization disclosed the active finding nonce.'

Write-Host 'Report common tests passed.'
