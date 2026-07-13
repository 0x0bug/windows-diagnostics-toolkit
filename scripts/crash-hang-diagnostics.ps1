[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$SinceDays = 7,

    [ValidateRange(1, 500)]
    [int]$MaxEvents = 50,

    [ValidateRange(1, 100)]
    [int]$MaxDumpFiles = 20
)

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\..\modules\crashes\diagnostic.ps1" @PSBoundParameters
