[CmdletBinding()]
param(
    [switch]$IncludeRunning,

    [ValidateRange(1, 500)]
    [int]$MaxItems = 50,

    [switch]$IncludeStartup,

    [switch]$IncludeScheduledTasks
)

$ErrorActionPreference = 'Stop'

. $PSScriptRoot\..\..\scripts\report-common.ps1

# A stopped service is not a failure by itself because Windows services can be
# started or stopped by trigger. RpcSs is the only curated critical-service rule.
# https://learn.microsoft.com/en-us/windows/win32/services/service-trigger-events
# Win32_Service documents ExitCode 1077 as "no attempts to start ... since boot";
# that value is context, not a service failure.
# https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-service
# https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/disable-rpc-service-windows-process-not-work

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

    if ([string]$Service.Name -eq 'RpcSs' -and [string]$Service.StartMode -eq 'Disabled') {
        return 'ConfirmedProblem'
    }

    $exitCode = 0L
    try {
        if ($null -ne $Service.ExitCode) {
            $exitCode = [long]$Service.ExitCode
        }
    }
    catch {
        return 'Suspicious'
    }

    if ($exitCode -notin @(0, 1077)) {
        return 'ConfirmedProblem'
    }

    if ([string]$Service.State -in @('Start Pending', 'Stop Pending', 'Continue Pending', 'Pause Pending')) {
        return 'Suspicious'
    }

    if ([string]$Service.StartMode -eq 'Auto' -and [string]$Service.State -eq 'Stopped') {
        return 'Indeterminate'
    }

    return 'Normal'
}

function Get-StartupSourceDefinitions {
    $startupFolderSuffix = 'Microsoft\Windows\Start Menu\Programs\Startup'
    return @(
        [pscustomobject]@{
            SourceType       = 'Registry'
            Location         = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            ApprovalLocation = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        },
        [pscustomobject]@{
            SourceType       = 'Registry'
            Location         = 'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
            ApprovalLocation = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        },
        [pscustomobject]@{
            SourceType       = 'Registry'
            Location         = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
            ApprovalLocation = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        },
        [pscustomobject]@{
            SourceType       = 'Registry'
            Location         = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
            ApprovalLocation = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
        },
        [pscustomobject]@{
            SourceType       = 'StartupFolder'
            Location         = Join-Path -Path $env:APPDATA -ChildPath $startupFolderSuffix
            ApprovalLocation = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        },
        [pscustomobject]@{
            SourceType       = 'StartupFolder'
            Location         = Join-Path -Path $env:ProgramData -ChildPath $startupFolderSuffix
            ApprovalLocation = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
        }
    )
}

function ConvertFrom-StartupApprovedValue {
    param($Value)

    # StartupApproved is an undocumented binary contract. Accept only the two
    # confirmed 12-byte state prefixes and keep every other shape conservative.
    if ($Value -isnot [byte[]] -or $Value.Length -ne 12) {
        return 'Unknown'
    }

    if ($Value[1] -ne 0 -or $Value[2] -ne 0 -or $Value[3] -ne 0) {
        return 'Unknown'
    }

    if ($Value[0] -eq 2) { return 'Enabled' }
    if ($Value[0] -eq 3) { return 'Disabled' }
    return 'Unknown'
}

function Get-StartupApprovalInventory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Path   = $Path
            Exists = $false
            Values = $values
            Error  = $null
        }
    }

    try {
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        foreach ($property in @($item.PSObject.Properties | Where-Object { $_.Name -notin @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') })) {
            $values[$property.Name] = $property.Value
        }

        return [pscustomobject]@{
            Path   = $Path
            Exists = $true
            Values = $values
            Error  = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Path   = $Path
            Exists = $true
            Values = $values
            Error  = $_.Exception.Message
        }
    }
}

function Resolve-StartupEntryState {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$ApprovalInventory
    )

    $path = [string]$ApprovalInventory.Path
    if (-not [string]::IsNullOrWhiteSpace([string]$ApprovalInventory.Error)) {
        return [pscustomobject]@{ State = 'Unknown'; StateSource = "StartupApproved read failed: $path" }
    }

    if (-not $ApprovalInventory.Exists) {
        return [pscustomobject]@{ State = 'Unknown'; StateSource = "StartupApproved key missing: $path" }
    }

    if (-not $ApprovalInventory.Values.ContainsKey($Name)) {
        return [pscustomobject]@{ State = 'Unknown'; StateSource = "StartupApproved value missing: $path" }
    }

    $state = ConvertFrom-StartupApprovedValue -Value $ApprovalInventory.Values[$Name]
    if ($state -eq 'Unknown') {
        return [pscustomobject]@{ State = 'Unknown'; StateSource = "StartupApproved value unrecognized: $path" }
    }

    return [pscustomobject]@{ State = $state; StateSource = $path }
}

