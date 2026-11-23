[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\tui.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}

function Assert-SequenceEqual {
    param([object[]]$Expected, [object[]]$Actual, [string]$Message)

    $expectedItems = @($Expected)
    $actualItems = @($Actual)
    if ($expectedItems.Count -ne $actualItems.Count) {
        throw "$Message ExpectedCount=$($expectedItems.Count) ActualCount=$($actualItems.Count)"
    }
    for ($index = 0; $index -lt $expectedItems.Count; $index++) {
        if ($expectedItems[$index] -ne $actualItems[$index]) {
            throw "$Message Index=$index Expected=$($expectedItems[$index]) Actual=$($actualItems[$index])"
        }
    }
}

function New-TestRegistrySnapshot {
    param([int]$Count = 10)

    $stockDefinitions = @(
        [pscustomobject]@{ Id='System'; Label='System information'; Recommended=$true; Order=10 },
        [pscustomobject]@{ Id='Security'; Label='Security posture'; Recommended=$true; Order=20 },
        [pscustomobject]@{ Id='Performance'; Label='Performance snapshot'; Recommended=$true; Order=30 },
        [pscustomobject]@{ Id='Network'; Label='Network'; Recommended=$true; Order=40; OptionBindings=@{ NetworkWebServiceUrl='WebServiceUrl' } },
        [pscustomobject]@{ Id='Time'; Label='Time synchronization'; Recommended=$true; Order=50 },
        [pscustomobject]@{ Id='Disk'; Label='Storage status'; Recommended=$true; Order=60 },
        [pscustomobject]@{ Id='Crashes'; Label='Crashes and hangs'; Recommended=$false; Order=70 },
        [pscustomobject]@{ Id='Events'; Label='Event logs'; Recommended=$false; Order=80 },
        [pscustomobject]@{ Id='Services'; Label='Services and startup'; Recommended=$false; Order=90 },
        [pscustomobject]@{ Id='Updates'; Label='Windows Update'; Recommended=$true; Order=100 }
    )
    $modules = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $Count; $index++) {
        if ($index -lt $stockDefinitions.Count) {
            $modules.Add($stockDefinitions[$index])
        }
        else {
            $number = $index + 1
            $modules.Add([pscustomobject]@{
                    Id = "Extra$number"
                    Label = "Extra module $number"
                    Recommended = $false
                    Order = $number * 10
                })
        }
    }
    return [pscustomobject]@{
        Modules = [System.Collections.ObjectModel.ReadOnlyCollection[object]]::new($modules)
    }
}

function Get-PlainLayoutLines {
    param([Parameter(Mandatory = $true)]$Layout)
    return @($Layout.Lines | ForEach-Object { ConvertTo-WdtTuiPlainText $_ })
}

