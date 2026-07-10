[CmdletBinding()]
param(
    [switch]$All,
    [switch]$System,
    [switch]$Security,
    [switch]$Performance,
    [switch]$Network,
    [switch]$Time,
    [switch]$Disk,
    [switch]$Crashes,
    [switch]$Events,
    [switch]$Services,
    [switch]$Updates,
    [string]$OutputDirectory = (Get-Location).Path,
    [switch]$ExportMarkdown,
    [switch]$PrivacyMode
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$reportCommonPath = Join-Path -Path $repositoryRoot -ChildPath 'scripts\report-common.ps1'
if (-not (Test-Path -LiteralPath $reportCommonPath -PathType Leaf)) {
    throw "Missing report helper: $reportCommonPath"
}

. $reportCommonPath

function Get-CurrentPowerShellPath {
    try {
        $processPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not [string]::IsNullOrWhiteSpace($processPath) -and (Test-Path -LiteralPath $processPath)) {
            return $processPath
        }
    }
    catch {
        # Fall back to the expected executable name below.
    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        return 'pwsh'
    }

    return Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
}

function Get-RelativeDisplayPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $baseUri = New-Object -TypeName System.Uri -ArgumentList (($BasePath.TrimEnd('\') + '\'))
    $targetUri = New-Object -TypeName System.Uri -ArgumentList $TargetPath
    $relativePath = $baseUri.MakeRelativeUri($targetUri).ToString()
    return [System.Uri]::UnescapeDataString($relativePath).Replace('/', '\')
}

function Convert-TextToLines {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }

    $lines = @($Text -split "`r?`n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        return @($lines[0..($lines.Count - 2)])
    }

    return $lines
}

function ConvertTo-CommandArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-DiagnosticScript {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $result = [ordered]@{
        Title       = $Title
        Command     = '{0} -NoProfile -ExecutionPolicy Bypass -File {1}' -f (Split-Path -Leaf $PowerShellPath), (Get-RelativeDisplayPath -BasePath $RepositoryRoot -TargetPath $ScriptPath)
        ExitCode    = $null
        OutputLines = @()
        ErrorLines  = @()
    }

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        $result.ExitCode = 1
        $result.ErrorLines = @("Missing script: $ScriptPath")
        return Resolve-WdtDiagnosticResult -Result ([pscustomobject]$result)
    }

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
        $escapedScriptPath = $ScriptPath.Replace("'", "''")
        $commandText = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & '$escapedScriptPath'"

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $PowerShellPath
        $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command {0}' -f (ConvertTo-CommandArgument -Value $commandText)
        $startInfo.WorkingDirectory = $RepositoryRoot
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        $startInfo.StandardOutputEncoding = $utf8NoBom
        $startInfo.StandardErrorEncoding = $utf8NoBom
        $startInfo.EnvironmentVariables['WDT_FINDING_PROTOCOL'] = '1'

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo

        [void]$process.Start()
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $result.ExitCode = $process.ExitCode
        $result.OutputLines = @(Convert-TextToLines -Text $standardOutput)
        $result.ErrorLines = @(Convert-TextToLines -Text $standardError)
    }
    catch {
        $result.ExitCode = 1
        $result.ErrorLines = @("Failed to run script: $($_.Exception.Message)")
    }

    return Resolve-WdtDiagnosticResult -Result ([pscustomobject]$result)
}

function Add-TextSection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        $Result
    )

    $Lines.Add('')
    $Lines.Add(('== {0} ==' -f $Result.Title))
    $Lines.Add(('Command: {0}' -f $Result.Command))
    $Lines.Add(('Exit code: {0}' -f $Result.ExitCode))
    $Lines.Add('')

    if ($Result.OutputLines.Count -gt 0) {
        foreach ($line in $Result.OutputLines) {
            $Lines.Add($line)
        }
    }
    else {
        $Lines.Add('(no output)')
    }

    if ($Result.ErrorLines.Count -gt 0) {
        $Lines.Add('')
        $Lines.Add('Errors and warnings:')
        foreach ($line in $Result.ErrorLines) {
            $Lines.Add($line)
        }
    }
}

function Add-MarkdownSection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        $Result
    )

    $Lines.Add('')
    $Lines.Add(('## {0}' -f $Result.Title))
    $Lines.Add('')
    $Lines.Add(('- Command: `{0}`' -f $Result.Command))
    $Lines.Add(('- Exit code: `{0}`' -f $Result.ExitCode))
    $Lines.Add('')
    $Lines.Add('```text')

    if ($Result.OutputLines.Count -gt 0) {
        foreach ($line in $Result.OutputLines) {
            $Lines.Add($line)
        }
    }
    else {
        $Lines.Add('(no output)')
    }

    if ($Result.ErrorLines.Count -gt 0) {
        $Lines.Add('')
        $Lines.Add('Errors and warnings:')
        foreach ($line in $Result.ErrorLines) {
            $Lines.Add($line)
        }
    }

    $Lines.Add('```')
}

