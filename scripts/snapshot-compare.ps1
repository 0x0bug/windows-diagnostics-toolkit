[CmdletBinding()]
param()

. $PSScriptRoot\snapshot.ps1
. $PSScriptRoot\diagnostic-data.ps1
. $PSScriptRoot\report-common.ps1

function Get-WdtSnapshotModule {
    param($Snapshot,[string]$ModuleId)
    return @($Snapshot.Modules | Where-Object { $_.ModuleId -ceq $ModuleId }) | Select-Object -First 1
}

function Get-WdtSnapshotSource {
    param($Module,[string]$SourceId)
    if ($null -eq $Module -or $null -eq $Module.Data) { return $null }
    return @($Module.Data.Sources | Where-Object { $_.Id -ceq $SourceId }) | Select-Object -First 1
}

function Test-WdtSnapshotSourceMatch {
    param($BeforeSource,$AfterSource)
    return ($null -ne $BeforeSource -and $null -ne $AfterSource -and $BeforeSource.Id -ceq $AfterSource.Id -and $BeforeSource.Scope -ceq $AfterSource.Scope -and $BeforeSource.Kind -ceq $AfterSource.Kind -and $BeforeSource.Coverage -ceq $AfterSource.Coverage -and $BeforeSource.Limit -eq $AfterSource.Limit)
}

function Test-WdtSnapshotInventoryComplete {
    param($InventoryModule,$ReferenceModule,$Fact)
    if ($null -eq $InventoryModule -or $null -eq $InventoryModule.Data -or $InventoryModule.Status -ne 'Success' -or $InventoryModule.Completeness -ne 'Complete' -or -not $InventoryModule.OutputComplete -or $InventoryModule.DataStatus -notin @('Available','Partial')) { return $false }
    foreach ($id in $Fact.SourceIds) {
        $source=Get-WdtSnapshotSource $InventoryModule $id
        $reference=Get-WdtSnapshotSource $ReferenceModule $id
        if (-not (Test-WdtSnapshotSourceMatch $source $reference) -or $source.Kind -ne 'Inventory' -or $source.Coverage -ne 'CurrentState' -or $source.Availability -ne 'Available' -or -not $source.QueryComplete -or $source.Truncated) { return $false }
    }
    return $true
}

function Test-WdtSnapshotFactSourcesMatch {
    param($BeforeModule,$AfterModule,$BeforeFact,$AfterFact)
    if ((($BeforeFact.SourceIds | Sort-Object) -join '|') -cne (($AfterFact.SourceIds | Sort-Object) -join '|')) { return $false }
    foreach ($id in $BeforeFact.SourceIds) {
        if (-not (Test-WdtSnapshotSourceMatch (Get-WdtSnapshotSource $BeforeModule $id) (Get-WdtSnapshotSource $AfterModule $id))) { return $false }
    }
    return $true
}

function Get-WdtSnapshotEvidenceRefs {
    param($Snapshot,[string]$ModuleId,[object[]]$Facts)
    return @($Facts | ForEach-Object { $_.EvidenceIds } | Sort-Object -Unique | ForEach-Object { '{0}/{1}/{2}' -f $Snapshot.SnapshotId,$ModuleId,$_ })
}

function Get-WdtSnapshotObservationSummary {
    param($Module,[object[]]$Facts)
    $ids=@($Facts | ForEach-Object { $_.EvidenceIds })
    $times=@()
    if ($null -ne $Module -and $null -ne $Module.Data) {
        $times=@($Module.Data.Evidence | Where-Object { $ids -ccontains $_.Id -and $null -ne $_.TimestampUtc } | ForEach-Object { ConvertTo-WdtDataUtcText $_.TimestampUtc } | Sort-Object)
    }
    $first=$null; $last=$null
    if ($times.Count -gt 0) { $first=$times[0]; $last=$times[-1] }
    return [pscustomobject]@{Count=$Facts.Count;FirstUtc=$first;LastUtc=$last}
}

function Test-WdtSnapshotValuesEqual {
    param($BeforeValues,$AfterValues)
    foreach ($property in $BeforeValues.PSObject.Properties) {
        $a=$property.Value; $b=$AfterValues.($property.Name)
        if (($null -eq $a) -ne ($null -eq $b) -or ($null -ne $a -and $a -cne $b)) { return $false }
    }
    return $true
}