function Get-PlainLayoutHash {
    param([Parameter(Mandatory = $true)]$Layout)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-PlainLayoutLines -Layout $Layout) -join "`n")
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($algorithm.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Assert-LayoutBounds {
    param([Parameter(Mandatory = $true)]$Layout, [int]$Width, [int]$Height)

    Assert-True ($Layout.Lines.Count -le $Height) "Layout $($Layout.Mode) exceeds terminal height $Height."
    foreach ($line in $Layout.Lines) {
        $lineWidth = (($line.Segments | ForEach-Object Text) -join '').Length
        Assert-True ($lineWidth -le $Width) "Layout $($Layout.Mode) exceeds terminal width $Width with line width $lineWidth."
    }
}

$registrySnapshot = New-TestRegistrySnapshot
$state = New-WdtTuiState -RegistrySnapshot $registrySnapshot -OutputDirectory 'C:\Reports'
Assert-Equal 10 $registrySnapshot.Modules.Count 'Diagnostic registry count is incorrect.'
Assert-Equal $null (ConvertTo-WdtTuiFallbackMenuAction -Answer '999999999999999999999999' -VisibleIndexes @(0..9) -RunIndex 10) 'Overflowing menu numbers must be treated as an unknown command.'
Assert-Equal 'Select' (ConvertTo-WdtTuiFallbackMenuAction -Answer '1' -VisibleIndexes @(0..9) -RunIndex 10).Action 'Valid fallback menu numbers must still select items.'
Assert-True ([object]::ReferenceEquals($registrySnapshot, $state.RegistrySnapshot)) 'TUI state must retain the supplied registry snapshot.'
Assert-Equal 7 @(Get-WdtTuiSelectedModule $state).Count 'Default selection is incorrect.'
Assert-SequenceEqual @('System', 'Security', 'Performance', 'Network', 'Time', 'Disk', 'Updates') @(Get-WdtRecommendedSelection -RegistrySnapshot $registrySnapshot) 'Recommended module order is incorrect.'
Assert-True $state.PrivacyMode 'Privacy mode must be enabled by default.'
Assert-True $state.ExportMarkdown 'Markdown export must be enabled by default.'

$originalSelection = $state.Diagnostics[0].Selected
$updated = Update-WdtTuiState $state ToggleCurrent
Assert-True ($updated -ne $state) 'State update must return a new state.'
Assert-True ([object]::ReferenceEquals($registrySnapshot, $updated.RegistrySnapshot)) 'State transitions must preserve the same registry snapshot.'
Assert-Equal (-not $originalSelection) $updated.Diagnostics[0].Selected 'Toggle did not change selection.'
$moved = Update-WdtTuiState $updated MoveDown
Assert-Equal 1 $moved.CursorIndex 'MoveDown did not advance cursor.'
$allSelected = Update-WdtTuiState $moved SelectAll
$recommendedState = Update-WdtTuiState $allSelected SelectRecommended
Assert-SequenceEqual @(Get-WdtRecommendedSelection -RegistrySnapshot $registrySnapshot) @(Get-WdtTuiSelectedModule -State $recommendedState) 'Recommended action did not use the session registry snapshot.'

$stockCases = @(
    [pscustomobject]@{ Width=140; Height=36; Mode='Wide'; Hash='d73e15a3e46d7b2fde245ab8ac9178c58a92a1d74db0b540041317afbcc380d0' },
    [pscustomobject]@{ Width=110; Height=22; Mode='WideShort'; Hash='4a7cef6dbb16225eeda32e45ed7d1765caa30584fc49d06a6d1b23522baf77e8' },
    [pscustomobject]@{ Width=80; Height=25; Mode='Normal'; Hash='0b6b5f572bafd63980997deebbe3cc08050b250de8331ffef4f922a58a4eb1fe' },
    [pscustomobject]@{ Width=59; Height=25; Mode='Compact'; Hash='1291ded8c1cd559447868d8a32282df755dd9ead933a970eec3fdff2729e5b15' }
)
foreach ($case in $stockCases) {
    $layout = Get-WdtTuiLayout -State $state -Width $case.Width -Height $case.Height -LogoMode Ascii
    Assert-Equal $case.Mode $layout.Mode "Unexpected stock layout for $($case.Width)x$($case.Height)."
    Assert-Equal $case.Hash (Get-PlainLayoutHash -Layout $layout) "Stock 10-module visual changed for $($case.Mode)."
    Assert-LayoutBounds -Layout $layout -Width $case.Width -Height $case.Height
}

$tooSmallLayout = Get-WdtTuiLayout -State $state -Width 20 -Height 10
Assert-Equal 'TooSmall' $tooSmallLayout.Mode 'Unexpected layout for a too-small terminal.'
Assert-LayoutBounds -Layout $tooSmallLayout -Width 20 -Height 10

$registry11 = New-TestRegistrySnapshot -Count 11
$state11 = New-WdtTuiState -RegistrySnapshot $registry11 -OutputDirectory 'C:\Reports'
$wideShort11 = Get-WdtTuiLayout -State $state11 -Width 110 -Height 22 -LogoMode Ascii
Assert-Equal 'WideShort' $wideShort11.Mode 'Eleven modules must not change the WideShort layout mode.'
Assert-Equal 0 $wideShort11.Viewport.Start 'Eleven-module WideShort viewport start is incorrect.'
Assert-Equal 10 $wideShort11.Viewport.End 'Eleven-module WideShort viewport end is incorrect.'
Assert-SequenceEqual @(0..18) @($wideShort11.VisibleIndexes) 'Eleven-module indexes are not dynamic.'
Assert-Equal 0 @((Get-PlainLayoutLines $wideShort11) -match 'DIAGNOSTICS \d+-\d+ of 11').Count 'Unclipped WideShort diagnostics must not show a range.'
Assert-LayoutBounds -Layout $wideShort11 -Width 110 -Height 22

$registry20 = New-TestRegistrySnapshot -Count 20
$state20 = New-WdtTuiState -RegistrySnapshot $registry20 -OutputDirectory 'C:\Reports'
$wideShort20 = Get-WdtTuiLayout -State $state20 -Width 110 -Height 22 -LogoMode Ascii
Assert-Equal 'WideShort' $wideShort20.Mode 'Twenty modules must not change the WideShort layout mode.'
Assert-SequenceEqual @(0..27) @($wideShort20.VisibleIndexes) 'WideShort controls or diagnostics are missing.'
$wideShort20Lines = @(Get-PlainLayoutLines $wideShort20)
$firstDiagnosticRow = @($wideShort20Lines | Where-Object { $_ -like '*System information*' })[0]
Assert-True ($firstDiagnosticRow -like '*Extra module 12*') 'WideShort diagnostics are not distributed column-major.'
Assert-Equal 0 @($wideShort20Lines -match 'DIAGNOSTICS \d+-\d+ of 20').Count 'Unclipped two-column diagnostics must not show a range.'
Assert-LayoutBounds -Layout $wideShort20 -Width 110 -Height 22

$registry30 = New-TestRegistrySnapshot -Count 30
$state30 = New-WdtTuiState -RegistrySnapshot $registry30 -OutputDirectory 'C:\Reports'
$state30.CursorIndex = 15
$clippedWide = Get-WdtTuiLayout -State $state30 -Width 110 -Height 22 -LogoMode Ascii
Assert-Equal 'WideShort' $clippedWide.Mode 'A larger registry must not force Compact layout.'
Assert-Equal 4 $clippedWide.Viewport.Start 'Centered two-column viewport start is incorrect.'
Assert-Equal 25 $clippedWide.Viewport.End 'Centered two-column viewport end is incorrect.'
Assert-SequenceEqual @(@(4..25) + @(30..37)) @($clippedWide.VisibleIndexes) 'Clipped WideShort visible indexes are incorrect.'
Assert-True (@((Get-PlainLayoutLines $clippedWide) -match 'DIAGNOSTICS 5-26 of 30').Count -gt 0) 'Clipped WideShort range is missing from the diagnostics header.'
Assert-LayoutBounds -Layout $clippedWide -Width 110 -Height 22

$state30.CursorIndex = 30
$controlAnchoredWide = Get-WdtTuiLayout -State $state30 -Width 110 -Height 22 -LogoMode Ascii
Assert-Equal 8 $controlAnchoredWide.Viewport.Start 'A control cursor must anchor the final diagnostics page.'
Assert-Equal 29 $controlAnchoredWide.Viewport.End 'The final diagnostics page is incorrect.'
Assert-SequenceEqual @(30..37) @($controlAnchoredWide.VisibleIndexes | Where-Object { $_ -ge 30 }) 'WideShort controls must remain visible.'

$state20.CursorIndex = 10
$normal20 = Get-WdtTuiLayout -State $state20 -Width 80 -Height 25 -LogoMode Ascii
Assert-Equal 'Normal' $normal20.Mode 'Twenty modules must not change the Normal layout mode.'
Assert-Equal 5 $normal20.Viewport.Start 'Centered Normal viewport start is incorrect.'
Assert-Equal 15 $normal20.Viewport.End 'Centered Normal viewport end is incorrect.'
Assert-SequenceEqual @(@(5..15) + @(20..27)) @($normal20.VisibleIndexes) 'Normal diagnostics or fixed controls are missing.'
Assert-True (@((Get-PlainLayoutLines $normal20) -match 'DIAGNOSTICS 6-16 of 20').Count -gt 0) 'Clipped Normal range is missing from the diagnostics header.'
Assert-True (@((Get-PlainLayoutLines $normal20) -match 'RUN DIAGNOSTICS').Count -gt 0) 'Normal fixed actions are not visible.'
Assert-LayoutBounds -Layout $normal20 -Width 80 -Height 25

$state20.CursorIndex = (Get-WdtTuiMenuIndex -State $state20 -Kind Run)
$compact20 = Get-WdtTuiLayout -State $state20 -Width 59 -Height 25 -LogoMode Ascii
Assert-Equal 'Compact' $compact20.Mode 'Registry size must not change a window-selected Compact layout.'
Assert-True ($compact20.VisibleIndexes -contains $state20.CursorIndex) 'Compact shared viewport must follow the cursor to Run.'
Assert-True ($compact20.VisibleIndexes -contains (Get-WdtTuiMenuIndex -State $state20 -Kind Exit)) 'Compact shared viewport must expose Exit on the final page.'
Assert-LayoutBounds -Layout $compact20 -Width 59 -Height 25

foreach ($kind in @('NetworkService', 'Recording', 'Incident')) {
    $state.CursorIndex = Get-WdtTuiMenuIndex -State $state -Kind $kind
    $smallLayout = Get-WdtTuiLayout -State $state -Width 40 -Height 18 -ShowItemNumbers $true
    Assert-True ($smallLayout.VisibleIndexes -contains $state.CursorIndex) "$kind is missing from the minimum-size viewport."
    Assert-LayoutBounds -Layout $smallLayout -Width 40 -Height 18
    Assert-True ($smallLayout.Lines.Count -lt 18) 'The numbered menu must reserve a line for the input prompt.'
}

$incidentPage = Update-WdtTuiState $state SelectCurrent
Assert-Equal 'Incident' $incidentPage.Page 'Incident menu failed to open.'
Assert-Equal $null $incidentPage.ActionRequested 'Opening Incident must wait for a symptom.'
$incidentLayout = Get-WdtTuiLayout -State $incidentPage -Width 40 -Height 18 -ShowItemNumbers $true
Assert-LayoutBounds -Layout $incidentLayout -Width 40 -Height 18
Assert-SequenceEqual @(0..2) @($incidentLayout.VisibleIndexes) 'Incident menu must show both symptoms and Back.'
$applicationFailure = Update-WdtTuiState $incidentPage SelectCurrent
Assert-Equal 'IncidentSymptom' $applicationFailure.ActionRequested 'Selecting Application crash or hang must request incident input.'
Assert-Equal 'AppFailure' $applicationFailure.ActionValue 'Application crash or hang mapped to the wrong symptom.'
$restartIncident = Update-WdtTuiState (Update-WdtTuiState $incidentPage MoveDown) SelectCurrent
Assert-Equal 'UnexpectedRestart' $restartIncident.ActionValue 'Unexpected restart mapped to the wrong symptom.'
$back = Update-WdtTuiState $incidentPage Exit
Assert-Equal 'Main' $back.Page 'Escape from the incident menu must return to the main menu.'
Assert-Equal $state.CursorIndex $back.CursorIndex 'Returning from a submenu must restore the selected main action.'
Assert-Equal $false $back.ExitRequested 'Returning from a submenu must not exit the session.'
Assert-Equal 'Exit' (ConvertTo-WdtTuiFallbackMenuAction -Answer Back -VisibleIndexes @(0..2) -RunIndex -1).Action 'The numbered incident menu must accept Back.'
Assert-Equal $null (ConvertTo-WdtTuiFallbackMenuAction -Answer Run -VisibleIndexes @(0..2) -RunIndex -1) 'The main menu Run shortcut must not start a collection from a submenu.'
Assert-Equal 'Down' (ConvertTo-WdtTuiFallbackMenuAction -Answer Down -VisibleIndexes @(0..2) -RunIndex 14).Action 'A numbered compact menu must allow scrolling without changing a selection.'

$state.CursorIndex = Get-WdtTuiMenuIndex -State $state -Kind 'Recording'
$recordingPage = Update-WdtTuiState $state SelectCurrent
$recordingLayout = Get-WdtTuiLayout -State $recordingPage -Width 40 -Height 18
Assert-Equal 'Recording' $recordingLayout.Mode 'Selecting Record performance must open a separate screen.'
Assert-LayoutBounds -Layout $recordingLayout -Width 40 -Height 18
Assert-SequenceEqual @(0..3) @($recordingLayout.VisibleIndexes) 'All recording durations and Back must be available at minimum size.'
Assert-SequenceEqual @(60, 90, 120) @((Get-WdtTuiMenuItem $recordingPage | Where-Object { $_.Kind -eq 'StartRecording' }).Value) 'The menu must offer all three recording durations.'
$recording = Update-WdtTuiState $recordingPage SelectCurrent
Assert-Equal 'StartRecording' $recording.ActionRequested 'Selecting a duration must request recording.'
Assert-Equal 60 $recording.ActionValue 'The default recording duration must be 60 seconds.'
$back = Update-WdtTuiState (Update-WdtTuiState $recordingPage MoveUp) SelectCurrent
Assert-Equal 'Main' $back.Page 'The recording menu Back item must return to the main menu.'
Assert-SequenceEqual @(Get-WdtTuiSelectedModule $state) @(Get-WdtTuiSelectedModule $back) 'Visiting the recording menu must preserve module selection.'
Assert-True ($back.PrivacyMode -and $back.ExportMarkdown -and $back.OutputDirectory -eq $state.OutputDirectory) 'Submenus must preserve report settings.'
$running = Get-WdtTuiRunningLayout -RunKind 'StartRecording' -DurationSeconds 90 -Width 39
Assert-True (((Get-PlainLayoutLines $running) -join "`n") -match 'Press M when the issue occurs') 'The recording screen must show the marker key during collection.'

$testTimeZone = [System.TimeZoneInfo]::CreateCustomTimeZone('Fixture', [timespan]::FromHours(2), 'Fixture', 'Fixture')
Assert-Equal '2026-11-02T14:30:00+02:00' (ConvertTo-WdtTuiIncidentTimestamp -Text '2026-11-02 14:30' -TimeZone $testTimeZone) 'Local input must carry the applicable timezone offset.'
Assert-Equal '2026-11-02T14:30:00Z' (ConvertTo-WdtTuiIncidentTimestamp -Text '2026-11-02T14:30:00Z' -TimeZone $testTimeZone) 'An explicit offset must override the local timezone.'
$dstTimeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time')
foreach ($ambiguousLocalTime in @('2026-11-01 01:30', '2026-03-08 02:30', '2026-02-30 14:30')) {
    $rejected = $false
    try { ConvertTo-WdtTuiIncidentTimestamp -Text $ambiguousLocalTime -TimeZone $dstTimeZone | Out-Null } catch { $rejected = $true }
    Assert-True $rejected "Invalid or ambiguous incident time was accepted: $ambiguousLocalTime."
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

$tokens = $null
$parseErrors = $null
$tuiAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'scripts\tui.ps1'), [ref]$tokens, [ref]$parseErrors)
Assert-Equal 0 $parseErrors.Count 'TUI source must parse without errors.'
$discoveryCalls = @($tuiAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Get-WdtModuleRegistry', 'Get-WdtDiagnosticDefinition')
        }, $true))
