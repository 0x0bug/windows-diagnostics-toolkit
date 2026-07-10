[CmdletBinding()]
param()

function Get-WdtRecommendedSelection {
    return @(Get-WdtDiagnosticDefinition | Where-Object { $_.Recommended } | ForEach-Object { $_.Name })
}

function New-WdtTuiState {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [string[]]$InitialSelection
    )

    $selectedNames = @($InitialSelection)
    if ($null -eq $InitialSelection -or $InitialSelection.Count -eq 0) {
        $selectedNames = @(Get-WdtRecommendedSelection)
    }
    $diagnostics = @(Get-WdtDiagnosticDefinition | ForEach-Object {
            [pscustomobject]@{
                Name     = $_.Name
                Label    = $_.Label
                Selected = $_.Name -in $selectedNames
            }
        })

    return [pscustomobject]@{
        Diagnostics    = $diagnostics
        PrivacyMode    = $true
        ExportMarkdown = $true
        OutputDirectory = $OutputDirectory
        CursorIndex    = 0
        ErrorMessage   = $null
        ExitRequested  = $false
        ActionRequested = $null
    }
}

function Get-WdtTuiSelectedModule {
    param([Parameter(Mandatory = $true)]$State)
    return @($State.Diagnostics | Where-Object { $_.Selected } | ForEach-Object { $_.Name })
}

function ConvertTo-WdtReportParameters {
    param([Parameter(Mandatory = $true)]$State)

    return @{
        SelectedModules = @(Get-WdtTuiSelectedModule -State $State)
        OutputDirectory = $State.OutputDirectory
        PrivacyMode     = [bool]$State.PrivacyMode
        ExportMarkdown  = [bool]$State.ExportMarkdown
    }
}

function Get-WdtTuiMenuItem {
    param([Parameter(Mandatory = $true)]$State)

    $items = @($State.Diagnostics | ForEach-Object { [pscustomobject]@{ Kind = 'Diagnostic'; Name = $_.Name; Label = $_.Label } })
    $items += @(
        [pscustomobject]@{ Kind = 'Privacy'; Name = 'PrivacyMode'; Label = 'Privacy mode' },
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
        Diagnostics     = @($State.Diagnostics | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Label = $_.Label; Selected = [bool]$_.Selected } })
        PrivacyMode     = [bool]$State.PrivacyMode
        ExportMarkdown  = [bool]$State.ExportMarkdown
        OutputDirectory = [string]$State.OutputDirectory
        CursorIndex     = [int]$State.CursorIndex
        ErrorMessage    = $State.ErrorMessage
        ExitRequested   = [bool]$State.ExitRequested
        ActionRequested = $null
    }
    $items = @(Get-WdtTuiMenuItem -State $nextState)

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
        $recommended = @(Get-WdtRecommendedSelection)
        foreach ($diagnostic in $nextState.Diagnostics) { $diagnostic.Selected = $diagnostic.Name -in $recommended }
        return $nextState
    }
    if ($Action -eq 'SetOutputDirectory') {
        $nextState.OutputDirectory = $Value
        return $nextState
    }
    if ($Action -eq 'Exit') {
        $nextState.ExitRequested = $true
        $nextState.ActionRequested = 'Exit'
        return $nextState
    }

    $currentItem = $items[$nextState.CursorIndex]
    if ($Action -eq 'ToggleCurrent' -or $Action -eq 'SelectCurrent') {
        if ($currentItem.Kind -eq 'Diagnostic') {
            foreach ($diagnostic in $nextState.Diagnostics) {
                if ($diagnostic.Name -eq $currentItem.Name) { $diagnostic.Selected = -not $diagnostic.Selected; break }
            }
        }
        elseif ($currentItem.Kind -eq 'Privacy') {
            $nextState.PrivacyMode = -not $nextState.PrivacyMode
        }
        elseif ($currentItem.Kind -eq 'Markdown') {
            $nextState.ExportMarkdown = -not $nextState.ExportMarkdown
        }
        elseif ($Action -eq 'SelectCurrent') {
            $nextState.ActionRequested = $currentItem.Kind
            if ($currentItem.Kind -eq 'Exit') { $nextState.ExitRequested = $true }
        }
    }
    return $nextState
}

