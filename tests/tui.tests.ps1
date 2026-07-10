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
$readmePath = Join-Path $repositoryRoot 'README.md'
. $catalogPath
. $tuiPath

$readme = Get-Content -LiteralPath $readmePath -Raw
Assert-True ($readme.Contains('powershell.exe -NoProfile -ExecutionPolicy Bypass')) 'README is missing the Windows PowerShell 5.1 launch command.'
Assert-True ($readme.Contains('If PowerShell reports that `pwsh` is not recognized')) 'README is missing pwsh troubleshooting guidance.'
Assert-True ($readme.Contains('installing PowerShell 7 is optional')) 'README does not explain that PowerShell 7 is optional.'
Assert-True (-not $readme.Contains('pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1')) 'README runtime examples still require PowerShell 7.'

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
$normalLayout = Get-WdtTuiLayout -State $renderState -Width 80 -Height 25
$compactLayout = Get-WdtTuiLayout -State $renderState -Width 40 -Height 18
Assert-Equal 'Normal' $normalLayout.Mode '80x25 must select normal layout.'
Assert-Equal 'Normal' (Get-WdtTuiLayout -State $renderState -Width 60 -Height 25).Mode '60x25 must select normal layout.'
Assert-Equal 'Compact' (Get-WdtTuiLayout -State $renderState -Width 59 -Height 25).Mode '59x25 must select compact layout.'
Assert-Equal 'Compact' $compactLayout.Mode '40x18 must select compact layout.'
foreach ($size in @(@(39, 18), @(40, 17), @(20, 10), @(5, 5))) {
    Assert-Equal 'TooSmall' (Get-WdtTuiLayout -State $renderState -Width $size[0] -Height $size[1]).Mode ("{0}x{1} must select TooSmall layout." -f $size[0], $size[1])
}
Assert-True ($normalLayout.Lines.Count -le 25) 'Normal TUI exceeds a 25-row terminal.'
Assert-True ($compactLayout.Lines.Count -le 18) 'Compact TUI exceeds its minimum supported height.'
$compactErrorState = Update-WdtTuiState -State $renderState -Action MoveDown
$compactErrorState.ErrorMessage = 'Sample compact error'
$compactErrorLayout = Get-WdtTuiLayout -State $compactErrorState -Width 40 -Height 18
Assert-True ($compactErrorLayout.Lines.Count -le 18) 'Compact TUI with an error exceeds its minimum supported height.'
Assert-True ((@($compactErrorLayout.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n").Contains('Error: Sample compact error')) 'Compact TUI hides its error message.'
Assert-Equal 3 @($normalLayout.Lines | Select-Object -First 3).Count 'Normal TUI logo must have three lines.'
foreach ($logoLine in @($normalLayout.Lines | Select-Object -First 3)) {
    $logoText = ConvertTo-WdtTuiPlainText -Line $logoLine
    Assert-True ($logoText.Length -le 32) 'TUI logo is wider than 32 characters.'
    Assert-True ($logoText -match '^[ -~]+$') 'TUI logo must be ASCII only.'
    Assert-Equal 'Cyan' $logoLine.Segments[0].Color 'TUI logo must be cyan.'
}
$normalScreen = @($normalLayout.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
$compactScreen = @($compactLayout.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
foreach ($text in @('Windows Diagnostics Toolkit', 'Read-only | Local reports | No telemetry', '[ ]', '[x]', 'Privacy Mode', 'Markdown report', 'Output:', 'Run diagnostics', 'Exit')) {
    Assert-True ($normalScreen.Contains($text)) ("Normal TUI rendering is missing: {0}" -f $text)
}
Assert-True ($compactScreen.Contains('WDT - Windows Diagnostics Toolkit')) 'Compact TUI header is missing.'
Assert-True ($compactScreen.Contains('Selected:')) 'Compact TUI status is missing.'
Assert-True ($compactScreen.Contains('Items ')) 'Compact TUI viewport indicator is missing.'
Assert-True ($compactScreen.Contains('...')) 'Narrow TUI did not truncate the output path.'
Assert-True (-not ($normalScreen -match "`e\[")) 'TUI model must not contain ANSI sequences.'
$allSegments = @($normalLayout.Lines | ForEach-Object { $_.Segments })
Assert-True (@($allSegments | Where-Object { $_.Text -eq '>' -and $_.Color -eq 'Yellow' }).Count -eq 0) 'Pointer unexpectedly lost its trailing space contract.'
Assert-True (@($allSegments | Where-Object { $_.Text -eq '> ' -and $_.Color -eq 'Yellow' }).Count -gt 0) 'Active pointer must be yellow.'
Assert-True (@($allSegments | Where-Object { $_.Text -eq '[x]' -and $_.Color -eq 'Green' }).Count -gt 0) 'Selected checkbox must be green.'
Assert-True (@($allSegments | Where-Object { $_.Text -eq '[ ]' -and $_.Color -eq 'DarkGray' }).Count -gt 0) 'Unselected checkbox must be dark gray.'
Assert-True (@($allSegments | Where-Object { $_.Text -like '*System information*' -and $_.Color -eq 'Gray' }).Count -gt 0) 'Unselected module text must be gray.'
Assert-True (@($allSegments | Where-Object { $_.Text -eq 'Run diagnostics' -and $_.Color -eq 'Green' }).Count -gt 0) 'Run action must be green.'
$privacyOffState = $renderState
for ($move = 0; $move -lt 10; $move++) { $privacyOffState = Update-WdtTuiState -State $privacyOffState -Action MoveDown }
$privacyOffState = Update-WdtTuiState -State $privacyOffState -Action ToggleCurrent
Assert-True (@((Get-WdtTuiLayout -State $privacyOffState -Width 80 -Height 25).Lines | ForEach-Object { $_.Segments } | Where-Object { $_.Text -eq '[ ]' -and $_.Color -eq 'DarkGray' }).Count -gt 0) 'Disabled privacy mode must be dark gray.'
$errorState = Update-WdtTuiState -State $renderState -Action MoveDown
$errorState.ErrorMessage = 'Sample error'
Assert-True (@((Get-WdtTuiLayout -State $errorState -Width 80 -Height 25).Lines | ForEach-Object { $_.Segments } | Where-Object { $_.Color -eq 'Red' }).Count -gt 0) 'Error must have a red segment.'
$warningResult = [pscustomobject]@{ ExitCode = 1 }
Assert-Equal 'Yellow' (Get-WdtTuiRunResultLayout -Result $warningResult)[0].Segments[0].Color 'Partial result must be yellow.'
foreach ($width in 1..5) { foreach ($line in @((Get-WdtTuiLayout -State $renderState -Width $width -Height 5).Lines)) { Assert-True ((ConvertTo-WdtTuiPlainText -Line $line).Length -le $width) 'Too-small text exceeded its width.' } }
foreach ($size in @(@(80, 25), @(60, 25), @(59, 25), @(40, 18), @(39, 18), @(40, 17), @(20, 10), @(5, 5))) { foreach ($line in @((Get-WdtTuiLayout -State $renderState -Width $size[0] -Height $size[1]).Lines)) { Assert-True ((ConvertTo-WdtTuiPlainText -Line $line).Length -le $size[0]) ("Layout exceeded {0} columns." -f $size[0]) } }
$lastItemState = $renderState
for ($move = 0; $move -lt 14; $move++) { $lastItemState = Update-WdtTuiState -State $lastItemState -Action MoveDown }
$lastCompact = Get-WdtTuiLayout -State $lastItemState -Width 40 -Height 18
Assert-True ($lastItemState.CursorIndex -ge $lastCompact.Viewport.Start -and $lastItemState.CursorIndex -le $lastCompact.Viewport.End) 'Active item is outside the compact viewport.'
Assert-True ((@($lastCompact.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n").Contains('Exit')) 'Exit is unreachable in compact viewport.'
$middleItemState = $renderState
for ($move = 0; $move -lt 7; $move++) { $middleItemState = Update-WdtTuiState -State $middleItemState -Action MoveDown }
$middleCompact = Get-WdtTuiLayout -State $middleItemState -Width 40 -Height 18
Assert-True ($middleItemState.CursorIndex -ge $middleCompact.Viewport.Start -and $middleItemState.CursorIndex -le $middleCompact.Viewport.End) 'Middle compact cursor is outside the viewport.'
$firstCompact = Get-WdtTuiLayout -State $renderState -Width 40 -Height 18
Assert-True ($renderState.CursorIndex -ge $firstCompact.Viewport.Start -and $renderState.CursorIndex -le $firstCompact.Viewport.End) 'First compact cursor is outside the viewport.'
$runState = $renderState
for ($move = 0; $move -lt 13; $move++) { $runState = Update-WdtTuiState -State $runState -Action MoveDown }
Assert-True ((@((Get-WdtTuiLayout -State $runState -Width 40 -Height 18).Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n").Contains('Run diagnostics')) 'Run is unreachable in compact viewport.'
$tooSmallText = @((Get-WdtTuiLayout -State $renderState -Width 20 -Height 10).Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
Assert-True ($tooSmallText.Contains('20x10')) 'TooSmall layout does not report the current size.'
Assert-Equal 'Exit' (ConvertTo-WdtTuiFallbackAction -Answer 'Exit') 'TooSmall fallback Exit was not recognized.'
Assert-Equal $null (ConvertTo-WdtTuiFallbackAction -Answer '') 'TooSmall fallback Enter should only redraw.'

$longLabelItem = [pscustomobject]@{ Kind = 'Diagnostic'; Name = 'System'; Label = ('L' * 120) }
foreach ($width in @(40, 10, 6, 5, 1)) {
    $longLabelLine = New-WdtTuiMenuLine -State $renderState -Item $longLabelItem -Index 0 -Width $width -ShowItemNumbers $false
    Assert-True ((ConvertTo-WdtTuiPlainText -Line $longLabelLine).Length -le $width) ("Long menu line exceeds width {0}." -f $width)
}

$numberedFirst = Get-WdtTuiLayout -State $renderState -Width 40 -Height 18 -ShowItemNumbers $true
$numberedFirstText = @($numberedFirst.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
Assert-True ($numberedFirstText.Contains('1.')) 'Numbered fallback does not number the first item.'
$numberedMiddle = Get-WdtTuiLayout -State $lastItemState -Width 40 -Height 18 -ShowItemNumbers $true
$numberedMiddleText = @($numberedMiddle.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
Assert-True ($numberedMiddleText.Contains('15.')) 'Numbered fallback does not preserve global viewport numbers.'
Assert-True ($numberedMiddleText.Contains('14.')) 'Numbered fallback does not number Run.'
Assert-True (-not $compactScreen.Contains('1.')) 'Keyboard layout unexpectedly displays item numbers.'
$runIndex = Get-WdtTuiMenuIndex -State $renderState -Kind 'Run'
$numberAction = ConvertTo-WdtTuiFallbackMenuAction -Answer '15' -VisibleIndexes $numberedMiddle.VisibleIndexes -RunIndex $runIndex
Assert-Equal 'Select' $numberAction.Action 'Visible number did not select an item.'
Assert-Equal 14 $numberAction.Index 'Visible number did not map to the global cursor index.'
Assert-Equal $null (ConvertTo-WdtTuiFallbackMenuAction -Answer '15' -VisibleIndexes @(0, 1) -RunIndex $runIndex) 'Hidden item number was accepted.'

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
    foreach ($report in @(Get-ChildItem -LiteralPath $cliOutput -Filter 'WindowsDiagnosticsReport-*' -File)) {
        Assert-True (-not ((Get-Content -LiteralPath $report.FullName -Raw) -match "`e\[")) ("Report contains an ANSI sequence: {0}" -f $report.Name)
    }
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
    $redirectedOutput = Join-Path $env:TEMP ('wdt-tui-redirected-' + [guid]::NewGuid().ToString('N'))
    try {
        $childOutput = @('') | & $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $entrypointPath @($routingCase.Arguments) -OutputDirectory $redirectedOutput 2>&1
        Assert-Equal 2 $LASTEXITCODE ("Redirected stdin exit code is incorrect for {0}." -f $routingCase.Name)
        $childText = $childOutput -join "`n"
        Assert-True ($childText.Contains('Interactive input is unavailable.')) ("Redirected stdin message is missing for {0}." -f $routingCase.Name)
        Assert-True ($childText.Contains('Use -All or select one or more diagnostic modules.')) ("Redirected stdin guidance is missing for {0}." -f $routingCase.Name)
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $redirectedOutput -Filter 'WindowsDiagnosticsReport-*' -File -ErrorAction SilentlyContinue).Count ("Redirected stdin created a report for {0}." -f $routingCase.Name)
    }
    finally {
        if (Test-Path -LiteralPath $redirectedOutput) { Remove-Item -LiteralPath $redirectedOutput -Recurse -Force }
    }
}
$global:LASTEXITCODE = 0

foreach ($routingCase in @(
        [pscustomobject]@{ Arguments = @('-System'); Expected = 'CommandLine' },
        [pscustomobject]@{ Arguments = @('-All'); Expected = 'CommandLine' }
    )) {
    Assert-Equal $routingCase.Expected (Get-WdtLaunchMode -InteractiveRequested $false -HasExplicitModuleSelection ($routingCase.Arguments -contains '-System') -AllRequested ($routingCase.Arguments -contains '-All') -IsInputRedirected $true) 'CLI switches must bypass the TUI under redirected input.'
}

Write-Host 'Interactive TUI tests passed.'
