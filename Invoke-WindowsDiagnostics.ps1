[CmdletBinding()]
param(
    [switch]$All,
    [switch]$System,
    [switch]$Network,
    [switch]$Disk,
    [switch]$Events,
    [string]$OutputDirectory = (Get-Location).Path,
    [switch]$ExportMarkdown
)

$ErrorActionPreference = 'Stop'

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
        return [pscustomobject]$result
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

    return [pscustomobject]$result
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

$repositoryRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$selectedAll = $All -or (-not $System -and -not $Network -and -not $Disk -and -not $Events)
$selectedChecks = New-Object System.Collections.Generic.List[object]

if ($selectedAll -or $System) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'System Information'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\system-info.ps1'
    })
}

if ($selectedAll -or $Network) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Network Check'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\network-check.ps1'
    })
}

if ($selectedAll -or $Disk) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Disk Health'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\disk-health.ps1'
    })
}

if ($selectedAll -or $Events) {
    $selectedChecks.Add([pscustomobject]@{
        Title = 'Event Log Check'
        Path  = Join-Path -Path $repositoryRoot -ChildPath 'scripts\event-log-check.ps1'
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

$textLines = New-Object System.Collections.Generic.List[string]
$textLines.Add('Windows Diagnostics Toolkit - Support Report')
$textLines.Add(('Created at    : {0}' -f $createdAt))
$textLines.Add(('Computer name : {0}' -f $env:COMPUTERNAME))
$textLines.Add(('Mode          : read-only'))
$textLines.Add(('Output        : {0}' -f $textReportPath))
$textLines.Add(('Selected      : {0}' -f (($selectedChecks | ForEach-Object { $_.Title }) -join ', ')))

foreach ($result in $results) {
    Add-TextSection -Lines $textLines -Result $result
}

[System.IO.File]::WriteAllLines($textReportPath, $textLines, [System.Text.Encoding]::UTF8)
Write-Host ("TXT report written: {0}" -f $textReportPath)

if ($ExportMarkdown) {
    $markdownLines = New-Object System.Collections.Generic.List[string]
    $markdownLines.Add('# Windows Diagnostics Toolkit - Support Report')
    $markdownLines.Add('')
    $markdownLines.Add(('- Created at: `{0}`' -f $createdAt))
    $markdownLines.Add(('- Computer name: `{0}`' -f $env:COMPUTERNAME))
    $markdownLines.Add(('- Mode: `read-only`'))
    $markdownLines.Add(('- TXT report: `{0}`' -f $textReportPath))
    $markdownLines.Add(('- Selected: `{0}`' -f (($selectedChecks | ForEach-Object { $_.Title }) -join ', ')))

    foreach ($result in $results) {
        Add-MarkdownSection -Lines $markdownLines -Result $result
    }

    [System.IO.File]::WriteAllLines($markdownReportPath, $markdownLines, [System.Text.Encoding]::UTF8)
    Write-Host ("Markdown report written: {0}" -f $markdownReportPath)
}

if (($results | Where-Object { $_.ExitCode -ne 0 }).Count -gt 0) {
    Write-Warning 'One or more diagnostics completed with a non-zero exit code. See the report for details.'
    exit 1
}
