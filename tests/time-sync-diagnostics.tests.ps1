[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-ContainsLiteral {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Text.IndexOf($Value, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}
. (Join-Path $PSScriptRoot 'privacy-identity.helpers.ps1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$timeScript = Join-Path -Path $repositoryRoot -ChildPath 'modules\time\diagnostic.ps1'
$scriptSource = Get-Content -LiteralPath $timeScript -Raw

Assert-True -Condition ($scriptSource.Contains("'/query /source'")) -Message 'Time diagnostics must query the configured time source.'
Assert-True -Condition ($scriptSource.Contains("'/query /status /verbose'")) -Message 'Time diagnostics must query verbose W32Time status.'
Assert-True -Condition ($scriptSource.Contains('System.Diagnostics.ProcessStartInfo')) -Message 'Time diagnostics must use ProcessStartInfo for w32tm.'
Assert-True -Condition $scriptSource.Contains("-ChildPath 'Sysnative'") -Message 'Time diagnostics must use Sysnative from a 32-bit process on 64-bit Windows.'
Assert-True -Condition ($scriptSource -notmatch "Get-Command\s+-Name\s+'w32tm\.exe'") -Message 'Time diagnostics must not fall back to resolving w32tm.exe through PATH.'
Assert-True -Condition ($scriptSource.Contains('RedirectStandardOutput = $true') -and $scriptSource.Contains('RedirectStandardError = $true')) -Message 'w32tm output streams must be redirected.'
Assert-True -Condition ($scriptSource.Contains('CurrentCulture.TextInfo.OEMCodePage')) -Message 'w32tm must use the current system OEM code page.'
Assert-True -Condition ($scriptSource -notmatch '(?i)\b(?:cp)?866\b') -Message 'Time diagnostics must not hardcode code page 866.'
Assert-True -Condition ($scriptSource -notmatch '&\s*w32tm(?:\.exe)?') -Message 'w32tm must not run through the PowerShell native pipeline.'
foreach ($forbiddenText in @('/config', '/resync', '/register', '/unregister')) {
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $scriptSource -Value $forbiddenText)) -Message ("Time diagnostics must not use '{0}'." -f $forbiddenText)
}

function ConvertFrom-TestUtf8Base64 {
    param([string]$Value)
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}

$tokens = $null
$parseErrors = $null
$timeAst = [System.Management.Automation.Language.Parser]::ParseFile($timeScript, [ref]$tokens, [ref]$parseErrors)
foreach ($functionName in @('Write-Section', 'Get-WdtOemEncoding', 'ConvertFrom-WdtOemBytes', 'New-WdtW32tmResult', 'Test-LocalClockSource', 'Invoke-W32tmQuery')) {
    $functionAst = @($timeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true))[0]
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$russianCulture = New-Object System.Globalization.CultureInfo 'ru-RU'
$syntheticEncoding = [System.Text.Encoding]::GetEncoding($russianCulture.TextInfo.OEMCodePage)
$russianText = ConvertFrom-TestUtf8Base64 '0KHQuNC90YXRgNC+0L3QuNC30LDRhtC40Y8g0LLRgNC10LzQtdC90Lg='
$decodedText = ConvertFrom-WdtOemBytes -Bytes $syntheticEncoding.GetBytes($russianText) -Encoding $syntheticEncoding
Assert-True -Condition ($decodedText -ceq $russianText) -Message 'Synthetic OEM bytes were not decoded to Cyrillic.'
$replacementCharacter = [string][char]0xFFFD
Assert-True -Condition (-not $decodedText.Contains($replacementCharacter)) -Message 'OEM decoding produced replacement characters or mojibake.'
$sourceText = ConvertFrom-TestUtf8Base64 '0JjRgdGC0L7Rh9C90LjQuiDQstGA0LXQvNC10L3QuA=='
$errorText = ConvertFrom-TestUtf8Base64 '0KHQu9GD0LbQsdCwINC90LXQtNC+0YHRgtGD0L/QvdCw'
$failedQuery = New-WdtW32tmResult -Stdout $sourceText -Stderr $errorText -ExitCode 5
Assert-True -Condition ($failedQuery.ExitCode -eq 5) -Message 'A nonzero w32tm exit code was not preserved.'
Assert-True -Condition ($failedQuery.Error.Contains($errorText)) -Message 'w32tm stderr was not preserved.'
$lineOne = ConvertFrom-TestUtf8Base64 '0KHRgtGA0L7QutCwIDE='
$lineTwo = ConvertFrom-TestUtf8Base64 '0KHRgtGA0L7QutCwIDI='
$successfulQuery = New-WdtW32tmResult -Stdout ($lineOne + "`r`n" + $lineTwo + "`r`n") -Stderr '' -ExitCode 0
Assert-True -Condition ($successfulQuery.Output.Count -eq 2 -and $null -eq $successfulQuery.Error) -Message 'Successful w32tm output was not preserved.'

$localizedSource = ConvertFrom-TestUtf8Base64 '0JvQvtC60LDQu9GM0L3Ri9C1INGH0LDRgdGLIENNT1M='
$localizedReference = ConvertFrom-TestUtf8Base64 '0JjQtNC10L3RgtC40YTQuNC60LDRgtC+0YAg0L7Qv9C+0YDRizog'
foreach ($source in @('Local CMOS Clock','Local Clock','Free-running System Clock')) {
    Assert-True (Test-LocalClockSource -Source $source) 'Known complete local-clock names must remain recognized.'
}
foreach ($marker in @('LOCL','LOCAL')) {
    $statusLines = @($localizedReference + '0x4C4F434C (' + $localizedSource + ': "' + $marker + '")')
    Assert-True (Test-LocalClockSource -Source $localizedSource -StatusOutput $statusLines) 'Invariant local reference evidence must recognize a translated source.'
}
foreach ($source in @('time.windows.com','dc01.example.local','local-clock.example.com','Local CMOS Clock.example.com','VM IC Time Synchronization Provider','76.79.67.76','')) {
    Assert-True (-not (Test-LocalClockSource -Source $source)) "A valid external or unknown source must not match the English local-name fallback: $source"
}
foreach ($statusLines in @(
        @('ReferenceId: 0x4C4F434C (source IP: 76.79.67.76)'),
        @('ReferenceId: 0x00000000 (source name: "LOCL")'),
        @('ReferenceId: 0x4C4F434C'),
        @('ReferenceId: 0x564D5450 (source name: "VMTP")'),
        @('ReferenceId: 0x4C4F434C (source name: "LOCL")','ReferenceId: 0x564D5450 (source name: "VMTP")'),
        @('Source: peer-0x4C4F434C-LOCL.example.com'),
        @()
    )) {
    Assert-True (-not (Test-LocalClockSource -Source $localizedSource -StatusOutput $statusLines)) 'Missing, ambiguous, or inconsistent reference evidence must not establish a local clock.'
}

Assert-True ((Get-Command Invoke-W32tmQuery).Parameters.ContainsKey('TimeoutSeconds')) 'The standalone w32tm query needs its own bounded timeout.'
foreach ($invalidTimeout in @(0,61)) {
    $rejectedTimeout = $false
    try { Invoke-W32tmQuery -Query Source -TimeoutSeconds $invalidTimeout | Out-Null }
    catch { $rejectedTimeout = $_.FullyQualifiedErrorId -like 'ParameterArgumentValidationError*' }
    Assert-True $rejectedTimeout 'Out-of-range internal query timeouts must be rejected before launch.'
}
. (Join-Path $repositoryRoot 'scripts\process-runner.ps1')
$queryDefinition = @($timeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-W32tmQuery' }, $true))[0].Extent.Text
$fixtureQueryDefinition = $queryDefinition.Replace('$commandPath = Resolve-WdtSystemExecutablePath -FileName ''w32tm.exe''', '$commandPath = $FixtureExecutable').Replace('$startInfo.Arguments = if ($Query -eq ''Source'') { ''/query /source'' } else { ''/query /status /verbose'' }', '$startInfo.Arguments = $FixtureArguments')
Assert-True ($fixtureQueryDefinition -cne $queryDefinition) 'The harmless w32tm fixture must use an AST clone of the production query.'
$queryFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('wdt-time-query-' + [guid]::NewGuid().ToString('N'))
$queryFixtureStarted = Get-Date
$fixtureExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$queryFixturePids = New-Object System.Collections.Generic.List[int]
function Invoke-W32tmFixture {
    param([string]$Path, [int]$TimeoutSeconds = 10, [string]$CaptureFailure, [string]$CleanupFailure)
    & {
        param($FixtureExecutable, $FixtureArguments, $Definition, $Timeout, $FailureMode, $CleanupMode)
        . ([scriptblock]::Create($Definition))
        if (-not [string]::IsNullOrWhiteSpace($CleanupMode)) {
            function Stop-WdtProcessTree {
                param($RootProcess, $CleanupTimeoutMilliseconds)
                Start-Sleep -Milliseconds 500
                if ($CleanupMode -eq 'Thrown') { throw 'Fixture cleanup provider failure.' }
                [pscustomobject]@{ Success=$false; Errors=@('Fixture ownership could not be confirmed.'); Items=@() }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($FailureMode)) {
            $factory = (Get-Command New-WdtStreamCaptureState).ScriptBlock
            $script:fixtureCaptureCount = 0
            function New-WdtStreamCaptureState {
                param([IO.StreamReader]$Reader)
                $script:fixtureCaptureCount++
                if ($script:fixtureCaptureCount -ne 1) { return & $factory -Reader $Reader }
                $completion = New-Object 'System.Threading.Tasks.TaskCompletionSource[int]'
                if ($FailureMode -eq 'Cancelled') { $completion.SetCanceled() }
                else { $completion.SetException((New-Object InvalidOperationException 'Fixture read fault.')) }
                $text = New-Object Text.StringBuilder
                [void]$text.Append('captured-before-fault')
                [pscustomobject]@{ Reader=$Reader; Buffer=(New-Object char[] 4096); Task=$completion.Task; Text=$text; Complete=$false; Error=$null }
            }
        }
        Invoke-W32tmQuery -Query Source -TimeoutSeconds $Timeout
    } $fixtureExecutable ('-NoProfile -ExecutionPolicy Bypass -File "' + $Path + '"') $fixtureQueryDefinition $TimeoutSeconds $CaptureFailure $CleanupFailure
}
try {
    New-Item -ItemType Directory -Path $queryFixtureRoot | Out-Null
    $pressurePath = Join-Path $queryFixtureRoot 'pressure.ps1'
    $pressureSource = @'
[Console]::OutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
for ($i=0; $i -lt 128; $i++) { [Console]::Out.WriteLine(('O' * 4096)); [Console]::Error.WriteLine(('E' * 4096)) }
[Console]::Out.WriteLine('OUT-END')
[Console]::Error.WriteLine('ERR-END')
'@
    [IO.File]::WriteAllText($pressurePath, $pressureSource, [Text.Encoding]::UTF8)
    $pressure = Invoke-W32tmFixture $pressurePath
    Assert-True ($pressure.ExitCode -eq 0 -and $pressure.OutputComplete) 'Simultaneous stdout/stderr pressure must finish with complete capture.'
    Assert-True (($pressure.Output -join "`n").Contains('OUT-END') -and $pressure.Error.Contains('ERR-END')) 'Both pressured streams must retain their final text.'

    $unicodePath = Join-Path $queryFixtureRoot 'unicode.ps1'
    $unicodeSource = '[Console]::OutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage); [Console]::WriteLine([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''0KHQuNC90YXRgNC+0L3QuNC30LDRhtC40Y8g0LLRgNC10LzQtdC90Lg=''))); [Console]::Error.WriteLine(''native-failure-detail''); exit 5'
    [IO.File]::WriteAllText($unicodePath, $unicodeSource, [Text.Encoding]::UTF8)
    $unicode = Invoke-W32tmFixture $unicodePath
    Assert-True ($unicode.ExitCode -eq 5 -and $unicode.OutputComplete -and $unicode.Error.Contains('native-failure-detail')) 'Native nonzero exit and stderr must survive capture.'
    $expectedNativeText = (Get-WdtOemEncoding).GetString((Get-WdtOemEncoding).GetBytes($russianText))
    Assert-True (($unicode.Output -join "`n").Contains($expectedNativeText)) 'Native OEM capture changed the encoded Unicode output.'

    $timeoutPath = Join-Path $queryFixtureRoot 'timeout.ps1'
    [IO.File]::WriteAllText($timeoutPath, '[IO.File]::WriteAllText((Join-Path $PSScriptRoot ''timeout.pid''), [string]$PID); [Console]::WriteLine(''timeout-prefix''); while ($true) { [Console]::Out.WriteLine((''P'' * 8192)); [Console]::Error.WriteLine((''E'' * 8192)) }', [Text.Encoding]::UTF8)
    $queryStarted = Get-Date
    $timeout = Invoke-W32tmFixture $timeoutPath 1
    Assert-True (((Get-Date) - $queryStarted).TotalSeconds -lt 12) 'Standalone w32tm timeout or cleanup exceeded its bound.'
    $queryFixturePids.Add([int][IO.File]::ReadAllText((Join-Path $queryFixtureRoot 'timeout.pid')))
    Assert-True (-not $timeout.OutputComplete -and $null -eq $timeout.ExitCode -and $timeout.Error -match 'timeout') 'Timeout must report incomplete capture and an unknown exit code.'
    Assert-True (($timeout.Output -join "`n").Contains('timeout-prefix')) 'Timeout must preserve captured stdout prefix.'
    Assert-True ($null -eq (Get-Process -Id $queryFixturePids[0] -ErrorAction SilentlyContinue)) 'Timed-out query fixture must be cleaned up.'

    foreach ($cleanupMode in @('Unconfirmed','Thrown')) {
        $queryStarted = Get-Date
        $failedCleanup = Invoke-W32tmFixture $timeoutPath 1 '' $cleanupMode
        $queryFixturePids.Add([int][IO.File]::ReadAllText((Join-Path $queryFixtureRoot 'timeout.pid')))
        Assert-True (((Get-Date) - $queryStarted).TotalSeconds -lt 10) 'Sluggish or failed cleanup must still leave a bounded drain.'
        Assert-True (-not $failedCleanup.OutputComplete -and $null -eq $failedCleanup.ExitCode) 'Unconfirmed cleanup must not invent a completed query.'
        Assert-True ($failedCleanup.Error -match 'Process-tree cleanup (was incomplete|failed): Fixture') 'Cleanup uncertainty must retain its own error instead of claiming successful termination.'
        Assert-True (($failedCleanup.Output -join "`n").Contains('timeout-prefix')) 'Failed cleanup must retain captured text.'
    }

    $heldPath = Join-Path $queryFixtureRoot 'held.ps1'
    $escapedExecutable = $fixtureExecutable.Replace("'", "''")
    $heldSource = '$info = New-Object Diagnostics.ProcessStartInfo; $info.FileName = ''' + $escapedExecutable + '''; $info.Arguments = ''-NoProfile -Command Start-Sleep -Seconds 20''; $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $child = [Diagnostics.Process]::Start($info); [IO.File]::WriteAllText((Join-Path $PSScriptRoot ''held.pid''), [string]$child.Id); [Console]::WriteLine(''held-prefix''); [Console]::WriteLine((''H'' * 8192))'
    [IO.File]::WriteAllText($heldPath, $heldSource, [Text.Encoding]::UTF8)
    $queryStarted = Get-Date
    $held = Invoke-W32tmFixture $heldPath
    $queryFixturePids.Add([int][IO.File]::ReadAllText((Join-Path $queryFixtureRoot 'held.pid')))
    Assert-True (((Get-Date) - $queryStarted).TotalSeconds -lt 8) 'Inherited pipe handles must not block stream drain.'
    Assert-True ($held.ExitCode -eq 0 -and -not $held.OutputComplete -and $held.Error -match 'incomplete') 'Held handles must preserve process success while reporting incomplete capture.'
    Assert-True (($held.Output -join "`n").Contains('held-prefix')) 'Held handles must preserve captured stdout prefix.'

    foreach ($failure in @('Faulted','Cancelled')) {
        $queryStarted = Get-Date
        $faulted = Invoke-W32tmFixture $unicodePath 10 $failure
        Assert-True (((Get-Date) - $queryStarted).TotalSeconds -lt 8) "$failure stream reads must finish without an unbounded drain."
        Assert-True (-not $faulted.OutputComplete -and $faulted.Error -match 'Stream read') "$failure stream reads must report incomplete capture and their own error."
        Assert-True (($faulted.Output -join "`n").Contains('captured-before-fault')) "$failure stream reads must retain captured text."
        Assert-True ($faulted.Error -notmatch 'drain did not finish') "$failure stream reads must not be mislabeled as a drain timeout."
    }
}
finally {
    foreach ($fixturePid in $queryFixturePids) {
        $fixtureProcess = Get-Process -Id $fixturePid -ErrorAction SilentlyContinue
        if ($null -ne $fixtureProcess -and $fixtureProcess.ProcessName -eq [IO.Path]::GetFileNameWithoutExtension($fixtureExecutable) -and $fixtureProcess.StartTime -ge $queryFixtureStarted) {
            Stop-Process -Id $fixturePid -Force -ErrorAction SilentlyContinue
        }
    }
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($queryFixtureRoot)
    $safeTemporaryPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedFixtureRoot.StartsWith($safeTemporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe time query fixture cleanup.' }
    if (Test-Path -LiteralPath $resolvedFixtureRoot) { Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force }
}

# Exercise the actual presentation/classification statements with synthetic
# query results; failed or partial status must never become positive evidence.
$presentationStart = $scriptSource.IndexOf("Write-Host 'Windows Diagnostics Toolkit - Time Sync Diagnostics'", [StringComparison]::Ordinal)
$presentationSource = $scriptSource.Substring($presentationStart).Replace('$timeService = Get-W32TimeService', '$timeService = $FixtureService').Replace('$domainMembership = Get-DomainMembership', '$domainMembership = $FixtureDomain').Replace('$timezoneInformation = Get-TimezoneInformation', '$timezoneInformation = $FixtureTimezone').Replace('$sourceQuery = Invoke-W32tmQuery -Query Source', '$sourceQuery = $FixtureSource').Replace('$statusQuery = Invoke-W32tmQuery -Query Status', '$statusQuery = $FixtureStatus')
function Invoke-TimePresentationFixture {
    param($SourceResult, $StatusResult)
    & {
        param($FixtureSource, $FixtureStatus, $Presentation)
        $FixtureService = [pscustomobject]@{ Service=[pscustomobject]@{Name='W32Time';State='Running';StartMode='Manual'};Error=$null }
        $FixtureDomain = [pscustomobject]@{ PartOfDomain=$false;Error=$null }
        $FixtureTimezone = [pscustomobject]@{ Timezone=[pscustomobject]@{Id='Fixture';DisplayName='Fixture'};Source='Fixture';Error=$null }
        $IncludeTimeServiceEvents = $false
        @(& ([scriptblock]::Create($Presentation)) 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
    } $SourceResult $StatusResult $presentationSource
}
$localStatus = New-WdtW32tmResult -Stdout 'ReferenceId: 0x4C4F434C (source name: "LOCL")' -ExitCode 0
$localSource = New-WdtW32tmResult -Stdout $localizedSource -ExitCode 0
$presentedLocal = Invoke-TimePresentationFixture $localSource $localStatus
Assert-True $presentedLocal.Contains('TIME_SOURCE_LOCAL_CLOCK') 'Complete invariant evidence must reach the local-clock finding.'
foreach ($incompleteStatus in @(
        (New-WdtW32tmResult -Stdout ($localStatus.Output -join "`n") -ExitCode 5),
        (New-WdtW32tmResult -Stdout ($localStatus.Output -join "`n") -ExitCode 0 -CaptureError 'Fixture partial capture.' -OutputComplete $false),
        (New-WdtW32tmResult -Stdout '' -ExitCode 0)
    )) {
    $presentedIncomplete = Invoke-TimePresentationFixture $localSource $incompleteStatus
    Assert-True (-not $presentedIncomplete.Contains('TIME_SOURCE_LOCAL_CLOCK')) 'Failed, partial, or missing status must not prove a translated local clock.'
    Assert-True $presentedIncomplete.Contains('TIME_STATUS_UNAVAILABLE') 'Failed, partial, or missing status must retain its availability finding.'
}
$blankSourceOutput = Invoke-TimePresentationFixture (New-WdtW32tmResult -Stdout '' -ExitCode 0) $localStatus
Assert-True $blankSourceOutput.Contains('TIME_SOURCE_UNAVAILABLE') 'An empty source must not be summarized as available.'
$partialSourceOutput = Invoke-TimePresentationFixture (New-WdtW32tmResult -Stdout 'captured-source-prefix' -ExitCode $null -CaptureError 'Fixture timeout.' -OutputComplete $false) $localStatus
Assert-True ($partialSourceOutput.Contains('Partial output:') -and $partialSourceOutput.Contains('captured-source-prefix') -and $partialSourceOutput.Contains('TIME_SOURCE_UNAVAILABLE')) 'Partial source text and collection failure must both reach the output.'
Assert-True (-not $partialSourceOutput.Contains('TIME_SOURCE_LOCAL_CLOCK')) 'Incomplete source text must not become positive local-clock evidence.'

$standaloneOutput = @(& $timeScript -IncludeTimeServiceEvents 6>&1 | ForEach-Object { [string]$_ })
foreach ($section in @('Windows Time Service', 'Timezone and Clock', 'Time Source', 'W32tm Status', 'Recent Time-Service Warnings and Errors')) {
    Assert-True -Condition (($standaloneOutput -join "`n").Contains(("== {0} ==" -f $section))) -Message ("Standalone time output is missing '{0}'." -f $section)
}

$previousProtocolMode = $env:WDT_FINDING_PROTOCOL
try {
    $unavailableOutput = @(& {
            function Get-Command {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                return $null
            }
            function Test-Path {
                [CmdletBinding()]
                param([string]$LiteralPath, [string]$PathType)

                return $false
            }


            function Get-CimInstance {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                throw 'Fixture CIM source unavailable.'
            }

            function Get-WinEvent {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                throw 'Fixture event source unavailable.'
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $timeScript -IncludeTimeServiceEvents 6>&1 | ForEach-Object { [string]$_ }
        })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}

$unavailableText = $unavailableOutput -join "`n"
foreach ($code in @('TIME_SERVICE_UNAVAILABLE', 'TIME_DOMAIN_MEMBERSHIP_UNAVAILABLE', 'TIME_TIMEZONE_UNAVAILABLE', 'TIME_SOURCE_UNAVAILABLE', 'TIME_STATUS_UNAVAILABLE', 'TIME_EVENTS_UNAVAILABLE')) {
    Assert-True -Condition $unavailableText.Contains($code) -Message ("Unavailable fixture did not emit '{0}'." -f $code)
}
Assert-True -Condition ($unavailableText -notmatch '"Severity":"ERROR"') -Message 'Unavailable time sources must not create ERROR findings.'

$temporaryRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetFullPath($env:RUNNER_TEMP)
}
else {
    [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
}
$temporaryRootPrefix = $temporaryRoot.TrimEnd('\') + '\'
$outputDirectory = Join-Path -Path $temporaryRoot -ChildPath ('wdt-time-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    & (Join-Path -Path $repositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1') -Time -PrivacyMode -ExportMarkdown -OutputDirectory $outputDirectory *> $null

    $textReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.txt' -File | Select-Object -First 1
    $markdownReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.md' -File | Select-Object -First 1
    Assert-True -Condition ($null -ne $textReport) -Message 'Time runner smoke test did not create a TXT report.'
    Assert-True -Condition ($null -ne $markdownReport) -Message 'Time runner smoke test did not create a Markdown report.'

    $textContent = Get-Content -LiteralPath $textReport.FullName -Raw
    $markdownContent = Get-Content -LiteralPath $markdownReport.FullName -Raw
    $combinedContent = $textContent + "`n" + $markdownContent

    Assert-True -Condition ($textContent -match '(?m)^Selected\s+: Time Sync Diagnostics\r?$') -Message 'Time runner selected the wrong module.'
    Assert-True -Condition $textContent.Contains('== Time Sync Diagnostics ==') -Message 'TXT report is missing the Time Sync Diagnostics section.'
    Assert-True -Condition $markdownContent.Contains('## Time Sync Diagnostics') -Message 'Markdown report is missing the Time Sync Diagnostics section.'
    $textSummaryIndex = $textContent.IndexOf('== Findings Summary ==', [System.StringComparison]::Ordinal)
    $textDetailsIndex = $textContent.IndexOf('== Time Sync Diagnostics ==', [System.StringComparison]::Ordinal)
    Assert-True -Condition ($textSummaryIndex -ge 0 -and $textDetailsIndex -ge 0 -and $textSummaryIndex -lt $textDetailsIndex) -Message 'TXT findings summary must exist before time details.'
    $markdownSummaryIndex = $markdownContent.IndexOf('## Findings Summary', [System.StringComparison]::Ordinal)
    $markdownDetailsIndex = $markdownContent.IndexOf('## Time Sync Diagnostics', [System.StringComparison]::Ordinal)
    Assert-True -Condition ($markdownSummaryIndex -ge 0 -and $markdownDetailsIndex -ge 0 -and $markdownSummaryIndex -lt $markdownDetailsIndex) -Message 'Markdown findings summary must exist before time details.'
    Assert-True -Condition (-not (Test-IdentityFieldLeak -Text $combinedContent -ComputerName $env:COMPUTERNAME -UserName $env:USERNAME)) -Message 'Privacy Mode leaked a computer or user identity field from time diagnostics.'
    Assert-True -Condition ($combinedContent -notmatch '@@WDT_FINDING@@') -Message 'Time report leaked an internal finding marker.'

    Write-Host 'Time sync diagnostics tests passed.'
}
finally {
    if (Test-Path -LiteralPath $outputDirectory) {
        $resolvedOutputDirectory = (Resolve-Path -LiteralPath $outputDirectory).Path
        if (-not $resolvedOutputDirectory.StartsWith($temporaryRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a path outside the temporary root: $resolvedOutputDirectory"
        }

        Remove-Item -LiteralPath $resolvedOutputDirectory -Recurse -Force
    }
}

if (Test-Path -LiteralPath $outputDirectory) {
    throw 'Time diagnostics smoke-test output directory was not removed.'
}
