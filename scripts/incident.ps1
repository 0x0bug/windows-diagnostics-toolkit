[CmdletBinding()]
param()

. $PSScriptRoot\snapshot.ps1
. $PSScriptRoot\diagnostic-data.ps1
. $PSScriptRoot\report-common.ps1

# Correlation uses raw identities only in memory. All returned diagnostic values
# come from the single privacy projection, with module-qualified local refs.
function Resolve-WdtIncidentWindow {
    param([string]$Symptom, [string]$At, [int]$BeforeMinutes=30, [int]$AfterMinutes=30)
    try {
        $canonical = switch ($Symptom) { AppFailure { 'AppFailure' } UnexpectedRestart { 'UnexpectedRestart' } default { throw 'Profile.' } }
        if ($BeforeMinutes -lt 0 -or $AfterMinutes -lt 0 -or ([long]$BeforeMinutes+$AfterMinutes) -le 0 -or ([long]$BeforeMinutes+$AfterMinutes) -gt 43200) { throw 'Window.' }
        $utc=ConvertTo-WdtDataUtcText $At
        if ($null -eq $utc) { throw 'Time.' }
        $time=[datetimeoffset]$utc
        $offset=if ($At -cmatch 'Z$') { '+00:00' } else { $At.Substring($At.Length-6) }
        return [pscustomobject][ordered]@{Symptom=$canonical;RequestedAt=$At;AtUtc=$utc;OriginalOffset=$offset;StartUtc=(ConvertTo-WdtDataUtcText $time.AddSeconds(-60L*$BeforeMinutes));EndUtc=(ConvertTo-WdtDataUtcText $time.AddSeconds(60L*$AfterMinutes));BeforeMinutes=$BeforeMinutes;AfterMinutes=$AfterMinutes}
    }
    catch { throw 'Invalid incident request. Use AppFailure or UnexpectedRestart, ISO 8601 time with Z or an offset, and a positive total window of at most 30 days.' }
}

function Get-WdtIncidentReportIdentity {
    param($Value)
    $identity=[guid]::Empty
    if ([System.Guid]::TryParse([string]$Value,[ref]$identity) -and $identity -ne [guid]::Empty) { return $identity.ToString('D') }
    return $null
}

function Get-WdtIncidentRecordIdentity {
    param($Item)
    if ($Item.TimePrecision -ne 'Instant' -or [string]::IsNullOrWhiteSpace($Item.LogName) -or [string]::IsNullOrWhiteSpace($Item.Provider) -or $null -eq $Item.EventId -or $Item.RecordId -notmatch '^[0-9]+$') { return $null }
    $record=([string]$Item.RecordId).TrimStart('0')
    if ($record.Length -eq 0) { return $null }
    return ConvertTo-Json -InputObject @($Item.LogName.ToLowerInvariant(),$Item.Provider.ToLowerInvariant(),$Item.EventId,$record,(ConvertTo-WdtDataUtcText $Item.TimestampUtc)) -Compress
}

function Test-WdtIncidentKnownText {
    param($Value)
    return -not ([string]::IsNullOrWhiteSpace([string]$Value) -or ([string]$Value).Trim() -in @('Unknown','Unknown application'))
}

function Test-WdtIncidentFailureCompatible {
    param($Left,$Right)
    return $Left.Kind -eq $Right.Kind -and
        (Test-WdtIncidentKnownText $Left.Component) -and (Test-WdtIncidentKnownText $Right.Component) -and
        $Left.Component.Trim() -ieq $Right.Component.Trim() -and
        (-not (Test-WdtIncidentKnownText $Left.FailureCode) -or -not (Test-WdtIncidentKnownText $Right.FailureCode) -or $Left.FailureCode -ieq $Right.FailureCode)
}

