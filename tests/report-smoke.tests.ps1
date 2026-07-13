[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$entrypoint = Join-Path $repositoryRoot 'Invoke-WindowsDiagnostics.ps1'
. (Join-Path $repositoryRoot 'scripts\report-common.ps1')
. (Join-Path $repositoryRoot 'scripts\module-registry.ps1')
. (Join-Path $repositoryRoot 'scripts\process-runner.ps1')
. (Join-Path $repositoryRoot 'scripts\tui.ps1')
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }

$tokens=$null; $errors=$null
$ast = [Management.Automation.Language.Parser]::ParseFile($entrypoint,[ref]$tokens,[ref]$errors)
Assert-Equal 0 @($errors).Count 'Entrypoint parser errors were found.'
$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) -join ','
$expectedParameterNames = 'All,System,Security,Performance,Network,Time,Disk,Crashes,Events,Services,Updates,OutputDirectory,ExportMarkdown,PrivacyMode,Interactive,ModuleTimeoutSeconds,NoExternalNetworkTests,NetworkDnsTestName,NetworkHttpsEndpoint,NetworkIcmpTarget,Module'
Assert-Equal $expectedParameterNames $parameterNames 'Public parameter order changed; existing implicit positional bindings must remain stable.'
foreach ($definition in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) { . ([scriptblock]::Create($definition.Extent.Text)) }
$registrySnapshot = Get-WdtModuleRegistry -ModuleRoot (Join-Path $repositoryRoot 'modules')

$output = Join-Path $env:TEMP ('wdt-report-smoke-' + [guid]::NewGuid().ToString('N'))
try {
    $state = New-WdtTuiState -RegistrySnapshot $registrySnapshot -OutputDirectory $output
    foreach ($diagnostic in $state.Diagnostics) { $diagnostic.Selected = ($diagnostic.Id -eq 'Network') }
    $parameters = ConvertTo-WdtReportParameters -State $state -RegistrySnapshot $registrySnapshot -ModuleTimeoutSeconds 17 -NoExternalNetworkTests $true -NetworkDnsTestName 'dns.interactive.fixture' -NetworkHttpsEndpoint 'https://interactive.fixture/' -NetworkIcmpTarget '192.0.2.55'
    $result = Invoke-WdtReport @parameters
    Assert-Equal 0 $result.ExitCode 'Interactive parameter forwarding smoke failed.'
    $report = Get-Content -LiteralPath $result.TextReportPath -Raw
    Assert-True ($report.Contains('External tests: NotTested (-NoExternalNetworkTests)')) 'NoExternalNetworkTests did not reach the network module.'
}
finally { if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force } }

$cliOutput = Join-Path $env:TEMP ('wdt-cli-module-smoke-' + [guid]::NewGuid().ToString('N'))
try {
    & $entrypoint -Module System,Network -NoExternalNetworkTests -ModuleTimeoutSeconds 17 -OutputDirectory $cliOutput
    $cliReport = @(Get-ChildItem -LiteralPath $cliOutput -Filter 'WindowsDiagnosticsReport-*.txt' -File)
    Assert-True ($cliReport.Count -eq 1) 'Generic -Module smoke did not create a report.'
    $cliText = Get-Content -LiteralPath $cliReport[0].FullName -Raw
    Assert-True ($cliText.Contains('Selected      : System Information, Network Check')) 'Generic -Module selection or registry order changed.'
    Assert-True ($cliText.Contains('External tests: NotTested (-NoExternalNetworkTests)')) 'Generic -Module options did not reach Network.'
}
finally { if (Test-Path -LiteralPath $cliOutput) { Remove-Item -LiteralPath $cliOutput -Recurse -Force } }

$legacyOutput = Join-Path $env:TEMP ('wdt-cli-legacy-smoke-' + [guid]::NewGuid().ToString('N'))
try {
    & $entrypoint -System -Network -NoExternalNetworkTests -ModuleTimeoutSeconds 17 -OutputDirectory $legacyOutput
    $legacyReport = @(Get-ChildItem -LiteralPath $legacyOutput -Filter 'WindowsDiagnosticsReport-*.txt' -File)
    Assert-True ($legacyReport.Count -eq 1) 'Legacy selector smoke did not create a report.'
    $legacyText = Get-Content -LiteralPath $legacyReport[0].FullName -Raw
    Assert-True ($legacyText.Contains('Selected      : System Information, Network Check')) 'Legacy selector union or registry order changed.'
}
finally { if (Test-Path -LiteralPath $legacyOutput) { Remove-Item -LiteralPath $legacyOutput -Recurse -Force } }
$global:LASTEXITCODE = 0

Write-Host 'Live report smoke tests passed.'
