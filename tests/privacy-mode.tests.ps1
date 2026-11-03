[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-ContainsLiteral {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Text.IndexOf($Value, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

. (Join-Path $PSScriptRoot 'privacy-identity.helpers.ps1')

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$temporaryRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetFullPath($env:RUNNER_TEMP)
}
else {
    [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
}
$temporaryRootPrefix = $temporaryRoot.TrimEnd('\') + '\'
$outputDirectory = Join-Path -Path $temporaryRoot -ChildPath ('wdt-privacy-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    & (Join-Path -Path $repositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1') -System -Network -PrivacyMode -ExportMarkdown -OutputDirectory $outputDirectory *> $null

    $textReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.txt' -File | Select-Object -First 1
    $markdownReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.md' -File | Select-Object -First 1
    Assert-True -Condition ($null -ne $textReport) -Message 'Privacy smoke test did not create a TXT report.'
    Assert-True -Condition ($null -ne $markdownReport) -Message 'Privacy smoke test did not create a Markdown report.'

    $textContent = Get-Content -LiteralPath $textReport.FullName -Raw
    $markdownContent = Get-Content -LiteralPath $markdownReport.FullName -Raw
    $combinedContent = $textContent + "`n" + $markdownContent

    $benignIdentityText = "Windows Diagnostics Toolkit`nElevation : Standard user"
    Assert-True -Condition (-not (Test-IdentityFieldLeak -Text $benignIdentityText -ComputerName 'WINDOWS' -UserName 'User')) -Message 'Privacy identity check rejected benign product or elevation text.'
    Assert-True -Condition (Test-IdentityFieldLeak -Text 'Computer name : WDT-IDENTITY-FIXTURE' -ComputerName 'WDT-IDENTITY-FIXTURE' -UserName 'WDT-USER-FIXTURE') -Message 'Privacy identity check did not detect a synthetic host identity leak.'
    Assert-True -Condition (Test-IdentityFieldLeak -Text '- Computer name: `WDT-IDENTITY-FIXTURE`' -ComputerName 'WDT-IDENTITY-FIXTURE' -UserName 'WDT-USER-FIXTURE') -Message 'Privacy identity check did not detect a synthetic Markdown host identity leak.'
    Assert-True -Condition (Test-IdentityFieldLeak -Text 'Computer name : WDT-IDENTITY-FIXTURE.example.test' -ComputerName 'WDT-IDENTITY-FIXTURE' -UserName 'WDT-USER-FIXTURE') -Message 'Privacy identity check did not detect a synthetic FQDN host identity leak.'
    Assert-True -Condition (Test-IdentityFieldLeak -Text 'Owner : WDT-USER-FIXTURE' -ComputerName 'WDT-IDENTITY-FIXTURE' -UserName 'WDT-USER-FIXTURE') -Message 'Privacy identity check did not detect a synthetic user identity leak.'
    Assert-True -Condition (Test-IdentityFieldLeak -Text '- User: `WDT-USER-FIXTURE`' -ComputerName 'WDT-IDENTITY-FIXTURE' -UserName 'WDT-USER-FIXTURE') -Message 'Privacy identity check did not detect a synthetic Markdown user identity leak.'

    Assert-True -Condition ($textContent -match '(?m)^Privacy mode\s+: enabled\r?$') -Message 'TXT report does not show enabled Privacy Mode.'
    Assert-True -Condition ($markdownContent -match '(?m)^- Privacy mode: `enabled`\r?$') -Message 'Markdown report does not show enabled Privacy Mode.'
    Assert-True -Condition ($combinedContent -notmatch '@@WDT_FINDING@@') -Message 'Privacy report leaked an internal finding marker.'
    Assert-True -Condition (-not (Test-IdentityFieldLeak -Text $combinedContent -ComputerName $env:COMPUTERNAME -UserName $env:USERNAME)) -Message 'Privacy report leaked a computer or user identity field.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value $env:USERPROFILE)) -Message 'Privacy report leaked the user-profile path.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value '1.1.1.1')) -Message 'Privacy report leaked the connectivity test IP address.'
    Assert-True -Condition ($combinedContent -match '<HOST-1>') -Message 'Privacy report is missing a host token.'
    Assert-True -Condition ($combinedContent -match '<IP-[0-9]+>') -Message 'Privacy report is missing an IP token.'
    Assert-True -Condition ($combinedContent -match 'www\.microsoft\.com') -Message 'Privacy Mode unexpectedly removed the DNS test name.'

    Write-Host 'Privacy mode smoke test passed.'
}
finally {
    if (Test-Path -LiteralPath $outputDirectory) {
        $resolvedOutputDirectory = (Resolve-Path -LiteralPath $outputDirectory).Path
        if (-not $resolvedOutputDirectory.StartsWith($temporaryRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a path outside the temporary root: $resolvedOutputDirectory"
        }

        Remove-Item -LiteralPath $resolvedOutputDirectory -Recurse -Force
    }
}

if (Test-Path -LiteralPath $outputDirectory) {
    throw 'Privacy smoke-test output directory was not removed.'
}
