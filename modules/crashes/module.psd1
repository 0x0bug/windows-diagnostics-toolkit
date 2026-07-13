@{
    SchemaVersion    = 1
    Id               = 'Crashes'
    Title            = 'Crash and Hang Diagnostics'
    Label            = 'Crashes and hangs'
    Description      = 'Collects recent crash, hang, reliability, and dump-file evidence.'
    EntryPoint       = 'diagnostic.ps1'
    Recommended      = $false
    Order            = 70
    DefaultArguments = @()
    OptionBindings   = @{}
}
