[CmdletBinding()]
param()

. $PSScriptRoot\report-common.ps1

function Get-WdtRecommendedSelection {
    param([Parameter(Mandatory = $true)]$RegistrySnapshot)
    return @($RegistrySnapshot.Modules | Where-Object { $_.Recommended } | ForEach-Object { $_.Id })
}

function New-WdtTuiState {
    param(
        [Parameter(Mandatory = $true)]$RegistrySnapshot,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [string[]]$InitialSelection,
        [string]$NetworkWebServiceUrl,
        [bool]$NoExternalNetworkTests
    )

    $selectedNames = @($InitialSelection)
    if ($null -eq $InitialSelection -or $InitialSelection.Count -eq 0) {
        $selectedNames = @(Get-WdtRecommendedSelection -RegistrySnapshot $RegistrySnapshot)
    }

    return [pscustomobject]@{
        RegistrySnapshot = $RegistrySnapshot
        Diagnostics = @($RegistrySnapshot.Modules | ForEach-Object {
                [pscustomobject]@{
                    Id = $_.Id
                    Label = $_.Label
                    Selected = $_.Id -in $selectedNames
                }
            })
        PrivacyMode = $true
        ExportMarkdown = $true
        OutputDirectory = $OutputDirectory
        NetworkWebServiceUrl = $NetworkWebServiceUrl
        NoExternalNetworkTests = $NoExternalNetworkTests
        Page = 'Main'
        CursorIndex = 0
        ErrorMessage = $null
        ExitRequested = $false
        ActionRequested = $null
        ActionValue = $null
    }
}

function Get-WdtTuiSelectedModule {
    param([Parameter(Mandatory = $true)]$State)
    return @($State.Diagnostics | Where-Object { $_.Selected } | ForEach-Object { $_.Id })
}

function ConvertTo-WdtReportParameters {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$RegistrySnapshot,
        [int]$ModuleTimeoutSeconds = 180,
        [bool]$NoExternalNetworkTests = $State.NoExternalNetworkTests,
        [string]$NetworkDnsTestName = 'www.microsoft.com',
        [string]$NetworkHttpsEndpoint = 'https://www.microsoft.com/',
        [string]$NetworkIcmpTarget = '1.1.1.1'
    )

    if (-not [System.Object]::ReferenceEquals($State.RegistrySnapshot, $RegistrySnapshot)) {
        throw 'The TUI state and report conversion must use the same registry snapshot.'
    }

    $selectedIds = @(Get-WdtTuiSelectedModule -State $State)
    $moduleDefinitions = @($RegistrySnapshot.Modules | Where-Object { $_.Id -in $selectedIds })
    $coreOptions = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $coreOptions.Add('NoExternalNetworkTests', [bool]$NoExternalNetworkTests)
    $coreOptions.Add('NetworkDnsTestName', [string]$NetworkDnsTestName)
    $coreOptions.Add('NetworkHttpsEndpoint', [string]$NetworkHttpsEndpoint)
    $coreOptions.Add('NetworkIcmpTarget', [string]$NetworkIcmpTarget)
    if (-not $NoExternalNetworkTests -and $State.NetworkWebServiceUrl -and
        @($moduleDefinitions | Where-Object { $_.OptionBindings -and $_.OptionBindings.ContainsKey('NetworkWebServiceUrl') }).Count -gt 0) {
        $coreOptions.Add('NetworkWebServiceUrl', [string]$State.NetworkWebServiceUrl)
    }
    $readOnlyCoreOptions = [System.Collections.ObjectModel.ReadOnlyDictionary[string,object]]::new($coreOptions)

    return @{
        ModuleDefinitions = $moduleDefinitions
        CoreOptions = $readOnlyCoreOptions
        OutputDirectory = $State.OutputDirectory
        PrivacyMode = [bool]$State.PrivacyMode
        ExportMarkdown = [bool]$State.ExportMarkdown
        SuppressConsoleOutput = $true
        ModuleTimeoutSeconds = $ModuleTimeoutSeconds
    }
}

function Get-WdtTuiMenuItem {
    param([Parameter(Mandatory = $true)]$State)

    if ($State.Page -eq 'Recording') {
        return @(
            [pscustomobject]@{ Kind = 'StartRecording'; Label = 'Record for 60 seconds (default)'; Value = 60 },
            [pscustomobject]@{ Kind = 'StartRecording'; Label = 'Record for 90 seconds'; Value = 90 },
            [pscustomobject]@{ Kind = 'StartRecording'; Label = 'Record for 120 seconds'; Value = 120 },
            [pscustomobject]@{ Kind = 'Back'; Label = 'Back' }
        )
    }
    if ($State.Page -eq 'Incident') {
        return @(
            [pscustomobject]@{ Kind = 'IncidentSymptom'; Label = 'Application crash or hang'; Value = 'AppFailure' },
            [pscustomobject]@{ Kind = 'IncidentSymptom'; Label = 'Unexpected restart'; Value = 'UnexpectedRestart' },
            [pscustomobject]@{ Kind = 'Back'; Label = 'Back' }
        )
    }

    $items = @($State.Diagnostics | ForEach-Object {
            [pscustomobject]@{ Kind = 'Diagnostic'; Id = $_.Id; Label = $_.Label }
        })
    $items += @(
        [pscustomobject]@{ Kind = 'Privacy'; Label = 'Privacy Mode' },
        [pscustomobject]@{ Kind = 'Markdown'; Label = 'Markdown report' },
        [pscustomobject]@{ Kind = 'NetworkService'; Label = 'Network service URL' },
        [pscustomobject]@{ Kind = 'Output'; Label = 'Output directory' },
        [pscustomobject]@{ Kind = 'Run'; Label = 'RUN DIAGNOSTICS' },
        [pscustomobject]@{ Kind = 'Recording'; Label = 'Record performance' },
        [pscustomobject]@{ Kind = 'Incident'; Label = 'Investigate an incident' },
        [pscustomobject]@{ Kind = 'Exit'; Label = 'Exit' }
    )
    return $items
}

function Get-WdtTuiMenuIndex {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $items = @(Get-WdtTuiMenuItem -State $State)
    for ($index = 0; $index -lt $items.Count; $index++) {
        if ($items[$index].Kind -eq $Kind) { return $index }
    }
    return -1
}

function Update-WdtTuiState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][ValidateSet('MoveUp', 'MoveDown', 'ToggleCurrent', 'SelectCurrent', 'SelectAll', 'SelectRecommended', 'SetOutputDirectory', 'SetNetworkWebServiceUrl', 'Exit')][string]$Action,
        [string]$Value
    )

    $nextState = [pscustomobject]@{
        RegistrySnapshot = $State.RegistrySnapshot
        Diagnostics = @($State.Diagnostics | ForEach-Object {
                [pscustomobject]@{ Id = $_.Id; Label = $_.Label; Selected = [bool]$_.Selected }
            })
        PrivacyMode = [bool]$State.PrivacyMode
        ExportMarkdown = [bool]$State.ExportMarkdown
        OutputDirectory = [string]$State.OutputDirectory
        NetworkWebServiceUrl = [string]$State.NetworkWebServiceUrl
        NoExternalNetworkTests = [bool]$State.NoExternalNetworkTests
        Page = $State.Page
        CursorIndex = [int]$State.CursorIndex
        ErrorMessage = $State.ErrorMessage
        ExitRequested = [bool]$State.ExitRequested
        ActionRequested = $null
        ActionValue = $null
    }
    $items = @(Get-WdtTuiMenuItem -State $nextState)
    $currentItem = $items[$nextState.CursorIndex]

    if ($nextState.Page -ne 'Main') {
        if ($Action -eq 'Exit' -or ($Action -eq 'SelectCurrent' -and $currentItem.Kind -eq 'Back')) {
            $previousPage = $nextState.Page
            $nextState.Page = 'Main'
            $nextState.CursorIndex = Get-WdtTuiMenuIndex -State $nextState -Kind $previousPage
            return $nextState
        }
        if ($Action -eq 'SelectCurrent') {
            $nextState.ActionRequested = $currentItem.Kind
            $nextState.ActionValue = $currentItem.Value
            return $nextState
        }
        if ($Action -notin @('MoveUp', 'MoveDown')) { return $nextState }
    }

    if ($Action -eq 'MoveUp') {
        $nextState.CursorIndex = if ($nextState.CursorIndex -le 0) { $items.Count - 1 } else { $nextState.CursorIndex - 1 }
        return $nextState
    }
    if ($Action -eq 'MoveDown') {
        $nextState.CursorIndex = if ($nextState.CursorIndex -ge $items.Count - 1) { 0 } else { $nextState.CursorIndex + 1 }
        return $nextState
    }
    if ($Action -eq 'SelectAll') {
        foreach ($diagnostic in $nextState.Diagnostics) { $diagnostic.Selected = $true }
        return $nextState
    }
    if ($Action -eq 'SelectRecommended') {
        $recommended = @(Get-WdtRecommendedSelection -RegistrySnapshot $nextState.RegistrySnapshot)
        foreach ($diagnostic in $nextState.Diagnostics) { $diagnostic.Selected = $diagnostic.Id -in $recommended }
        return $nextState
    }
    if ($Action -eq 'SetOutputDirectory') {
        $nextState.OutputDirectory = $Value
        return $nextState
    }
    if ($Action -eq 'SetNetworkWebServiceUrl') {
        $nextState.NetworkWebServiceUrl = $Value
        return $nextState
    }
    if ($Action -eq 'Exit') {
        $nextState.ExitRequested = $true
        $nextState.ActionRequested = 'Exit'
        return $nextState
    }

    if ($Action -eq 'ToggleCurrent' -or $Action -eq 'SelectCurrent') {
        if ($currentItem.Kind -eq 'Diagnostic') {
            foreach ($diagnostic in $nextState.Diagnostics) {
                if ($diagnostic.Id -eq $currentItem.Id) {
                    $diagnostic.Selected = -not $diagnostic.Selected
                    break
                }
            }
        }
        elseif ($currentItem.Kind -eq 'Privacy') {
            $nextState.PrivacyMode = -not $nextState.PrivacyMode
        }
        elseif ($currentItem.Kind -eq 'Markdown') {
            $nextState.ExportMarkdown = -not $nextState.ExportMarkdown
        }
        elseif ($Action -eq 'SelectCurrent' -and $currentItem.Kind -in @('Recording', 'Incident')) {
            $nextState.Page = $currentItem.Kind
            $nextState.CursorIndex = 0
        }
        elseif ($Action -eq 'SelectCurrent') {
            $nextState.ActionRequested = $currentItem.Kind
            if ($currentItem.Kind -eq 'Exit') { $nextState.ExitRequested = $true }
        }
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

function Format-WdtTuiPath {
    param([string]$Path, [int]$Width)

    if ($Width -le 0) { return '' }
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -le $Width) { return $Path }
    if ($Width -lt 4) { return $Path.Substring($Path.Length - $Width) }
    return '...' + $Path.Substring($Path.Length - ($Width - 3))
}

