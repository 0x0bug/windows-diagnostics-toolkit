@{
    SchemaVersion    = 1
    Id               = 'Performance'
    Title            = 'Performance Snapshot'
    Label            = 'Performance snapshot'
    Description      = 'Captures current resource usage and the highest-impact processes.'
    EntryPoint       = 'diagnostic.ps1'
    Recommended      = $true
    Order            = 30
    DefaultArguments = @()
    OptionBindings   = @{}
}