function ConvertTo-MarkdownInlineText {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) {
        return ''
    }

    return $Text.Replace('\', '\\').Replace('`', '\`').Replace('*', '\*').Replace('[', '\[').Replace(']', '\]').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Add-TextFindingsSummary {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        $Summary
    )

    $Lines.Add('')
    $Lines.Add('== Findings Summary ==')
    $Lines.Add(('Overall status : {0}' -f $Summary.OverallStatus))
    $Lines.Add(('Errors         : {0}' -f $Summary.ErrorCount))
    $Lines.Add(('Warnings       : {0}' -f $Summary.WarningCount))
    $Lines.Add(('OK modules     : {0}' -f $Summary.OkModuleCount))
    $Lines.Add('')

    foreach ($finding in @($Summary.Items)) {
        if ($finding.Severity -eq 'OK') {
            $Lines.Add(('[OK] {0} - {1}' -f $finding.Module, $finding.Message))
            continue
        }

        $line = '[{0}] {1} / {2} - {3}' -f $finding.Severity, $finding.Module, $finding.Code, $finding.Message
        if (-not [string]::IsNullOrWhiteSpace($finding.Evidence)) {
            $line += ' Evidence: {0}' -f $finding.Evidence
        }

        $Lines.Add($line)
    }
}

function Add-MarkdownFindingsSummary {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        $Summary
    )

    $Lines.Add('')
    $Lines.Add('## Findings Summary')
    $Lines.Add('')
    $Lines.Add(('- Overall status: `{0}`' -f $Summary.OverallStatus))
    $Lines.Add(('- Errors: `{0}`' -f $Summary.ErrorCount))
    $Lines.Add(('- Warnings: `{0}`' -f $Summary.WarningCount))
    $Lines.Add(('- OK modules: `{0}`' -f $Summary.OkModuleCount))
    $Lines.Add('')

    foreach ($finding in @($Summary.Items)) {
        $module = ConvertTo-MarkdownInlineText -Text $finding.Module
        $message = ConvertTo-MarkdownInlineText -Text $finding.Message

        if ($finding.Severity -eq 'OK') {
            $Lines.Add(('- `[OK]` **{0}** - {1}' -f $module, $message))
            continue
        }

        $code = ConvertTo-MarkdownInlineText -Text $finding.Code
        $line = '- `[{0}]` **{1} / {2}** - {3}' -f $finding.Severity, $module, $code, $message
        if (-not [string]::IsNullOrWhiteSpace($finding.Evidence)) {
            $evidence = ConvertTo-MarkdownInlineText -Text $finding.Evidence
            $line += ' Evidence: {0}' -f $evidence
        }

        $Lines.Add($line)
    }
}

function Protect-WdtDiagnosticResults {
    param(
        [Parameter(Mandatory = $true)][object[]]$Results,
        $Context
    )

    foreach ($result in @($Results)) {
        $result.Command = Protect-WdtSensitiveUrlText -Text ([string]$result.Command)
        $result.OutputLines = @($result.OutputLines | ForEach-Object { Protect-WdtSensitiveUrlText -Text ([string]$_) })
        $result.ErrorLines = @($result.ErrorLines | ForEach-Object { Protect-WdtSensitiveUrlText -Text ([string]$_) })

        foreach ($finding in @($result.Findings)) {
            $finding.Message = Protect-WdtSensitiveUrlText -Text ([string]$finding.Message)
            if (-not [string]::IsNullOrWhiteSpace($finding.Evidence)) {
                $finding.Evidence = Protect-WdtSensitiveUrlText -Text ([string]$finding.Evidence)
            }
        }

        if ($null -eq $Context) {
            continue
        }

        $result.Command = Protect-WdtText -Text ([string]$result.Command) -Context $Context
        $result.OutputLines = @($result.OutputLines | ForEach-Object { Protect-WdtText -Text ([string]$_) -Context $Context })
        $result.ErrorLines = @($result.ErrorLines | ForEach-Object { Protect-WdtText -Text ([string]$_) -Context $Context })

        foreach ($finding in @($result.Findings)) {
            $finding.Message = Protect-WdtText -Text ([string]$finding.Message) -Context $Context
            if (-not [string]::IsNullOrWhiteSpace($finding.Evidence)) {
                $finding.Evidence = Protect-WdtText -Text ([string]$finding.Evidence) -Context $Context
            }
        }
    }
}

$selectedAll = $All -or (-not $System -and -not $Security -and -not $Performance -and -not $Network -and -not $Time -and -not $Disk -and -not $Crashes -and -not $Events -and -not $Services -and -not $Updates)
$selectedChecks = New-Object System.Collections.Generic.List[object]

if ($selectedAll -or $System) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'System Information'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\system-info.ps1'
    })
}

if ($selectedAll -or $Security) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Security Posture'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\security-posture.ps1'
    })
}

if ($selectedAll -or $Performance) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Performance Snapshot'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\performance-snapshot.ps1'
    })
}

if ($selectedAll -or $Network) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Network Check'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\network-check.ps1'
    })
}

if ($selectedAll -or $Time) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Time Sync Diagnostics'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\time-sync-diagnostics.ps1'
    })
}

if ($selectedAll -or $Disk) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Disk Health'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\disk-health.ps1'
    })
}

if ($selectedAll -or $Crashes) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Crash and Hang Diagnostics'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\crash-hang-diagnostics.ps1'
    })
}

if ($selectedAll -or $Events) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Event Log Check'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\event-log-check.ps1'
    })
}

if ($selectedAll -or $Services) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Services Check'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\services-check.ps1'
    })
}

if ($selectedAll -or $Updates) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Windows Update Check'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\windows-update-check.ps1'
    })
}

$resolvedOutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $resolvedOutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
}

do {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportBaseName = "WindowsDiagnosticsReport-$timestamp"
    $textReportPath = Join-Path -Path $resolvedOutputDirectory -ChildPath "$reportBaseName.txt"
    $markdownReportPath = Join-Path -Path $resolvedOutputDirectory -ChildPath "$reportBaseName.md"

    if ((Test-Path -LiteralPath $textReportPath) -or (Test-Path -LiteralPath $markdownReportPath)) {
        Start-Sleep -Seconds 1
    }
} while ((Test-Path -LiteralPath $textReportPath) -or (Test-Path -LiteralPath $markdownReportPath))

$powerShellPath = Get-CurrentPowerShellPath
$createdAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'

$results = New-Object System.Collections.Generic.List[object]
foreach ($check in $selectedChecks) {
    $results.Add((Invoke-DiagnosticScript -Title $check.Title -ScriptPath $check.Path -PowerShellPath $powerShellPath -RepositoryRoot $repositoryRoot))
}

$privacyModeLabel = if ($PrivacyMode) { 'enabled' } else { 'disabled' }
$displayComputerName = [string]$env:COMPUTERNAME
$displayTextReportPath = $textReportPath
$displayMarkdownReportPath = $markdownReportPath
$redactionContext = $null

if ($PrivacyMode) {
    $redactionContext = New-WdtRedactionContext
    if (-not [string]::IsNullOrWhiteSpace($displayComputerName)) {
        $displayComputerName = Get-WdtRedactionToken -Context $redactionContext -Category HOST -Value $displayComputerName
    }
    $displayTextReportPath = Protect-WdtText -Text $textReportPath -Context $redactionContext
    $displayMarkdownReportPath = Protect-WdtText -Text $markdownReportPath -Context $redactionContext
}

Protect-WdtDiagnosticResults -Results @($results.ToArray()) -Context $redactionContext

$findingsSummary = Get-WdtFindingsSummary -Results @($results.ToArray())

$textLines = New-Object System.Collections.Generic.List[string]
$textLines.Add('Windows Diagnostics Toolkit - Support Report')
$textLines.Add(('Created at    : {0}' -f $createdAt))
$textLines.Add(('Computer name : {0}' -f $displayComputerName))
$textLines.Add(('Mode          : read-only'))
$textLines.Add(('Privacy mode  : {0}' -f $privacyModeLabel))
$textLines.Add(('Output        : {0}' -f $displayTextReportPath))
$textLines.Add(('Selected      : {0}' -f (($selectedChecks | ForEach-Object { $_.Title }) -join ', ')))

Add-TextFindingsSummary -Lines $textLines -Summary $findingsSummary

foreach ($result in $results) {
    Add-TextSection -Lines $textLines -Result $result
}

[System.IO.File]::WriteAllLines($textReportPath, $textLines, [System.Text.Encoding]::UTF8)
Write-Host ("TXT report written: {0}" -f $displayTextReportPath)

if ($ExportMarkdown) {
    $markdownLines = New-Object System.Collections.Generic.List[string]
    $markdownLines.Add('# Windows Diagnostics Toolkit - Support Report')
    $markdownLines.Add('')
    $markdownLines.Add(('- Created at: `{0}`' -f $createdAt))
    $markdownLines.Add(('- Computer name: `{0}`' -f $displayComputerName))
    $markdownLines.Add(('- Mode: `read-only`'))
    $markdownLines.Add(('- Privacy mode: `{0}`' -f $privacyModeLabel))
    $markdownLines.Add(('- TXT report: `{0}`' -f $displayTextReportPath))
    $markdownLines.Add(('- Selected: `{0}`' -f (($selectedChecks | ForEach-Object { $_.Title }) -join ', ')))

    Add-MarkdownFindingsSummary -Lines $markdownLines -Summary $findingsSummary

    foreach ($result in $results) {
        Add-MarkdownSection -Lines $markdownLines -Result $result
    }

    [System.IO.File]::WriteAllLines($markdownReportPath, $markdownLines, [System.Text.Encoding]::UTF8)
    Write-Host ("Markdown report written: {0}" -f $displayMarkdownReportPath)
}

if (($results | Where-Object { $_.ExitCode -ne 0 }).Count -gt 0) {
    Write-Warning 'One or more diagnostics completed with a non-zero exit code. See the report for details.'
    exit 1
}
