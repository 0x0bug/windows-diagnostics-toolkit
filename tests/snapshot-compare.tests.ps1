[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\snapshot-compare.ps1')
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected,$Actual,[string]$Message) if ($Expected -cne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }
function New-ComparisonFixture {
    param([object[]]$Facts=@(),[string]$Availability='Available',[string]$ModuleId='Updates',[object[]]$Evidence=@(),[string]$Scope='Get-HotFix/HotFixID')
    $source=New-WdtDataSource -Id hotfix -Kind Inventory -Scope $Scope -Availability $Availability -QueryComplete ($Availability -eq 'Available') -Coverage CurrentState
    if ($ModuleId -eq 'Crashes') { $source=New-WdtDataSource -Id crash-source-1 -Kind History -Scope 'Application Error/1000' -Availability $Availability -QueryComplete ($Availability -eq 'Available') -StartUtc '2026-10-26T12:00:00Z' -EndUtc '2026-11-02T12:00:00Z' }
    $data=New-WdtDiagnosticData -ModuleId $ModuleId -Sources @($source) -Facts $Facts -Evidence $Evidence -WindowStartUtc '2026-10-26T12:00:00Z' -WindowEndUtc '2026-11-02T12:00:00Z'
    $status=if ($Availability -eq 'Available') { 'Available' } else { 'Partial' }
    $result=[pscustomobject]@{Status='Success';ExitCode=0;Completeness='Complete';OutputComplete=$true;DataStatus=$status;DataErrors=@();Data=$data}
    New-WdtSnapshot -ToolkitVersion test -ModuleIds @($ModuleId) -Results @($result) -CollectionStartedUtc '2026-11-02T12:00:00Z' -CollectionFinishedUtc '2026-11-02T12:00:01Z' -WindowStartUtc '2026-10-26T12:00:00Z' -WindowEndUtc '2026-11-02T12:00:00Z'
}
function New-HotFixFact { param([string]$Id='f1',[string]$Key='KB123456') New-WdtDataFact -Id $Id -Type HotFix -Key $Key -Values @{HotFixId=$Key;InstalledDate=$null} -Comparison Inventory -SourceIds @('hotfix') }
function Get-State { param($Before,$After) @((Compare-WdtSnapshots $Before $After).Differences)[0].State }
$full=New-ComparisonFixture -Facts @((New-HotFixFact))
$empty=New-ComparisonFixture
Assert-Equal Removed (Get-State $full $empty) 'Complete after inventory should establish removal.'
Assert-Equal Added (Get-State $empty $full) 'Complete before inventory should establish addition.'
foreach ($availability in @('Partial','Unavailable','NotCollected')) {
    $incomplete=New-ComparisonFixture -Availability $availability
    Assert-Equal InformationLost (Get-State $full $incomplete) 'Incomplete after must not establish removal.'
    Assert-Equal NewlyObserved (Get-State $incomplete $full) 'Incomplete before must not establish addition.'
}
$brokenExecution=New-ComparisonFixture
$brokenExecution.Modules[0].Status='Timeout';$brokenExecution.Modules[0].Completeness='Partial';$brokenExecution.Modules[0].ExitCode=124
Assert-Equal InformationLost (Get-State $full $brokenExecution) 'A successful query cannot override execution loss.'
$unselected=New-ComparisonFixture;$unselected.Modules[0].Data=$null;$unselected.Modules[0].DataStatus='NotCollected'
Assert-Equal InformationLost (Get-State $full $unselected) 'NotCollected cannot become a complete empty inventory.'
$known=New-ComparisonFixture -Facts @((New-HotFixFact))
$unknown=New-ComparisonFixture -Facts @((New-HotFixFact));$unknown.Modules[0].Data.Facts[0].ValueState='Unknown';$unknown.Modules[0].Data.Facts[0].Values.HotFixId=$null
Assert-Equal InformationLost (Get-State $known $unknown) 'Known to Unknown is information loss.'
Assert-Equal InformationGained (Get-State $unknown $known) 'Unknown to Known is information gained.'

# Actual false, zero, and empty strings remain Known values rather than absence.
function New-ValueFixture {
    param([string]$State='Known')
    $source=New-WdtDataSource -Id reboot-1 -Kind Configuration -Scope 'RebootIndicator/Component Based Servicing RebootPending' -Coverage CurrentState
    $fact=New-WdtDataFact -Id f1 -Type RebootIndicator -Key reboot -ValueState $State -Comparison Configuration -Values @{Name='';Present=$false} -SourceIds @('reboot-1')
    if ($State -ne 'Known') { $fact.Values.Name=$null;$fact.Values.Present=$null }
    $s=New-ComparisonFixture
    $s.Modules[0].Data.Sources=@($source);$s.Modules[0].Data.Facts=@($fact)
    return $s
}
Assert-Equal InformationLost (Get-State (New-ValueFixture) (New-ValueFixture Unknown)) 'Known false/empty was treated as Unknown.'
$zero=New-ComparisonFixture -ModuleId Crashes
$zero.SelectedModules=@('Events');$zero.Modules[0].ModuleId='Events'
$zero.Modules[0].Data=New-WdtDiagnosticData -ModuleId Events -WindowStartUtc $zero.WindowStartUtc -WindowEndUtc $zero.WindowEndUtc -Sources @((New-WdtDataSource -Id event-log-1 -Kind History -Scope 'System/Levels=1,2')) -Facts @((New-WdtDataFact -Id f1 -Type EventObservation -Key event-zero -Comparison Windowed -Values @{Provider='';EventId=0;Level=0} -SourceIds @('event-log-1')))
Assert-WdtSnapshot $zero
Assert-Equal 1 (Compare-WdtSnapshots $zero $zero).Differences[0].BeforeValues.Count 'Known zero/empty event fields disappeared.'

