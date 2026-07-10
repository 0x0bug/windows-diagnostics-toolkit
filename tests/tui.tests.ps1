[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw ("{0} Expected={1}; Actual={2}" -f $Message, $Expected, $Actual) } }
function Assert-Throws {
    param([scriptblock]$ScriptBlock, [string]$Pattern, [string]$Message)
    try { & $ScriptBlock; throw $Message }
    catch {
        if ($_.Exception.Message -eq $Message) { throw }
        Assert-True ($_.Exception.Message -like $Pattern) ("Unexpected error: {0}" -f $_.Exception.Message)
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$catalogPath = Join-Path $repositoryRoot 'scripts\diagnostic-catalog.ps1'
$tuiPath = Join-Path $repositoryRoot 'scripts\tui.ps1'
$entrypointPath = Join-Path $repositoryRoot 'Invoke-WindowsDiagnostics.ps1'
. $catalogPath
. $tuiPath

foreach ($path in @($catalogPath, $tuiPath, $entrypointPath)) {
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    Assert-Equal 0 @($parseErrors).Count ("PowerShell source must parse: {0}" -f $path)
}

$catalog = @(Get-WdtDiagnosticDefinition)
Assert-Equal 10 $catalog.Count 'Diagnostic catalog count is incorrect.'
Assert-Equal 'Label,Name,Recommended,Script,Title' (($catalog[0].PSObject.Properties.Name | Sort-Object) -join ',') 'Diagnostic catalog fields are incorrect.'
Assert-Equal 10 @($catalog.Name | Sort-Object -Unique).Count 'Diagnostic names are not unique.'
Assert-Equal 10 @($catalog.Script | Sort-Object -Unique).Count 'Diagnostic scripts are not unique.'
Assert-True (@($catalog | Where-Object { $_.Recommended }).Count -gt 0) 'Catalog has no recommended diagnostics.'
foreach ($definition in $catalog) {
    Assert-True (Test-Path -LiteralPath (Join-Path $repositoryRoot ("scripts\{0}" -f $definition.Script)) -PathType Leaf) ("Missing diagnostic script: {0}" -f $definition.Script)
}

$launchCases = @(
    [pscustomobject]@{ Interactive = $false; Explicit = $false; All = $false; Redirected = $false; Expected = 'Interactive' },
    [pscustomobject]@{ Interactive = $true; Explicit = $false; All = $false; Redirected = $false; Expected = 'Interactive' },
    [pscustomobject]@{ Interactive = $false; Explicit = $false; All = $true; Redirected = $true; Expected = 'CommandLine' },
    [pscustomobject]@{ Interactive = $false; Explicit = $true; All = $false; Redirected = $true; Expected = 'CommandLine' },
    [pscustomobject]@{ Interactive = $true; Explicit = $true; All = $false; Redirected = $false; Expected = 'Interactive' },
    [pscustomobject]@{ Interactive = $false; Explicit = $false; All = $false; Redirected = $true; Expected = 'InteractiveUnavailable' },
    [pscustomobject]@{ Interactive = $true; Explicit = $false; All = $false; Redirected = $true; Expected = 'InteractiveUnavailable' }
)
foreach ($case in $launchCases) {
    $mode = Get-WdtLaunchMode -InteractiveRequested $case.Interactive -HasExplicitModuleSelection $case.Explicit -AllRequested $case.All -IsInputRedirected $case.Redirected
    Assert-Equal $case.Expected $mode 'Launch mode routing is incorrect.'
}

$state = New-WdtTuiState -OutputDirectory 'C:\Reports'
Assert-Equal @($catalog | Where-Object Recommended).Count @(Get-WdtTuiSelectedModule -State $state).Count 'Recommended selection count is incorrect.'
Assert-True ($state.PrivacyMode) 'Privacy mode must be enabled by default.'
Assert-True ($state.ExportMarkdown) 'Markdown export must be enabled by default.'
Assert-Equal 'C:\Reports' $state.OutputDirectory 'Initial output directory is incorrect.'

$menuCount = @(Get-WdtTuiMenuItem -State $state).Count
$originalState = $state
$originalFirstSelection = $state.Diagnostics[0].Selected
$state = Update-WdtTuiState -State $state -Action MoveUp
Assert-True ($state -ne $originalState) 'State transition returned the input object.'
Assert-Equal $originalFirstSelection $originalState.Diagnostics[0].Selected 'State transition mutated the input diagnostics.'
Assert-True ($state.Diagnostics[0] -ne $originalState.Diagnostics[0]) 'State transition did not clone diagnostics.'
Assert-Equal ($menuCount - 1) $state.CursorIndex 'MoveUp did not wrap.'
$state = Update-WdtTuiState -State $state -Action MoveDown
Assert-Equal 0 $state.CursorIndex 'MoveDown did not wrap.'
$beforeToggle = $state.Diagnostics[0].Selected
$state = Update-WdtTuiState -State $state -Action ToggleCurrent
Assert-True ($state.Diagnostics[0].Selected -ne $beforeToggle) 'Current diagnostic was not toggled.'
$state.CursorIndex = $state.Diagnostics.Count
$state = Update-WdtTuiState -State $state -Action ToggleCurrent
Assert-True (-not $state.PrivacyMode) 'Privacy mode was not toggled.'
$state.CursorIndex = $state.Diagnostics.Count + 1
$state = Update-WdtTuiState -State $state -Action ToggleCurrent
Assert-True (-not $state.ExportMarkdown) 'Markdown export was not toggled.'
$state = Update-WdtTuiState -State $state -Action SelectAll
Assert-Equal 10 @(Get-WdtTuiSelectedModule -State $state).Count 'SelectAll failed.'
$state = Update-WdtTuiState -State $state -Action SelectRecommended
Assert-Equal @($catalog | Where-Object Recommended).Count @(Get-WdtTuiSelectedModule -State $state).Count 'SelectRecommended failed.'
$state = Update-WdtTuiState -State $state -Action SetOutputDirectory -Value 'D:\Reports'
Assert-Equal 'D:\Reports' $state.OutputDirectory 'Output directory transition failed.'
$state = Update-WdtTuiState -State $state -Action Exit
Assert-True ($state.ExitRequested) 'Exit transition failed.'
Assert-True ($state.CursorIndex -ge 0 -and $state.CursorIndex -lt $menuCount) 'Cursor is outside menu bounds.'

$renderState = New-WdtTuiState -OutputDirectory ('C:\A\Very\Long\Report\Directory\That\Must\Be\Truncated\For\Narrow\Terminals')
$renderState.Diagnostics[0].Selected = $false
$normalLayout = @(Get-WdtTuiLayout -State $renderState -Width 80 -Height 25)
$compactLayout = @(Get-WdtTuiLayout -State $renderState -Width 40 -Height 20)
Assert-True ($normalLayout.Count -le 25) 'Normal TUI exceeds a 25-row terminal.'
Assert-True ($compactLayout.Count -lt $normalLayout.Count) 'Compact TUI did not reduce its layout.'
Assert-Equal 4 @($normalLayout | Select-Object -First 4).Count 'Normal TUI logo must have four lines.'
foreach ($logoLine in @($normalLayout | Select-Object -First 4)) {
    Assert-True ($logoLine.Text.Length -le 32) 'TUI logo is wider than 32 characters.'
    Assert-True ($logoLine.Text -match '^[ -~]+$') 'TUI logo must be ASCII only.'
}
$normalScreen = @($normalLayout | ForEach-Object Text) -join "`n"
$compactScreen = @($compactLayout | ForEach-Object Text) -join "`n"
foreach ($text in @('Read-only | Local reports | No telemetry', '[ ]', '[x]', 'Privacy mode', 'Markdown report', 'Output:', 'Run diagnostics')) {
    Assert-True ($normalScreen.Contains($text)) ("Normal TUI rendering is missing: {0}" -f $text)
}
Assert-True ($compactScreen.Contains('WDT | Read-only | Local reports | No telemetry')) 'Compact TUI header is missing.'
Assert-True ($compactScreen.Contains('...')) 'Narrow TUI did not truncate the output path.'
Assert-True (-not ($normalScreen -match "`e\[")) 'TUI model must not contain ANSI sequences.'
Assert-True (@($normalLayout | Where-Object { $_.Role -eq 'Header' }).Count -gt 0) 'TUI layout has no header role.'
Assert-True (@($normalLayout | Where-Object { $_.Role -eq 'Success' }).Count -gt 0) 'TUI layout has no success role.'
Assert-True (@($normalLayout | Where-Object { $_.Role -eq 'Selected' }).Count -gt 0) 'TUI layout has no selected role.'

$parameters = ConvertTo-WdtReportParameters -State $renderState
Assert-Equal @(Get-WdtTuiSelectedModule -State $renderState).Count @($parameters.SelectedModules).Count 'Selected modules were not preserved in report parameters.'

$tokens = $null; $parseErrors = $null
$entrypointAst = [System.Management.Automation.Language.Parser]::ParseFile($entrypointPath, [ref]$tokens, [ref]$parseErrors)
$runnerFunction = @($entrypointAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-WdtReport' }, $true))
Assert-Equal 1 $runnerFunction.Count 'Invoke-WdtReport is missing.'
. ([scriptblock]::Create($runnerFunction[0].Extent.Text))
Assert-Throws { Invoke-WdtReport -SelectedModules @() -OutputDirectory 'C:\Reports' } '*At least one diagnostic module*' 'Empty runner selection was accepted.'
Assert-Throws { Invoke-WdtReport -SelectedModules @('Unknown') -OutputDirectory 'C:\Reports' } '*Unknown diagnostic module*' 'Unknown runner module was accepted.'

$tuiImports = @($entrypointAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -and $node.Extent.Text -eq '. $PSScriptRoot\scripts\tui.ps1' }, $true))
Assert-Equal 1 $tuiImports.Count 'Entrypoint TUI import is missing.'
$parent = $tuiImports[0].Parent
while ($null -ne $parent -and $parent -isnot [System.Management.Automation.Language.IfStatementAst]) { $parent = $parent.Parent }
Assert-True ($null -ne $parent -and $parent.Extent.Text -match '\$launchMode\s+-eq\s+''Interactive''') 'TUI import is not isolated to interactive launch mode.'

$cliOutput = Join-Path $env:TEMP ('wdt-tui-cli-' + [guid]::NewGuid().ToString('N'))
try {
    & $entrypointPath -System -PrivacyMode -ExportMarkdown -OutputDirectory $cliOutput
    Assert-True (@(Get-ChildItem -LiteralPath $cliOutput -Filter 'WindowsDiagnosticsReport-*.txt' -File).Count -ge 1) 'CLI mode did not create a TXT report.'
    Assert-True (@(Get-ChildItem -LiteralPath $cliOutput -Filter 'WindowsDiagnosticsReport-*.md' -File).Count -ge 1) 'CLI mode did not create a Markdown report.'
}
finally {
    if (Test-Path -LiteralPath $cliOutput) { Remove-Item -LiteralPath $cliOutput -Recurse -Force }
}

$hostExecutable = (Get-Process -Id $PID).Path
foreach ($routingCase in @(
        [pscustomobject]@{ Arguments = @(); Name = 'no arguments' },
        [pscustomobject]@{ Arguments = @('-Interactive'); Name = 'interactive' },
        [pscustomobject]@{ Arguments = @('-Interactive', '-System'); Name = 'interactive system' },
        [pscustomobject]@{ Arguments = @('-Interactive', '-All'); Name = 'interactive all' }
    )) {
    $childOutput = @('') | & $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $entrypointPath @($routingCase.Arguments) 2>&1
    Assert-Equal 2 $LASTEXITCODE ("Redirected stdin exit code is incorrect for {0}." -f $routingCase.Name)
    $childText = $childOutput -join "`n"
    Assert-True ($childText.Contains('Interactive input is unavailable.')) ("Redirected stdin message is missing for {0}." -f $routingCase.Name)
    Assert-True ($childText.Contains('Use -All or select one or more diagnostic modules.')) ("Redirected stdin guidance is missing for {0}." -f $routingCase.Name)
}

foreach ($routingCase in @(
        [pscustomobject]@{ Arguments = @('-System'); Expected = 'CommandLine' },
        [pscustomobject]@{ Arguments = @('-All'); Expected = 'CommandLine' }
    )) {
    Assert-Equal $routingCase.Expected (Get-WdtLaunchMode -InteractiveRequested $false -HasExplicitModuleSelection ($routingCase.Arguments -contains '-System') -AllRequested ($routingCase.Arguments -contains '-All') -IsInputRedirected $true) 'CLI switches must bypass the TUI under redirected input.'
}

Write-Host 'Interactive TUI tests passed.'