function Get-WdtTuiLayoutMode {
    param([int]$Width, [int]$Height)

    if ($Width -ge 110 -and $Height -ge 28) { return 'Wide' }
    if ($Width -ge 110 -and $Height -ge 22) { return 'WideShort' }
    if ($Width -ge 60 -and $Height -ge 25) { return 'Normal' }
    if ($Width -ge 40 -and $Height -ge 18) { return 'Compact' }
    return 'TooSmall'
}

function New-WdtTuiSegment {
    param([string]$Text, [string]$Color = 'White')
    return [pscustomobject]@{ Text = $Text; Color = $Color }
}

function Expand-WdtTuiSegments {
    param([object[]]$Segments)

    foreach ($segment in @($Segments)) {
        if ($segment -is [System.Array]) {
            foreach ($nestedSegment in @($segment)) {
                if ($null -ne $nestedSegment) { $nestedSegment }
            }
        }
        elseif ($null -ne $segment) {
            $segment
        }
    }
}

function New-WdtTuiLine {
    param([object[]]$Segments)
    return [pscustomobject]@{ Segments = @(Expand-WdtTuiSegments -Segments $Segments) }
}

function New-WdtTuiTextLine {
    param([string]$Text, [string]$Color = 'White')
    return New-WdtTuiLine -Segments @((New-WdtTuiSegment -Text $Text -Color $Color))
}

function ConvertTo-WdtTuiPlainText {
    param([Parameter(Mandatory = $true)]$Line)
    return (@($Line.Segments | ForEach-Object { $_.Text }) -join '')
}

function Limit-WdtTuiSegments {
    param([object[]]$Segments, [int]$Width)

    $remaining = [Math]::Max(0, $Width)
    $limited = @()
    foreach ($segment in @(Expand-WdtTuiSegments -Segments $Segments)) {
        if ($remaining -le 0) { break }
        $text = Format-WdtTuiText -Text $segment.Text -Width $remaining
        if ($text.Length -gt 0) {
            $limited += New-WdtTuiSegment -Text $text -Color $segment.Color
            $remaining -= $text.Length
        }
    }
    return @($limited)
}

function Add-WdtTuiLinePadding {
    param([Parameter(Mandatory = $true)]$Line, [int]$Width)

    $segments = @(Limit-WdtTuiSegments -Segments $Line.Segments -Width $Width)
    $length = @($segments | ForEach-Object { $_.Text.Length } | Measure-Object -Sum).Sum
    if ($null -eq $length) { $length = 0 }
    if ($length -lt $Width) {
        $segments += New-WdtTuiSegment -Text (' ' * ($Width - $length)) -Color 'White'
    }
    return New-WdtTuiLine -Segments $segments
}

function New-WdtTuiBorderLine {
    param([int]$Width, [string]$Color = 'Cyan')

    if ($Width -le 0) { return New-WdtTuiTextLine -Text '' -Color $Color }
    if ($Width -eq 1) { return New-WdtTuiTextLine -Text '+' -Color $Color }
    return New-WdtTuiTextLine -Text ('+' + ('-' * [Math]::Max(0, $Width - 2)) + '+') -Color $Color
}

function New-WdtTuiFramedLine {
    param([Parameter(Mandatory = $true)]$Line, [int]$Width)

    $content = Add-WdtTuiLinePadding -Line $Line -Width ([Math]::Max(0, $Width - 2))
    return New-WdtTuiLine -Segments @(
        (New-WdtTuiSegment -Text '|' -Color 'Cyan'),
        $content.Segments,
        (New-WdtTuiSegment -Text '|' -Color 'Cyan')
    )
}

function New-WdtTuiAlignedLine {
    param(
        [string]$LeftText,
        [string]$RightText,
        [int]$Width,
        [string]$LeftColor = 'White',
        [string]$RightColor = 'White'
    )

    $left = Format-WdtTuiText -Text $LeftText -Width $Width
    $rightCapacity = [Math]::Max(0, $Width - $left.Length - 1)
    $right = Format-WdtTuiText -Text $RightText -Width $rightCapacity
    $spacing = [Math]::Max(0, $Width - $left.Length - $right.Length)
    return New-WdtTuiLine -Segments @(
        (New-WdtTuiSegment -Text $left -Color $LeftColor),
        (New-WdtTuiSegment -Text (' ' * $spacing) -Color 'White'),
        (New-WdtTuiSegment -Text $right -Color $RightColor)
    )
}

function Join-WdtTuiColumns {
    param(
        [Parameter(Mandatory = $true)]$LeftLine,
        [Parameter(Mandatory = $true)]$RightLine,
        [int]$LeftWidth,
        [int]$RightWidth
    )

    $left = Add-WdtTuiLinePadding -Line $LeftLine -Width $LeftWidth
    $right = Add-WdtTuiLinePadding -Line $RightLine -Width $RightWidth
    return New-WdtTuiLine -Segments @(
        (New-WdtTuiSegment -Text '|' -Color 'Cyan'),
        $left.Segments,
        (New-WdtTuiSegment -Text '|' -Color 'Cyan'),
        $right.Segments,
        (New-WdtTuiSegment -Text '|' -Color 'Cyan')
    )
}

function Test-WdtTuiUnicodeLogoSupport {
    param(
        [bool]$IsOutputRedirected,
        [string]$OutputEncodingWebName
    )

    if ($IsOutputRedirected) { return $false }
    return $OutputEncodingWebName -in @('utf-8', 'utf8')
}

function Get-WdtTuiLogoModeDecision {
    param(
        [bool]$IsOutputRedirected,
        [string]$OutputEncodingWebName,
        [string]$Override
    )

    if ($Override -ieq 'ascii') { return 'Ascii' }
    if ($Override -ieq 'unicode') { return $(if ($IsOutputRedirected) { 'Ascii' } else { 'Unicode' }) }
    if (Test-WdtTuiUnicodeLogoSupport -IsOutputRedirected $IsOutputRedirected -OutputEncodingWebName $OutputEncodingWebName) {
        return 'Unicode'
    }
    return 'Ascii'
}

function Get-WdtTuiLogoMode {
    try {
        $isOutputRedirected = [System.Console]::IsOutputRedirected
        $override = [string]$env:WDT_TUI_LOGO
        $encodingWebName = ''
        if ($override -ine 'unicode') {
            $encodingWebName = [System.Console]::OutputEncoding.WebName
        }
        return Get-WdtTuiLogoModeDecision -IsOutputRedirected $isOutputRedirected -OutputEncodingWebName $encodingWebName -Override $override
    }
    catch { }
    return 'Ascii'
}

