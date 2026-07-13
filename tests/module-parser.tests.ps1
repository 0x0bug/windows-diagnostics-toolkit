[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$moduleRegistryPath = Join-Path $repositoryRoot 'scripts\module-registry.ps1'
if (-not (Test-Path -LiteralPath $moduleRegistryPath -PathType Leaf)) { throw "Missing module registry: $moduleRegistryPath" }
. $moduleRegistryPath

$registrySnapshot = Get-WdtModuleRegistry -ModuleRoot (Join-Path $repositoryRoot 'modules')
$moduleScripts = @($registrySnapshot.Modules | ForEach-Object { @($_.ScriptPaths) } | Sort-Object -Unique)
if ($moduleScripts.Count -eq 0) { throw 'Module registry did not expose any PowerShell scripts.' }

foreach ($script in $moduleScripts) {
    $path = [string]$script
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing registered module script $path." }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw "Parser errors in registered module script $path." }
}

Write-Host ('Diagnostic module parser tests passed ({0} scripts).' -f $moduleScripts.Count)
