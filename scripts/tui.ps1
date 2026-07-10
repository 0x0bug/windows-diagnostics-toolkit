[CmdletBinding()]
param()

function Get-WdtTuiDiagnosticDefinition {
    return @(
        [pscustomobject]@{ Name = 'System'; Label = 'System information' },
        [pscustomobject]@{ Name = 'Security'; Label = 'Security posture' },
        [pscustomobject]@{ Name = 'Performance'; Label = 'Performance snapshot' },
        [pscustomobject]@{ Name = 'Network'; Label = 'Network' },
        [pscustomobject]@{ Name = 'Time'; Label = 'Time synchronization' },
        [pscustomobject]@{ Name = 'Disk'; Label = 'Disk health' },
        [pscustomobject]@{ Name = 'Crashes'; Label = 'Crashes and hangs' },
        [pscustomobject]@{ Name = 'Events'; Label = 'Event logs' },
        [pscustomobject]@{ Name = 'Services'; Label = 'Services and startup' },
        [pscustomobject]@{ Name = 'Updates'; Label = 'Windows Update' }
    )
}

function Get-WdtRecommendedSelection {
    return @('System', 'Security', 'Performance', 'Network', 'Time', 'Disk', 'Updates')
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
    $diagnostics = @(Get-WdtTuiDiagnosticDefinition | ForEach-Object {
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
    }
}

function Set-WdtRecommendedSelection {
    param([Parameter(Mandatory = $true)]$State)

    $recommended = @(Get-WdtRecommendedSelection)
    foreach ($diagnostic in $State.Diagnostics) {
        $diagnostic.Selected = $diagnostic.Name -in $recommended
    }
    return $State
}

function Set-WdtAllSelection {
    param([Parameter(Mandatory = $true)]$State)

    foreach ($diagnostic in $State.Diagnostics) {
        $diagnostic.Selected = $true
    }
    return $State
}

function Switch-WdtDiagnosticSelection {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Name
    )

    foreach ($diagnostic in $State.Diagnostics) {
        if ($diagnostic.Name -eq $Name) {
            $diagnostic.Selected = -not $diagnostic.Selected
            break
        }
    }
    return $State
}

function Set-WdtTuiCancelled {
    param([Parameter(Mandatory = $true)]$State)
    $State.ExitRequested = $true
    return $State
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
                    if ($number -ge 1 -and $number -le $items.Count) { $state.CursorIndex = $number - 1; $action = 'Select' }
                }
                elseif ($answer -ieq 'A') { $action = 'All' }
                elseif ($answer -ieq 'R') { $action = 'Recommended' }
                elseif ($answer -ieq 'Run') { $state.CursorIndex = $items.Count - 2; $action = 'Select' }
                elseif ($answer -ieq 'Exit') { $action = 'Exit' }
                if ($null -eq $action) { $state.ErrorMessage = 'Unknown menu command.'; continue }
            }

            $state.ErrorMessage = $null
            if ($action -eq 'Up') { $state.CursorIndex = if ($state.CursorIndex -le 0) { $items.Count - 1 } else { $state.CursorIndex - 1 }; continue }
            if ($action -eq 'Down') { $state.CursorIndex = if ($state.CursorIndex -ge $items.Count - 1) { 0 } else { $state.CursorIndex + 1 }; continue }
            if ($action -eq 'All') { $state = Set-WdtAllSelection -State $state; continue }
            if ($action -eq 'Recommended') { $state = Set-WdtRecommendedSelection -State $state; continue }
            if ($action -eq 'Exit') { $state = Set-WdtTuiCancelled -State $state; continue }
            if ($action -notin @('Toggle', 'Select')) { continue }

            $item = $items[$state.CursorIndex]
            if ($item.Kind -eq 'Diagnostic') { $state = Switch-WdtDiagnosticSelection -State $state -Name $item.Name; continue }
            if ($item.Kind -eq 'Privacy') { $state.PrivacyMode = -not $state.PrivacyMode; continue }
            if ($item.Kind -eq 'Markdown') { $state.ExportMarkdown = -not $state.ExportMarkdown; continue }
            if ($item.Kind -eq 'Output' -and $action -eq 'Select') {
                $path = Read-Host 'Output directory'
                if ([string]::IsNullOrWhiteSpace($path)) { $state.ErrorMessage = 'Output directory cannot be empty.'; continue }
                try { $state.OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path) }
                catch { $state.ErrorMessage = $_.Exception.Message }
                continue
            }
            if ($item.Kind -eq 'Exit' -and $action -eq 'Select') { $state = Set-WdtTuiCancelled -State $state; continue }
            if ($item.Kind -ne 'Run' -or $action -ne 'Select') { continue }

            try {
                $state.OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($state.OutputDirectory)
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
