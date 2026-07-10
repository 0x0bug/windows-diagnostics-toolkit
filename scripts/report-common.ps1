[CmdletBinding()]
param()

$script:WdtFindingPrefix = '@@WDT_FINDING@@'

function ConvertTo-WdtSingleLineText {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) {
        return $null
    }

    return (($Text -replace '[\r\n]+', ' ') -replace '\s{2,}', ' ').Trim()
}

function New-WdtFindingObject {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Module,

        [Parameter(Mandatory = $true)]
        [ValidateSet('OK', 'WARN', 'ERROR')]
        [string]$Severity,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Z][A-Z0-9_]*$')]
        [string]$Code,

        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Evidence
    )

    $normalizedMessage = ConvertTo-WdtSingleLineText -Text $Message
    $normalizedEvidence = ConvertTo-WdtSingleLineText -Text $Evidence

    return [pscustomobject][ordered]@{
        Module   = $Module
        Severity = $Severity
        Code     = $Code
        Message  = $normalizedMessage
        Evidence = $normalizedEvidence
    }
}

function ConvertTo-WdtFindingMarker {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('WARN', 'ERROR')]
        [string]$Severity,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Z][A-Z0-9_]*$')]
        [string]$Code,

        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Evidence
    )

    $normalizedMessage = ConvertTo-WdtSingleLineText -Text $Message
    $normalizedEvidence = ConvertTo-WdtSingleLineText -Text $Evidence
    $payload = [ordered]@{
        Severity = $Severity
        Code     = $Code
        Message  = $normalizedMessage
    }

    if (-not [string]::IsNullOrWhiteSpace($normalizedEvidence)) {
        $payload.Evidence = $normalizedEvidence
    }

    return $script:WdtFindingPrefix + ($payload | ConvertTo-Json -Compress)
}

function Write-WdtFinding {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('WARN', 'ERROR')]
        [string]$Severity,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Z][A-Z0-9_]*$')]
        [string]$Code,

        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Evidence
    )

    $normalizedMessage = ConvertTo-WdtSingleLineText -Text $Message
    $normalizedEvidence = ConvertTo-WdtSingleLineText -Text $Evidence

    if ($env:WDT_FINDING_PROTOCOL -eq '1') {
        Write-Host (ConvertTo-WdtFindingMarker -Severity $Severity -Code $Code -Message $normalizedMessage -Evidence $normalizedEvidence)
        return
    }

    if ([string]::IsNullOrWhiteSpace($normalizedEvidence)) {
        Write-Host ('[{0}] {1} - {2}' -f $Severity, $Code, $normalizedMessage)
        return
    }

    Write-Host ('[{0}] {1} - {2} Evidence: {3}' -f $Severity, $Code, $normalizedMessage, $normalizedEvidence)
}

function Test-WdtFindingLine {
    param([AllowEmptyString()][string]$Line)

    if ($null -eq $Line) {
        return $false
    }

    return $Line.StartsWith($script:WdtFindingPrefix, [System.StringComparison]::Ordinal)
}

function ConvertFrom-WdtFindingLine {
    param([Parameter(Mandatory = $true)][string]$Line)

    if (-not (Test-WdtFindingLine -Line $Line)) {
        throw 'The line is not a Windows Diagnostics Toolkit finding marker.'
    }

    $json = $Line.Substring($script:WdtFindingPrefix.Length)
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw 'The finding marker payload is empty.'
    }

    try {
        $payload = $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "The finding marker payload is invalid JSON. $($_.Exception.Message)"
    }

    $propertyNames = @($payload.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($requiredProperty in @('Severity', 'Code', 'Message')) {
        if ($propertyNames -notcontains $requiredProperty) {
            throw "The finding marker is missing the '$requiredProperty' property."
        }
    }

    $severity = ([string]$payload.Severity).ToUpperInvariant()
    if ($severity -notin @('WARN', 'ERROR')) {
        throw "The finding severity '$severity' is unsupported."
    }

    $code = [string]$payload.Code
    if ($code -notmatch '^[A-Z][A-Z0-9_]*$') {
        throw "The finding code '$code' is invalid."
    }

    $message = ConvertTo-WdtSingleLineText -Text ([string]$payload.Message)
    if ([string]::IsNullOrWhiteSpace($message)) {
        throw 'The finding message is empty.'
    }

    $evidence = $null
    if ($propertyNames -contains 'Evidence' -and $null -ne $payload.Evidence) {
        $evidence = ConvertTo-WdtSingleLineText -Text ([string]$payload.Evidence)
    }

    return New-WdtFindingObject -Module '' -Severity $severity -Code $code -Message $message -Evidence $evidence
}

