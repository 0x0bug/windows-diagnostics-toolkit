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
    [string[]]$Module,
    [switch]$SaveSnapshot,
    [string]$BeforeSnapshot,
    [string]$AfterSnapshot,
    [ValidateSet('AppFailure','UnexpectedRestart')]
    [string]$IncidentSymptom,
    [string]$IncidentAt,
    [int]$IncidentBeforeMinutes = 30,
    [int]$IncidentAfterMinutes = 30
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$toolkitVersion = 'development'
$versionPath = Join-Path -Path $repositoryRoot -ChildPath 'VERSION'
if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
    $versionText = Get-Content -LiteralPath $versionPath -Raw
    if (-not [string]::IsNullOrWhiteSpace($versionText)) {
        $toolkitVersion = $versionText.Trim()
    }
}

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
. $PSScriptRoot\scripts\diagnostic-data.ps1
. $PSScriptRoot\scripts\snapshot.ps1
. $PSScriptRoot\scripts\snapshot-compare.ps1
. $PSScriptRoot\scripts\incident.ps1

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

function Get-WdtMarkdownFence {
    param([string[]]$ContentLines)

    $fenceLength = 3
    foreach ($line in @($ContentLines)) {
        foreach ($match in @([System.Text.RegularExpressions.Regex]::Matches([string]$line, '`+'))) {
            if ($match.Length -ge $fenceLength) { $fenceLength = $match.Length + 1 }
        }
    }

    return -join @(1..$fenceLength | ForEach-Object { '`' })
}

function Add-MarkdownSection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        $Result
    )

    $Lines.Add('')
    $markdownTitle = (ConvertTo-MarkdownInlineText -Text ([string]$Result.Title)) -replace '[\r\n]+', ' '
    $Lines.Add(('## {0}' -f $markdownTitle))
    $Lines.Add('')
    $Lines.Add('- Command:')
    $Lines.Add('')
    $commandLines = @([System.Text.RegularExpressions.Regex]::Split([string]$Result.Command, '\r?\n'))
    $commandFence = Get-WdtMarkdownFence -ContentLines $commandLines
    $Lines.Add($commandFence + 'text')
    if ($commandLines.Count -eq 0 -or ($commandLines.Count -eq 1 -and $commandLines[0].Length -eq 0)) {
        $Lines.Add('(empty command)')
    }
    else {
        foreach ($commandLine in $commandLines) {
            $Lines.Add($commandLine)
        }
    }
    $Lines.Add($commandFence)
    $Lines.Add('')
    $Lines.Add(('- Exit code: `{0}`' -f $Result.ExitCode))
    $Lines.Add(('- Execution: `{0}`' -f $Result.Status))
    $Lines.Add(('- Duration: `{0:N2} s`' -f $Result.Duration.TotalSeconds))
    $Lines.Add(('- Completeness: `{0}`' -f $Result.Completeness))
    $Lines.Add('')
    $fence = Get-WdtMarkdownFence -ContentLines (@($Result.OutputLines) + @($Result.ErrorLines))
    $Lines.Add($fence + 'text')

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

    $Lines.Add($fence)
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

function Get-WdtUniqueReportPaths {
    param(
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [bool]$ExportMarkdown,
        [string]$Prefix = 'WindowsDiagnosticsReport'
    )

    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $reportBaseName = '{0}-{1}-{2}' -f $Prefix, $timestamp, [System.Guid]::NewGuid().ToString('N')
        $textPath = Join-Path -Path $OutputDirectory -ChildPath ($reportBaseName + '.txt')
        $markdownPath = Join-Path -Path $OutputDirectory -ChildPath ($reportBaseName + '.md')
        if (Test-Path -LiteralPath $textPath) { continue }
        if ($ExportMarkdown -and (Test-Path -LiteralPath $markdownPath)) { continue }
        return [pscustomobject]@{ TextPath = $textPath; MarkdownPath = $markdownPath }
    }

    throw 'Could not allocate a unique report filename after 10 attempts.'
}

