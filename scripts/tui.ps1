[CmdletBinding()]
param()

function Get-WdtRecommendedSelection {
    return @(Get-WdtDiagnosticDefinition | Where-Object { $_.Recommended } | ForEach-Object { $_.Name })
}

function New-WdtTuiState {
    param([Parameter(Mandatory = $true)][string]$OutputDirectory, [string[]]$InitialSelection)

    $selectedNames = @($InitialSelection)
    if ($null -eq $InitialSelection -or $InitialSelection.Count -eq 0) { $selectedNames = @(Get-WdtRecommendedSelection) }
    return [pscustomobject]@{
        Diagnostics = @(Get-WdtDiagnosticDefinition | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Label = $_.Label; Selected = $_.Name -in $selectedNames } })
        PrivacyMode = $true; ExportMarkdown = $true; OutputDirectory = $OutputDirectory; CursorIndex = 0
        ErrorMessage = $null; ExitRequested = $false; ActionRequested = $null
    }
}

function Get-WdtTuiSelectedModule { param([Parameter(Mandatory = $true)]$State) return @($State.Diagnostics | Where-Object { $_.Selected } | ForEach-Object { $_.Name }) }

function ConvertTo-WdtReportParameters {
    param([Parameter(Mandatory = $true)]$State)
    return @{ SelectedModules = @(Get-WdtTuiSelectedModule -State $State); OutputDirectory = $State.OutputDirectory; PrivacyMode = [bool]$State.PrivacyMode; ExportMarkdown = [bool]$State.ExportMarkdown }
}

function Get-WdtTuiMenuItem {
    param([Parameter(Mandatory = $true)]$State)
    $items = @($State.Diagnostics | ForEach-Object { [pscustomobject]@{ Kind = 'Diagnostic'; Name = $_.Name; Label = $_.Label } })
    $items += @(
        [pscustomobject]@{ Kind = 'Privacy'; Name = 'PrivacyMode'; Label = 'Privacy Mode' },
        [pscustomobject]@{ Kind = 'Markdown'; Name = 'ExportMarkdown'; Label = 'Markdown report' },
        [pscustomobject]@{ Kind = 'Output'; Name = 'OutputDirectory'; Label = 'Output directory' },
        [pscustomobject]@{ Kind = 'Run'; Name = 'Run'; Label = 'Run diagnostics' },
        [pscustomobject]@{ Kind = 'Exit'; Name = 'Exit'; Label = 'Exit' }
    )
    return $items
}

function Update-WdtTuiState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][ValidateSet('MoveUp', 'MoveDown', 'ToggleCurrent', 'SelectCurrent', 'SelectAll', 'SelectRecommended', 'SetOutputDirectory', 'Exit')][string]$Action,
        [string]$Value
    )

    $nextState = [pscustomobject]@{
        Diagnostics = @($State.Diagnostics | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Label = $_.Label; Selected = [bool]$_.Selected } })
        PrivacyMode = [bool]$State.PrivacyMode; ExportMarkdown = [bool]$State.ExportMarkdown; OutputDirectory = [string]$State.OutputDirectory
        CursorIndex = [int]$State.CursorIndex; ErrorMessage = $State.ErrorMessage; ExitRequested = [bool]$State.ExitRequested; ActionRequested = $null
    }
    $items = @(Get-WdtTuiMenuItem -State $nextState)
    if ($Action -eq 'MoveUp') { $nextState.CursorIndex = if ($nextState.CursorIndex -le 0) { $items.Count - 1 } else { $nextState.CursorIndex - 1 }; return $nextState }
    if ($Action -eq 'MoveDown') { $nextState.CursorIndex = if ($nextState.CursorIndex -ge $items.Count - 1) { 0 } else { $nextState.CursorIndex + 1 }; return $nextState }
    if ($Action -eq 'SelectAll') { foreach ($diagnostic in $nextState.Diagnostics) { $diagnostic.Selected = $true }; return $nextState }
    if ($Action -eq 'SelectRecommended') { $recommended = @(Get-WdtRecommendedSelection); foreach ($diagnostic in $nextState.Diagnostics) { $diagnostic.Selected = $diagnostic.Name -in $recommended }; return $nextState }
    if ($Action -eq 'SetOutputDirectory') { $nextState.OutputDirectory = $Value; return $nextState }
    if ($Action -eq 'Exit') { $nextState.ExitRequested = $true; $nextState.ActionRequested = 'Exit'; return $nextState }

    $currentItem = $items[$nextState.CursorIndex]
    if ($Action -eq 'ToggleCurrent' -or $Action -eq 'SelectCurrent') {
        if ($currentItem.Kind -eq 'Diagnostic') { foreach ($diagnostic in $nextState.Diagnostics) { if ($diagnostic.Name -eq $currentItem.Name) { $diagnostic.Selected = -not $diagnostic.Selected; break } } }
        elseif ($currentItem.Kind -eq 'Privacy') { $nextState.PrivacyMode = -not $nextState.PrivacyMode }
        elseif ($currentItem.Kind -eq 'Markdown') { $nextState.ExportMarkdown = -not $nextState.ExportMarkdown }
        elseif ($Action -eq 'SelectCurrent') { $nextState.ActionRequested = $currentItem.Kind; if ($currentItem.Kind -eq 'Exit') { $nextState.ExitRequested = $true } }
    }
    return $nextState
}

