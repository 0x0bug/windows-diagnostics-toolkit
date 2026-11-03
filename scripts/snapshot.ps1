[CmdletBinding()]
param()

. $PSScriptRoot\diagnostic-data.ps1
. $PSScriptRoot\report-common.ps1

$script:WdtSnapshotByteLimit = 67108864
$script:WdtSnapshotCharacterLimit = 16777216

function Assert-WdtSnapshotModules {
    param([AllowEmptyCollection()][string[]]$ModuleIds)
    if ($ModuleIds.Count -eq 0 -or $ModuleIds.Count -gt 4) { throw 'Snapshot collection requires an explicit selection of System, Crashes, Events, or Updates.' }
    $seen=@{}
    foreach ($id in $ModuleIds) {
        if ($id -cnotin @('System','Crashes','Events','Updates') -or $seen.ContainsKey($id)) { throw 'Snapshot collection supports only System, Crashes, Events, and Updates, selected explicitly.' }
        $seen[$id]=$true
    }
}

function Assert-WdtSnapshot {
    param([Parameter(Mandatory=$true)]$Snapshot)
    try {
        Assert-WdtDataProperties $Snapshot @('SchemaVersion','ToolkitVersion','SnapshotId','CreatedUtc','CollectionStartedUtc','CollectionFinishedUtc','PrivacyMode','RedactionScopeId','SelectedModules','WindowStartUtc','WindowEndUtc','Modules')
        if (-not (Test-WdtDataInteger $Snapshot.SchemaVersion) -or $Snapshot.SchemaVersion -ne 1) { throw 'Schema.' }
        Assert-WdtDataText $Snapshot.ToolkitVersion
        if ([string]::IsNullOrWhiteSpace($Snapshot.ToolkitVersion)) { throw 'Version.' }
        foreach ($name in @('SnapshotId','RedactionScopeId')) { if ($Snapshot.$name -isnot [string] -or $Snapshot.$name -cnotmatch '^[a-f0-9]{32}$') { throw 'Identity.' } }
        if ($Snapshot.PrivacyMode -isnot [bool] -or $Snapshot.SelectedModules -isnot [System.Array] -or $Snapshot.Modules -isnot [System.Array]) { throw 'Type.' }
        Assert-WdtSnapshotModules $Snapshot.SelectedModules
        if ($Snapshot.Modules.Count -ne $Snapshot.SelectedModules.Count) { throw 'Modules.' }
        foreach ($id in $Snapshot.SelectedModules) { if ($id -isnot [string]) { throw 'Module type.' } }
        $started=ConvertTo-WdtDataUtcText $Snapshot.CollectionStartedUtc
        $finished=ConvertTo-WdtDataUtcText $Snapshot.CollectionFinishedUtc
        $created=ConvertTo-WdtDataUtcText $Snapshot.CreatedUtc
        if ($null -eq $started -or $null -eq $finished -or $null -eq $created -or [datetimeoffset]$started -gt [datetimeoffset]$finished -or [datetimeoffset]$finished -gt [datetimeoffset]$created) { throw 'Time.' }
        $start=ConvertTo-WdtDataUtcText $Snapshot.WindowStartUtc; $end=ConvertTo-WdtDataUtcText $Snapshot.WindowEndUtc
        if (($null -eq $start) -ne ($null -eq $end) -or ($null -ne $start -and [datetimeoffset]$start -ge [datetimeoffset]$end)) { throw 'Window.' }
        for ($i=0;$i -lt $Snapshot.Modules.Count;$i++) {
            $module=$Snapshot.Modules[$i]
            Assert-WdtDataProperties $module @('ModuleId','Status','ExitCode','Completeness','OutputComplete','DataStatus','DataErrors','Data')
            foreach ($name in @('ModuleId','Status','Completeness','DataStatus')) { Assert-WdtDataText $module.$name }
            if ($module.ModuleId -cne $Snapshot.SelectedModules[$i] -or $module.Status -cnotin @('Success','NonZeroExit','Timeout','LaunchError','Cancelled') -or $module.Completeness -cnotin @('Complete','Partial','Unavailable') -or $module.DataStatus -cnotin @('Available','Partial','Unavailable','NotCollected')) { throw 'Module enum.' }
            if ($module.OutputComplete -isnot [bool] -or ($null -ne $module.ExitCode -and -not (Test-WdtDataInteger $module.ExitCode)) -or $module.DataErrors -isnot [System.Array] -or $module.DataErrors.Count -gt 100) { throw 'Execution type.' }
            foreach ($errorText in $module.DataErrors) { Assert-WdtDataText $errorText }
            $expectedCompleteness=if ($module.Status -eq 'Success' -and $module.OutputComplete) { 'Complete' } elseif ($module.Status -in @('Success','NonZeroExit','Timeout')) { 'Partial' } else { 'Unavailable' }
            if ($module.Completeness -cne $expectedCompleteness -or ($module.Status -eq 'Success' -and $module.ExitCode -ne 0)) { throw 'Execution state.' }
            if ($null -eq $module.Data) {
                if ($module.DataStatus -in @('Available','Partial')) { throw 'Missing data.' }
                continue
            }
            Assert-WdtDiagnosticData $module.Data
            $dataStart=ConvertTo-WdtDataUtcText $module.Data.WindowStartUtc; $dataEnd=ConvertTo-WdtDataUtcText $module.Data.WindowEndUtc
            $expectedStart=$start; $expectedEnd=$end
            if ($module.ModuleId -eq 'System') { $expectedStart=$null; $expectedEnd=$null }
            if ($module.Data.ModuleId -cne $module.ModuleId -or $dataStart -cne $expectedStart -or $dataEnd -cne $expectedEnd -or $module.DataStatus -eq 'NotCollected') { throw 'Data scope.' }
            if ($module.DataStatus -eq 'Available' -and ($module.DataErrors.Count -gt 0 -or $module.Data.Sources.Count -eq 0 -or @($module.Data.Sources | Where-Object { $_.Availability -ne 'Available' -or -not $_.QueryComplete -or $_.Truncated }).Count -gt 0)) { throw 'Data status.' }
        }
    }
    catch { throw 'Invalid or unsupported WDT snapshot.' }
}

