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

function Get-WdtTuiMenuIndex {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$Kind)

    $items = @(Get-WdtTuiMenuItem -State $State)
    for ($index = 0; $index -lt $items.Count; $index++) {
        if ($items[$index].Kind -eq $Kind) { return $index }
    }
    return -1
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

function New-WdtTuiSegment {
    param([string]$Text, [string]$Color = 'White')
    return [pscustomobject]@{ Text = $Text; Color = $Color }
}

function New-WdtTuiLine {
    param([object[]]$Segments)
    return [pscustomobject]@{ Segments = @($Segments) }
}

function ConvertTo-WdtTuiPlainText {
    param([Parameter(Mandatory = $true)]$Line)
    return (@($Line.Segments | ForEach-Object { $_.Text }) -join '')
}

function Limit-WdtTuiSegments {
    param([object[]]$Segments, [int]$Width)

    $remaining = [Math]::Max(0, $Width)
    $limited = @()
    foreach ($segment in @($Segments | Where-Object { $null -ne $_ })) {
        if ($remaining -le 0) { break }
        $text = Format-WdtTuiText -Text $segment.Text -Width $remaining
        if ($text.Length -gt 0) {
            $limited += New-WdtTuiSegment -Text $text -Color $segment.Color
            $remaining -= $text.Length
        }
    }
    return @($limited)
}

function New-WdtTuiMenuLine {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Item,
        [int]$Index,
        [int]$Width,
        [bool]$ShowItemNumbers
    )

    $active = $Index -eq $State.CursorIndex
    $pointer = if ($active) { '> ' } else { '  ' }
    $pointerColor = if ($active) { 'Yellow' } else { 'White' }
    $numberPrefix = if ($ShowItemNumbers) { ('{0}. ' -f ($Index + 1)) } else { '' }
    $numberSegment = if ($ShowItemNumbers) { New-WdtTuiSegment -Text $numberPrefix -Color 'DarkGray' } else { $null }

    if ($Item.Kind -eq 'Diagnostic') {
        $diagnostic = @($State.Diagnostics | Where-Object { $_.Name -eq $Item.Name })[0]
        $checked = [bool]$diagnostic.Selected
        $mark = if ($checked) { '[x]' } else { '[ ]' }
        $separator = ' '
        $labelWidth = [Math]::Max(0, $Width - $numberPrefix.Length - $pointer.Length - $mark.Length - $separator.Length)
        $label = Format-WdtTuiText -Text $Item.Label -Width $labelWidth
        $markColor = if ($checked) { 'Green' } else { 'DarkGray' }
        $labelColor = if ($checked) { 'White' } else { 'Gray' }
        $segments = @($numberSegment, (New-WdtTuiSegment $pointer $pointerColor), (New-WdtTuiSegment $mark $markColor), (New-WdtTuiSegment ($separator + $label) $labelColor))
        return New-WdtTuiLine -Segments (Limit-WdtTuiSegments -Segments $segments -Width $Width)
    }

    if ($Item.Kind -in @('Privacy', 'Markdown')) {
        $enabled = if ($Item.Kind -eq 'Privacy') { [bool]$State.PrivacyMode } else { [bool]$State.ExportMarkdown }
        $mark = if ($enabled) { '[x]' } else { '[ ]' }
        $separator = ' '
        $labelWidth = [Math]::Max(0, $Width - $numberPrefix.Length - $pointer.Length - $mark.Length - $separator.Length)
        $label = Format-WdtTuiText -Text $Item.Label -Width $labelWidth
        $markColor = if ($enabled) { 'Green' } else { 'DarkGray' }
        $labelColor = if ($enabled) { 'White' } else { 'Gray' }
        $segments = @($numberSegment, (New-WdtTuiSegment $pointer $pointerColor), (New-WdtTuiSegment $mark $markColor), (New-WdtTuiSegment ($separator + $label) $labelColor))
        return New-WdtTuiLine -Segments (Limit-WdtTuiSegments -Segments $segments -Width $Width)
    }

    if ($Item.Kind -eq 'Output') {
        $prefix = 'Output: '
        $pathWidth = [Math]::Max(0, $Width - $numberPrefix.Length - $pointer.Length - $prefix.Length)
        $path = Format-WdtTuiPath -Path $State.OutputDirectory -Width $pathWidth
        $segments = @($numberSegment, (New-WdtTuiSegment $pointer $pointerColor), (New-WdtTuiSegment $prefix 'White'), (New-WdtTuiSegment $path 'DarkGray'))
        return New-WdtTuiLine -Segments (Limit-WdtTuiSegments -Segments $segments -Width $Width)
    }

    $color = if ($Item.Kind -eq 'Run') { 'Green' } elseif ($active) { 'Yellow' } else { 'Gray' }
    $labelWidth = [Math]::Max(0, $Width - $numberPrefix.Length - $pointer.Length)
    $label = Format-WdtTuiText -Text $Item.Label -Width $labelWidth
    $segments = @($numberSegment, (New-WdtTuiSegment $pointer $pointerColor), (New-WdtTuiSegment $label $color))
    return New-WdtTuiLine -Segments (Limit-WdtTuiSegments -Segments $segments -Width $Width)
}