function Invoke-WdtReport {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$ModuleDefinitions,
        [Parameter(Mandatory = $true)]$CoreOptions,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [bool]$ExportMarkdown,
        [bool]$PrivacyMode,
        [bool]$SuppressConsoleOutput,
        [int]$ModuleTimeoutSeconds = 180,
        [bool]$SaveSnapshot = $false
    )

    $startedAt = Get-Date
    $selectedChecks = @($ModuleDefinitions)
    if ($selectedChecks.Count -eq 0) {
        throw 'At least one diagnostic module must be selected.'
    }

    $windowStart=$null; $windowEnd=$null
    if ($SaveSnapshot) {
        Assert-WdtSnapshotModules @($selectedChecks | ForEach-Object { [string]$_.Id })
        $windowEnd=ConvertTo-WdtDataUtcText ([datetime]::UtcNow)
        $windowStart=ConvertTo-WdtDataUtcText (([datetimeoffset]$windowEnd).AddDays(-7))
    }

    $resolvedOutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if (-not (Test-Path -LiteralPath $resolvedOutputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null
    }

    $reportPaths = Get-WdtUniqueReportPaths -OutputDirectory $resolvedOutputDirectory -ExportMarkdown:$ExportMarkdown
    $textReportPath = $reportPaths.TextPath
    $markdownReportPath = $reportPaths.MarkdownPath

    $powerShellPath = Get-CurrentPowerShellPath
    $createdAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($check in $selectedChecks) {
        $scriptArguments = @(Get-WdtModuleInvocationArguments -Definition $check -CoreOptions $CoreOptions)
        $dataParameters=@{}
        if ($SaveSnapshot) { $dataParameters=@{CollectData=$true;ModuleId=$check.Id;DataStartUtc=$windowStart;DataEndUtc=$windowEnd} }
        $results.Add((Invoke-DiagnosticScript -Title $check.Title -ScriptPath $check.EntryPoint -PowerShellPath $powerShellPath -RepositoryRoot $repositoryRoot -TimeoutSeconds $ModuleTimeoutSeconds -ScriptArguments $scriptArguments @dataParameters))
    }
    $collectionFinishedUtc=ConvertTo-WdtDataUtcText ([datetime]::UtcNow)

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
    $snapshotPath=$null
    $snapshotActionFailed=$false
    if ($SaveSnapshot) {
        $snapshot=New-WdtSnapshot -ToolkitVersion $toolkitVersion -ModuleIds @($selectedChecks | ForEach-Object { [string]$_.Id }) -Results @($results.ToArray()) -CollectionStartedUtc $startedAt -CollectionFinishedUtc $collectionFinishedUtc -WindowStartUtc $windowStart -WindowEndUtc $windowEnd -PrivacyMode $PrivacyMode
        $snapshotPath=Write-WdtSnapshot -Snapshot $snapshot -OutputDirectory $resolvedOutputDirectory -Context $redactionContext
        $snapshotActionFailed=@($results | Where-Object { $null -eq $_.Data -or $_.DataStatus -eq 'NotCollected' -or $_.DataErrors.Count -gt 0 }).Count -gt 0
        if (-not $SuppressConsoleOutput) { Write-Host ('JSON snapshot written: {0}' -f (Protect-WdtDataString $snapshotPath $redactionContext)) }
    }

    $textLines = New-Object System.Collections.Generic.List[string]
    $textLines.Add('Windows Diagnostics Toolkit - Support Report')
    $textLines.Add(('Toolkit version : {0}' -f $toolkitVersion))
    $textLines.Add(('Created at    : {0}' -f $createdAt))
    $textLines.Add(('Computer name : {0}' -f $displayComputerName))
    $textLines.Add(('Mode          : read-only'))
    $textLines.Add(('Privacy mode  : {0}' -f $privacyModeLabel))
    $textLines.Add(('Elevation     : {0}' -f $elevationLabel))
    $textLines.Add(('Collection completeness: {0}' -f $collectionCompleteness))
    $textLines.Add(('Output        : {0}' -f $displayTextReportPath))
    $textLines.Add(('Selected      : {0}' -f (($selectedChecks | ForEach-Object { $_.Title }) -join ', ')))
    if ($SaveSnapshot) {
        $textLines.Add(('Snapshot      : {0}' -f (Protect-WdtDataString $snapshotPath $redactionContext)))
        $textLines.Add(('History window [UTC start,end): {0} / {1}' -f $windowStart,$windowEnd))
        $textLines.Add('Current configuration/inventory describes collection time. History retention may be unknown.')
        $textLines.Add(('Structured data status: {0}' -f (($selectedChecks | ForEach-Object -Begin { $dataIndex=0 } -Process { $label='{0}={1}' -f $_.Id,$results[$dataIndex].DataStatus; $dataIndex++; $label }) -join ', ')))
    }
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
        $markdownLines.Add(('- Toolkit version : {0}' -f $toolkitVersion))
        $markdownLines.Add(('- Created at: `{0}`' -f $createdAt))
        $markdownLines.Add(('- Computer name: `{0}`' -f $displayComputerName))
        $markdownLines.Add(('- Mode: `read-only`'))
        $markdownLines.Add(('- Privacy mode: `{0}`' -f $privacyModeLabel))
        $markdownLines.Add(('- Elevation: `{0}`' -f $elevationLabel))
        $markdownLines.Add(('- Collection completeness: `{0}`' -f $collectionCompleteness))
        $markdownLines.Add(('- TXT report: `{0}`' -f $displayTextReportPath))
        $markdownLines.Add(('- Selected: `{0}`' -f (($selectedChecks | ForEach-Object { $_.Title }) -join ', ')))
        if ($SaveSnapshot) {
            $markdownLines.Add(('- Snapshot: `{0}`' -f (Protect-WdtDataString $snapshotPath $redactionContext)))
            $markdownLines.Add(('- History window [UTC start,end): `{0}` / `{1}`' -f $windowStart,$windowEnd))
            $markdownLines.Add('- Current configuration/inventory describes collection time. History retention may be unknown.')
            $markdownLines.Add(('- Structured data status: {0}' -f (($selectedChecks | ForEach-Object -Begin { $dataIndex=0 } -Process { $label='{0}={1}' -f $_.Id,$results[$dataIndex].DataStatus; $dataIndex++; $label }) -join ', ')))
        }
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

    $exitCode = if (($results | Where-Object { $_.ExitCode -ne 0 }).Count -gt 0 -or $snapshotActionFailed) { 1 } else { 0 }
    if ($snapshotActionFailed -and -not $SuppressConsoleOutput) { Write-Warning 'Snapshot collection did not receive a complete valid data protocol. See structured data status and source limitations.' }
    if ($exitCode -ne 0 -and -not $SuppressConsoleOutput) {
        Write-Warning 'One or more diagnostics completed with a non-zero exit code. See the report for details.'
    }

    return [pscustomobject]@{
        ExitCode           = $exitCode
        TextReportPath     = $textReportPath
        MarkdownReportPath = $writtenMarkdownPath
        SnapshotPath       = $snapshotPath
        WarningCount       = $findingsSummary.WarningCount
        ErrorCount         = $findingsSummary.ErrorCount
        SelectedCount      = $selectedChecks.Count
        ElapsedTime        = ((Get-Date) - $startedAt)
    }
}

