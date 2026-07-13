[CmdletBinding()]
param(
    [ValidateRange(1, 720)]
    [int]$SinceHours = 24,

    [switch]$IncludeWarnings,

    [ValidateRange(1, 500)]
    [int]$MaxEvents = 50
)

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\..\modules\events\diagnostic.ps1" @PSBoundParameters