function New-WdtSnapshot {
    param([string]$ToolkitVersion,[string[]]$ModuleIds,[object[]]$Results,
        $CollectionStartedUtc,$CollectionFinishedUtc,$WindowStartUtc=$null,$WindowEndUtc=$null,[bool]$PrivacyMode=$false)
    $modules=New-Object System.Collections.Generic.List[object]
    if ($ModuleIds.Count -ne $Results.Count) { throw 'Invalid or unsupported WDT snapshot.' }
    for ($i=0;$i -lt $ModuleIds.Count;$i++) {
        $result=$Results[$i]
        $modules.Add([pscustomobject][ordered]@{ModuleId=$ModuleIds[$i];Status=$result.Status;ExitCode=$result.ExitCode;Completeness=$result.Completeness;OutputComplete=$result.OutputComplete;DataStatus=$result.DataStatus;DataErrors=@($result.DataErrors);Data=$result.Data})
    }
    $snapshot=[pscustomobject][ordered]@{
        SchemaVersion=1; ToolkitVersion=$ToolkitVersion; SnapshotId=[System.Guid]::NewGuid().ToString('N')
        CreatedUtc=(ConvertTo-WdtDataUtcText ([datetime]::UtcNow)); CollectionStartedUtc=(ConvertTo-WdtDataUtcText $CollectionStartedUtc); CollectionFinishedUtc=(ConvertTo-WdtDataUtcText $CollectionFinishedUtc)
        PrivacyMode=$PrivacyMode; RedactionScopeId=[System.Guid]::NewGuid().ToString('N');SelectedModules=@($ModuleIds)
        WindowStartUtc=(ConvertTo-WdtDataUtcText $WindowStartUtc);WindowEndUtc=(ConvertTo-WdtDataUtcText $WindowEndUtc);Modules=@($modules.ToArray())
    }
    Assert-WdtSnapshot $snapshot
    return $snapshot
}

function Protect-WdtSnapshot {
    param($Snapshot,$Context,[bool]$PrivacyMode=$false)
    Assert-WdtSnapshot $Snapshot
    $effectivePrivacy=$PrivacyMode -or $Snapshot.PrivacyMode
    if ($effectivePrivacy -and $null -eq $Context) { $Context=New-WdtRedactionContext }
    $copy=$Snapshot | ConvertTo-Json -Depth 16 -Compress | ConvertFrom-Json
    $copy.PrivacyMode=$effectivePrivacy
    $copy.ToolkitVersion=Protect-WdtDataString $copy.ToolkitVersion $Context
    foreach ($name in @('CreatedUtc','CollectionStartedUtc','CollectionFinishedUtc','WindowStartUtc','WindowEndUtc')) { $copy.$name=ConvertTo-WdtDataUtcText $copy.$name }
    foreach ($module in $copy.Modules) {
        $module.DataErrors=@($module.DataErrors | ForEach-Object { Protect-WdtDataString $_ $Context })
        if ($null -ne $module.Data) {
            $module.Data=Protect-WdtDiagnosticData -Data $module.Data -Context $Context
            foreach ($name in @('WindowStartUtc','WindowEndUtc')) { $module.Data.$name=ConvertTo-WdtDataUtcText $module.Data.$name }
            foreach ($source in $module.Data.Sources) { foreach ($name in @('StartUtc','EndUtc')) { $source.$name=ConvertTo-WdtDataUtcText $source.$name } }
            foreach ($item in $module.Data.Evidence) { foreach ($name in @('TimestampUtc','EndUtc')) { $item.$name=ConvertTo-WdtDataUtcText $item.$name } }
        }
    }
    Assert-WdtSnapshot $copy
    return $copy
}

