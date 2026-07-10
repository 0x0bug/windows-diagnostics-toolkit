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
$timeScript = Join-Path -Path $repositoryRoot -ChildPath 'scripts\time-sync-diagnostics.ps1'
$scriptSource = Get-Content -LiteralPath $timeScript -Raw

Assert-True -Condition ($scriptSource.Contains('& w32tm.exe /query /source')) -Message 'Time diagnostics must query the configured time source.'
Assert-True -Condition ($scriptSource.Contains('& w32tm.exe /query /status /verbose')) -Message 'Time diagnostics must query verbose W32Time status.'
foreach ($forbiddenText in @('/config', '/resync', '/register', '/unregister')) {
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $scriptSource -Value $forbiddenText)) -Message ("Time diagnostics must not use '{0}'." -f $forbiddenText)
}

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
    Assert-True -Condition ($textContent.IndexOf('== Findings Summary ==', [System.StringComparison]::Ordinal) -lt $textContent.IndexOf('== Time Sync Diagnostics ==', [System.StringComparison]::Ordinal)) -Message 'TXT findings summary must precede time details.'
    Assert-True -Condition ($markdownContent.IndexOf('## Findings Summary', [System.StringComparison]::Ordinal) -lt $markdownContent.IndexOf('## Time Sync Diagnostics', [System.StringComparison]::Ordinal)) -Message 'Markdown findings summary must precede time details.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value $env:COMPUTERNAME)) -Message 'Privacy Mode leaked the computer name from time diagnostics.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value $env:USERNAME)) -Message 'Privacy Mode leaked the user name from time diagnostics.'
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