function Test-WdtIncidentGroupLink {
    param($Left,$Right,[string]$Mode)
    $leftIds=@($Left | ForEach-Object { Get-WdtIncidentReportIdentity $_.Item.ReportId } | Sort-Object -Unique)
    $rightIds=@($Right | ForEach-Object { Get-WdtIncidentReportIdentity $_.Item.ReportId } | Sort-Object -Unique)
    if (@($leftIds+$rightIds | Sort-Object -Unique).Count -gt 1) { return $false }
    if ($Mode -eq 'Report') { foreach ($a in $Left) {
        foreach ($b in $Right) {
            if ($a.Item.Kind -in @('Crash','Hang','BugCheck') -and $b.Item.Kind -in @('Crash','Hang','BugCheck')) {
                if (-not (Test-WdtIncidentFailureCompatible $a.Item $b.Item)) { return $false }
            }
        }
    } }
    if ($Mode -eq 'Report') {
        foreach ($a in $Left) { foreach ($b in $Right) {
            if ($null -ne $a.ReportIdentity -and $a.ReportIdentity -eq $b.ReportIdentity -and $a.Item.Kind -in @('Crash','Hang','BugCheck') -and (Test-WdtIncidentFailureCompatible $a.Item $b.Item)) { return $true }
        } }
        return $false
    }
    return $true
}

function Get-WdtIncidentRoot {
    param($Groups,[int]$Index)
    while ($Groups[$Index].Parent -ne $Index) { $Index=$Groups[$Index].Parent }
    return $Index
}

function Test-WdtIncidentRestartSignal {
    param($Record)
    if ($Record.ModuleId -ne 'Events' -or $Record.Item.Kind -ne 'Event' -or $Record.Item.LogName -ine 'System' -or $Record.Item.Provider -ine 'Microsoft-Windows-Kernel-Power' -or $Record.Item.EventId -ne 41) { return $false }
    foreach ($fact in $Record.Facts) {
        if ($fact.Type -eq 'EventObservation' -and $fact.ValueState -eq 'Known' -and $fact.Values.Provider -ieq 'Microsoft-Windows-Kernel-Power' -and $fact.Values.EventId -eq 41 -and $fact.Values.Level -eq 1) { return $true }
    }
    return $false
}

function Assert-WdtIncidentWindow {
    param([Parameter(Mandatory=$true)]$Window)
    try {
        Assert-WdtDataProperties $Window @('Symptom','RequestedAt','AtUtc','OriginalOffset','StartUtc','EndUtc','BeforeMinutes','AfterMinutes')
        foreach ($name in @('Symptom','RequestedAt','AtUtc','OriginalOffset','StartUtc','EndUtc')) { Assert-WdtDataText $Window.$name }
        foreach ($name in @('BeforeMinutes','AfterMinutes')) { if (-not (Test-WdtDataInteger $Window.$name)) { throw 'Minutes.' } }
        $checked=Resolve-WdtIncidentWindow -Symptom $Window.Symptom -At $Window.RequestedAt -BeforeMinutes $Window.BeforeMinutes -AfterMinutes $Window.AfterMinutes
        foreach ($property in $checked.PSObject.Properties) { if ($Window.($property.Name) -cne $property.Value) { throw 'Window mismatch.' } }
        return $checked
    } catch { throw 'Invalid WDT incident window.' }
}

