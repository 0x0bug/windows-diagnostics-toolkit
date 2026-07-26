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

# The byte-for-byte bootstrap guarantee requires a repository-owned EOL policy:
# without it, core.autocrlf=true checkouts produce CRLF and a different SHA-256.
$expectedCanonicalBootstrapSha256 = 'fd1f9bc55fe8665c4a2d4706728eff16723a4c62fffd57baeb9c697b35a77bc6'
$gitAttributesPath = Join-Path -Path $repositoryRoot -ChildPath '.gitattributes'
Assert-True (Test-Path -LiteralPath $gitAttributesPath -PathType Leaf) 'Repository root is missing .gitattributes; the PowerShell LF policy must be repository-owned.'
$gitAttributesLines = @(Get-Content -LiteralPath $gitAttributesPath)
Assert-True (@($gitAttributesLines | Where-Object { $_ -match '^\s*\*\.ps1\s+text\s+eol=lf\s*$' }).Count -ge 1) '.gitattributes does not contain the active rule: *.ps1 text eol=lf'
$canonicalBootstrapBytes = [System.IO.File]::ReadAllBytes($canonicalBootstrap)
Assert-True ([System.Array]::IndexOf($canonicalBootstrapBytes, [byte]13) -lt 0) 'Canonical bootstrap checkout contains CR bytes. Re-checkout PowerShell files after the LF policy (for example: git checkout -- .) or fix .gitattributes.'
Assert-True ([string]::Equals($canonicalHash, $expectedCanonicalBootstrapSha256, [System.StringComparison]::OrdinalIgnoreCase)) "Canonical bootstrap SHA-256 changed. Expected $expectedCanonicalBootstrapSha256 but found $($canonicalHash.ToLowerInvariant()). Update the pinned value only for a deliberate, reviewed bootstrap change."

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
