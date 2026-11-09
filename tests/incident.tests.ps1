[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\incident.ps1')
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -cne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }
function Assert-Throws { param([scriptblock]$Action, [string]$Message) $failed=$false; try { & $Action } catch { $failed=$true }; Assert-True $failed $Message }

$window = Resolve-WdtIncidentWindow -Symptom appfailure -At '2025-11-02T12:00:00+02:00' -BeforeMinutes 30 -AfterMinutes 30
Assert-Equal AppFailure $window.Symptom 'Profile must be canonical.'
Assert-Equal '2025-11-02T10:00:00.0000000Z' $window.AtUtc 'Explicit offset was lost.'
$equivalent = Resolve-WdtIncidentWindow -Symptom AppFailure -At '2025-11-02T10:00:00Z'
Assert-Equal $window.StartUtc $equivalent.StartUtc 'Equivalent UTC instants got different windows.'
foreach ($at in @('', '2025-11-02', '2025-11-02T10:00:00', 'not a timestamp')) { Assert-Throws { Resolve-WdtIncidentWindow -Symptom AppFailure -At $at } 'Missing/invalid offset must fail.' }
Assert-Throws { Resolve-WdtIncidentWindow -Symptom Other -At '2025-11-02T10:00:00Z' } 'Unknown profile accepted.'
Assert-Throws { Resolve-WdtIncidentWindow -Symptom AppFailure -At '2025-11-02T10:00:00Z' -BeforeMinutes -1 } 'Negative shoulder accepted.'
Assert-Throws { Resolve-WdtIncidentWindow -Symptom AppFailure -At '2025-11-02T10:00:00Z' -BeforeMinutes 0 -AfterMinutes 0 } 'Empty window accepted.'
Assert-Throws { Resolve-WdtIncidentWindow -Symptom AppFailure -At '2025-11-02T10:00:00Z' -BeforeMinutes 43200 -AfterMinutes 1 } 'Oversized window accepted.'
$dstA = Resolve-WdtIncidentWindow -Symptom AppFailure -At '2025-10-26T02:30:00+02:00'
$dstB = Resolve-WdtIncidentWindow -Symptom AppFailure -At '2025-10-26T02:30:00+01:00'
Assert-True ($dstA.AtUtc -ne $dstB.AtUtc) 'Explicit DST offsets became ambiguous local time.'

