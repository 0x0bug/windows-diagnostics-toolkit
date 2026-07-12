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

function Get-WdtExecutionCompleteness {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'NonZeroExit', 'Timeout', 'LaunchError', 'Cancelled')]
        [string]$Status
    )

    switch ($Status) {
        'Success' { return 'Complete' }
        { $_ -in @('NonZeroExit', 'Timeout') } { return 'Partial' }
        default { return 'Unavailable' }
    }
}

function Get-WdtCollectionCompleteness {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    if (@($Results).Count -eq 0) { throw 'At least one module result is required.' }
    $values = @($Results | ForEach-Object { Get-WdtExecutionCompleteness -Status ([string]$_.Status) })
    if (@($values | Where-Object { $_ -eq 'Unavailable' }).Count -eq $values.Count) { return 'Unavailable' }
    if (@($values | Where-Object { $_ -eq 'Complete' }).Count -eq $values.Count) { return 'Complete' }
    return 'Partial'
}

function New-WdtStreamCaptureState {
    param([Parameter(Mandatory = $true)][System.IO.StreamReader]$Reader)

    $buffer = New-Object char[] 4096
    return [pscustomobject]@{
        Reader   = $Reader
        Buffer   = $buffer
        Task     = $Reader.ReadAsync($buffer, 0, $buffer.Length)
        Text     = New-Object System.Text.StringBuilder
        Complete = $false
        Error    = $null
    }
}

function Read-WdtCompletedStreamChunks {
    param([Parameter(Mandatory = $true)]$State)

    $madeProgress = $false
    while (-not $State.Complete -and $null -ne $State.Task -and $State.Task.IsCompleted) {
        $madeProgress = $true
        if ($State.Task.IsCanceled) {
            $State.Error = 'Stream read was cancelled.'
            $State.Complete = $true
            break
        }
        if ($State.Task.IsFaulted) {
            $State.Error = 'Stream read failed: {0}' -f $State.Task.Exception
            $State.Complete = $true
            break
        }

        try {
            $characterCount = [int]$State.Task.Result
        }
        catch {
            $State.Error = 'Stream read failed: {0}' -f $_.Exception.Message
            $State.Complete = $true
            break
        }

        if ($characterCount -eq 0) {
            $State.Complete = $true
            break
        }

        [void]$State.Text.Append($State.Buffer, 0, $characterCount)
        try {
            $State.Task = $State.Reader.ReadAsync($State.Buffer, 0, $State.Buffer.Length)
        }
        catch {
            $State.Error = 'Stream read failed: {0}' -f $_.Exception.Message
            $State.Complete = $true
        }
    }

    return $madeProgress
}

function Get-WdtProcessCreationKey {
    param($CreationDate)
    if ($null -eq $CreationDate) { return '' }
    try { return ([datetime]$CreationDate).ToString('o') }
    catch { return [string]$CreationDate }
}

function Test-WdtProcessIdentity {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        $Current
    )

    if ($null -eq $Current) { return 'NotFound' }
    if ([int]$Current.ProcessId -ne [int]$Expected.ProcessId) { return 'PidMismatch' }
    if (-not $Expected.IsRoot -and [int]$Current.ParentProcessId -ne [int]$Expected.ParentProcessId) { return 'ParentMismatch' }
    if ((Get-WdtProcessCreationKey -CreationDate $Current.CreationDate) -ne [string]$Expected.CreationKey) { return 'CreationTimeMismatch' }
    return 'Match'
}