function Get-WdtTuiLogo {
    param([ValidateSet('Ascii', 'Unicode')][string]$Mode = 'Ascii')

    if ($Mode -eq 'Unicode') {
        $block = [char]0x2588
        $vertical = [char]0x2551
        $topLeft = [char]0x2554
        $topRight = [char]0x2557
        $horizontal = [char]0x2550
        $bottomLeft = [char]0x255A
        $bottomRight = [char]0x255D
        $templates = @(
            'BB7    BB7 BBBBBB7 BBBBBBBB7',
            'BBI    BBI BBF==BB7L==BBF==J',
            'BBI B7 BBI BBI  BBI   BBI',
            'BBIBBB7BBI BBI  BBI   BBI',
            'LBBBFBBBFJ BBBBBBFJ   BBI',
            ' L==JL==J  L=====J    L=J'
        )
        return @($templates | ForEach-Object {
                $_.Replace([char]'B', $block).Replace([char]'I', $vertical).Replace([char]'F', $topLeft).Replace([char]'7', $topRight).Replace([char]'=', $horizontal).Replace([char]'L', $bottomLeft).Replace([char]'J', $bottomRight)
            })
    }

    return @(
        '::  ##      ##   ######    ########  ::',
        '::  ##      ##   ##   ##      ##     ::',
        '::  ##  ##  ##   ##    ##     ##     ::',
        '::  ## #### ##   ##    ##     ##     ::',
        '::   ###  ###    ##   ##      ##     ::',
        '::    ##  ##     ######       ##     ::'
    )
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
        $diagnostic = @($State.Diagnostics | Where-Object { $_.Id -eq $Item.Id })[0]
        $checked = [bool]$diagnostic.Selected
        $mark = if ($checked) { '[x]' } else { '[ ]' }
        $markColor = if ($checked) { 'Green' } else { 'DarkGray' }
        $labelColor = if ($active) { 'Yellow' } elseif ($checked) { 'White' } else { 'Gray' }
        $labelWidth = [Math]::Max(0, $Width - $numberPrefix.Length - $pointer.Length - $mark.Length - 1)
        $label = Format-WdtTuiText -Text $Item.Label -Width $labelWidth
        $segments = @(
            $numberSegment,
            (New-WdtTuiSegment -Text $pointer -Color $pointerColor),
            (New-WdtTuiSegment -Text $mark -Color $markColor),
            (New-WdtTuiSegment -Text (' ' + $label) -Color $labelColor)
        )
        return New-WdtTuiLine -Segments (Limit-WdtTuiSegments -Segments $segments -Width $Width)
    }

    if ($Item.Kind -in @('Privacy', 'Markdown')) {
        $enabled = if ($Item.Kind -eq 'Privacy') { [bool]$State.PrivacyMode } else { [bool]$State.ExportMarkdown }
        $mark = if ($enabled) { '[x]' } else { '[ ]' }
        $markColor = if ($enabled) { 'Green' } else { 'DarkGray' }
        $labelColor = if ($active) { 'Yellow' } elseif ($enabled) { 'White' } else { 'Gray' }
        $labelWidth = [Math]::Max(0, $Width - $numberPrefix.Length - $pointer.Length - $mark.Length - 1)
        $label = Format-WdtTuiText -Text $Item.Label -Width $labelWidth
        $segments = @(
            $numberSegment,
            (New-WdtTuiSegment -Text $pointer -Color $pointerColor),
            (New-WdtTuiSegment -Text $mark -Color $markColor),
            (New-WdtTuiSegment -Text (' ' + $label) -Color $labelColor)
        )
        return New-WdtTuiLine -Segments (Limit-WdtTuiSegments -Segments $segments -Width $Width)
    }

    if ($Item.Kind -in @('Output', 'NetworkService')) {
        if ($Item.Kind -eq 'Output') {
            $prefix = 'Output: '
            $pathWidth = [Math]::Max(0, $Width - $numberPrefix.Length - $pointer.Length - $prefix.Length)
            $value = Format-WdtTuiPath -Path $State.OutputDirectory -Width $pathWidth
        }
        else {
            $prefix = $Item.Label + ': '
            $value = if ($State.NoExternalNetworkTests) { 'Disabled' } elseif ($State.NetworkWebServiceUrl) { 'Set' } else { 'Off' }
        }
        $segments = @(
            $numberSegment,
            (New-WdtTuiSegment -Text $pointer -Color $pointerColor),
            (New-WdtTuiSegment -Text $prefix -Color $(if ($active) { 'Yellow' } else { 'White' })),
            (New-WdtTuiSegment -Text $value -Color 'DarkGray')
        )
        return New-WdtTuiLine -Segments (Limit-WdtTuiSegments -Segments $segments -Width $Width)
    }

    $shortcut = if ($Item.Kind -eq 'Run') { 'Enter' } elseif ($Item.Kind -in @('Exit', 'Back')) { 'Esc' } else { '' }
    $labelColor = if ($Item.Kind -eq 'Run') { 'Green' } elseif ($active) { 'Yellow' } else { 'Gray' }
    $prefixLength = $numberPrefix.Length + $pointer.Length
    $contentWidth = [Math]::Max(0, $Width - $prefixLength)
    $actionLine = New-WdtTuiAlignedLine -LeftText $Item.Label -RightText $shortcut -Width $contentWidth -LeftColor $labelColor -RightColor 'DarkGray'
    $segments = @($numberSegment, (New-WdtTuiSegment -Text $pointer -Color $pointerColor), $actionLine.Segments)
    return New-WdtTuiLine -Segments (Limit-WdtTuiSegments -Segments $segments -Width $Width)
}

function Get-WdtTuiViewport {
    param([int]$ItemCount, [int]$CursorIndex, [int]$Capacity)

    $visible = [Math]::Max(1, [Math]::Min($ItemCount, $Capacity))
    $start = [Math]::Max(0, [Math]::Min($CursorIndex - [Math]::Floor($visible / 2), $ItemCount - $visible))
    return [pscustomobject]@{ Start = $start; End = $start + $visible - 1; Capacity = $visible }
}

function Get-WdtTuiDiagnosticViewport {
    param(
        [int]$DiagnosticCount,
        [int]$CursorIndex,
        [int]$Rows,
        [int]$Columns = 1
    )

    $anchor = if ($CursorIndex -lt $DiagnosticCount) { $CursorIndex } else { $DiagnosticCount - 1 }
    return Get-WdtTuiViewport -ItemCount $DiagnosticCount -CursorIndex $anchor -Capacity ($Rows * $Columns)
}

function Join-WdtTuiDiagnosticColumns {
    param(
        [Parameter(Mandatory = $true)]$LeftLine,
        [Parameter(Mandatory = $true)]$RightLine,
        [int]$Width
    )

    $leftWidth = [Math]::Floor([Math]::Max(0, $Width - 1) / 2)
    $rightWidth = [Math]::Max(0, $Width - $leftWidth - 1)
    $left = Add-WdtTuiLinePadding -Line $LeftLine -Width $leftWidth
    $right = Add-WdtTuiLinePadding -Line $RightLine -Width $rightWidth
    return New-WdtTuiLine -Segments @(
        $left.Segments,
        (New-WdtTuiSegment -Text ' '),
        $right.Segments
    )
}

function Get-WdtTuiDiagnosticLines {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)]$Viewport,
        [int]$Rows,
        [int]$Columns,
        [int]$Width,
        [bool]$ShowItemNumbers
    )

    if ($Columns -eq 1) {
        return @($Viewport.Start..$Viewport.End | ForEach-Object {
                New-WdtTuiMenuLine -State $State -Item $Items[$_] -Index $_ -Width $Width -ShowItemNumbers $ShowItemNumbers
            })
    }

    $lines = @()
    for ($row = 0; $row -lt $Rows; $row++) {
        $leftIndex = $Viewport.Start + $row
        $rightIndex = $Viewport.Start + $Rows + $row
        $leftLine = if ($leftIndex -le $Viewport.End) {
            New-WdtTuiMenuLine -State $State -Item $Items[$leftIndex] -Index $leftIndex -Width ([Math]::Floor([Math]::Max(0, $Width - 1) / 2)) -ShowItemNumbers $ShowItemNumbers
        }
        else { New-WdtTuiTextLine -Text '' }
        $rightLine = if ($rightIndex -le $Viewport.End) {
            New-WdtTuiMenuLine -State $State -Item $Items[$rightIndex] -Index $rightIndex -Width ([Math]::Max(0, $Width - [Math]::Floor([Math]::Max(0, $Width - 1) / 2) - 1)) -ShowItemNumbers $ShowItemNumbers
        }
        else { New-WdtTuiTextLine -Text '' }
        $lines += Join-WdtTuiDiagnosticColumns -LeftLine $leftLine -RightLine $rightLine -Width $Width
    }
    return @($lines)
}

function Get-WdtTuiDiagnosticHeader {
    param([string]$Text, [int]$DiagnosticCount, [Parameter(Mandatory = $true)]$Viewport)

    if ($Viewport.Capacity -lt $DiagnosticCount) {
        return '{0} {1}-{2} of {3}' -f $Text, ($Viewport.Start + 1), ($Viewport.End + 1), $DiagnosticCount
    }
    return $Text
}

function Get-WdtTuiVisibleIndexes {
    param([int]$DiagnosticCount, [int]$ItemCount, [Parameter(Mandatory = $true)]$Viewport)

    return @(
        @($Viewport.Start..$Viewport.End)
        @($DiagnosticCount..($ItemCount - 1))
    )
}

function ConvertTo-WdtTuiFallbackAction {
    param([string]$Answer, [bool]$IsMain = $true)
    if (($IsMain -and $Answer -ieq 'Exit') -or (-not $IsMain -and $Answer -ieq 'Back')) { return 'Exit' }
    return $null
}

