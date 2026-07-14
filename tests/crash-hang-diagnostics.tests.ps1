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

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    if ($Expected -ne $Actual) {
        throw "$Message Expected=$Expected Actual=$Actual"
    }
}

function Import-TestFunctions {
    param([string]$Path, [string[]]$Names)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    foreach ($name in $Names) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        $scriptDefinition = $definition.Extent.Text -replace ('^function\s+' + [regex]::Escape($name)), ('function script:' + $name)
        Invoke-Expression $scriptDefinition
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

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$crashScript = Join-Path -Path $repositoryRoot -ChildPath 'modules\crashes\diagnostic.ps1'
$scriptSource = Get-Content -LiteralPath $crashScript -Raw

foreach ($forbiddenText in @('Get-Content', 'Get-FileHash', 'CommandLine')) {
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $scriptSource -Value $forbiddenText)) -Message ("Crash diagnostics must not collect '{0}'." -f $forbiddenText)
}
Assert-True -Condition ($scriptSource -match "MaxEvents = 50") -Message 'Crash diagnostics must default to 50 events.'
Assert-True -Condition ($scriptSource -match "MaxDumpFiles = 20") -Message 'Crash diagnostics must default to 20 dump files.'

Import-TestFunctions $crashScript @('ConvertTo-CrashRecord','Merge-DuplicateCrashRecords','Group-CrashRecords','Get-CrashGroupSeverity')
$nowUtc = ([datetimeoffset](Get-Date)).UtcDateTime
$cutoffUtc = $nowUtc.AddDays(-7)
$sharedReportId = '11111111-2222-3333-4444-555555555555'
$applicationEventRecord = ConvertTo-CrashRecord ([pscustomobject]@{
        ProviderName='Application Error'; Id=1000; TimeCreated=$nowUtc.AddHours(-2)
        Kind='Crash'; Component='fixture.exe'; FailureCode='0xc0000005'; ReportId=$sharedReportId
    }) EventLog
$werEventRecord = ConvertTo-CrashRecord ([pscustomobject]@{
        ProviderName='Windows Error Reporting'; Id=1001; TimeCreated=$nowUtc.AddMinutes(-119)
        Kind='Crash'; Component='fixture.exe'; FailureCode='0xc0000005'; ReportId=$sharedReportId
    }) EventLog
$deduplicated = @(Merge-DuplicateCrashRecords @($applicationEventRecord, $werEventRecord) $cutoffUtc)
Assert-Equal 1 $deduplicated.Count 'Application Error and WER for the same ReportId must become one incident.'
Assert-Equal 2 @($deduplicated[0].Sources).Count 'Deduplication must preserve both evidence sources.'

$bucketStart = $nowUtc.Date.AddHours(12)
$fallbackApplicationEvent = $applicationEventRecord.PSObject.Copy()
$fallbackApplicationEvent.ReportId = ''
$fallbackApplicationEvent.TimeCreated = $bucketStart.AddMinutes(1)
$fallbackWerEvent = $werEventRecord.PSObject.Copy()
$fallbackWerEvent.ReportId = ''
$fallbackWerEvent.TimeCreated = $bucketStart.AddMinutes(4)
$fallbackDeduplicated = @(Merge-DuplicateCrashRecords @($fallbackApplicationEvent, $fallbackWerEvent) $cutoffUtc)
Assert-Equal 1 $fallbackDeduplicated.Count 'Records without ReportId in the same deterministic five-minute bucket must deduplicate.'
$differentFailureEvent = $fallbackWerEvent.PSObject.Copy()
$differentFailureEvent.FailureCode = '0xe0434352'
$differentFailureDeduplication = @(Merge-DuplicateCrashRecords @($fallbackApplicationEvent, $differentFailureEvent) $cutoffUtc)
Assert-Equal 2 $differentFailureDeduplication.Count 'Different failure codes in the same five-minute bucket must remain separate incidents.'

