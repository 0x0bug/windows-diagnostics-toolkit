[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\..\modules\system\diagnostic.ps1" @PSBoundParameters