function ConvertTo-WdtTuiFallbackMenuAction {
    param([string]$Answer, [int[]]$VisibleIndexes, [int]$RunIndex)

    if ($Answer -ieq 'Up') { return [pscustomobject]@{ Action = 'Up'; Index = $null } }
    if ($Answer -ieq 'Down') { return [pscustomobject]@{ Action = 'Down'; Index = $null } }
    if ($RunIndex -ge 0) {
        if ($Answer -ieq 'A') { return [pscustomobject]@{ Action = 'All'; Index = $null } }
        if ($Answer -ieq 'R') { return [pscustomobject]@{ Action = 'Recommended'; Index = $null } }
        if ($Answer -ieq 'Run') { return [pscustomobject]@{ Action = 'Select'; Index = $RunIndex } }
    }
    if ((ConvertTo-WdtTuiFallbackAction -Answer $Answer -IsMain ($RunIndex -ge 0)) -eq 'Exit') {
        return [pscustomobject]@{ Action = 'Exit'; Index = $null }
    }
    if ($Answer -match '^\d+$') {
        try { $index = [int]$Answer - 1 }
        catch { return $null }
        if ($VisibleIndexes -contains $index) { return [pscustomobject]@{ Action = 'Select'; Index = $index } }
    }
    return $null
}

function Get-WdtTuiTooSmallLayout {
    param([int]$Width, [int]$Height, [int]$HostWidth = $Width, [bool]$IsMain = $true)

    $textLines = @(
        'WDT - terminal window is too small.',
        'Minimum size: 40x18.',
        ('Current: {0}x{1}.' -f $HostWidth, $Height),
        'Resize the window and press any key.',
        $(if ($IsMain) { 'Esc exits.' } else { 'Esc goes back.' })
    )
    $lines = $textLines | Select-Object -First ([Math]::Max(1, $Height)) | ForEach-Object {
        New-WdtTuiTextLine -Text (Format-WdtTuiText -Text $_ -Width $Width) -Color $(if ($_ -like 'WDT*') { 'Yellow' } else { 'DarkGray' })
    }
    return [pscustomobject]@{ Mode = 'TooSmall'; Lines = @($lines); Viewport = $null; VisibleIndexes = @() }
}

function Get-WdtTuiHelpText {
    param([string]$Mode)

    if ($Mode -in @('Wide', 'WideShort')) { return 'Up/Down Navigate | Space Toggle | Enter Select | A All | R Recommended | Esc Exit' }
    if ($Mode -eq 'Normal') { return 'Up/Down | Space Toggle | Enter Select | A All | R Recommended | Esc Exit' }
    return 'Up/Down | Space | Enter | A | R | Esc'
}

function Get-WdtTuiFooterText {
    return 'Safe. Local. Transparent. | No changes made to your system.'
}

function Get-WdtTuiWideLayout {
    param(
        [Parameter(Mandatory = $true)]$State,
        [int]$Width,
        [int]$Height,
        [bool]$Short,
        [ValidateSet('Ascii', 'Unicode')][string]$LogoMode = 'Ascii',
        [bool]$ShowItemNumbers
    )

    $items = @(Get-WdtTuiMenuItem -State $State)
    $selectedCount = @(Get-WdtTuiSelectedModule -State $State).Count
    $contentWidth = $Width - 3
    $leftWidth = [Math]::Floor($contentWidth * 0.56)
    $rightWidth = $contentWidth - $leftWidth
    $diagnosticRows = if ($Short) { $Height - 11 } else { $Height - 16 }
    $diagnosticRows -= [int]$ShowItemNumbers
    $diagnosticColumns = if ($State.Diagnostics.Count -le $diagnosticRows) { 1 } else { 2 }
    $diagnosticViewport = Get-WdtTuiDiagnosticViewport -DiagnosticCount $State.Diagnostics.Count -CursorIndex $State.CursorIndex -Rows $diagnosticRows -Columns $diagnosticColumns
    $lines = @((New-WdtTuiBorderLine -Width $Width))

    if ($Short) {
        $lines += New-WdtTuiFramedLine -Line (New-WdtTuiAlignedLine -LeftText ' WDT' -RightText 'Windows Diagnostics Toolkit ' -Width ($Width - 2) -LeftColor 'Cyan' -RightColor 'White') -Width $Width
        $lines += New-WdtTuiFramedLine -Line (New-WdtTuiTextLine -Text ' Read-only | Local reports | No telemetry' -Color 'DarkGray') -Width $Width
    }
    else {
        $logo = @(Get-WdtTuiLogo -Mode $LogoMode)
        $logoWidth = @($logo | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
        $headerLeftWidth = [Math]::Min($logoWidth + 2, [Math]::Max($logoWidth, $contentWidth - 42))
        $headerRightWidth = $contentWidth - $headerLeftWidth
        for ($index = 0; $index -lt $logo.Count; $index++) {
            $headerText = if ($index -eq 1) { 'Windows Diagnostics Toolkit' } elseif ($index -eq 2) { 'Read-only | Local reports | No telemetry' } else { '' }
            $leftLine = New-WdtTuiTextLine -Text ('  ' + $logo[$index]) -Color 'Cyan'
            $rightLine = New-WdtTuiTextLine -Text ('  ' + $headerText) -Color $(if ($index -eq 1) { 'White' } else { 'DarkGray' })
            $lines += Join-WdtTuiColumns -LeftLine $leftLine -RightLine $rightLine -LeftWidth $headerLeftWidth -RightWidth $headerRightWidth
        }
    }
    $lines += New-WdtTuiBorderLine -Width $Width

    $leftPanel = @()
    $diagnosticHeader = Get-WdtTuiDiagnosticHeader -Text ' DIAGNOSTICS' -DiagnosticCount $State.Diagnostics.Count -Viewport $diagnosticViewport
    $leftPanel += New-WdtTuiAlignedLine -LeftText $diagnosticHeader -RightText ('Selected: {0} / {1} ' -f $selectedCount, $State.Diagnostics.Count) -Width $leftWidth -LeftColor 'Cyan' -RightColor 'Cyan'
    $leftPanel += New-WdtTuiTextLine -Text (' ' + ('-' * [Math]::Max(0, $leftWidth - 2))) -Color 'DarkGray'
    $leftPanel += Get-WdtTuiDiagnosticLines -State $State -Items $items -Viewport $diagnosticViewport -Rows $diagnosticRows -Columns $diagnosticColumns -Width $leftWidth -ShowItemNumbers $ShowItemNumbers
    if (-not $Short) { $leftPanel += New-WdtTuiTextLine -Text '' }

    $rightPanel = @()
    $rightPanel += New-WdtTuiTextLine -Text ' OPTIONS / OUTPUT' -Color 'Cyan'
    $rightPanel += New-WdtTuiTextLine -Text (' ' + ('-' * [Math]::Max(0, $rightWidth - 2))) -Color 'DarkGray'
    for ($index = $State.Diagnostics.Count; $index -lt $items.Count; $index++) {
        if ($items[$index].Kind -eq 'Run') {
            $rightPanel += New-WdtTuiTextLine -Text (' ' + ('-' * [Math]::Max(0, $rightWidth - 2))) -Color 'DarkGray'
        }
        $rightPanel += New-WdtTuiMenuLine -State $State -Item $items[$index] -Index $index -Width ($rightWidth - 1) -ShowItemNumbers $ShowItemNumbers
    }

    $panelHeight = [Math]::Max($leftPanel.Count, $rightPanel.Count)
    while ($leftPanel.Count -lt $panelHeight) { $leftPanel += New-WdtTuiTextLine -Text '' }
    while ($rightPanel.Count -lt $panelHeight) { $rightPanel += New-WdtTuiTextLine -Text '' }
    for ($index = 0; $index -lt $panelHeight; $index++) {
        $lines += Join-WdtTuiColumns -LeftLine $leftPanel[$index] -RightLine $rightPanel[$index] -LeftWidth $leftWidth -RightWidth $rightWidth
    }
    $lines += New-WdtTuiBorderLine -Width $Width
    $helpMode = if ($Short) { 'WideShort' } else { 'Wide' }
    $help = Format-WdtTuiText -Text (Get-WdtTuiHelpText -Mode $helpMode) -Width ($Width - 2)
    $lines += New-WdtTuiFramedLine -Line (New-WdtTuiTextLine -Text (' ' + $help) -Color 'DarkGray') -Width $Width
    $lines += New-WdtTuiBorderLine -Width $Width
    $footerText = if ([string]::IsNullOrWhiteSpace($State.ErrorMessage)) { Get-WdtTuiFooterText } else { 'Error: ' + $State.ErrorMessage }
    $footerColor = if ([string]::IsNullOrWhiteSpace($State.ErrorMessage)) { 'Cyan' } else { 'Red' }
    $footer = Format-WdtTuiText -Text $footerText -Width ($Width - 2)
    $lines += New-WdtTuiFramedLine -Line (New-WdtTuiTextLine -Text (' ' + $footer) -Color $footerColor) -Width $Width
    $lines += New-WdtTuiBorderLine -Width $Width

    $mode = if ($Short) { 'WideShort' } else { 'Wide' }
    return [pscustomobject]@{
        Mode = $mode
        Lines = @($lines)
        Viewport = $diagnosticViewport
        VisibleIndexes = @(Get-WdtTuiVisibleIndexes -DiagnosticCount $State.Diagnostics.Count -ItemCount $items.Count -Viewport $diagnosticViewport)
    }
}

function Get-WdtTuiNormalLayout {
    param(
        [Parameter(Mandatory = $true)]$State,
        [int]$Width,
        [int]$Height,
        [bool]$ShowItemNumbers
    )

    $items = @(Get-WdtTuiMenuItem -State $State)
    $selectedCount = @(Get-WdtTuiSelectedModule -State $State).Count
    $controlCount = $items.Count - $State.Diagnostics.Count
    $diagnosticRows = $Height - 6 - $controlCount - [int]$ShowItemNumbers
    $diagnosticViewport = Get-WdtTuiDiagnosticViewport -DiagnosticCount $State.Diagnostics.Count -CursorIndex $State.CursorIndex -Rows $diagnosticRows
    $lines = @()
    $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'WDT - Windows Diagnostics Toolkit' -Width $Width) -Color 'Cyan'
    $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'Read-only | Local reports | No telemetry' -Width $Width) -Color 'DarkGray'
    $diagnosticHeader = Get-WdtTuiDiagnosticHeader -Text 'DIAGNOSTICS' -DiagnosticCount $State.Diagnostics.Count -Viewport $diagnosticViewport
    $lines += New-WdtTuiAlignedLine -LeftText $diagnosticHeader -RightText ('Selected: {0} / {1}' -f $selectedCount, $State.Diagnostics.Count) -Width $Width -LeftColor 'Cyan' -RightColor 'Cyan'
    $lines += Get-WdtTuiDiagnosticLines -State $State -Items $items -Viewport $diagnosticViewport -Rows $diagnosticRows -Columns 1 -Width $Width -ShowItemNumbers $ShowItemNumbers
    $lines += New-WdtTuiAlignedLine -LeftText 'OPTIONS' -RightText 'OUTPUT / ACTIONS' -Width $Width -LeftColor 'Cyan' -RightColor 'Cyan'
    for ($index = $State.Diagnostics.Count; $index -lt $items.Count; $index++) {
        $lines += New-WdtTuiMenuLine -State $State -Item $items[$index] -Index $index -Width $Width -ShowItemNumbers $ShowItemNumbers
    }
    $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text (Get-WdtTuiHelpText -Mode 'Normal') -Width $Width) -Color 'DarkGray'
    $footerText = if ([string]::IsNullOrWhiteSpace($State.ErrorMessage)) { Get-WdtTuiFooterText } else { 'Error: ' + $State.ErrorMessage }
    $footerColor = if ([string]::IsNullOrWhiteSpace($State.ErrorMessage)) { 'Cyan' } else { 'Red' }
    $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text $footerText -Width $Width) -Color $footerColor

    return [pscustomobject]@{
        Mode = 'Normal'
        Lines = @($lines)
        Viewport = $diagnosticViewport
        VisibleIndexes = @(Get-WdtTuiVisibleIndexes -DiagnosticCount $State.Diagnostics.Count -ItemCount $items.Count -Viewport $diagnosticViewport)
    }
}

