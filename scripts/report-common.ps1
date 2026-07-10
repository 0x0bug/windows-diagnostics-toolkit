[CmdletBinding()]
param()

$script:WdtFindingPrefix = '@@WDT_FINDING@@'

function Protect-WdtSensitiveUrlText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $credentialPattern = '(?i)(?<Prefix>\b(?:(?:https?|socks[45]?)://|(?:https?|socks|proxy)=|proxy(?:\s*(?:url|server(?:\(s\))?))?\s*:\s*))[^/\s;@]+@'
    $protectedText = [System.Text.RegularExpressions.Regex]::Replace(
        $Text,
        $credentialPattern,
        '${Prefix}<REDACTED>@'
    )

    $sensitiveQueryPattern = '(?i)(?<Prefix>[?&](?:access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|api[_-]?key|token|key|secret|password|passwd|pwd|credential|auth|authorization|signature|sig|sas|code|session(?:id)?|jwt|x-amz-[a-z0-9_-]+)=)[^&#\s]+'
    return [System.Text.RegularExpressions.Regex]::Replace(
        $protectedText,
        $sensitiveQueryPattern,
        '${Prefix}<REDACTED>'
    )
}

function New-WdtRedactionContext {
    param(
        [AllowEmptyString()][string]$ComputerName = $env:COMPUTERNAME,
        [AllowEmptyString()][string]$UserName = $env:USERNAME,
        [AllowEmptyString()][string]$UserDomain = $env:USERDOMAIN,
        [AllowEmptyString()][string]$UserProfile = $env:USERPROFILE
    )

    $tokenMaps = @{}
    $tokenCounters = @{}
    foreach ($category in @('HOST', 'USER', 'IP', 'MAC', 'ID')) {
        $tokenMaps[$category] = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
        $tokenCounters[$category] = 0
    }

    return [pscustomobject][ordered]@{
        ComputerName  = $ComputerName
        UserName      = $UserName
        UserDomain    = $UserDomain
        UserProfile   = $UserProfile
        TokenMaps     = $tokenMaps
        TokenCounters = $tokenCounters
    }
}

function Get-WdtRedactionToken {
    param(
        [Parameter(Mandatory = $true)]$Context,

        [Parameter(Mandatory = $true)]
        [ValidateSet('HOST', 'USER', 'IP', 'MAC', 'ID')]
        [string]$Category,

        [Parameter(Mandatory = $true)][string]$Value
    )

    $map = $Context.TokenMaps[$Category]
    if ($map.ContainsKey($Value)) {
        return [string]$map[$Value]
    }

    $nextNumber = [int]$Context.TokenCounters[$Category] + 1
    $Context.TokenCounters[$Category] = $nextNumber
    $token = '<{0}-{1}>' -f $Category, $nextNumber
    $map[$Value] = $token
    return $token
}

function Protect-WdtRegexMatches {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)]$Context,

        [Parameter(Mandatory = $true)]
        [ValidateSet('HOST', 'USER', 'IP', 'MAC', 'ID')]
        [string]$Category,

        [Parameter(Mandatory = $true)][System.Text.RegularExpressions.Regex]$Regex,
        [string]$CaptureGroupName,
        [scriptblock]$Validator,
        [scriptblock]$TokenValueSelector
    )

    $matches = $Regex.Matches($Text)
    if ($matches.Count -eq 0) {
        return $Text
    }

    $builder = New-Object System.Text.StringBuilder
    $nextIndex = 0

    foreach ($match in $matches) {
        $valueMatch = $match
        if (-not [string]::IsNullOrWhiteSpace($CaptureGroupName)) {
            $valueMatch = $match.Groups[$CaptureGroupName]
            if (-not $valueMatch.Success) {
                [void]$builder.Append($Text.Substring($nextIndex, ($match.Index + $match.Length) - $nextIndex))
                $nextIndex = $match.Index + $match.Length
                continue
            }
        }

        [void]$builder.Append($Text.Substring($nextIndex, $valueMatch.Index - $nextIndex))
        $value = $valueMatch.Value
        $isValid = $true
        if ($null -ne $Validator) {
            $isValid = [bool](& $Validator $value $valueMatch $Text)
        }

        if ($isValid) {
            $tokenValue = $value
            if ($null -ne $TokenValueSelector) {
                $tokenValue = [string](& $TokenValueSelector $value)
            }

            [void]$builder.Append((Get-WdtRedactionToken -Context $Context -Category $Category -Value $tokenValue))
        }
        else {
            [void]$builder.Append($value)
        }

        $nextIndex = $valueMatch.Index + $valueMatch.Length
    }

    [void]$builder.Append($Text.Substring($nextIndex))
    return $builder.ToString()
}