Assert-Equal 0 $discoveryCalls.Count 'TUI must not perform hidden registry discovery.'
$literalSpecialIndexes = @($tuiAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.IndexExpressionAst] -and
            $node.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.Target.VariablePath.UserPath -eq 'items' -and
            $node.Index.Extent.Text -match '^(10|11|12|13|14)$'
        }, $true))
Assert-Equal 0 $literalSpecialIndexes.Count 'TUI special item indexes must be derived from the module count.'

$interactiveSession = $tuiAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-WdtInteractiveSession' }, $true)
$interactiveParameters = @($interactiveSession.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-True ($interactiveParameters -contains 'RegistrySnapshot') 'Interactive session must require an explicit registry snapshot.'
$cleanupCalls = @($interactiveSession.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Complete-WdtTuiConsoleFrame' }, $true))
Assert-Equal 1 $cleanupCalls.Count 'Interactive session must call the centralized console cleanup exactly once.'
$cleanupOwner = $cleanupCalls[0].Parent
while ($null -ne $cleanupOwner -and $cleanupOwner -isnot [System.Management.Automation.Language.TrapStatementAst] -and $cleanupOwner -isnot [System.Management.Automation.Language.TryStatementAst]) { $cleanupOwner = $cleanupOwner.Parent }
Assert-True ($null -ne $cleanupOwner -and $cleanupCalls[0].Extent.StartLineNumber -ge $cleanupOwner.Finally.Extent.StartLineNumber) 'Centralized console cleanup must be called from finally.'

foreach ($diagnostic in $state.Diagnostics) { $diagnostic.Selected = ($diagnostic.Id -eq 'Network') }
$parameters = ConvertTo-WdtReportParameters -State $state -RegistrySnapshot $registrySnapshot -ModuleTimeoutSeconds 37 -NoExternalNetworkTests $true -NetworkDnsTestName 'dns.fixture.example' -NetworkHttpsEndpoint 'https://tcp.fixture.example/' -NetworkIcmpTarget '192.0.2.44'
Assert-Equal 1 @($parameters.ModuleDefinitions).Count 'Selected module definitions were not preserved.'
Assert-Equal 'Network' $parameters.ModuleDefinitions[0].Id 'Wrong module definition was selected.'
Assert-True ([object]::ReferenceEquals($registrySnapshot.Modules[3], $parameters.ModuleDefinitions[0])) 'Report conversion must pass the registry definition, not reconstruct it.'
Assert-True $parameters.SuppressConsoleOutput 'TUI must suppress report console output.'
Assert-Equal 37 $parameters.ModuleTimeoutSeconds 'ModuleTimeoutSeconds was not preserved.'
Assert-Equal $true $parameters.CoreOptions['noexternalnetworktests'] 'Boolean core option was not preserved case-insensitively.'
Assert-Equal 'dns.fixture.example' $parameters.CoreOptions['NetworkDnsTestName'] 'DNS name was not preserved.'
Assert-Equal 'https://tcp.fixture.example/' $parameters.CoreOptions['NetworkHttpsEndpoint'] 'HTTPS endpoint was not preserved.'
Assert-Equal '192.0.2.44' $parameters.CoreOptions['NetworkIcmpTarget'] 'ICMP target was not preserved.'
Assert-True ($parameters.CoreOptions.IsReadOnly) 'Core options must be wrapped in a read-only dictionary.'
Assert-True (-not $parameters.ContainsKey('SelectedModules')) 'Legacy selected ID report parameter must not be emitted.'
$coreMutationBlocked = $false
try { $parameters.CoreOptions.Add('Unexpected', 'value') }
catch { $coreMutationBlocked = $true }
Assert-True $coreMutationBlocked 'Core options must reject mutation.'

$serviceUrl = 'https://service.fixture.example/path?token=private'
$networkState = Update-WdtTuiState $state SetNetworkWebServiceUrl -Value $serviceUrl
$networkParameters = ConvertTo-WdtReportParameters -State $networkState -RegistrySnapshot $registrySnapshot
Assert-Equal $serviceUrl $networkParameters.CoreOptions['NetworkWebServiceUrl'] 'The Network module did not receive the configured service URL.'
$disabledParameters = ConvertTo-WdtReportParameters -State $networkState -RegistrySnapshot $registrySnapshot -NoExternalNetworkTests $true
Assert-True (-not $disabledParameters.CoreOptions.ContainsKey('NetworkWebServiceUrl')) 'Disabling external tests must suppress the configured service URL.'
$networkText = (Get-WdtTuiLines -State $networkState -Width 80 -Height 25) -join "`n"
Assert-True ($networkText.Contains('Network service URL: Set') -and -not $networkText.Contains('token=private')) 'The menu must show URL status without redisplaying the URL.'
$cleared = Update-WdtTuiState $networkState SetNetworkWebServiceUrl -Value ''
$clearedParameters = ConvertTo-WdtReportParameters -State $cleared -RegistrySnapshot $registrySnapshot
Assert-True (-not $clearedParameters.CoreOptions.ContainsKey('NetworkWebServiceUrl')) 'Clearing the URL must remove the service probe.'
foreach ($diagnostic in $networkState.Diagnostics) { $diagnostic.Selected = ($diagnostic.Id -eq 'System') }
$noNetworkParameters = ConvertTo-WdtReportParameters -State $networkState -RegistrySnapshot $registrySnapshot
Assert-True (-not $noNetworkParameters.CoreOptions.ContainsKey('NetworkWebServiceUrl')) 'The URL must be omitted when Network is deselected.'

$otherSnapshot = New-TestRegistrySnapshot
$snapshotMismatchBlocked = $false
try { ConvertTo-WdtReportParameters -State $state -RegistrySnapshot $otherSnapshot | Out-Null }
catch { $snapshotMismatchBlocked = $true }
Assert-True $snapshotMismatchBlocked 'Report conversion must reject a different registry snapshot.'

Assert-Equal 'Ascii' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $false -OutputEncodingWebName 'utf-8' -Override 'ascii') 'The ascii override must force the ASCII logo.'
Assert-Equal 'Unicode' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $false -OutputEncodingWebName 'ibm866' -Override 'unicode') 'The unicode override must apply in an interactive host.'
Assert-Equal 'Ascii' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $true -OutputEncodingWebName 'utf-8' -Override 'unicode') 'The unicode override must stay ASCII for redirected output.'
Assert-Equal 'Unicode' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $false -OutputEncodingWebName 'utf-8' -Override '') 'Interactive UTF-8 output must select the Unicode logo.'
Assert-Equal 'Ascii' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $true -OutputEncodingWebName 'utf-8' -Override '') 'Redirected output must select the ASCII logo.'
Assert-Equal 'Ascii' (Get-WdtTuiLogoModeDecision -IsOutputRedirected $false -OutputEncodingWebName 'ibm866' -Override '') 'An OEM encoding must select the ASCII logo.'

