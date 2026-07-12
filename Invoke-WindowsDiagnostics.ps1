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
    [string]$NetworkIcmpTarget = '1.1.1.1'
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$reportCommonPath = Join-Path -Path $repositoryRoot -ChildPath 'scripts\report-common.ps1'
if (-not (Test-Path -LiteralPath $reportCommonPath -PathType Leaf)) {
    throw "Missing report helper: $reportCommonPath"
}

. $PSScriptRoot\scripts\report-common.ps1

$catalogPath = Join-Path -Path $repositoryRoot -ChildPath 'scripts\diagnostic-catalog.ps1'
if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    throw "Missing diagnostic catalog: $catalogPath"
}

. $PSScriptRoot\scripts\diagnostic-catalog.ps1

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

function Stop-WdtProcessTree {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$RootProcess)

    $processIds = New-Object System.Collections.Generic.List[int]
    $processIds.Add($RootProcess.Id)
    for ($index = 0; $index -lt $processIds.Count; $index++) {
        try {
            foreach ($child in @(Get-CimInstance -ClassName Win32_Process -Filter ("ParentProcessId={0}" -f $processIds[$index]) -ErrorAction Stop)) {
                if ($child.ProcessId -notin $processIds) { $processIds.Add([int]$child.ProcessId) }
            }
        }
        catch { }
    }

    foreach ($processId in @($processIds.ToArray() | Sort-Object -Descending)) {
        try {
            $target = [System.Diagnostics.Process]::GetProcessById($processId)
            $target.Kill()
            $target.WaitForExit(5000) | Out-Null
            $target.Dispose()
        }
        catch { }
    }
}

function Invoke-DiagnosticScript {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [string[]]$ScriptArguments = @()
    )

    $result = [ordered]@{
        Title       = $Title
        Command     = '{0} -NoProfile -ExecutionPolicy Bypass -File {1}' -f (Split-Path -Leaf $PowerShellPath), (Get-RelativeDisplayPath -BasePath $RepositoryRoot -TargetPath $ScriptPath)
        ExitCode    = $null
        OutputLines = @()
        ErrorLines  = @()
        Status      = 'LaunchError'
        Duration    = [timespan]::Zero
        Completeness = 'Unavailable'
    }

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        $result.ExitCode = 1
        $result.ErrorLines = @("Missing script: $ScriptPath")
        return Resolve-WdtDiagnosticResult -Result ([pscustomobject]$result)
    }

    $process = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
        $escapedScriptPath = $ScriptPath.Replace("'", "''")
        $escapedArguments = @($ScriptArguments | ForEach-Object {
                $argument = [string]$_
                if ($argument -match '^-[A-Za-z][A-Za-z0-9]*$') { $argument }
                else { "'" + $argument.Replace("'", "''") + "'" }
            })
        $commandText = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & '$escapedScriptPath' $($escapedArguments -join ' ')"

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
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-WdtProcessTree -RootProcess $process
            $result.ExitCode = 124
            $result.Status = 'Timeout'
            $result.ErrorLines = @("Module exceeded timeout of $TimeoutSeconds second(s).")
        }
        else {
            $process.WaitForExit()
            $result.ExitCode = $process.ExitCode
            $result.Status = if ($process.ExitCode -eq 0) { 'Success' } else { 'NonZeroExit' }
        }

        $result.OutputLines = @(Convert-TextToLines -Text $stdoutTask.Result)
        $capturedErrors = @(Convert-TextToLines -Text $stderrTask.Result)
        $result.ErrorLines = @($result.ErrorLines) + $capturedErrors
        $result.Completeness = if ($result.Status -eq 'Success') { 'Complete' } else { 'Partial' }
    }
    catch {
        if ($null -ne $process -and -not $process.HasExited) { Stop-WdtProcessTree -RootProcess $process }
        $result.ExitCode = 1
        $result.Status = if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { 'Cancelled' } else { 'LaunchError' }
        $result.ErrorLines = @("Failed to run script: $($_.Exception.Message)")
    }
    finally {
        $stopwatch.Stop()
        $result.Duration = $stopwatch.Elapsed
        if ($null -ne $process) { $process.Dispose() }
    }

    $resolved = Resolve-WdtDiagnosticResult -Result ([pscustomobject]$result)
    if ($resolved.Status -eq 'LaunchError' -or $resolved.Status -eq 'Cancelled') {
        $resolved.Completeness = 'Unavailable'
    }
    elseif (@($resolved.Findings | Where-Object { $_.Code -match '(_UNAVAILABLE|_INCOMPLETE)$' }).Count -gt 0) {
        $resolved.Completeness = 'Partial'
    }
    if ($resolved.Status -eq 'Timeout') {
        $resolved.Findings = @($resolved.Findings | Where-Object { $_.Code -ne 'MODULE_EXECUTION_FAILED' }) + @(
            New-WdtFindingObject -Module $resolved.Title -Severity ERROR -Code 'MODULE_EXECUTION_TIMEOUT' -Message 'The diagnostic module exceeded its execution timeout.' -Evidence ("TimeoutSeconds={0}; Duration={1:N1}s" -f $TimeoutSeconds, $resolved.Duration.TotalSeconds)
        )
    }
    return $resolved
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
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SelectedModules,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [bool]$ExportMarkdown,
        [bool]$PrivacyMode,
        [bool]$SuppressConsoleOutput,
        [int]$ModuleTimeoutSeconds = 180,
        [bool]$NoExternalNetworkTests,
        [string]$NetworkDnsTestName = 'www.microsoft.com',
        [string]$NetworkHttpsEndpoint = 'https://www.microsoft.com/',
        [string]$NetworkIcmpTarget = '1.1.1.1'
    )

    $startedAt = Get-Date
    $selectedChecks = New-Object System.Collections.Generic.List[object]
    $checkDefinitions = @(Get-WdtDiagnosticDefinition)
    $knownModuleNames = @($checkDefinitions | ForEach-Object { $_.Name })
    $unknownModuleNames = @($SelectedModules | Where-Object { $_ -notin $knownModuleNames })
    if ($unknownModuleNames.Count -gt 0) {
        throw ('Unknown diagnostic module(s): {0}' -f ($unknownModuleNames -join ', '))
    }

    foreach ($definition in $checkDefinitions) {
        if ($definition.Name -in $SelectedModules) {
            $selectedChecks.Add([pscustomobject]@{
                    Title = $definition.Title
                    Path  = Join-Path -Path $repositoryRoot -ChildPath ("scripts\{0}" -f $definition.Script)
                    Name  = $definition.Name
                })
        }
    }

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
        $scriptArguments = @()
        if ($check.Name -eq 'Network') {
            if ($NoExternalNetworkTests) { $scriptArguments += '-NoExternalNetworkTests' }
            $scriptArguments += @('-DnsTestName', $NetworkDnsTestName, '-HttpsEndpoint', $NetworkHttpsEndpoint, '-IcmpTarget', $NetworkIcmpTarget)
        }
        if ($check.Name -eq 'Services') { $scriptArguments += @('-IncludeStartup', '-IncludeScheduledTasks') }
        $results.Add((Invoke-DiagnosticScript -Title $check.Title -ScriptPath $check.Path -PowerShellPath $powerShellPath -RepositoryRoot $repositoryRoot -TimeoutSeconds $ModuleTimeoutSeconds -ScriptArguments $scriptArguments))
    }

    $privacyModeLabel = if ($PrivacyMode) { 'enabled' } else { 'disabled' }
    $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $elevationLabel = if ($isElevated) { 'Elevated' } else { 'Standard user' }
    $limitedModules = @($results | Where-Object { $_.Completeness -ne 'Complete' } | ForEach-Object { $_.Title })
    $collectionCompleteness = if (($results | Where-Object { $_.Completeness -eq 'Unavailable' }).Count -gt 0) { 'Unavailable' } elseif ($limitedModules.Count -gt 0) { 'Partial' } else { 'Complete' }
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
    $textLines.Add(('Limited modules: {0}' -f $(if ($limitedModules.Count) { $limitedModules -join ', ' } else { 'None' })))
    $textLines.Add(('Unavailable data sources: {0}' -f $(if ($limitedModules.Count) { 'See limited module sections' } else { 'None reported' })))
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
        $markdownLines.Add(('- Limited modules: `{0}`' -f $(if ($limitedModules.Count) { $limitedModules -join ', ' } else { 'None' })))
        $markdownLines.Add(('- Unavailable data sources: `{0}`' -f $(if ($limitedModules.Count) { 'See limited module sections' } else { 'None reported' })))
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