function Format-WdtTuiText {
    param([AllowEmptyString()][string]$Text, [int]$Width)
    $safeText = if ($null -eq $Text) { '' } else { $Text }
    if ($Width -le 0) { return '' }
    if ($safeText.Length -le $Width) { return $safeText }
    if ($Width -lt 4) { return $safeText.Substring(0, $Width) }
    return $safeText.Substring(0, $Width - 3) + '...'
}

function Format-WdtTuiPath { param([string]$Path, [int]$Width) return (Format-WdtTuiText -Text $Path -Width $Width) }

function Get-WdtTuiLayoutMode {
    param([int]$Width, [int]$Height)
    if ($Width -ge 60 -and $Height -ge 25) { return 'Normal' }
    if ($Width -ge 40 -and $Height -ge 18) { return 'Compact' }
    return 'TooSmall'
}

function New-WdtTuiSegment { param([string]$Text, [string]$Color = 'White') return [pscustomobject]@{ Text = $Text; Color = $Color } }
function New-WdtTuiLine { param([object[]]$Segments) return [pscustomobject]@{ Segments = @($Segments) } }
function ConvertTo-WdtTuiPlainText { param([Parameter(Mandatory = $true)]$Line) return (@($Line.Segments | ForEach-Object { $_.Text }) -join '') }

function New-WdtTuiMenuLine {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)]$Item, [int]$Index, [int]$Width)
    $active = $Index -eq $State.CursorIndex
    $pointer = if ($active) { '> ' } else { '  ' }
    $pointerColor = if ($active) { 'Yellow' } else { 'White' }
    if ($Item.Kind -eq 'Diagnostic') {
        $diagnostic = @($State.Diagnostics | Where-Object { $_.Name -eq $Item.Name })[0]
        $checked = [bool]$diagnostic.Selected; $mark = if ($checked) { '[x]' } else { '[ ]' }
        $label = Format-WdtTuiText -Text $Item.Label -Width ([Math]::Max(0, $Width - 5))
        return New-WdtTuiLine -Segments @((New-WdtTuiSegment $pointer $pointerColor), (New-WdtTuiSegment $mark $(if ($checked) { 'Green' } else { 'DarkGray' })), (New-WdtTuiSegment (' ' + $label) $(if ($checked) { 'White' } else { 'Gray' })))
    }
    if ($Item.Kind -in @('Privacy', 'Markdown')) {
        $enabled = if ($Item.Kind -eq 'Privacy') { [bool]$State.PrivacyMode } else { [bool]$State.ExportMarkdown }
        $mark = if ($enabled) { '[x]' } else { '[ ]' }
        $label = Format-WdtTuiText -Text $Item.Label -Width ([Math]::Max(0, $Width - 5))
        return New-WdtTuiLine -Segments @((New-WdtTuiSegment $pointer $pointerColor), (New-WdtTuiSegment $mark $(if ($enabled) { 'Green' } else { 'DarkGray' })), (New-WdtTuiSegment (' ' + $label) $(if ($enabled) { 'White' } else { 'Gray' })))
    }
    if ($Item.Kind -eq 'Output') {
        $prefix = 'Output: '; $path = Format-WdtTuiPath -Path $State.OutputDirectory -Width ([Math]::Max(0, $Width - $pointer.Length - $prefix.Length))
        return New-WdtTuiLine -Segments @((New-WdtTuiSegment $pointer $pointerColor), (New-WdtTuiSegment $prefix 'White'), (New-WdtTuiSegment $path 'DarkGray'))
    }
    $color = if ($Item.Kind -eq 'Run') { 'Green' } elseif ($active) { 'Yellow' } else { 'Gray' }
    return New-WdtTuiLine -Segments @((New-WdtTuiSegment $pointer $pointerColor), (New-WdtTuiSegment (Format-WdtTuiText -Text $Item.Label -Width ([Math]::Max(0, $Width - $pointer.Length))) $color))
}