function Get-WdtTuiCompactLayout {
    param(
        [Parameter(Mandatory = $true)]$State,
        [int]$Width,
        [int]$Height,
        [bool]$ShowItemNumbers
    )

    $items = @(Get-WdtTuiMenuItem -State $State)
    $selectedCount = @(Get-WdtTuiSelectedModule -State $State).Count
    $lines = @()
    $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'WDT - Windows Diagnostics Toolkit' -Width $Width) -Color 'Cyan'
    $status = 'Selected: {0} | Privacy: {1} | Markdown: {2}' -f $selectedCount, $(if ($State.PrivacyMode) { 'On' } else { 'Off' }), $(if ($State.ExportMarkdown) { 'On' } else { 'Off' })
    $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text $status -Width $Width) -Color 'DarkGray'

    $fixedRows = 5 + [int]$ShowItemNumbers
    $errorRows = if ([string]::IsNullOrWhiteSpace($State.ErrorMessage)) { 0 } else { 1 }
    $menuCapacity = [Math]::Max(1, $Height - $fixedRows - $errorRows)
    $viewport = Get-WdtTuiViewport -ItemCount $items.Count -CursorIndex $State.CursorIndex -Capacity $menuCapacity
    $range = 'Items {0}-{1} of {2}' -f ($viewport.Start + 1), ($viewport.End + 1), $items.Count
    $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text $range -Width $Width) -Color 'Cyan'
    for ($index = $viewport.Start; $index -le $viewport.End; $index++) {
        $lines += New-WdtTuiMenuLine -State $State -Item $items[$index] -Index $index -Width $Width -ShowItemNumbers $ShowItemNumbers
    }
    if (-not [string]::IsNullOrWhiteSpace($State.ErrorMessage)) {
        $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text ('Error: ' + $State.ErrorMessage) -Width $Width) -Color 'Red'
    }
    $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text (Get-WdtTuiHelpText -Mode 'Compact') -Width $Width) -Color 'DarkGray'
    $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'Safe. Local. No system changes.' -Width $Width) -Color 'Cyan'

    return [pscustomobject]@{
        Mode = 'Compact'
        Lines = @($lines)
        Viewport = $viewport
        VisibleIndexes = @($viewport.Start..$viewport.End)
    }
}

function Get-WdtTuiSubmenuLayout {
    param(
        [Parameter(Mandatory = $true)]$State,
        [int]$Width,
        [bool]$ShowItemNumbers
    )

    if ($State.Page -eq 'Recording') {
        $title = 'Record performance'
        $help = 'Reproduce the issue during recording.'
        $prompt = 'Choose a recording duration.'
    }
    else {
        $title = 'Investigate an incident'
        $help = 'Search within 30 minutes of the issue.'
        $prompt = 'Choose what happened.'
    }

    $lines = @(
        (New-WdtTuiTextLine -Text $title -Color 'Cyan'),
        (New-WdtTuiTextLine -Text $help -Color 'DarkGray'),
        (New-WdtTuiTextLine -Text $prompt -Color 'White'),
        (New-WdtTuiTextLine -Text '')
    )
    $items = @(Get-WdtTuiMenuItem -State $State)
    for ($index = 0; $index -lt $items.Count; $index++) {
        $lines += New-WdtTuiMenuLine -State $State -Item $items[$index] -Index $index -Width $Width -ShowItemNumbers $ShowItemNumbers
    }
    if (-not [string]::IsNullOrWhiteSpace($State.ErrorMessage)) {
        $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text ('Error: ' + $State.ErrorMessage) -Width $Width) -Color 'Red'
    }
    $controls = if ($ShowItemNumbers) { 'Item number | Back' } else { 'Up/Down | Enter Select | Esc Back' }
    $lines += New-WdtTuiTextLine -Text $controls -Color 'DarkGray'
    return [pscustomobject]@{
        Mode = $State.Page
        Lines = @($lines)
        Viewport = $null
        VisibleIndexes = @(0..($items.Count - 1))
    }
}

function Get-WdtTuiLayout {
    param(
        [Parameter(Mandatory = $true)]$State,
        [int]$Width = 80,
        [int]$Height = 25,
        [ValidateSet('Ascii', 'Unicode')][string]$LogoMode = 'Ascii',
        [bool]$ShowItemNumbers
    )

    $hostWidth = $Width
    $hostHeight = $Height
    $renderWidth = Get-WdtTuiRenderWidth -WindowWidth $hostWidth
    $mode = Get-WdtTuiLayoutMode -Width $hostWidth -Height $hostHeight
    if ($mode -eq 'TooSmall') { return Get-WdtTuiTooSmallLayout -Width $renderWidth -Height $hostHeight -HostWidth $hostWidth -IsMain ($State.Page -eq 'Main') }
    if ($State.Page -ne 'Main') { return Get-WdtTuiSubmenuLayout -State $State -Width $renderWidth -ShowItemNumbers $ShowItemNumbers }
    if ($mode -eq 'Wide') { return Get-WdtTuiWideLayout -State $State -Width $renderWidth -Height $hostHeight -Short $false -LogoMode $LogoMode -ShowItemNumbers $ShowItemNumbers }
    if ($mode -eq 'WideShort') { return Get-WdtTuiWideLayout -State $State -Width $renderWidth -Height $hostHeight -Short $true -LogoMode 'Ascii' -ShowItemNumbers $ShowItemNumbers }
    if ($mode -eq 'Normal') {
        $normalWidth = [Math]::Min($renderWidth, 96)
        return Get-WdtTuiNormalLayout -State $State -Width $normalWidth -Height $hostHeight -ShowItemNumbers $ShowItemNumbers
    }
    return Get-WdtTuiCompactLayout -State $State -Width $renderWidth -Height $hostHeight -ShowItemNumbers $ShowItemNumbers
}

function Get-WdtTuiLines {
    param([Parameter(Mandatory = $true)]$State, [int]$Width = 80, [int]$Height = 25)
    return @((Get-WdtTuiLayout -State $State -Width $Width -Height $Height).Lines | ForEach-Object { ConvertTo-WdtTuiPlainText $_ })
}

