[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\..\modules\security\diagnostic.ps1" @PSBoundParameters