function New-IncidentEvidence {
    param([string]$Id='e1', [string]$ModuleId='Crashes', [string]$At='2025-11-02T10:00:00Z', [string]$RecordId='101', [string]$ReportId='', [string]$Kind='Crash', [string]$Component='sample.exe', [string]$Code='0xc0000005', [string]$Provider='Application Error', [int]$EventId=1000, [string]$LogName='Application', [string]$Message='fixture')
    $sourceId = switch ($ModuleId) { Crashes { 'crash-source-1' } Events { 'event-log-1' } Updates { 'update-log-1' } }
    New-WdtDataEvidence -Id $Id -SourceId $sourceId -TimestampUtc $At -TimePrecision Instant -LogName $LogName -Provider $Provider -EventId $EventId -RecordId $RecordId -ReportId $ReportId -Kind $Kind -Component $Component -FailureCode $Code -Message $Message
}
function New-IncidentResults {
    param([object[]]$Crashes=@(), [object[]]$Events=@(), [object[]]$Updates=@(), [int]$EventLevel=1, [string]$Availability='Available', [object[]]$ExtraUpdateFacts=@(), [object[]]$ExtraUpdateSources=@(), $DataWindow=$window)
    foreach ($moduleId in @('Crashes','Events','Updates')) {
        $items = switch ($moduleId) { Crashes { $Crashes } Events { $Events } Updates { $Updates } }
        $sourceId = switch ($moduleId) { Crashes { 'crash-source-1' } Events { 'event-log-1' } Updates { 'update-log-1' } }
        $scope = switch ($moduleId) { Crashes { 'Application Error/1000' } Events { 'System/Levels=1,2' } Updates { 'System/WindowsUpdateClientFailures' } }
        $sources=@((New-WdtDataSource -Id $sourceId -Kind History -Scope $scope -Availability $Availability -QueryComplete ($Availability -eq 'Available') -StartUtc $DataWindow.StartUtc -EndUtc $DataWindow.EndUtc))
        $facts=@(); $index=0
        foreach ($item in @($items)) {
            $index++
            $type = switch ($moduleId) { Crashes { 'CrashObservation' } Events { 'EventObservation' } Updates { 'UpdateFailure' } }
            $values = switch ($moduleId) {
                Crashes { @{Component=$item.Component;Kind=$item.Kind;FailureCode=$item.FailureCode} }
                Events { @{Provider=$item.Provider;EventId=$item.EventId;Level=$EventLevel} }
                Updates { @{UpdateIdentifier=$null;Title=$item.Component;ErrorCode=$item.FailureCode;Kind='Installation'} }
            }
            $facts += New-WdtDataFact -Id ('f'+$index) -Type $type -IdentityScope SnapshotLocal -Values $values -Comparison Windowed -SourceIds @($sourceId) -EvidenceIds @($item.Id)
        }
        if ($moduleId -eq 'Updates') { $facts += $ExtraUpdateFacts; $sources += $ExtraUpdateSources }
        $data=New-WdtDiagnosticData -ModuleId $moduleId -WindowStartUtc $DataWindow.StartUtc -WindowEndUtc $DataWindow.EndUtc -Sources $sources -Facts $facts -Evidence @($items)
        [pscustomobject]@{Status='Success';ExitCode=0;Completeness='Complete';OutputComplete=$true;DataStatus=$(if ($Availability -eq 'Available') { 'Available' } else { 'Partial' });DataErrors=@();Data=$data}
    }
}
function New-IncidentFixture {
    param([object[]]$Results=(New-IncidentResults), $Window=$window, [bool]$PrivacyMode=$false, $Context=$null, [string]$Finished='2025-11-03T10:00:01Z', [string]$Started='2025-11-03T10:00:00Z')
    New-WdtIncident -Window $Window -Results $Results -ToolkitVersion test -CollectionStartedUtc $Started -CollectionFinishedUtc $Finished -PrivacyMode $PrivacyMode -Context $Context
}

$one=New-IncidentEvidence
$boundary=New-IncidentResults -Crashes @((New-IncidentEvidence -At $window.StartUtc), (New-IncidentEvidence -Id e2 -At $window.EndUtc -RecordId 102))
$incident=New-IncidentFixture -Results $boundary
Assert-Equal 1 $incident.Timeline.Count 'Window must include start and exclude end.'
Assert-Equal 1 $incident.Observations.Count 'A single target fact must not fill a summary quota.'

# Same source record from generic Events and Crashes: preserve every ref and
# select the target from all members, even if the generic record sorts first.
$same=New-IncidentEvidence -ModuleId Events -Kind Event -Component '' -Code ''
$linked=New-IncidentFixture -Results (New-IncidentResults -Crashes @($one) -Events @($same))
Assert-Equal 1 $linked.Timeline.Count 'Exact cross-module record duplicated the incident.'
Assert-Equal 2 $linked.Timeline[0].EvidenceRefs.Count 'Cross-module provenance was lost.'
Assert-True $linked.Timeline[0].IsTarget 'A generic event hid target eligibility.'
$generic=New-IncidentFixture -Results (New-IncidentResults -Events @((New-IncidentEvidence -ModuleId Events -Kind Event -Component '' -Code '' -Provider 'Fixture Provider' -EventId 99 -Message "Useful context`r`ncontinued")))
Assert-True ($generic.Timeline[0].Label -match 'Fixture Provider/99; Useful context continued') 'Generic event timeline lost provider/id/context.'
$unknownComponent=New-IncidentEvidence -Component 'Unknown application'
$unknownCopy=New-IncidentEvidence -Id e2 -Component 'Unknown application' -At '2025-11-02T12:00:00+02:00'
Assert-Equal 1 (New-IncidentFixture -Results (New-IncidentResults -Crashes @($unknownComponent,$unknownCopy))).Timeline.Count 'Exact source identity incorrectly required a known application.'