function Get-WdtTuiRunningLayout {
    param([int]$SelectedCount, [int]$Width = 80, [string]$RunKind = 'Run', [int]$DurationSeconds)

    $status = switch ($RunKind) {
        'StartRecording' { 'Recording performance...' }
        'IncidentSymptom' { 'Investigating the incident...' }
        default { 'Running diagnostics...' }
    }

    $lines = @(
        (New-WdtTuiBorderLine -Width $Width),
        (New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'Windows Diagnostics Toolkit' -Width $Width) -Color 'Cyan'),
        (New-WdtTuiTextLine -Text (Format-WdtTuiText -Text $status -Width $Width) -Color 'Yellow')
    )
    if ($RunKind -eq 'StartRecording') {
        $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text ('Duration: {0} seconds' -f $DurationSeconds) -Width $Width) -Color 'White'
        $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'Press M when the issue occurs.' -Width $Width) -Color 'White'
        $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'Recording ends automatically.' -Width $Width) -Color 'DarkGray'
    }
    elseif ($RunKind -eq 'IncidentSymptom') {
        $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'Checking logs near the selected time.' -Width $Width) -Color 'White'
    }
    else {
        $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text ('Selected modules: {0}' -f $SelectedCount) -Width $Width) -Color 'White'
        $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'Diagnostics are running. This may take a moment.' -Width $Width) -Color 'DarkGray'
    }
    $lines += @(
        (New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'Reports remain local. No system changes are made.' -Width $Width) -Color 'DarkGray'),
        (New-WdtTuiBorderLine -Width $Width)
    )
    return [pscustomobject]@{ Mode = 'Running'; Lines = $lines }
}

function Get-WdtTuiRunName {
    param([string]$RunKind)

    switch ($RunKind) {
        'StartRecording' { return 'Performance recording' }
        'IncidentSymptom' { return 'Incident investigation' }
        default { return 'Diagnostics' }
    }
}

function Get-WdtTuiRunResultLayout {
    param([Parameter(Mandatory = $true)]$Result, [int]$Width = 80, [string]$RunKind = 'Run')

    $name = Get-WdtTuiRunName -RunKind $RunKind
    $isSuccess = $Result.ExitCode -eq 0 -and $Result.Completeness -eq 'Complete'
    $status = if ($isSuccess) { "$name completed successfully." }
    elseif ($Result.ExitCode -eq 0) { "$name completed with incomplete output." }
    elseif ($Result.Completeness -eq 'Unavailable') { "$name unavailable." }
    else { "$name completed with partial failures." }
    $statusColor = if ($isSuccess) { 'Green' } else { 'Yellow' }
    $lines = @(
        (New-WdtTuiBorderLine -Width $Width),
        (New-WdtTuiTextLine -Text (Format-WdtTuiText -Text $status -Width $Width) -Color $statusColor),
        (New-WdtTuiTextLine -Text (Format-WdtTuiText -Text ('TXT: {0}' -f $Result.DisplayTextReportPath) -Width $Width) -Color 'DarkGray')
    )
    if (-not [string]::IsNullOrWhiteSpace($Result.DisplayMarkdownReportPath)) {
        $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text ('Markdown: {0}' -f $Result.DisplayMarkdownReportPath) -Width $Width) -Color 'DarkGray'
    }
    if ($null -ne $Result.PSObject.Properties['WarningCount'] -and $null -ne $Result.PSObject.Properties['ErrorCount']) {
        $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text ('WARN: {0} | ERROR: {1}' -f $Result.WarningCount, $Result.ErrorCount) -Width $Width) -Color $(if ($Result.ErrorCount -gt 0) { 'Red' } elseif ($Result.WarningCount -gt 0) { 'Yellow' } else { 'Green' })
    }
    $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text ('Elapsed: {0}' -f $Result.ElapsedTime) -Width $Width) -Color 'DarkGray'
    $lines += New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'Enter returns to menu | Esc exits' -Width $Width) -Color 'DarkGray'
    $lines += New-WdtTuiBorderLine -Width $Width
    return [pscustomobject]@{ Mode = $(if ($isSuccess) { 'Success' } else { 'Warning' }); Lines = @($lines) }
}

function Get-WdtTuiErrorLayout {
    param([string]$Message, [int]$Width = 80, [string]$RunKind = 'Run')

    $name = Get-WdtTuiRunName -RunKind $RunKind
    return [pscustomobject]@{
        Mode = 'Error'
        Lines = @(
            (New-WdtTuiBorderLine -Width $Width),
            (New-WdtTuiTextLine -Text (Format-WdtTuiText -Text "$name failed." -Width $Width) -Color 'Red'),
            (New-WdtTuiTextLine -Text (Format-WdtTuiText -Text $Message -Width $Width) -Color 'Red'),
            (New-WdtTuiTextLine -Text (Format-WdtTuiText -Text 'Enter returns to menu | Esc exits' -Width $Width) -Color 'DarkGray'),
            (New-WdtTuiBorderLine -Width $Width)
        )
    }
}

function Test-WdtTuiColorOutput {
    try { return -not [System.Console]::IsOutputRedirected -and $null -ne $Host.UI }
    catch { return $false }
}

function Get-WdtTuiRenderWidth {
    param([int]$WindowWidth)
    return [Math]::Max(1, $WindowWidth - 1)
}

function ConvertTo-WdtTuiFrame {
    param([Parameter(Mandatory = $true)]$Layout, [int]$WindowWidth)

    $renderWidth = Get-WdtTuiRenderWidth -WindowWidth $WindowWidth
    return @($Layout.Lines | ForEach-Object {
            ConvertTo-WdtTuiPlainText -Line (Add-WdtTuiLinePadding -Line $_ -Width $renderWidth)
        })
}

function Get-WdtTuiFrameOperations {
    param([string[]]$PreviousFrame, [string[]]$CurrentFrame, [int]$RenderWidth)

    $previous = @($PreviousFrame)
    $current = @($CurrentFrame)
    $rowCount = [Math]::Max($previous.Count, $current.Count)
    $operations = @()
    for ($row = 0; $row -lt $rowCount; $row++) {
        $oldText = if ($row -lt $previous.Count) { [string]$previous[$row] } else { '' }
        $newText = if ($row -lt $current.Count) { [string]$current[$row] } else { ' ' * $RenderWidth }
        if ($oldText -cne $newText) {
            $operations += [pscustomobject]@{
                Row = $row
                Text = $newText
                ClearsRemovedRow = $row -ge $current.Count
            }
        }
    }
    return @($operations)
}

function Get-WdtTuiRenderStrategy {
    param([bool]$IsOutputRedirected, [bool]$CursorPositioningAvailable)

    if ($IsOutputRedirected -or -not $CursorPositioningAvailable) { return 'Full' }
    return 'Diff'
}

function Write-WdtTuiLine {
    param([Parameter(Mandatory = $true)]$Line, [bool]$UseColor, [int]$Width, [bool]$NoNewline)

    $renderLine = Add-WdtTuiLinePadding -Line $Line -Width $Width
    $plainText = ConvertTo-WdtTuiPlainText -Line $renderLine
    if (-not $UseColor) {
        Write-Host $plainText -NoNewline:$NoNewline
        return
    }
    try {
        foreach ($segment in @($renderLine.Segments)) {
            Write-Host $segment.Text -NoNewline -ForegroundColor $segment.Color
        }
        if (-not $NoNewline) { Write-Host }
    }
    catch {
        Write-Host $plainText -NoNewline:$NoNewline
    }
}

function Write-WdtTuiDiffRow {
    param([Parameter(Mandatory = $true)]$Line, [bool]$UseColor, [int]$Width)

    $renderLine = Add-WdtTuiLinePadding -Line $Line -Width $Width
    $plainText = ConvertTo-WdtTuiPlainText -Line $renderLine
    if (-not $UseColor) {
        Write-Host $plainText -NoNewline
        return
    }
    try {
        foreach ($segment in @($renderLine.Segments)) {
            Write-Host $segment.Text -NoNewline -ForegroundColor $segment.Color
        }
    }
    catch {
        Write-Host $plainText -NoNewline
    }
}

function Write-WdtTuiFullFrame {
    param([Parameter(Mandatory = $true)]$Layout, [bool]$UseColor, [int]$Width)

    $lines = @($Layout.Lines)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $isLastLine = $index -eq $lines.Count - 1
        Write-WdtTuiLine -Line $lines[$index] -UseColor $UseColor -Width $Width -NoNewline $isLastLine
    }
}

function Reset-WdtTuiFrame {
    $script:WdtTuiPreviousFrame = @()
}

function Get-WdtTuiExitAnchorRow {
    param([int]$FrameHeight, [int]$BufferHeight)

    $lastFrameRow = [Math]::Max(0, $FrameHeight - 1)
    $lastBufferRow = [Math]::Max(0, $BufferHeight - 1)
    return [Math]::Min($lastFrameRow, $lastBufferRow)
}

function Complete-WdtTuiConsoleFrame {
    $frameHeight = @($script:WdtTuiPreviousFrame).Count
    $wroteNewline = $false
    try {
        if ($frameHeight -gt 0 -and -not [System.Console]::IsOutputRedirected) {
            $anchorRow = Get-WdtTuiExitAnchorRow -FrameHeight $frameHeight -BufferHeight ([System.Console]::BufferHeight)
            [System.Console]::SetCursorPosition(0, $anchorRow)
        }
        Write-Host ''
        $wroteNewline = $true
    }
    catch {
        if (-not $wroteNewline) {
            try { Write-Host '' } catch { }
        }
    }
    finally {
        Reset-WdtTuiFrame
    }
}

