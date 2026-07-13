@{
    SchemaVersion    = 1
    Id               = 'Events'
    Title            = 'Event Log Check'
    Label            = 'Event logs'
    Description      = 'Summarizes recent critical and error events from Windows logs.'
    EntryPoint       = 'diagnostic.ps1'
    Recommended      = $false
    Order            = 80
    DefaultArguments = @()
    OptionBindings   = @{}
}
