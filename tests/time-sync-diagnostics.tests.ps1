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

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$timeScript = Join-Path -Path $repositoryRoot -ChildPath 'modules\time\diagnostic.ps1'
$scriptSource = Get-Content -LiteralPath $timeScript -Raw

Assert-True -Condition ($scriptSource.Contains("'/query /source'")) -Message 'Time diagnostics must query the configured time source.'
Assert-True -Condition ($scriptSource.Contains("'/query /status /verbose'")) -Message 'Time diagnostics must query verbose W32Time status.'
Assert-True -Condition ($scriptSource.Contains('System.Diagnostics.ProcessStartInfo')) -Message 'Time diagnostics must use ProcessStartInfo for w32tm.'
Assert-True -Condition $scriptSource.Contains("-ChildPath 'Sysnative'") -Message 'Time diagnostics must use Sysnative from a 32-bit process on 64-bit Windows.'
Assert-True -Condition ($scriptSource -notmatch "Get-Command\s+-Name\s+'w32tm\.exe'") -Message 'Time diagnostics must not fall back to resolving w32tm.exe through PATH.'
Assert-True -Condition ($scriptSource.Contains('RedirectStandardOutput = $true') -and $scriptSource.Contains('RedirectStandardError = $true')) -Message 'w32tm output streams must be redirected.'
Assert-True -Condition ($scriptSource.Contains('CurrentCulture.TextInfo.OEMCodePage')) -Message 'w32tm must use the current system OEM code page.'
Assert-True -Condition ($scriptSource -notmatch '(?i)\b(?:cp)?866\b') -Message 'Time diagnostics must not hardcode code page 866.'
Assert-True -Condition ($scriptSource -notmatch '&\s*w32tm(?:\.exe)?') -Message 'w32tm must not run through the PowerShell native pipeline.'
foreach ($forbiddenText in @('/config', '/resync', '/register', '/unregister')) {
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $scriptSource -Value $forbiddenText)) -Message ("Time diagnostics must not use '{0}'." -f $forbiddenText)
}

function ConvertFrom-TestUtf8Base64 {
    param([string]$Value)
    return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
}

$tokens = $null
$parseErrors = $null
$timeAst = [System.Management.Automation.Language.Parser]::ParseFile($timeScript, [ref]$tokens, [ref]$parseErrors)
foreach ($functionName in @('Get-WdtOemEncoding', 'ConvertFrom-WdtOemBytes', 'New-WdtW32tmResult')) {
    $functionAst = @($timeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true))[0]
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$russianCulture = New-Object System.Globalization.CultureInfo 'ru-RU'
$syntheticEncoding = [System.Text.Encoding]::GetEncoding($russianCulture.TextInfo.OEMCodePage)
$russianText = ConvertFrom-TestUtf8Base64 '0KHQuNC90YXRgNC+0L3QuNC30LDRhtC40Y8g0LLRgNC10LzQtdC90Lg='
$decodedText = ConvertFrom-WdtOemBytes -Bytes $syntheticEncoding.GetBytes($russianText) -Encoding $syntheticEncoding
Assert-True -Condition ($decodedText -ceq $russianText) -Message 'Synthetic OEM bytes were not decoded to Cyrillic.'
$replacementCharacter = [string][char]0xFFFD
Assert-True -Condition (-not $decodedText.Contains($replacementCharacter)) -Message 'OEM decoding produced replacement characters or mojibake.'
$sourceText = ConvertFrom-TestUtf8Base64 '0JjRgdGC0L7Rh9C90LjQuiDQstGA0LXQvNC10L3QuA=='
$errorText = ConvertFrom-TestUtf8Base64 '0KHQu9GD0LbQsdCwINC90LXQtNC+0YHRgtGD0L/QvdCw'
$failedQuery = New-WdtW32tmResult -Stdout $sourceText -Stderr $errorText -ExitCode 5
Assert-True -Condition ($failedQuery.ExitCode -eq 5) -Message 'A nonzero w32tm exit code was not preserved.'
Assert-True -Condition ($failedQuery.Error.Contains($errorText)) -Message 'w32tm stderr was not preserved.'
$lineOne = ConvertFrom-TestUtf8Base64 '0KHRgtGA0L7QutCwIDE='
$lineTwo = ConvertFrom-TestUtf8Base64 '0KHRgtGA0L7QutCwIDI='
$successfulQuery = New-WdtW32tmResult -Stdout ($lineOne + "`r`n" + $lineTwo + "`r`n") -Stderr '' -ExitCode 0
Assert-True -Condition ($successfulQuery.Output.Count -eq 2 -and $null -eq $successfulQuery.Error) -Message 'Successful w32tm output was not preserved.'

