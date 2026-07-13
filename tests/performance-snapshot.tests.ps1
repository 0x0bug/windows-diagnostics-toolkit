[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

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
$performanceScript = Join-Path -Path $repositoryRoot -ChildPath 'modules\performance\diagnostic.ps1'
$scriptSource = Get-Content -LiteralPath $performanceScript -Raw

foreach ($forbiddenPattern in @('\.Path\b', '\.Owner\b', 'CommandLine')) {
    Assert-True -Condition ($scriptSource -notmatch $forbiddenPattern) -Message ("Performance script must not collect '{0}'." -f $forbiddenPattern)
}

. $performanceScript

$previousProtocolMode = $env:WDT_FINDING_PROTOCOL
try {
    $env:WDT_FINDING_PROTOCOL = '1'
    $thresholdOutput = @(Write-PerformanceFindings -MemoryAvailablePercent 4 -CpuPercent 95 -PagefilePercent 80 -MemoryWarningPercent 15 -CpuWarningPercent 95 6>&1 | ForEach-Object { [string]$_ })
    $unavailableOutput = @(Write-PerformanceFindings -MemoryAvailablePercent $null -CpuPercent $null -PagefilePercent $null -MemoryWarningPercent 15 -CpuWarningPercent 95 -UnavailableSources @('Memory', 'Cpu', 'Pagefile', 'Processes') 6>&1 | ForEach-Object { [string]$_ })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}

$thresholdText = $thresholdOutput -join "`n"
foreach ($code in @('PERFORMANCE_MEMORY_CRITICAL', 'PERFORMANCE_CPU_HIGH', 'PERFORMANCE_PAGEFILE_HIGH')) {
    Assert-True -Condition $thresholdText.Contains($code) -Message ("Threshold fixture did not emit '{0}'." -f $code)
}

$unavailableText = $unavailableOutput -join "`n"
foreach ($code in @('PERFORMANCE_MEMORY_UNAVAILABLE', 'PERFORMANCE_CPU_UNAVAILABLE', 'PERFORMANCE_PAGEFILE_UNAVAILABLE', 'PERFORMANCE_PROCESS_LIST_UNAVAILABLE')) {
    Assert-True -Condition $unavailableText.Contains($code) -Message ("Unavailable fixture did not emit '{0}'." -f $code)
}
Assert-True -Condition ($unavailableText -notmatch '"Severity":"ERROR"') -Message 'Unavailable performance sources must not create ERROR findings.'

$standaloneOutput = @(& $performanceScript 6>&1 | ForEach-Object { [string]$_ })
foreach ($section in @('Memory', 'CPU Snapshot', 'Pagefile Usage', 'Top Processes by Working Set', 'Top Processes by CPU Time')) {
    Assert-True -Condition (($standaloneOutput -join "`n").Contains(("== {0} ==" -f $section))) -Message ("Standalone performance output is missing '{0}'." -f $section)
}

$temporaryRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetFullPath($env:RUNNER_TEMP)
}
else {
    [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
}
$temporaryRootPrefix = $temporaryRoot.TrimEnd('\') + '\'
$outputDirectory = Join-Path -Path $temporaryRoot -ChildPath ('wdt-performance-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    & (Join-Path -Path $repositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1') -Performance -PrivacyMode -ExportMarkdown -OutputDirectory $outputDirectory *> $null

    $textReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.txt' -File | Select-Object -First 1
    $markdownReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.md' -File | Select-Object -First 1
    Assert-True -Condition ($null -ne $textReport) -Message 'Performance runner smoke test did not create a TXT report.'
    Assert-True -Condition ($null -ne $markdownReport) -Message 'Performance runner smoke test did not create a Markdown report.'

    $textContent = Get-Content -LiteralPath $textReport.FullName -Raw
    $markdownContent = Get-Content -LiteralPath $markdownReport.FullName -Raw
    $combinedContent = $textContent + "`n" + $markdownContent

    Assert-True -Condition ($textContent -match '(?m)^Selected\s+: Performance Snapshot\r?$') -Message 'Performance runner selected the wrong module.'
    Assert-True -Condition $textContent.Contains('== Performance Snapshot ==') -Message 'TXT report is missing the Performance Snapshot section.'
    Assert-True -Condition $markdownContent.Contains('## Performance Snapshot') -Message 'Markdown report is missing the Performance Snapshot section.'
    Assert-True -Condition ($textContent.IndexOf('== Findings Summary ==', [System.StringComparison]::Ordinal) -lt $textContent.IndexOf('== Performance Snapshot ==', [System.StringComparison]::Ordinal)) -Message 'TXT findings summary must precede Performance Snapshot details.'
    Assert-True -Condition ($markdownContent.IndexOf('## Findings Summary', [System.StringComparison]::Ordinal) -lt $markdownContent.IndexOf('## Performance Snapshot', [System.StringComparison]::Ordinal)) -Message 'Markdown findings summary must precede Performance Snapshot details.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value $env:COMPUTERNAME)) -Message 'Privacy Mode leaked the computer name from Performance Snapshot.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value $env:USERNAME)) -Message 'Privacy Mode leaked the user name from Performance Snapshot.'
    Assert-True -Condition ($combinedContent -notmatch '@@WDT_FINDING@@') -Message 'Performance report leaked an internal finding marker.'

    Write-Host 'Performance snapshot tests passed.'
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
    throw 'Performance snapshot smoke-test output directory was not removed.'
}