function Invoke-WdtSnapshotComparison {
    param([string]$BeforePath,[string]$AfterPath,[string]$OutputDirectory,[bool]$PrivacyMode,[bool]$ExportMarkdown)
    $before=Read-WdtSnapshot -LiteralPath $BeforePath
    $after=Read-WdtSnapshot -LiteralPath $AfterPath
    $context=$null
    if ($PrivacyMode -or $before.PrivacyMode -or $after.PrivacyMode) { $context=New-WdtRedactionContext }
    $comparison=Compare-WdtSnapshots -Before $before -After $after -PrivacyMode $PrivacyMode -Context $context
    $resolvedOutputDirectory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if (-not (Test-Path -LiteralPath $resolvedOutputDirectory -PathType Container)) { New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null }
    $paths=Get-WdtUniqueReportPaths -OutputDirectory $resolvedOutputDirectory -ExportMarkdown $ExportMarkdown -Prefix 'WindowsDiagnosticsComparison'
    $textReportPath=$paths.TextPath; $markdownReportPath=$paths.MarkdownPath
    $textLines=@(Get-WdtSnapshotComparisonLines -Comparison $comparison)
    [System.IO.File]::WriteAllLines($textReportPath, $textLines, [System.Text.Encoding]::UTF8)
    Write-Host ('TXT comparison written: {0}' -f (Protect-WdtDataString $textReportPath $context))
    if ($ExportMarkdown) {
        $markdownLines=@(Get-WdtSnapshotComparisonLines -Comparison $comparison -Markdown)
        [System.IO.File]::WriteAllLines($markdownReportPath, $markdownLines, [System.Text.Encoding]::UTF8)
        Write-Host ('Markdown comparison written: {0}' -f (Protect-WdtDataString $markdownReportPath $context))
    }
}

