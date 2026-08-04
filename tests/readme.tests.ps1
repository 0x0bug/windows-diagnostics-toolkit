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
$usagePath = Join-Path -Path $repositoryRoot -ChildPath 'docs\usage.md'
$readme = Normalize-LineEndings -Text (Get-Content -LiteralPath $readmePath -Raw)
$usage = Normalize-LineEndings -Text (Get-Content -LiteralPath $usagePath -Raw)
$bootstrapCommand = 'irm https://wdt.digital/run.ps1 | iex'
$releaseUrl = 'https://github.com/0x0bug/windows-diagnostics-toolkit/releases/tag/v0.1.0-beta'
$inspectionCommand = Normalize-LineEndings -Text @'
irm https://wdt.digital/run.ps1 -OutFile .\wdt-run.ps1
notepad .\wdt-run.ps1
.\wdt-run.ps1
'@

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
Assert-True ($readme.Contains($bootstrapCommand)) 'README is missing the public beta bootstrap command.'
Assert-True ($usage.Contains($bootstrapCommand)) 'Usage guide is missing the public beta bootstrap command.'
Assert-True ($readme.Contains($inspectionCommand)) 'README is missing the bootstrap inspection workflow.'
Assert-True ($usage.Contains($inspectionCommand)) 'Usage guide is missing the bootstrap inspection workflow.'
Assert-True ($readme.Contains($releaseUrl)) 'README is missing the v0.1.0-beta prerelease link.'
Assert-True ($usage.Contains($releaseUrl)) 'Usage guide is missing the v0.1.0-beta prerelease link.'
Assert-True ($readme.Contains('SHA-256 verification protects the downloaded release ZIP, not `run.ps1`.')) 'README misstates the checksum trust boundary.'
Assert-True ($usage.Contains('SHA-256 verification protects the downloaded release ZIP, not `run.ps1`.')) 'Usage guide misstates the checksum trust boundary.'
foreach ($staleCopy in @('planned `v0.1.0-beta`', 'until that beta is published', 'until the beta is published', 'no beta release ZIP is published yet', 'bootstrap is prepared')) {
    Assert-True ($readme.IndexOf($staleCopy, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "README contains stale prerelease copy: $staleCopy"
    Assert-True ($usage.IndexOf($staleCopy, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) "Usage guide contains stale prerelease copy: $staleCopy"
}
Assert-True ($readme.Contains('Running without switches opens the interactive TUI.')) 'README does not document the TUI-first default.'
Assert-True ($readme.Contains('With `-All`, `-Module`, or one or more legacy module switches it runs directly in command-line mode.')) 'README does not distinguish TUI and command-line routing.'
Assert-True ($readme.Contains('.\Invoke-WindowsDiagnostics.ps1 -Module System,Network')) 'README is missing the generic module selector example.'
Assert-True ($usage.Contains('.\Invoke-WindowsDiagnostics.ps1 -Module Events,Updates')) 'Usage guide is missing the generic module selector example.'
Assert-True ($readme.Contains('[Built-in module authoring](docs/module-authoring.md)')) 'README does not link the module authoring guide.'
Assert-True ($readme.Contains('script execution is disabled')) 'README is missing Execution Policy troubleshooting.'
Assert-True ($readme.Contains('does not change the machine-wide or current-user execution policy')) 'README does not explain the process-only Execution Policy bypass.'
Assert-True ($readme.Contains('If PowerShell reports that `pwsh` is not recognized')) 'README is missing pwsh troubleshooting guidance.'
Assert-True ($readme.Contains('installing PowerShell 7 is optional')) 'README does not explain that PowerShell 7 is optional.'
Assert-True ($readme.Contains('| Wide | `110x28`')) 'README does not document the Wide TUI threshold.'
Assert-True ($readme.Contains('| WideShort | `110x22`')) 'README does not document the WideShort layout.'
Assert-True ($readme.Contains('| Compact | `40x18`')) 'README does not document the Compact layout.'
Assert-True ($readme.Contains('`120x30` or larger is recommended')) 'README does not document the recommended dashboard size.'
Assert-True ($readme.Contains('WDT_TUI_LOGO')) 'README does not document the logo override.'
Assert-True ($readme.Contains('OEM encoding such as `cp866`')) 'README does not explain the ASCII fallback for OEM encodings.'
Assert-True (-not $readme.Contains('The interface is ASCII-first')) 'README still contains the obsolete ASCII-first description.'
Assert-True (-not $readme.Contains('Set-ExecutionPolicy Unrestricted')) 'README recommends a persistent unsafe Execution Policy change.'
Assert-True (-not $readme.Contains('C:\Users\')) 'README contains an absolute user profile path.'

$wideTuiImage = 'https://wdt.digital/assets/tui-wide-real.png'
$resultTuiImage = 'https://wdt.digital/assets/tui-result-real.png'
Assert-True ($readme.Contains($wideTuiImage)) 'README does not reference the published Wide TUI visual.'
Assert-True ($readme.Contains($resultTuiImage)) 'README does not reference the published result visual.'
Assert-True ($usage.Contains($wideTuiImage)) 'Usage guide does not reference the published Wide TUI visual.'
Assert-True ($usage.Contains($resultTuiImage)) 'Usage guide does not reference the published result visual.'
Assert-True (-not $readme.Contains('site/assets/')) 'README still references legacy local site assets.'
Assert-True (-not $usage.Contains('site/assets/')) 'Usage guide still references legacy local site assets.'
Assert-True ($usage.Contains('ASCII appears instead of the Unicode logo')) 'Usage guide is missing Unicode fallback troubleshooting.'
Assert-True (-not $usage.Contains('## Real Co-Authored Commit')) 'Usage guide still contains contributor workflow content.'

Write-Host 'README and documentation tests passed.'
