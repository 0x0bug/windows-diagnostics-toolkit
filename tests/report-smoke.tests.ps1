[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$entrypoint = Join-Path $repositoryRoot 'Invoke-WindowsDiagnostics.ps1'
. (Join-Path $repositoryRoot 'scripts\report-common.ps1')
. (Join-Path $repositoryRoot 'scripts\diagnostic-catalog.ps1')
. (Join-Path $repositoryRoot 'scripts\process-runner.ps1')
. (Join-Path $repositoryRoot 'scripts\tui.ps1')
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }

$tokens=$null; $errors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile($entrypoint,[ref]$tokens,[ref]$errors)
foreach ($definition in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) { . ([scriptblock]::Create($definition.Extent.Text)) }

$output = Join-Path $env:TEMP ('wdt-report-smoke-' + [guid]::NewGuid().ToString('N'))
try {
    $state = New-WdtTuiState $output
    foreach ($diagnostic in $state.Diagnostics) { $diagnostic.Selected = ($diagnostic.Name -eq 'Network') }
    $parameters = ConvertTo-WdtReportParameters $state 17 $true 'dns.interactive.fixture' 'https://interactive.fixture/' '192.0.2.55'
    $result = Invoke-WdtReport @parameters
    Assert-Equal 0 $result.ExitCode 'Interactive parameter forwarding smoke failed.'
    $report = Get-Content -LiteralPath $result.TextReportPath -Raw
    Assert-True ($report.Contains('External tests: NotTested (-NoExternalNetworkTests)')) 'NoExternalNetworkTests did not reach the network module.'
}
finally { if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force } }

$cliOutput = Join-Path $env:TEMP ('wdt-cli-smoke-' + [guid]::NewGuid().ToString('N'))
try {
    & $entrypoint -System -NoExternalNetworkTests -ModuleTimeoutSeconds 17 -OutputDirectory $cliOutput
    Assert-True (@(Get-ChildItem -LiteralPath $cliOutput -Filter 'WindowsDiagnosticsReport-*.txt' -File).Count -eq 1) 'CLI smoke did not create a report.'
}
finally { if (Test-Path -LiteralPath $cliOutput) { Remove-Item -LiteralPath $cliOutput -Recurse -Force } }
$global:LASTEXITCODE = 0

Write-Host 'Live report smoke tests passed.'
