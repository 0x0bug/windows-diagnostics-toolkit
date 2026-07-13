[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$SinceDays = 7,

    [ValidateRange(1, 100)]
    [int]$MaxEvents = 20,

    [switch]$IncludeTimeServiceEvents
)

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\..\modules\time\diagnostic.ps1" @PSBoundParameters