function Show-WdtTuiFrame {
    param([Parameter(Mandatory = $true)]$Layout, [int]$Width, [bool]$ForceFull)

    $renderWidth = Get-WdtTuiRenderWidth -WindowWidth $Width
    $currentFrame = @(ConvertTo-WdtTuiFrame -Layout $Layout -WindowWidth $Width)
    $previousFrame = if ($null -eq $script:WdtTuiPreviousFrame) { @() } else { @($script:WdtTuiPreviousFrame) }
    $operations = @(Get-WdtTuiFrameOperations -PreviousFrame $previousFrame -CurrentFrame $currentFrame -RenderWidth $renderWidth)
    $useColor = Test-WdtTuiColorOutput
    $outputRedirected = $false
    try { $outputRedirected = [System.Console]::IsOutputRedirected } catch { $outputRedirected = $true }
    $cursorPositioningAvailable = -not $outputRedirected
    $strategy = if ($ForceFull) { 'Full' } else { Get-WdtTuiRenderStrategy -IsOutputRedirected $outputRedirected -CursorPositioningAvailable $cursorPositioningAvailable }

    if ($outputRedirected) {
        Write-WdtTuiFullFrame -Layout $Layout -UseColor $false -Width $renderWidth
        $script:WdtTuiPreviousFrame = @($currentFrame)
        return
    }

    if ($strategy -eq 'Diff') {
        try {
            foreach ($operation in $operations) {
                $column = 0
                $row = [int]$operation.Row
                [System.Console]::SetCursorPosition($column, $row)
                $line = if ($row -lt @($Layout.Lines).Count) { $Layout.Lines[$row] } else { New-WdtTuiTextLine -Text '' }
                Write-WdtTuiDiffRow -Line $line -UseColor $useColor -Width $renderWidth
            }
            $script:WdtTuiPreviousFrame = @($currentFrame)
            return
        }
        catch {
            $strategy = 'Full'
        }
    }

    if ($strategy -eq 'Full') {
        try { Clear-Host } catch { }
        Write-WdtTuiFullFrame -Layout $Layout -UseColor $useColor -Width $renderWidth
        $script:WdtTuiPreviousFrame = @($currentFrame)
    }
}

function Get-WdtTuiHostSize {
    $width = 80
    $height = 25
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        $height = $Host.UI.RawUI.WindowSize.Height
    }
    catch { }
    return [pscustomobject]@{ Width = $width; Height = $height }
}

function Get-WdtTuiEventDecision {
    param(
        [bool]$KeyAvailable,
        [int]$InitialWidth,
        [int]$InitialHeight,
        [int]$CurrentWidth,
        [int]$CurrentHeight
    )

    if ($KeyAvailable) { return 'Key' }
    if ($CurrentWidth -ne $InitialWidth -or $CurrentHeight -ne $InitialHeight) { return 'Resize' }
    return 'Wait'
}

