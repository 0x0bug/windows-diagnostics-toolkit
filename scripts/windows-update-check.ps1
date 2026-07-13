[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$SinceDays = 30,

    [ValidateRange(1, 500)]
    [int]$MaxEvents = 50,

    [switch]$IncludeEventLog
)

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\..\modules\updates\diagnostic.ps1" @PSBoundParameters