function Assert-WdtSnapshotJsonShape {
    param([string]$Json)
    # Bound nesting before the JSON parser and reject duplicate property names,
    # including escaped spellings. Parsing still owns all JSON grammar checks.
    $depth=0; $scopes=@{}
    for ($i=0;$i -lt $Json.Length;$i++) {
        $character=$Json[$i]
        if ($character -eq '"') {
            $start=$i; $escaped=$false; $i++
            for (;$i -lt $Json.Length;$i++) {
                if ($escaped) { $escaped=$false;continue }
                if ($Json[$i] -eq '\') { $escaped=$true;continue }
                if ($Json[$i] -eq '"') { break }
            }
            if ($i -ge $Json.Length) { throw 'JSON string.' }
            $next=$i+1
            while ($next -lt $Json.Length -and $Json[$next] -in @(' ',"`r","`n","`t")) { $next++ }
            if ($next -lt $Json.Length -and $Json[$next] -eq ':' -and $depth -gt 0 -and $scopes[$depth].Kind -eq '{') {
                $key=$Json.Substring($start+1,$i-$start-1)
                if ($key.Contains('\')) { $key=ConvertFrom-Json -InputObject $Json.Substring($start,$i-$start+1) -ErrorAction Stop }
                if ($scopes[$depth].Keys.ContainsKey($key)) { throw 'Duplicate JSON property.' }
                $scopes[$depth].Keys[$key]=$true
            }
        }
        elseif ($character -in @('{','[')) {
            $depth++;if ($depth -gt 20) { throw 'JSON depth.' }
            $scopes[$depth]=[pscustomobject]@{Kind=[string]$character;Keys=@{}}
        }
        elseif ($character -in @('}',']')) {
            if ($depth -eq 0 -or ($character -eq '}' -and $scopes[$depth].Kind -ne '{') -or ($character -eq ']' -and $scopes[$depth].Kind -ne '[')) { throw 'JSON balance.' }
            $depth--
        }
    }
    if ($depth -ne 0) { throw 'JSON balance.' }
}

function Read-WdtSnapshot {
    param([Parameter(Mandatory=$true)][string]$LiteralPath)
    $snapshotStream=$null; $snapshotReader=$null
    try {
        $snapshotInputPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LiteralPath)
        $snapshotStream=[System.IO.File]::Open($snapshotInputPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
        if ($snapshotStream.Length -eq 0 -or $snapshotStream.Length -gt $script:WdtSnapshotByteLimit) { throw 'Size.' }
        $snapshotEncoding=New-Object System.Text.UTF8Encoding -ArgumentList $false,$true
        $snapshotReader=New-Object System.IO.StreamReader -ArgumentList $snapshotStream,$snapshotEncoding,$false
        $snapshotBuffer=New-Object char[] 4096
        $snapshotText=New-Object System.Text.StringBuilder
        while (($readCount=$snapshotReader.Read($snapshotBuffer,0,$snapshotBuffer.Length)) -gt 0) {
            if ($snapshotText.Length+$readCount -gt $script:WdtSnapshotCharacterLimit -or $snapshotStream.Position -gt $script:WdtSnapshotByteLimit) { throw 'Size.' }
            [void]$snapshotText.Append($snapshotBuffer,0,$readCount)
        }
        $json=$snapshotText.ToString().TrimStart([char]0xfeff)
        Assert-WdtSnapshotJsonShape $json
        $snapshot=ConvertFrom-Json -InputObject $json -ErrorAction Stop
        Assert-WdtSnapshot $snapshot
        return $snapshot
    }
    catch { throw 'Invalid or unsupported WDT snapshot.' }
    finally { if ($null -ne $snapshotReader) { $snapshotReader.Dispose() }; if ($null -ne $snapshotStream) { $snapshotStream.Dispose() } }
}

function Write-WdtSnapshot {
    param([Parameter(Mandatory=$true)]$Snapshot,[Parameter(Mandatory=$true)][string]$OutputDirectory,$Context)
    try {
        $safe=Protect-WdtSnapshot -Snapshot $Snapshot -Context $Context
        $json=$safe | ConvertTo-Json -Depth 16
        if ($json.Length -gt $script:WdtSnapshotCharacterLimit) { throw 'Size.' }
        $snapshotEncoding=New-Object System.Text.UTF8Encoding -ArgumentList $false,$true
        $snapshotBytes=$snapshotEncoding.GetBytes($json)
        if ($snapshotBytes.Length -gt $script:WdtSnapshotByteLimit) { throw 'Size.' }
        $directory=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'Directory.' }
        for ($attempt=0;$attempt -lt 10;$attempt++) {
            $name='WindowsDiagnosticsSnapshot-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'),[System.Guid]::NewGuid().ToString('N')
            $snapshotPath=Join-Path $directory $name
            $snapshotStream=$null
            try { $snapshotStream=[System.IO.File]::Open($snapshotPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None) }
            catch [System.IO.IOException] { if (Test-Path -LiteralPath $snapshotPath) { continue }; throw }
            try { $snapshotStream.Write($snapshotBytes,0,$snapshotBytes.Length) }
            finally { $snapshotStream.Dispose() }
            return $snapshotPath
        }
        throw 'Names.'
    }
    catch { throw 'Could not write WDT snapshot.' }
}
