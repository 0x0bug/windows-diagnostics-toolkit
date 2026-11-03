[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\diagnostic-data.ps1')
. (Join-Path $repositoryRoot 'scripts\process-runner.ps1')
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected,$Actual,[string]$Message) if ($Expected -cne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }
function Assert-Throws { param([scriptblock]$Action,[string]$Message) $thrown=$false; try { & $Action } catch { $thrown=$true }; Assert-True $thrown $Message }
function New-FixtureData {
    $source=New-WdtDataSource -Id os -Kind Configuration -Scope 'Win32_OperatingSystem.Version.BuildNumber' -Coverage CurrentState
    $fact=New-WdtDataFact -Id f1 -Type OsVersion -Key windows-version -Values @{Version='10.0'; Build='26000'} -Comparison Configuration -SourceIds @('os')
    New-WdtDiagnosticData -ModuleId System -Sources @($source) -Facts @($fact)
}
function Get-FixtureFrames {
    param($Data)
    & { param($value) function Write-WdtDiagnosticDataFrame { param($Marker) $Marker }; Write-WdtDiagnosticData $value } $Data
}

$nonce='0123456789abcdef0123456789abcdef'
$savedEnv=@{}
foreach ($name in @('WDT_DATA_PROTOCOL','WDT_DATA_NONCE','WDT_DATA_MODULE','WDT_DATA_START_UTC','WDT_DATA_END_UTC')) { $savedEnv[$name]=[Environment]::GetEnvironmentVariable($name) }
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('wdt-data-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $env:WDT_DATA_PROTOCOL='1'; $env:WDT_DATA_NONCE=$nonce; $env:WDT_DATA_MODULE='System'; $env:WDT_DATA_START_UTC=''; $env:WDT_DATA_END_UTC=''
    $data=New-FixtureData
    Assert-WdtDiagnosticData $data
    $frames=@(Get-FixtureFrames $data)
    $resolved=Resolve-WdtDiagnosticData -OutputLines (@('human output')+$frames) -Nonce $nonce -ExpectedModuleId System
    Assert-Equal Available $resolved.DataStatus 'Complete framed data must be available.'
    Assert-Equal 1 $resolved.OutputLines.Count 'Frames must not leak into human output.'
    Assert-Equal 0 $resolved.Data.Evidence.Count 'Empty collections must survive wire parsing.'
    Assert-Equal '26000' $resolved.Data.Facts[0].Values.Build 'Typed values did not round-trip.'
    Assert-Equal (ConvertTo-WdtDataUtcText '2026-11-02T12:00:00Z') (ConvertTo-WdtDataUtcText '2026-11-02T14:00:00+02:00') 'Equivalent offsets must denote one instant.'
    Assert-Throws { ConvertTo-WdtDataUtcText '2026-11-02T12:00:00' } 'A missing timezone must fail.'
    Assert-Throws { ConvertTo-WdtDataUtcText ([datetime]'2026-11-02T12:00:00') } 'Unspecified DateTime must fail.'
    Assert-Throws { ConvertTo-WdtDataUtcText -Value @() } 'An empty timestamp array must not become null.'
    Assert-Throws { ConvertTo-WdtDataUtcText -Value @('') } 'A singleton empty-string timestamp array must not become null.'
    $broken=New-FixtureData;$broken.WindowStartUtc=@();Assert-Throws { Assert-WdtDiagnosticData $broken } 'Nullable data timestamps must reject array coercion.'
    $parsedTime=@{t='2026-11-02T12:00:00Z'} | ConvertTo-Json | ConvertFrom-Json
    Assert-Equal (ConvertTo-WdtDataUtcText '2026-11-02T12:00:00Z') (ConvertTo-WdtDataUtcText $parsedTime.t) 'JSON datetime representation differs across shells.'

    $empty=New-WdtDiagnosticData -ModuleId System -Sources @($data.Sources[0])
    Assert-Equal Available (Resolve-WdtDiagnosticData (Get-FixtureFrames $empty) $nonce System).DataStatus 'An available empty source is valid.'
    $unavailable=New-FixtureData; $unavailable.Sources[0].Availability='Unavailable'; $unavailable.Sources[0].QueryComplete=$false; $unavailable.Facts[0].ValueState='Unknown'; $unavailable.Facts[0].Values.Version=$null; $unavailable.Facts[0].Values.Build=$null
    Assert-Equal Unavailable (Resolve-WdtDiagnosticData (Get-FixtureFrames $unavailable) $nonce System).DataStatus 'Unavailable is not available-empty.'
    foreach ($value in @('true',1,1.0)) { $broken=New-FixtureData; $broken.Sources[0].QueryComplete=$value; Assert-Throws { Assert-WdtDiagnosticData $broken } 'Boolean source fields must have actual boolean types.' }
    $broken=New-FixtureData;$broken.ModuleId=@('System');Assert-Throws { Assert-WdtDiagnosticData $broken } 'Module identity must be a scalar string.'
    foreach ($name in @('Kind','Availability','Coverage')) {
        $broken=New-FixtureData;$broken.Sources[0].$name=@($broken.Sources[0].$name)
        Assert-Throws { Assert-WdtDiagnosticData $broken } 'Source enums must be scalar strings.'
    }
    foreach ($name in @('Type','IdentityScope','ValueState','Comparison')) {
        $broken=New-FixtureData;$broken.Facts[0].$name=@($broken.Facts[0].$name)
        Assert-Throws { Assert-WdtDiagnosticData $broken } 'Fact enums must be scalar strings.'
    }
    foreach ($name in @('SourceId','Kind','TimePrecision')) {
        $broken=New-FixtureData;$broken.Evidence=@((New-WdtDataEvidence -Id e1 -SourceId os -Kind Event))
        $broken.Evidence[0].$name=@($broken.Evidence[0].$name)
        Assert-Throws { Assert-WdtDiagnosticData $broken } 'Evidence identities/enums must be scalar strings.'
    }
    $broken=New-FixtureData; $broken.Facts[0].Comparison='Inventory'; Assert-Throws { Assert-WdtDiagnosticData $broken } 'Fact comparison policy cannot change independently of its type.'
    $broken=New-FixtureData; $broken.Sources[0].Scope='PERSONAL-HOST'; Assert-Throws { Assert-WdtDiagnosticData $broken } 'Scopes must be a closed per-adapter vocabulary.'
    $broken=New-FixtureData; $broken.Facts[0].SourceIds=@('missing'); Assert-Throws { Assert-WdtDiagnosticData $broken } 'Dangling source refs must fail.'
    $broken=New-FixtureData; $broken.Facts=@($broken.Facts[0],$broken.Facts[0]); Assert-Throws { Assert-WdtDiagnosticData $broken } 'Duplicate fact refs must fail.'
    $broken=New-FixtureData; $broken.Facts[0].Values | Add-Member NoteProperty Owner 'private'; Assert-Throws { Assert-WdtDiagnosticData $broken } 'Unexpected field names must fail.'

    foreach ($case in @(
        @{Lines=@($frames | Select-Object -SkipLast 1); Complete=$true},
        @{Lines=@($frames[0],('@@WDT_DATA@@'+$nonce+':{invalid secret payload'),$frames[-1]); Complete=$true},
        @{Lines=@($frames | ForEach-Object { $_.Replace($nonce,('f'*32)) }); Complete=$true},
        @{Lines=$frames; Complete=$false}
    )) {
        $partial=Resolve-WdtDiagnosticData -OutputLines $case.Lines -Nonce $nonce -ExpectedModuleId System -ExecutionComplete $case.Complete
        Assert-True ($partial.DataStatus -ne 'Available') 'Damaged or incomplete transport must not be available.'
        Assert-True (($partial.DataErrors -join '') -notmatch 'secret payload') 'Protocol errors must not repeat raw payload.'
        Assert-Equal 0 $partial.OutputLines.Count 'Protocol errors must not expose machine frames as text.'
    }
    $limitSaved=$script:WdtDataCharacterLimit
    try { $script:WdtDataCharacterLimit=100; $limited=Resolve-WdtDiagnosticData (Get-FixtureFrames $data) $nonce System; Assert-True ($limited.DataStatus -ne 'Available') 'Emitter and parser character budgets must make loss explicit.' }
    finally { $script:WdtDataCharacterLimit=$limitSaved }

    $source=New-WdtDataSource -Id crash-source-1 -Kind History -Scope 'Application Error/1000'
    $other=New-WdtDataSource -Id crash-source-2 -Kind History -Scope 'Windows Error Reporting/1001'
    $ev=New-WdtDataEvidence -Id e1 -SourceId crash-source-1 -TimestampUtc '2026-11-02T12:00:00Z' -TimePrecision Instant -OriginalOffset '+00:00' -RecordId 42 -ReportId '11111111-2222-3333-4444-555555555555' -Kind Crash -Component 'C:\Users\PrivateUser\app.exe' -Message 'C:\Users\PrivateUser\app.exe --token "private quoted token"'
    $fact=New-WdtDataFact -Id f1 -Type CrashObservation -Key 'C:\Users\PrivateUser\app.exe|Crash|0x1' -Values @{Component='C:\Users\PrivateUser\app.exe'; Kind='Crash'; FailureCode='0x1'} -Comparison Windowed -SourceIds @('crash-source-1') -EvidenceIds @('e1')
    $raw=New-WdtDiagnosticData -ModuleId Crashes -Sources @($source,$other) -Facts @($fact) -Evidence @($ev)
    $raw.Sources[0].Availability='Partial'; $raw.Sources[0].QueryComplete=$false; $raw.Sources[0].Error='PRIVATE-HOST C:\Users\PrivateUser'
    $context=New-WdtRedactionContext -ComputerName PRIVATE-HOST -UserName PrivateUser -UserProfile 'C:\Users\PrivateUser'
    $protected=Protect-WdtDiagnosticData $raw $context
    Assert-Equal SnapshotLocal $protected.Facts[0].IdentityScope 'Sensitive keys must become snapshot-local.'
    Assert-True ([string]::IsNullOrEmpty($protected.Facts[0].Key)) 'No original or token-based comparison key may survive.'
    Assert-Equal 'C:\Users\PrivateUser\app.exe' $raw.Evidence[0].Component 'Privacy must not mutate the original.'
    $json=$protected | ConvertTo-Json -Depth 12
    Assert-True ($json -notmatch 'PRIVATE-HOST|PrivateUser|private quoted token|11111111-2222') 'Nested privacy projection leaked identity, secrets, or raw identifiers.'
    $broken=$raw | ConvertTo-Json -Depth 12 | ConvertFrom-Json; $broken.Facts[0].SourceIds=@('crash-source-2'); Assert-Throws { Assert-WdtDiagnosticData $broken } 'Evidence must belong to a declared fact source.'
    $broken=$raw | ConvertTo-Json -Depth 12 | ConvertFrom-Json; $broken.Evidence[0].OriginalOffset='+14:01'; Assert-Throws { Assert-WdtDiagnosticData $broken } 'Impossible offsets must fail.'

    # Runner integration also proves that legacy children cannot inherit an
    # accidental opt-in request from the parent process.
    $fixture=Join-Path $tempRoot 'fixture.ps1'
    $helper=(Join-Path $repositoryRoot 'scripts\diagnostic-data.ps1').Replace("'","''")
    $sourceText=@'
. '__HELPER__'
if ((Get-WdtDataRequest).Enabled) {
    $s=New-WdtDataSource -Id os -Kind Configuration -Scope 'Win32_OperatingSystem.Version.BuildNumber' -Coverage CurrentState
    Write-WdtDiagnosticData (New-WdtDiagnosticData -ModuleId System -Sources @($s))
}
Write-Output ('enabled='+(Get-WdtDataRequest).Enabled)
'@
    [IO.File]::WriteAllText($fixture,$sourceText.Replace('__HELPER__',$helper),[Text.Encoding]::UTF8)
    $shell=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $legacy=Invoke-DiagnosticScript fixture $fixture $shell $repositoryRoot 15
    Assert-Equal NotCollected $legacy.DataStatus 'A legacy run must not collect data.'
    Assert-True (($legacy.OutputLines -join '') -match 'enabled=False') 'Inherited controls activated a legacy child.'
    $collected=Invoke-DiagnosticScript fixture $fixture $shell $repositoryRoot 15 -CollectData -ModuleId System
    Assert-Equal Available $collected.DataStatus ('Runner data collection failed: '+($collected.DataErrors -join ';'))
    Assert-True (($collected.OutputLines -join '') -notmatch '@@WDT_DATA@@') 'Runner must remove machine frames.'
    Assert-True (Test-Path -LiteralPath $fixture) 'Collection must preserve fixture/input files.'
    $missing=Invoke-DiagnosticScript fixture (Join-Path $tempRoot 'missing.ps1') $shell $repositoryRoot 15 -CollectData -ModuleId System
    Assert-Equal Unavailable $missing.DataStatus 'A requested missing source is unavailable, not unselected.'
    $launch=Invoke-DiagnosticScript fixture $fixture (Join-Path $tempRoot 'missing-shell.exe') $repositoryRoot 15 -CollectData -ModuleId System
    Assert-Equal Unavailable $launch.DataStatus 'A requested launch failure must be unavailable.'

    $systemFixture=Join-Path $tempRoot 'system.ps1'
    $systemModule=(Join-Path $repositoryRoot 'modules\system\diagnostic.ps1').Replace("'","''")
    $systemText=@'
function Get-CimInstance { param($ClassName,$Filter) if ($ClassName -eq 'Win32_OperatingSystem') { [pscustomobject]@{Caption='Windows'; LastBootUpTime=$null} } }
& '__MODULE__'
'@
    [IO.File]::WriteAllText($systemFixture,$systemText.Replace('__MODULE__',$systemModule),[Text.Encoding]::UTF8)
    $system=Invoke-DiagnosticScript fixture $systemFixture $shell $repositoryRoot 30 -CollectData -ModuleId System
    Assert-Equal Available $system.DataStatus 'A successful OS query is distinct from unknown properties.'
    Assert-Equal Unknown $system.Data.Facts[0].ValueState 'Missing OS properties must not become known empty strings.'
    Assert-True ($null -eq $system.Data.Facts[0].Values.Version -and $null -eq $system.Data.Facts[0].Values.Build) 'Unknown OS properties must remain null.'

    $crashFixture=Join-Path $tempRoot 'crashes.ps1'
    $crashModule=(Join-Path $repositoryRoot 'modules\crashes\diagnostic.ps1').Replace("'","''")
    $crashText=@'
$global:queryCount=0
function Get-WinEvent {
    param($FilterHashtable,$MaxEvents,$ErrorAction)
    $global:queryCount++
    if ($FilterHashtable.ProviderName -ne 'Application Error') { return @() }
    foreach ($n in @(1,2)) {
        [pscustomobject]@{ ProviderName='Application Error'; Id=1000; LogName='Application'; RecordId=(100+$n); TimeCreated=('2026-11-02T14:0'+$n+':00+02:00'); Component='fixture.exe'; Kind='Crash'; FailureCode='0xc0000005'; ReportId=''; Message='fixture'; Properties=@() }
    }
}
function Get-CimInstance { param($Namespace,$ClassName,$Filter,$ErrorAction) @() }
function Get-ChildItem { param($LiteralPath,$Path,$Filter,$File,$ErrorAction) @() }
& '__MODULE__'
Write-Output ('queries='+$global:queryCount)
'@
    [IO.File]::WriteAllText($crashFixture,$crashText.Replace('__MODULE__',$crashModule),[Text.Encoding]::UTF8)
    $crashes=Invoke-DiagnosticScript fixture $crashFixture $shell $repositoryRoot 30 -CollectData -ModuleId Crashes -DataStartUtc '2026-11-02T12:00:00Z' -DataEndUtc '2026-11-02T13:00:00Z'
    Assert-Equal Available $crashes.DataStatus ('Crash adapter failed: '+($crashes.DataErrors -join ';')+($crashes.ErrorLines -join ';'))
    Assert-Equal 2 $crashes.Data.Facts.Count 'Independent crashes in one legacy five-minute bucket must remain separate data records.'
    Assert-Equal '101' $crashes.Data.Evidence[0].RecordId 'Crash evidence lost its source record id.'
    Assert-Equal '+02:00' $crashes.Data.Evidence[0].OriginalOffset 'Crash evidence must retain its original offset before UTC normalization.'
    Assert-True (($crashes.OutputLines -join '') -match 'queries=4') 'Structured export queried crash sources again.'
    Assert-True (($crashes.OutputLines -join '') -match 'Time window \[UTC\).*2026-11-02T12:00:00.*2026-11-02T13:00:00') 'Opt-in crash report did not show the effective data window.'

    $updateFixture=Join-Path $tempRoot 'updates.ps1'
    $updateModule=(Join-Path $repositoryRoot 'modules\updates\diagnostic.ps1').Replace("'","''")
    $updateText=@'
$global:hotFixQueries=0
function Get-HotFix {
    param($ErrorAction)
    $global:hotFixQueries++
    [pscustomobject]@{HotFixID='KB123456'; InstalledOn=[datetime]'2025-01-01'; InstalledBy='PRIVATE-OWNER'; Description='fixture'}
    [pscustomobject]@{HotFixID='KB654321'; InstalledOn='unknown'; InstalledBy='PRIVATE-OWNER'; Description='fixture'}
}
function Get-WinEvent { param($FilterHashtable,$ErrorAction) @() }
function Get-CimInstance {
    param($ClassName,$ErrorAction)
    if ($ClassName -eq 'Win32_OperatingSystem') { [pscustomobject]@{Caption='Windows'; Version='10.0'; BuildNumber='26000'} }
    else { [pscustomobject]@{Name='wuauserv'; State='Stopped'; StartMode='Manual'; ExitCode=1077} }
}
function Test-Path { param($LiteralPath) if ($LiteralPath -like '*Component Based Servicing*') { throw 'fixture denied' }; $false }
function Get-ItemProperty { param($LiteralPath,$ErrorAction) [pscustomobject]@{} }
& '__MODULE__'
Write-Output ('hotfixqueries='+$global:hotFixQueries)
'@
    [IO.File]::WriteAllText($updateFixture,$updateText.Replace('__MODULE__',$updateModule),[Text.Encoding]::UTF8)
    $updates=Invoke-DiagnosticScript fixture $updateFixture $shell $repositoryRoot 30 -CollectData -ModuleId Updates -DataStartUtc '2026-11-02T12:00:00Z' -DataEndUtc '2026-11-02T13:00:00Z'
    Assert-Equal Partial $updates.DataStatus ('Update adapter failed: '+($updates.DataErrors -join ';')+($updates.ErrorLines -join ';'))
    Assert-True ($null -ne $updates.Data) 'Partial reboot assessment must preserve other data.'
    $hotFixes=@($updates.Data.Facts | Where-Object Type -eq HotFix)
    Assert-Equal 2 $hotFixes.Count 'Full HotFixID inventory must include old and unparseable-date items.'
    Assert-Equal '2025-01-01' $hotFixes[0].Values.InstalledDate 'Date-only installation data was lost.'
    Assert-Equal Unknown $updates.Data.Evidence[0].TimePrecision 'An unspecified date must not invent a timezone.'
    $reboot=@($updates.Data.Facts | Where-Object { $_.Type -eq 'RebootIndicator' -and $_.Values.Name -eq 'Component Based Servicing RebootPending' })[0]
    Assert-Equal Unknown $reboot.ValueState 'An inaccessible reboot check must not become known false.'
    Assert-True ($null -eq $reboot.Values.Present) 'Unavailable reboot state must be null, not false.'
    $knownReboot=@($updates.Data.Facts | Where-Object { $_.Type -eq 'RebootIndicator' -and $_.Values.Name -eq 'PendingFileRenameOperations' })[0]
    Assert-Equal Known $knownReboot.ValueState 'A completed empty reboot check must remain known.'
    Assert-True ($knownReboot.Values.Present -is [bool] -and -not $knownReboot.Values.Present) 'Known false must remain a typed false value.'
    Assert-True (($updates.OutputLines -join '') -match 'hotfixqueries=1') 'Structured export queried hotfix inventory again.'
    Assert-True (($updates.Data | ConvertTo-Json -Depth 12) -notmatch 'PRIVATE-OWNER|InstalledBy') 'New data must not collect InstalledBy.'
    Assert-True (($updates.OutputLines -join '') -match 'Time window \[UTC\).*2026-11-02T12:00:00.*2026-11-02T13:00:00') 'Opt-in update report did not show the effective data window.'

    $eventFixture=Join-Path $tempRoot 'events.ps1'
    $eventModule=(Join-Path $repositoryRoot 'modules\events\diagnostic.ps1').Replace("'","''")
    $eventText=@'
$global:queryCount=0
function Get-WinEvent {
    param($FilterHashtable,$MaxEvents,$ErrorAction)
    $global:queryCount++
    if ($null -ne $FilterHashtable.Id) {
        return [pscustomobject]@{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41; Level=1; RecordId=999; TimeCreated=[datetime]'2026-11-02T12:30:00Z'; Message='signal'; LevelDisplayName='Critical'}
    }
    if ($FilterHashtable.LogName -ne 'Application') { return @() }
    foreach ($n in @(0,1,2)) {
        [pscustomobject]@{LogName='Application'; ProviderName='Fixture'; Id=7000; Level=2; RecordId=(200+$n); TimeCreated=([datetime]'2026-11-02T12:00:00Z').AddHours($n); Message='fixture'; LevelDisplayName='Error'}
    }
}
& '__MODULE__' -MaxEvents 3
Write-Output ('queries='+$global:queryCount)
'@
    [IO.File]::WriteAllText($eventFixture,$eventText.Replace('__MODULE__',$eventModule),[Text.Encoding]::UTF8)
    $events=Invoke-DiagnosticScript fixture $eventFixture $shell $repositoryRoot 30 -CollectData -ModuleId Events -DataStartUtc '2026-11-02T12:00:00Z' -DataEndUtc '2026-11-02T13:00:00Z'
    Assert-Equal Partial $events.DataStatus ('Capped events must be partial: '+($events.DataErrors -join ';')+($events.ErrorLines -join ';'))
    Assert-Equal 2 $events.Data.Evidence.Count 'Data window must include start and exclude end, even when a source ignores bounds.'
    Assert-Equal '200' $events.Data.Evidence[0].RecordId 'Event source reference was lost.'
    Assert-Equal high-signals $events.Data.Evidence[1].SourceId 'A signal supplied only by the signal query must retain its actual source.'
    Assert-True (($events.OutputLines -join '') -match 'queries=3') 'Event export must reuse three existing queries.'
    Assert-True (($events.OutputLines -join '') -match 'Time window \[UTC\).*2026-11-02T12:00:00.*2026-11-02T13:00:00') 'Opt-in event report did not show the effective data window.'
}
finally {
    foreach ($name in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnv[$name]) }
    $resolvedTemp=[IO.Path]::GetFullPath($tempRoot); $expectedRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolvedTemp.StartsWith($expectedRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside temp root.' }
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
Write-Host 'Diagnostic data tests passed.'
