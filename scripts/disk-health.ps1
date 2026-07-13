[CmdletBinding()]
param(
    [ValidateRange(1, 99)]
    [int]$LowFreeSpacePercent = 15
)

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\..\modules\disk\diagnostic.ps1" @PSBoundParameters