function Get-WdtTuiViewport {
    param([int]$ItemCount, [int]$CursorIndex, [int]$Capacity)
    $visible = [Math]::Max(1, [Math]::Min($ItemCount, $Capacity))
    $start = [Math]::Max(0, [Math]::Min($CursorIndex - [Math]::Floor($visible / 2), $ItemCount - $visible))
    return [pscustomobject]@{ Start = $start; End = $start + $visible - 1; Capacity = $visible }
}

function Get-WdtTuiTooSmallLayout {
    param([int]$Width, [int]$Height)
    $lines = @(
        'WDT - terminal window is too small.',
        'Minimum size: 40x18.',
        ('Current size: {0}x{1}.' -f $Width, $Height),
        'Resize the window and press any key.',
        'Esc exits.'
    ) | ForEach-Object { New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text $_ -Width $Width) $(if ($_ -like 'WDT*') { 'Yellow' } else { 'DarkGray' }))) }
    return [pscustomobject]@{ Mode = 'TooSmall'; Lines = @($lines); Viewport = $null }
}

function Get-WdtTuiLayout {
    param([Parameter(Mandatory = $true)]$State, [int]$Width = 80, [int]$Height = 25)
    $mode = Get-WdtTuiLayoutMode -Width $Width -Height $Height
    if ($mode -eq 'TooSmall') { return Get-WdtTuiTooSmallLayout -Width $Width -Height $Height }
    $items = @(Get-WdtTuiMenuItem -State $State)
    $lines = @(); $selected = @(Get-WdtTuiSelectedModule -State $State).Count
    if ($mode -eq 'Normal') {
        foreach ($logo in @('W   W  DDD   TTTTT', 'W W W  D  D    T', ' W W   DDD     T')) { $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text $logo -Width $Width) 'Cyan')) }
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'Windows Diagnostics Toolkit' -Width $Width) 'White'))
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'Read-only | Local reports | No telemetry' -Width $Width) 'DarkGray'))
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'Diagnostics' -Width $Width) 'Cyan'))
        for ($index = 0; $index -lt $State.Diagnostics.Count; $index++) { $lines += New-WdtTuiMenuLine -State $State -Item $items[$index] -Index $index -Width $Width }
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text ('Selected: {0}' -f $selected) -Width $Width) 'DarkGray'))
        for ($index = $State.Diagnostics.Count; $index -lt $items.Count; $index++) { $lines += New-WdtTuiMenuLine -State $State -Item $items[$index] -Index $index -Width $Width }
    }
    else {
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'WDT - Windows Diagnostics Toolkit' -Width $Width) 'White'))
        $status = 'Selected: {0} | Privacy: {1} | Markdown: {2}' -f $selected, $(if ($State.PrivacyMode) { 'On' } else { 'Off' }), $(if ($State.ExportMarkdown) { 'On' } else { 'Off' })
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text $status -Width $Width) 'DarkGray'))
        $viewport = Get-WdtTuiViewport -ItemCount $items.Count -CursorIndex $State.CursorIndex -Capacity 13
        $range = 'Items {0}-{1} of {2}' -f ($viewport.Start + 1), ($viewport.End + 1), $items.Count
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text $range -Width $Width) 'Cyan'))
        for ($index = $viewport.Start; $index -le $viewport.End; $index++) { $lines += New-WdtTuiMenuLine -State $State -Item $items[$index] -Index $index -Width $Width }
    }
    if (-not [string]::IsNullOrWhiteSpace($State.ErrorMessage)) { $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text ('Error: ' + $State.ErrorMessage) -Width $Width) 'Red')) }
    $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'Up/Down Navigate  Space Toggle  Enter Select' -Width $Width) 'DarkGray'))
    $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'A All  R Recommended  Esc Exit' -Width $Width) 'DarkGray'))
    return [pscustomobject]@{ Mode = $mode; Lines = @($lines); Viewport = $(if ($mode -eq 'Compact') { $viewport } else { $null }) }
}

