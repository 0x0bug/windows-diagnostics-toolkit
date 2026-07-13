@{
    SchemaVersion    = 1
    Id               = 'Services'
    Title            = 'Services and Startup'
    Label            = 'Services and startup'
    Description      = 'Reviews service state together with startup and scheduled-task entries.'
    EntryPoint       = 'diagnostic.ps1'
    Recommended      = $false
    Order            = 90
    DefaultArguments = @('-IncludeStartup', '-IncludeScheduledTasks')
    OptionBindings   = @{}
}
