[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) } }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$tuiPath = Join-Path $repositoryRoot 'scripts\tui.ps1'
. $tuiPath

$tokens = $null; $parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($tuiPath, [ref]$tokens, [ref]$parseErrors)
Assert-Equal 0 @($parseErrors).Count 'TUI must parse in the active PowerShell version.'

$state = New-WdtTuiState -OutputDirectory 'C:\Reports'
Assert-Equal 7 @(Get-WdtTuiSelectedModule -State $state).Count 'Recommended selection count is incorrect.'
Assert-True ($state.PrivacyMode) 'Privacy mode must be enabled by default.'
Assert-True ($state.ExportMarkdown) 'Markdown export must be enabled by default.'

$explicitState = New-WdtTuiState -OutputDirectory 'C:\Reports' -InitialSelection @('Crashes')
Assert-Equal 1 @(Get-WdtTuiSelectedModule -State $explicitState).Count 'Explicit initial selection was not preserved.'
Assert-Equal 'Crashes' @(Get-WdtTuiSelectedModule -State $explicitState)[0] 'Explicit initial module is incorrect.'

$state = Set-WdtAllSelection -State $state
Assert-Equal 10 @(Get-WdtTuiSelectedModule -State $state).Count 'Select all did not select every diagnostic.'
$state = Switch-WdtDiagnosticSelection -State $state -Name 'Events'
Assert-Equal 9 @(Get-WdtTuiSelectedModule -State $state).Count 'Single diagnostic toggle failed.'
$state = Set-WdtRecommendedSelection -State $state
Assert-Equal 7 @(Get-WdtTuiSelectedModule -State $state).Count 'Recommended reset failed.'

foreach ($diagnostic in $state.Diagnostics) { $diagnostic.Selected = $false }
Assert-Equal 0 @(Get-WdtTuiSelectedModule -State $state).Count 'Empty selection was not preserved.'
$state.Diagnostics[0].Selected = $true
$parameters = ConvertTo-WdtReportParameters -State $state
Assert-Equal 'System' $parameters.SelectedModules[0] 'Selection was not converted to report parameters.'
Assert-Equal 'C:\Reports' $parameters.OutputDirectory 'Output directory was not preserved.'
Assert-True ($parameters.PrivacyMode -and $parameters.ExportMarkdown) 'Report options were not converted.'

$state.Diagnostics[1].Selected = $false
$lines = @(Get-WdtTuiLines -State $state -Width 60)
$screen = $lines -join "`n"
foreach ($text in @('Windows Diagnostics Toolkit', '[', ']', 'Run diagnostics', 'Privacy mode', 'Space Toggle', 'A Select all')) {
    Assert-True ($screen.Contains($text)) ("TUI rendering is missing: {0}" -f $text)
}
Assert-True ($screen.Contains(([char]0x2713))) 'TUI rendering does not contain the selected marker.'
Assert-True ($screen.Contains('[ ]')) 'TUI rendering does not contain an unselected marker.'
[void](Get-WdtTuiLines -State $state -Width 30)

$state = Set-WdtTuiCancelled -State $state
Assert-True ($state.ExitRequested) 'Cancel state was not recorded.'

Write-Host 'Interactive TUI tests passed.'