function Get-WdtTuiLines { param([Parameter(Mandatory = $true)]$State, [int]$Width = 80, [int]$Height = 25) return @((Get-WdtTuiLayout -State $State -Width $Width -Height $Height).Lines | ForEach-Object { ConvertTo-WdtTuiPlainText $_ }) }
function Get-WdtTuiRunResultLayout {
    param([Parameter(Mandatory = $true)]$Result)
    $text = if ($Result.ExitCode -eq 0) { 'Diagnostics completed successfully.' } else { 'Diagnostics completed with partial failures.' }
    $color = if ($Result.ExitCode -eq 0) { 'Green' } else { 'Yellow' }
    return @((New-WdtTuiLine -Segments @((New-WdtTuiSegment $text $color))))
}

function Test-WdtTuiColorOutput {
    try { return -not [System.Console]::IsOutputRedirected -and $null -ne $Host.UI }
    catch { return $false }
}

function Write-WdtTuiLine {
    param([Parameter(Mandatory = $true)]$Line, [bool]$UseColor)
    $plainText = ConvertTo-WdtTuiPlainText -Line $Line
    if (-not $UseColor) { Write-Host $plainText; return }
    try {
        foreach ($segment in @($Line.Segments)) { Write-Host $segment.Text -NoNewline -ForegroundColor $segment.Color }
        Write-Host
    }
    catch { Write-Host $plainText }
}

function Show-WdtTuiScreen {
    param([Parameter(Mandatory = $true)]$State)
    $width = 80; $height = 25
    try { $width = $Host.UI.RawUI.WindowSize.Width; $height = $Host.UI.RawUI.WindowSize.Height } catch { }
    try { Clear-Host } catch { }
    $useColor = Test-WdtTuiColorOutput
    foreach ($line in @((Get-WdtTuiLayout -State $State -Width $width -Height $height).Lines)) { Write-WdtTuiLine -Line $line -UseColor $useColor }
}

function Show-WdtTuiRunResult {
    param($Result)
    foreach ($line in @(Get-WdtTuiRunResultLayout -Result $Result)) { Write-WdtTuiLine -Line $line -UseColor (Test-WdtTuiColorOutput) }
    Write-Host ('TXT report: {0}' -f $Result.TextReportPath)
    if (-not [string]::IsNullOrWhiteSpace($Result.MarkdownReportPath)) { Write-Host ('Markdown report: {0}' -f $Result.MarkdownReportPath) }
    Write-Host ('WARN findings: {0}' -f $Result.WarningCount); Write-Host ('ERROR findings: {0}' -f $Result.ErrorCount); Write-Host ('Elapsed: {0}' -f $Result.ElapsedTime)
}

