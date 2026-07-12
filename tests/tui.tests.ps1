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
$wideLayout = Get-WdtTuiLayout -State $renderState -Width 120 -Height 30
$normalLayout = Get-WdtTuiLayout -State $renderState -Width 80 -Height 25
$compactLayout = Get-WdtTuiLayout -State $renderState -Width 40 -Height 18
Assert-Equal 'Wide' (Get-WdtTuiLayout -State $renderState -Width 140 -Height 36).Mode '140x36 must select wide layout.'
Assert-Equal 'Wide' $wideLayout.Mode '120x30 must select wide layout.'
Assert-Equal 'Wide' (Get-WdtTuiLayout -State $renderState -Width 110 -Height 28).Mode '110x28 must select wide layout.'
Assert-Equal 'WideShort' (Get-WdtTuiLayout -State $renderState -Width 120 -Height 22).Mode '120x22 must select short wide layout.'
Assert-Equal 'WideShort' (Get-WdtTuiLayout -State $renderState -Width 150 -Height 25).Mode '150x25 must select short wide layout.'
Assert-Equal 'Wide' (Get-WdtTuiLayout -State $renderState -Width 150 -Height 36).Mode '150x36 must select full wide layout.'
Assert-Equal 'Normal' (Get-WdtTuiLayout -State $renderState -Width 109 -Height 28).Mode '109x28 must select normal layout.'
Assert-Equal 'Normal' $normalLayout.Mode '80x25 must select normal layout.'
Assert-Equal 'Normal' (Get-WdtTuiLayout -State $renderState -Width 68 -Height 25).Mode '68x25 must select normal layout.'
Assert-Equal 'Normal' (Get-WdtTuiLayout -State $renderState -Width 84 -Height 25).Mode '84x25 must select normal layout.'
Assert-Equal 'Normal' (Get-WdtTuiLayout -State $renderState -Width 60 -Height 25).Mode '60x25 must select normal layout.'
Assert-Equal 'Compact' (Get-WdtTuiLayout -State $renderState -Width 59 -Height 25).Mode '59x25 must select compact layout.'
Assert-Equal 'Compact' $compactLayout.Mode '40x18 must select compact layout.'
foreach ($size in @(@(39, 18), @(40, 17), @(20, 10), @(5, 5))) {
    Assert-Equal 'TooSmall' (Get-WdtTuiLayout -State $renderState -Width $size[0] -Height $size[1]).Mode ("{0}x{1} must select TooSmall layout." -f $size[0], $size[1])
}
Assert-True ($normalLayout.Lines.Count -le 25) 'Normal TUI exceeds a 25-row terminal.'
Assert-True ($compactLayout.Lines.Count -le 18) 'Compact TUI exceeds its minimum supported height.'
Assert-True ($wideLayout.Lines.Count -le 30) 'Wide TUI exceeds its terminal height.'
$compactErrorState = Update-WdtTuiState -State $renderState -Action MoveDown
$compactErrorState.ErrorMessage = 'Sample compact error'
$compactErrorLayout = Get-WdtTuiLayout -State $compactErrorState -Width 40 -Height 18
Assert-True ($compactErrorLayout.Lines.Count -le 18) 'Compact TUI with an error exceeds its minimum supported height.'
Assert-True ((@($compactErrorLayout.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n").Contains('Error: Sample compact error')) 'Compact TUI hides its error message.'
Assert-Equal 'Unicode' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $false -HasWtSession $false -TermProgram '' -OutputEncodingWebName 'utf-8' -Override '') 'Interactive UTF-8 without WT_SESSION did not enable Unicode.'
Assert-Equal 'Unicode' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $false -HasWtSession $true -TermProgram '' -OutputEncodingWebName 'utf-8' -Override auto) 'WT_SESSION did not remain a positive Unicode signal.'
Assert-Equal 'Unicode' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $false -HasWtSession $false -TermProgram 'Windows_Terminal' -OutputEncodingWebName 'utf8' -Override auto) 'TERM_PROGRAM did not remain a positive Unicode signal.'
Assert-Equal 'Ascii' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $true -HasWtSession $true -TermProgram 'Windows_Terminal' -OutputEncodingWebName 'utf-8' -Override auto) 'Redirected output enabled Unicode.'
Assert-Equal 'Ascii' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $false -HasWtSession $true -TermProgram 'Windows_Terminal' -OutputEncodingWebName 'ibm866' -Override auto) 'Non-UTF-8 output enabled Unicode.'
Assert-Equal 'Ascii' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $false -HasWtSession $true -TermProgram 'Windows_Terminal' -OutputEncodingWebName 'utf-8' -Override ascii) 'ASCII override was ignored.'
Assert-Equal 'Unicode' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $false -HasWtSession $false -TermProgram '' -OutputEncodingWebName '' -Override unicode) 'Unicode override was ignored for interactive output.'
Assert-Equal 'Ascii' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $true -HasWtSession $false -TermProgram '' -OutputEncodingWebName 'utf-8' -Override unicode) 'Unicode override bypassed redirected-output safety.'
Assert-Equal 'Ascii' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $false -HasWtSession $false -TermProgram '' -OutputEncodingWebName 'unknown' -Override invalid) 'Invalid override did not safely fall back to automatic ASCII detection.'
$asciiLogo = @(Get-WdtTuiLogo -Mode Ascii)
$unicodeLogo = @(Get-WdtTuiLogo -Mode Unicode)
Assert-Equal 6 $asciiLogo.Count 'ASCII logo must have six rows.'
Assert-Equal 6 $unicodeLogo.Count 'Unicode logo must have six rows.'
foreach ($logoText in $asciiLogo) {
    Assert-True ($logoText -match '^[ -~]+$') 'TUI logo must be ASCII only.'
}
$asciiWide = Get-WdtTuiLayout -State $renderState -Width 110 -Height 28 -LogoMode Ascii
$unicodeWide = Get-WdtTuiLayout -State $renderState -Width 110 -Height 28 -LogoMode Unicode
foreach ($logoLayout in @($asciiWide, $unicodeWide)) {
    Assert-True ($logoLayout.Lines.Count -le 28) 'Wide logo layout exceeds 110x28.'
    foreach ($line in @($logoLayout.Lines)) {
        Assert-True ((ConvertTo-WdtTuiPlainText -Line $line).Length -le 109) 'Wide logo layout exceeds safe render width.'
    }
}
$asciiWideText = @($asciiWide.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
$unicodeWideText = @($unicodeWide.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
Assert-True ($asciiWideText.Contains($asciiLogo[0])) 'Forced ASCII logo is missing from Wide.'
Assert-True ($unicodeWideText.Contains($unicodeLogo[0])) 'Forced Unicode logo is missing from Wide.'
$shortWideText = @((Get-WdtTuiLayout -State $renderState -Width 120 -Height 22 -LogoMode Unicode).Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
Assert-True (-not $shortWideText.Contains($unicodeLogo[0]) -and -not $shortWideText.Contains($asciiLogo[0])) 'WideShort unexpectedly uses a full logo.'
$wideScreen = @($wideLayout.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
$normalScreen = @($normalLayout.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
$compactScreen = @($compactLayout.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
foreach ($text in @('Windows Diagnostics Toolkit', 'Read-only | Local reports | No telemetry', '[ ]', '[x]', 'Privacy Mode', 'Markdown report', 'Output:', 'RUN DIAGNOSTICS', 'Exit')) {
    Assert-True ($normalScreen.Contains($text)) ("Normal TUI rendering is missing: {0}" -f $text)
}
Assert-True ($compactScreen.Contains('WDT - Windows Diagnostics Toolkit')) 'Compact TUI header is missing.'
Assert-True ($compactScreen.Contains('Selected:')) 'Compact TUI status is missing.'
Assert-True ($compactScreen.Contains('Items ')) 'Compact TUI viewport indicator is missing.'
Assert-True ($compactScreen.Contains('...')) 'Narrow TUI did not truncate the output path.'
Assert-True (-not ($normalScreen -match "`e\[")) 'TUI model must not contain ANSI sequences.'
foreach ($text in @('DIAGNOSTICS', 'OPTIONS', 'OUTPUT', 'RUN DIAGNOSTICS', 'Exit', 'Up/Down Navigate', 'Safe. Local. Transparent.', 'No changes made to your system.')) {
    Assert-True ($wideScreen.Contains($text)) ("Wide TUI rendering is missing: {0}" -f $text)
}
foreach ($diagnostic in @($renderState.Diagnostics)) {
    Assert-True ($wideScreen.Contains($diagnostic.Label)) ("Wide TUI is missing diagnostic: {0}" -f $diagnostic.Label)
}
$selectedCount = @(Get-WdtTuiSelectedModule -State $renderState).Count
Assert-True ($wideScreen.Contains(('Selected: {0} / 10' -f $selectedCount))) 'Wide selected count is incorrect.'
Assert-True ($wideScreen.Contains('Narrow\Terminals')) 'Wide output path did not preserve its useful suffix.'
Assert-True ($wideScreen.Contains('> [ ] System information')) 'Wide active item is not visibly marked.'
Assert-True (-not ($wideScreen -match "`e\[")) 'Wide layout contains ANSI sequences.'
$allSegments = @($normalLayout.Lines | ForEach-Object { $_.Segments })
Assert-True (@($allSegments | Where-Object { $_.Text -eq '>' -and $_.Color -eq 'Yellow' }).Count -eq 0) 'Pointer unexpectedly lost its trailing space contract.'
Assert-True (@($allSegments | Where-Object { $_.Text -eq '> ' -and $_.Color -eq 'Yellow' }).Count -gt 0) 'Active pointer must be yellow.'
Assert-True (@($allSegments | Where-Object { $_.Text -like '*System information*' -and $_.Color -eq 'Yellow' }).Count -gt 0) 'Active label must be visually emphasized.'
Assert-True (@($allSegments | Where-Object { $_.Text -eq '[x]' -and $_.Color -eq 'Green' }).Count -gt 0) 'Selected checkbox must be green.'
Assert-True (@($allSegments | Where-Object { $_.Text -eq '[ ]' -and $_.Color -eq 'DarkGray' }).Count -gt 0) 'Unselected checkbox must be dark gray.'
Assert-True (@($allSegments | Where-Object { $_.Text -like '*Crashes and hangs*' -and $_.Color -eq 'Gray' }).Count -gt 0) 'Unselected module text must be gray.'
Assert-True (@($allSegments | Where-Object { $_.Text -eq 'RUN DIAGNOSTICS' -and $_.Color -eq 'Green' }).Count -gt 0) 'Run action must be green.'
$privacyOffState = $renderState
for ($move = 0; $move -lt 10; $move++) { $privacyOffState = Update-WdtTuiState -State $privacyOffState -Action MoveDown }
$privacyOffState = Update-WdtTuiState -State $privacyOffState -Action ToggleCurrent
Assert-True (@((Get-WdtTuiLayout -State $privacyOffState -Width 80 -Height 25).Lines | ForEach-Object { $_.Segments } | Where-Object { $_.Text -eq '[ ]' -and $_.Color -eq 'DarkGray' }).Count -gt 0) 'Disabled privacy mode must be dark gray.'
$errorState = Update-WdtTuiState -State $renderState -Action MoveDown
$errorState.ErrorMessage = 'Sample error'
Assert-True (@((Get-WdtTuiLayout -State $errorState -Width 80 -Height 25).Lines | ForEach-Object { $_.Segments } | Where-Object { $_.Color -eq 'Red' }).Count -gt 0) 'Error must have a red segment.'
$warningResult = [pscustomobject]@{ ExitCode = 1; TextReportPath = 'C:\Reports\report.txt'; MarkdownReportPath = 'C:\Reports\report.md'; WarningCount = 2; ErrorCount = 1; ElapsedTime = [timespan]::FromSeconds(5) }
Assert-Equal 'Yellow' (Get-WdtTuiRunResultLayout -Result $warningResult).Lines[1].Segments[0].Color 'Partial result must be yellow.'
$successResult = [pscustomobject]@{ ExitCode = 0; TextReportPath = 'C:\Reports\report.txt'; MarkdownReportPath = 'C:\Reports\report.md'; WarningCount = 0; ErrorCount = 0; ElapsedTime = [timespan]::FromSeconds(5) }
$statusLayouts = @(
    (Get-WdtTuiRunningLayout -SelectedCount 7 -Width 40),
    (Get-WdtTuiRunResultLayout -Result $successResult -Width 40),
    (Get-WdtTuiRunResultLayout -Result $warningResult -Width 40),
    (Get-WdtTuiErrorLayout -Message ('Failure ' * 20) -Width 40)
)
foreach ($statusLayout in $statusLayouts) {
    Assert-True ($statusLayout.Lines.Count -le 18) ("Status layout is too tall: {0}" -f $statusLayout.Mode)
    foreach ($line in @($statusLayout.Lines)) {
        Assert-True ((ConvertTo-WdtTuiPlainText -Line $line).Length -le 40) ("Status layout line is too wide: {0}" -f $statusLayout.Mode)
    }
}
$runningText = @((Get-WdtTuiRunningLayout -SelectedCount 7 -Width 80).Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n"
Assert-True ($runningText.Contains('Selected modules: 7')) 'Running screen is missing selected module count.'
Assert-True ($runningText.Contains('Diagnostics are running. This may take a moment.')) 'Running screen is missing honest status guidance.'
Assert-True (-not $runningText.Contains('Progress:')) 'Running screen contains misleading progress.'
foreach ($width in 1..5) { foreach ($line in @((Get-WdtTuiLayout -State $renderState -Width $width -Height 5).Lines)) { Assert-True ((ConvertTo-WdtTuiPlainText -Line $line).Length -le $width) 'Too-small text exceeded its width.' } }
foreach ($size in @(@(140, 36), @(120, 30), @(110, 28), @(120, 22), @(150, 25), @(150, 36), @(109, 28), @(84, 25), @(80, 25), @(68, 25), @(60, 25), @(59, 25), @(40, 18), @(39, 18), @(40, 17), @(20, 10), @(5, 5))) {
    $sizedLayout = Get-WdtTuiLayout -State $renderState -Width $size[0] -Height $size[1]
    Assert-True ($sizedLayout.Lines.Count -le $size[1]) ("Layout exceeded {0} rows." -f $size[1])
    $renderWidth = Get-WdtTuiRenderWidth -WindowWidth $size[0]
    foreach ($line in @($sizedLayout.Lines)) {
        Assert-True ((ConvertTo-WdtTuiPlainText -Line $line).Length -le $renderWidth) ("Layout exceeded safe render width {0}." -f $renderWidth)
    }
    $frame = @(ConvertTo-WdtTuiFrame -Layout $sizedLayout -WindowWidth $size[0])
    foreach ($frameLine in $frame) {
        Assert-Equal $renderWidth $frameLine.Length ("Frame line does not use safe render width for {0}." -f $size[0])
        Assert-True ($frameLine.Length -lt $size[0]) ("Frame writes into the final terminal column for {0}." -f $size[0])
    }
}

foreach ($size in @(@(120, 22), @(150, 25), @(150, 36))) {
    $responsiveLayout = Get-WdtTuiLayout -State $renderState -Width $size[0] -Height $size[1]
    $responsiveLines = @($responsiveLayout.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ })
    foreach ($line in $responsiveLines) {
        Assert-True ($line.EndsWith('+') -or $line.EndsWith('|')) ("Wide frame lost its right border at {0}x{1}." -f $size[0], $size[1])
    }
    $responsiveText = $responsiveLines -join "`n"
    Assert-True ($responsiveText.Contains(('Selected: {0} / 10' -f $selectedCount))) ("Selected count was truncated at {0}x{1}." -f $size[0], $size[1])
    Assert-True ($responsiveText.Contains('RUN DIAGNOSTICS') -and $responsiveText.Contains('Enter')) ("Run shortcut was truncated at {0}x{1}." -f $size[0], $size[1])
    Assert-True ($responsiveText.Contains('Exit') -and $responsiveText.Contains('Esc')) ("Exit shortcut was truncated at {0}x{1}." -f $size[0], $size[1])
}

$responsiveModes = @('Normal', 'Normal', 'WideShort', 'WideShort', 'Wide', 'WideShort', 'WideShort', 'Normal', 'Normal')
$responsiveSizes = @(@(68, 25), @(84, 25), @(120, 22), @(150, 25), @(150, 36), @(150, 25), @(120, 22), @(84, 25), @(68, 25))
$selectionBeforeResponsiveResize = @(Get-WdtTuiSelectedModule -State $renderState) -join ','
$cursorBeforeResponsiveResize = $renderState.CursorIndex
for ($index = 0; $index -lt $responsiveSizes.Count; $index++) {
    $responsiveSize = $responsiveSizes[$index]
    Assert-Equal $responsiveModes[$index] (Get-WdtTuiLayout -State $renderState -Width $responsiveSize[0] -Height $responsiveSize[1]).Mode 'Responsive mode transition is incorrect.'
}
Assert-Equal $selectionBeforeResponsiveResize (@(Get-WdtTuiSelectedModule -State $renderState) -join ',') 'Responsive resize changed selection.'
Assert-Equal $cursorBeforeResponsiveResize $renderState.CursorIndex 'Responsive resize changed cursor index.'

Assert-Equal 79 (Get-WdtTuiRenderWidth -WindowWidth 80) 'Render width must reserve the final terminal column.'
$sameFrame = @('alpha     ', 'beta      ')
Assert-Equal 0 @(Get-WdtTuiFrameOperations -PreviousFrame $sameFrame -CurrentFrame $sameFrame -RenderWidth 10).Count 'Identical frames created update operations.'
$oneChange = @(Get-WdtTuiFrameOperations -PreviousFrame @('alpha     ', 'beta      ') -CurrentFrame @('alpha     ', 'gamma     ') -RenderWidth 10)
Assert-Equal 1 $oneChange.Count 'A single changed row did not create exactly one operation.'
Assert-Equal 1 $oneChange[0].Row 'The changed row index is incorrect.'
$shortenedLine = @(Get-WdtTuiFrameOperations -PreviousFrame @('abcdefghij') -CurrentFrame @('abc       ') -RenderWidth 10)
Assert-Equal 1 $shortenedLine.Count 'A shortened row did not create one operation.'
Assert-Equal 'abc       ' $shortenedLine[0].Text 'A shortened row does not clear its old tail.'
$shorterFrame = @(Get-WdtTuiFrameOperations -PreviousFrame @('alpha     ', 'obsolete  ') -CurrentFrame @('alpha     ') -RenderWidth 10)
Assert-Equal 1 $shorterFrame.Count 'A shorter frame did not clear its removed row.'
Assert-Equal 1 $shorterFrame[0].Row 'Removed frame row index is incorrect.'
Assert-Equal (' ' * 10) $shorterFrame[0].Text 'Removed frame row is not cleared with spaces.'
Assert-True ($shorterFrame[0].ClearsRemovedRow) 'Removed frame operation is not marked as a clear.'
$invalidatedFrame = @(Get-WdtTuiFrameOperations -PreviousFrame @() -CurrentFrame @('alpha     ', 'beta      ') -RenderWidth 10)
Assert-Equal 2 $invalidatedFrame.Count 'Frame invalidation did not create a full set of row operations.'
Assert-Equal 'Full' (Get-WdtTuiRenderStrategy -IsOutputRedirected $false -CursorPositioningAvailable $false) 'Unavailable cursor positioning did not select full-render fallback.'
Assert-Equal 'Full' (Get-WdtTuiRenderStrategy -IsOutputRedirected $true -CursorPositioningAvailable $true) 'Redirected output did not select full-render fallback.'
Assert-Equal 'Diff' (Get-WdtTuiRenderStrategy -IsOutputRedirected $false -CursorPositioningAvailable $true) 'Interactive cursor support did not select diff rendering.'
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
Assert-True ((@((Get-WdtTuiLayout -State $runState -Width 40 -Height 18).Lines | ForEach-Object { ConvertTo-WdtTuiPlainText -Line $_ }) -join "`n").Contains('RUN DIAGNOSTICS')) 'Run is unreachable in compact viewport.'
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

$selectionBeforeResize = @(Get-WdtTuiSelectedModule -State $renderState) -join ','
$cursorBeforeResize = $renderState.CursorIndex
foreach ($size in @(@(140, 36), @(80, 25), @(40, 18), @(20, 10), @(120, 30))) {
    [void](Get-WdtTuiLayout -State $renderState -Width $size[0] -Height $size[1])
}
Assert-Equal $selectionBeforeResize (@(Get-WdtTuiSelectedModule -State $renderState) -join ',') 'Resize layout calculation changed selection.'
Assert-Equal $cursorBeforeResize $renderState.CursorIndex 'Resize layout calculation changed cursor state.'
$sameSizeDecision = Get-WdtTuiEventDecision -KeyAvailable $false -InitialWidth 110 -InitialHeight 28 -CurrentWidth 110 -CurrentHeight 28
Assert-Equal 'Wait' $sameSizeDecision 'An unchanged host size requested a redraw.'
$resizeDecision = Get-WdtTuiEventDecision -KeyAvailable $false -InitialWidth 110 -InitialHeight 28 -CurrentWidth 80 -CurrentHeight 25
Assert-Equal 'Resize' $resizeDecision 'A changed host size did not produce a resize event.'
$keyDuringResizeDecision = Get-WdtTuiEventDecision -KeyAvailable $true -InitialWidth 110 -InitialHeight 28 -CurrentWidth 80 -CurrentHeight 25
Assert-Equal 'Key' $keyDuringResizeDecision 'An available key was lost when a resize was also detected.'
if ([System.Console]::IsOutputRedirected) {
    Assert-True (-not (Test-WdtTuiColorOutput)) 'Redirected output did not disable colors.'
}

$parameters = ConvertTo-WdtReportParameters `
    -State $renderState `
    -ModuleTimeoutSeconds 37 `
    -NoExternalNetworkTests $true `
    -NetworkDnsTestName 'dns.fixture.example' `
    -NetworkHttpsEndpoint 'https://tcp.fixture.example/' `
    -NetworkIcmpTarget '192.0.2.44'
Assert-Equal @(Get-WdtTuiSelectedModule -State $renderState).Count @($parameters.SelectedModules).Count 'Selected modules were not preserved in report parameters.'
Assert-True ($parameters.SuppressConsoleOutput) 'TUI report parameters do not suppress runner console output.'
Assert-Equal 37 $parameters.ModuleTimeoutSeconds 'TUI did not preserve ModuleTimeoutSeconds.'
Assert-Equal $true $parameters.NoExternalNetworkTests 'TUI did not preserve NoExternalNetworkTests.'
Assert-Equal 'dns.fixture.example' $parameters.NetworkDnsTestName 'TUI did not preserve NetworkDnsTestName.'
Assert-Equal 'https://tcp.fixture.example/' $parameters.NetworkHttpsEndpoint 'TUI did not preserve NetworkHttpsEndpoint.'
Assert-Equal '192.0.2.44' $parameters.NetworkIcmpTarget 'TUI did not preserve NetworkIcmpTarget.'

$tokens = $null; $parseErrors = $null
$entrypointAst = [System.Management.Automation.Language.Parser]::ParseFile($entrypointPath, [ref]$tokens, [ref]$parseErrors)
$tuiTokens = $null; $tuiParseErrors = $null
$tuiAst = [System.Management.Automation.Language.Parser]::ParseFile($tuiPath, [ref]$tuiTokens, [ref]$tuiParseErrors)
$cursorCalls = @($tuiAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'SetCursorPosition' }, $true))
Assert-Equal 1 $cursorCalls.Count 'TUI must have exactly one SetCursorPosition call.'
$cursorFunction = $cursorCalls[0].Parent
while ($null -ne $cursorFunction -and $cursorFunction -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $cursorFunction = $cursorFunction.Parent }
Assert-Equal 'Show-WdtTuiFrame' $cursorFunction.Name 'SetCursorPosition is outside the frame renderer.'
Assert-Equal '$column' $cursorCalls[0].Arguments[0].Extent.Text 'SetCursorPosition column must use the reviewed variable.'
Assert-Equal '$row' $cursorCalls[0].Arguments[1].Extent.Text 'SetCursorPosition row must use the reviewed variable.'
$cursorVisibilityReferences = @($tuiAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.MemberExpressionAst] -and $node.Member.Value -eq 'CursorVisible' }, $true))
Assert-True ($cursorVisibilityReferences.Count -ge 3) 'Cursor visibility is not saved, hidden, and restored.'
foreach ($reference in $cursorVisibilityReferences) {
    $owner = $reference.Parent
    while ($null -ne $owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
    Assert-Equal 'Invoke-WdtInteractiveSession' $owner.Name 'Cursor visibility is used outside the interactive session.'
}
$interactiveFunction = @($tuiAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-WdtInteractiveSession' }, $true))[0]
Assert-True ($interactiveFunction.Extent.Text -match '(?s)finally\s*\{.*CursorVisible\s*=\s*\$originalCursorVisible') 'Cursor visibility is not restored in finally.'
Assert-True ($interactiveFunction.Extent.Text -match '(?s)\$completionEvent\s*=\s*Wait-WdtTuiEvent.*?if\s*\(\$completionEvent\.KeyInfo\.Key\s+-eq\s*\[System\.ConsoleKey\]::Escape\).*?if\s*\(\$completionEvent\.KeyInfo\.Key\s+-eq\s*\[System\.ConsoleKey\]::Enter\)') 'Result screen does not wait specifically for Enter or Esc.'
Assert-True ($interactiveFunction.Extent.Text -match '(?s)try\s*\{\s*Reset-WdtTuiFrame.*?while\s*\(') 'Interactive session does not invalidate a previous session frame on entry.'
Assert-True ($interactiveFunction.Extent.Text -match '(?s)finally\s*\{\s*Reset-WdtTuiFrame') 'Interactive session does not invalidate its frame in finally.'
Assert-True ($interactiveFunction.Extent.Text -match '(?s)catch\s*\{.*?Reset-WdtTuiFrame\s*\r?\n\s*Show-WdtTuiFrame.*?-ForceFull\s+\$true') 'Error screen is not force-rendered from a clean frame.'
$sessionText = $interactiveFunction.Extent.Text
foreach ($forwardedParameter in @('ModuleTimeoutSeconds', 'NoExternalNetworkTests', 'NetworkDnsTestName', 'NetworkHttpsEndpoint', 'NetworkIcmpTarget')) {
    Assert-True ($sessionText -match (('-{0}\s+\${0}' -f $forwardedParameter))) ("Interactive session does not forward {0} to report parameters." -f $forwardedParameter)
}
Assert-True ($sessionText -match 'Invoke-WdtReport\s+@reportParameters') 'Interactive report parameters are not splatted into Invoke-WdtReport.'
$firstFrameInitialization = $sessionText.IndexOf('$isFirstMenuFrame = $true')
$firstFrameRender = $sessionText.IndexOf('-ForceFull $isFirstMenuFrame')
$diffFrameTransition = $sessionText.IndexOf('$isFirstMenuFrame = $false')
Assert-True ($firstFrameInitialization -ge 0) 'Interactive session does not initialize first-frame full rendering.'
Assert-True ($firstFrameRender -gt $firstFrameInitialization) 'First menu screen does not use the full-render flag.'
Assert-True ($diffFrameTransition -gt $firstFrameRender) 'Subsequent menu screens are not switched back to diff rendering.'
$eventWaitFunction = @($tuiAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-WdtTuiEvent' }, $true))[0]
Assert-True ($null -ne $eventWaitFunction) 'Resize-aware TUI event wait function is missing.'
Assert-True ($eventWaitFunction.Extent.Text -match '\[System\.Console\]::KeyAvailable') 'TUI event wait does not poll Console.KeyAvailable.'
Assert-True ($eventWaitFunction.Extent.Text -match 'Start-Sleep\s+-Milliseconds\s+\$PollMilliseconds') 'TUI event wait does not use the bounded polling interval.'
Assert-True ($eventWaitFunction.Extent.Text -match '(?s)catch\s*\{.*?\[System\.Console\]::ReadKey\(\$true\).*?UsedBlockingFallback\s*=\s*\$true') 'KeyAvailable failure does not use the blocking ReadKey fallback.'
Assert-True ($sessionText -match '(?s)\$inputEvent\.Type\s+-eq\s*''Resize''.*?Reset-WdtTuiFrame.*?Show-WdtTuiScreen.*?-ForceFull\s+\$true.*?continue') 'Menu resize does not force one clean redraw.'
Assert-True ($sessionText -match '(?s)\$completionEvent\.Type\s+-eq\s*''Resize''.*?Reset-WdtTuiFrame.*?-ForceFull\s+\$true.*?continue') 'Result or error resize does not force one clean redraw.'
Assert-True ($tuiAst.Extent.Text.Contains('$script:WdtTuiPreviousFrame')) 'Renderer does not keep the previous plain-text frame.'
Assert-True (-not $tuiAst.Extent.Text.Contains('$script:WdtTuiPreviousFrameHeight')) 'Renderer still uses the legacy frame-height buffer.'
$diffWriter = @($tuiAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-WdtTuiDiffRow' }, $true))[0]
$diffWriteCommands = @($diffWriter.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Host' }, $true))
Assert-True ($diffWriteCommands.Count -gt 0) 'Diff row writer has no output commands.'
foreach ($writeCommand in $diffWriteCommands) {
    Assert-True ($writeCommand.Extent.Text -match '(?i)-NoNewline\b') 'Diff row writer contains a newline-producing Write-Host call.'
}
$fullWriter = @($tuiAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-WdtTuiFullFrame' }, $true))[0]
Assert-True ($fullWriter.Extent.Text -match '(?s)\$isLastLine\s*=.*?-NoNewline\s+\$isLastLine') 'Full frame writer does not suppress newline after its last row.'
$resultRenderer = @($tuiAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-WdtTuiRunResult' }, $true))[0]
Assert-True ($resultRenderer.Extent.Text -match '(?s)Reset-WdtTuiFrame.*?Show-WdtTuiFrame.*?-ForceFull\s+\$true') 'Result screen is not force-rendered from a clean frame.'
$runnerFunction = @($entrypointAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-WdtReport' }, $true))
Assert-Equal 1 $runnerFunction.Count 'Invoke-WdtReport is missing.'
$runnerConsoleCommands = @($runnerFunction[0].FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Write-Host', 'Write-Warning') }, $true))
Assert-Equal 3 $runnerConsoleCommands.Count 'Unexpected runner console output inventory.'
foreach ($runnerCommand in $runnerConsoleCommands) {
    $guard = $runnerCommand.Parent
    while ($null -ne $guard -and $guard -isnot [System.Management.Automation.Language.IfStatementAst]) { $guard = $guard.Parent }
    Assert-True ($null -ne $guard -and $guard.Extent.Text -match 'SuppressConsoleOutput') 'Runner console output is not guarded for TUI execution.'
}
. ([scriptblock]::Create($runnerFunction[0].Extent.Text))
Assert-Throws { Invoke-WdtReport -SelectedModules @() -OutputDirectory 'C:\Reports' } '*At least one diagnostic module*' 'Empty runner selection was accepted.'
Assert-Throws { Invoke-WdtReport -SelectedModules @('Unknown') -OutputDirectory 'C:\Reports' } '*Unknown diagnostic module*' 'Unknown runner module was accepted.'

. (Join-Path $repositoryRoot 'scripts\report-common.ps1')
foreach ($definition in @($entrypointAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$interactiveSmokeOutput = Join-Path $env:TEMP ('wdt-tui-parameters-' + [guid]::NewGuid().ToString('N'))
try {
    $interactiveSmokeState = New-WdtTuiState -OutputDirectory $interactiveSmokeOutput
    foreach ($diagnostic in $interactiveSmokeState.Diagnostics) { $diagnostic.Selected = ($diagnostic.Name -eq 'Network') }
    $interactiveReportParameters = ConvertTo-WdtReportParameters `
        -State $interactiveSmokeState `
        -ModuleTimeoutSeconds 17 `
        -NoExternalNetworkTests $true `
        -NetworkDnsTestName 'dns.interactive.fixture' `
        -NetworkHttpsEndpoint 'https://interactive.fixture/' `
        -NetworkIcmpTarget '192.0.2.55'
    $interactiveReportResult = Invoke-WdtReport @interactiveReportParameters
    Assert-Equal 0 $interactiveReportResult.ExitCode 'Interactive parameter-flow smoke failed.'
    $interactiveTextReport = Get-Content -LiteralPath $interactiveReportResult.TextReportPath -Raw
    Assert-True ($interactiveTextReport.Contains('External tests: NotTested (-NoExternalNetworkTests)')) 'Interactive NoExternalNetworkTests did not reach the network module.'
}
finally {
    if (Test-Path -LiteralPath $interactiveSmokeOutput) { Remove-Item -LiteralPath $interactiveSmokeOutput -Recurse -Force }
}

$tuiImports = @($entrypointAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -and $node.Extent.Text -eq '. $PSScriptRoot\scripts\tui.ps1' }, $true))
Assert-Equal 1 $tuiImports.Count 'Entrypoint TUI import is missing.'
$parent = $tuiImports[0].Parent
while ($null -ne $parent -and $parent -isnot [System.Management.Automation.Language.IfStatementAst]) { $parent = $parent.Parent }
Assert-True ($null -ne $parent -and $parent.Extent.Text -match '\$launchMode\s+-eq\s+''Interactive''') 'TUI import is not isolated to interactive launch mode.'
$interactiveCalls = @($entrypointAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-WdtInteractiveSession' }, $true))
Assert-Equal 1 $interactiveCalls.Count 'Entrypoint must invoke exactly one interactive session.'
foreach ($forwardedParameter in @('ModuleTimeoutSeconds', 'NoExternalNetworkTests', 'NetworkDnsTestName', 'NetworkHttpsEndpoint', 'NetworkIcmpTarget')) {
    Assert-True ($interactiveCalls[0].Extent.Text -match (('-{0}\b' -f $forwardedParameter))) ("Entrypoint does not pass {0} into the interactive session." -f $forwardedParameter)
}

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
