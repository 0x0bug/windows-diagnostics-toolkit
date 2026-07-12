[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$moduleScripts = @(
    'system-info.ps1', 'security-posture.ps1', 'performance-snapshot.ps1', 'network-check.ps1',
    'time-sync-diagnostics.ps1', 'disk-health.ps1', 'crash-hang-diagnostics.ps1', 'event-log-check.ps1',
    'services-check.ps1', 'windows-update-check.ps1'
)

foreach ($script in $moduleScripts) {
    $path = Join-Path $repositoryRoot "scripts\$script"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing module $script." }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw "Parser errors in module $script." }
}

Write-Host 'Ten diagnostic module parser tests passed.'
