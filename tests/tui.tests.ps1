[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\diagnostic-catalog.ps1')
. (Join-Path $repositoryRoot 'scripts\tui.ps1')
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }

$catalog = @(Get-WdtDiagnosticDefinition)
$state = New-WdtTuiState -OutputDirectory 'C:\Reports'
Assert-Equal 10 $catalog.Count 'Diagnostic catalog count is incorrect.'
Assert-Equal @($catalog | Where-Object Recommended).Count @(Get-WdtTuiSelectedModule $state).Count 'Default selection is incorrect.'
Assert-True $state.PrivacyMode 'Privacy mode must be enabled by default.'
Assert-True $state.ExportMarkdown 'Markdown export must be enabled by default.'

$originalSelection = $state.Diagnostics[0].Selected
$updated = Update-WdtTuiState $state ToggleCurrent
Assert-True ($updated -ne $state) 'State update must return a new state.'
Assert-Equal (-not $originalSelection) $updated.Diagnostics[0].Selected 'Toggle did not change selection.'
$moved = Update-WdtTuiState $updated MoveDown
Assert-Equal 1 $moved.CursorIndex 'MoveDown did not advance cursor.'

foreach ($case in @(
    [pscustomobject]@{ Width=140; Height=36; Mode='Wide' },
    [pscustomobject]@{ Width=80; Height=25; Mode='Normal' },
    [pscustomobject]@{ Width=59; Height=25; Mode='Compact' },
    [pscustomobject]@{ Width=20; Height=10; Mode='TooSmall' }
)) {
    $layout = Get-WdtTuiLayout -State $state -Width $case.Width -Height $case.Height
    Assert-Equal $case.Mode $layout.Mode "Unexpected layout for $($case.Width)x$($case.Height)."
    Assert-True ($layout.Lines.Count -le $case.Height) 'Layout exceeds terminal height.'
    foreach ($line in $layout.Lines) { Assert-True (($line.Segments | ForEach-Object Text) -join '').Length -le $case.Width 'Layout exceeds terminal width.' }
}

foreach ($diagnostic in $state.Diagnostics) { $diagnostic.Selected = ($diagnostic.Name -eq 'Network') }
$parameters = ConvertTo-WdtReportParameters -State $state -ModuleTimeoutSeconds 37 -NoExternalNetworkTests $true -NetworkDnsTestName 'dns.fixture.example' -NetworkHttpsEndpoint 'https://tcp.fixture.example/' -NetworkIcmpTarget '192.0.2.44'
Assert-Equal @('Network') @($parameters.SelectedModules) 'Selected modules were not preserved.'
Assert-True $parameters.SuppressConsoleOutput 'TUI must suppress report console output.'
Assert-Equal 37 $parameters.ModuleTimeoutSeconds 'ModuleTimeoutSeconds was not preserved.'
Assert-Equal $true $parameters.NoExternalNetworkTests 'NoExternalNetworkTests was not preserved.'
Assert-Equal 'dns.fixture.example' $parameters.NetworkDnsTestName 'DNS name was not preserved.'
Assert-Equal 'https://tcp.fixture.example/' $parameters.NetworkHttpsEndpoint 'TCP endpoint was not preserved.'
Assert-Equal '192.0.2.44' $parameters.NetworkIcmpTarget 'ICMP target was not preserved.'

Write-Host 'TUI state, layout, and parameter conversion tests passed.'
