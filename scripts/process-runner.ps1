[CmdletBinding()]
param()

$script:WdtProcessRunnerConfig = [ordered]@{
    StreamBufferSize = 4096
    ProcessPollIntervalMilliseconds = 25
    StreamDrainPollIntervalMilliseconds = 10
    StreamDrainTimeoutMilliseconds = 2000
    CleanupTimeoutMilliseconds = 10000
    PerProcessExitWaitMilliseconds = 1500
    # CIM CreationDate and Process.StartTime can differ at sub-second precision.
    ProcessCreationTimeToleranceSeconds = 1.0
    CimOperationTimeoutSeconds = 2
}

$script:WdtRuntimeStatus = [ordered]@{
    Success = 'Success'
    NonZeroExit = 'NonZeroExit'
    Timeout = 'Timeout'
    LaunchError = 'LaunchError'
    Cancelled = 'Cancelled'
}

$script:WdtCleanupStatus = [ordered]@{
    Match = 'Match'
    NotFound = 'NotFound'
    PidMismatch = 'PidMismatch'
    ParentMismatch = 'ParentMismatch'
    CreationTimeMismatch = 'CreationTimeMismatch'
    TimedOut = 'TimedOut'
    QueryFailed = 'QueryFailed'
    TargetNotFound = 'TargetNotFound'
    AncestorNotFound = 'AncestorNotFound'
    SnapshotParentMissing = 'SnapshotParentMissing'
    IdentityMismatch = 'IdentityMismatch'
    AlreadyExited = 'AlreadyExited'
    SkippedDeadline = 'SkippedDeadline'
    SnapshotError = 'SnapshotError'
    Terminated = 'Terminated'
    StillRunning = 'StillRunning'
    TerminationFailed = 'TerminationFailed'
}

function New-WdtStatusResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowEmptyString()][string]$Message = ''
    )

    return [pscustomobject]@{ Status = $Status; Message = $Message }
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

function Get-WdtExecutionCompleteness {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [bool]$OutputComplete = $true
    )

    if ($Status -notin @($script:WdtRuntimeStatus.Values)) { throw "Unsupported runtime status: $Status" }
    if ($Status -eq $script:WdtRuntimeStatus.Success) { return $(if ($OutputComplete) { 'Complete' } else { 'Partial' }) }
    if ($Status -in @($script:WdtRuntimeStatus.NonZeroExit, $script:WdtRuntimeStatus.Timeout)) { return 'Partial' }
    return 'Unavailable'
}

function New-WdtStreamCaptureState {
    param([Parameter(Mandatory = $true)][System.IO.StreamReader]$Reader)

    $buffer = New-Object char[] $script:WdtProcessRunnerConfig.StreamBufferSize
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

    if ($null -eq $Current) { return New-WdtStatusResult -Status $script:WdtCleanupStatus.NotFound -Message 'Process no longer exists.' }
    if ([int]$Current.ProcessId -ne [int]$Expected.ProcessId) { return New-WdtStatusResult -Status $script:WdtCleanupStatus.PidMismatch -Message 'Process ID changed.' }
    if (-not $Expected.IsRoot -and [int]$Current.ParentProcessId -ne [int]$Expected.ParentProcessId) { return New-WdtStatusResult -Status $script:WdtCleanupStatus.ParentMismatch -Message 'Parent process ID changed.' }
    if ((Get-WdtProcessCreationKey -CreationDate $Current.CreationDate) -ne [string]$Expected.CreationKey) { return New-WdtStatusResult -Status $script:WdtCleanupStatus.CreationTimeMismatch -Message 'Process creation time changed.' }
    return New-WdtStatusResult -Status $script:WdtCleanupStatus.Match
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
        $inventory = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec $script:WdtProcessRunnerConfig.CimOperationTimeoutSeconds -ErrorAction Stop)
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
    if ($rootDifferenceSeconds -gt $script:WdtProcessRunnerConfig.ProcessCreationTimeToleranceSeconds) {
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
        if ($CleanupStopwatch.ElapsedMilliseconds -ge $CleanupTimeoutMilliseconds) { return New-WdtStatusResult -Status $script:WdtCleanupStatus.TimedOut -Message 'Cleanup deadline reached during identity validation.' }
        try {
            $current = @(Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $cursor.ProcessId) -OperationTimeoutSec $script:WdtProcessRunnerConfig.CimOperationTimeoutSeconds -ErrorAction Stop | Select-Object -First 1)
        }
        catch { return New-WdtStatusResult -Status $script:WdtCleanupStatus.QueryFailed -Message $_.Exception.Message }
        $currentRecord = if ($current.Count -eq 0) { $null } else { $current[0] }
        $identity = Test-WdtProcessIdentity -Expected $cursor -Current $currentRecord
        if ($identity.Status -eq $script:WdtCleanupStatus.NotFound) {
            $status = if ($isTarget) { $script:WdtCleanupStatus.TargetNotFound } else { $script:WdtCleanupStatus.AncestorNotFound }
            return New-WdtStatusResult -Status $status -Message $identity.Message
        }
        if ($identity.Status -ne $script:WdtCleanupStatus.Match) { return $identity }
        if ($cursor.IsRoot) { return New-WdtStatusResult -Status $script:WdtCleanupStatus.Match }
        if (-not $SnapshotById.ContainsKey([int]$cursor.ParentProcessId)) { return New-WdtStatusResult -Status $script:WdtCleanupStatus.SnapshotParentMissing -Message 'Expected parent is absent from the cleanup snapshot.' }
        $cursor = $SnapshotById[[int]$cursor.ParentProcessId]
        $isTarget = $false
    }
    return New-WdtStatusResult -Status $script:WdtCleanupStatus.SnapshotParentMissing -Message 'Expected parent is absent from the cleanup snapshot.'
}

