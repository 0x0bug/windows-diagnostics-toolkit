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