$guid='12345678-1234-4234-8234-123456789abc'
$crash=New-IncidentEvidence -ReportId $guid
$wer=New-IncidentEvidence -Id e2 -RecordId 202 -Provider 'Windows Error Reporting' -EventId 1001 -ReportId $guid -At '2025-11-02T10:00:15Z'
$linked=New-IncidentFixture -Results (New-IncidentResults -Crashes @($crash,$wer) -Events @($same))
Assert-Equal 1 $linked.Timeline.Count 'Compatible Application Error and WER with one GUID were not linked.'
Assert-Equal 3 $linked.Timeline[0].EvidenceRefs.Count 'Report linkage lost refs.'
$different=New-IncidentEvidence -Id e2 -RecordId 202 -ReportId '87654321-1234-4234-8234-123456789abc' -At '2025-11-02T10:00:30Z'
$independent=New-IncidentFixture -Results (New-IncidentResults -Crashes @($crash,$different))
Assert-Equal 2 $independent.Timeline.Count 'Two independent crashes within one minute disappeared.'
Assert-Equal 0 @($independent.Timeline | Where-Object { $_.AmbiguousWith.Count -gt 0 }).Count 'Distinct ReportIds were called ambiguous duplicates.'
foreach ($id in @('', 'Unknown', '00000000-0000-0000-0000-000000000000')) {
    $ambiguous=New-IncidentFixture -Results (New-IncidentResults -Crashes @((New-IncidentEvidence -RecordId '' -ReportId $id),(New-IncidentEvidence -Id e2 -RecordId '' -ReportId $id -At '2025-11-02T10:00:30Z')))
    Assert-Equal 2 $ambiguous.Timeline.Count 'Weak or zero identities removed observations.'
    Assert-True ($ambiguous.Timeline[0].AmbiguousWith.Count -gt 0) 'Weak identity ambiguity was hidden.'
    Assert-True (@($ambiguous.Observations | Where-Object Classification -eq TemporalCoincidence).Count -gt 0) 'Ambiguous identity must be labelled temporal coincidence.'
}
foreach ($other in @(
    (New-IncidentEvidence -Id e2 -At '2025-11-02T10:00:01Z'),
    (New-IncidentEvidence -Id e2 -Provider 'Other Provider'),
    (New-IncidentEvidence -Id e2 -RecordId 102)
)) { Assert-Equal 2 (New-IncidentFixture -Results (New-IncidentResults -Crashes @($one,$other))).Timeline.Count 'RecordId reuse or a distinct record was mistaken for an identical source record.' }
$conflicting=New-IncidentEvidence -Id e2 -RecordId 202 -ReportId $guid -Code '0xc0000409'
Assert-Equal 2 (New-IncidentFixture -Results (New-IncidentResults -Crashes @($crash,$conflicting))).Timeline.Count 'A shared GUID erased conflicting failure codes.'
$differentComponent=New-IncidentEvidence -Id e2 -RecordId 202 -ReportId $guid -Component other.exe
Assert-Equal 2 (New-IncidentFixture -Results (New-IncidentResults -Crashes @($crash,$differentComponent))).Timeline.Count 'A shared GUID erased incompatible components.'
$differentKind=New-IncidentEvidence -Id e2 -RecordId 202 -ReportId $guid -Kind Hang
Assert-Equal 2 (New-IncidentFixture -Results (New-IncidentResults -Crashes @($crash,$differentKind))).Timeline.Count 'A shared GUID erased incompatible kinds.'