function Invoke-WdtInteractiveSession {
    param([string[]]$InitialSelection, [Parameter(Mandatory = $true)][string]$OutputDirectory)
    if ([System.Console]::IsInputRedirected) { Write-Host 'Interactive input is unavailable.'; Write-Host 'Use -All or select one or more diagnostic modules.'; return 2 }
    $state = New-WdtTuiState -OutputDirectory $OutputDirectory -InitialSelection $InitialSelection; $useReadKey = $true; $lastExitCode = 0
    try {
        while (-not $state.ExitRequested) {
            Show-WdtTuiScreen -State $state
            $mode = Get-WdtTuiLayoutMode -Width $(try { $Host.UI.RawUI.WindowSize.Width } catch { 80 }) -Height $(try { $Host.UI.RawUI.WindowSize.Height } catch { 25 })
            $action = $null
            if ($useReadKey) {
                try {
                    $keyInfo = [System.Console]::ReadKey($true)
                    if ($mode -eq 'TooSmall') { if ($keyInfo.Key -eq [System.ConsoleKey]::Escape) { return $lastExitCode }; continue }
                    if ($keyInfo.Key -eq [System.ConsoleKey]::UpArrow) { $action = 'Up' } elseif ($keyInfo.Key -eq [System.ConsoleKey]::DownArrow) { $action = 'Down' } elseif ($keyInfo.Key -eq [System.ConsoleKey]::Spacebar) { $action = 'Toggle' } elseif ($keyInfo.Key -eq [System.ConsoleKey]::Enter) { $action = 'Select' } elseif ($keyInfo.Key -eq [System.ConsoleKey]::Escape) { $action = 'Exit' } elseif ($keyInfo.KeyChar -eq 'a' -or $keyInfo.KeyChar -eq 'A') { $action = 'All' } elseif ($keyInfo.KeyChar -eq 'r' -or $keyInfo.KeyChar -eq 'R') { $action = 'Recommended' }
                }
                catch { $useReadKey = $false; $state.ErrorMessage = 'Direct key input is unavailable. Numbered input is active.'; continue }
            }
            else {
                if ($mode -eq 'TooSmall') { Read-Host 'Resize the window, then press Enter (or type Exit)' | Out-Null; continue }
                $answer = Read-Host 'Enter A, R, Run, Exit, or an item number'
                if ($answer -ieq 'A') { $action = 'All' } elseif ($answer -ieq 'R') { $action = 'Recommended' } elseif ($answer -ieq 'Run') { while ($state.CursorIndex -ne 13) { $state = Update-WdtTuiState -State $state -Action MoveDown }; $action = 'Select' } elseif ($answer -ieq 'Exit') { $action = 'Exit' } elseif ($answer -match '^\d+$') { $number = [int]$answer; $items = @(Get-WdtTuiMenuItem -State $state); if ($number -ge 1 -and $number -le $items.Count) { while ($state.CursorIndex -ne ($number - 1)) { $state = Update-WdtTuiState -State $state -Action MoveDown }; $action = 'Select' } }
                if ($null -eq $action) { $state.ErrorMessage = 'Unknown menu command.'; continue }
            }
            $state.ErrorMessage = $null
            if ($action -eq 'Up') { $state = Update-WdtTuiState -State $state -Action MoveUp; continue }; if ($action -eq 'Down') { $state = Update-WdtTuiState -State $state -Action MoveDown; continue }; if ($action -eq 'All') { $state = Update-WdtTuiState -State $state -Action SelectAll; continue }; if ($action -eq 'Recommended') { $state = Update-WdtTuiState -State $state -Action SelectRecommended; continue }; if ($action -eq 'Exit') { $state = Update-WdtTuiState -State $state -Action Exit; continue }; if ($action -notin @('Toggle', 'Select')) { continue }
            $state = Update-WdtTuiState -State $state -Action $(if ($action -eq 'Toggle') { 'ToggleCurrent' } else { 'SelectCurrent' })
            if ($state.ActionRequested -eq 'Output') { $path = Read-Host 'Output directory'; if ([string]::IsNullOrWhiteSpace($path)) { $state.ErrorMessage = 'Output directory cannot be empty.'; continue }; try { $state = Update-WdtTuiState -State $state -Action SetOutputDirectory -Value $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path) } catch { $state.ErrorMessage = $_.Exception.Message }; continue }
            if ($state.ExitRequested -or $state.ActionRequested -ne 'Run') { continue }
            try { $state = Update-WdtTuiState -State $state -Action SetOutputDirectory -Value $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($state.OutputDirectory) } catch { $state.ErrorMessage = ('Invalid output directory: ' + $_.Exception.Message); continue }
            $reportParameters = ConvertTo-WdtReportParameters -State $state
            if (@($reportParameters.SelectedModules).Count -eq 0) { $state.ErrorMessage = 'Select at least one diagnostic module.'; continue }
            try { try { Clear-Host } catch { }; Write-Host 'Running diagnostics...'; $result = Invoke-WdtReport @reportParameters; $lastExitCode = $result.ExitCode; Show-WdtTuiRunResult -Result $result } catch { $lastExitCode = 1; Write-Host ('Diagnostics failed: ' + $_.Exception.Message) -ForegroundColor Red }
            if ($useReadKey) { Write-Host 'Press Enter to return to the menu or Escape to exit.'; try { if ([System.Console]::ReadKey($true).Key -eq [System.ConsoleKey]::Escape) { return $lastExitCode } } catch { $useReadKey = $false } }
            if (-not $useReadKey) { Read-Host 'Press Enter to return to the menu' | Out-Null }
        }
    }
    finally { Write-Host '' }
    return $lastExitCode
}