function Wait-WdtTuiEvent {
    param(
        [int]$InitialWidth,
        [int]$InitialHeight,
        [int]$PollMilliseconds = 75
    )

    while ($true) {
        try {
            $keyAvailable = [System.Console]::KeyAvailable
        }
        catch {
            $keyInfo = [System.Console]::ReadKey($true)
            return [pscustomobject]@{
                Type = 'Key'
                KeyInfo = $keyInfo
                Size = Get-WdtTuiHostSize
                UsedBlockingFallback = $true
            }
        }

        $currentSize = Get-WdtTuiHostSize
        $decision = Get-WdtTuiEventDecision -KeyAvailable $keyAvailable -InitialWidth $InitialWidth -InitialHeight $InitialHeight -CurrentWidth $currentSize.Width -CurrentHeight $currentSize.Height
        if ($decision -eq 'Key') {
            $keyInfo = [System.Console]::ReadKey($true)
            return [pscustomobject]@{
                Type = 'Key'
                KeyInfo = $keyInfo
                Size = $currentSize
                UsedBlockingFallback = $false
            }
        }
        if ($decision -eq 'Resize') {
            $candidateSize = $currentSize
            $stablePolls = 0
            while ($stablePolls -lt 2) {
                Start-Sleep -Milliseconds $PollMilliseconds
                $nextSize = Get-WdtTuiHostSize
                if ($nextSize.Width -eq $candidateSize.Width -and $nextSize.Height -eq $candidateSize.Height) {
                    $stablePolls++
                }
                else {
                    $candidateSize = $nextSize
                    $stablePolls = 0
                }
            }
            if ($candidateSize.Width -ne $InitialWidth -or $candidateSize.Height -ne $InitialHeight) {
                return [pscustomobject]@{
                    Type = 'Resize'
                    KeyInfo = $null
                    Size = $candidateSize
                    UsedBlockingFallback = $false
                }
            }
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
}

function Show-WdtTuiScreen {
    param(
        [Parameter(Mandatory = $true)]$State,
        [int]$Width,
        [int]$Height,
        [bool]$ShowItemNumbers,
        [bool]$ForceFull
    )

    $logoMode = Get-WdtTuiLogoMode
    $layout = Get-WdtTuiLayout -State $State -Width $Width -Height $Height -LogoMode $logoMode -ShowItemNumbers $ShowItemNumbers
    Show-WdtTuiFrame -Layout $layout -Width $Width -ForceFull $ForceFull
    return $layout
}

function Show-WdtTuiRunResult {
    param([Parameter(Mandatory = $true)]$Result, [int]$Width, [string]$RunKind = 'Run')

    $renderWidth = Get-WdtTuiRenderWidth -WindowWidth $Width
    $layout = Get-WdtTuiRunResultLayout -Result $Result -Width $renderWidth -RunKind $RunKind
    Reset-WdtTuiFrame
    Show-WdtTuiFrame -Layout $layout -Width $Width -ForceFull $true
}

function Read-WdtTuiField {
    param([string]$Title, [string[]]$Instructions, [string]$Prompt, [bool]$ManageCursor)

    $size = Get-WdtTuiHostSize
    $layout = [pscustomobject]@{
        Lines = @(
            (New-WdtTuiTextLine -Text $Title -Color 'Cyan')
            foreach ($line in $Instructions) { New-WdtTuiTextLine -Text $line -Color 'DarkGray' }
        )
    }
    Show-WdtTuiFrame -Layout $layout -Width $size.Width -ForceFull $true
    Write-Host ''
    try {
        if ($ManageCursor) {
            try { [System.Console]::CursorVisible = $true } catch { }
        }
        return Read-Host $Prompt
    }
    finally {
        if ($ManageCursor) {
            try { [System.Console]::CursorVisible = $false } catch { }
        }
    }
}

function ConvertTo-WdtTuiIncidentTimestamp {
    param([string]$Text, [System.TimeZoneInfo]$TimeZone = [System.TimeZoneInfo]::Local)

    if ($Text -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$') {
        return $Text
    }

    $localTime = [datetime]::MinValue
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $format = [string[]]@('yyyy-MM-dd H:mm', 'yyyy-MM-dd H:mm:ss')
    if (-not [datetime]::TryParseExact($Text, $format, $culture, [System.Globalization.DateTimeStyles]::None, [ref]$localTime)) {
        throw 'Use YYYY-MM-DD HH:mm.'
    }
    if ($TimeZone.IsInvalidTime($localTime)) { throw 'This local time does not exist.' }
    if ($TimeZone.IsAmbiguousTime($localTime)) { throw 'Repeated hour. Use an offset.' }

    $offsetTime = [datetimeoffset]::new($localTime, $TimeZone.GetUtcOffset($localTime))
    return $offsetTime.ToString("yyyy-MM-dd'T'HH:mm:sszzz", $culture)
}

function Invoke-WdtInteractiveSession {
    param(
        [Parameter(Mandatory = $true)]$RegistrySnapshot,
        [string[]]$InitialSelection,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [int]$ModuleTimeoutSeconds = 180,
        [bool]$NoExternalNetworkTests = $false,
        [string]$NetworkDnsTestName = 'www.microsoft.com',
        [string]$NetworkHttpsEndpoint = 'https://www.microsoft.com/',
        [string]$NetworkIcmpTarget = '1.1.1.1',
        [string]$NetworkWebServiceUrl
    )

    if ([System.Console]::IsInputRedirected) {
        Write-Host 'Interactive input is unavailable.'
        Write-Host 'Use -All or select one or more diagnostic modules.'
        return 2
    }

    $state = New-WdtTuiState -RegistrySnapshot $RegistrySnapshot -OutputDirectory $OutputDirectory -InitialSelection $InitialSelection -NetworkWebServiceUrl $NetworkWebServiceUrl -NoExternalNetworkTests $NoExternalNetworkTests
    $useReadKey = $true
    $lastExitCode = 0
    $originalCursorVisible = $null
    $isFirstMenuFrame = $true
    try {
        Reset-WdtTuiFrame
        try {
            $originalCursorVisible = [System.Console]::CursorVisible
            [System.Console]::CursorVisible = $false
        }
        catch { }

        while (-not $state.ExitRequested) {
            $size = Get-WdtTuiHostSize
            $layout = Show-WdtTuiScreen -State $state -Width $size.Width -Height $size.Height -ShowItemNumbers (-not $useReadKey) -ForceFull ($isFirstMenuFrame -or -not $useReadKey)
            $isFirstMenuFrame = $false
            $action = $null

            if ($useReadKey) {
                try {
                    $inputEvent = Wait-WdtTuiEvent -InitialWidth $size.Width -InitialHeight $size.Height
                    if ($inputEvent.Type -eq 'Resize') {
                        Reset-WdtTuiFrame
                        $null = Show-WdtTuiScreen -State $state -Width $inputEvent.Size.Width -Height $inputEvent.Size.Height -ShowItemNumbers $false -ForceFull $true
                        continue
                    }
                    $keyInfo = $inputEvent.KeyInfo
                    if ($layout.Mode -eq 'TooSmall') {
                        if ($keyInfo.Key -eq [System.ConsoleKey]::Escape) {
                            $state = Update-WdtTuiState -State $state -Action Exit
                        }
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
                Write-Host ''
                if ($layout.Mode -eq 'TooSmall') {
                    $isMain = $state.Page -eq 'Main'
                    $leaveCommand = if ($isMain) { 'Exit' } else { 'Back' }
                    $answer = Read-Host ('Resize and press Enter, or type ' + $leaveCommand)
                    if ((ConvertTo-WdtTuiFallbackAction -Answer $answer -IsMain $isMain) -eq 'Exit') {
                        $state = Update-WdtTuiState -State $state -Action Exit
                    }
                    continue
                }

                $runIndex = Get-WdtTuiMenuIndex -State $state -Kind 'Run'
                $prompt = if ($runIndex -ge 0) { 'Item number, Up, Down, A, R, Run, Exit' } else { 'Item number or Back' }
                $answer = Read-Host $prompt
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

            $transition = if ($action -eq 'Toggle') { 'ToggleCurrent' } else { 'SelectCurrent' }
            $state = Update-WdtTuiState -State $state -Action $transition
            if ($state.ActionRequested -eq 'Output') {
                $path = Read-Host 'Output directory'
                if ([string]::IsNullOrWhiteSpace($path)) {
                    $state.ErrorMessage = 'Output directory cannot be empty.'
                    continue
                }
                try {
                    $resolvedPath = Resolve-WdtFilesystemPath -Path $path
                    $state = Update-WdtTuiState -State $state -Action SetOutputDirectory -Value $resolvedPath
                }
                catch {
                    $state.ErrorMessage = $_.Exception.Message
                }
                continue
            }
            if ($state.ActionRequested -eq 'NetworkService') {
                if ($NoExternalNetworkTests) {
                    $state.ErrorMessage = 'External tests are disabled.'
                    continue
                }
                $url = [string](Read-WdtTuiField -Title 'Network service URL' -Instructions @(
                        'Used when Network is selected.',
                        'Enter an HTTP or HTTPS URL.',
                        'Omit credentials and # fragments.',
                        'Blank clears the URL. Back cancels.'
                    ) -Prompt 'URL' -ManageCursor ($null -ne $originalCursorVisible))
                $isFirstMenuFrame = $true
                $url = $url.Trim()
                if ($url -ieq 'Back') { continue }
                if ($url -and $null -eq (ConvertTo-WdtWebServiceUri -Value $url)) {
                    $state.ErrorMessage = 'Enter an HTTP or HTTPS URL.'
                    continue
                }
                $state = Update-WdtTuiState -State $state -Action SetNetworkWebServiceUrl -Value $url
                continue
            }
            $runKind = $state.ActionRequested
            if ($state.ExitRequested -or $runKind -notin @('Run', 'StartRecording', 'IncidentSymptom')) { continue }

            $selectedCount = 0
            $durationSeconds = 0
            if ($runKind -eq 'Run') {
                $reportParameters = ConvertTo-WdtReportParameters `
                    -State $state `
                    -RegistrySnapshot $RegistrySnapshot `
                    -ModuleTimeoutSeconds $ModuleTimeoutSeconds `
                    -NoExternalNetworkTests $NoExternalNetworkTests `
                    -NetworkDnsTestName $NetworkDnsTestName `
                    -NetworkHttpsEndpoint $NetworkHttpsEndpoint `
                    -NetworkIcmpTarget $NetworkIcmpTarget
                $selectedCount = @($reportParameters.ModuleDefinitions).Count
                if ($selectedCount -eq 0) {
                    $state.ErrorMessage = 'Select at least one diagnostic module.'
                    continue
                }
            }
            else {
                $reportParameters = @{
                    OutputDirectory = $state.OutputDirectory
                    PrivacyMode = $state.PrivacyMode
                    ExportMarkdown = $state.ExportMarkdown
                    SuppressConsoleOutput = $true
                }
                if ($runKind -eq 'StartRecording') {
                    $durationSeconds = [int]$state.ActionValue
                    $reportParameters.DurationSeconds = $durationSeconds
                    $reportParameters.InteractiveMarker = $true
                }
                else {
                    $at = [string](Read-WdtTuiField -Title 'Approximate incident time' -Instructions @(
                            'Local time: YYYY-MM-DD HH:mm',
                            'Example: 2026-11-02 14:30',
                            'For DST gaps or repeats, add offset:',
                            '2026-11-02T14:30:00+02:00',
                            'Blank or Back cancels.'
                        ) -Prompt 'Date and time' -ManageCursor ($null -ne $originalCursorVisible))
                    $isFirstMenuFrame = $true
                    $at = $at.Trim()
                    if (-not $at -or $at -ieq 'Back') { continue }
                    try {
                        $timestamp = ConvertTo-WdtTuiIncidentTimestamp -Text $at
                        $reportParameters.Window = Resolve-WdtIncidentWindow -Symptom $state.ActionValue -At $timestamp
                        $reportParameters.ModuleTimeoutSeconds = $ModuleTimeoutSeconds
                    }
                    catch {
                        $state.ErrorMessage = $_.Exception.Message
                        continue
                    }
                }
            }

            $size = Get-WdtTuiHostSize
            $renderWidth = Get-WdtTuiRenderWidth -WindowWidth $size.Width
            $runningLayout = Get-WdtTuiRunningLayout -SelectedCount $selectedCount -Width $renderWidth -RunKind $runKind -DurationSeconds $durationSeconds
            Show-WdtTuiFrame -Layout $runningLayout -Width $size.Width -ForceFull $isFirstMenuFrame
            try {
                $result = switch ($runKind) {
                    'StartRecording' { Invoke-WdtRecordingReport @reportParameters }
                    'IncidentSymptom' { Invoke-WdtIncident @reportParameters }
                    default { Invoke-WdtReport @reportParameters }
                }
                $lastExitCode = $result.ExitCode
                $completionKind = 'Result'
                $completionResult = $result
                $completionError = $null
                $size = Get-WdtTuiHostSize
                Show-WdtTuiRunResult -Result $result -Width $size.Width -RunKind $runKind
            }
            catch {
                $lastExitCode = 1
                $completionKind = 'Error'
                $completionResult = $null
                $completionError = $_.Exception.Message
                $size = Get-WdtTuiHostSize
                $renderWidth = Get-WdtTuiRenderWidth -WindowWidth $size.Width
                $errorLayout = Get-WdtTuiErrorLayout -Message $completionError -Width $renderWidth -RunKind $runKind
                Reset-WdtTuiFrame
                Show-WdtTuiFrame -Layout $errorLayout -Width $size.Width -ForceFull $true
            }

            if ($useReadKey) {
                try {
                    while ($true) {
                        $completionEvent = Wait-WdtTuiEvent -InitialWidth $size.Width -InitialHeight $size.Height
                        if ($completionEvent.Type -eq 'Resize') {
                            $size = $completionEvent.Size
                            $renderWidth = Get-WdtTuiRenderWidth -WindowWidth $size.Width
                            $completionLayout = if ($completionKind -eq 'Result') {
                                Get-WdtTuiRunResultLayout -Result $completionResult -Width $renderWidth -RunKind $runKind
                            }
                            else {
                                Get-WdtTuiErrorLayout -Message $completionError -Width $renderWidth -RunKind $runKind
                            }
                            Reset-WdtTuiFrame
                            Show-WdtTuiFrame -Layout $completionLayout -Width $size.Width -ForceFull $true
                            continue
                        }
                        if ($completionEvent.KeyInfo.Key -eq [System.ConsoleKey]::Escape) { return $lastExitCode }
                        if ($completionEvent.KeyInfo.Key -eq [System.ConsoleKey]::Enter) { break }
                    }
                }
                catch { $useReadKey = $false }
            }
            if (-not $useReadKey) {
                Write-Host ''
                Read-Host 'Press Enter to return to the menu' | Out-Null
            }
        }
    }
    finally {
        Complete-WdtTuiConsoleFrame
        if ($null -ne $originalCursorVisible) {
            try { [System.Console]::CursorVisible = $originalCursorVisible } catch { }
        }
    }
    return $lastExitCode
}
