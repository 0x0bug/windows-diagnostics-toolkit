[CmdletBinding()]
param()

. $PSScriptRoot\report-common.ps1

# This helper deliberately performs no file I/O. Data stays in memory until the
# caller has projected it through the report's privacy context.
$script:WdtDataFrameLimit = 16384
$script:WdtDataItemLimit = 12000
$script:WdtDataCharacterLimit = 16777216

function ConvertTo-WdtDataUtcText {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -isnot [string] -and $Value -isnot [datetime] -and $Value -isnot [datetimeoffset]) { throw 'A timestamp has an invalid type.' }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { throw 'A timestamp has no known time zone.' }
        return ([datetimeoffset]$Value).UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        throw 'A timestamp must be ISO 8601 with an explicit offset.'
    }
    $time = [datetimeoffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
    return $time.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-WdtDataRequest {
    $enabled = $env:WDT_DATA_PROTOCOL -eq '1' -and $env:WDT_DATA_NONCE -match '^[a-fA-F0-9]{32}$'
    $start = $null; $end = $null
    if ($enabled) {
        $start = ConvertTo-WdtDataUtcText $env:WDT_DATA_START_UTC
        $end = ConvertTo-WdtDataUtcText $env:WDT_DATA_END_UTC
        if (($null -eq $start) -ne ($null -eq $end)) { throw 'Both data window boundaries are required.' }
        if ($null -ne $start -and [datetimeoffset]$start -ge [datetimeoffset]$end) { throw 'The data window must be nonempty.' }
    }
    return [pscustomobject]@{ Enabled = $enabled; StartUtc = $start; EndUtc = $end }
}

function New-WdtDataSource {
    param([string]$Id, [ValidateSet('Configuration','Inventory','History')][string]$Kind,
        [string]$Scope, [ValidateSet('Available','Partial','Unavailable','NotCollected')][string]$Availability = 'Available',
        [bool]$QueryComplete = $true, [bool]$Truncated = $false, $Limit = $null,
        [ValidateSet('Unknown','QueryWindow','CurrentState')][string]$Coverage = 'Unknown',
        $StartUtc = $null, $EndUtc = $null, [AllowNull()][string]$Error = $null)
    return [pscustomobject][ordered]@{
        Id=$Id; Kind=$Kind; Scope=$Scope; Availability=$Availability; QueryComplete=$QueryComplete
        Truncated=$Truncated; Limit=$Limit; Coverage=$Coverage
        StartUtc=(ConvertTo-WdtDataUtcText $StartUtc); EndUtc=(ConvertTo-WdtDataUtcText $EndUtc); Error=$Error
    }
}

function New-WdtDataFact {
    param([string]$Id, [ValidateSet('OsVersion','RebootIndicator','HotFix','CrashObservation','EventObservation','UpdateFailure')][string]$Type,
        [AllowNull()][string]$Key = $null, [ValidateSet('Semantic','SnapshotLocal')][string]$IdentityScope = 'Semantic',
        [ValidateSet('Known','Unknown','NotApplicable')][string]$ValueState = 'Known', $Values,
        [ValidateSet('Configuration','Inventory','Windowed')][string]$Comparison,
        [string[]]$SourceIds = @(), [string[]]$EvidenceIds = @())
    return [pscustomobject][ordered]@{
        Id=$Id; Type=$Type; Key=$Key; IdentityScope=$IdentityScope; ValueState=$ValueState
        Values=[pscustomobject]$Values; Comparison=$Comparison; SourceIds=@($SourceIds); EvidenceIds=@($EvidenceIds)
    }
}

function New-WdtDataEvidence {
    param([string]$Id, [string]$SourceId, $TimestampUtc = $null,
        [ValidateSet('Instant','Day','Unknown')][string]$TimePrecision = 'Unknown', $EndUtc = $null,
        [AllowNull()][string]$OriginalOffset = $null, [AllowNull()][string]$LogName = $null,
        [AllowNull()][string]$Provider = $null, $EventId = $null,
        [AllowNull()][string]$RecordId = $null, [AllowNull()][string]$ReportId = $null,
        [ValidateSet('Crash','Hang','BugCheck','Event','UpdateInstallationFailure','UpdateDownloadFailure','HotFix')][string]$Kind,
        [AllowNull()][string]$Component = $null, [AllowNull()][string]$FailureCode = $null,
        [AllowNull()][string]$Message = $null)
    return [pscustomobject][ordered]@{
        Id=$Id; SourceId=$SourceId; TimestampUtc=(ConvertTo-WdtDataUtcText $TimestampUtc)
        TimePrecision=$TimePrecision; EndUtc=(ConvertTo-WdtDataUtcText $EndUtc); OriginalOffset=$OriginalOffset
        LogName=$LogName; Provider=$Provider; EventId=$EventId; RecordId=$RecordId; ReportId=$ReportId
        Kind=$Kind; Component=$Component; FailureCode=$FailureCode; Message=$Message
    }
}

function New-WdtDiagnosticData {
    param([ValidateSet('System','Crashes','Events','Updates')][string]$ModuleId,
        $WindowStartUtc = $null, $WindowEndUtc = $null,
        [object[]]$Sources = @(), [object[]]$Facts = @(), [object[]]$Evidence = @())
    return [pscustomobject][ordered]@{
        SchemaVersion=1; ModuleId=$ModuleId; WindowStartUtc=(ConvertTo-WdtDataUtcText $WindowStartUtc)
        WindowEndUtc=(ConvertTo-WdtDataUtcText $WindowEndUtc); Sources=@($Sources); Facts=@($Facts); Evidence=@($Evidence)
    }
}

function Get-WdtDataAvailability {
    param([AllowNull()][string]$Error, [int]$Count = 0, [int]$Limit = 0)
    if (-not [string]::IsNullOrEmpty($Error)) { return 'Unavailable' }
    if ($Limit -gt 0 -and $Count -ge $Limit) { return 'Partial' }
    return 'Available'
}

function Get-WdtDataTimestamp {
    param($Value)
    try {
        $utc = ConvertTo-WdtDataUtcText $Value
        if ($null -ne $utc) {
            $offset = ([datetimeoffset]$Value).ToString('zzz', [Globalization.CultureInfo]::InvariantCulture)
            return [pscustomobject]@{Utc=$utc; Offset=$offset; Precision='Instant'}
        }
    }
    catch { }
    return [pscustomobject]@{Utc=$null; Offset=$null; Precision='Unknown'}
}

function Test-WdtDataInWindow {
    param($TimestampUtc, $StartUtc, $EndUtc)
    if ($null -eq $TimestampUtc) { return $true }
    $time = [datetimeoffset]$TimestampUtc
    return (($null -eq $StartUtc -or $time -ge [datetimeoffset]$StartUtc) -and ($null -eq $EndUtc -or $time -lt [datetimeoffset]$EndUtc))
}

function ConvertTo-WdtDataMessage {
    param([AllowNull()][string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return $null }
    # Secrets are removed before length limiting. Unknown oversized messages are
    # omitted rather than persisting an incomplete sensitive token.
    $safe = Protect-WdtCommandLineSecrets -Text (Protect-WdtSensitiveUrlText -Text $Message)
    if ($safe.Length -gt 8192) { return '[Message omitted: exceeds diagnostic data field limit.]' }
    return $safe
}

function Assert-WdtDataProperties {
    param($Object, [string[]]$Names)
    if ($null -eq $Object -or $Object -is [string] -or $Object -is [System.Array]) { throw 'Invalid data object.' }
    $actual = @($Object.PSObject.Properties | ForEach-Object Name)
    if ($actual.Count -ne $Names.Count) { throw 'Unexpected data properties.' }
    foreach ($name in $Names) { if ($actual -cnotcontains $name) { throw 'Missing required data property.' } }
}

function Assert-WdtDataText {
    param($Value, [bool]$Nullable = $false)
    if ($null -eq $Value -and $Nullable) { return }
    if ($Value -isnot [string] -or $Value.Length -gt 8192) { throw 'Invalid data string.' }
}

function Test-WdtDataInteger {
    param($Value)
    return (($Value -is [int] -or $Value -is [long]) -and $Value -ge [int]::MinValue -and $Value -le [int]::MaxValue)
}

function Assert-WdtDiagnosticData {
    param([Parameter(Mandatory=$true)]$Data)
    Assert-WdtDataProperties $Data @('SchemaVersion','ModuleId','WindowStartUtc','WindowEndUtc','Sources','Facts','Evidence')
    Assert-WdtDataText $Data.ModuleId
    if (-not (Test-WdtDataInteger $Data.SchemaVersion) -or $Data.SchemaVersion -ne 1 -or $Data.ModuleId -cnotin @('System','Crashes','Events','Updates')) { throw 'Unsupported data schema or module.' }
    foreach ($name in @('Sources','Facts','Evidence')) { if ($Data.$name -isnot [System.Array]) { throw 'Data collections must be arrays.' } }
    $start = ConvertTo-WdtDataUtcText $Data.WindowStartUtc; $end = ConvertTo-WdtDataUtcText $Data.WindowEndUtc
    if (($null -eq $start) -ne ($null -eq $end) -or ($null -ne $start -and [datetimeoffset]$start -ge [datetimeoffset]$end)) { throw 'Invalid data window.' }
    if ($Data.Sources.Count + $Data.Facts.Count + $Data.Evidence.Count -gt $script:WdtDataItemLimit) { throw 'Data item budget exceeded.' }
    $sourceDefinitions = @{
        System=@{os=@('Configuration','Win32_OperatingSystem.Version.BuildNumber')}
        Crashes=@{
            'crash-source-1'=@('History','Application Error/1000'); 'crash-source-2'=@('History','Windows Error Reporting/1001')
            'crash-source-3'=@('History','Application Hang/1002'); 'crash-source-4'=@('History','SystemErrorReporting/1001'); 'crash-source-5'=@('History','Reliability')
        }
        Events=@{
            'event-log-1'=@('History','System/Levels=1,2','System/Levels=1,2,3')
            'event-log-2'=@('History','Application/Levels=1,2','Application/Levels=1,2,3')
            'high-signals'=@('History','System/Id=41,55/ProviderLevelRules')
        }
        Updates=@{
            hotfix=@('Inventory','Get-HotFix/HotFixID')
            'reboot-1'=@('Configuration','RebootIndicator/Component Based Servicing RebootPending')
            'reboot-2'=@('Configuration','RebootIndicator/Windows Update Auto Update RebootRequired')
            'reboot-3'=@('Configuration','RebootIndicator/PendingFileRenameOperations')
            'update-log-1'=@('History','System/WindowsUpdateClientFailures')
            'update-log-2'=@('History','Microsoft-Windows-WindowsUpdateClient/Operational/WindowsUpdateClientFailures')
        }
    }
    $sources = @{}; $evidenceIds = @{}; $factIds = @{}
    foreach ($source in $Data.Sources) {
        Assert-WdtDataProperties $source @('Id','Kind','Scope','Availability','QueryComplete','Truncated','Limit','Coverage','StartUtc','EndUtc','Error')
        foreach ($name in @('Kind','Availability','Coverage')) { Assert-WdtDataText $source.$name }
        if ($source.Id -isnot [string] -or $source.Id -cnotmatch '^[a-z][a-z0-9-]{0,79}$' -or $sources.ContainsKey($source.Id)) { throw 'Invalid or duplicate source identity.' }
        $sources[$source.Id] = $source
        Assert-WdtDataText $source.Scope
        $definition = $sourceDefinitions[$Data.ModuleId][$source.Id]
        if ($null -eq $definition -or $source.Kind -cne $definition[0] -or @($definition | Select-Object -Skip 1) -cnotcontains $source.Scope) { throw 'Unsupported source identity, kind, or scope.' }
        if ($source.Kind -cnotin @('Configuration','Inventory','History') -or $source.Availability -cnotin @('Available','Partial','Unavailable','NotCollected') -or $source.Coverage -cnotin @('Unknown','QueryWindow','CurrentState')) { throw 'Invalid source enum.' }
        if ($source.QueryComplete -isnot [bool] -or $source.Truncated -isnot [bool] -or ($null -ne $source.Limit -and (-not (Test-WdtDataInteger $source.Limit) -or $source.Limit -lt 1))) { throw 'Invalid source completeness type.' }
        if ($source.Availability -eq 'Available' -and (-not $source.QueryComplete -or $source.Truncated)) { throw 'Incomplete source cannot be available.' }
        if ($source.Availability -eq 'Available' -and -not [string]::IsNullOrEmpty([string]$source.Error)) { throw 'An available source cannot carry an error.' }
        if ($source.Availability -in @('Unavailable','NotCollected') -and $source.QueryComplete) { throw 'An unavailable source cannot be complete.' }
        Assert-WdtDataText $source.Error $true
        $sourceStart = ConvertTo-WdtDataUtcText $source.StartUtc; $sourceEnd = ConvertTo-WdtDataUtcText $source.EndUtc
        if (($null -eq $sourceStart) -ne ($null -eq $sourceEnd) -or ($null -ne $sourceStart -and [datetimeoffset]$sourceStart -ge [datetimeoffset]$sourceEnd)) { throw 'Invalid source window.' }
    }
    foreach ($item in $Data.Evidence) {
        Assert-WdtDataProperties $item @('Id','SourceId','TimestampUtc','TimePrecision','EndUtc','OriginalOffset','LogName','Provider','EventId','RecordId','ReportId','Kind','Component','FailureCode','Message')
        foreach ($name in @('SourceId','Kind','TimePrecision')) { Assert-WdtDataText $item.$name }
        if ($item.Id -isnot [string] -or $item.Id -cnotmatch '^e[0-9]+$' -or $evidenceIds.ContainsKey($item.Id) -or -not $sources.ContainsKey([string]$item.SourceId)) { throw 'Invalid evidence identity or source reference.' }
        $evidenceIds[$item.Id] = $item
        foreach ($name in @('OriginalOffset','LogName','Provider','RecordId','ReportId','Component','FailureCode','Message')) { Assert-WdtDataText $item.$name $true }
        if ($null -ne $item.EventId -and (-not (Test-WdtDataInteger $item.EventId) -or $item.EventId -lt 0)) { throw 'Invalid event id.' }
        if ($item.Kind -cnotin @('Crash','Hang','BugCheck','Event','UpdateInstallationFailure','UpdateDownloadFailure','HotFix') -or $item.TimePrecision -cnotin @('Instant','Day','Unknown')) { throw 'Invalid evidence enum.' }
        $time = ConvertTo-WdtDataUtcText $item.TimestampUtc; $until = ConvertTo-WdtDataUtcText $item.EndUtc
        if ($item.TimePrecision -eq 'Instant' -and $null -eq $time) { throw 'An instant requires a timestamp.' }
        if ($item.TimePrecision -eq 'Day' -and ($null -eq $time -or $null -eq $until -or [datetimeoffset]$time -ge [datetimeoffset]$until)) { throw 'Day precision requires an uncertainty interval.' }
        if ($item.TimePrecision -eq 'Unknown' -and ($null -ne $time -or $null -ne $until)) { throw 'Unknown precision must not invent a timestamp.' }
        if ($item.TimePrecision -eq 'Instant' -and $null -ne $until) { throw 'An instant cannot carry a day interval.' }
        if ($null -ne $item.OriginalOffset -and $item.OriginalOffset -ne '' -and $item.OriginalOffset -notmatch '^[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00)$') { throw 'Invalid original offset.' }
    }
    $schemas = @{
        OsVersion=@{Version='string'; Build='string'}
        RebootIndicator=@{Name='string'; Present='bool'}
        HotFix=@{HotFixId='string'; InstalledDate='nullable'}
        CrashObservation=@{Component='string'; Kind='string'; FailureCode='string'}
        EventObservation=@{Provider='string'; EventId='int'; Level='int'}
        UpdateFailure=@{UpdateIdentifier='nullable'; Title='string'; ErrorCode='string'; Kind='string'}
    }
    $factDefinitions = @{
        OsVersion=@('System','Configuration'); RebootIndicator=@('Updates','Configuration'); HotFix=@('Updates','Inventory')
        CrashObservation=@('Crashes','Windowed'); EventObservation=@('Events','Windowed'); UpdateFailure=@('Updates','Windowed')
    }
    foreach ($fact in $Data.Facts) {
        Assert-WdtDataProperties $fact @('Id','Type','Key','IdentityScope','ValueState','Values','Comparison','SourceIds','EvidenceIds')
        foreach ($name in @('Type','IdentityScope','ValueState','Comparison')) { Assert-WdtDataText $fact.$name }
        if ($fact.Id -isnot [string] -or $fact.Id -cnotmatch '^f[0-9]+$' -or $factIds.ContainsKey($fact.Id) -or -not $schemas.ContainsKey([string]$fact.Type)) { throw 'Invalid fact identity or type.' }
        $factIds[$fact.Id] = $true
        Assert-WdtDataText $fact.Key $true
        if ($fact.IdentityScope -cnotin @('Semantic','SnapshotLocal') -or $fact.ValueState -cnotin @('Known','Unknown','NotApplicable') -or $fact.Comparison -cnotin @('Configuration','Inventory','Windowed')) { throw 'Invalid fact enum.' }
        if ($Data.ModuleId -cne $factDefinitions[$fact.Type][0] -or $fact.Comparison -cne $factDefinitions[$fact.Type][1]) { throw 'Fact type has an incompatible module or comparison policy.' }
        if ($fact.IdentityScope -eq 'SnapshotLocal' -and -not [string]::IsNullOrEmpty([string]$fact.Key)) { throw 'A local identity cannot carry a comparison key.' }
        if ($fact.IdentityScope -eq 'Semantic' -and [string]::IsNullOrWhiteSpace([string]$fact.Key)) { throw 'A semantic identity needs a key.' }
        if ($fact.SourceIds -isnot [System.Array] -or $fact.SourceIds.Count -eq 0 -or $fact.EvidenceIds -isnot [System.Array]) { throw 'Fact references must be arrays.' }
        $seen = @{}
        foreach ($id in $fact.SourceIds) { if ($id -isnot [string] -or -not $sources.ContainsKey($id) -or $seen.ContainsKey($id)) { throw 'Invalid fact source reference.' }; $seen[$id]=$true }
        $seen = @{}
        foreach ($id in $fact.EvidenceIds) {
            if ($id -isnot [string] -or -not $evidenceIds.ContainsKey($id) -or $seen.ContainsKey($id) -or $fact.SourceIds -cnotcontains $evidenceIds[$id].SourceId) { throw 'Invalid fact evidence reference.' }
            $seen[$id]=$true
        }
        $schema = $schemas[$fact.Type]
        Assert-WdtDataProperties $fact.Values @($schema.Keys)
        foreach ($name in $schema.Keys) {
            $value = $fact.Values.$name
            if ($fact.ValueState -ne 'Known' -and $null -eq $value) { continue }
            switch ($schema[$name]) {
                'string' { Assert-WdtDataText $value }
                'nullable' { Assert-WdtDataText $value $true }
                'bool' { if ($value -isnot [bool]) { throw 'Invalid boolean fact value.' } }
                'int' { if (-not (Test-WdtDataInteger $value)) { throw 'Invalid integer fact value.' } }
            }
        }
    }
}

function Write-WdtDiagnosticDataFrame {
    param([string]$Marker)
    [System.Console]::Out.WriteLine($Marker)
}

function Write-WdtDiagnosticData {
    param([Parameter(Mandatory=$true)]$Data)
    $request = Get-WdtDataRequest
    if (-not $request.Enabled) { return }
    Assert-WdtDiagnosticData $Data
    if ($Data.ModuleId -cne $env:WDT_DATA_MODULE) { throw 'Unexpected module for data request.' }
    $prefix = '@@WDT_DATA@@' + $env:WDT_DATA_NONCE + ':'
    $begin = [ordered]@{Frame='Begin'; SchemaVersion=1; ModuleId=$Data.ModuleId; WindowStartUtc=$Data.WindowStartUtc; WindowEndUtc=$Data.WindowEndUtc}
    Write-WdtDiagnosticDataFrame ($prefix + ($begin | ConvertTo-Json -Compress -Depth 8))
    $count = 0; $characters = 0; $overflow = $false
    foreach ($collection in @('Sources','Evidence','Facts')) {
        foreach ($item in @($Data.$collection)) {
            $json = [ordered]@{Frame='Item'; Collection=$collection; Value=$item} | ConvertTo-Json -Compress -Depth 8
            if ($json.Length -gt $script:WdtDataFrameLimit -or $count -ge $script:WdtDataItemLimit -or $characters + $json.Length -gt $script:WdtDataCharacterLimit) { $overflow=$true; continue }
            Write-WdtDiagnosticDataFrame ($prefix + $json)
            $count++; $characters += $json.Length
        }
    }
    Write-WdtDiagnosticDataFrame ($prefix + ([ordered]@{Frame='End'; Count=$count; Overflow=$overflow} | ConvertTo-Json -Compress))
}

function Resolve-WdtDiagnosticData {
    param([AllowEmptyCollection()][string[]]$OutputLines, [string]$Nonce, [string]$ExpectedModuleId, [bool]$ExecutionComplete = $true)
    $clean = New-Object 'System.Collections.Generic.List[string]'
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $sources = New-Object 'System.Collections.Generic.List[object]'; $facts = New-Object 'System.Collections.Generic.List[object]'; $evidence = New-Object 'System.Collections.Generic.List[object]'
    $prefix = '@@WDT_DATA@@' + $Nonce + ':'
    $begin = $null; $ended = $false; $count = 0; $characters = 0
    foreach ($line in @($OutputLines)) {
        if (-not $line.StartsWith('@@WDT_DATA@@', [StringComparison]::Ordinal)) { $clean.Add($line); continue }
        if ($Nonce -notmatch '^[a-fA-F0-9]{32}$' -or -not $line.StartsWith($prefix, [StringComparison]::Ordinal)) { if ($errors.Count -lt 20) { $errors.Add('Unauthenticated data frame discarded.') }; continue }
        try {
            $json = $line.Substring($prefix.Length); $characters += $json.Length
            if ($json.Length -gt $script:WdtDataFrameLimit -or $characters -gt $script:WdtDataCharacterLimit) { throw 'Data budget exceeded.' }
            $frame = $json | ConvertFrom-Json -ErrorAction Stop
            if ($ended) { throw 'Data frame followed the end marker.' }
            switch -CaseSensitive ($frame.Frame) {
                'Begin' {
                    Assert-WdtDataProperties $frame @('Frame','SchemaVersion','ModuleId','WindowStartUtc','WindowEndUtc')
                    if ($null -ne $begin -or -not (Test-WdtDataInteger $frame.SchemaVersion) -or $frame.SchemaVersion -ne 1 -or $frame.ModuleId -cne $ExpectedModuleId) { throw 'Invalid data start marker.' }
                    $begin = $frame
                }
                'Item' {
                    Assert-WdtDataProperties $frame @('Frame','Collection','Value')
                    if ($null -eq $begin -or $count -ge $script:WdtDataItemLimit) { throw 'Invalid data item ordering or budget.' }
                    switch -CaseSensitive ($frame.Collection) {
                        'Sources' { $sources.Add($frame.Value) }
                        'Facts' { $facts.Add($frame.Value) }
                        'Evidence' { $evidence.Add($frame.Value) }
                        default { throw 'Unknown data collection.' }
                    }
                    $count++
                }
                'End' {
                    Assert-WdtDataProperties $frame @('Frame','Count','Overflow')
                    if ($null -eq $begin -or -not (Test-WdtDataInteger $frame.Count) -or $frame.Count -ne $count -or $frame.Overflow -isnot [bool]) { throw 'Invalid data end marker.' }
                    $ended = $true
                    if ($frame.Overflow) { $errors.Add('Diagnostic data exceeded its output budget.'); }
                }
                default { throw 'Unknown data frame.' }
            }
        }
        catch { if ($errors.Count -lt 20) { $errors.Add('Invalid diagnostic data frame discarded.'); } }
    }
    $data = $null
    if ($null -ne $begin) {
        try {
            $data = New-WdtDiagnosticData -ModuleId $ExpectedModuleId -WindowStartUtc $begin.WindowStartUtc -WindowEndUtc $begin.WindowEndUtc -Sources @($sources.ToArray()) -Facts @($facts.ToArray()) -Evidence @($evidence.ToArray())
            Assert-WdtDiagnosticData $data
        }
        catch { $data = $null; $errors.Add('Diagnostic data failed schema validation.'); }
    }
    if (-not $ended) { $errors.Add('Diagnostic data did not include a complete end marker.'); }
    if (-not $ExecutionComplete) { $errors.Add('Execution or stream capture was incomplete.'); }
    $status = 'Unavailable'
    if ($null -ne $data) {
        $status = 'Available'
        if ($errors.Count -gt 0 -or @($data.Sources | Where-Object { $_.Availability -ne 'Available' -or -not $_.QueryComplete }).Count -gt 0) { $status = 'Partial' }
        if ($data.Sources.Count -eq 0 -or @($data.Sources | Where-Object { $_.Availability -notin @('Unavailable','NotCollected') }).Count -eq 0) { $status = 'Unavailable' }
        if ($status -ne 'Available' -and $errors.Count -gt 0) {
            foreach ($source in $data.Sources) { if ($source.Availability -eq 'Available') { $source.Availability='Partial'; $source.QueryComplete=$false } }
        }
    }
    return [pscustomobject]@{Data=$data; DataStatus=$status; DataErrors=@($errors.ToArray()); OutputLines=@($clean.ToArray())}
}

function Protect-WdtDataString {
    param($Value, $Context)
    if ($null -eq $Value) { return $null }
    $text = Protect-WdtSensitiveUrlText -Text ([string]$Value)
    $text = Protect-WdtCommandLineSecrets -Text $text
    if ($null -ne $Context) { $text = Protect-WdtText -Text $text -Context $Context }
    return $text
}

function Protect-WdtDiagnosticData {
    param([Parameter(Mandatory=$true)]$Data, $Context)
    Assert-WdtDiagnosticData $Data
    $copy = $Data | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
    foreach ($source in $copy.Sources) { $source.Error = Protect-WdtDataString $source.Error $Context }
    foreach ($fact in $copy.Facts) {
        $changed = $false
        foreach ($property in @($fact.Values.PSObject.Properties)) {
            if ($property.Value -is [string]) {
                $protected = Protect-WdtDataString $property.Value $Context
                if ($protected -cne $property.Value -or $protected -match '<(?:HOST|USER|IP|MAC|ID)-[0-9]+>') { $changed=$true }
                $property.Value = $protected
            }
        }
        if ($null -ne $fact.Key) {
            $protectedKey = Protect-WdtDataString $fact.Key $Context
            if ($protectedKey -cne $fact.Key -or $protectedKey -match '<(?:HOST|USER|IP|MAC|ID)-[0-9]+>') { $changed=$true }
        }
        if ($changed) { $fact.Key=$null; $fact.IdentityScope='SnapshotLocal' }
    }
    foreach ($item in $copy.Evidence) {
        foreach ($name in @('LogName','Provider','Component','FailureCode','Message')) { $item.$name = Protect-WdtDataString $item.$name $Context }
        foreach ($name in @('RecordId','ReportId')) {
            if ($null -ne $Context -and -not [string]::IsNullOrEmpty([string]$item.$name)) { $item.$name = Get-WdtRedactionToken -Context $Context -Category ID -Value ([string]$item.$name) }
            else { $item.$name = Protect-WdtDataString $item.$name $Context }
        }
    }
    Assert-WdtDiagnosticData $copy
    return $copy
}