function Format-WdtTuiPath {
    param([string]$Path, [int]$Width)

    $available = [Math]::Max(12, $Width - 10)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -le $available) { return $Path }
    return '...' + $Path.Substring($Path.Length - ($available - 3))
}

function Get-WdtTuiLines {
    param(
        [Parameter(Mandatory = $true)]$State,
        [int]$Width = 80
    )

    $safeWidth = [Math]::Max(40, $Width)
    $items = @(Get-WdtTuiMenuItem -State $State)
    $selectedCount = @(Get-WdtTuiSelectedModule -State $State).Count
    $checkMark = [char]0x2713
    $lines = @(
        'Windows Diagnostics Toolkit',
        '',
        'Read-only diagnostics',
        'Local reports',
        'No telemetry',
        '',
        'Diagnostics',
        ('-' * [Math]::Max(20, $safeWidth - 2))
    )

    for ($index = 0; $index -lt $items.Count; $index++) {
        $item = $items[$index]
        $active = if ($index -eq $State.CursorIndex) { '>' } else { ' ' }
        if ($item.Kind -eq 'Diagnostic') {
            $diagnostic = @($State.Diagnostics | Where-Object { $_.Name -eq $item.Name })[0]
            $mark = if ($diagnostic.Selected) { $checkMark } else { ' ' }
            $lines += ("{0} [{1}] {2}" -f $active, $mark, $item.Label)
        }
    }

    $lines += @('', ("Selected modules: {0}" -f $selectedCount), '', 'Report options', ('-' * [Math]::Max(20, $safeWidth - 2)))
    for ($index = $State.Diagnostics.Count; $index -lt $items.Count; $index++) {
        $item = $items[$index]
        $active = if ($index -eq $State.CursorIndex) { '>' } else { ' ' }
        if ($item.Kind -eq 'Privacy') {
            $mark = if ($State.PrivacyMode) { $checkMark } else { ' ' }
            $lines += ("{0} [{1}] Privacy mode" -f $active, $mark)
        }
        elseif ($item.Kind -eq 'Markdown') {
            $mark = if ($State.ExportMarkdown) { $checkMark } else { ' ' }
            $lines += ("{0} [{1}] Markdown report" -f $active, $mark)
        }
        elseif ($item.Kind -eq 'Output') {
            $lines += ("{0} Output: {1}" -f $active, (Format-WdtTuiPath -Path $State.OutputDirectory -Width $safeWidth))
        }
        elseif ($item.Kind -eq 'Run') {
            $lines += ''; $lines += 'Actions'; $lines += ('-' * [Math]::Max(20, $safeWidth - 2)); $lines += ("{0} Run diagnostics" -f $active)
        }
        elseif ($item.Kind -eq 'Exit') {
            $lines += ("{0} Exit" -f $active)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($State.ErrorMessage)) {
        $lines += ''; $lines += ("Error: {0}" -f $State.ErrorMessage)
    }
    $lines += @('', 'Up/Down Navigate   Space Toggle   Enter Select', 'A Select all   R Recommended   Esc Exit')
    return $lines
}

function Show-WdtTuiScreen {
    param([Parameter(Mandatory = $true)]$State)

    $width = 80
    try { $width = $Host.UI.RawUI.WindowSize.Width } catch { }
    Clear-Host
    foreach ($line in @(Get-WdtTuiLines -State $State -Width $width)) {
        if ($line -like 'Error:*') { Write-Host $line -ForegroundColor Red } else { Write-Host $line }
    }
}

function Show-WdtTuiRunResult {
    param($Result)

    Write-Host ''
    if ($Result.ExitCode -eq 0) { Write-Host 'Diagnostics completed successfully.' -ForegroundColor Green }
    else { Write-Host 'Diagnostics completed with partial failures.' -ForegroundColor Yellow }
    Write-Host ("TXT report: {0}" -f $Result.TextReportPath)
    if (-not [string]::IsNullOrWhiteSpace($Result.MarkdownReportPath)) { Write-Host ("Markdown report: {0}" -f $Result.MarkdownReportPath) }
    Write-Host ("WARN findings: {0}" -f $Result.WarningCount)
    Write-Host ("ERROR findings: {0}" -f $Result.ErrorCount)
    Write-Host ("Elapsed: {0}" -f $Result.ElapsedTime)
}

function Invoke-WdtInteractiveSession {
    param(
        [string[]]$InitialSelection,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    if ([System.Console]::IsInputRedirected) {
        Write-Host 'Interactive input is unavailable because stdin is redirected.' -ForegroundColor Red
        Write-Host 'Use: .\Invoke-WindowsDiagnostics.ps1 -System -OutputDirectory .\WindowsDiagnosticsReports'
        return 2
    }

    $state = New-WdtTuiState -OutputDirectory $OutputDirectory -InitialSelection $InitialSelection
    $useReadKey = $true
    $lastExitCode = 0
    try {
        while (-not $state.ExitRequested) {
            Show-WdtTuiScreen -State $state
            $items = @(Get-WdtTuiMenuItem -State $state)
            $action = $null

            if ($useReadKey) {
                try {
                    $keyInfo = [System.Console]::ReadKey($true)
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
                for ($menuIndex = 0; $menuIndex -lt $items.Count; $menuIndex++) {
                    Write-Host ("{0}. {1}" -f ($menuIndex + 1), $items[$menuIndex].Label)
                }
                $answer = Read-Host 'Enter item number, A, R, Run, or Exit'
                if ([string]::IsNullOrWhiteSpace($answer)) { $state.ErrorMessage = 'Input is required.'; continue }
                if ($answer -match '^\d+$') {
                    $number = [int]$answer
                    if ($number -ge 1 -and $number -le $items.Count) {
                        while ($state.CursorIndex -ne ($number - 1)) { $state = Update-WdtTuiState -State $state -Action MoveDown }
                        $action = 'Select'
                    }
                }
                elseif ($answer -ieq 'A') { $action = 'All' }
                elseif ($answer -ieq 'R') { $action = 'Recommended' }
                elseif ($answer -ieq 'Run') {
                    while ($state.CursorIndex -ne ($items.Count - 2)) { $state = Update-WdtTuiState -State $state -Action MoveDown }
                    $action = 'Select'
                }
                elseif ($answer -ieq 'Exit') { $action = 'Exit' }
                if ($null -eq $action) { $state.ErrorMessage = 'Unknown menu command.'; continue }
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
                if ([string]::IsNullOrWhiteSpace($path)) { $state.ErrorMessage = 'Output directory cannot be empty.'; continue }
                try {
                    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
                    $state = Update-WdtTuiState -State $state -Action SetOutputDirectory -Value $resolvedPath
                }
                catch { $state.ErrorMessage = $_.Exception.Message }
                continue
            }
            if ($state.ExitRequested) { continue }
            if ($state.ActionRequested -ne 'Run') { continue }

            try {
                $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($state.OutputDirectory)
                $state = Update-WdtTuiState -State $state -Action SetOutputDirectory -Value $resolvedPath
            }
            catch {
                $state.ErrorMessage = ("Invalid output directory: {0}" -f $_.Exception.Message)
                continue
            }
            $reportParameters = ConvertTo-WdtReportParameters -State $state
            if (@($reportParameters.SelectedModules).Count -eq 0) { $state.ErrorMessage = 'Select at least one diagnostic module.'; continue }
            try {
                Clear-Host
                Write-Host 'Running diagnostics...'
                Write-Host ("Selected modules ({0}): {1}" -f @($reportParameters.SelectedModules).Count, ($reportParameters.SelectedModules -join ', '))
                Write-Host ("Privacy mode: {0}" -f $(if ($reportParameters.PrivacyMode) { 'enabled' } else { 'disabled' }))
                Write-Host ("Output directory: {0}" -f $reportParameters.OutputDirectory)
                $result = Invoke-WdtReport @reportParameters
                $lastExitCode = $result.ExitCode
                Show-WdtTuiRunResult -Result $result
            }
            catch {
                $lastExitCode = 1
                Write-Host ("Diagnostics failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            }
            if ($useReadKey) {
                Write-Host ''; Write-Host 'Press Enter to return to the menu or Escape to exit.'
                try {
                    $completionKey = [System.Console]::ReadKey($true)
                    if ($completionKey.Key -eq [System.ConsoleKey]::Escape) { return $lastExitCode }
                }
                catch {
                    $useReadKey = $false
                    Read-Host 'Press Enter to return to the menu' | Out-Null
                }
            }
            else { Read-Host 'Press Enter to return to the menu' | Out-Null }
        }
    }
    finally {
        Write-Host ''
    }
    return $lastExitCode
}