# A generic record also links the same Updates event; Error20/31 are failures.
foreach ($id in @(20,31)) {
    $kind=if ($id -eq 20) { 'UpdateInstallationFailure' } else { 'UpdateDownloadFailure' }
    $update=New-IncidentEvidence -ModuleId Updates -Kind $kind -RecordId 303 -Provider 'Microsoft-Windows-WindowsUpdateClient' -EventId $id -At '2025-11-02T09:59:00Z' -Component 'KB123456' -Code '0x80240001' -LogName System
    $event=New-IncidentEvidence -ModuleId Events -Kind Event -RecordId 303 -Provider 'Microsoft-Windows-WindowsUpdateClient' -EventId $id -At '2025-11-02T09:59:00Z' -LogName System
    $context=New-IncidentFixture -Results (New-IncidentResults -Crashes @($one) -Events @($event) -Updates @($update))
    Assert-Equal 2 $context.Timeline.Count 'Exact Updates/Events evidence was not linked.'
    $relation=@($context.Observations | Where-Object Classification -eq TemporalCoincidence)
    Assert-Equal 1 $relation.Count 'Preceding update failure should supply one temporal observation.'
    Assert-True ($relation[0].Text -match 'before.*does not establish cause or a successful installation') 'Update ordering was overstated.'
    Assert-Equal 0 @($context.Observations | Where-Object Classification -eq Hypothesis).Count 'MVP generated a causal hypothesis.'
}
$restartWindow=Resolve-WdtIncidentWindow -Symptom unexpectedrestart -At $window.RequestedAt
$signal=New-IncidentEvidence -ModuleId Events -Kind Event -LogName System -Provider 'Microsoft-Windows-Kernel-Power' -EventId 41
$restart=New-IncidentFixture -Window $restartWindow -Results (New-IncidentResults -Events @($signal))
Assert-True $restart.Timeline[0].IsTarget 'Exact Kernel-Power41 signal was lost.'
Assert-True ($restart.Observations[0].Text -match 'does not establish BugCheck or cause') 'Event41 was overstated.'
foreach ($case in @('provider','level','channel')) {
    $badSignal=New-IncidentEvidence -ModuleId Events -Kind Event -LogName System -Provider 'Microsoft-Windows-Kernel-Power' -EventId 41
    $level=1
    if ($case -eq 'provider') { $badSignal.Provider='Wrong Provider' }
    if ($case -eq 'level') { $level=2 }
    if ($case -eq 'channel') { $badSignal.LogName='Application' }
    $badRestart=New-IncidentFixture -Window $restartWindow -Results (New-IncidentResults -Events @($badSignal) -EventLevel $level)
    Assert-Equal 0 @($badRestart.Timeline | Where-Object IsTarget).Count 'Wrong provider/level/channel became a restart signal.'
}
$bug=New-IncidentEvidence -Kind BugCheck -Component Windows -Provider 'Microsoft-Windows-WER-SystemErrorReporting' -EventId 1001
Assert-True (New-IncidentFixture -Window $restartWindow -Results (New-IncidentResults -Crashes @($bug))).Timeline[0].IsTarget 'Recognized historical BugCheck was discarded by recency.'
Assert-Equal 0 @((New-IncidentFixture -Results (New-IncidentResults -Crashes @($bug))).Timeline | Where-Object IsTarget).Count 'BugCheck became an application failure.'

