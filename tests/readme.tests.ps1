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
Assert-True ($readme.Contains('| Wide | `110x28`')) 'README does not document the Wide TUI threshold.'
Assert-True ($readme.Contains('| WideShort | `110x22`')) 'README does not document the WideShort layout.'
Assert-True ($readme.Contains('| Compact | `40x18`')) 'README does not document the Compact layout.'
Assert-True ($readme.Contains('`120x30` or larger is recommended')) 'README does not document the recommended dashboard size.'
Assert-True ($readme.Contains('WDT_TUI_LOGO')) 'README does not document the logo override.'
Assert-True ($readme.Contains('OEM encoding such as `cp866`')) 'README does not explain the ASCII fallback for OEM encodings.'
Assert-True (-not $readme.Contains('The interface is ASCII-first')) 'README still contains the obsolete ASCII-first description.'
Assert-True (-not $readme.Contains('Set-ExecutionPolicy Unrestricted')) 'README recommends a persistent unsafe Execution Policy change.'
Assert-True (-not $readme.Contains('C:\Users\')) 'README contains an absolute user profile path.'

$requiredAssets = @(
    'site\assets\tui-wide-unicode.svg',
    'site\assets\tui-result.svg'
)
foreach ($relativeAsset in $requiredAssets) {
    $assetPath = Join-Path -Path $repositoryRoot -ChildPath $relativeAsset
    Assert-True (Test-Path -LiteralPath $assetPath -PathType Leaf) ("Documentation asset is missing: {0}" -f $relativeAsset)
}

Assert-True ($readme.Contains('site/assets/tui-wide-unicode.svg')) 'README does not reference the Wide TUI visual.'
Assert-True ($readme.Contains('site/assets/tui-result.svg')) 'README does not reference the result visual.'
Assert-True ($usage.Contains('../site/assets/tui-wide-unicode.svg')) 'Usage guide does not reference the Wide TUI visual.'
Assert-True ($usage.Contains('../site/assets/tui-result.svg')) 'Usage guide does not reference the result visual.'
Assert-True ($usage.Contains('ASCII appears instead of the Unicode logo')) 'Usage guide is missing Unicode fallback troubleshooting.'
Assert-True (-not $usage.Contains('## Real Co-Authored Commit')) 'Usage guide still contains contributor workflow content.'

Write-Host 'README and documentation tests passed.'