$unrelated=New-ComparisonFixture
$unrelated.Modules[0].Data.Sources+=New-WdtDataSource -Id reboot-1 -Kind Configuration -Scope 'RebootIndicator/Component Based Servicing RebootPending' -Availability Unavailable -QueryComplete $false -Error 'fixture unavailable'
$unrelated.Modules[0].DataStatus='Partial'
Assert-Equal Removed (Get-State $full $unrelated) 'An unrelated unavailable source blocked a complete hotfix inventory.'
$differentLimit=New-ComparisonFixture;$differentLimit.Modules[0].Data.Sources[0].Limit=10
Assert-Equal InformationLost (Get-State $full $differentLimit) 'A different source query limit was treated as identical coverage.'
$dated=New-ComparisonFixture -Facts @((New-HotFixFact));$dated.Modules[0].Data.Facts[0].Values.InstalledDate='2025-01-01'
Assert-Equal Changed (Get-State $known $dated) 'Known metadata change was lost.'
Assert-True ((Compare-WdtSnapshots $known $dated).Differences[0].Reason -match 'does not establish reinstallation') 'Date-quality change was overstated.'

# Literal privacy tokens may never supply semantic identity, even in untrusted JSON.
foreach ($pair in @(@('<USER-1>','<USER-1>'),@('<USER-1>','<USER-2>'))) {
    $before=New-ComparisonFixture -Facts @((New-HotFixFact -Key $pair[0]))
    $after=New-ComparisonFixture -Facts @((New-HotFixFact -Key $pair[1]))
    $before.PrivacyMode=$true;$after.PrivacyMode=$true
    $diff=Compare-WdtSnapshots $before $after
    Assert-True (@($diff.Differences | Where-Object { $_.State -ne 'NotComparable' }).Count -eq 0) 'Tokens were used as cross-snapshot identities.'
}
$local=New-ComparisonFixture -Facts @((New-HotFixFact));$local.Modules[0].Data.Facts[0].IdentityScope='SnapshotLocal';$local.Modules[0].Data.Facts[0].Key=$null
Assert-Equal NotComparable (Get-State $local $empty) 'Local identity was reported as removed.'

$evidence=New-WdtDataEvidence -Id e1 -SourceId crash-source-1 -TimestampUtc '2026-10-26T13:00:00Z' -TimePrecision Instant -Kind Crash
$crash=New-WdtDataFact -Id f1 -Type CrashObservation -Key 'fixture.exe|Crash|0x1' -Comparison Windowed -Values @{Component='fixture.exe';Kind='Crash';FailureCode='0x1'} -SourceIds @('crash-source-1') -EvidenceIds @('e1')
$before=New-ComparisonFixture -ModuleId Crashes -Facts @($crash) -Evidence @($evidence)
$after=New-ComparisonFixture -ModuleId Crashes
$after.WindowStartUtc='2026-10-27T12:00:00Z';$after.WindowEndUtc='2026-11-03T12:00:00Z';$after.Modules[0].Data.WindowStartUtc=$after.WindowStartUtc;$after.Modules[0].Data.WindowEndUtc=$after.WindowEndUtc
$after.Modules[0].Data.Sources[0].StartUtc=$after.WindowStartUtc;$after.Modules[0].Data.Sources[0].EndUtc=$after.WindowEndUtc
$diff=Compare-WdtSnapshots $before $after
Assert-Equal WindowedObservations $diff.Differences[0].State 'History was treated as inventory.'
Assert-Equal 1 $diff.Differences[0].BeforeValues.Count 'Observation counts were lost.'
Assert-Equal ($before.SnapshotId+'/Crashes/e1') $diff.Differences[0].BeforeEvidenceRefs[0] 'Evidence references are not snapshot/module-qualified.'
Assert-True ($diff.Differences[0].Reason -match 'window') 'Rolling history absence needs a window limitation.'
$zeroOther=$zero | ConvertTo-Json -Depth 16 | ConvertFrom-Json
$zeroOther.Modules[0].Data.Sources[0].Scope='System/Levels=1,2,3'
Assert-Equal NotComparable (Get-State $zero $zeroOther) 'Different event query filters were compared as equivalent.'
$text=(Get-WdtSnapshotComparisonLines $diff) -join "`n"
Assert-True ($text -notmatch 'regression|fixed|cause:') 'Comparison invented a causal or regression verdict.'

$raw=New-ComparisonFixture -Facts @((New-HotFixFact -Key 'PRIVATE-HOST'))
$private=New-ComparisonFixture;$private.PrivacyMode=$true
$context=New-WdtRedactionContext -ComputerName PRIVATE-HOST -UserName PrivateUser -UserProfile 'C:\Users\PrivateUser'
$mixed=Compare-WdtSnapshots $raw $private -Context $context
Assert-True $mixed.PrivacyMode 'Mixed privacy did not inherit stricter privacy.'
Assert-True ((($mixed | ConvertTo-Json -Depth 20) -notmatch 'PRIVATE-HOST')) 'Mixed privacy leaked raw input.'
Assert-Equal 'PRIVATE-HOST' $raw.Modules[0].Data.Facts[0].Values.HotFixId 'Comparison mutated input.'
$hostile=New-ComparisonFixture -Facts @((New-HotFixFact -Key 'fixture```|header'))
$markdown=@(Get-WdtSnapshotComparisonLines (Compare-WdtSnapshots (New-ComparisonFixture) $hostile) -Markdown)
Assert-Equal '````text' $markdown[2] 'Markdown output did not fence untrusted backtick runs.'
Assert-Equal '````' $markdown[-1] 'Markdown fence was not closed.'
Write-Host 'Snapshot comparison tests passed.'
