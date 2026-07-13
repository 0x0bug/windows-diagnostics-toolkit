@{
    SchemaVersion    = 1
    Id               = 'Time'
    Title            = 'Time Sync Diagnostics'
    Label            = 'Time synchronization'
    Description      = 'Inspects Windows time service configuration and synchronization state.'
    EntryPoint       = 'diagnostic.ps1'
    Recommended      = $true
    Order            = 50
    DefaultArguments = @()
    OptionBindings   = @{}
}
