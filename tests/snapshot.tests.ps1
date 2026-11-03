[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\snapshot.ps1')
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected,$Actual,[string]$Message) if ($Expected -cne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }
function Assert-Invalid { param([scriptblock]$Action) $message=$null; try { & $Action | Out-Null } catch { $message=$_.Exception.Message }; Assert-Equal 'Invalid or unsupported WDT snapshot.' $message 'Snapshot failures must be generic.' }
function New-FixtureSnapshot {
    $source = New-WdtDataSource -Id os -Kind Configuration -Scope 'Win32_OperatingSystem.Version.BuildNumber' -Coverage CurrentState
    $fact = New-WdtDataFact -Id f1 -Type OsVersion -Key windows-version -Comparison Configuration -Values @{Version='10.0'; Build='26000'} -SourceIds @('os')
    $data = New-WdtDiagnosticData -ModuleId System -Sources @($source) -Facts @($fact)
    $result = [pscustomobject]@{Status='Success'; ExitCode=0; Completeness='Complete'; OutputComplete=$true; DataStatus='Available'; DataErrors=@(); Data=$data}
    New-WdtSnapshot -ToolkitVersion '0.1.0-beta' -ModuleIds @('System') -Results @($result) -CollectionStartedUtc '2026-11-02T12:00:00Z' -CollectionFinishedUtc '2026-11-02T12:00:01Z' -WindowStartUtc '2026-10-26T12:00:00Z' -WindowEndUtc '2026-11-02T12:00:00Z'
}
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('wdt-snapshot-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $snapshot=New-FixtureSnapshot
    Assert-WdtSnapshot $snapshot
    $path=Write-WdtSnapshot -Snapshot $snapshot -OutputDirectory $temporaryRoot
    $read=Read-WdtSnapshot -LiteralPath $path
    Assert-Equal '26000' $read.Modules[0].Data.Facts[0].Values.Build 'Nested values failed to round-trip.'
    Assert-Equal 0 $read.Modules[0].Data.Evidence.Count 'Empty arrays failed to round-trip.'
    Assert-True ($path -match 'WindowsDiagnosticsSnapshot-\d{8}-\d{6}-[a-f0-9]{32}\.json$') 'A snapshot name needs timestamp and GUID.'
    Assert-Equal (ConvertTo-WdtDataUtcText $snapshot.CollectionStartedUtc) (ConvertTo-WdtDataUtcText $read.CollectionStartedUtc) 'Cross-shell timestamp representation changed the instant.'
    $dated=New-FixtureSnapshot
    $dated.SelectedModules=@('Updates');$dated.Modules[0].ModuleId='Updates'
    $datedSource=New-WdtDataSource -Id hotfix -Kind Inventory -Scope 'Get-HotFix/HotFixID' -Coverage CurrentState
    $datedFact=New-WdtDataFact -Id f1 -Type HotFix -Key KB123456 -Comparison Inventory -Values @{HotFixId='KB123456';InstalledDate='2025-01-01'} -SourceIds @('hotfix') -EvidenceIds @('e1')
    $datedEvidence=New-WdtDataEvidence -Id e1 -SourceId hotfix -Kind HotFix -TimePrecision Unknown
    $dated.Modules[0].Data=New-WdtDiagnosticData -ModuleId Updates -WindowStartUtc $dated.WindowStartUtc -WindowEndUtc $dated.WindowEndUtc -Sources @($datedSource) -Facts @($datedFact) -Evidence @($datedEvidence)
    $datesOutput=Join-Path $temporaryRoot 'dates';New-Item -ItemType Directory -Path $datesOutput | Out-Null
    $datedRead=Read-WdtSnapshot (Write-WdtSnapshot $dated $datesOutput)
    Assert-Equal '2025-01-01' $datedRead.Modules[0].Data.Facts[0].Values.InstalledDate 'Date-only installation metadata changed.'
    Assert-Equal Unknown $datedRead.Modules[0].Data.Evidence[0].TimePrecision 'Round-trip invented time precision.'
    Assert-True ($null -eq $datedRead.Modules[0].Data.Evidence[0].TimestampUtc) 'Round-trip invented a timezone.'
    $original=[IO.File]::ReadAllText($path)
    $second=Write-WdtSnapshot -Snapshot $snapshot -OutputDirectory $temporaryRoot
    Assert-True ($path -ne $second) 'Snapshot names collided.'
    Assert-Equal $original ([IO.File]::ReadAllText($path)) 'Input snapshot was overwritten.'
    foreach ($mutate in @(
        { param($s) $s.SchemaVersion=2 },
        { param($s) $s.PrivacyMode='false' },
        { param($s) $s.CollectionStartedUtc='2026-11-02T12:00:00' },
        { param($s) $s.Modules[0].Data.WindowStartUtc=@() },
        { param($s) $s.Modules[0].Data.Facts[0].EvidenceIds=@('missing') },
        { param($s) $s.SelectedModules=@('System','System') },
        { param($s) $s.Modules[0].OutputComplete='true' },
        { param($s) $s.Modules[0].Status=@('Success') },
        { param($s) $s.Modules[0].ModuleId=@('System') },
        { param($s) $s.Modules[0].Completeness=@('Complete') },
        { param($s) $s.Modules[0].DataStatus=@('Available') },
        { param($s) $s.Modules[0].Data.ModuleId='Events' },
        { param($s) $s | Add-Member NoteProperty RawContext @{Secret='private'} }
    )) {
        $broken=New-FixtureSnapshot; & $mutate $broken
        Assert-Invalid { Assert-WdtSnapshot $broken }
    }
    $invalidPath=Join-Path $temporaryRoot 'PRIVATE-INPUT.json'
    foreach ($invalid in @('{"raw":"PRIVATE-PAYLOAD"','null','[]','{"SchemaVersion":99}',('{"SchemaVersion":1,"SchemaVersion":1}'),('{"name":1,"na\u006de":2}'),(('['*21)+(']'*21)))) {
        [IO.File]::WriteAllText($invalidPath,$invalid,[Text.Encoding]::UTF8)
        Assert-Invalid { Read-WdtSnapshot $invalidPath }
    }
    $sizeSaved=$script:WdtSnapshotByteLimit
    try {
        $script:WdtSnapshotByteLimit=10; Assert-Invalid { Read-WdtSnapshot $path }
        $writeError=$null; try { Write-WdtSnapshot $snapshot $temporaryRoot | Out-Null } catch { $writeError=$_.Exception.Message }
        Assert-Equal 'Could not write WDT snapshot.' $writeError 'Write failure must be generic and distinguishable from read/schema errors.'
    }
    finally { $script:WdtSnapshotByteLimit=$sizeSaved }

    $private=New-FixtureSnapshot
    $unicode=-join @([char]0x041f,[char]0x0440,[char]0x0438,[char]0x0432,[char]0x0435,[char]0x0442)
    $private.Modules[0].Data.Facts[0].Values.Version=$unicode+' PRIVATE-HOST "C:\Users\PrivateUser" --token "secret value"'
    $context=New-WdtRedactionContext -ComputerName PRIVATE-HOST -UserName PrivateUser -UserProfile 'C:\Users\PrivateUser'
    $private.PrivacyMode=$true
    $privatePath=Write-WdtSnapshot $private $temporaryRoot -Context $context
    $privateText=[IO.File]::ReadAllText($privatePath)
    Assert-True ($privateText -notmatch 'PRIVATE-HOST|PrivateUser|secret value|LiteralMap|RegexRules|RawContext') 'Snapshot leaked protected values or the context.'
    Assert-True ($privateText.Contains($unicode)) 'UTF-8 non-ASCII text was lost.'
    Assert-Equal SnapshotLocal (Read-WdtSnapshot $privatePath).Modules[0].Data.Facts[0].IdentityScope 'Protected identities must stay local.'
    Assert-True ($private.Modules[0].Data.Facts[0].Values.Version.Contains('PRIVATE-HOST')) 'Writer mutated raw in-memory input.'

    # The other supported shell reads actual Unicode codepoints and writes a
    # second artifact which this shell reads again. Both directions run in CI.
    $roundtripScript=Join-Path $temporaryRoot 'roundtrip.ps1'
    $roundtripSource=@'
param($InputPath,$OutputPath)
$ErrorActionPreference='Stop'
. '__HELPER__'
$s=Read-WdtSnapshot $InputPath
$word=-join @([char]0x041f,[char]0x0440,[char]0x0438,[char]0x0432,[char]0x0435,[char]0x0442)
if (-not $s.Modules[0].Data.Facts[0].Values.Version.Contains($word)) { throw 'Cross-shell Unicode codepoints changed.' }
if ($s.Modules[0].Data.Evidence.Count -ne 0 -or -not $s.PrivacyMode) { throw 'Cross-shell arrays/bool changed.' }
Write-WdtSnapshot $s $OutputPath | Out-Null
'@
    $helper=(Join-Path $repositoryRoot 'scripts\snapshot.ps1').Replace("'","''")
    [IO.File]::WriteAllText($roundtripScript,$roundtripSource.Replace('__HELPER__',$helper),[Text.Encoding]::UTF8)
    $otherShell=if ($PSVersionTable.PSEdition -eq 'Core') { 'powershell.exe' } else { 'pwsh.exe' }
    $roundtripOutput=Join-Path $temporaryRoot 'roundtrip';New-Item -ItemType Directory -Path $roundtripOutput | Out-Null
    & $otherShell -NoProfile -ExecutionPolicy Bypass -File $roundtripScript $privatePath $roundtripOutput
    Assert-Equal 0 $LASTEXITCODE 'Cross-shell reader/writer failed.'
    $roundtripFile=@(Get-ChildItem -LiteralPath $roundtripOutput -Filter '*.json')[0]
    Assert-True ((Read-WdtSnapshot $roundtripFile.FullName).Modules[0].Data.Facts[0].Values.Version.Contains($unicode)) 'Return round-trip changed Unicode codepoints.'

    # Independent writers share an output directory and must preserve inputs.
    $writer=Join-Path $temporaryRoot 'writer.ps1'
    $helper=(Join-Path $repositoryRoot 'scripts\snapshot.ps1').Replace("'","''")
    $writerSource=@'
param($InputPath,$OutputPath)
$ErrorActionPreference='Stop'
. '__HELPER__'
Write-WdtSnapshot -Snapshot (Read-WdtSnapshot $InputPath) -OutputDirectory $OutputPath | Out-Null
'@
    [IO.File]::WriteAllText($writer,$writerSource.Replace('__HELPER__',$helper),[Text.Encoding]::UTF8)
    $shell=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $children=@()
    try {
        for ($i=0;$i -lt 3;$i++) { $children+=Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $writer),('"{0}"' -f $path),('"{0}"' -f $temporaryRoot)) -PassThru -WindowStyle Hidden }
        foreach ($child in $children) { Assert-True ($child.WaitForExit(30000)) 'Concurrent writer exceeded timeout.'; Assert-Equal 0 $child.ExitCode 'Concurrent writer failed.' }
    }
    finally { foreach ($child in $children) { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force }; $child.Dispose() } }
    Assert-Equal 6 @(Get-ChildItem -LiteralPath $temporaryRoot -Filter 'WindowsDiagnosticsSnapshot-*.json').Count 'Concurrent artifacts were overwritten.'
    Assert-Equal $original ([IO.File]::ReadAllText($path)) 'Concurrent writes changed an input.'
}
finally {
    $resolved=[IO.Path]::GetFullPath($temporaryRoot)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'Snapshot tests passed.'