function Get-WdtProcessTreeSnapshot {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$RootProcess)

    $items = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    try {
        $rootId = $RootProcess.Id
        $rootStartTime = $RootProcess.StartTime
    }
    catch {
        $errors.Add(('Root process identity is unavailable: {0}' -f $_.Exception.Message))
        return [pscustomobject]@{ Items = @(); Errors = @($errors.ToArray()); RootExited = $false }
    }

    try {
        $inventory = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 1 -ErrorAction Stop)
    }
    catch {
        $errors.Add(('Process inventory failed: {0}' -f $_.Exception.Message))
        return [pscustomobject]@{ Items = @(); Errors = @($errors.ToArray()); RootExited = $false }
    }

    $rootRecord = @($inventory | Where-Object { [int]$_.ProcessId -eq $rootId } | Select-Object -First 1)
    if ($rootRecord.Count -eq 0) {
        return [pscustomobject]@{ Items = @(); Errors = @(); RootExited = $true }
    }

    $rootCreationTime = [datetime]$rootRecord[0].CreationDate
    $rootDifferenceSeconds = ($rootCreationTime - $rootStartTime).TotalSeconds
    if ($rootDifferenceSeconds -lt 0) { $rootDifferenceSeconds = -$rootDifferenceSeconds }
    if ($rootDifferenceSeconds -gt 0.01) {
        $errors.Add('Root process creation time changed before cleanup inventory was captured.')
        return [pscustomobject]@{ Items = @(); Errors = @($errors.ToArray()); RootExited = $false }
    }

    $rootEntry = [pscustomobject]@{
        ProcessId = $rootId; ParentProcessId = [int]$rootRecord[0].ParentProcessId; Depth = 0; IsRoot = $true
        CreationKey = Get-WdtProcessCreationKey -CreationDate $rootRecord[0].CreationDate; StartTime = $rootStartTime
    }
    $items.Add($rootEntry)
    $byId = @{ $rootId = $rootEntry }

    $added = $true
    while ($added) {
        $added = $false
        foreach ($record in $inventory) {
            $processId = [int]$record.ProcessId
            $parentId = [int]$record.ParentProcessId
            if ($byId.ContainsKey($processId) -or -not $byId.ContainsKey($parentId)) { continue }
            $entry = [pscustomobject]@{
                ProcessId = $processId; ParentProcessId = $parentId; Depth = ([int]$byId[$parentId].Depth + 1); IsRoot = $false
                CreationKey = Get-WdtProcessCreationKey -CreationDate $record.CreationDate; StartTime = [datetime]$record.CreationDate
            }
            $byId[$processId] = $entry
            $items.Add($entry)
            $added = $true
        }
    }

    return [pscustomobject]@{ Items = @($items.ToArray()); Errors = @($errors.ToArray()); RootExited = $false }
}

function Test-WdtSnapshotMembership {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter(Mandatory = $true)]$SnapshotById,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch]$CleanupStopwatch,
        [Parameter(Mandatory = $true)][int]$CleanupTimeoutMilliseconds
    )

    $cursor = $Entry
    $isTarget = $true
    while ($null -ne $cursor) {
        if ($CleanupStopwatch.ElapsedMilliseconds -ge $CleanupTimeoutMilliseconds) { return 'TimedOut' }
        try {
            $current = @(Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $cursor.ProcessId) -OperationTimeoutSec 1 -ErrorAction Stop | Select-Object -First 1)
        }
        catch { return 'QueryFailed: {0}' -f $_.Exception.Message }
        $currentRecord = if ($current.Count -eq 0) { $null } else { $current[0] }
        $identity = Test-WdtProcessIdentity -Expected $cursor -Current $currentRecord
        if ($identity -eq 'NotFound') { return $(if ($isTarget) { 'TargetNotFound' } else { 'AncestorNotFound' }) }
        if ($identity -ne 'Match') { return $identity }
        if ($cursor.IsRoot) { return 'Match' }
        if (-not $SnapshotById.ContainsKey([int]$cursor.ParentProcessId)) { return 'SnapshotParentMissing' }
        $cursor = $SnapshotById[[int]$cursor.ParentProcessId]
        $isTarget = $false
    }
    return 'SnapshotParentMissing'
}

