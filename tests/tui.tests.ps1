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

foreach ($case in @(
    [pscustomobject]@{ FrameHeight=0; BufferHeight=25; Expected=0 },
    [pscustomobject]@{ FrameHeight=1; BufferHeight=25; Expected=0 },
    [pscustomobject]@{ FrameHeight=18; BufferHeight=25; Expected=17 },
    [pscustomobject]@{ FrameHeight=25; BufferHeight=25; Expected=24 },
    [pscustomobject]@{ FrameHeight=40; BufferHeight=25; Expected=24 }
)) {
    $anchorRow = Get-WdtTuiExitAnchorRow -FrameHeight $case.FrameHeight -BufferHeight $case.BufferHeight
    Assert-Equal $case.Expected $anchorRow "Unexpected exit anchor for frame=$($case.FrameHeight), buffer=$($case.BufferHeight)."
    Assert-True ($anchorRow -ge 0) 'TUI exit anchor must not be negative.'
    Assert-True ($anchorRow -le ($case.BufferHeight - 1)) 'TUI exit anchor exceeds the console buffer.'
}

$tokens = $null; $parseErrors = $null
$tuiAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'scripts\tui.ps1'), [ref]$tokens, [ref]$parseErrors)
$interactiveSession = $tuiAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-WdtInteractiveSession' }, $true)
$cleanupCalls = @($interactiveSession.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Complete-WdtTuiConsoleFrame' }, $true))
Assert-Equal 1 $cleanupCalls.Count 'Interactive session must call the centralized console cleanup exactly once.'
$cleanupOwner = $cleanupCalls[0].Parent
while ($null -ne $cleanupOwner -and $cleanupOwner -isnot [Management.Automation.Language.TrapStatementAst] -and $cleanupOwner -isnot [Management.Automation.Language.TryStatementAst]) { $cleanupOwner = $cleanupOwner.Parent }
Assert-True ($null -ne $cleanupOwner -and $cleanupCalls[0].Extent.StartLineNumber -ge $cleanupOwner.Finally.Extent.StartLineNumber) 'Centralized console cleanup must be called from finally.'

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