# No current reboot state is projected back into the historical incident.
$reboot=New-WdtDataFact -Id f90 -Type RebootIndicator -Key reboot -Comparison Configuration -Values @{Name='Reboot pending';Present=$true} -SourceIds @('reboot-1')
$rebootSource=New-WdtDataSource -Id reboot-1 -Kind Configuration -Scope 'RebootIndicator/Component Based Servicing RebootPending' -Coverage CurrentState
$empty=New-IncidentFixture -Results (New-IncidentResults -ExtraUpdateFacts @($reboot) -ExtraUpdateSources @($rebootSource))
Assert-Equal 0 $empty.Observations.Count 'Empty evidence or current reboot flags invented an observation.'
Assert-True (($empty.Limitations -join ' ') -match 'does not establish system health') 'Empty result declared health.'
Assert-True (($empty.Limitations -join ' ') -match 'Current reboot/service states') 'Current-state limitation missing.'
foreach ($availability in @('Partial','Unavailable','NotCollected')) {
    $partial=New-IncidentFixture -Results (New-IncidentResults -Availability $availability)
    Assert-Equal $availability $partial.Coverage[0].Source.Availability 'Source state was collapsed into empty success.'
    Assert-Equal 0 $partial.ExitCode 'Valid unavailable source should not become an execution failure.'
}
$missing=New-IncidentResults; $missing[0].Data=$null; $missing[0].DataStatus='Unavailable'
$lost=New-IncidentFixture -Results $missing
Assert-Equal 1 $lost.ExitCode 'Missing requested machine protocol succeeded.'
Assert-Equal $null $lost.Coverage[0].Source 'Missing module source became a fabricated empty source.'
$partial=New-IncidentResults; $partial[0].DataStatus='Partial'; $partial[0].Data.Sources[0].Availability='Partial'; $partial[0].Data.Sources[0].QueryComplete=$false; $partial[0].Data.Sources[0].Truncated=$true; $partial[0].Data.Sources[0].Limit=20
Assert-True (New-IncidentFixture -Results $partial).Coverage[0].Source.Truncated 'Query cap disappeared.'

# Date-only data never receives a place in the exact timeline.
function New-DateResults {
    param([string]$Precision='Unknown',[string]$Date='2025-11-02')
    $r=New-IncidentResults
    $r[2].Data.Sources+=New-WdtDataSource -Id hotfix -Kind Inventory -Scope 'Get-HotFix/HotFixID' -Coverage CurrentState
    $e=New-WdtDataEvidence -Id e90 -SourceId hotfix -Kind HotFix -Component KB123456 -TimePrecision $Precision
    if ($Precision -eq 'Day') { $e.TimestampUtc='2025-11-02T00:00:00Z'; $e.EndUtc='2025-11-03T00:00:00Z' }
    $r[2].Data.Evidence+= $e
    $r[2].Data.Facts+=New-WdtDataFact -Id f90 -Type HotFix -Key KB123456 -Comparison Inventory -Values @{HotFixId='KB123456';InstalledDate=$Date} -SourceIds @('hotfix') -EvidenceIds @('e90')
    return $r
}
foreach ($precision in @('Unknown','Day')) {
    $dated=New-IncidentFixture -Results (New-DateResults -Precision $precision)
    Assert-Equal 0 $dated.Timeline.Count 'Date-only update became a midnight event.'
    Assert-Equal 1 $dated.DateContext.Count 'Overlapping date context was lost.'
    if ($precision -eq 'Unknown') {
        Assert-Equal $null $dated.DateContext[0].StartUtc 'Unknown historical timezone invented UTC.'
        Assert-True ($dated.DateContext[0].Reason -match 'Possible date overlap only') 'Inferred overlap was presented as fact.'
    }
}
Assert-Equal 0 (New-IncidentFixture -Results (New-DateResults -Date '2025-10-20')).DateContext.Count 'Unrelated date context leaked into window.'
$future=Resolve-WdtIncidentWindow -Symptom AppFailure -At '2028-01-01T00:00:00Z'
$futureReport=New-IncidentFixture -Window $future -Results (New-IncidentResults -DataWindow $future)
Assert-Equal $null $futureReport.ObservedStartUtc 'Future window has an invented observed interval.'
Assert-Equal $null $futureReport.ObservedThroughUtc 'Future window has an invented observed end.'
Assert-True (($futureReport.Limitations -join ' ') -match 'no observed past intersection') 'Entirely future request not explained.'
$mixedFuture=New-IncidentFixture -Results (New-IncidentResults) -Started '2025-11-02T09:59:59Z' -Finished '2025-11-02T10:00:01Z'
Assert-Equal '2025-11-02T10:00:01.0000000Z' $mixedFuture.ObservedThroughUtc 'Future part was treated as observed.'
$futureClock=New-IncidentFixture -Results (New-IncidentResults -Crashes @((New-IncidentEvidence -At '2025-11-02T10:01:00Z'))) -Started '2025-11-02T09:59:59Z' -Finished '2025-11-02T10:00:01Z'
Assert-Equal 0 $futureClock.Timeline.Count 'Future source timestamp became an observed future fact.'
Assert-Equal 1 $futureClock.Evidence.Count 'Future source timestamp was silently discarded.'
Assert-True (($futureClock.Limitations -join ' ') -match 'timestamp/clock inconsistency') 'Future clock anomaly not explained.'

