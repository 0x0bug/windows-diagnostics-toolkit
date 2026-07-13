[CmdletBinding()]
param(
    [switch]$IncludeRunning,

    [ValidateRange(1, 500)]
    [int]$MaxItems = 50,

    [switch]$IncludeStartup,

    [switch]$IncludeScheduledTasks
)

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\..\modules\services\diagnostic.ps1" @PSBoundParameters