function Invoke-WdtIncident {
    param($Window,[string]$OutputDirectory,[bool]$PrivacyMode,[bool]$ExportMarkdown,[int]$ModuleTimeoutSeconds=180)
    $window=Assert-WdtIncidentWindow $Window
    $checks=@(Resolve-WdtModuleSelection -Registry $registrySnapshot -ModuleIds @('Crashes','Events','Updates'))
    $started=ConvertTo-WdtDataUtcText ([datetime]::UtcNow)
    $results=New-Object System.Collections.Generic.List[object]
    foreach ($check in $checks) {
        $arguments=@(Get-WdtModuleInvocationArguments -Definition $check -CoreOptions $coreOptions)
        $results.Add((Invoke-DiagnosticScript -Title $check.Title -ScriptPath $check.EntryPoint -PowerShellPath (Get-CurrentPowerShellPath) -RepositoryRoot $repositoryRoot -TimeoutSeconds $ModuleTimeoutSeconds -ScriptArguments $arguments -CollectData -ModuleId $check.Id -DataStartUtc $window.StartUtc -DataEndUtc $window.EndUtc))
    }
    $finished=ConvertTo-WdtDataUtcText ([datetime]::UtcNow)
    $context=$null
    if ($PrivacyMode) { $context=New-WdtRedactionContext }
    $incident=New-WdtIncident -Window $window -Results @($results.ToArray()) -ToolkitVersion $toolkitVersion -CollectionStartedUtc $started -CollectionFinishedUtc $finished -PrivacyMode $PrivacyMode -Context $context
    $textLines=@(Get-WdtIncidentLines -Incident $incident)
    # Only projected diagnostic text reaches disk; captured legacy output stays
    # in memory and is not a source of incident facts or a second report.
    try {
        $resolvedOutputDirectory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
        if (-not (Test-Path -LiteralPath $resolvedOutputDirectory -PathType Container)) { New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null }
        $paths=Get-WdtUniqueReportPaths -OutputDirectory $resolvedOutputDirectory -ExportMarkdown $ExportMarkdown -Prefix 'WindowsDiagnosticsIncident'
        $textReportPath=$paths.TextPath; $markdownReportPath=$paths.MarkdownPath
        [System.IO.File]::WriteAllLines($textReportPath, $textLines, [System.Text.Encoding]::UTF8)
        if ($ExportMarkdown) {
            $fence=Get-WdtMarkdownFence -ContentLines $textLines
            $markdownLines=@('# Incident Investigation','',($fence+'text'))+$textLines+@($fence)
            [System.IO.File]::WriteAllLines($markdownReportPath, $markdownLines, [System.Text.Encoding]::UTF8)
        }
    } catch { throw 'Could not write WDT incident report.' }
    Write-Host ('TXT incident written: {0}' -f (Protect-WdtDataString $textReportPath $context))
    if ($ExportMarkdown) { Write-Host ('Markdown incident written: {0}' -f (Protect-WdtDataString $markdownReportPath $context)) }
    if ($incident.ExitCode -ne 0) { Write-Warning 'Incident collection had an execution or machine-data protocol failure. Review source coverage and limitations.' }
    return [pscustomobject]@{ExitCode=$incident.ExitCode;TextReportPath=$textReportPath;MarkdownReportPath=$(if ($ExportMarkdown) { $markdownReportPath } else { $null });Incident=$incident}
}