# API validation is independent of CLI binding and never mutates raw input.
$badWindow=$window | ConvertTo-Json | ConvertFrom-Json; $badWindow.EndUtc='2025-11-02T11:00:00Z'
Assert-Throws { New-IncidentFixture -Window $badWindow } 'API accepted inconsistent precomputed bounds.'
$badData=New-IncidentResults; $badData[0].Data.ModuleId='Events'
Assert-Throws { New-IncidentFixture -Results $badData } 'API accepted an incompatible module.'
$secret='https://alice:pw@host.invalid/?token=incident-secret'
$message='HOST-PRIVATE Alice C:\Users\Alice\private 192.0.2.15 00-11-22-33-44-55 '+$secret+" `````````````r`nSummary observations:`r`n[Fact] injected row"
$message += "`r`n"+'<Event><Data>The process svchost.exe has initiated the restart of computer HOST-PRIVATE on behalf of user Alice</Data><Data>Alice.smith@example.test</Data><Data>GoogleUpdateTaskUserS-1-5-21-111111111-222222222-333333333-1001Core</Data><Data>tool.exe --api-key=incident-api-secret --access-token=incident-access-secret --client-secret=incident-client-secret --pwd=incident-pwd-secret</Data></Event>'+"`r`nDNS suffix: incident.private.test`r`nDNS search list: branch.incident.private.test`r`nProxy server: incident-proxy.private.test:8080`r`nAuto config URL: https://incident-pac.private.test/private/config.pac"
$privateValues = @('HOST-PRIVATE','Alice','192.0.2.15','00-11-22-33-44-55',$guid,'incident-secret','alice:pw','smith@example.test','S-1-5-21-','incident-api-secret','incident-access-secret','incident-client-secret','incident-pwd-secret','incident.private.test','incident-proxy.private.test','incident-pac.private.test','/private/config.pac')
$unicode=-join @([char]0x041F,[char]0x0440,[char]0x0438,[char]0x043B,[char]0x043E,[char]0x0436,[char]0x0435,[char]0x043D,[char]0x0438,[char]0x0435)
$private=New-IncidentResults -Crashes @((New-IncidentEvidence -ReportId $guid -Component ('HOST-PRIVATE '+$unicode+"`r`ncomponent row") -Message $message))
$private[0].DataStatus='Partial'; $private[0].DataErrors=@($message); $private[0].Data.Sources[0].Availability='Partial'; $private[0].Data.Sources[0].QueryComplete=$false; $private[0].Data.Sources[0].Error=$message
$rawBefore=ConvertTo-Json -InputObject $private -Depth 16 -Compress
$privacyContext=New-WdtRedactionContext -ComputerName HOST-PRIVATE -UserName Alice -UserDomain DOMAIN -UserProfile 'C:\Users\Alice'
$safe=New-IncidentFixture -Results $private -PrivacyMode $true -Context $privacyContext
$safeText=(Get-WdtIncidentLines $safe) -join "`n"
foreach ($raw in $privateValues) { Assert-True (-not $safeText.Contains($raw)) 'Private data leaked through summaries, timeline, appendix or coverage/errors.' }
Assert-True ($safeText.Contains($unicode)) 'Unicode diagnostic context was lost.'
Assert-True ($safe.Timeline[0].Label -notmatch '[\r\n]' -and $safe.Observations[0].Text -notmatch '[\r\n]') 'Source newlines split summary/timeline rows.'
Assert-True ($safe.Evidence[0].Item.Message -match '[\r\n]') 'Presentation normalization destroyed full redacted evidence.'
Assert-Equal 1 @((Get-WdtIncidentLines $safe) | Where-Object { $_ -ceq 'Summary observations:' }).Count 'Multiline evidence injected a new summary section.'
Assert-True (@((Get-WdtIncidentLines $safe) | Where-Object { $_ -match '[\r\n]' }).Count -eq 0) 'Multiline source/error text escaped a labelled report row.'
Assert-Equal $rawBefore (ConvertTo-Json -InputObject $private -Depth 16 -Compress) 'Incident projection mutated raw inputs.'
Assert-True (-not (ConvertTo-Json $safe -Depth 20).Contains('TokenMaps')) 'Redaction map was returned.'
$autoPrivate=New-IncidentFixture -Results (New-IncidentResults -Crashes @((New-IncidentEvidence -Message '192.0.2.15'))) -PrivacyMode $true
Assert-True (-not ((Get-WdtIncidentLines $autoPrivate) -join ' ').Contains('192.0.2.15')) 'PrivacyMode without caller Context was bypassed.'
$public=New-IncidentFixture -Results (New-IncidentResults -Crashes @((New-IncidentEvidence -Message $secret)))
Assert-True (-not ((Get-WdtIncidentLines $public) -join ' ').Contains('incident-secret')) 'Secrets were retained with PrivacyMode disabled.'
foreach ($observation in $safe.Observations) { foreach ($ref in $observation.EvidenceRefs) { Assert-True ($safe.Evidence.Ref -contains $ref) 'Summary reference is not traceable to the appendix.' }; foreach ($ref in $observation.TimelineRefs) { Assert-True ($safe.Timeline.Id -contains $ref) 'Summary timeline reference dangles.' } }
foreach ($entry in $linked.Timeline) { foreach ($ref in $entry.EvidenceRefs) { Assert-True ($linked.Evidence.Ref -contains $ref) 'Linked timeline lost a source reference.' } }

