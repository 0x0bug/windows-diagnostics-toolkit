[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Normalize-LineEndings {
    param([AllowEmptyString()][string]$Text)
    return ($Text -replace "`r`n", "`n").Trim()
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$readmePath = Join-Path -Path $repositoryRoot -ChildPath 'README.md'
$readme = Normalize-LineEndings -Text (Get-Content -LiteralPath $readmePath -Raw)

$interactiveWindowsPowerShellCommand = Normalize-LineEndings -Text @'
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-WindowsDiagnostics.ps1
'@

$commandLineWindowsPowerShellCommand = Normalize-LineEndings -Text @'
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
'@

Assert-True ($readme.Contains($interactiveWindowsPowerShellCommand)) 'README is missing the Windows PowerShell 5.1 interactive launch command.'
Assert-True ($readme.Contains($commandLineWindowsPowerShellCommand)) 'README is missing the Windows PowerShell 5.1 command-line example.'
Assert-True ($readme.Contains('Running without switches opens the interactive TUI.')) 'README does not document the TUI-first default.'
Assert-True ($readme.Contains('With `-All` or one or more module switches it runs directly in command-line mode.')) 'README does not distinguish TUI and command-line routing.'
Assert-True ($readme.Contains('script execution is disabled')) 'README is missing Execution Policy troubleshooting.'
Assert-True ($readme.Contains('does not change the machine-wide or current-user execution policy')) 'README does not explain the process-only Execution Policy bypass.'
Assert-True ($readme.Contains('If PowerShell reports that `pwsh` is not recognized')) 'README is missing pwsh troubleshooting guidance.'
Assert-True ($readme.Contains('Installing PowerShell 7 is optional')) 'README does not explain that PowerShell 7 is optional.'
Assert-True (-not $readme.Contains('Set-ExecutionPolicy Unrestricted')) 'README recommends a persistent unsafe Execution Policy change.'

Write-Host 'README tests passed.'