function Compare-WdtSnapshots {
    param([Parameter(Mandatory=$true)]$Before,[Parameter(Mandatory=$true)]$After,[bool]$PrivacyMode=$false,$Context)
    Assert-WdtSnapshot $Before; Assert-WdtSnapshot $After
    $effectivePrivacy=$PrivacyMode -or $Before.PrivacyMode -or $After.PrivacyMode
    if ($effectivePrivacy -and $null -eq $Context) { $Context=New-WdtRedactionContext }
    # Independent copies preserve the source files and their local token scopes.
    # No privacy token, even a literal supplied in JSON, becomes a semantic key.
    $beforeSafe=Protect-WdtSnapshot $Before $Context -PrivacyMode $effectivePrivacy
    $afterSafe=Protect-WdtSnapshot $After $Context -PrivacyMode $effectivePrivacy
    $differences=New-Object System.Collections.Generic.List[object]
    $coverage=New-Object System.Collections.Generic.List[object]
    $moduleIds=@(($beforeSafe.SelectedModules+$afterSafe.SelectedModules) | Sort-Object -Unique)
    foreach ($moduleId in $moduleIds) {
        $beforeModule=Get-WdtSnapshotModule $beforeSafe $moduleId
        $afterModule=Get-WdtSnapshotModule $afterSafe $moduleId
        foreach ($side in @('Before','After')) {
            $module=if ($side -eq 'Before') { $beforeModule } else { $afterModule }
            if ($null -eq $module -or $null -eq $module.Data) {
                $coverage.Add([pscustomobject]@{Side=$side;ModuleId=$moduleId;SourceId=$null;Scope=$null;Kind=$null;Availability=$(if ($null -eq $module) { 'NotCollected' } else { $module.DataStatus });QueryComplete=$false;Truncated=$false;Limit=$null;Coverage='Unknown';StartUtc=$null;EndUtc=$null;Error=$null;DataErrors=$(if ($null -eq $module) { @() } else { @($module.DataErrors) });Execution=$(if ($null -eq $module) { 'NotCollected' } else { $module.Status });DataStatus=$(if ($null -eq $module) { 'NotCollected' } else { $module.DataStatus })})
            }
            else {
                foreach ($source in $module.Data.Sources) {
                    $coverage.Add([pscustomobject]@{Side=$side;ModuleId=$moduleId;SourceId=$source.Id;Scope=$source.Scope;Kind=$source.Kind;Availability=$source.Availability;QueryComplete=$source.QueryComplete;Truncated=$source.Truncated;Limit=$source.Limit;Coverage=$source.Coverage;StartUtc=(ConvertTo-WdtDataUtcText $source.StartUtc);EndUtc=(ConvertTo-WdtDataUtcText $source.EndUtc);Error=$source.Error;DataErrors=@($module.DataErrors);Execution=$module.Status;DataStatus=$module.DataStatus})
                }
            }
        }
        $beforeFacts=@();$afterFacts=@()
        if ($null -ne $beforeModule -and $null -ne $beforeModule.Data) { $beforeFacts=@($beforeModule.Data.Facts) }
        if ($null -ne $afterModule -and $null -ne $afterModule.Data) { $afterFacts=@($afterModule.Data.Facts) }
        foreach ($side in @('Before','After')) {
            $facts=if ($side -eq 'Before') { $beforeFacts } else { $afterFacts }
            $snapshot=if ($side -eq 'Before') { $beforeSafe } else { $afterSafe }
            foreach ($fact in @($facts | Where-Object { $_.IdentityScope -ne 'Semantic' })) {
                $refs=@(Get-WdtSnapshotEvidenceRefs $snapshot $moduleId @($fact))
                $differences.Add([pscustomobject]@{ModuleId=$moduleId;Type=$fact.Type;Key=$null;State='NotComparable';Reason=($side+' snapshot-local identity cannot be matched across redaction scopes.');BeforeValues=$(if ($side -eq 'Before') { $fact.Values } else { $null });AfterValues=$(if ($side -eq 'After') { $fact.Values } else { $null });BeforeEvidenceRefs=$(if ($side -eq 'Before') { @($refs) } else { @() });AfterEvidenceRefs=$(if ($side -eq 'After') { @($refs) } else { @() })})
            }
        }
        $semanticBefore=@($beforeFacts | Where-Object { $_.IdentityScope -eq 'Semantic' })
        $semanticAfter=@($afterFacts | Where-Object { $_.IdentityScope -eq 'Semantic' })
        $keys=@(($semanticBefore+$semanticAfter | ForEach-Object { '{0}|{1}' -f $_.Type,$_.Key }) | Sort-Object -Unique -CaseSensitive)
        foreach ($identity in $keys) {
            $bf=@($semanticBefore | Where-Object { ('{0}|{1}' -f $_.Type,$_.Key) -ceq $identity })
            $af=@($semanticAfter | Where-Object { ('{0}|{1}' -f $_.Type,$_.Key) -ceq $identity })
            $example=if ($af.Count -gt 0) { $af[0] } else { $bf[0] }
            $bv=$null;$av=$null;$state='Unchanged';$reason='Known values are unchanged.'
            if ($bf.Count -gt 0) { $bv=$bf[0].Values }
            if ($af.Count -gt 0) { $av=$af[0].Values }
            if ($example.Comparison -eq 'Windowed') {
                $bv=Get-WdtSnapshotObservationSummary $beforeModule $bf
                $av=Get-WdtSnapshotObservationSummary $afterModule $af
                $state='WindowedObservations'
                $reason='Observations in the selected windows; counts are not a severity verdict. Retention is unknown.'
                if ($bf.Count -eq 0) { $reason='Newly observed signature in the after window; prior absence does not establish when the issue began.' }
                if ($af.Count -eq 0) { $reason='Not observed in the after window; window movement, unknown retention, and source coverage limit interpretation.' }
                if ($bf.Count -gt 0 -and $af.Count -gt 0 -and -not (Test-WdtSnapshotFactSourcesMatch $beforeModule $afterModule $bf[0] $af[0])) { $state='NotComparable';$reason='Observation source scopes or query filters differ.' }
            }
            elseif ($bf.Count -gt 1 -or $af.Count -gt 1) { $state='NotComparable';$reason='Multiple configuration or inventory facts share a key.' }
            elseif ($bf.Count -eq 0) {
                $state='NewlyObserved';$reason='No comparable known before value; prior inventory is incomplete or has a different scope.'
                if ($example.ValueState -ne 'Known') { $state='NotComparable';$reason='The newly observed value is unknown or not applicable.' }
                elseif ($example.Comparison -eq 'Inventory' -and (Test-WdtSnapshotInventoryComplete $beforeModule $afterModule $example)) { $state='Added';$reason='Absent from the complete comparable before inventory; present in after. Get-HotFix covers only its own inventory.' }
            }
            elseif ($af.Count -eq 0) {
                $state='InformationLost';$reason='The after value is missing without a complete comparable inventory.'
                if ($example.ValueState -ne 'Known') { $state='NotComparable';$reason='The before value was unknown or not applicable.' }
                elseif ($example.Comparison -eq 'Inventory' -and (Test-WdtSnapshotInventoryComplete $afterModule $beforeModule $example)) { $state='Removed';$reason='Present in before; absent from the complete comparable after inventory. This does not describe all Windows updates.' }
            }
            elseif (-not (Test-WdtSnapshotFactSourcesMatch $beforeModule $afterModule $bf[0] $af[0])) { $state='NotComparable';$reason='Source identity, scope, kind, coverage, or query limit differs.' }
            elseif ($bf[0].ValueState -ne $af[0].ValueState) {
                if ($bf[0].ValueState -eq 'Known') { $state='InformationLost';$reason='Known value became unknown or not applicable.' }
                elseif ($af[0].ValueState -eq 'Known') { $state='InformationGained';$reason='A previously unknown value is now known.' }
                else { $state='NotComparable';$reason='Unknown and not-applicable states differ.' }
            }
            elseif ($bf[0].ValueState -ne 'Known') { $reason='Both values are unknown or not applicable; no health conclusion is available.' }
            elseif (-not (Test-WdtSnapshotValuesEqual $bv $av)) {
                $state='Changed';$reason='Comparable known values differ; this alone is not a problem verdict.'
                if ($example.Type -eq 'HotFix') { $reason='HotFix metadata differs, including possible date-quality changes; this does not establish reinstallation.' }
            }
            $differences.Add([pscustomobject]@{ModuleId=$moduleId;Type=$example.Type;Key=$example.Key;State=$state;Reason=$reason;BeforeValues=$bv;AfterValues=$av;BeforeEvidenceRefs=@(Get-WdtSnapshotEvidenceRefs $beforeSafe $moduleId $bf);AfterEvidenceRefs=@(Get-WdtSnapshotEvidenceRefs $afterSafe $moduleId $af)})
        }
    }
    return [pscustomobject]@{SchemaVersion=1;BeforeSnapshotId=$beforeSafe.SnapshotId;AfterSnapshotId=$afterSafe.SnapshotId;PrivacyMode=$effectivePrivacy;BeforeWindow=[pscustomobject]@{StartUtc=(ConvertTo-WdtDataUtcText $beforeSafe.WindowStartUtc);EndUtc=(ConvertTo-WdtDataUtcText $beforeSafe.WindowEndUtc)};AfterWindow=[pscustomobject]@{StartUtc=(ConvertTo-WdtDataUtcText $afterSafe.WindowStartUtc);EndUtc=(ConvertTo-WdtDataUtcText $afterSafe.WindowEndUtc)};Coverage=@($coverage.ToArray());Differences=@($differences.ToArray())}
}