# Validate the public action before it can create output or run diagnostics.
$entrypoint=Join-Path $repositoryRoot 'Invoke-WindowsDiagnostics.ps1'
$invalidOutput=Join-Path ([IO.Path]::GetTempPath()) ('wdt-incident-invalid-'+[guid]::NewGuid().ToString('N'))
foreach ($request in @(
    @{IncidentSymptom='AppFailure'},
    @{IncidentAt='2025-11-02T10:00:00Z'},
    @{IncidentBeforeMinutes=15},
    @{IncidentSymptom='AppFailure';IncidentAt='2025-11-02T10:00:00'},
    @{IncidentSymptom='AppFailure';IncidentAt='2025-11-02T10:00:00Z';IncidentBeforeMinutes=0;IncidentAfterMinutes=0},
    @{IncidentSymptom='AppFailure';IncidentAt='2025-11-02T10:00:00Z';IncidentBeforeMinutes=-1},
    @{IncidentSymptom='AppFailure';IncidentAt='2025-11-02T10:00:00Z';All=$true},
    @{IncidentSymptom='AppFailure';IncidentAt='2025-11-02T10:00:00Z';Module=@('Crashes')},
    @{IncidentSymptom='AppFailure';IncidentAt='2025-11-02T10:00:00Z';Crashes=$true},
    @{IncidentSymptom='AppFailure';IncidentAt='2025-11-02T10:00:00Z';Interactive=$true},
    @{IncidentSymptom='AppFailure';IncidentAt='2025-11-02T10:00:00Z';SaveSnapshot=$true},
    @{IncidentSymptom='AppFailure';IncidentAt='2025-11-02T10:00:00Z';BeforeSnapshot='missing';AfterSnapshot='missing'},
    @{IncidentSymptom='AppFailure';IncidentAt='2025-11-02T10:00:00Z';NoExternalNetworkTests=$true}
)) {
    Assert-Throws { & $entrypoint @request -OutputDirectory $invalidOutput } 'Conflicting or invalid incident CLI request was accepted.'
    Assert-True (-not (Test-Path -LiteralPath $invalidOutput)) 'Invalid CLI input wrote output before validation.'
}