function Get-WdtProcessCleanupSummary {
    param([object[]]$Items, [string[]]$Errors, [bool]$TimedOut)
    $failureStatuses = @(
        $script:WdtCleanupStatus.IdentityMismatch,
        $script:WdtCleanupStatus.QueryFailed,
        $script:WdtCleanupStatus.TerminationFailed,
        $script:WdtCleanupStatus.StillRunning,
        $script:WdtCleanupStatus.SnapshotError
    )
    $failedItems = @($Items | Where-Object { $_.Status -in $failureStatuses })
    return [pscustomobject]@{
        Success = (-not $TimedOut -and @($Errors).Count -eq 0 -and $failedItems.Count -eq 0)
        TimedOut = $TimedOut
        AttemptedCount = @($Items | Where-Object { $_.Status -notin @($script:WdtCleanupStatus.AlreadyExited, $script:WdtCleanupStatus.SkippedDeadline) }).Count
        TerminatedCount = @($Items | Where-Object { $_.Status -eq $script:WdtCleanupStatus.Terminated }).Count
        AlreadyExitedCount = @($Items | Where-Object { $_.Status -eq $script:WdtCleanupStatus.AlreadyExited }).Count
        Items = @($Items)
        Errors = @($Errors)
    }
}

function Stop-WdtProcessTree {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$RootProcess,
        [ValidateRange(100, 30000)][int]$CleanupTimeoutMilliseconds = $script:WdtProcessRunnerConfig.CleanupTimeoutMilliseconds
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
        $itemResults.Add([pscustomobject]@{ ProcessId = $RootProcess.Id; Depth = 0; Status = $script:WdtCleanupStatus.SnapshotError; Message = $message })
    }
    elseif (@($snapshot.Items).Count -eq 0) {
        $itemResults.Add([pscustomobject]@{ ProcessId = $null; Depth = 0; Status = $script:WdtCleanupStatus.SnapshotError; Message = 'No verified process-tree snapshot is available.' })
    }
    else {
        $snapshotById = @{}
        foreach ($entry in @($snapshot.Items)) { $snapshotById[[int]$entry.ProcessId] = $entry }
        foreach ($entry in @($snapshot.Items | Sort-Object -Property Depth -Descending)) {
            if ($cleanupStopwatch.ElapsedMilliseconds -ge $CleanupTimeoutMilliseconds) {
                $timedOut = $true
                $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = $script:WdtCleanupStatus.SkippedDeadline; Message = 'Cleanup deadline reached.' })
                continue
            }

            $membership = Test-WdtSnapshotMembership -Entry $entry -SnapshotById $snapshotById -CleanupStopwatch $cleanupStopwatch -CleanupTimeoutMilliseconds $CleanupTimeoutMilliseconds
            if ($membership.Status -eq $script:WdtCleanupStatus.TargetNotFound) {
                $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = $script:WdtCleanupStatus.AlreadyExited; Message = 'Process exited before termination.' })
                continue
            }
            if ($membership.Status -ne $script:WdtCleanupStatus.Match) {
                if ($membership.Status -eq $script:WdtCleanupStatus.TimedOut) { $timedOut = $true }
                $status = if ($membership.Status -eq $script:WdtCleanupStatus.QueryFailed) { $script:WdtCleanupStatus.QueryFailed } else { $script:WdtCleanupStatus.IdentityMismatch }
                $message = 'Process ownership could not be revalidated ({0}): {1}' -f $membership.Status, $membership.Message
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
                if ($differenceSeconds -gt $script:WdtProcessRunnerConfig.ProcessCreationTimeToleranceSeconds) {
                    $message = 'Process creation time changed immediately before termination.'
                    $errors.Add(('PID {0}: {1}' -f $entry.ProcessId, $message))
                    $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = $script:WdtCleanupStatus.IdentityMismatch; Message = $message })
                    continue
                }

                if ($cleanupStopwatch.ElapsedMilliseconds -ge $CleanupTimeoutMilliseconds) {
                    $timedOut = $true
                    $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = $script:WdtCleanupStatus.SkippedDeadline; Message = 'Cleanup deadline reached immediately before termination.' })
                    continue
                }

                $target.Kill()
                $remainingMilliseconds = $CleanupTimeoutMilliseconds - [int]$cleanupStopwatch.ElapsedMilliseconds
                if ($remainingMilliseconds -lt 0) { $remainingMilliseconds = 0 }
                if ($remainingMilliseconds -gt $script:WdtProcessRunnerConfig.PerProcessExitWaitMilliseconds) { $remainingMilliseconds = $script:WdtProcessRunnerConfig.PerProcessExitWaitMilliseconds }
                if ($remainingMilliseconds -gt 0 -and $target.WaitForExit($remainingMilliseconds)) {
                    $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = $script:WdtCleanupStatus.Terminated; Message = 'Process terminated.' })
                }
                else {
                    $message = 'Process did not confirm exit before the cleanup deadline.'
                    $errors.Add(('PID {0}: {1}' -f $entry.ProcessId, $message))
                    $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = $script:WdtCleanupStatus.StillRunning; Message = $message })
                }
            }
            catch [System.ArgumentException] {
                $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = $script:WdtCleanupStatus.AlreadyExited; Message = 'Process exited before termination.' })
            }
            catch {
                $message = 'Termination failed: {0}' -f $_.Exception.Message
                $errors.Add(('PID {0}: {1}' -f $entry.ProcessId, $message))
                $itemResults.Add([pscustomobject]@{ ProcessId = $entry.ProcessId; Depth = $entry.Depth; Status = $script:WdtCleanupStatus.TerminationFailed; Message = $message })
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
        Status      = $script:WdtRuntimeStatus.LaunchError
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
    $findingNonce = $null
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
        $findingNonce = [System.Guid]::NewGuid().ToString('N')
        $escapedScriptPath = $ScriptPath.Replace("'", "''")
        $escapedArguments = @($ScriptArguments | ForEach-Object {
                $argument = [string]$_
                if ($argument -match '^-[A-Za-z][A-Za-z0-9]*$') { $argument }
                else { "'" + $argument.Replace("'", "''") + "'" }
            })
        $commandText = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; & '$escapedScriptPath' $($escapedArguments -join ' ') 6>&1"
        $encodedCommand = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandText))

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $PowerShellPath
        $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand ' + $encodedCommand
        $startInfo.WorkingDirectory = $RepositoryRoot
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        $startInfo.StandardOutputEncoding = $utf8NoBom
        $startInfo.StandardErrorEncoding = $utf8NoBom
        $startInfo.EnvironmentVariables['WDT_FINDING_PROTOCOL'] = '1'

        $startInfo.EnvironmentVariables['WDT_FINDING_NONCE'] = $findingNonce
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
            $processExited = $process.WaitForExit($script:WdtProcessRunnerConfig.ProcessPollIntervalMilliseconds)
        }

        if (-not $processExited) {
            $result.ExitCode = 124
            $result.Status = $script:WdtRuntimeStatus.Timeout
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
            $result.Status = if ($process.ExitCode -eq 0) { $script:WdtRuntimeStatus.Success } else { $script:WdtRuntimeStatus.NonZeroExit }
        }

        $drainStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ((-not $stdoutState.Complete -or -not $stderrState.Complete) -and $drainStopwatch.ElapsedMilliseconds -lt $script:WdtProcessRunnerConfig.StreamDrainTimeoutMilliseconds) {
            $stdoutProgress = Read-WdtCompletedStreamChunks -State $stdoutState
            $stderrProgress = Read-WdtCompletedStreamChunks -State $stderrState
            if (-not $stdoutProgress -and -not $stderrProgress) { Start-Sleep -Milliseconds $script:WdtProcessRunnerConfig.StreamDrainPollIntervalMilliseconds }
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
            $drainTimeoutSeconds = $script:WdtProcessRunnerConfig.StreamDrainTimeoutMilliseconds / 1000
            $result.ErrorLines += ('Captured output is incomplete because stream drain did not finish within {0} seconds: {1}.' -f $drainTimeoutSeconds, ($incompleteStreams -join ', '))
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
        if ($result.Status -ne $script:WdtRuntimeStatus.Timeout) {
            $result.ExitCode = 1
            $result.Status = if ($primaryError.Exception -is [System.Management.Automation.PipelineStoppedException]) { $script:WdtRuntimeStatus.Cancelled } else { $script:WdtRuntimeStatus.LaunchError }
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

    $resolved = Resolve-WdtDiagnosticResult -Result ([pscustomobject]$result) -FindingNonce $findingNonce
    $resolved.Completeness = Get-WdtExecutionCompleteness -Status $resolved.Status -OutputComplete $resolved.OutputComplete
    if ($resolved.Status -eq $script:WdtRuntimeStatus.Timeout) {
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
