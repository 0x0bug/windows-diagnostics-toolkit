[CmdletBinding()]
param(
    [switch]$IncludeRunning,

    [ValidateRange(1, 500)]
    [int]$MaxItems = 50,

    [switch]$IncludeStartup,

    [switch]$IncludeScheduledTasks
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\report-common.ps1

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Write-Host ''
    Write-Host "== $Title =="
}

function Write-ItemLimitNote {
    param(
        [Parameter(Mandatory = $true)][int]$Shown,
        [Parameter(Mandatory = $true)][int]$Total
    )

    if ($Total -gt $Shown) {
        Write-Host ("Showing {0} of {1} item(s). Use -MaxItems to adjust the limit." -f $Shown, $Total)
        Write-Host ''
    }
}

function ConvertTo-SafeSingleLine {
    param(
        [string]$Value,
        [int]$MaxLength = 180
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'None'
    }

    $singleLine = (($Value -replace '\s+', ' ').Trim())
    if ($singleLine.Length -le $MaxLength) {
        return $singleLine
    }

    return ($singleLine.Substring(0, $MaxLength - 3) + '...')
}

function Get-ServiceInventory {
    try {
        return [pscustomobject]@{
            Services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
            Error    = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Services = @()
            Error    = $_.Exception.Message
        }
    }
}

function Get-ServiceDiagnosticState {
    param([Parameter(Mandatory = $true)]$Service)

    if ([string]$Service.State -in @('Start Pending', 'Stop Pending', 'Continue Pending', 'Pause Pending')) {
        return 'WarnPending'
    }
    if ([int]$Service.ExitCode -ne 0) { return 'WarnExitCode' }
    if ([string]$Service.StartMode -eq 'Auto' -and [string]$Service.State -eq 'Stopped') {
        return 'Indeterminate'
    }
    return 'Normal'
}

function Get-StartupEntryInventory {
    $registryPaths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )

    $entries = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    foreach ($path in $registryPaths) {
        try {
            if (-not (Test-Path -LiteralPath $path)) {
                $errors.Add([pscustomobject]@{
                    Path  = $path
                    Error = 'Path not found'
                })
                continue
            }

            $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            $properties = $item.PSObject.Properties |
                Where-Object { $_.Name -notlike 'PS*' }

            foreach ($property in $properties) {
                $entries.Add([pscustomobject]@{
                    Location = $path
                    Name     = $property.Name
                    Command  = [string]$property.Value
                })
            }
        }
        catch {
            $errors.Add([pscustomobject]@{
                Path  = $path
                Error = $_.Exception.Message
            })
        }
    }

    return [pscustomobject]@{
        Entries = @($entries.ToArray())
        Errors  = @($errors.ToArray())
    }
}

function Get-ScheduledTaskInventory {
    $taskCommand = Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue
    $taskInfoCommand = Get-Command -Name Get-ScheduledTaskInfo -ErrorAction SilentlyContinue

    if ($null -eq $taskCommand -or $null -eq $taskInfoCommand) {
        return [pscustomobject]@{
            Tasks       = @()
            Error       = 'Get-ScheduledTask or Get-ScheduledTaskInfo is unavailable.'
            Unavailable = $true
        }
    }

    $tasks = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]

    try {
        $scheduledTasks = @(Get-ScheduledTask -ErrorAction Stop)
    }
    catch {
        return [pscustomobject]@{
            Tasks       = @()
            Error       = $_.Exception.Message
            Unavailable = $false
        }
    }

    foreach ($task in $scheduledTasks) {
        try {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
            if ($taskInfo.LastTaskResult -ne 0) {
                $tasks.Add([pscustomobject]@{
                    TaskName       = $task.TaskName
                    TaskPath       = $task.TaskPath
                    State          = $task.State
                    LastRunTime    = $taskInfo.LastRunTime
                    LastTaskResult = $taskInfo.LastTaskResult
                    NextRunTime    = $taskInfo.NextRunTime
                })
            }
        }
        catch {
            $errors.Add([pscustomobject]@{
                TaskName = $task.TaskName
                TaskPath = $task.TaskPath
                Error    = $_.Exception.Message
            })
        }
    }

    return [pscustomobject]@{
        Tasks       = @($tasks.ToArray())
        Errors      = @($errors.ToArray())
        Error       = $null
        Unavailable = $false
    }
}

