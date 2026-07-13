@{
    SchemaVersion    = 1
    Id               = 'Disk'
    Title            = 'Storage Status'
    Label            = 'Storage status'
    Description      = 'Reports fixed-volume capacity, free space, and storage health signals.'
    EntryPoint       = 'diagnostic.ps1'
    Recommended      = $true
    Order            = 60
    DefaultArguments = @()
    OptionBindings   = @{}
}