function Get-StartupRegistrySourceInventory {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        $ApprovalInventory
    )

    $entries = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    if ($null -eq $ApprovalInventory) {
        $ApprovalInventory = Get-StartupApprovalInventory -Path $Definition.ApprovalLocation
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$approvalInventory.Error)) {
        $errors.Add([pscustomobject]@{ Path = $approvalInventory.Path; Error = $approvalInventory.Error })
    }

    try {
        if (Test-Path -LiteralPath $Definition.Location) {
            $item = Get-ItemProperty -LiteralPath $Definition.Location -ErrorAction Stop
            foreach ($property in @($item.PSObject.Properties | Where-Object { $_.Name -notin @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') })) {
                $state = Resolve-StartupEntryState -Name $property.Name -ApprovalInventory $approvalInventory
                $entries.Add([pscustomobject]@{
                    State       = $state.State
                    StateSource = $state.StateSource
                    SourceType  = $Definition.SourceType
                    Location    = $Definition.Location
                    Name        = $property.Name
                    Command     = [string]$property.Value
                })
            }
        }
    }
    catch {
        $errors.Add([pscustomobject]@{ Path = $Definition.Location; Error = $_.Exception.Message })
    }

    return [pscustomobject]@{ Entries = @($entries.ToArray()); Errors = @($errors.ToArray()) }
}

function Get-StartupFolderSourceInventory {
    param(
        [Parameter(Mandatory = $true)]$Definition,
        $ApprovalInventory
    )

    $entries = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    if ($null -eq $ApprovalInventory) {
        $ApprovalInventory = Get-StartupApprovalInventory -Path $Definition.ApprovalLocation
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$approvalInventory.Error)) {
        $errors.Add([pscustomobject]@{ Path = $approvalInventory.Path; Error = $approvalInventory.Error })
    }

    try {
        if (Test-Path -LiteralPath $Definition.Location -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $Definition.Location -Force -File -ErrorAction Stop)) {
                $state = Resolve-StartupEntryState -Name $file.Name -ApprovalInventory $approvalInventory
                $entries.Add([pscustomobject]@{
                    State       = $state.State
                    StateSource = $state.StateSource
                    SourceType  = $Definition.SourceType
                    Location    = $Definition.Location
                    Name        = $file.Name
                    Command     = $file.FullName
                })
            }
        }
    }
    catch {
        $errors.Add([pscustomobject]@{ Path = $Definition.Location; Error = $_.Exception.Message })
    }

    return [pscustomobject]@{ Entries = @($entries.ToArray()); Errors = @($errors.ToArray()) }
}

function Merge-StartupInventory {
    param([object[]]$SourceInventories)

    $entries = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    foreach ($inventory in @($SourceInventories)) {
        foreach ($entry in @($inventory.Entries)) { $entries.Add($entry) }
        foreach ($errorItem in @($inventory.Errors)) { $errors.Add($errorItem) }
    }

    return [pscustomobject]@{ Entries = @($entries.ToArray()); Errors = @($errors.ToArray()) }
}