function Get-WdtSnapshotComparisonLines {
    param([Parameter(Mandatory=$true)]$Comparison,[switch]$Markdown)
    $lines=New-Object System.Collections.Generic.List[string]
    $lines.Add('Windows Diagnostics Toolkit - Offline Snapshot Comparison')
    $lines.Add(('Before snapshot: {0}' -f $Comparison.BeforeSnapshotId));$lines.Add(('After snapshot : {0}' -f $Comparison.AfterSnapshotId))
    $lines.Add(('Privacy mode   : {0}' -f $Comparison.PrivacyMode))
    $lines.Add('The selected pair is assumed to describe the intended system; machine identity is not verified.')
    $lines.Add('Configuration changes and observation counts alone do not establish a problem or its resolution.')
    $lines.Add('')
    $lines.Add('Summary:')
    foreach ($group in @($Comparison.Differences | Group-Object State | Sort-Object Name)) { $lines.Add(('  {0}: {1}' -f $group.Name,$group.Count)) }
    if ($Comparison.Differences.Count -eq 0) { $lines.Add('  No comparable facts were collected. Empty/unavailable sources do not establish health.') }
    $lines.Add(('Before history window [start,end): {0} / {1}' -f $Comparison.BeforeWindow.StartUtc,$Comparison.BeforeWindow.EndUtc))
    $lines.Add(('After history window [start,end) : {0} / {1}' -f $Comparison.AfterWindow.StartUtc,$Comparison.AfterWindow.EndUtc))
    foreach ($side in @('Before','After')) {
        $window=if ($side -eq 'Before') { $Comparison.BeforeWindow } else { $Comparison.AfterWindow }
        if ($null -ne $window.StartUtc) { $lines.Add(('{0} history window duration: {1:N2} hours' -f $side,(([datetimeoffset]$window.EndUtc)-([datetimeoffset]$window.StartUtc)).TotalHours)) }
    }
    $lines.Add('Current configuration/inventory represents collection time, rather than the historical window.')
    $lines.Add('History counts are evidence observations before incident correlation; multiple sources can describe one incident.')
    $lines.Add('')
    $lines.Add('Differences and observations:')
    foreach ($difference in @($Comparison.Differences | Where-Object { $_.State -ne 'Unchanged' })) {
        $lines.Add(('{0}/{1} {2}: {3}' -f $difference.ModuleId,$difference.Type,$difference.Key,$difference.State))
        $lines.Add(('  {0}' -f $difference.Reason))
        $lines.Add(('  Before: {0}' -f (ConvertTo-Json -InputObject $difference.BeforeValues -Compress -Depth 5)))
        $lines.Add(('  After : {0}' -f (ConvertTo-Json -InputObject $difference.AfterValues -Compress -Depth 5)))
        if ($difference.BeforeEvidenceRefs.Count -gt 0) { $lines.Add(('  Before evidence: {0}' -f ($difference.BeforeEvidenceRefs -join ', '))) }
        if ($difference.AfterEvidenceRefs.Count -gt 0) { $lines.Add(('  After evidence : {0}' -f ($difference.AfterEvidenceRefs -join ', '))) }
    }
    $lines.Add('')
    $lines.Add('Source coverage and limitations (query completion does not prove history retention):')
    foreach ($source in $Comparison.Coverage) {
        $lines.Add(('{0} {1}/{2}: {3}; execution={4}; data={5}; queryComplete={6}; truncated={7}; limit={8}; coverage={9}; scope={10}; window={11}/{12}' -f $source.Side,$source.ModuleId,$source.SourceId,$source.Availability,$source.Execution,$source.DataStatus,$source.QueryComplete,$source.Truncated,$source.Limit,$source.Coverage,$source.Scope,$source.StartUtc,$source.EndUtc))
        if (-not [string]::IsNullOrEmpty($source.Error)) { $lines.Add(('  Source reason: {0}' -f $source.Error)) }
        foreach ($errorText in $source.DataErrors) { $lines.Add(('  Data reason: {0}' -f $errorText)) }
    }
    if ($Markdown) {
        $fence='```'
        foreach ($line in $lines) { foreach ($match in @([System.Text.RegularExpressions.Regex]::Matches($line,'`+'))) { if ($match.Length -ge $fence.Length) { $fence='`'*($match.Length+1) } } }
        return @('# Offline Snapshot Comparison','',($fence+'text'))+@($lines.ToArray())+@($fence)
    }
    return @($lines.ToArray())
}