function Get-WdtTuiViewport {
    param([int]$ItemCount, [int]$CursorIndex, [int]$Capacity)
    $visible = [Math]::Max(1, [Math]::Min($ItemCount, $Capacity))
    $start = [Math]::Max(0, [Math]::Min($CursorIndex - [Math]::Floor($visible / 2), $ItemCount - $visible))
    return [pscustomobject]@{ Start = $start; End = $start + $visible - 1; Capacity = $visible }
}

function ConvertTo-WdtTuiFallbackAction {
    param([string]$Answer)
    if ($Answer -ieq 'Exit') { return 'Exit' }
    return $null
}

function ConvertTo-WdtTuiFallbackMenuAction {
    param([string]$Answer, [int[]]$VisibleIndexes, [int]$RunIndex)

    if ($Answer -ieq 'A') { return [pscustomobject]@{ Action = 'All'; Index = $null } }
    if ($Answer -ieq 'R') { return [pscustomobject]@{ Action = 'Recommended'; Index = $null } }
    if ($Answer -ieq 'Run') { return [pscustomobject]@{ Action = 'Select'; Index = $RunIndex } }
    if ($Answer -ieq 'Exit') { return [pscustomobject]@{ Action = 'Exit'; Index = $null } }
    if ($Answer -match '^\d+$') {
        $index = [int]$Answer - 1
        if ($VisibleIndexes -contains $index) { return [pscustomobject]@{ Action = 'Select'; Index = $index } }
    }
    return $null
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
    param(
        [Parameter(Mandatory = $true)]$State,
        [int]$Width = 80,
        [int]$Height = 25,
        [bool]$ShowItemNumbers
    )

    $mode = Get-WdtTuiLayoutMode -Width $Width -Height $Height
    if ($mode -eq 'TooSmall') {
        return Get-WdtTuiTooSmallLayout -Width $Width -Height $Height
    }

    $items = @(Get-WdtTuiMenuItem -State $State)
    $lines = @()
    $selected = @(Get-WdtTuiSelectedModule -State $State).Count

    if ($mode -eq 'Normal') {
        foreach ($logo in @('W   W  DDD   TTTTT', 'W W W  D  D    T', ' W W   DDD     T')) {
            $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text $logo -Width $Width) 'Cyan'))
        }
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'Windows Diagnostics Toolkit' -Width $Width) 'White'))
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'Read-only | Local reports | No telemetry' -Width $Width) 'DarkGray'))
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'Diagnostics' -Width $Width) 'Cyan'))
        for ($index = 0; $index -lt $State.Diagnostics.Count; $index++) {
            $lines += New-WdtTuiMenuLine -State $State -Item $items[$index] -Index $index -Width $Width -ShowItemNumbers $ShowItemNumbers
        }
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text ('Selected: {0}' -f $selected) -Width $Width) 'DarkGray'))
        for ($index = $State.Diagnostics.Count; $index -lt $items.Count; $index++) {
            $lines += New-WdtTuiMenuLine -State $State -Item $items[$index] -Index $index -Width $Width -ShowItemNumbers $ShowItemNumbers
        }
    }
    else {
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'WDT - Windows Diagnostics Toolkit' -Width $Width) 'White'))
        $status = 'Selected: {0} | Privacy: {1} | Markdown: {2}' -f $selected, $(if ($State.PrivacyMode) { 'On' } else { 'Off' }), $(if ($State.ExportMarkdown) { 'On' } else { 'Off' })
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text $status -Width $Width) 'DarkGray'))
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment '' 'Cyan'))

        $headerRows = 1
        $statusRows = 1
        $viewportIndicatorRows = 1
        $helpRows = 2
        $errorRows = if ([string]::IsNullOrWhiteSpace($State.ErrorMessage)) { 0 } else { 1 }
        $menuCapacity = [Math]::Max(1, $Height - $headerRows - $statusRows - $viewportIndicatorRows - $helpRows - $errorRows)
        $viewport = Get-WdtTuiViewport -ItemCount $items.Count -CursorIndex $State.CursorIndex -Capacity $menuCapacity
        $range = 'Items {0}-{1} of {2}' -f ($viewport.Start + 1), ($viewport.End + 1), $items.Count
        $lines[$lines.Count - 1] = New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text $range -Width $Width) 'Cyan'))
        for ($index = $viewport.Start; $index -le $viewport.End; $index++) {
            $lines += New-WdtTuiMenuLine -State $State -Item $items[$index] -Index $index -Width $Width -ShowItemNumbers $ShowItemNumbers
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($State.ErrorMessage)) {
        $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text ('Error: ' + $State.ErrorMessage) -Width $Width) 'Red'))
    }
    $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'Up/Down Navigate  Space Toggle  Enter Select' -Width $Width) 'DarkGray'))
    $lines += New-WdtTuiLine -Segments @((New-WdtTuiSegment (Format-WdtTuiText -Text 'A All  R Recommended  Esc Exit' -Width $Width) 'DarkGray'))
    return [pscustomobject]@{
        Mode = $mode
        Lines = @($lines)
        Viewport = $(if ($mode -eq 'Compact') { $viewport } else { $null })
        VisibleIndexes = $(if ($mode -eq 'Compact') { @($viewport.Start..$viewport.End) } else { @(0..($items.Count - 1)) })
    }
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
    param([Parameter(Mandatory = $true)]$State, [bool]$ShowItemNumbers)

    $width = 80
    $height = 25
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        $height = $Host.UI.RawUI.WindowSize.Height
    }
    catch { }
    try {
        Clear-Host
    }
    catch { }

    $useColor = Test-WdtTuiColorOutput
    $layout = Get-WdtTuiLayout -State $State -Width $width -Height $height -ShowItemNumbers $ShowItemNumbers
    foreach ($line in @($layout.Lines)) {
        Write-WdtTuiLine -Line $line -UseColor $useColor
    }
}