function Resolve-WdtDiagnosticResult {
    param([Parameter(Mandatory = $true)]$Result)

    $cleanOutputLines = New-Object System.Collections.Generic.List[string]
    $findings = New-Object System.Collections.Generic.List[object]

    foreach ($line in @($Result.OutputLines)) {
        if (-not (Test-WdtFindingLine -Line $line)) {
            $cleanOutputLines.Add([string]$line)
            continue
        }

        try {
            $finding = ConvertFrom-WdtFindingLine -Line $line
            $findings.Add((New-WdtFindingObject -Module $Result.Title -Severity $finding.Severity -Code $finding.Code -Message $finding.Message -Evidence $finding.Evidence))
        }
        catch {
            $findings.Add((New-WdtFindingObject -Module $Result.Title -Severity 'ERROR' -Code 'FINDING_PROTOCOL_INVALID' -Message 'The diagnostic emitted an invalid finding marker.' -Evidence $_.Exception.Message))
        }
    }

    if ($Result.ExitCode -ne 0) {
        $findings.Add((New-WdtFindingObject -Module $Result.Title -Severity 'ERROR' -Code 'MODULE_EXECUTION_FAILED' -Message 'The diagnostic completed with a non-zero exit code.' -Evidence ('ExitCode={0}' -f $Result.ExitCode)))
    }

    if ($findings.Count -eq 0) {
        $findings.Add((New-WdtFindingObject -Module $Result.Title -Severity 'OK' -Code 'MODULE_OK' -Message 'No findings.'))
    }

    $Result.OutputLines = @($cleanOutputLines.ToArray())
    if ($Result.PSObject.Properties.Name -contains 'Findings') {
        $Result.Findings = @($findings.ToArray())
    }
    else {
        $Result | Add-Member -MemberType NoteProperty -Name Findings -Value @($findings.ToArray())
    }

    return $Result
}

function Get-WdtFindingsSummary {
    param([Parameter(Mandatory = $true)][object[]]$Results)

    $items = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($result in @($Results)) {
        foreach ($finding in @($result.Findings)) {
            $key = '{0}{5}{1}{5}{2}{5}{3}{5}{4}' -f $finding.Module, $finding.Severity, $finding.Code, $finding.Message, $finding.Evidence, [char]0
            if ($seen.ContainsKey($key)) {
                continue
            }

            $seen[$key] = $true
            $items.Add($finding)
        }
    }

    $errors = @($items | Where-Object { $_.Severity -eq 'ERROR' })
    $warnings = @($items | Where-Object { $_.Severity -eq 'WARN' })
    $okItems = @($items | Where-Object { $_.Severity -eq 'OK' })
    $overallStatus = if ($errors.Count -gt 0) {
        'ERROR'
    }
    elseif ($warnings.Count -gt 0) {
        'WARN'
    }
    else {
        'OK'
    }

    return [pscustomobject][ordered]@{
        OverallStatus = $overallStatus
        ErrorCount     = $errors.Count
        WarningCount   = $warnings.Count
        OkModuleCount  = $okItems.Count
        Items          = @($errors + $warnings + $okItems)
    }
}