$secondIncident = $applicationEventRecord.PSObject.Copy()
$secondIncident.ReportId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$secondIncident.TimeCreated = $nowUtc.AddMinutes(-30)
$secondIncident.Evidence = 'second fixture crash'
$recentApplicationGroups = @(Group-CrashRecords @(Merge-DuplicateCrashRecords @($applicationEventRecord, $werEventRecord, $secondIncident) $cutoffUtc))
Assert-Equal 1 $recentApplicationGroups.Count 'Repeated crashes of the same component and code must be grouped.'
Assert-Equal 2 $recentApplicationGroups[0].Count 'The grouped crash count must use deduplicated incidents.'
Assert-Equal 'WARN' (Get-CrashGroupSeverity $recentApplicationGroups[0] $nowUtc) 'A repeated recent application crash must be WARN.'

$oldIncident = $applicationEventRecord.PSObject.Copy()
$oldIncident.ReportId = '99999999-8888-7777-6666-555555555555'
$oldIncident.TimeCreated = $nowUtc.AddDays(-3)
$oldGroup = @(Group-CrashRecords @(Merge-DuplicateCrashRecords @($oldIncident) $cutoffUtc))[0]
Assert-Equal 'None' (Get-CrashGroupSeverity $oldGroup $nowUtc) 'A single old application crash must remain context.'

$otherApplication = $secondIncident.PSObject.Copy()
$otherApplication.Component = 'other.exe'
$otherApplication.ReportId = '12345678-1234-1234-1234-123456789012'
$differentApplicationGroups = @(Group-CrashRecords @(Merge-DuplicateCrashRecords @($secondIncident, $otherApplication) $cutoffUtc))
Assert-Equal 2 $differentApplicationGroups.Count 'Different applications must not be grouped together.'

$bugCheckOne = [pscustomobject]@{ TimeCreated=$nowUtc.AddHours(-2); Component='Windows'; Kind='BugCheck'; FailureCode='0x0000009f'; ReportId='10000000-0000-0000-0000-000000000001'; Source='Event Log/SystemErrorReporting'; Evidence='first bugcheck' }
$bugCheckTwo = [pscustomobject]@{ TimeCreated=$nowUtc.AddHours(-1); Component='Windows'; Kind='BugCheck'; FailureCode='0x0000009f'; ReportId='10000000-0000-0000-0000-000000000002'; Source='Reliability Monitor/SystemErrorReporting'; Evidence='second bugcheck' }
$singleBugCheckGroup = @(Group-CrashRecords @(Merge-DuplicateCrashRecords @($bugCheckOne) $cutoffUtc))[0]
Assert-Equal 'WARN' (Get-CrashGroupSeverity $singleBugCheckGroup $nowUtc) 'A recent BugCheck must create a separate WARN signal.'
$repeatedBugCheckGroup = @(Group-CrashRecords @(Merge-DuplicateCrashRecords @($bugCheckOne, $bugCheckTwo) $cutoffUtc))[0]
Assert-Equal 2 $repeatedBugCheckGroup.Count 'Repeated BugChecks must be grouped.'
Assert-Equal 'ERROR' (Get-CrashGroupSeverity $repeatedBugCheckGroup $nowUtc) 'Repeated recent BugChecks must be ERROR.'

$standaloneOutput = @(& $crashScript 6>&1 | ForEach-Object { [string]$_ })
foreach ($section in @('Application Crash and Hang Events', 'BugCheck Events', 'Recent Dump Metadata')) {
    Assert-True -Condition (($standaloneOutput -join "`n").Contains(("== {0} ==" -f $section))) -Message ("Standalone crash output is missing '{0}'." -f $section)
}

