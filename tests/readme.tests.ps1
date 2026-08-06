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

function Get-MarkdownHeadings {
    param([Parameter(Mandatory = $true)][string]$Text)

    $insideFence = $false
    foreach ($line in @($Text -split "`n")) {
        if ($line -match '^```') {
            $insideFence = -not $insideFence
            continue
        }
        if (-not $insideFence -and $line -match '^(#{1,6})[ ]+(.+?)\s*$') {
            [pscustomobject]@{
                Level = $matches[1].Length
                Text  = $matches[2].Trim()
            }
        }
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$readmePath = Join-Path -Path $repositoryRoot -ChildPath 'README.md'
$usagePath = Join-Path -Path $repositoryRoot -ChildPath 'docs\usage.md'
$readmeRaw = Get-Content -LiteralPath $readmePath -Raw
$readme = Normalize-LineEndings -Text $readmeRaw
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
Assert-True ($readme.Contains('| Interactive TUI | `.\WindowsDiagnosticsReports` |')) 'README does not document the interactive default report directory.'
Assert-True ($readme.Contains('| Command-line mode | Current working directory |')) 'README does not document the command-line default report directory.'
Assert-True (-not $readme.Contains('Reports are written to the current directory unless `-OutputDirectory` is provided')) 'README incorrectly applies the command-line output default to the interactive TUI.'
Assert-True (-not $readme.Contains('[Latest beta]')) 'README uses a temporal release label instead of the pinned beta version.'
Assert-True ($readme.Contains('| Wide | `110x28`')) 'README does not document the Wide TUI threshold.'
Assert-True ($readme.Contains('| WideShort | `110x22`')) 'README does not document the WideShort layout.'
Assert-True ($readme.Contains('| Compact | `40x18`')) 'README does not document the Compact layout.'
Assert-True ($readme.Contains('`120x30` or larger is recommended')) 'README does not document the recommended dashboard size.'
Assert-True ($readme.Contains('WDT_TUI_LOGO')) 'README does not document the logo override.'
Assert-True ($readme.Contains('OEM encoding such as `cp866`')) 'README does not explain the ASCII fallback for OEM encodings.'
Assert-True (-not $readme.Contains('The interface is ASCII-first')) 'README still contains the obsolete ASCII-first description.'
Assert-True (-not $readme.Contains('Set-ExecutionPolicy Unrestricted')) 'README recommends a persistent unsafe Execution Policy change.'
Assert-True (-not $readme.Contains('C:\Users\')) 'README contains an absolute user profile path.'

$headings = @(Get-MarkdownHeadings -Text $readme)
Assert-True ($headings.Count -gt 0) 'README has no Markdown headings.'
Assert-True ($headings[0].Level -eq 1) 'README must begin with a level-one title.'
Assert-True (@($headings | Where-Object { $_.Level -eq 1 }).Count -eq 1) 'README must contain exactly one level-one title.'
$seenHeadings = @{}
for ($index = 0; $index -lt $headings.Count; $index++) {
    $heading = $headings[$index]
    $headingKey = $heading.Text.ToLowerInvariant()
    Assert-True (-not $seenHeadings.ContainsKey($headingKey)) "README contains a duplicate heading: $($heading.Text)"
    $seenHeadings[$headingKey] = $true
    if ($index -gt 0) {
        Assert-True ($heading.Level -le ($headings[$index - 1].Level + 1)) "README skips a heading level before: $($heading.Text)"
    }
}

$insideFence = $false
foreach ($line in @($readme -split "`n")) {
    if ($line -match '^```(?<language>.*)$') {
        if (-not $insideFence) {
            Assert-True (-not [string]::IsNullOrWhiteSpace($matches['language'])) 'README contains a fenced code block without a language identifier.'
        }
        else {
            Assert-True ([string]::IsNullOrWhiteSpace($matches['language'])) 'README closing code fence contains unexpected text.'
        }
        $insideFence = -not $insideFence
    }
}
Assert-True (-not $insideFence) 'README contains an unclosed fenced code block.'

foreach ($imageMatch in @([System.Text.RegularExpressions.Regex]::Matches($readme, '!\[(?<alt>[^\]\r\n]*)\]\([^)]+\)'))) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($imageMatch.Groups['alt'].Value)) 'README contains a Markdown image without alt text.'
}
foreach ($imageTagMatch in @([System.Text.RegularExpressions.Regex]::Matches($readme, '(?is)<img\b[^>]*>'))) {
    $altMatch = [System.Text.RegularExpressions.Regex]::Match($imageTagMatch.Value, '\balt="(?<alt>[^"]+)"')
    Assert-True ($altMatch.Success -and -not [string]::IsNullOrWhiteSpace($altMatch.Groups['alt'].Value)) 'README contains an HTML image without meaningful alt text.'
}

$genericLinkTexts = @('here', 'click here', 'learn more', 'read more')
foreach ($linkMatch in @([System.Text.RegularExpressions.Regex]::Matches($readme, '(?<!\!)\[(?<text>[^\]\r\n]+)\]\((?<target>[^)\r\n]+)\)'))) {
    $linkText = $linkMatch.Groups['text'].Value.Trim().ToLowerInvariant()
    Assert-True ($linkText -notin $genericLinkTexts) "README contains generic link text: $linkText"

    $target = $linkMatch.Groups['target'].Value.Trim()
    if ($target -match '^(https?://|mailto:|#)') {
        continue
    }
    $relativePath = ($target -split '#', 2)[0]
    $resolvedPath = Join-Path -Path $repositoryRoot -ChildPath $relativePath
    Assert-True (Test-Path -LiteralPath $resolvedPath) "README contains a broken relative link: $target"
}

$rawLines = @($readmeRaw -split "`r?`n")
for ($lineIndex = 0; $lineIndex -lt $rawLines.Count; $lineIndex++) {
    Assert-True (-not $rawLines[$lineIndex].Contains("`t")) "README contains a tab on line $($lineIndex + 1)."
    Assert-True (-not ($rawLines[$lineIndex] -match '[ ]+$')) "README contains trailing spaces on line $($lineIndex + 1)."
}
Assert-True ($readmeRaw.EndsWith("`n")) 'README must end with a newline.'
Assert-True ((Get-Item -LiteralPath $readmePath).Length -lt 512000) 'README exceeds the GitHub rendering limit of 500 KiB.'

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