$hasIncidentRequest=@('IncidentSymptom','IncidentAt','IncidentBeforeMinutes','IncidentAfterMinutes' | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count -gt 0
if ($hasIncidentRequest) {
    $incidentAllowed=@('IncidentSymptom','IncidentAt','IncidentBeforeMinutes','IncidentAfterMinutes','OutputDirectory','ExportMarkdown','PrivacyMode','ModuleTimeoutSeconds','Verbose','Debug','ErrorAction','WarningAction','InformationAction','ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable')
    foreach ($parameterName in $PSBoundParameters.Keys) { if ($parameterName -notin $incidentAllowed) { throw 'Incident investigation cannot be combined with module selection, snapshots, interactive or network options.' } }
    if (-not $PSBoundParameters.ContainsKey('IncidentSymptom') -or -not $PSBoundParameters.ContainsKey('IncidentAt')) { throw 'IncidentSymptom and IncidentAt are required together.' }
    $incidentWindow=Resolve-WdtIncidentWindow -Symptom $IncidentSymptom -At $IncidentAt -BeforeMinutes $IncidentBeforeMinutes -AfterMinutes $IncidentAfterMinutes
    $incidentResult=Invoke-WdtIncident -Window $incidentWindow -OutputDirectory $OutputDirectory -PrivacyMode ([bool]$PrivacyMode) -ExportMarkdown ([bool]$ExportMarkdown) -ModuleTimeoutSeconds $ModuleTimeoutSeconds
    if ($incidentResult.ExitCode -ne 0) { exit $incidentResult.ExitCode }
    return
}

$hasSnapshotPair=$PSBoundParameters.ContainsKey('BeforeSnapshot') -or $PSBoundParameters.ContainsKey('AfterSnapshot')
if ($hasSnapshotPair) {
    if ([string]::IsNullOrWhiteSpace($BeforeSnapshot) -or [string]::IsNullOrWhiteSpace($AfterSnapshot)) { throw 'BeforeSnapshot and AfterSnapshot are required together.' }
    $offlineAllowed=@('BeforeSnapshot','AfterSnapshot','OutputDirectory','ExportMarkdown','PrivacyMode','Verbose','Debug','ErrorAction','WarningAction','InformationAction','ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable')
    foreach ($parameterName in $PSBoundParameters.Keys) { if ($parameterName -notin $offlineAllowed) { throw 'Snapshot comparison cannot be combined with live collection or interactive options.' } }
    Invoke-WdtSnapshotComparison -BeforePath $BeforeSnapshot -AfterPath $AfterSnapshot -OutputDirectory $OutputDirectory -PrivacyMode ([bool]$PrivacyMode) -ExportMarkdown ([bool]$ExportMarkdown)
    return
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
if ($SaveSnapshot -and ($All -or $Interactive -or -not $hasExplicitSelection)) { throw 'SaveSnapshot requires an explicit supported module selection and cannot be combined with All or Interactive.' }
$selectedDefinitions = @(Resolve-WdtModuleSelection `
        -Registry $registrySnapshot `
        -ModuleIds $moduleIds `
        -LegacySelections $legacySelections `
        -AllRequested:([bool]$All))
if ($SaveSnapshot) { Assert-WdtSnapshotModules @($selectedDefinitions | ForEach-Object { [string]$_.Id }) }

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

$reportResult = Invoke-WdtReport -ModuleDefinitions $selectedDefinitions -CoreOptions $coreOptions -OutputDirectory $OutputDirectory -ExportMarkdown:$ExportMarkdown -PrivacyMode:$PrivacyMode -ModuleTimeoutSeconds $ModuleTimeoutSeconds -SaveSnapshot:([bool]$SaveSnapshot)
if ($reportResult.ExitCode -ne 0) {
    exit $reportResult.ExitCode
}
