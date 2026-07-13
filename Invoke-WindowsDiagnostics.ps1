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
    [switch]$PrivacyMode,
    [switch]$Interactive,
    [ValidateRange(1, 2147483)]
    [int]$ModuleTimeoutSeconds = 180,
    [switch]$NoExternalNetworkTests,
    [ValidateNotNullOrEmpty()]
    [string]$NetworkDnsTestName = 'www.microsoft.com',
    [ValidateNotNullOrEmpty()]
    [string]$NetworkHttpsEndpoint = 'https://www.microsoft.com/',
    [ValidateNotNullOrEmpty()]
    [string]$NetworkIcmpTarget = '1.1.1.1',
    [string[]]$Module
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$reportCommonPath = Join-Path -Path $repositoryRoot -ChildPath 'scripts\report-common.ps1'
if (-not (Test-Path -LiteralPath $reportCommonPath -PathType Leaf)) {
    throw "Missing report helper: $reportCommonPath"
}

. $PSScriptRoot\scripts\report-common.ps1

$moduleRegistryPath = Join-Path -Path $repositoryRoot -ChildPath 'scripts\module-registry.ps1'
if (-not (Test-Path -LiteralPath $moduleRegistryPath -PathType Leaf)) {
    throw "Missing module registry: $moduleRegistryPath"
}

. $PSScriptRoot\scripts\module-registry.ps1

$moduleRoot = Join-Path -Path $repositoryRoot -ChildPath 'modules'
$registrySnapshot = Get-WdtModuleRegistry -ModuleRoot $moduleRoot

$coreOptionValues = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
$coreOptionValues['NoExternalNetworkTests'] = [bool]$NoExternalNetworkTests
$coreOptionValues['NetworkDnsTestName'] = $NetworkDnsTestName
$coreOptionValues['NetworkHttpsEndpoint'] = $NetworkHttpsEndpoint
$coreOptionValues['NetworkIcmpTarget'] = $NetworkIcmpTarget
$coreOptions = New-Object 'System.Collections.ObjectModel.ReadOnlyDictionary[string,object]' $coreOptionValues

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

$processRunnerPath = Join-Path -Path $repositoryRoot -ChildPath 'scripts\process-runner.ps1'
if (-not (Test-Path -LiteralPath $processRunnerPath -PathType Leaf)) {
    throw "Missing process runner: $processRunnerPath"
}

. $PSScriptRoot\scripts\process-runner.ps1

function Get-WdtCollectionCompleteness {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    if (@($Results).Count -eq 0) { throw 'At least one module result is required.' }
    $values = @($Results | ForEach-Object { [string]$_.Completeness })
    if (@($values | Where-Object { $_ -eq 'Unavailable' }).Count -eq $values.Count) { return 'Unavailable' }
    if (@($values | Where-Object { $_ -eq 'Complete' }).Count -eq $values.Count) { return 'Complete' }
    return 'Partial'
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
    $Lines.Add(('Execution: {0}' -f $Result.Status))
    $Lines.Add(('Duration: {0:N2} s' -f $Result.Duration.TotalSeconds))
    $Lines.Add(('Completeness: {0}' -f $Result.Completeness))
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
    $Lines.Add(('- Execution: `{0}`' -f $Result.Status))
    $Lines.Add(('- Duration: `{0:N2} s`' -f $Result.Duration.TotalSeconds))
    $Lines.Add(('- Completeness: `{0}`' -f $Result.Completeness))
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

function Invoke-WdtReport {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$ModuleDefinitions,
        [Parameter(Mandatory = $true)]$CoreOptions,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [bool]$ExportMarkdown,
        [bool]$PrivacyMode,
        [bool]$SuppressConsoleOutput,
        [int]$ModuleTimeoutSeconds = 180
    )

    $startedAt = Get-Date
    $selectedChecks = @($ModuleDefinitions)
    if ($selectedChecks.Count -eq 0) {
        throw 'At least one diagnostic module must be selected.'
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
        $scriptArguments = @(Get-WdtModuleInvocationArguments -Definition $check -CoreOptions $CoreOptions)
        $results.Add((Invoke-DiagnosticScript -Title $check.Title -ScriptPath $check.EntryPoint -PowerShellPath $powerShellPath -RepositoryRoot $repositoryRoot -TimeoutSeconds $ModuleTimeoutSeconds -ScriptArguments $scriptArguments))
    }

    $privacyModeLabel = if ($PrivacyMode) { 'enabled' } else { 'disabled' }
    $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $elevationLabel = if ($isElevated) { 'Elevated' } else { 'Standard user' }
    $collectionCompleteness = Get-WdtCollectionCompleteness -Results @($results.ToArray())
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
    $textLines.Add(('Elevation     : {0}' -f $elevationLabel))
    $textLines.Add(('Collection completeness: {0}' -f $collectionCompleteness))
    $textLines.Add(('Output        : {0}' -f $displayTextReportPath))
    $textLines.Add(('Selected      : {0}' -f (($selectedChecks | ForEach-Object { $_.Title }) -join ', ')))
    Add-TextFindingsSummary -Lines $textLines -Summary $findingsSummary
    foreach ($result in $results) {
        Add-TextSection -Lines $textLines -Result $result
    }

    [System.IO.File]::WriteAllLines($textReportPath, $textLines, [System.Text.Encoding]::UTF8)
    if (-not $SuppressConsoleOutput) {
        Write-Host ("TXT report written: {0}" -f $displayTextReportPath)
    }

    $writtenMarkdownPath = $null
    if ($ExportMarkdown) {
        $markdownLines = New-Object System.Collections.Generic.List[string]
        $markdownLines.Add('# Windows Diagnostics Toolkit - Support Report')
        $markdownLines.Add('')
        $markdownLines.Add(('- Created at: `{0}`' -f $createdAt))
        $markdownLines.Add(('- Computer name: `{0}`' -f $displayComputerName))
        $markdownLines.Add(('- Mode: `read-only`'))
        $markdownLines.Add(('- Privacy mode: `{0}`' -f $privacyModeLabel))
        $markdownLines.Add(('- Elevation: `{0}`' -f $elevationLabel))
        $markdownLines.Add(('- Collection completeness: `{0}`' -f $collectionCompleteness))
        $markdownLines.Add(('- TXT report: `{0}`' -f $displayTextReportPath))
        $markdownLines.Add(('- Selected: `{0}`' -f (($selectedChecks | ForEach-Object { $_.Title }) -join ', ')))
        Add-MarkdownFindingsSummary -Lines $markdownLines -Summary $findingsSummary
        foreach ($result in $results) {
            Add-MarkdownSection -Lines $markdownLines -Result $result
        }

        [System.IO.File]::WriteAllLines($markdownReportPath, $markdownLines, [System.Text.Encoding]::UTF8)
        if (-not $SuppressConsoleOutput) {
            Write-Host ("Markdown report written: {0}" -f $displayMarkdownReportPath)
        }
        $writtenMarkdownPath = $markdownReportPath
    }

    $exitCode = if (($results | Where-Object { $_.ExitCode -ne 0 }).Count -gt 0) { 1 } else { 0 }
    if ($exitCode -ne 0 -and -not $SuppressConsoleOutput) {
        Write-Warning 'One or more diagnostics completed with a non-zero exit code. See the report for details.'
    }

    return [pscustomobject]@{
        ExitCode           = $exitCode
        TextReportPath     = $textReportPath
        MarkdownReportPath = $writtenMarkdownPath
        WarningCount       = $findingsSummary.WarningCount
        ErrorCount         = $findingsSummary.ErrorCount
        SelectedCount      = $selectedChecks.Count
        ElapsedTime        = ((Get-Date) - $startedAt)
    }
}

