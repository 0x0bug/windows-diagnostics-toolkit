@{
    SchemaVersion    = 1
    Id               = 'Security'
    Title            = 'Security Posture'
    Label            = 'Security posture'
    Description      = 'Reviews built-in Windows security controls and their current state.'
    EntryPoint       = 'diagnostic.ps1'
    Recommended      = $true
    Order            = 20
    DefaultArguments = @()
    OptionBindings   = @{}
}