$selectedModules = New-Object System.Collections.Generic.List[string]
foreach ($selection in @(
        [pscustomobject]@{ Name = 'System'; Enabled = $System },
        [pscustomobject]@{ Name = 'Security'; Enabled = $Security },
        [pscustomobject]@{ Name = 'Performance'; Enabled = $Performance },
        [pscustomobject]@{ Name = 'Network'; Enabled = $Network },
        [pscustomobject]@{ Name = 'Time'; Enabled = $Time },
        [pscustomobject]@{ Name = 'Disk'; Enabled = $Disk },
        [pscustomobject]@{ Name = 'Crashes'; Enabled = $Crashes },
        [pscustomobject]@{ Name = 'Events'; Enabled = $Events },
        [pscustomobject]@{ Name = 'Services'; Enabled = $Services },
        [pscustomobject]@{ Name = 'Updates'; Enabled = $Updates }
    )) {
    if ($selection.Enabled) {
        $selectedModules.Add($selection.Name)
    }
}

$hasExplicitSelection = $selectedModules.Count -gt 0
if ($All) {
    $selectedModules = New-Object System.Collections.Generic.List[string]
    foreach ($definition in @(Get-WdtDiagnosticDefinition)) {
        $selectedModules.Add($definition.Name)
    }
}

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
    $initialSelection = if ($All -or $hasExplicitSelection) { @($selectedModules.ToArray()) } else { $null }
    $interactiveExitCode = Invoke-WdtInteractiveSession -InitialSelection $initialSelection -OutputDirectory $interactiveOutputDirectory
    if ($interactiveExitCode -ne 0) {
        exit $interactiveExitCode
    }
    return
}

$reportResult = Invoke-WdtReport -SelectedModules @($selectedModules.ToArray()) -OutputDirectory $OutputDirectory -ExportMarkdown:$ExportMarkdown -PrivacyMode:$PrivacyMode -ModuleTimeoutSeconds $ModuleTimeoutSeconds -NoExternalNetworkTests:$NoExternalNetworkTests -NetworkDnsTestName $NetworkDnsTestName -NetworkHttpsEndpoint $NetworkHttpsEndpoint -NetworkIcmpTarget $NetworkIcmpTarget
if ($reportResult.ExitCode -ne 0) {
    exit $reportResult.ExitCode
}