$standaloneOutput = @(& $timeScript -IncludeTimeServiceEvents 6>&1 | ForEach-Object { [string]$_ })
foreach ($section in @('Windows Time Service', 'Timezone and Clock', 'Time Source', 'W32tm Status', 'Recent Time-Service Warnings and Errors')) {
    Assert-True -Condition (($standaloneOutput -join "`n").Contains(("== {0} ==" -f $section))) -Message ("Standalone time output is missing '{0}'." -f $section)
}

$previousProtocolMode = $env:WDT_FINDING_PROTOCOL
try {
    $unavailableOutput = @(& {
            function Get-Command {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                return $null
            }
            function Test-Path {
                [CmdletBinding()]
                param([string]$LiteralPath, [string]$PathType)

                return $false
            }


            function Get-CimInstance {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                throw 'Fixture CIM source unavailable.'
            }

            function Get-WinEvent {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)

                throw 'Fixture event source unavailable.'
            }

            $env:WDT_FINDING_PROTOCOL = '1'
            & $timeScript -IncludeTimeServiceEvents 6>&1 | ForEach-Object { [string]$_ }
        })
}
finally {
    $env:WDT_FINDING_PROTOCOL = $previousProtocolMode
}

$unavailableText = $unavailableOutput -join "`n"
foreach ($code in @('TIME_SERVICE_UNAVAILABLE', 'TIME_DOMAIN_MEMBERSHIP_UNAVAILABLE', 'TIME_TIMEZONE_UNAVAILABLE', 'TIME_SOURCE_UNAVAILABLE', 'TIME_STATUS_UNAVAILABLE', 'TIME_EVENTS_UNAVAILABLE')) {
    Assert-True -Condition $unavailableText.Contains($code) -Message ("Unavailable fixture did not emit '{0}'." -f $code)
}
Assert-True -Condition ($unavailableText -notmatch '"Severity":"ERROR"') -Message 'Unavailable time sources must not create ERROR findings.'

$temporaryRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetFullPath($env:RUNNER_TEMP)
}
else {
    [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
}
$temporaryRootPrefix = $temporaryRoot.TrimEnd('\') + '\'
$outputDirectory = Join-Path -Path $temporaryRoot -ChildPath ('wdt-time-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    & (Join-Path -Path $repositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1') -Time -PrivacyMode -ExportMarkdown -OutputDirectory $outputDirectory *> $null

    $textReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.txt' -File | Select-Object -First 1
    $markdownReport = Get-ChildItem -LiteralPath $outputDirectory -Filter 'WindowsDiagnosticsReport-*.md' -File | Select-Object -First 1
    Assert-True -Condition ($null -ne $textReport) -Message 'Time runner smoke test did not create a TXT report.'
    Assert-True -Condition ($null -ne $markdownReport) -Message 'Time runner smoke test did not create a Markdown report.'

    $textContent = Get-Content -LiteralPath $textReport.FullName -Raw
    $markdownContent = Get-Content -LiteralPath $markdownReport.FullName -Raw
    $combinedContent = $textContent + "`n" + $markdownContent

    Assert-True -Condition ($textContent -match '(?m)^Selected\s+: Time Sync Diagnostics\r?$') -Message 'Time runner selected the wrong module.'
    Assert-True -Condition $textContent.Contains('== Time Sync Diagnostics ==') -Message 'TXT report is missing the Time Sync Diagnostics section.'
    Assert-True -Condition $markdownContent.Contains('## Time Sync Diagnostics') -Message 'Markdown report is missing the Time Sync Diagnostics section.'
    Assert-True -Condition ($textContent.IndexOf('== Findings Summary ==', [System.StringComparison]::Ordinal) -lt $textContent.IndexOf('== Time Sync Diagnostics ==', [System.StringComparison]::Ordinal)) -Message 'TXT findings summary must precede time details.'
    Assert-True -Condition ($markdownContent.IndexOf('## Findings Summary', [System.StringComparison]::Ordinal) -lt $markdownContent.IndexOf('## Time Sync Diagnostics', [System.StringComparison]::Ordinal)) -Message 'Markdown findings summary must precede time details.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value $env:COMPUTERNAME)) -Message 'Privacy Mode leaked the computer name from time diagnostics.'
    Assert-True -Condition (-not (Test-ContainsLiteral -Text $combinedContent -Value $env:USERNAME)) -Message 'Privacy Mode leaked the user name from time diagnostics.'
    Assert-True -Condition ($combinedContent -notmatch '@@WDT_FINDING@@') -Message 'Time report leaked an internal finding marker.'

    Write-Host 'Time sync diagnostics tests passed.'
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
    throw 'Time diagnostics smoke-test output directory was not removed.'
}
