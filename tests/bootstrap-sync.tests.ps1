[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$canonicalBootstrap = Join-Path -Path $repositoryRoot -ChildPath 'scripts\bootstrap\run.ps1'
$syncScript = Join-Path -Path $repositoryRoot -ChildPath 'scripts\Sync-WdtSiteBootstrap.ps1'
$powerShellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$temporaryRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('wdt-bootstrap-sync-tests-' + [System.Guid]::NewGuid().ToString('N'))
$previousLastExitCode = $global:LASTEXITCODE

foreach ($requiredFile in @($canonicalBootstrap, $syncScript)) {
    Assert-True (Test-Path -LiteralPath $requiredFile -PathType Leaf) "Required file is missing: $requiredFile"
}

$canonicalHash = (Get-FileHash -LiteralPath $canonicalBootstrap -Algorithm SHA256).Hash
$tokens = $null
$parseErrors = $null
$syncAst = [System.Management.Automation.Language.Parser]::ParseFile($syncScript, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'Sync script contains PowerShell parser errors.'

$forbiddenCommands = @('git', 'gh', 'Invoke-RestMethod', 'Invoke-WebRequest', 'curl', 'curl.exe')
$commandAsts = @($syncAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
foreach ($commandAst in $commandAsts) {
    $commandName = $commandAst.GetCommandName()
    Assert-True ($commandName -notin $forbiddenCommands) "Sync script contains a forbidden external or network command: $commandName"
}
$syncScriptText = Get-Content -LiteralPath $syncScript -Raw
Assert-True ($syncScriptText -notmatch '(?i)api\.github\.com') 'Sync script contains a GitHub API endpoint.'

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
