[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }

# Exercise the smoke test's actual path setup without running live diagnostics.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'report-smoke.tests.ps1'), [ref]$tokens, [ref]$errors)
Assert-Equal 0 @($errors).Count 'Report smoke parser errors were found.'
$resolver = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-WdtSmokeCleanupPath' }, $true))
Assert-Equal 1 $resolver.Count 'Report smoke must expose its guarded cleanup resolver.'
. ([scriptblock]::Create($resolver[0].Extent.Text))

$pathAssignments = @{}
foreach ($name in @('smokeTemporaryRoot', 'parallelOutput', 'snapshotOutput')) {
    $assignments = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq $name }, $true))
    Assert-Equal 1 $assignments.Count "Report smoke must assign $name once."
    $pathAssignments[$name] = [scriptblock]::Create($assignments[0].Extent.Text)
}

$originalTemp = $env:TEMP
$originalTmp = $env:TMP
$systemTemporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$fixtureRoot = Join-Path $systemTemporaryRoot ('wdt-smoke-path-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
try {
    $selectedRoot = Join-Path $fixtureRoot 'selected-temp'
    $alternateRoot = Join-Path $fixtureRoot 'environment-temp'
    $siblingRoot = $selectedRoot + '-sibling'
    foreach ($directory in @($selectedRoot, $alternateRoot, $siblingRoot)) { New-Item -ItemType Directory -Path $directory | Out-Null }
    $env:TMP = $selectedRoot
    $env:TEMP = $alternateRoot
    Assert-True ([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -ne [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')) 'Regression requires distinct TEMP and GetTempPath roots.'
    . $pathAssignments['smokeTemporaryRoot']
    Assert-Equal $selectedRoot $smokeTemporaryRoot.TrimEnd('\') 'Smoke did not capture the selected temporary root.'

    # Changes after setup must not change where creation or cleanup is permitted.
    $env:TMP = $alternateRoot
    foreach ($name in @('parallelOutput', 'snapshotOutput')) {
        . $pathAssignments[$name]
        $outputPath = (Get-Variable -Name $name -ValueOnly)
        Assert-Equal $selectedRoot (Split-Path -Parent $outputPath) 'Smoke output used a different root from cleanup.'
        New-Item -ItemType Directory -Path $outputPath | Out-Null
        $cleanupPath = Resolve-WdtSmokeCleanupPath -Path $outputPath -TemporaryRoot $smokeTemporaryRoot
        Assert-Equal ([IO.Path]::GetFullPath($outputPath)) $cleanupPath 'Guard rejected or changed an owned output path.'
        Remove-Item -LiteralPath $cleanupPath -Recurse -Force
        Assert-True (-not (Test-Path -LiteralPath $outputPath)) 'Guarded cleanup did not remove its owned output.'
    }

    foreach ($outsideDirectory in @($alternateRoot, $siblingRoot)) {
        [IO.File]::WriteAllText((Join-Path $outsideDirectory 'must-survive.txt'), 'outside output')
    }
    foreach ($unsafePath in @($selectedRoot, $alternateRoot, $siblingRoot, (Join-Path $selectedRoot '..\environment-temp'))) {
        $threw = $false
        try { Resolve-WdtSmokeCleanupPath -Path $unsafePath -TemporaryRoot $smokeTemporaryRoot | Out-Null } catch { $threw = $true }
        Assert-True $threw "Guard accepted an unsafe cleanup path: $unsafePath"
    }
    foreach ($outsideDirectory in @($alternateRoot, $siblingRoot)) {
        Assert-Equal 'outside output' ([IO.File]::ReadAllText((Join-Path $outsideDirectory 'must-survive.txt'))) 'Outside fixture changed after a rejected cleanup.'
    }
}
finally {
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolvedFixtureRoot.StartsWith($systemTemporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe smoke path regression cleanup.' }
    Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force
}
Write-Host 'Report smoke path regression tests passed.'

# Output readiness must be checked by a real create/write/delete-on-close probe
# before any live collector. Inject an existing owned path at the probe's path
# assignment to force an actual CreateNew I/O failure without changing ACLs.
$repositoryRoot = Split-Path -Parent $PSScriptRoot
foreach ($helper in @('report-common.ps1', 'module-registry.ps1', 'snapshot-compare.ps1', 'incident.ps1')) {
    . (Join-Path $repositoryRoot ('scripts\' + $helper))
}
$tokens = $null; $errors = $null
$entrypointAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repositoryRoot 'Invoke-WindowsDiagnostics.ps1'), [ref]$tokens, [ref]$errors)
Assert-Equal 0 @($errors).Count 'Launcher parser errors were found.'
$outputDefinition = $entrypointAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Initialize-WdtOutputDirectory' }, $true)
Assert-True ($null -ne $outputDefinition) 'Launcher must share output write preflight across live report actions.'
foreach ($definition in @($entrypointAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$registrySnapshot = Get-WdtModuleRegistry -ModuleRoot (Join-Path $repositoryRoot 'modules')
$coreOptions = @{}; $toolkitVersion = 'fixture'; $script:preflightCollectorCalls = 0
function Invoke-DiagnosticScript { $script:preflightCollectorCalls++; throw 'A collector ran before output readiness was checked.' }
$preflightRoot = Join-Path $systemTemporaryRoot ('wdt-output-preflight-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $preflightRoot | Out-Null
try {
    $readyOutput = Join-Path $preflightRoot 'new-output'
    Assert-Equal ([IO.Path]::GetFullPath($readyOutput)) (Initialize-WdtOutputDirectory -OutputDirectory $readyOutput) 'Preflight did not return the created filesystem directory.'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $readyOutput -Force).Count 'Successful preflight left a probe or final report placeholder.'
    $sentinelPath = Join-Path $readyOutput 'existing-report.txt'
    [IO.File]::WriteAllText($sentinelPath, 'existing artifact must survive')
    Initialize-WdtOutputDirectory -OutputDirectory $readyOutput | Out-Null
    Assert-Equal 'existing artifact must survive' ([IO.File]::ReadAllText($sentinelPath)) 'Preflight changed an existing user artifact.'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $readyOutput -Force).Count 'Repeated preflight left a probe.'
    $nonFilesystemPath = 'Env:\WDT_PREFLIGHT_' + [guid]::NewGuid().ToString('N')
    $caught = $null
    try { Initialize-WdtOutputDirectory -OutputDirectory $nonFilesystemPath | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught -and $caught.Exception.Message -like 'Could not prepare OutputDirectory.*') 'Preflight must reject non-filesystem output before creating anything.'
    Assert-True (-not (Test-Path -LiteralPath $nonFilesystemPath)) 'Preflight created a non-filesystem item.'
    $preflightErrorRecords = New-Object 'System.Collections.Generic.List[object]'
    $preflightError = & {
        $ErrorActionPreference = 'Continue'
        try {
            Initialize-WdtOutputDirectory -OutputDirectory $sentinelPath *>&1 | ForEach-Object { $preflightErrorRecords.Add($_) }
        }
        catch { $_.Exception.Message }
    }
    Assert-True ($preflightError -like 'Could not prepare OutputDirectory.*') 'Directory creation failure did not produce the safe output I/O error.'
    Assert-Equal 0 $preflightErrorRecords.Count 'Directory creation emitted raw error details before the safe preflight error.'
    Assert-Equal 'existing artifact must survive' ([IO.File]::ReadAllText($sentinelPath)) 'Directory creation failure changed its existing parent artifact.'

    $probeAssignments = @($outputDefinition.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'probePath' }, $true))
    Assert-Equal 1 $probeAssignments.Count 'Preflight must assign its owned probe path once.'
    $faultHelper = $outputDefinition.Extent.Text.Replace($probeAssignments[0].Extent.Text, '$probePath = Join-Path $resolvedOutputDirectory ''blocked-probe.tmp''')
    . ([scriptblock]::Create($faultHelper))
    $blockedProbe = Join-Path $readyOutput 'blocked-probe.tmp'
    [IO.File]::WriteAllText($blockedProbe, 'occupied probe path must survive')
    $window = Resolve-WdtIncidentWindow -Symptom AppFailure -At '2025-11-02T10:00:00Z'
    foreach ($action in @('Report', 'Snapshot', 'Incident')) {
        $script:preflightCollectorCalls = 0
        $caught = $null
        try {
            if ($action -eq 'Incident') {
                Invoke-WdtIncident -Window $window -OutputDirectory $readyOutput -PrivacyMode $true -ExportMarkdown $true | Out-Null
            }
            else {
                Invoke-WdtReport -ModuleDefinitions @($registrySnapshot.ById['System']) -CoreOptions $coreOptions -OutputDirectory $readyOutput -SaveSnapshot ($action -eq 'Snapshot') -PrivacyMode $true -ExportMarkdown $true -SuppressConsoleOutput $true | Out-Null
            }
        }
        catch { $caught = $_ }
        Assert-True ($null -ne $caught) "$action accepted a failing output probe."
        Assert-True ($caught.Exception.Message -like 'Could not prepare OutputDirectory.*') "$action did not report an output I/O preflight error."
        Assert-True (-not $caught.Exception.Message.Contains($readyOutput) -and -not $caught.Exception.Message.Contains('blocked-probe')) 'Preflight error exposed raw path/exception details.'
        Assert-Equal 0 $script:preflightCollectorCalls "$action collected data before discovering the output failure."
        Assert-Equal 'occupied probe path must survive' ([IO.File]::ReadAllText($blockedProbe)) 'A failed create-only probe overwrote or deleted an existing file.'
        Assert-Equal 2 @(Get-ChildItem -LiteralPath $readyOutput -Force).Count "$action wrote an artifact after output preflight failed."
    }

    # Semantic errors take precedence over even a deliberately failing probe.
    $invalidOutput = Join-Path $preflightRoot 'invalid-selection'
    $caught = $null
    try { Invoke-WdtReport -ModuleDefinitions @($registrySnapshot.ById['Network']) -CoreOptions $coreOptions -OutputDirectory $invalidOutput -SaveSnapshot $true | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught -and $caught.Exception.Message -notlike 'Could not prepare OutputDirectory.*') 'Snapshot module validation must precede preflight.'
    Assert-True (-not (Test-Path -LiteralPath $invalidOutput)) 'Invalid snapshot selection created an output directory.'
    Assert-Equal 0 $script:preflightCollectorCalls 'Invalid snapshot selection invoked a collector.'
    $invalidOutput = Join-Path $preflightRoot 'invalid-comparison'
    $caught = $null
    try { Invoke-WdtSnapshotComparison -BeforePath (Join-Path $preflightRoot 'missing.json') -AfterPath (Join-Path $preflightRoot 'missing.json') -OutputDirectory $invalidOutput | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught -and $caught.Exception.Message -notlike 'Could not prepare OutputDirectory.*') 'Offline snapshot validation must precede preflight.'
    Assert-True (-not (Test-Path -LiteralPath $invalidOutput)) 'Invalid offline input created an output directory.'
    Assert-Equal 0 $script:preflightCollectorCalls 'Offline snapshot comparison invoked a collector.'
}
finally {
    $resolvedPreflightRoot = [IO.Path]::GetFullPath($preflightRoot)
    if (-not $resolvedPreflightRoot.StartsWith($systemTemporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe preflight fixture cleanup.' }
    Remove-Item -LiteralPath $resolvedPreflightRoot -Recurse -Force
}
Write-Host 'Output preflight regression tests passed.'
