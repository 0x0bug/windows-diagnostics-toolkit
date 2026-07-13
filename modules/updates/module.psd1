@{
    SchemaVersion    = 1
    Id               = 'Updates'
    Title            = 'Windows Update Check'
    Label            = 'Windows Update'
    Description      = 'Checks Windows Update services, policy, history, and reboot state.'
    EntryPoint       = 'diagnostic.ps1'
    Recommended      = $true
    Order            = 100
    DefaultArguments = @()
    OptionBindings   = @{}
}
