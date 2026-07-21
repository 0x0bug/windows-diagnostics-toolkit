[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SiteCheckoutPath
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$canonicalBootstrap = Join-Path -Path $repositoryRoot -ChildPath 'scripts\bootstrap\run.ps1'
$siteRoot = [System.IO.Path]::GetFullPath($SiteCheckoutPath)
$siteGitMetadata = Join-Path -Path $siteRoot -ChildPath '.git'
$siteBootstrap = Join-Path -Path $siteRoot -ChildPath 'run.ps1'

if (-not (Test-Path -LiteralPath $canonicalBootstrap -PathType Leaf)) {
    throw "Canonical bootstrap is missing: $canonicalBootstrap"
}
if (-not (Test-Path -LiteralPath $siteRoot -PathType Container)) {
    throw "Site checkout directory is missing: $siteRoot"
}
if (-not (Test-Path -LiteralPath $siteGitMetadata)) {
    throw "Site checkout does not contain Git metadata: $siteRoot"
}

Copy-Item -LiteralPath $canonicalBootstrap -Destination $siteBootstrap -Force

$canonicalHash = (Get-FileHash -LiteralPath $canonicalBootstrap -Algorithm SHA256).Hash
$siteHash = (Get-FileHash -LiteralPath $siteBootstrap -Algorithm SHA256).Hash
if (-not [string]::Equals($canonicalHash, $siteHash, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Bootstrap synchronization failed: $siteBootstrap does not match $canonicalBootstrap"
}

Write-Host "Synchronized bootstrap: $siteBootstrap"
Write-Host "SHA-256: $($canonicalHash.ToLowerInvariant())"
