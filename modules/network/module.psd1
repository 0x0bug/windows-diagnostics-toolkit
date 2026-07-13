@{
    SchemaVersion    = 1
    Id               = 'Network'
    Title            = 'Network Check'
    Label            = 'Network'
    Description      = 'Checks adapters, routes, DNS, HTTPS, and optional external connectivity.'
    EntryPoint       = 'diagnostic.ps1'
    Recommended      = $true
    Order            = 40
    DefaultArguments = @()
    OptionBindings   = @{
        NoExternalNetworkTests = 'NoExternalNetworkTests'
        NetworkDnsTestName     = 'DnsTestName'
        NetworkHttpsEndpoint   = 'HttpsEndpoint'
        NetworkIcmpTarget      = 'IcmpTarget'
    }
}