function Write-ServiceRows {
    param(
        [object[]]$Services,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    $shown = @($Services | Select-Object -First $Limit)
    Write-ItemLimitNote -Shown $shown.Count -Total $Services.Count

    if ($shown.Count -eq 0) {
        Write-Host 'No matching services found.'
        return
    }

    foreach ($service in $shown) {
        Write-Host ('Name       : {0}' -f $service.Name)
        Write-Host ('DisplayName: {0}' -f $service.DisplayName)
        Write-Host ('State      : {0}' -f $service.State)
        Write-Host ('StartMode  : {0}' -f $service.StartMode)
        Write-Host ('ExitCode   : {0}' -f $service.ExitCode)
        Write-Host ('ProcessId  : {0}' -f $service.ProcessId)
        Write-Host ''
    }
}

Write-Host 'Windows Diagnostics Toolkit - Services Check'
Write-Host 'Mode: read-only'

$serviceInventory = Get-ServiceInventory
$services = @($serviceInventory.Services)

$automaticNotRunning = @(
    $services |
        Where-Object { (Get-ServiceDiagnosticState -Service $_) -eq 'Indeterminate' } |
        Sort-Object -Property Name
)

$nonOkServiceStates = @(
    $services |
        Where-Object { (Get-ServiceDiagnosticState -Service $_) -like 'Warn*' } |
        Sort-Object -Property State, Name
)

$runningServices = @(
    $services |
        Where-Object { $_.State -eq 'Running' } |
        Sort-Object -Property Name
)

if ($null -ne $serviceInventory.Error) {
    Write-WdtFinding -Severity WARN -Code 'SERVICE_INVENTORY_UNAVAILABLE' -Message 'The Windows service inventory could not be read.' -Evidence (ConvertTo-SafeSingleLine -Value $serviceInventory.Error)
}
else {
    $serviceStateIssues = @($nonOkServiceStates | Sort-Object -Property Name -Unique)

    if ($serviceStateIssues.Count -gt 0) {
        $serviceIssueEvidence = @(
            $serviceStateIssues |
                Select-Object -First 10 |
                ForEach-Object { '{0}={1} ({2})' -f $_.Name, $_.State, $_.StartMode }
        ) -join '; '

        Write-WdtFinding -Severity WARN -Code 'SERVICE_STATE_CONFIRMED' -Message ('{0} service(s) have a pending state or non-zero service exit code.' -f $serviceStateIssues.Count) -Evidence $serviceIssueEvidence
    }
}

Write-Section 'Summary'
if ($null -ne $serviceInventory.Error) {
    Write-Host ('Services inventory: unavailable - {0}' -f $serviceInventory.Error)
}
else {
    Write-Host ('Total services                 : {0}' -f $services.Count)
    Write-Host ('Running services               : {0}' -f $runningServices.Count)
    Write-Host ('Auto + Stopped (Indeterminate) : {0}' -f $automaticNotRunning.Count)
    Write-Host ('Confirmed service issues       : {0}' -f $nonOkServiceStates.Count)
}

Write-Host ('Startup entries included       : {0}' -f [bool]$IncludeStartup)
Write-Host ('Scheduled tasks included       : {0}' -f [bool]$IncludeScheduledTasks)

Write-Section 'Automatic Stopped Services (Indeterminate)'
if ($null -ne $serviceInventory.Error) {
    Write-Host 'Skipped because service inventory is unavailable.'
}
else {
    Write-Host 'Stopped automatic services can be trigger-start, delayed, conditional, or intentionally idle; this state alone is not a warning.'
    Write-ServiceRows -Services $automaticNotRunning -Limit $MaxItems
}

Write-Section 'Pending States or Non-Zero Exit Codes'
if ($null -ne $serviceInventory.Error) {
    Write-Host 'Skipped because service inventory is unavailable.'
}
else {
    Write-ServiceRows -Services $nonOkServiceStates -Limit $MaxItems
}

if ($IncludeRunning -and $null -eq $serviceInventory.Error) {
    Write-Section 'Running Services'
    Write-ServiceRows -Services $runningServices -Limit $MaxItems
}

Write-Section 'Startup Entries'
if (-not $IncludeStartup) {
    Write-Host 'Skipped. Use -IncludeStartup to include read-only startup entry checks.'
}
else {
    $startupInventory = Get-StartupEntryInventory
    $startupEntries = @($startupInventory.Entries | Sort-Object -Property Location, Name)
    $shownStartupEntries = @($startupEntries | Select-Object -First $MaxItems)
    $startupSourceErrors = @($startupInventory.Errors | Where-Object { $_.Error -ne 'Path not found' })

    if ($startupSourceErrors.Count -gt 0) {
        $startupErrorEvidence = @(
            $startupSourceErrors |
                ForEach-Object { '{0}: {1}' -f $_.Path, (ConvertTo-SafeSingleLine -Value $_.Error) }
        ) -join '; '

        Write-WdtFinding -Severity WARN -Code 'STARTUP_SOURCE_UNAVAILABLE' -Message ('{0} startup source(s) could not be read.' -f $startupSourceErrors.Count) -Evidence $startupErrorEvidence
    }

    Write-ItemLimitNote -Shown $shownStartupEntries.Count -Total $startupEntries.Count

    if ($shownStartupEntries.Count -eq 0) {
        Write-Host 'No startup entries found.'
    }
    else {
        foreach ($entry in $shownStartupEntries) {
            Write-Host ('Location: {0}' -f $entry.Location)
            Write-Host ('Name    : {0}' -f $entry.Name)
            Write-Host ('Command : {0}' -f (ConvertTo-SafeSingleLine -Value $entry.Command))
            Write-Host ''
        }
    }

    foreach ($errorItem in @($startupInventory.Errors)) {
        Write-Warning ("Startup source unavailable: {0} - {1}" -f $errorItem.Path, $errorItem.Error)
    }
}

Write-Section 'Scheduled Tasks With Non-Zero Last Result'
if (-not $IncludeScheduledTasks) {
    Write-Host 'Skipped. Use -IncludeScheduledTasks to include read-only scheduled task checks.'
}
else {
    $taskInventory = Get-ScheduledTaskInventory

    if ($taskInventory.Unavailable) {
        Write-WdtFinding -Severity WARN -Code 'SCHEDULED_TASK_SOURCE_UNAVAILABLE' -Message 'Scheduled task diagnostics are unavailable.' -Evidence (ConvertTo-SafeSingleLine -Value $taskInventory.Error)
        Write-Host ('Unavailable: {0}' -f $taskInventory.Error)
    }
    elseif ($null -ne $taskInventory.Error) {
        Write-WdtFinding -Severity WARN -Code 'SCHEDULED_TASK_SOURCE_UNAVAILABLE' -Message 'The scheduled task inventory could not be read.' -Evidence (ConvertTo-SafeSingleLine -Value $taskInventory.Error)
        Write-Host ('Skipped because scheduled tasks are unavailable: {0}' -f $taskInventory.Error)
    }
    else {
        $tasks = @($taskInventory.Tasks | Sort-Object -Property TaskPath, TaskName)
        $shownTasks = @($tasks | Select-Object -First $MaxItems)

        Write-ItemLimitNote -Shown $shownTasks.Count -Total $tasks.Count

        if ($shownTasks.Count -eq 0) {
            Write-Host 'No scheduled tasks with non-zero LastTaskResult found.'
        }
        else {
            foreach ($task in $shownTasks) {
                Write-Host ('TaskName      : {0}' -f $task.TaskName)
                Write-Host ('TaskPath      : {0}' -f $task.TaskPath)
                Write-Host ('State         : {0}' -f $task.State)
                Write-Host ('LastRunTime   : {0}' -f $task.LastRunTime)
                Write-Host ('LastTaskResult: {0}' -f $task.LastTaskResult)
                Write-Host ('NextRunTime   : {0}' -f $task.NextRunTime)
                Write-Host ''
            }
        }

        if ($taskInventory.Errors.Count -gt 0) {
            $taskErrorEvidence = @(
                $taskInventory.Errors |
                    Select-Object -First 10 |
                    ForEach-Object { '{0}{1}: {2}' -f $_.TaskPath, $_.TaskName, (ConvertTo-SafeSingleLine -Value $_.Error) }
            ) -join '; '

            Write-WdtFinding -Severity WARN -Code 'SCHEDULED_TASK_SOURCE_UNAVAILABLE' -Message ('Details could not be read for {0} scheduled task(s).' -f $taskInventory.Errors.Count) -Evidence $taskErrorEvidence
        }

        foreach ($errorItem in @($taskInventory.Errors | Select-Object -First $MaxItems)) {
            Write-Warning ("Scheduled task info unavailable: {0}{1} - {2}" -f $errorItem.TaskPath, $errorItem.TaskName, $errorItem.Error)
        }
    }
}
