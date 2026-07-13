[CmdletBinding()]
param(
    [ValidateRange(1, 100)]
    [int]$TopProcessCount = 10,

    [ValidateRange(1, 99)]
    [int]$LowMemoryPercent = 15,

    [ValidateRange(1, 100)]
    [int]$HighCpuPercent = 95
)

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\..\modules\performance\diagnostic.ps1" @PSBoundParameters