function Protect-WdtLiteralValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)]$Context,

        [Parameter(Mandatory = $true)]
        [ValidateSet('HOST', 'USER')]
        [string]$Category,

        [AllowEmptyString()][string]$Value,
        [switch]$UseIdentifierBoundary,
        [switch]$UsePathBoundary,
        [switch]$PreserveDiagnosticFileNames,
        [scriptblock]$Validator,
        [scriptblock]$TokenValueSelector
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Text
    }

    $pattern = [System.Text.RegularExpressions.Regex]::Escape($Value)
    if ($UseIdentifierBoundary) {
        $rightBoundary = '(?![A-Z0-9_-])'
        if ($PreserveDiagnosticFileNames) {
            $rightBoundary = '(?![A-Z0-9_-]|\.(?:exe|com|dll|sys|msi|msix|appx|lnk|dmp|mdmp|hdmp|wer)\b)'
        }

        $pattern = '(?<![A-Z0-9_-]){0}{1}' -f $pattern, $rightBoundary
    }
    elseif ($UsePathBoundary) {
        $pattern = '{0}(?=$|[\\/])' -f $pattern
    }

    $regex = New-Object System.Text.RegularExpressions.Regex(
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    return Protect-WdtRegexMatches -Text $Text -Context $Context -Category $Category -Regex $regex -Validator $Validator -TokenValueSelector $TokenValueSelector
}

function Test-WdtDiagnosticNameMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][int]$Length
    )

    $lineStart = 0
    if ($Index -gt 0) {
        $lastLineFeed = $Text.LastIndexOf([char]10, $Index - 1)
        $lastCarriageReturn = $Text.LastIndexOf([char]13, $Index - 1)
        $lineStart = [Math]::Max($lastLineFeed, $lastCarriageReturn) + 1
    }

    $lineEnd = $Text.Length
    $nextLineFeed = $Text.IndexOf([char]10, $Index)
    $nextCarriageReturn = $Text.IndexOf([char]13, $Index)
    foreach ($candidateEnd in @($nextLineFeed, $nextCarriageReturn)) {
        if ($candidateEnd -ge 0 -and $candidateEnd -lt $lineEnd) {
            $lineEnd = $candidateEnd
        }
    }

    $line = $Text.Substring($lineStart, $lineEnd - $lineStart)
    $relativeIndex = $Index - $lineStart
    $diagnosticNamePatterns = @(
        '(?i)\b(?:Faulting application name|Application(?: Name)?|Process(?: Name)?|Image(?: Name)?|Dump(?: File)?(?: Name)?|DumpFile)\s*[:=]\s*(?<WdtValue>[^,;\r\n]+)',
        '(?i)\b(?:Process|Application)\s+(?<WdtValue>.+?)(?=\s+(?:failed|hung|stopped|terminated|crashed|exited|is|was)\b|[,;]|$)'
    )

    foreach ($pattern in $diagnosticNamePatterns) {
        foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($line, $pattern)) {
            $valueGroup = $match.Groups['WdtValue']
            if (-not $valueGroup.Success -or $valueGroup.Value -match '[\\/]') {
                continue
            }

            if ($relativeIndex -ge $valueGroup.Index -and
                ($relativeIndex + $Length) -le ($valueGroup.Index + $valueGroup.Length)) {
                return $true
            }
        }
    }

    return $false
}