function Get-WdtProcessCleanupSummary {
    param([object[]]$Items, [string[]]$Errors, [bool]$TimedOut)
    $failureStatuses = @('IdentityMismatch', 'QueryFailed', 'TerminationFailed', 'StillRunning', 'SnapshotError')
    $failedItems = @($Items | Where-Object { $_.Status -in $failureStatuses })
    return [pscustomobject]@{
        Success = (-not $TimedOut -and @($Errors).Count -eq 0 -and $failedItems.Count -eq 0)
        TimedOut = $TimedOut
        AttemptedCount = @($Items | Where-Object { $_.Status -notin @('AlreadyExited', 'SkippedDeadline') }).Count
        TerminatedCount = @($Items | Where-Object { $_.Status -eq 'Terminated' }).Count
        AlreadyExitedCount = @($Items | Where-Object { $_.Status -eq 'AlreadyExited' }).Count
        Items = @($Items)
        Errors = @($Errors)
    }
}

function Stop-WdtProcessTree {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$RootProcess,
        [ValidateRange(100, 30000)][int]$CleanupTimeoutMilliseconds = 5000
    )

    $cleanupStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $itemResults = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $timedOut = $false
    $snapshot = Get-WdtProcessTreeSnapshot -RootProcess $RootProcess
    foreach ($snapshotError in @($snapshot.Errors)) { $errors.Add([string]$snapshotError) }
    if ($snapshot.RootExited) {
        $message = 'Root process exited before its descendants could be revalidated.'
        $errors.Add($message)
        $itemResults.Add([pscustomobject]@{ ProcessId = $RootProcess.Id; Depth = 0; Status = 'SnapshotError'; Message = $message })
    }
    elseif (@($snapshot.Items).Count -eq 0) {
        $itemResults.Add([pscustomobject]@{ ProcessId = $null; Depth = 0; Status = 'SnapshotError'; Message = 'No verified process-tree snapshot is available.' })
    }
    else {
        $snapshotById = @{}
        foreach ($entry in @($snapshot.Items)) { $snapshotById[[int]$entry.ProcessId] = $entry }
        foreach ($entry in @($snapshot.Items | Sort-Object -Property Depth -Descending)) {
            if ($cleanupStopwatch.ElapsedMilliseconds -ge $CleanupTimeoutMilliseconds) {
                $timedOut = $true
                $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = 'SkippedDeadline'; Message = 'Cleanup deadline reached.' })
                continue
            }

            $membership = Test-WdtSnapshotMembership -Entry $entry -SnapshotById $snapshotById -CleanupStopwatch $cleanupStopwatch -CleanupTimeoutMilliseconds $CleanupTimeoutMilliseconds
            if ($membership -eq 'TargetNotFound') {
                $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = 'AlreadyExited'; Message = 'Process exited before termination.' })
                continue
            }
            if ($membership -ne 'Match') {
                if ($membership -eq 'TimedOut') { $timedOut = $true }
                $status = if ($membership -like 'QueryFailed:*') { 'QueryFailed' } else { 'IdentityMismatch' }
                $message = 'Process ownership could not be revalidated: {0}' -f $membership
                $errors.Add(('PID {0}: {1}' -f $entry.ProcessId, $message))
                $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = $status; Message = $message })
                continue
            }

            $target = $null
            try {
                $target = [System.Diagnostics.Process]::GetProcessById([int]$entry.ProcessId)
                $actualStartTime = $target.StartTime
                $differenceSeconds = ($actualStartTime - [datetime]$entry.StartTime).TotalSeconds
                if ($differenceSeconds -lt 0) { $differenceSeconds = -$differenceSeconds }
                if ($differenceSeconds -gt 0.01) {
                    $message = 'Process creation time changed immediately before termination.'
                    $errors.Add(('PID {0}: {1}' -f $entry.ProcessId, $message))
                    $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = 'IdentityMismatch'; Message = $message })
                    continue
                }

                if ($cleanupStopwatch.ElapsedMilliseconds -ge $CleanupTimeoutMilliseconds) {
                    $timedOut = $true
                    $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = 'SkippedDeadline'; Message = 'Cleanup deadline reached immediately before termination.' })
                    continue
                }

                $target.Kill()
                $remainingMilliseconds = $CleanupTimeoutMilliseconds - [int]$cleanupStopwatch.ElapsedMilliseconds
                if ($remainingMilliseconds -lt 0) { $remainingMilliseconds = 0 }
                if ($remainingMilliseconds -gt 500) { $remainingMilliseconds = 500 }
                if ($remainingMilliseconds -gt 0 -and $target.WaitForExit($remainingMilliseconds)) {
                    $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = 'Terminated'; Message = 'Process terminated.' })
                }
                else {
                    $message = 'Process did not confirm exit before the cleanup deadline.'
                    $errors.Add(('PID {0}: {1}' -f $entry.ProcessId, $message))
                    $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = 'StillRunning'; Message = $message })
                }
            }
            catch [System.ArgumentException] {
                $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = 'AlreadyExited'; Message = 'Process exited before termination.' })
            }
            catch {
                $message = 'Termination failed: {0}' -f $_.Exception.Message
                $errors.Add(('PID {0}: {1}' -f $entry.ProcessId, $message))
                $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = 'TerminationFailed'; Message = $message })
            }
            finally {
                if ($null -ne $target) {
                    try { $target.Dispose() }
                    catch { $errors.Add(('PID {0}: process handle disposal failed: {1}' -f $entry.ProcessId, $_.Exception.Message)) }
                }
            }
        }
    }

    $summary = Get-WdtProcessCleanupSummary -Items @($itemResults.ToArray()) -Errors @($errors.ToArray()) -TimedOut $timedOut
    $cleanupStopwatch.Stop()
    $summary | Add-Member -MemberType NoteProperty -Name Duration -Value $cleanupStopwatch.Elapsed
    return $summary
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
        Cleanup     = $null
        OutputComplete = $true
    }

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        $result.ExitCode = 1
        $result.ErrorLines = @("Missing script: $ScriptPath")
        return Resolve-WdtDiagnosticResult -Result ([pscustomobject]$result)
    }

    $process = $null
    $processStarted = $false
    $stdoutState = $null
    $stderrState = $null
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
        $processStarted = $true
        $stdoutState = New-WdtStreamCaptureState -Reader $process.StandardOutput
        $stderrState = New-WdtStreamCaptureState -Reader $process.StandardError
        $processExited = $false
        while (-not $processExited -and $stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            [void](Read-WdtCompletedStreamChunks -State $stdoutState)
            [void](Read-WdtCompletedStreamChunks -State $stderrState)
            $processExited = $process.WaitForExit(25)
        }

        if (-not $processExited) {
            $result.ExitCode = 124
            $result.Status = 'Timeout'
            $result.ErrorLines = @("Module exceeded timeout of $TimeoutSeconds second(s).")
            try {
                $cleanup = Stop-WdtProcessTree -RootProcess $process
                $result.Cleanup = $cleanup
                if (-not $cleanup.Success) {
                    $cleanupMessage = 'Process-tree cleanup was incomplete: {0}' -f (($cleanup.Errors | Select-Object -First 5) -join '; ')
                    $result.ErrorLines += $cleanupMessage
                }
            }
            catch {
                $result.ErrorLines += ('Process-tree cleanup failed: {0}' -f $_.Exception.Message)
            }
        }
        else {
            $result.ExitCode = $process.ExitCode
            $result.Status = if ($process.ExitCode -eq 0) { 'Success' } else { 'NonZeroExit' }
        }

        $drainStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ((-not $stdoutState.Complete -or -not $stderrState.Complete) -and $drainStopwatch.ElapsedMilliseconds -lt 2000) {
            $stdoutProgress = Read-WdtCompletedStreamChunks -State $stdoutState
            $stderrProgress = Read-WdtCompletedStreamChunks -State $stderrState
            if (-not $stdoutProgress -and -not $stderrProgress) { Start-Sleep -Milliseconds 10 }
        }
        $drainStopwatch.Stop()
        [void](Read-WdtCompletedStreamChunks -State $stdoutState)
        [void](Read-WdtCompletedStreamChunks -State $stderrState)

        $result.OutputLines = @(Convert-TextToLines -Text $stdoutState.Text.ToString())
        $result.ErrorLines = @($result.ErrorLines) + @(Convert-TextToLines -Text $stderrState.Text.ToString())
        foreach ($streamState in @($stdoutState, $stderrState)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$streamState.Error)) { $result.ErrorLines += [string]$streamState.Error }
        }
        if (-not $stdoutState.Complete -or -not $stderrState.Complete) {
            $result.OutputComplete = $false
            $incompleteStreams = @()
            if (-not $stdoutState.Complete) { $incompleteStreams += 'stdout' }
            if (-not $stderrState.Complete) { $incompleteStreams += 'stderr' }
            $result.ErrorLines += ('Captured output is incomplete because stream drain did not finish within 2 seconds: {0}.' -f ($incompleteStreams -join ', '))
        }
    }
    catch {
        $primaryError = $_
        $secondaryErrors = @()
        if ($processStarted) {
            try {
                $cleanup = Stop-WdtProcessTree -RootProcess $process
                $result.Cleanup = $cleanup
                if (-not $cleanup.Success) { $secondaryErrors += ('Process-tree cleanup was incomplete: {0}' -f (($cleanup.Errors | Select-Object -First 5) -join '; ')) }
            }
            catch {
                $secondaryErrors += ('Process-tree cleanup failed: {0}' -f $_.Exception.Message)
            }
        }
        if ($result.Status -ne 'Timeout') {
            $result.ExitCode = 1
            $result.Status = if ($primaryError.Exception -is [System.Management.Automation.PipelineStoppedException]) { 'Cancelled' } else { 'LaunchError' }
        }
        $result.ErrorLines = @($result.ErrorLines) + @("Failed to run script: $($primaryError.Exception.Message)") + $secondaryErrors
    }
    finally {
        $stopwatch.Stop()
        $result.Duration = $stopwatch.Elapsed
        foreach ($streamState in @($stdoutState, $stderrState)) {
            if ($null -ne $streamState -and -not $streamState.Complete) {
                try { $streamState.Reader.Dispose() }
                catch { $result.ErrorLines += ('Failed to close an incomplete stream reader: {0}' -f $_.Exception.Message) }
            }
        }
        if ($null -ne $process) {
            try { $process.Dispose() }
            catch { $result.ErrorLines += ('Failed to dispose the child process handle: {0}' -f $_.Exception.Message) }
        }
    }

    $resolved = Resolve-WdtDiagnosticResult -Result ([pscustomobject]$result)
    $resolved.Completeness = Get-WdtExecutionCompleteness -Status $resolved.Status
    if ($resolved.Status -eq 'Timeout') {
        $resolved.Findings = @($resolved.Findings | Where-Object { $_.Code -ne 'MODULE_EXECUTION_FAILED' }) + @(
            New-WdtFindingObject -Module $resolved.Title -Severity ERROR -Code 'MODULE_EXECUTION_TIMEOUT' -Message 'The diagnostic module exceeded its execution timeout.' -Evidence ("TimeoutSeconds={0}; Duration={1:N1}s" -f $TimeoutSeconds, $resolved.Duration.TotalSeconds)
        )
    }
    if ($null -ne $resolved.Cleanup -and -not $resolved.Cleanup.Success) {
        $resolved.Findings = @($resolved.Findings) + @(
            New-WdtFindingObject -Module $resolved.Title -Severity ERROR -Code 'MODULE_PROCESS_CLEANUP_INCOMPLETE' -Message 'The diagnostic process tree could not be fully cleaned up within the bounded cleanup attempt.' -Evidence (($resolved.Cleanup.Errors | Select-Object -First 5) -join '; ')
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
    $interactiveExitCode = Invoke-WdtInteractiveSession `
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

$reportResult = Invoke-WdtReport -SelectedModules @($selectedModules.ToArray()) -OutputDirectory $OutputDirectory -ExportMarkdown:$ExportMarkdown -PrivacyMode:$PrivacyMode -ModuleTimeoutSeconds $ModuleTimeoutSeconds -NoExternalNetworkTests:$NoExternalNetworkTests -NetworkDnsTestName $NetworkDnsTestName -NetworkHttpsEndpoint $NetworkHttpsEndpoint -NetworkIcmpTarget $NetworkIcmpTarget
if ($reportResult.ExitCode -ne 0) {
    exit $reportResult.ExitCode
}