# Exercise the concrete main action using typed fixture results, preserving
# privacy before file writes and using the existing dynamic Markdown fence.
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($entrypoint,[ref]$tokens,[ref]$parseErrors)
foreach ($name in @('Invoke-WdtIncident','Initialize-WdtOutputDirectory','Get-WdtUniqueReportPaths','Get-WdtMarkdownFence','Get-CurrentPowerShellPath')) {
    $definition=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))[0]
    . ([scriptblock]::Create($definition.Extent.Text))
}
. (Join-Path $repositoryRoot 'scripts\module-registry.ps1')
$registrySnapshot=Get-WdtModuleRegistry -ModuleRoot (Join-Path $repositoryRoot 'modules')
$coreOptions=@{}; $toolkitVersion='test'; $script:fixtureCallIndex=0; $script:fixtureInvocation=@(); $script:fixtureResults=$private
function Invoke-DiagnosticScript {
    param($Title,$ScriptPath,$PowerShellPath,$RepositoryRoot,$TimeoutSeconds,$ScriptArguments,[switch]$CollectData,$ModuleId,$DataStartUtc,$DataEndUtc)
    $script:fixtureInvocation+= [pscustomobject]@{ModuleId=$ModuleId;CollectData=[bool]$CollectData;Start=$DataStartUtc;End=$DataEndUtc;Timeout=$TimeoutSeconds}
    $value=$script:fixtureResults[$script:fixtureCallIndex]; $script:fixtureCallIndex++
    return $value
}
$output=Join-Path ([IO.Path]::GetTempPath()) ('wdt-incident-fixture-'+[guid]::NewGuid().ToString('N'))
try {
    $result = & {
        function New-WdtRedactionContext { return $privacyContext }
        Invoke-WdtIncident -Window $window -OutputDirectory $output -PrivacyMode $true -ExportMarkdown $true -ModuleTimeoutSeconds 17
    }
    Assert-Equal 3 $script:fixtureInvocation.Count 'Incident did not collect exactly the three selected modules once.'
    Assert-Equal 'Crashes,Events,Updates' ($script:fixtureInvocation.ModuleId -join ',') 'Incident module ordering changed.'
    foreach ($call in $script:fixtureInvocation) { Assert-True ($call.CollectData -and $call.Start -eq $window.StartUtc -and $call.End -eq $window.EndUtc -and $call.Timeout -eq 17) 'Incident window/timeout did not reach the existing runner.' }
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $output -Filter '*.json' -File).Count 'Incident unexpectedly wrote JSON.'
    $txt=[IO.File]::ReadAllText($result.TextReportPath,[Text.Encoding]::UTF8)
    $md=[IO.File]::ReadAllText($result.MarkdownReportPath,[Text.Encoding]::UTF8)
    Assert-True ($txt.Contains($unicode) -and $md.Contains($unicode)) 'Concrete artifacts lost Unicode.'
    Assert-True (-not $txt.Contains('incident-secret') -and -not $md.Contains('incident-secret')) 'Raw secret reached an artifact.'
    foreach ($raw in $privateValues) { Assert-True (-not $txt.Contains($raw) -and -not $md.Contains($raw)) 'A private fixture value reached a concrete TXT/Markdown artifact.' }
    $mdLines=[IO.File]::ReadAllLines($result.MarkdownReportPath,[Text.Encoding]::UTF8)
    Assert-Equal '```````text' $mdLines[2] 'Markdown fence did not protect embedded backticks.'
    Assert-Equal '```````' $mdLines[-1] 'Markdown report fence is unbalanced.'
    $names=@(Get-ChildItem -LiteralPath $output -File | ForEach-Object Name)
    Assert-Equal 2 $names.Count 'Incident action produced unexpected artifacts.'
    Assert-True (@($names | Where-Object { $_ -notlike 'WindowsDiagnosticsIncident-*' }).Count -eq 0) 'Incident reused ordinary report names.'
}
finally {
    if (Test-Path -LiteralPath $output) {
        $resolved=(Resolve-Path -LiteralPath $output).Path
        $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if (-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Output 'Incident regression tests passed.'