$previousProtocolMode = $env:WDT_FINDING_PROTOCOL
try {
    $fixtureOutput = @(& {
            function Get-WinEvent {
                [CmdletBinding()]
                param(
                    [hashtable]$FilterHashtable,
                    [int]$MaxEvents
                )

                if ($FilterHashtable.ProviderName -eq 'Microsoft-Windows-WER-SystemErrorReporting') {
                    return [pscustomobject]@{
                        TimeCreated  = (Get-Date).AddMinutes(-30)
                        LogName      = 'System'
                        Id           = 1001
                        ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
                        Kind         = 'BugCheck'
                        Component    = 'Windows'
                        FailureCode  = '0x0000009f'
                        ReportId     = '20000000-0000-0000-0000-000000000001'
                    }
                }

                if ($FilterHashtable.ProviderName -eq 'Application Error') {
                    return [pscustomobject]@{
                        TimeCreated  = (Get-Date).AddMinutes(-45)
                        LogName      = 'Application'
                        Id           = 1000
                        ProviderName = 'Application Error'
                        Kind         = 'Crash'
                        Component    = 'fixture.exe'
                        FailureCode  = '0xc0000005'
                        ReportId     = '30000000-0000-0000-0000-000000000001'
                    }
                }

                return @()
            }

            function Get-CimInstance {
                [CmdletBinding()]
                param([string]$Namespace, [string]$ClassName, [string]$Filter)

                throw 'Fixture Reliability Monitor unavailable.'
            }

            function Test-Path {
                [CmdletBinding()]
                param([string]$LiteralPath, [string]$PathType)

                return $false
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $crashScript 6>&1 | ForEach-Object { [string]$_ }
        })

    $reliabilityFallbackOutput = @(& {
            function Get-WinEvent {
                [CmdletBinding()]
                param([hashtable]$FilterHashtable, [int]$MaxEvents)

                throw 'Fixture crash event source unavailable.'
            }

            function Get-CimInstance {
                [CmdletBinding()]
                param([string]$Namespace, [string]$ClassName, [string]$Filter)

                return @()
            }

            function Test-Path {
                [CmdletBinding()]
                param([string]$LiteralPath, [string]$PathType)

                return $false
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $crashScript 6>&1 | ForEach-Object { [string]$_ }
        })

    $unavailableOutput = @(& {
            function Get-WinEvent {
                [CmdletBinding()]
                param([hashtable]$FilterHashtable, [int]$MaxEvents)

                throw 'Fixture event source unavailable.'
            }

            function Get-CimInstance {
                [CmdletBinding()]
                param([string]$Namespace, [string]$ClassName, [string]$Filter)

                throw 'Fixture Reliability Monitor unavailable.'
            }

            function Test-Path {
                [CmdletBinding()]
                param([string]$LiteralPath, [string]$PathType)

                return $false
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $crashScript 6>&1 | ForEach-Object { [string]$_ }
        })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}

$fixtureText = $fixtureOutput -join "`n"
Assert-True -Condition $fixtureText.Contains('CRASH_APPLICATION_FAILURES_DETECTED') -Message 'Application crash fixture did not emit a WARN finding.'
Assert-True -Condition $fixtureText.Contains('CRASH_BUGCHECK_DETECTED') -Message 'BugCheck fixture did not emit a separate high-signal finding.'
Assert-True -Condition ($fixtureText -match 'Reliability Monitor: Unavailable') -Message 'Unavailable Reliability Monitor did not preserve the Event Log fallback.'
Assert-True -Condition (-not $fixtureText.Contains('CRASH_ASSESSMENT_UNAVAILABLE')) -Message 'Working Event Log sources must suppress the crash assessment availability finding.'
Assert-True -Condition ($fixtureText -notmatch '"Severity":"ERROR"') -Message 'A single recent BugCheck must not be escalated to ERROR.'

$reliabilityFallbackText = $reliabilityFallbackOutput -join "`n"
Assert-True -Condition ($reliabilityFallbackText.Contains('Reliability Monitor: Available')) -Message 'Working Reliability Monitor fallback was not reported as available.'
Assert-True -Condition (-not $reliabilityFallbackText.Contains('CRASH_ASSESSMENT_UNAVAILABLE')) -Message 'Working Reliability Monitor fallback must suppress the crash assessment availability finding.'
Assert-True -Condition (-not $reliabilityFallbackText.Contains('@@WDT_FINDING@@')) -Message 'Unavailable crash Event Logs with a working empty Reliability fallback must remain context.'

$unavailableText = $unavailableOutput -join "`n"
foreach ($code in @('CRASH_APPLICATION_EVENTS_UNAVAILABLE', 'CRASH_BUGCHECK_EVENTS_UNAVAILABLE', 'CRASH_DUMP_METADATA_UNAVAILABLE')) {
    Assert-True -Condition (-not $unavailableText.Contains($code)) -Message ("Unavailable context must not emit legacy finding '{0}'." -f $code)
}
Assert-Equal 1 ([regex]::Matches($unavailableText, '@@WDT_FINDING@@').Count) 'Complete crash source loss must emit exactly one finding.'
Assert-Equal 1 ([regex]::Matches($unavailableText, 'CRASH_ASSESSMENT_UNAVAILABLE').Count) 'Complete crash source loss must emit one assessment-level code.'
Assert-True -Condition ($unavailableText.Contains('assessment could not be completed')) -Message 'Crash availability message must describe an incomplete assessment.'
Assert-True -Condition ($unavailableText.Contains('"Severity":"WARN"')) -Message 'Crash assessment availability must emit WARN.'
Assert-True -Condition ($unavailableText -notmatch '"Severity":"ERROR"') -Message 'Crash source availability must never create ERROR.'
Assert-True -Condition ($unavailableText -match 'Reliability Monitor: Unavailable') -Message 'Unavailable Reliability Monitor must be shown as context.'

$temporaryRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetFullPath($env:RUNNER_TEMP)
}
else {
    [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
}
$temporaryRootPrefix = $temporaryRoot.TrimEnd('\') + '\'
$outputDirectory = Join-Path -Path $temporaryRoot -ChildPath ('wdt-crashes-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    & (Join-Path -Path $repositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1') -Crashes -PrivacyMode -ExportMarkdown -OutputDirectory $outputDirectory *> $null

    $textReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.txt' -File | Select-Object -First 1
    $markdownReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.md' -File | Select-Object -First 1
    Assert-True -Condition ($null -ne $textReport) -Message 'Crash runner smoke test did not create a TXT report.'
    Assert-True -Condition ($null -ne $markdownReport) -Message 'Crash runner smoke test did not create a Markdown report.'

    $textContent = Get-Content -LiteralPath $textReport.FullName -Raw
    $markdownContent = Get-Content -LiteralPath $markdownReport.FullName -Raw
    $combinedContent = $textContent + "`n" + $markdownContent

    Assert-True -Condition ($textContent -match '(?m)^Selected\s+: Crash and Hang Diagnostics\r?$') -Message 'Crash runner selected the wrong module.'
    Assert-True -Condition $textContent.Contains('== Crash and Hang Diagnostics ==') -Message 'TXT report is missing the Crash and Hang Diagnostics section.'
    Assert-True -Condition $markdownContent.Contains('## Crash and Hang Diagnostics') -Message 'Markdown report is missing the Crash and Hang Diagnostics section.'
    Assert-True -Condition ($textContent.IndexOf('== Findings Summary ==', [System.StringComparison]::Ordinal) -lt $textContent.IndexOf('== Crash and Hang Diagnostics ==', [System.StringComparison]::Ordinal)) -Message 'TXT findings summary must precede crash details.'
    Assert-True -Condition ($markdownContent.IndexOf('## Findings Summary', [System.StringComparison]::Ordinal) -lt $markdownContent.IndexOf('## Crash and Hang Diagnostics', [System.StringComparison]::Ordinal)) -Message 'Markdown findings summary must precede crash details.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value $env:COMPUTERNAME)) -Message 'Privacy Mode leaked the computer name from crash diagnostics.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value $env:USERNAME)) -Message 'Privacy Mode leaked the user name from crash diagnostics.'
    Assert-True -Condition ($combinedContent -notmatch '@@WDT_FINDING@@') -Message 'Crash report leaked an internal finding marker.'

    Write-Host 'Crash and hang diagnostics tests passed.'
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
    throw 'Crash diagnostics smoke-test output directory was not removed.'
}