function Protect-WdtKnownIdentityValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)]$Context,

        [Parameter(Mandatory = $true)]
        [ValidateSet('HOST', 'USER')]
        [string]$Category,

        [AllowEmptyString()][string]$Value,
        [scriptblock]$TokenValueSelector
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Text
    }

    $diagnosticNameValidator = {
        param([string]$Candidate, $ValueMatch, [string]$SourceText)
        return -not (Test-WdtDiagnosticNameMatch -Text $SourceText -Index $ValueMatch.Index -Length $ValueMatch.Length)
    }

    return Protect-WdtLiteralValue `
        -Text $Text `
        -Context $Context `
        -Category $Category `
        -Value $Value `
        -UseIdentifierBoundary `
        -PreserveDiagnosticFileNames `
        -Validator $diagnosticNameValidator `
        -TokenValueSelector $TokenValueSelector
}

function Protect-WdtText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)]$Context
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    # A known profile prefix is protected first and shares the current user's token.
    $profileTokenValueSelector = {
        param([string]$Candidate)

        if (-not [string]::IsNullOrWhiteSpace($Context.UserName)) {
            return $Context.UserName
        }

        return $Candidate
    }
    $protectedText = Protect-WdtLiteralValue -Text $Text -Context $Context -Category USER -Value $Context.UserProfile -UsePathBoundary -TokenValueSelector $profileTokenValueSelector

    $userProfilePattern = '(?:[A-Z]:)?[\\/](?:Users|Documents and Settings)[\\/](?<WdtValue>[^\\/\r\n:]+)(?=$|[\\/])'
    $userProfileRegex = New-Object System.Text.RegularExpressions.Regex(
        $userProfilePattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category USER -Regex $userProfileRegex -CaptureGroupName 'WdtValue'

    $userFieldPattern = '(?im)(?:^|;)\s*(?:InstalledBy|UserName|RunAs|Owner|Account|User)\s*[:=]\s*(?<WdtValue>[^;\r\n]*?)\s*(?=;|$)'
    $userFieldRegex = New-Object System.Text.RegularExpressions.Regex(
        $userFieldPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $identityValueValidator = {
        param([string]$Candidate)
        return -not [string]::IsNullOrWhiteSpace($Candidate) -and $Candidate -notmatch '^\s*<(?:USER|HOST)-\d+>\s*$'
    }
    $userTokenValueSelector = {
        param([string]$Candidate)

        $normalized = $Candidate.Trim()
        if ($normalized.Contains('\')) {
            return $normalized.Substring($normalized.LastIndexOf('\') + 1)
        }

        return $normalized
    }
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category USER -Regex $userFieldRegex -CaptureGroupName 'WdtValue' -Validator $identityValueValidator -TokenValueSelector $userTokenValueSelector

    $hostFieldPattern = '(?im)(?:^|;)\s*(?:PSComputerName|ComputerName|Computer Name|HostName|Host Name|MachineName|Machine Name|System Name|CSName|Computer|Host)\s*[:=]\s*(?<WdtValue>[^;\r\n]*?)\s*(?=;|$)'
    $hostFieldRegex = New-Object System.Text.RegularExpressions.Regex(
        $hostFieldPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $hostTokenValueSelector = {
        param([string]$Candidate)

        $normalized = $Candidate.Trim().TrimEnd('.')
        if (-not [string]::IsNullOrWhiteSpace($Context.ComputerName) -and
            ($normalized.Equals($Context.ComputerName, [System.StringComparison]::OrdinalIgnoreCase) -or
                $normalized.StartsWith($Context.ComputerName + '.', [System.StringComparison]::OrdinalIgnoreCase))) {
            return $Context.ComputerName
        }

        return $normalized
    }
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category HOST -Regex $hostFieldRegex -CaptureGroupName 'WdtValue' -Validator $identityValueValidator -TokenValueSelector $hostTokenValueSelector

    if (-not [string]::IsNullOrWhiteSpace($Context.UserDomain) -and -not [string]::IsNullOrWhiteSpace($Context.UserName)) {
        $qualifiedUserName = '{0}\{1}' -f $Context.UserDomain, $Context.UserName
        $protectedText = Protect-WdtKnownIdentityValue -Text $protectedText -Context $Context -Category USER -Value $qualifiedUserName -TokenValueSelector $userTokenValueSelector
    }

    if (-not [string]::IsNullOrWhiteSpace($Context.UserName)) {
        $protectedText = Protect-WdtKnownIdentityValue -Text $protectedText -Context $Context -Category USER -Value $Context.UserName -TokenValueSelector $userTokenValueSelector
    }

    if (-not [string]::IsNullOrWhiteSpace($Context.ComputerName)) {
        $protectedText = Protect-WdtKnownIdentityValue -Text $protectedText -Context $Context -Category HOST -Value $Context.ComputerName -TokenValueSelector $hostTokenValueSelector
    }

    $uncHostPattern = '\\\\(?<WdtValue>[^\\/\s]+)(?=\\)'
    $uncHostRegex = New-Object System.Text.RegularExpressions.Regex(
        $uncHostPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $uncHostValidator = {
        param([string]$Candidate)
        return -not [string]::IsNullOrWhiteSpace($Candidate) -and $Candidate -notin @('?', '.', 'localhost') -and $Candidate -notmatch '^<HOST-\d+>$'
    }
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category HOST -Regex $uncHostRegex -CaptureGroupName 'WdtValue' -Validator $uncHostValidator -TokenValueSelector $hostTokenValueSelector

    $macTokenValueSelector = {
        param([string]$Candidate)
        return (($Candidate.Trim()) -replace '[-:.]', '').ToUpperInvariant()
    }

    $macFieldPattern = '(?im)(?:^|;)\s*(?:MAC|MACAddress|MAC Address|PhysicalAddress|Physical Address)\s*[:=]\s*(?<WdtValue>[^;\r\n]*?)\s*(?=;|$)'
    $macFieldRegex = New-Object System.Text.RegularExpressions.Regex(
        $macFieldPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $macFieldValidator = {
        param([string]$Candidate)

        $normalized = $Candidate.Trim()
        if ($normalized -match '^<MAC-\d+>$') {
            return $false
        }

        return $normalized -match '^(?:[0-9A-F]{2}(?:-[0-9A-F]{2}){5}|[0-9A-F]{2}(?::[0-9A-F]{2}){5}|[0-9A-F]{4}(?:\.[0-9A-F]{4}){2}|[0-9A-F]{2}(?:-[0-9A-F]{2}){7}|[0-9A-F]{2}(?::[0-9A-F]{2}){7}|[0-9A-F]{4}(?:\.[0-9A-F]{4}){3})$'
    }
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category MAC -Regex $macFieldRegex -CaptureGroupName 'WdtValue' -Validator $macFieldValidator -TokenValueSelector $macTokenValueSelector

    $macPattern = '(?<![0-9A-F:-])(?:[0-9A-F]{2}(?:-[0-9A-F]{2}){5}|[0-9A-F]{2}(?::[0-9A-F]{2}){5}|[0-9A-F]{4}(?:\.[0-9A-F]{4}){2})(?![0-9A-F:-])'
    $macRegex = New-Object System.Text.RegularExpressions.Regex(
        $macPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category MAC -Regex $macRegex -TokenValueSelector $macTokenValueSelector

    $deviceIdPattern = '(?<![A-Z0-9_])(?<WdtValue>(?:PCI|USB|HID|SCSI|IDE|SWD|ACPI|BTH|BTHENUM|DISPLAY|STORAGE|WPDBUSENUM|ROOT|HTREE|VMBUS|UMB|UEFI)\\[^\s,;]*[A-Z0-9_&*#{}\\%+-])(?![A-Z0-9_&*#{}\\%+-])'
    $deviceIdRegex = New-Object System.Text.RegularExpressions.Regex(
        $deviceIdPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category ID -Regex $deviceIdRegex -CaptureGroupName 'WdtValue'

    $labelledDeviceIdPattern = '(?im)^\s*(?:DeviceId|Device ID|PNPDeviceID|InstanceId|Instance ID|HardwareId|Hardware ID)\s*:\s*(?<WdtValue>[^\r\n]*?)\s*$'
    $labelledDeviceIdRegex = New-Object System.Text.RegularExpressions.Regex(
        $labelledDeviceIdPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $identifierValueValidator = {
        param([string]$Candidate)
        return -not [string]::IsNullOrWhiteSpace($Candidate) -and $Candidate -notmatch '^\s*<ID-\d+>\s*$'
    }
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category ID -Regex $labelledDeviceIdRegex -CaptureGroupName 'WdtValue' -Validator $identifierValueValidator

    $sidPattern = '(?<![A-Z0-9_-])S-\d-\d+(?:-\d+)+(?![0-9-])'
    $sidRegex = New-Object System.Text.RegularExpressions.Regex(
        $sidPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category ID -Regex $sidRegex

    $guidValuePattern = '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
    $guidPattern = '(?<![0-9A-F])(?:\{' + $guidValuePattern + '\}|\(' + $guidValuePattern + '\)|' + $guidValuePattern + ')(?![0-9A-F])'
    $guidRegex = New-Object System.Text.RegularExpressions.Regex(
        $guidPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $guidTokenValueSelector = {
        param([string]$Candidate)

        $guid = [System.Guid]::Empty
        if ([System.Guid]::TryParse($Candidate, [ref]$guid)) {
            return $guid.ToString('D')
        }

        return $Candidate
    }
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category ID -Regex $guidRegex -TokenValueSelector $guidTokenValueSelector

    $volumeLabelPattern = '(?m)^\s*(?:VolumeLabel|Volume Label|Label)\s*:\s*(?<WdtValue>[^\r\n]*?)\s*$'
    $volumeLabelRegex = New-Object System.Text.RegularExpressions.Regex(
        $volumeLabelPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category ID -Regex $volumeLabelRegex -CaptureGroupName 'WdtValue' -Validator $identifierValueValidator

    $commandLinePattern = '(?i)\b(?:ParentCommandLine|Parent Command Line|ProcessCommandLine|Process Command Line|CommandLine|Command Line)\s*[:=]\s*(?<WdtValue>[^\r\n]+)'
    $commandLineRegex = New-Object System.Text.RegularExpressions.Regex(
        $commandLinePattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $commandLineValidator = {
        param([string]$Candidate)
        return -not [string]::IsNullOrWhiteSpace($Candidate) -and $Candidate -notmatch '^\s*<ID-\d+>\s*$'
    }
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category ID -Regex $commandLineRegex -CaptureGroupName 'WdtValue' -Validator $commandLineValidator

    $ipv6CandidatePattern = '(?<![0-9A-Z_.:%-])[0-9A-F:.]*:[0-9A-F:.]*[0-9A-F:](?:%[0-9A-Z_.-]+)?(?![0-9A-Z_:%-]|\.[0-9A-F])'
    $ipv6CandidateRegex = New-Object System.Text.RegularExpressions.Regex(
        $ipv6CandidatePattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $ipv6Validator = {
        param([string]$Candidate)

        $address = $null
        if (-not [System.Net.IPAddress]::TryParse($Candidate, [ref]$address)) {
            return $false
        }

        return $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
    }
    $ipTokenValueSelector = {
        param([string]$Candidate)

        $address = $null
        if ([System.Net.IPAddress]::TryParse($Candidate, [ref]$address)) {
            return $address.ToString()
        }

        return $Candidate
    }
    $protectedText = Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category IP -Regex $ipv6CandidateRegex -Validator $ipv6Validator -TokenValueSelector $ipTokenValueSelector

    $ipv4CandidatePattern = '(?<![0-9A-Z_.])(?:\d{1,3}\.){3}\d{1,3}(?![0-9A-Z_]|\.[0-9])'
    $ipv4CandidateRegex = New-Object System.Text.RegularExpressions.Regex(
        $ipv4CandidatePattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $ipv4Validator = {
        param([string]$Candidate)

        $address = $null
        if (-not [System.Net.IPAddress]::TryParse($Candidate, [ref]$address)) {
            return $false
        }

        return $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    }
    return Protect-WdtRegexMatches -Text $protectedText -Context $Context -Category IP -Regex $ipv4CandidateRegex -Validator $ipv4Validator -TokenValueSelector $ipTokenValueSelector
}

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
