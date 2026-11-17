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
. (Join-Path $PSScriptRoot 'privacy-identity.helpers.ps1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$performanceScript = Join-Path -Path $repositoryRoot -ChildPath 'modules\performance\diagnostic.ps1'
$scriptSource = Get-Content -LiteralPath $performanceScript -Raw

foreach ($forbiddenPattern in @('\.Path\b', '\.Owner\b', 'CommandLine')) {
    Assert-True -Condition ($scriptSource -notmatch $forbiddenPattern) -Message ("Performance script must not collect '{0}'." -f $forbiddenPattern)
}

. $performanceScript

# An empty successful runtime query is different from a failed query. It does
# not establish configured intent or a measured zero percent of usage.
function Invoke-PagefileQueryFixture {
    param([string]$Mode)
    & {
        param($FixtureMode)
        function Get-CimInstance {
            [CmdletBinding()]
            param([string]$ClassName)
            if ($ClassName -ne 'Win32_PageFileUsage') { throw 'Unexpected fixture CIM query.' }
            switch ($FixtureMode) {
                'Empty' { return @() }
                'Failed' { throw 'Fixture pagefile provider failure.' }
                'Zero' { return [pscustomobject]@{ AllocatedBaseSize=0; CurrentUsage=0 } }
                'Active' {
                    [pscustomobject]@{ AllocatedBaseSize=100; CurrentUsage=50 }
                    [pscustomobject]@{ AllocatedBaseSize=300; CurrentUsage=150 }
                }
            }
        }
        Get-PagefileSnapshot
    } $Mode
}
$emptyPagefile = Invoke-PagefileQueryFixture Empty
Assert-True ($null -eq $emptyPagefile.Error) 'A successful empty pagefile query must not become a provider error.'
Assert-Equal 0 $emptyPagefile.RecordCount 'Empty pagefile results must retain an explicit record count.'
foreach ($metric in @('AllocatedMegabytes','UsedMegabytes','UsedPercent')) {
    Assert-True ($null -eq $emptyPagefile.$metric) "Empty pagefile results must not fabricate $metric."
}
$activePagefile = Invoke-PagefileQueryFixture Active
Assert-Equal 2 $activePagefile.RecordCount 'Pagefile record count is wrong.'
Assert-Equal 400 $activePagefile.AllocatedMegabytes 'Active pagefile allocation changed.'
Assert-Equal 200 $activePagefile.UsedMegabytes 'Active pagefile usage changed.'
Assert-Equal 50 $activePagefile.UsedPercent 'Active pagefile percent changed.'
foreach ($mode in @('Failed','Zero')) {
    $failedPagefile = Invoke-PagefileQueryFixture $mode
    Assert-True (-not [string]::IsNullOrWhiteSpace($failedPagefile.Error)) "$mode pagefile evidence must remain unavailable."
    Assert-True ($null -eq $failedPagefile.UsedPercent) "$mode pagefile evidence must not produce a percentage."
}

function Invoke-PagefilePresentationFixture {
    param($Pagefile, [switch]$MemoryUnavailable)
    & {
        param($FixturePagefile, $FixtureMemoryUnavailable)
        function Get-MemorySnapshot {
            if ($FixtureMemoryUnavailable) { return [pscustomobject]@{ AvailablePercent=$null;Error='Fixture memory unavailable.' } }
            [pscustomobject]@{ TotalBytes=1GB; AvailableBytes=512MB; AvailablePercent=50; Error=$null }
        }
        function Get-CpuSnapshot { [pscustomobject]@{ Percent=10; Samples=@(10,10,10); Error=$null } }
        function Get-PagefileSnapshot { $FixturePagefile }
        function Get-ProcessSnapshot { [pscustomobject]@{ Processes=@(); Error=$null } }
        function Get-ProcessCpuActivity { @() }
        @(Invoke-PerformanceSnapshot -ProcessLimit 5 -MemoryWarningPercent 15 -CpuWarningPercent 95 6>&1 | ForEach-Object { [string]$_ })
    } $Pagefile ([bool]$MemoryUnavailable)
}
$savedPagefileProtocol = $env:WDT_FINDING_PROTOCOL
$savedPagefileNonce = $env:WDT_FINDING_NONCE
try {
    $env:WDT_FINDING_PROTOCOL = '1'
    $env:WDT_FINDING_NONCE = ''
    foreach ($mode in @('Empty','Active','Failed','Zero')) {
        $pagefileResult = Invoke-PagefileQueryFixture $mode
        $fixtureLines = @(Invoke-PagefilePresentationFixture $pagefileResult)
        $fixtureText = $fixtureLines -join "`n"
        Assert-True ($fixtureText.Contains('PERFORMANCE_PAGEFILE_UNAVAILABLE') -eq ($mode -in @('Failed','Zero'))) "$mode pagefile availability was classified incorrectly."
        Assert-True (-not $fixtureText.Contains('PERFORMANCE_PAGEFILE_HIGH')) "$mode fixture must not produce a high-usage finding."
        $resolvedFixture = Resolve-WdtDiagnosticResult ([pscustomobject]@{ Title='Performance Snapshot';ExitCode=0;OutputLines=$fixtureLines })
        $summary = Get-WdtFindingsSummary @($resolvedFixture)
        Assert-Equal $(if ($mode -in @('Failed','Zero')) { 'WARN' } else { 'OK' }) $summary.OverallStatus "$mode pagefile finding changed summary availability incorrectly."
        Assert-Equal 0 $summary.ErrorCount 'A pagefile collection state must not become a health ERROR.'
        if ($mode -eq 'Empty') {
            Assert-True ($fixtureText.Contains('No pagefile usage records were returned')) 'Empty pagefile output must explain the successful empty result.'
            Assert-True ($fixtureText.Contains('indeterminate')) 'Empty runtime records must not imply a healthy pagefile assessment.'
            Assert-True ($fixtureText -notmatch '(?m)^(Allocated|Used|Usage)\s*:') 'Empty pagefile output must not display zero-valued metrics.'
            Assert-True ($fixtureText -notmatch '(?i)pagefile.*disabled') 'Empty runtime records must not infer configured intent.'
            $partialLines = @(Invoke-PagefilePresentationFixture $pagefileResult -MemoryUnavailable)
            $partialResult = Resolve-WdtDiagnosticResult ([pscustomobject]@{ Title='Performance Snapshot';ExitCode=0;OutputLines=$partialLines })
            $partialSummary = Get-WdtFindingsSummary @($partialResult)
            Assert-Equal 'WARN' $partialSummary.OverallStatus 'Known-empty pagefile records must not conceal another unavailable source.'
            Assert-Equal 1 $partialSummary.WarningCount 'Only the genuinely unavailable memory source must produce a warning.'
            Assert-Equal 'PERFORMANCE_MEMORY_UNAVAILABLE' $partialSummary.Items[0].Code 'The unavailable memory source finding was lost.'
        }
    }
}
finally { $env:WDT_FINDING_PROTOCOL=$savedPagefileProtocol; $env:WDT_FINDING_NONCE=$savedPagefileNonce }

# Exercise the real snapshot entry point with the two legitimate empty process cases.
$originalFunctions = @{}
foreach ($functionName in @('Get-MemorySnapshot','Get-CpuSnapshot','Get-PagefileSnapshot','Get-ProcessSnapshot','Get-ProcessCpuActivity')) {
    $originalFunctions[$functionName] = (Get-Command $functionName -CommandType Function).ScriptBlock
}
try {
    function Get-MemorySnapshot { [pscustomobject]@{ TotalBytes=1GB; AvailableBytes=512MB; AvailablePercent=50; Error=$null } }
    function Get-CpuSnapshot { [pscustomobject]@{ Percent=10; Samples=@(10,10,10); Error=$null } }
    function Get-PagefileSnapshot { [pscustomobject]@{ AllocatedMegabytes=100; UsedMegabytes=10; UsedPercent=10; Error=$null } }
    function Get-ProcessSnapshot { [pscustomobject]@{ Processes=@(); Error='Fixture process inventory unavailable.' } }
    function Get-ProcessCpuActivity { return @() }
    $emptyInventoryOutput = @(Invoke-PerformanceSnapshot -ProcessLimit 5 -MemoryWarningPercent 15 -CpuWarningPercent 95 6>&1 | ForEach-Object { [string]$_ })
    $emptyInventoryText = $emptyInventoryOutput -join "`n"
    Assert-True -Condition $emptyInventoryText.Contains('== Memory ==') -Message 'Empty process inventory must preserve the Memory section.'
    Assert-True -Condition $emptyInventoryText.Contains('== Currently Most Active Processes ==') -Message 'Empty process inventory must preserve the CPU activity section.'
    Assert-True -Condition $emptyInventoryText.Contains('PERFORMANCE_PROCESS_LIST_UNAVAILABLE') -Message 'Empty process inventory must reach the unavailable process finding.'

    function Get-ProcessSnapshot { [pscustomobject]@{ Processes=@([pscustomobject]@{Id=1;Name='fixture';WorkingSet=1;CpuTime=1;StartTime=$null}); Error=$null } }
    $emptyActivityOutput = @(Invoke-PerformanceSnapshot -ProcessLimit 5 -MemoryWarningPercent 15 -CpuWarningPercent 95 6>&1 | ForEach-Object { [string]$_ })
    $emptyActivityText = $emptyActivityOutput -join "`n"
    Assert-True -Condition $emptyActivityText.Contains('== Top Processes by CPU Time ==') -Message 'Empty CPU activity must preserve the cumulative CPU section.'
    Assert-True -Condition $emptyActivityText.Contains('No process values are available.') -Message 'Empty CPU activity must be reported without aborting the snapshot.'
}
finally {
    foreach ($functionName in $originalFunctions.Keys) { Set-Item -Path ("Function:{0}" -f $functionName) -Value $originalFunctions[$functionName] }
}

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
    $textSummaryIndex = $textContent.IndexOf('== Findings Summary ==', [System.StringComparison]::Ordinal)
    $textDetailsIndex = $textContent.IndexOf('== Performance Snapshot ==', [System.StringComparison]::Ordinal)
    Assert-True -Condition ($textSummaryIndex -ge 0 -and $textDetailsIndex -ge 0 -and $textSummaryIndex -lt $textDetailsIndex) -Message 'TXT findings summary must exist before Performance Snapshot details.'
    $markdownSummaryIndex = $markdownContent.IndexOf('## Findings Summary', [System.StringComparison]::Ordinal)
    $markdownDetailsIndex = $markdownContent.IndexOf('## Performance Snapshot', [System.StringComparison]::Ordinal)
    Assert-True -Condition ($markdownSummaryIndex -ge 0 -and $markdownDetailsIndex -ge 0 -and $markdownSummaryIndex -lt $markdownDetailsIndex) -Message 'Markdown findings summary must exist before Performance Snapshot details.'
    Assert-True -Condition (-not (Test-IdentityFieldLeak -Text $combinedContent -ComputerName $env:COMPUTERNAME -UserName $env:USERNAME)) -Message 'Privacy Mode leaked a computer or user identity field from Performance Snapshot.'
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
