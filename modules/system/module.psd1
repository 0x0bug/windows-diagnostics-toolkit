@{
    SchemaVersion    = 1
    Id               = 'System'
    Title            = 'System Information'
    Label            = 'System information'
    Description      = 'Collects operating system, hardware, and environment information.'
    EntryPoint       = 'diagnostic.ps1'
    Recommended      = $true
    Order            = 10
    DefaultArguments = @()
    OptionBindings   = @{}
}