function New-WdtIncident {
    param([Parameter(Mandatory=$true)]$Window, [Parameter(Mandatory=$true)][object[]]$Results,
        [string]$ToolkitVersion, $CollectionStartedUtc, $CollectionFinishedUtc, [bool]$PrivacyMode=$false, $Context)
    try {
        $checked=Assert-WdtIncidentWindow $Window
        $capture=New-WdtSnapshot -ToolkitVersion $ToolkitVersion -ModuleIds @('Crashes','Events','Updates') -Results $Results -CollectionStartedUtc $CollectionStartedUtc -CollectionFinishedUtc $CollectionFinishedUtc -WindowStartUtc $checked.StartUtc -WindowEndUtc $checked.EndUtc
    }
    catch { throw 'Invalid WDT incident data or window.' }

    $records=New-Object System.Collections.Generic.List[object]
    $dateRecords=New-Object System.Collections.Generic.List[object]
    $futureClockRefs=New-Object System.Collections.Generic.List[string]
    $limitations=New-Object System.Collections.Generic.List[string]
    $start=[datetimeoffset]$checked.StartUtc; $end=[datetimeoffset]$checked.EndUtc
    foreach ($module in $capture.Modules) {
        if ($null -eq $module.Data) { continue }
        $factRefs=@{}
        foreach ($fact in $module.Data.Facts) { foreach ($id in $fact.EvidenceIds) {
            if (-not $factRefs.ContainsKey($id)) { $factRefs[$id]=New-Object System.Collections.Generic.List[object] }
            $factRefs[$id].Add($fact)
        } }
        foreach ($item in $module.Data.Evidence) {
            $linkedFacts=@(); if ($factRefs.ContainsKey($item.Id)) { $linkedFacts=@($factRefs[$item.Id].ToArray()) }
            $record=[pscustomobject]@{Ref=($module.ModuleId+'/'+$item.Id);ModuleId=$module.ModuleId;Item=$item;Facts=$linkedFacts;RecordIdentity=(Get-WdtIncidentRecordIdentity $item);ReportIdentity=(Get-WdtIncidentReportIdentity $item.ReportId);Date=$null;DateReason=$null}
            if ($item.Kind -eq 'HotFix') {
                if ($item.TimePrecision -eq 'Day') {
                    if ([datetimeoffset]$item.TimestampUtc -lt $end -and [datetimeoffset]$item.EndUtc -gt $start) { $record.DateReason='Known day uncertainty interval overlaps the requested window; no exact installation time.'; $dateRecords.Add($record) }
                }
                else {
                    foreach ($fact in $linkedFacts) {
                        $date=[string]$fact.Values.InstalledDate
                        if ($fact.Type -ne 'HotFix' -or $fact.ValueState -ne 'Known' -or $date -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
                        try {
                            # Only a possible-overlap test. These UTC values are
                            # inferred +/-14h bounds, never source install times.
                            $nominal=[datetimeoffset]($date+'T00:00:00Z')
                            if ($nominal.AddHours(-14) -lt $end -and $nominal.AddDays(1).AddHours(14) -gt $start) {
                                $record.Date=$date; $record.DateReason='Possible date overlap only: historical timezone is unknown (conservative +/-14h test); no exact UTC installation time.'; $dateRecords.Add($record)
                            }
                        } catch { $limitations.Add('A source-reported HotFix date could not be interpreted; installation timing is unknown.') }
                        break
                    }
                }
                continue
            }
            if ($item.TimePrecision -eq 'Instant' -and -not (Test-WdtDataInWindow $item.TimestampUtc $checked.StartUtc $checked.EndUtc)) { continue }
            if ($item.TimePrecision -eq 'Instant' -and [datetimeoffset]$item.TimestampUtc -gt [datetimeoffset]$capture.CollectionFinishedUtc) { $futureClockRefs.Add($record.Ref) }
            $records.Add($record)
        }
    }

    $groups=New-Object System.Collections.Generic.List[object]
    $recordIndex=@{}; $reportIndex=@{}
    foreach ($record in @($records.ToArray() | Sort-Object @{Expression={ConvertTo-WdtDataUtcText $_.Item.TimestampUtc}},Ref)) {
        $index=$groups.Count
        $members=New-Object System.Collections.Generic.List[object]; $members.Add($record)
        $groups.Add([pscustomobject]@{Parent=$index;Members=$members})
        $candidates=New-Object System.Collections.Generic.List[object]
        if ($null -ne $record.RecordIdentity -and $recordIndex.ContainsKey($record.RecordIdentity)) { foreach ($candidate in $recordIndex[$record.RecordIdentity]) { $candidates.Add([pscustomobject]@{Index=$candidate;Mode='Record'}) } }
        if ($null -ne $record.ReportIdentity -and $reportIndex.ContainsKey($record.ReportIdentity)) { foreach ($candidate in $reportIndex[$record.ReportIdentity]) { $candidates.Add([pscustomobject]@{Index=$candidate;Mode='Report'}) } }
        foreach ($candidate in $candidates) {
            $root=Get-WdtIncidentRoot $groups $index; $other=Get-WdtIncidentRoot $groups $candidate.Index
            if ($root -eq $other) { continue }
            if (Test-WdtIncidentGroupLink $groups[$other].Members.ToArray() $groups[$root].Members.ToArray() $candidate.Mode) {
                foreach ($member in $groups[$root].Members) { $groups[$other].Members.Add($member) }
                $groups[$root].Parent=$other
            }
        }
        foreach ($pair in @(@{Map=$recordIndex;Key=$record.RecordIdentity},@{Map=$reportIndex;Key=$record.ReportIdentity})) {
            if ($null -eq $pair.Key) { continue }
            if (-not $pair.Map.ContainsKey($pair.Key)) { $pair.Map[$pair.Key]=New-Object System.Collections.Generic.List[int] }
            $pair.Map[$pair.Key].Add($index)
        }
    }

    if ($PrivacyMode -and $null -eq $Context) { $Context=New-WdtRedactionContext }
    $safe=Protect-WdtSnapshot -Snapshot $capture -Context $Context -PrivacyMode $PrivacyMode
    $safeRefs=@{}
    foreach ($module in $safe.Modules) { if ($null -ne $module.Data) { foreach ($item in $module.Data.Evidence) { $safeRefs[$module.ModuleId+'/'+$item.Id]=$item } } }
    $timeline=New-Object System.Collections.Generic.List[object]
    $unplaced=New-Object System.Collections.Generic.List[string]
    $rawByEntry=@{}
    foreach ($group in $groups) {
        if ($group.Parent -ne $groups.IndexOf($group)) { continue }
        $members=@($group.Members.ToArray() | Sort-Object Ref)
        $instants=@($members | Where-Object { $_.Item.TimePrecision -eq 'Instant' -and [datetimeoffset]$_.Item.TimestampUtc -le [datetimeoffset]$capture.CollectionFinishedUtc } | Sort-Object @{Expression={ConvertTo-WdtDataUtcText $_.Item.TimestampUtc}},Ref)
        if ($instants.Count -eq 0) { foreach ($member in $members) { $unplaced.Add($member.Ref) }; continue }
        $targets=@($members | Where-Object {
            ($checked.Symptom -eq 'AppFailure' -and $_.ModuleId -eq 'Crashes' -and $_.Item.Kind -in @('Crash','Hang')) -or
            ($checked.Symptom -eq 'UnexpectedRestart' -and (($_.ModuleId -eq 'Crashes' -and $_.Item.Kind -eq 'BugCheck') -or (Test-WdtIncidentRestartSignal $_)))
        })
        $special=@($members | Where-Object { $_.Item.Kind -ne 'Event' })
        $primary=if ($targets.Count -gt 0) { $targets[0] } elseif ($special.Count -gt 0) { $special[0] } else { $members[0] }
        $item=$safeRefs[$primary.Ref]
        $kind=if (Test-WdtIncidentRestartSignal $primary) { 'UnexpectedRestartSignal' } else { $item.Kind }
        $severity=if ($kind -eq 'BugCheck') { 0 } elseif ($targets.Count -gt 0) { 1 } elseif ($kind -in @('UpdateInstallationFailure','UpdateDownloadFailure')) { 2 } else { 3 }
        $label=ConvertTo-WdtSingleLineText $(
            if ($kind -eq 'UnexpectedRestartSignal') { 'Kernel-Power 41: Windows recorded an unexpected shutdown/restart; this does not establish BugCheck or cause.' }
            elseif ($kind -eq 'Event') {
                $contextText=ConvertTo-WdtSingleLineText $item.Message
                if ($null -ne $contextText -and $contextText.Length -gt 240) { $contextText=$contextText.Substring(0,240)+'...' }
                'Event context: {0}/{1}; {2}' -f $item.Provider,$item.EventId,$contextText
            }
            else { '{0}: {1}; code={2}' -f $kind,$item.Component,$item.FailureCode }
        )
        $id='t'+($timeline.Count+1)
        $refs=@($members | ForEach-Object Ref)
        $timeline.Add([pscustomobject]@{Id=$id;Classification='Fact';IsTarget=($targets.Count -gt 0);Kind=$kind;Label=$label;FirstUtc=(ConvertTo-WdtDataUtcText $instants[0].Item.TimestampUtc);LastUtc=(ConvertTo-WdtDataUtcText $instants[-1].Item.TimestampUtc);EvidenceRefs=$refs;AmbiguousWith=@();Priority=$severity})
        $rawByEntry[$id]=$members
    }
    $ordered=@($timeline.ToArray() | Sort-Object FirstUtc,Id)
    # A weak match only annotates retained entries. Distinct valid ReportIds are
    # independent observations, not possible duplicates merely close in time.
    for ($i=0;$i -lt $ordered.Count;$i++) {
        $left=@($rawByEntry[$ordered[$i].Id] | Where-Object { $_.Item.Kind -in @('Crash','Hang','BugCheck') })
        if ($left.Count -eq 0) { continue }
        for ($j=$i+1;$j -lt $ordered.Count;$j++) {
            if (([datetimeoffset]$ordered[$j].FirstUtc-[datetimeoffset]$ordered[$i].LastUtc).TotalMinutes -gt 5) { break }
            $right=@($rawByEntry[$ordered[$j].Id] | Where-Object { $_.Item.Kind -in @('Crash','Hang','BugCheck') })
            if ($right.Count -eq 0) { continue }
            $ids=@(@($left+$right) | ForEach-Object ReportIdentity | Where-Object { $null -ne $_ } | Sort-Object -Unique)
            if ($ids.Count -gt 1) { continue }
            if (Test-WdtIncidentFailureCompatible $left[0].Item $right[0].Item) { $ordered[$i].AmbiguousWith+= $ordered[$j].Id; $ordered[$j].AmbiguousWith+= $ordered[$i].Id }
        }
    }

    $observations=New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($ordered | Where-Object IsTarget | Sort-Object Priority,FirstUtc,Id | Select-Object -First 5)) {
        $observations.Add([pscustomobject]@{Classification='Fact';Text=$entry.Label;TimelineRefs=@($entry.Id);EvidenceRefs=@($entry.EvidenceRefs)})
    }
    $targetEntries=@($ordered | Where-Object IsTarget)
    foreach ($entry in @($ordered | Where-Object { -not $_.IsTarget -and $_.Kind -in @('UpdateInstallationFailure','UpdateDownloadFailure') })) {
        if ($observations.Count -ge 5 -or $targetEntries.Count -eq 0) { break }
        $target=$targetEntries[0]
        $relation=if ([datetimeoffset]$entry.FirstUtc -lt [datetimeoffset]$target.FirstUtc) { 'before' } else { 'at or after' }
        $observations.Add([pscustomobject]@{Classification='TemporalCoincidence';Text=('{0} recorded {1} target evidence in this window. Temporal ordering does not establish cause or a successful installation.' -f $entry.Label,$relation);TimelineRefs=@($entry.Id,$target.Id);EvidenceRefs=@(@($entry.EvidenceRefs+$target.EvidenceRefs) | Sort-Object -Unique)})
    }
    foreach ($entry in @($ordered | Where-Object { $_.AmbiguousWith.Count -gt 0 })) {
        if ($observations.Count -ge 5) { break }
        $other=@($ordered | Where-Object { $_.Id -eq $entry.AmbiguousWith[0] })[0]
        if (@($observations | Where-Object { $_.Classification -eq 'TemporalCoincidence' -and $_.TimelineRefs -contains $entry.Id -and $_.TimelineRefs -contains $other.Id }).Count -gt 0) { continue }
        $observations.Add([pscustomobject]@{Classification='TemporalCoincidence';Text='Nearby compatible failure observations have no proven shared identity; possible duplicate reporting remains ambiguous. Both entries are retained.';TimelineRefs=@($entry.Id,$other.Id);EvidenceRefs=@(@($entry.EvidenceRefs+$other.EvidenceRefs) | Sort-Object -Unique)})
    }

    $coverage=New-Object System.Collections.Generic.List[object]
    foreach ($module in $safe.Modules) {
        $sources=@(); if ($null -ne $module.Data) { $sources=@($module.Data.Sources) }
        if ($sources.Count -eq 0) { $coverage.Add([pscustomobject]@{ModuleId=$module.ModuleId;SourceId=$null;Execution=$module.Status;Completeness=$module.Completeness;DataStatus=$module.DataStatus;DataErrors=@($module.DataErrors);Source=$null;EvidenceCount=0}) }
        foreach ($source in $sources) {
            $coverage.Add([pscustomobject]@{ModuleId=$module.ModuleId;SourceId=$source.Id;Execution=$module.Status;Completeness=$module.Completeness;DataStatus=$module.DataStatus;DataErrors=@($module.DataErrors);Source=$source;EvidenceCount=@($module.Data.Evidence | Where-Object SourceId -eq $source.Id).Count})
        }
    }
    $dateContext=New-Object System.Collections.Generic.List[object]
    foreach ($record in $dateRecords) { $item=$safeRefs[$record.Ref]; $dateContext.Add([pscustomobject]@{EvidenceRefs=@($record.Ref);Component=$item.Component;InstalledDate=$record.Date;TimePrecision=$item.TimePrecision;StartUtc=$item.TimestampUtc;EndUtc=$item.EndUtc;Reason=$record.DateReason}) }
    $evidence=New-Object System.Collections.Generic.List[object]
    foreach ($record in @(@($records.ToArray())+@($dateRecords.ToArray()) | Sort-Object Ref -Unique)) { $evidence.Add([pscustomobject]@{Ref=$record.Ref;SourceRef=($record.ModuleId+'/'+$record.Item.SourceId);Item=$safeRefs[$record.Ref]}) }
    $finish=[datetimeoffset]$safe.CollectionFinishedUtc
    $observedEnd=if ($end -lt $finish) { $end } else { $finish }
    $hasObserved=$observedEnd -gt $start
    $through=if ($hasObserved) { ConvertTo-WdtDataUtcText $observedEnd } else { $null }
    $observedStart=if ($hasObserved) { $checked.StartUtc } else { $null }
    $futureStart=if ($finish -gt $start) { ConvertTo-WdtDataUtcText $finish } else { $checked.StartUtc }
    if ($end -gt $finish) { $limitations.Add(('Future requested portion [{0}, {1}) was not observed. Collection cannot observe future events.' -f $futureStart,$checked.EndUtc)) }
    if (-not $hasObserved) { $limitations.Add('The requested window has no observed past intersection at collection finish.') }
    if ($targetEntries.Count -eq 0) { $limitations.Add('No recognized target evidence was available in the requested window; this does not establish system health or absence of an incident.') }
    if ($unplaced.Count -gt 0) { $limitations.Add(('Evidence without a usable observed instant cannot be placed in the exact timeline or established inside the observed window: {0}.' -f ($unplaced -join ', '))) }
    if ($futureClockRefs.Count -gt 0) { $limitations.Add(('Source timestamps after collection finish are a timestamp/clock inconsistency, not observed future events; retained in the appendix and excluded as exact timeline instants: {0}.' -f ($futureClockRefs -join ', '))) }
    $limitations.Add('Timestamps describe evidence recording, which may differ from the actual failure time. Collection is not synchronized across sources; the observed bound is an upper bound, not proof of complete coverage.')
    $limitations.Add('History retention is unknown. Query success and an empty query do not establish health; caps, source availability, execution and protocol completeness remain separate.')
    $limitations.Add('Get-HotFix is a limited current inventory, not all Windows updates or drivers. Missing entries do not prove no updates occurred. Current reboot/service states do not describe the historical incident and are excluded from observations.')
    $limitations.Add('Facts describe observations. TemporalCoincidence describes timing or ambiguous identity only. No causal Hypothesis is generated; update/driver causality cannot be inferred from ordering.')
    $actionFailed=@($safe.Modules | Where-Object { $_.Status -ne 'Success' -or -not $_.OutputComplete -or $null -eq $_.Data -or $_.DataStatus -eq 'NotCollected' -or $_.DataErrors.Count -gt 0 }).Count -gt 0
    return [pscustomobject]@{ToolkitVersion=$safe.ToolkitVersion;Window=$checked;CollectionStartedUtc=$safe.CollectionStartedUtc;CollectionFinishedUtc=$safe.CollectionFinishedUtc;ObservedStartUtc=$observedStart;ObservedThroughUtc=$through;PrivacyMode=$PrivacyMode;Observations=@($observations.ToArray());Timeline=$ordered;DateContext=@($dateContext.ToArray());Evidence=@($evidence.ToArray());Coverage=@($coverage.ToArray());Limitations=@($limitations.ToArray());ExitCode=$(if ($actionFailed) { 1 } else { 0 })}
}

