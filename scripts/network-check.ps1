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

& "$PSScriptRoot\..\modules\network\diagnostic.ps1" @PSBoundParameters
