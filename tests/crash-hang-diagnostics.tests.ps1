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

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$crashScript = Join-Path -Path $repositoryRoot -ChildPath 'scripts\crash-hang-diagnostics.ps1'
$scriptSource = Get-Content -LiteralPath $crashScript -Raw

foreach ($forbiddenText in @('Get-Content', 'Get-FileHash', 'CommandLine')) {
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $scriptSource -Value $forbiddenText)) -Message ("Crash diagnostics must not collect '{0}'." -f $forbiddenText)
}
Assert-True -Condition ($scriptSource -match "MaxEvents = 50") -Message 'Crash diagnostics must default to 50 events.'
Assert-True -Condition ($scriptSource -match "MaxDumpFiles = 20") -Message 'Crash diagnostics must default to 20 dump files.'

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

                if ($FilterHashtable.LogName -eq 'System') {
                    return [pscustomobject]@{
                        TimeCreated  = [datetime]'2026-07-10T10:00:00'
                        LogName      = 'System'
                        Id           = 1001
                        ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
                    }
                }

                return [pscustomobject]@{
                    TimeCreated  = [datetime]'2026-07-10T09:00:00'
                    LogName      = 'Application'
                    Id           = 1000
                    ProviderName = 'Application Error'
                }
            }

            function Test-Path {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                return $false
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $crashScript 6>&1 | ForEach-Object { [string]$_ }
        })

    $unavailableOutput = @(& {
            function Get-WinEvent {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                throw 'Fixture event source unavailable.'
            }

            function Test-Path {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                return $true
            }

            function Get-ChildItem {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                throw 'Fixture dump source unavailable.'
            }

            function Get-Item {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                throw 'Fixture dump source unavailable.'
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
Assert-True -Condition $fixtureText.Contains('CRASH_BUGCHECK_DETECTED') -Message 'BugCheck fixture did not emit an ERROR finding.'

$unavailableText = $unavailableOutput -join "`n"
foreach ($code in @('CRASH_APPLICATION_EVENTS_UNAVAILABLE', 'CRASH_BUGCHECK_EVENTS_UNAVAILABLE', 'CRASH_DUMP_METADATA_UNAVAILABLE')) {
    Assert-True -Condition $unavailableText.Contains($code) -Message ("Unavailable fixture did not emit '{0}'." -f $code)
}
Assert-True -Condition ($unavailableText -notmatch '"Severity":"ERROR"') -Message 'Unavailable crash sources must not create ERROR findings.'

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