function Get-WdtIncidentLines {
    param([Parameter(Mandatory=$true)]$Incident)
    $lines=New-Object System.Collections.Generic.List[string]
    $lines.Add('Windows Diagnostics Toolkit - Incident Investigation')
    $lines.Add(('Toolkit version: {0}; privacy mode: {1}; read-only' -f $Incident.ToolkitVersion,$Incident.PrivacyMode))
    $lines.Add(('Symptom: {0}; user-supplied approximate center: {1}; original offset: {2}; timestamp format: Instant (not verified failure-time precision)' -f $Incident.Window.Symptom,$Incident.Window.RequestedAt,$Incident.Window.OriginalOffset))
    $lines.Add(('Requested UTC window [start,end): {0} / {1}' -f $Incident.Window.StartUtc,$Incident.Window.EndUtc))
    $lines.Add(('Collection UTC: {0} / {1}' -f $Incident.CollectionStartedUtc,$Incident.CollectionFinishedUtc))
    $lines.Add(('Observed past bound [start,end): {0} / {1} (empty means no observed past intersection)' -f $Incident.ObservedStartUtc,$Incident.ObservedThroughUtc))
    $lines.Add(''); $lines.Add('Summary observations:')
    if ($Incident.Observations.Count -eq 0) { $lines.Add('  Insufficient recognized evidence for a target observation; review coverage and limitations.') }
    foreach ($observation in $Incident.Observations) { $lines.Add(('[{0}] {1} Timeline={2}; Evidence={3}' -f $observation.Classification,$observation.Text,($observation.TimelineRefs -join ', '),($observation.EvidenceRefs -join ', '))) }
    $lines.Add(''); $lines.Add('Exact evidence timeline (UTC recording times):')
    if ($Incident.Timeline.Count -eq 0) { $lines.Add('  No timestamped evidence available in this window.') }
    foreach ($entry in $Incident.Timeline) {
        $lines.Add(('{0} [{1}] {2} / {3}; target={4}; {5}; Evidence={6}' -f $entry.Id,$entry.Classification,$entry.FirstUtc,$entry.LastUtc,$entry.IsTarget,$entry.Label,($entry.EvidenceRefs -join ', ')))
        if ($entry.AmbiguousWith.Count -gt 0) { $lines.Add(('  [TemporalCoincidence] Possible duplicate reporting is ambiguous with {0}; entries retained.' -f ($entry.AmbiguousWith -join ', '))) }
    }
    $lines.Add(''); $lines.Add('Uncertain date context (excluded from exact sequence):')
    if ($Incident.DateContext.Count -eq 0) { $lines.Add('  No usable overlapping date context from the limited inventory; this is not proof that no updates occurred.') }
    foreach ($date in $Incident.DateContext) {
        $lines.Add(('{0}; source date={1}; precision={2}; {3}; Evidence={4}' -f $date.Component,$date.InstalledDate,$date.TimePrecision,$date.Reason,($date.EvidenceRefs -join ', ')))
        if ($date.TimePrecision -eq 'Day') { $lines.Add(('  Source day uncertainty interval [start,end): {0} / {1} (not an exact install time)' -f $date.StartUtc,$date.EndUtc)) }
    }
    $lines.Add(''); $lines.Add('Source coverage (Available-empty differs from missing/unavailable):')
    foreach ($coverage in $Incident.Coverage) {
        $lines.Add(('{0}/{1}: execution={2}; completeness={3}; data={4}; source evidence records={5}' -f $coverage.ModuleId,$coverage.SourceId,$coverage.Execution,$coverage.Completeness,$coverage.DataStatus,$coverage.EvidenceCount))
        if ($null -eq $coverage.Source) { $lines.Add('  Source data missing; availability and period coverage cannot be established.') }
        else {
            $s=$coverage.Source
            $lines.Add(('  {0}; queryComplete={1}; truncated={2}; limit={3}; kind={4}; coverage={5}; scope={6}; query window={7}/{8}' -f $s.Availability,$s.QueryComplete,$s.Truncated,$s.Limit,$s.Kind,$s.Coverage,$s.Scope,$s.StartUtc,$s.EndUtc))
            if (-not [string]::IsNullOrEmpty($s.Error)) { $lines.Add(('  Source reason: {0}' -f $s.Error)) }
        }
        foreach ($errorText in $coverage.DataErrors) { $lines.Add(('  Data reason: {0}' -f $errorText)) }
    }
    $lines.Add(''); $lines.Add('Limitations:')
    foreach ($limitation in $Incident.Limitations) { $lines.Add(('  '+$limitation)) }
    $lines.Add(''); $lines.Add('Evidence appendix (all linked source refs retained):')
    foreach ($evidence in $Incident.Evidence) {
        $item=$evidence.Item
        $lines.Add(('{0}; source={1}; channel={2}; provider={3}; eventId={4}; recordId={5}; reportId={6}; kind={7}; time={8}; precision={9}; until={10}; originalOffset={11}' -f $evidence.Ref,$evidence.SourceRef,$item.LogName,$item.Provider,$item.EventId,$item.RecordId,$item.ReportId,$item.Kind,$item.TimestampUtc,$item.TimePrecision,$item.EndUtc,$item.OriginalOffset))
        $lines.Add(('  component={0}; code={1}; message={2}' -f $item.Component,$item.FailureCode,$item.Message))
    }
    # Normalize only the presentation: full redacted source strings remain in
    # the Evidence and Coverage objects for inspection and traceability.
    return @($lines.ToArray() | ForEach-Object { ConvertTo-WdtSingleLineText $_ })
}