$privateResult = [pscustomobject]@{
    ExitCode=0; Completeness='Partial'; WarningCount=1; ErrorCount=0; ElapsedTime=[timespan]::Zero
    TextReportPath='C:\Users\FixtureUser\report.txt'; MarkdownReportPath='C:\Users\FixtureUser\report.md'
    DisplayTextReportPath='C:\Users\<USER-1>\report.txt'; DisplayMarkdownReportPath='C:\Users\<USER-1>\report.md'
}
$resultLayout = Get-WdtTuiRunResultLayout $privateResult -Width 100
$resultText = (Get-PlainLayoutLines $resultLayout) -join "`n"
Assert-Equal 'Warning' $resultLayout.Mode 'A successful exit with partial output must not use the success layout.'
Assert-True ($resultText.Contains('incomplete output')) 'The result screen must explain the partial capture.'
Assert-True ($resultText.Contains('<USER-1>') -and -not $resultText.Contains('FixtureUser')) 'The result screen must use the same privacy-safe paths as the report.'
$privateResult.PSObject.Properties.Remove('WarningCount')
$privateResult.PSObject.Properties.Remove('ErrorCount')
$incidentResult = (Get-PlainLayoutLines (Get-WdtTuiRunResultLayout $privateResult -Width 100 -RunKind IncidentSymptom)) -join "`n"
Assert-True ($incidentResult.Contains('Incident investigation') -and -not $incidentResult.Contains('WARN:')) 'Incident results without finding counts must display their real status without empty counts.'
$rejected = $false
try { Resolve-WdtFilesystemPath -Path 'Env:WdtFixture' | Out-Null } catch { $rejected = $true }
Assert-True $rejected 'A non-filesystem provider must not be treated as a relative directory.'
Assert-Equal (Join-Path (Get-Location).Path 'WdtFixture') (Resolve-WdtFilesystemPath 'WdtFixture') 'A normal relative output path must resolve in the current directory.'

Write-Host 'TUI snapshots, menus, incident time handling, and report parameters passed.'