function Get-StartupEntriesForDisplay {
    param(
        [object[]]$Entries,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    $indexedEntries = for ($index = 0; $index -lt @($Entries).Count; $index++) {
        $entry = @($Entries)[$index]
        $stateRank = if ($entry.State -eq 'Enabled') { 0 } elseif ($entry.State -eq 'Disabled') { 1 } else { 2 }
        [pscustomobject]@{
            Entry         = $entry
            StateRank     = $stateRank
            SourceType    = [string]$entry.SourceType
            Location      = [string]$entry.Location
            Name          = [string]$entry.Name
            Command       = [string]$entry.Command
            OriginalIndex = $index
        }
    }

    return @($indexedEntries | Sort-Object -Property StateRank, SourceType, Location, Name, Command, OriginalIndex | Select-Object -First $Limit | ForEach-Object { $_.Entry })
}

function Get-StartupEntryInventory {
    $sourceInventories = New-Object System.Collections.Generic.List[object]
    foreach ($definition in @(Get-StartupSourceDefinitions)) {
        if ($definition.SourceType -eq 'Registry') {
            $sourceInventories.Add((Get-StartupRegistrySourceInventory -Definition $definition))
        }
        else {
            $sourceInventories.Add((Get-StartupFolderSourceInventory -Definition $definition))
        }
    }

    return Merge-StartupInventory -SourceInventories @($sourceInventories.ToArray())
}

function Write-StartupEntryRows {
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)][int]$Limit
    )

    $entries = @($Inventory.Entries)
    $shownEntries = @(Get-StartupEntriesForDisplay -Entries $entries -Limit $Limit)
    Write-ItemLimitNote -Shown $shownEntries.Count -Total $entries.Count
    Write-Host 'A registered startup entry is not necessarily active. State is reported only when StartupApproved contains a recognized value.'
    Write-Host ''

    if ($shownEntries.Count -eq 0) {
        Write-Host 'No startup entries found.'
    }
    else {
        foreach ($entry in $shownEntries) {
            Write-Host ('State               : {0}' -f $entry.State)
            Write-Host ('State source        : {0}' -f (ConvertTo-SafeSingleLine -Value $entry.StateSource))
            Write-Host ('Source type         : {0}' -f $entry.SourceType)
            Write-Host ('Location            : {0}' -f (ConvertTo-SafeSingleLine -Value $entry.Location))
            Write-Host ('Name                : {0}' -f (ConvertTo-SafeSingleLine -Value $entry.Name))
            Write-Host ('Startup Command Line: {0}' -f (ConvertTo-SafeSingleLine -Value $entry.Command))
            Write-Host ''
        }
    }

    foreach ($errorItem in @($Inventory.Errors)) {
        Write-Host ("Startup source unavailable (context only): {0} - {1}" -f $errorItem.Path, $errorItem.Error)
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

$suspiciousServiceStates = @(
    $services |
        Where-Object { (Get-ServiceDiagnosticState -Service $_) -eq 'Suspicious' } |
        Sort-Object -Property State, Name
)

$confirmedServiceProblems = @(
    $services |
        Where-Object { (Get-ServiceDiagnosticState -Service $_) -eq 'ConfirmedProblem' } |
        Sort-Object -Property Name
)

$nonZeroExitCodeServices = @(
    $services |
        Where-Object {
            $exitCode = $_.ExitCode -as [long]
            $null -ne $exitCode -and $exitCode -notin @(0, 1077)
        }
)

$disabledCriticalServices = @(
    $services |
        Where-Object { [string]$_.Name -eq 'RpcSs' -and [string]$_.StartMode -eq 'Disabled' } |
        Sort-Object -Property Name
)

$runningServices = @(
    $services |
        Where-Object { $_.State -eq 'Running' } |
        Sort-Object -Property Name
)

if ($null -ne $serviceInventory.Error) {
    Write-WdtFinding -Severity WARN -Code 'SERVICE_INVENTORY_UNAVAILABLE' -Message 'Services assessment could not be completed because the Win32_Service inventory was unavailable.' -Evidence (ConvertTo-SafeSingleLine -Value $serviceInventory.Error)
}

if ($nonZeroExitCodeServices.Count -gt 0) {
    $serviceExitCodeEvidence = @(
        $nonZeroExitCodeServices |
            Select-Object -First 10 |
            ForEach-Object { '{0}={1} ({2}), ExitCode={3}' -f $_.Name, $_.State, $_.StartMode, $_.ExitCode }
    ) -join '; '
    Write-WdtFinding -Severity WARN -Code 'SERVICE_EXIT_CODE_NONZERO' -Message ('{0} service(s) report an actionable non-zero service exit code.' -f $nonZeroExitCodeServices.Count) -Evidence $serviceExitCodeEvidence
}

if ($disabledCriticalServices.Count -gt 0) {
    $criticalServiceEvidence = @(
        $disabledCriticalServices |
            ForEach-Object { '{0}={1} ({2})' -f $_.Name, $_.State, $_.StartMode }
    ) -join '; '
    Write-WdtFinding -Severity WARN -Code 'CRITICAL_SERVICE_DISABLED' -Message 'The Remote Procedure Call service is disabled.' -Evidence $criticalServiceEvidence
}

Write-Section 'Summary'
if ($null -ne $serviceInventory.Error) {
    Write-Host ('Services inventory: unavailable - {0}' -f $serviceInventory.Error)
}
else {
    Write-Host ('Total services                 : {0}' -f $services.Count)
    Write-Host ('Running services               : {0}' -f $runningServices.Count)
    Write-Host ('Auto + Stopped (Indeterminate) : {0}' -f $automaticNotRunning.Count)
    Write-Host ('Pending states (Suspicious)     : {0}' -f $suspiciousServiceStates.Count)
    Write-Host ('Confirmed service problems     : {0}' -f $confirmedServiceProblems.Count)
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

Write-Section 'Pending Service States (Suspicious Context)'
if ($null -ne $serviceInventory.Error) {
    Write-Host 'Skipped because service inventory is unavailable.'
}
else {
    Write-Host 'A pending state is a transition snapshot and does not create a finding by itself.'
    Write-ServiceRows -Services $suspiciousServiceStates -Limit $MaxItems
}

Write-Section 'Confirmed Service Problems'
if ($null -ne $serviceInventory.Error) {
    Write-Host 'Skipped because service inventory is unavailable.'
}
else {
    Write-ServiceRows -Services $confirmedServiceProblems -Limit $MaxItems
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
    Write-StartupEntryRows -Inventory $startupInventory -Limit $MaxItems
}

Write-Section 'Scheduled Tasks With Non-Zero Last Result (Context)'
if (-not $IncludeScheduledTasks) {
    Write-Host 'Skipped. Use -IncludeScheduledTasks to include read-only scheduled task checks.'
}
else {
    $taskInventory = Get-ScheduledTaskInventory

    if ($taskInventory.Unavailable) {
        Write-Host ('Unavailable (context only): {0}' -f $taskInventory.Error)
    }
    elseif ($null -ne $taskInventory.Error) {
        Write-Host ('Skipped because scheduled tasks are unavailable (context only): {0}' -f $taskInventory.Error)
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

        foreach ($errorItem in @($taskInventory.Errors | Select-Object -First $MaxItems)) {
            Write-Host ("Scheduled task info unavailable (context only): {0}{1} - {2}" -f $errorItem.TaskPath, $errorItem.TaskName, $errorItem.Error)
        }
    }
}
