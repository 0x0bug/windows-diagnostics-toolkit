[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-NormalizedText {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-Content -LiteralPath $Path -Raw).Replace("`r`n", "`n").Replace("`r", "`n")
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$canonicalBootstrap = Join-Path -Path $repositoryRoot -ChildPath 'scripts\bootstrap\run.ps1'
$publishedBootstrap = Join-Path -Path $repositoryRoot -ChildPath 'site\run.ps1'
$syncScript = Join-Path -Path $repositoryRoot -ChildPath 'scripts\Sync-WdtSiteBootstrap.ps1'
$powerShellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$temporaryRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('wdt-bootstrap-sync-tests-' + [System.Guid]::NewGuid().ToString('N'))
$previousLastExitCode = $global:LASTEXITCODE

foreach ($requiredFile in @($canonicalBootstrap, $publishedBootstrap, $syncScript)) {
    Assert-True (Test-Path -LiteralPath $requiredFile -PathType Leaf) "Required file is missing: $requiredFile"
}

$canonicalHash = (Get-FileHash -LiteralPath $canonicalBootstrap -Algorithm SHA256).Hash
$publishedHash = (Get-FileHash -LiteralPath $publishedBootstrap -Algorithm SHA256).Hash
$byteEqual = [string]::Equals($canonicalHash, $publishedHash, [System.StringComparison]::OrdinalIgnoreCase)
if (-not $byteEqual) {
    Assert-True ((Get-NormalizedText -Path $canonicalBootstrap) -ceq (Get-NormalizedText -Path $publishedBootstrap)) 'Canonical and published bootstrap differ beyond CRLF/LF line endings.'
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $siteCheckout = Join-Path -Path $temporaryRoot -ChildPath 'wdt-site'
    New-Item -ItemType Directory -Path $siteCheckout -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $siteCheckout '.git') -Force | Out-Null

    & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $syncScript -SiteCheckoutPath $siteCheckout *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'Sync script failed for a valid site checkout fixture.'

    $syncedBootstrap = Join-Path -Path $siteCheckout -ChildPath 'run.ps1'
    Assert-True (Test-Path -LiteralPath $syncedBootstrap -PathType Leaf) 'Sync script did not create run.ps1.'
    $syncedHash = (Get-FileHash -LiteralPath $syncedBootstrap -Algorithm SHA256).Hash
    Assert-True ([string]::Equals($canonicalHash, $syncedHash, [System.StringComparison]::OrdinalIgnoreCase)) 'Sync script did not preserve canonical bootstrap bytes.'

    $missingCheckout = Join-Path -Path $temporaryRoot -ChildPath 'missing-site'
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $syncScript -SiteCheckoutPath $missingCheckout *> $null
        $missingCheckoutExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Assert-True ($missingCheckoutExitCode -ne 0) 'Sync script returned success for a missing site checkout.'
}
finally {
    $global:LASTEXITCODE = $previousLastExitCode
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host "Bootstrap synchronization tests passed with PowerShell $($PSVersionTable.PSVersion)."
