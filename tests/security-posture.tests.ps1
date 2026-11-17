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
$securityScript = Join-Path -Path $repositoryRoot -ChildPath 'modules\security\diagnostic.ps1'
$scriptSource = Get-Content -LiteralPath $securityScript -Raw

foreach ($forbiddenText in @('KeyProtector', 'RecoveryPassword', 'Recovery Key', 'CommandLine')) {
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $scriptSource -Value $forbiddenText)) -Message ("Security script must not collect '{0}'." -f $forbiddenText)
}

$standaloneOutput = @(& $securityScript 6>&1 | ForEach-Object { [string]$_ })
foreach ($section in @('Defender', 'Firewall Profiles', 'Secure Boot', 'TPM', 'BitLocker')) {
    Assert-True -Condition (($standaloneOutput -join "`n").Contains(("== {0} ==" -f $section))) -Message ("Standalone security output is missing '{0}'." -f $section)
}

$previousProtocolMode = $env:WDT_FINDING_PROTOCOL
try {
    $unavailableOutput = @(& {
            function Get-Command {
                [CmdletBinding()]
                param([string]$Name)

                return $null
            }

            function Get-CimInstance {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                throw 'Fixture source unavailable.'
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $securityScript 6>&1 | ForEach-Object { [string]$_ }
        })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}

$unavailableText = $unavailableOutput -join "`n"
foreach ($code in @('SECURITY_DEFENDER_UNAVAILABLE', 'SECURITY_FIREWALL_UNAVAILABLE', 'SECURITY_SECURE_BOOT_UNAVAILABLE', 'SECURITY_TPM_UNAVAILABLE', 'SECURITY_BITLOCKER_UNAVAILABLE')) {
    Assert-True -Condition $unavailableText.Contains($code) -Message ("Unavailable fixture did not emit '{0}'." -f $code)
}
Assert-True -Condition ($unavailableText -notmatch '"Severity":"ERROR"') -Message 'Unavailable security sources must not create ERROR findings.'

$partialBitLocker = @(& {
        function Get-Command { [CmdletBinding()] param([string]$Name); return $null }
        function Get-CimInstance {
            [CmdletBinding()]
            param([string]$ClassName, [string]$Namespace)
            if ($ClassName -eq 'Win32_EncryptableVolume') {
                foreach ($volume in @('Fixture A','Fixture B','Fixture C')) { [pscustomobject]@{DeviceID=$volume} }
            }
        }
        function Invoke-CimMethod {
            [CmdletBinding()]
            param($InputObject, [string]$MethodName)
            if ($MethodName -eq 'GetProtectionStatus') {
                if ($InputObject.DeviceID -eq 'Fixture B') { throw 'Fixture protection query failed.' }
                return [pscustomobject]@{ReturnValue=0; ProtectionStatus=1}
            }
            switch ($InputObject.DeviceID) {
                'Fixture A' { [pscustomobject]@{ReturnValue=2150694912; ConversionStatus=0} }
                'Fixture B' { [pscustomobject]@{ReturnValue=0; ConversionStatus=4} }
                'Fixture C' { [pscustomobject]@{ReturnValue=0; ConversionStatus=5} }
            }
        }
        $env:WDT_FINDING_PROTOCOL = '1'
        try { & $securityScript 6>&1 | ForEach-Object { [string]$_ } }
        finally { $env:WDT_FINDING_PROTOCOL = $previousProtocolMode }
    }) -join "`n"
Assert-True -Condition ($partialBitLocker -match 'GetConversionStatus: Unexpected CIM return code: 2150694912') -Message 'A failed conversion query must retain its return code.'
Assert-True -Condition ($partialBitLocker -match 'GetProtectionStatus: Fixture protection query failed') -Message 'A failed protection query must retain its reason.'
Assert-True -Condition ($partialBitLocker -match 'Volume status\s+: EncryptionPaused' -and $partialBitLocker -match 'Volume status\s+: DecryptionPaused') -Message 'Paused conversion states must remain readable across volumes.'
Assert-True -Condition ($partialBitLocker.Contains('SECURITY_BITLOCKER_PARTIAL') -and $partialBitLocker -notmatch 'SECURITY_BITLOCKER_NOT_PROTECTED|SECURITY_BITLOCKER_UNAVAILABLE') -Message 'CIM errors must be reported without claiming a protection state or dropping other volumes.'

$temporaryRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetFullPath($env:RUNNER_TEMP)
}
else {
    [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
}
$temporaryRootPrefix = $temporaryRoot.TrimEnd('\') + '\'
$outputDirectory = Join-Path -Path $temporaryRoot -ChildPath ('wdt-security-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    & (Join-Path -Path $repositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1') -Security -PrivacyMode -ExportMarkdown -OutputDirectory $outputDirectory *> $null

    $textReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.txt' -File | Select-Object -First 1
    $markdownReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.md' -File | Select-Object -First 1
    Assert-True -Condition ($null -ne $textReport) -Message 'Security runner smoke test did not create a TXT report.'
    Assert-True -Condition ($null -ne $markdownReport) -Message 'Security runner smoke test did not create a Markdown report.'

    $textContent = Get-Content -LiteralPath $textReport.FullName -Raw
    $markdownContent = Get-Content -LiteralPath $markdownReport.FullName -Raw
    $combinedContent = $textContent + "`n" + $markdownContent

    Assert-True -Condition ($textContent -match '(?m)^Selected\s+: Security Posture\r?$') -Message 'Security runner selected the wrong module.'
    Assert-True -Condition $textContent.Contains('== Security Posture ==') -Message 'TXT report is missing the Security Posture section.'
    Assert-True -Condition $markdownContent.Contains('## Security Posture') -Message 'Markdown report is missing the Security Posture section.'
    $textSummaryIndex = $textContent.IndexOf('== Findings Summary ==', [System.StringComparison]::Ordinal)
    $textDetailsIndex = $textContent.IndexOf('== Security Posture ==', [System.StringComparison]::Ordinal)
    Assert-True -Condition ($textSummaryIndex -ge 0 -and $textDetailsIndex -ge 0 -and $textSummaryIndex -lt $textDetailsIndex) -Message 'TXT findings summary must exist before Security Posture details.'
    $markdownSummaryIndex = $markdownContent.IndexOf('## Findings Summary', [System.StringComparison]::Ordinal)
    $markdownDetailsIndex = $markdownContent.IndexOf('## Security Posture', [System.StringComparison]::Ordinal)
    Assert-True -Condition ($markdownSummaryIndex -ge 0 -and $markdownDetailsIndex -ge 0 -and $markdownSummaryIndex -lt $markdownDetailsIndex) -Message 'Markdown findings summary must exist before Security Posture details.'
    Assert-True -Condition (-not (Test-IdentityFieldLeak -Text $combinedContent -ComputerName $env:COMPUTERNAME -UserName $env:USERNAME)) -Message 'Privacy Mode leaked a computer or user identity field from Security Posture.'
    Assert-True -Condition ($combinedContent -notmatch '@@WDT_FINDING@@') -Message 'Security report leaked an internal finding marker.'

    Write-Host 'Security posture tests passed.'
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
    throw 'Security posture smoke-test output directory was not removed.'
}
