[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $repositoryRoot -ChildPath 'scripts\report-common.ps1')

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

function New-TestDiagnosticResult {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [int]$ExitCode = 0,
        [string[]]$OutputLines = @()
    )

    return [pscustomobject][ordered]@{
        Title       = $Title
        Command     = 'test command'
        ExitCode    = $ExitCode
        OutputLines = @($OutputLines)
        ErrorLines  = @()
    }
}

$previousProtocolMode = $env:WDT_FINDING_PROTOCOL
try {
    $env:WDT_FINDING_PROTOCOL = '1'
    $protocolOutput = @(Write-WdtFinding -Severity WARN -Code 'PROTOCOL_WARNING' -Message 'Protocol output.' 6>&1 | ForEach-Object { [string]$_ })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}

Assert-Equal -Expected 1 -Actual $protocolOutput.Count -Message 'Protocol mode must emit exactly one finding marker.'
Assert-True -Condition (Test-WdtFindingLine -Line $protocolOutput[0]) -Message 'Protocol mode must emit a parseable finding marker.'

$warningMarker = ConvertTo-WdtFindingMarker -Severity WARN -Code 'TEST_WARNING' -Message 'A warning was detected.' -Evidence 'Value=1'
$warningResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'Warning Module' -OutputLines @('detail line', $warningMarker, $warningMarker))

Assert-Equal -Expected 0 -Actual $warningResult.ExitCode -Message 'Findings must not change the module exit code.'
Assert-Equal -Expected 1 -Actual $warningResult.OutputLines.Count -Message 'Finding markers must be removed from diagnostic detail output.'
Assert-Equal -Expected 'detail line' -Actual $warningResult.OutputLines[0] -Message 'Non-marker output must be preserved.'

$warningSummary = Get-WdtFindingsSummary -Results @($warningResult)
Assert-Equal -Expected 'WARN' -Actual $warningSummary.OverallStatus -Message 'A warning must set WARN overall status.'
Assert-Equal -Expected 1 -Actual $warningSummary.WarningCount -Message 'Duplicate findings must be removed from the summary.'
Assert-Equal -Expected 0 -Actual $warningSummary.ErrorCount -Message 'A warning-only result must not add errors.'

$multilineMarker = ConvertTo-WdtFindingMarker -Severity WARN -Code 'MULTILINE_WARNING' -Message "First line`r`nSecond line" -Evidence "Value one`nValue two"
$multilineFinding = ConvertFrom-WdtFindingLine -Line $multilineMarker
Assert-Equal -Expected 'First line Second line' -Actual $multilineFinding.Message -Message 'Finding messages must be normalized to one line.'
Assert-Equal -Expected 'Value one Value two' -Actual $multilineFinding.Evidence -Message 'Finding evidence must be normalized to one line.'

$errorMarker = ConvertTo-WdtFindingMarker -Severity ERROR -Code 'TEST_ERROR' -Message 'An error was detected.'
$errorResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'Error Module' -OutputLines @($errorMarker))
$okResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'OK Module' -OutputLines @('normal output'))
$mixedSummary = Get-WdtFindingsSummary -Results @($warningResult, $errorResult, $okResult)

Assert-Equal -Expected 'ERROR' -Actual $mixedSummary.OverallStatus -Message 'ERROR must take precedence over WARN and OK.'
Assert-Equal -Expected 1 -Actual $mixedSummary.ErrorCount -Message 'The error count is incorrect.'
Assert-Equal -Expected 1 -Actual $mixedSummary.WarningCount -Message 'The warning count is incorrect.'
Assert-Equal -Expected 1 -Actual $mixedSummary.OkModuleCount -Message 'A clean module must produce one OK item.'
Assert-Equal -Expected 'ERROR' -Actual $mixedSummary.Items[0].Severity -Message 'Errors must be listed before warnings and OK modules.'
Assert-Equal -Expected 'WARN' -Actual $mixedSummary.Items[1].Severity -Message 'Warnings must be listed after errors.'
Assert-Equal -Expected 'OK' -Actual $mixedSummary.Items[2].Severity -Message 'OK modules must be listed last.'

$invalidResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'Invalid Marker Module' -OutputLines @('@@WDT_FINDING@@{invalid json'))
$invalidSummary = Get-WdtFindingsSummary -Results @($invalidResult)

Assert-Equal -Expected 'ERROR' -Actual $invalidSummary.OverallStatus -Message 'An invalid marker must produce an ERROR summary.'
Assert-Equal -Expected 'FINDING_PROTOCOL_INVALID' -Actual $invalidSummary.Items[0].Code -Message 'An invalid marker must use the protocol error code.'
Assert-Equal -Expected 0 -Actual $invalidResult.OutputLines.Count -Message 'Invalid internal markers must not appear in report details.'

$failedResult = Resolve-WdtDiagnosticResult -Result (New-TestDiagnosticResult -Title 'Failed Module' -ExitCode 7)
$failedSummary = Get-WdtFindingsSummary -Results @($failedResult)

Assert-Equal -Expected 'MODULE_EXECUTION_FAILED' -Actual $failedSummary.Items[0].Code -Message 'A non-zero exit code must create a module execution finding.'
Assert-Equal -Expected 7 -Actual $failedResult.ExitCode -Message 'Result processing must preserve the original exit code.'
Assert-True -Condition (@($failedSummary.Items | Where-Object { $_.Severity -eq 'OK' }).Count -eq 0) -Message 'A failed module must not be marked OK.'

Write-Host 'Report common tests passed.'