$legacySelections = [ordered]@{
    System      = [bool]$System
    Security    = [bool]$Security
    Performance = [bool]$Performance
    Network     = [bool]$Network
    Time        = [bool]$Time
    Disk        = [bool]$Disk
    Crashes     = [bool]$Crashes
    Events      = [bool]$Events
    Services    = [bool]$Services
    Updates     = [bool]$Updates
}

$missingLegacyIds = @($legacySelections.Keys | Where-Object { -not $registrySnapshot.ById.ContainsKey([string]$_) })
if ($missingLegacyIds.Count -gt 0) {
    throw ('Built-in module registry is missing legacy module(s): {0}' -f (($missingLegacyIds | Sort-Object) -join ', '))
}

$moduleIds = if ($PSBoundParameters.ContainsKey('Module')) { @($Module) } else { @() }
$hasLegacySelection = @($legacySelections.GetEnumerator() | Where-Object { [bool]$_.Value }).Count -gt 0
$hasExplicitSelection = $moduleIds.Count -gt 0 -or $hasLegacySelection
$selectedDefinitions = @(Resolve-WdtModuleSelection `
        -Registry $registrySnapshot `
        -ModuleIds $moduleIds `
        -LegacySelections $legacySelections `
        -AllRequested:([bool]$All))

$launchMode = Get-WdtLaunchMode `
    -InteractiveRequested ([bool]$Interactive) `
    -HasExplicitModuleSelection $hasExplicitSelection `
    -AllRequested ([bool]$All) `
    -IsInputRedirected ([System.Console]::IsInputRedirected)

if ($launchMode -eq 'InteractiveUnavailable') {
    Write-Host 'Interactive input is unavailable.' -ForegroundColor Red
    Write-Host 'Use -All or select one or more diagnostic modules.'
    exit 2
}

if ($launchMode -eq 'Interactive') {
    $tuiPath = Join-Path -Path $repositoryRoot -ChildPath 'scripts\tui.ps1'
    if (-not (Test-Path -LiteralPath $tuiPath -PathType Leaf)) {
        throw "Missing interactive helper: $tuiPath"
    }
    . $PSScriptRoot\scripts\tui.ps1

    $interactiveOutputDirectory = if ($PSBoundParameters.ContainsKey('OutputDirectory')) {
        $OutputDirectory
    }
    else {
        Join-Path -Path (Get-Location).Path -ChildPath 'WindowsDiagnosticsReports'
    }
    $initialSelection = if ($All -or $hasExplicitSelection) { @($selectedDefinitions | ForEach-Object { [string]$_.Id }) } else { $null }
    $interactiveExitCode = Invoke-WdtInteractiveSession `
        -RegistrySnapshot $registrySnapshot `
        -InitialSelection $initialSelection `
        -OutputDirectory $interactiveOutputDirectory `
        -ModuleTimeoutSeconds $ModuleTimeoutSeconds `
        -NoExternalNetworkTests ([bool]$NoExternalNetworkTests) `
        -NetworkDnsTestName $NetworkDnsTestName `
        -NetworkHttpsEndpoint $NetworkHttpsEndpoint `
        -NetworkIcmpTarget $NetworkIcmpTarget
    if ($interactiveExitCode -ne 0) {
        exit $interactiveExitCode
    }
    return
}

$reportResult = Invoke-WdtReport -ModuleDefinitions $selectedDefinitions -CoreOptions $coreOptions -OutputDirectory $OutputDirectory -ExportMarkdown:$ExportMarkdown -PrivacyMode:$PrivacyMode -ModuleTimeoutSeconds $ModuleTimeoutSeconds
if ($reportResult.ExitCode -ne 0) {
    exit $reportResult.ExitCode
}