function Show-WdtTuiRunResult {
    param($Result)
    foreach ($line in @(Get-WdtTuiRunResultLayout -Result $Result)) { Write-WdtTuiLine -Line $line -UseColor (Test-WdtTuiColorOutput) }
    Write-Host ('TXT report: {0}' -f $Result.TextReportPath)
    if (-not [string]::IsNullOrWhiteSpace($Result.MarkdownReportPath)) { Write-Host ('Markdown report: {0}' -f $Result.MarkdownReportPath) }
    Write-Host ('WARN findings: {0}' -f $Result.WarningCount); Write-Host ('ERROR findings: {0}' -f $Result.ErrorCount); Write-Host ('Elapsed: {0}' -f $Result.ElapsedTime)
}

function Invoke-WdtInteractiveSession {
    param(
        [string[]]$InitialSelection,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    if ([System.Console]::IsInputRedirected) {
        Write-Host 'Interactive input is unavailable.'
        Write-Host 'Use -All or select one or more diagnostic modules.'
        return 2
    }

    $state = New-WdtTuiState -OutputDirectory $OutputDirectory -InitialSelection $InitialSelection
    $useReadKey = $true
    $lastExitCode = 0

    try {
        while (-not $state.ExitRequested) {
            $width = 80
            $height = 25
            try {
                $width = $Host.UI.RawUI.WindowSize.Width
                $height = $Host.UI.RawUI.WindowSize.Height
            }
            catch { }

            $layout = Get-WdtTuiLayout -State $state -Width $width -Height $height -ShowItemNumbers (-not $useReadKey)
            Show-WdtTuiScreen -State $state -ShowItemNumbers (-not $useReadKey)
            $mode = $layout.Mode
            $action = $null

            if ($useReadKey) {
                try {
                    $keyInfo = [System.Console]::ReadKey($true)
                    if ($mode -eq 'TooSmall') {
                        if ($keyInfo.Key -eq [System.ConsoleKey]::Escape) { return $lastExitCode }
                        continue
                    }
                    if ($keyInfo.Key -eq [System.ConsoleKey]::UpArrow) { $action = 'Up' }
                    elseif ($keyInfo.Key -eq [System.ConsoleKey]::DownArrow) { $action = 'Down' }
                    elseif ($keyInfo.Key -eq [System.ConsoleKey]::Spacebar) { $action = 'Toggle' }
                    elseif ($keyInfo.Key -eq [System.ConsoleKey]::Enter) { $action = 'Select' }
                    elseif ($keyInfo.Key -eq [System.ConsoleKey]::Escape) { $action = 'Exit' }
                    elseif ($keyInfo.KeyChar -eq 'a' -or $keyInfo.KeyChar -eq 'A') { $action = 'All' }
                    elseif ($keyInfo.KeyChar -eq 'r' -or $keyInfo.KeyChar -eq 'R') { $action = 'Recommended' }
                }
                catch {
                    $useReadKey = $false
                    $state.ErrorMessage = 'Direct key input is unavailable. Numbered input is active.'
                    continue
                }
            }
            else {
                if ($mode -eq 'TooSmall') {
                    $answer = Read-Host 'Resize the window, then press Enter (or type Exit)'
                    if ((ConvertTo-WdtTuiFallbackAction -Answer $answer) -eq 'Exit') { return $lastExitCode }
                    continue
                }

                $answer = Read-Host 'Enter A, R, Run, Exit, or an item number'
                $runIndex = Get-WdtTuiMenuIndex -State $state -Kind 'Run'
                $fallbackAction = ConvertTo-WdtTuiFallbackMenuAction -Answer $answer -VisibleIndexes $layout.VisibleIndexes -RunIndex $runIndex
                if ($null -eq $fallbackAction) {
                    $state.ErrorMessage = 'Unknown menu command.'
                    continue
                }
                if ($null -ne $fallbackAction.Index) {
                    while ($state.CursorIndex -ne $fallbackAction.Index) {
                        $state = Update-WdtTuiState -State $state -Action MoveDown
                    }
                }
                $action = $fallbackAction.Action
            }

            $state.ErrorMessage = $null

            if ($action -eq 'Up') { $state = Update-WdtTuiState -State $state -Action MoveUp; continue }
            if ($action -eq 'Down') { $state = Update-WdtTuiState -State $state -Action MoveDown; continue }
            if ($action -eq 'All') { $state = Update-WdtTuiState -State $state -Action SelectAll; continue }
            if ($action -eq 'Recommended') { $state = Update-WdtTuiState -State $state -Action SelectRecommended; continue }
            if ($action -eq 'Exit') { $state = Update-WdtTuiState -State $state -Action Exit; continue }
            if ($action -notin @('Toggle', 'Select')) { continue }

            $state = Update-WdtTuiState -State $state -Action $(if ($action -eq 'Toggle') { 'ToggleCurrent' } else { 'SelectCurrent' })
            if ($state.ActionRequested -eq 'Output') {
                $path = Read-Host 'Output directory'
                if ([string]::IsNullOrWhiteSpace($path)) {
                    $state.ErrorMessage = 'Output directory cannot be empty.'
                    continue
                }
                try {
                    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
                    $state = Update-WdtTuiState -State $state -Action SetOutputDirectory -Value $resolvedPath
                }
                catch {
                    $state.ErrorMessage = $_.Exception.Message
                }
                continue
            }
            if ($state.ExitRequested -or $state.ActionRequested -ne 'Run') { continue }
            try {
                $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($state.OutputDirectory)
                $state = Update-WdtTuiState -State $state -Action SetOutputDirectory -Value $resolvedPath
            }
            catch {
                $state.ErrorMessage = ('Invalid output directory: ' + $_.Exception.Message)
                continue
            }
            $reportParameters = ConvertTo-WdtReportParameters -State $state
            if (@($reportParameters.SelectedModules).Count -eq 0) { $state.ErrorMessage = 'Select at least one diagnostic module.'; continue }
            try {
                try { Clear-Host } catch { }
                Write-Host 'Running diagnostics...'
                $result = Invoke-WdtReport @reportParameters
                $lastExitCode = $result.ExitCode
                Show-WdtTuiRunResult -Result $result
            }
            catch {
                $lastExitCode = 1
                Write-Host ('Diagnostics failed: ' + $_.Exception.Message) -ForegroundColor Red
            }
            if ($useReadKey) {
                Write-Host 'Press Enter to return to the menu or Escape to exit.'
                try {
                    if ([System.Console]::ReadKey($true).Key -eq [System.ConsoleKey]::Escape) { return $lastExitCode }
                }
                catch { $useReadKey = $false }
            }
            if (-not $useReadKey) { Read-Host 'Press Enter to return to the menu' | Out-Null }
        }
    }
    finally {
        Write-Host ''
    }
    return $lastExitCode
}
