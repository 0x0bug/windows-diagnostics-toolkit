[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'report-common.ps1')

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)

    Write-Host ''
    Write-Host "== $Title =="
}

function ConvertTo-SafeText {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return 'Unknown'
    }

    return (([string]$Value -replace '[\r\n]+', ' ') -replace '\s{2,}', ' ').Trim()
}

function ConvertTo-BooleanOrNull {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim()
    if ($text -match '^(True|Enabled|On|1)$') {
        return $true
    }

    if ($text -match '^(False|Disabled|Off|0)$') {
        return $false
    }

    return $null
}

function ConvertTo-BooleanDisplay {
    param([object]$Value)

    $normalized = ConvertTo-BooleanOrNull -Value $Value
    if ($null -eq $normalized) {
        return 'Unknown'
    }

    if ($normalized) {
        return 'Enabled'
    }

    return 'Disabled'
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $null
}

function Get-DefenderStatus {
    $lastError = $null

    if ($null -ne (Get-Command -Name 'Get-MpComputerStatus' -ErrorAction SilentlyContinue)) {
        try {
            return [pscustomobject]@{
                Status = Get-MpComputerStatus -ErrorAction Stop
                Source = 'Get-MpComputerStatus'
                Error  = $null
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    try {
        return [pscustomobject]@{
            Status = Get-CimInstance -Namespace 'root\Microsoft\Windows\Defender' -ClassName 'MSFT_MpComputerStatus' -ErrorAction Stop
            Source = 'MSFT_MpComputerStatus (CIM)'
            Error  = $null
        }
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($lastError)) {
            $lastError = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Status = $null
        Source = 'Unavailable'
        Error  = $lastError
    }
}

function Get-FirewallProfiles {
    $lastError = $null

    if ($null -ne (Get-Command -Name 'Get-NetFirewallProfile' -ErrorAction SilentlyContinue)) {
        try {
            return [pscustomobject]@{
                Profiles = @(Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object {
                        [pscustomobject]@{
                            Name    = $_.Name
                            Enabled = $_.Enabled
                            Source  = 'Get-NetFirewallProfile'
                        }
                    })
                Error    = $null
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    try {
        return [pscustomobject]@{
            Profiles = @(Get-CimInstance -Namespace 'root\StandardCimv2' -ClassName 'MSFT_NetFirewallProfile' -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{
                        Name    = Get-ObjectPropertyValue -InputObject $_ -Names @('Name', 'InstanceID')
                        Enabled = Get-ObjectPropertyValue -InputObject $_ -Names @('Enabled')
                        Source  = 'MSFT_NetFirewallProfile (CIM)'
                    }
                })
            Error    = $null
        }
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($lastError)) {
            $lastError = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Profiles = @()
        Error    = $lastError
    }
}

function Get-SecureBootStatus {
    $lastError = $null

    if ($null -ne (Get-Command -Name 'Confirm-SecureBootUEFI' -ErrorAction SilentlyContinue)) {
        try {
            return [pscustomobject]@{
                Available = $true
                Enabled   = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
                Source    = 'Confirm-SecureBootUEFI'
                Error     = $null
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    foreach ($className in @('MSFT_SecureBoot', 'MS_SecureBoot')) {
        try {
            $status = Get-CimInstance -Namespace 'root\WMI' -ClassName $className -ErrorAction Stop | Select-Object -First 1
            $enabled = ConvertTo-BooleanOrNull -Value (Get-ObjectPropertyValue -InputObject $status -Names @('SecureBootEnabled', 'Enabled', 'State'))
            if ($null -ne $enabled) {
                return [pscustomobject]@{
                    Available = $true
                    Enabled   = $enabled
                    Source    = ('{0} (CIM)' -f $className)
                    Error     = $null
                }
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Available = $false
        Enabled   = $null
        Source    = 'Unavailable'
        Error     = $lastError
    }
}

function Get-TpmStatus {
    $lastError = $null

    if ($null -ne (Get-Command -Name 'Get-Tpm' -ErrorAction SilentlyContinue)) {
        try {
            $status = Get-Tpm -ErrorAction Stop
            if ($status -is [string] -or
                $null -eq $status.PSObject.Properties['TpmPresent']) {
                throw 'Get-Tpm did not return a TPM status object.'
            }

            return [pscustomobject]@{
                Status = $status
                Source = 'Get-Tpm'
                Error  = $null
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    try {
        return [pscustomobject]@{
            Status = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName 'Win32_Tpm' -ErrorAction Stop | Select-Object -First 1
            Source = 'Win32_Tpm (CIM)'
            Error  = $null
        }
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($lastError)) {
            $lastError = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Status = $null
        Source = 'Unavailable'
        Error  = $lastError
    }
}

function ConvertTo-BitLockerProtectionStatus {
    param([object]$Value)

    if ($null -eq $Value) {
        return 'Unknown'
    }

    $text = ([string]$Value).Trim()
    if ($text -match '^(1|On|Protected)$') {
        return 'On'
    }

    if ($text -match '^(0|Off|Unprotected)$') {
        return 'Off'
    }

    return 'Unknown'
}

function ConvertTo-BitLockerVolumeStatus {
    param([object]$Value)

    if ($null -eq $Value) {
        return 'Unknown'
    }

    $text = ([string]$Value).Trim()
    if ($text -match '^(0|FullyDecrypted)$') {
        return 'FullyDecrypted'
    }

    if ($text -match '^(1|FullyEncrypted)$') {
        return 'FullyEncrypted'
    }

    if ($text -match '^(2|EncryptionInProgress)$') {
        return 'EncryptionInProgress'
    }

    if ($text -match '^(3|DecryptionInProgress)$') {
        return 'DecryptionInProgress'
    }

    return $text
}

function Get-BitLockerVolumes {
    $lastError = $null

    if ($null -ne (Get-Command -Name 'Get-BitLockerVolume' -ErrorAction SilentlyContinue)) {
        try {
            return [pscustomobject]@{
                Volumes = @(Get-BitLockerVolume -ErrorAction Stop | ForEach-Object {
                        [pscustomobject]@{
                            MountPoint       = ConvertTo-SafeText -Value ($_.MountPoint -join ', ')
                            ProtectionStatus = ConvertTo-BitLockerProtectionStatus -Value $_.ProtectionStatus
                            VolumeStatus     = ConvertTo-BitLockerVolumeStatus -Value $_.VolumeStatus
                            Source           = 'Get-BitLockerVolume'
                        }
                    })
                Error   = $null
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    try {
        $cimVolumes = @(Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName 'Win32_EncryptableVolume' -ErrorAction Stop)
        $volumes = New-Object System.Collections.Generic.List[object]
        foreach ($volume in $cimVolumes) {
            $protection = Invoke-CimMethod -InputObject $volume -MethodName 'GetProtectionStatus' -ErrorAction Stop
            $conversion = Invoke-CimMethod -InputObject $volume -MethodName 'GetConversionStatus' -ErrorAction Stop
            $volumes.Add([pscustomobject]@{
                    MountPoint       = ConvertTo-SafeText -Value $volume.DeviceID
                    ProtectionStatus = ConvertTo-BitLockerProtectionStatus -Value $protection.ProtectionStatus
                    VolumeStatus     = ConvertTo-BitLockerVolumeStatus -Value $conversion.ConversionStatus
                    Source           = 'Win32_EncryptableVolume (CIM)'
                })
        }

        return [pscustomobject]@{
            Volumes = @($volumes.ToArray())
            Error   = $null
        }
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($lastError)) {
            $lastError = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Volumes = @()
        Error   = $lastError
    }
}

Write-Host 'Windows Diagnostics Toolkit - Security Posture'
Write-Host 'Mode: read-only'

Write-Section 'Defender'
$defender = Get-DefenderStatus
if ($null -eq $defender.Status) {
    Write-Host 'Unavailable'
    Write-WdtFinding -Severity WARN -Code 'SECURITY_DEFENDER_UNAVAILABLE' -Message 'Microsoft Defender status is unavailable.' -Evidence $defender.Error
}
else {
    $defenderFields = @(
        [pscustomobject]@{ Label = 'Antivirus enabled'; Names = @('AntivirusEnabled') },
        [pscustomobject]@{ Label = 'Real-time protection'; Names = @('RealTimeProtectionEnabled') },
        [pscustomobject]@{ Label = 'Service enabled'; Names = @('AMServiceEnabled') },
        [pscustomobject]@{ Label = 'Antispyware enabled'; Names = @('AntispywareEnabled') },
        [pscustomobject]@{ Label = 'Network inspection'; Names = @('NISEnabled') }
    )

    Write-Host ('Source              : {0}' -f $defender.Source)
    $disabledFields = New-Object System.Collections.Generic.List[string]
    foreach ($field in $defenderFields) {
        $value = Get-ObjectPropertyValue -InputObject $defender.Status -Names $field.Names
        Write-Host ('{0,-20}: {1}' -f $field.Label, (ConvertTo-BooleanDisplay -Value $value))
        if ((ConvertTo-BooleanOrNull -Value $value) -eq $false) {
            $disabledFields.Add($field.Label)
        }
    }

    if ($disabledFields.Count -gt 0) {
        Write-WdtFinding -Severity WARN -Code 'SECURITY_DEFENDER_DISABLED' -Message 'One or more Microsoft Defender protection components are disabled.' -Evidence ($disabledFields -join ', ')
    }
}

Write-Section 'Firewall Profiles'
$firewall = Get-FirewallProfiles
if ($null -ne $firewall.Error -or $firewall.Profiles.Count -eq 0) {
    Write-Host 'Unavailable'
    Write-WdtFinding -Severity WARN -Code 'SECURITY_FIREWALL_UNAVAILABLE' -Message 'Firewall profile status is unavailable.' -Evidence $firewall.Error
}
else {
    $disabledProfiles = New-Object System.Collections.Generic.List[string]
    foreach ($profile in $firewall.Profiles) {
        Write-Host ('{0,-20}: {1} ({2})' -f (ConvertTo-SafeText -Value $profile.Name), (ConvertTo-BooleanDisplay -Value $profile.Enabled), $profile.Source)
        if ((ConvertTo-BooleanOrNull -Value $profile.Enabled) -eq $false) {
            $disabledProfiles.Add((ConvertTo-SafeText -Value $profile.Name))
        }
    }

    if ($disabledProfiles.Count -gt 0) {
        Write-WdtFinding -Severity WARN -Code 'SECURITY_FIREWALL_PROFILE_DISABLED' -Message 'One or more Windows Firewall profiles are disabled.' -Evidence ($disabledProfiles -join ', ')
    }
}

Write-Section 'Secure Boot'
$secureBoot = Get-SecureBootStatus
if (-not $secureBoot.Available) {
    Write-Host 'Unavailable'
    Write-WdtFinding -Severity WARN -Code 'SECURITY_SECURE_BOOT_UNAVAILABLE' -Message 'Secure Boot status is unavailable.' -Evidence $secureBoot.Error
}
else {
    Write-Host ('Source  : {0}' -f $secureBoot.Source)
    Write-Host ('Enabled : {0}' -f (ConvertTo-BooleanDisplay -Value $secureBoot.Enabled))
    if ($secureBoot.Enabled -eq $false) {
        Write-WdtFinding -Severity WARN -Code 'SECURITY_SECURE_BOOT_DISABLED' -Message 'Secure Boot is disabled.' -Evidence $secureBoot.Source
    }
}

Write-Section 'TPM'
$tpm = Get-TpmStatus
if ($null -eq $tpm.Status) {
    Write-Host 'Unavailable'
    Write-WdtFinding -Severity WARN -Code 'SECURITY_TPM_UNAVAILABLE' -Message 'TPM status is unavailable.' -Evidence $tpm.Error
}
else {
    $tpmPresent = Get-ObjectPropertyValue -InputObject $tpm.Status -Names @('TpmPresent', 'IsEnabled_InitialValue')
    $tpmReady = Get-ObjectPropertyValue -InputObject $tpm.Status -Names @('TpmReady', 'IsActivated_InitialValue')
    $tpmEnabled = Get-ObjectPropertyValue -InputObject $tpm.Status -Names @('TpmEnabled', 'IsEnabled_InitialValue')
    Write-Host ('Source    : {0}' -f $tpm.Source)
    Write-Host ('Present   : {0}' -f (ConvertTo-BooleanDisplay -Value $tpmPresent))
    Write-Host ('Ready     : {0}' -f (ConvertTo-BooleanDisplay -Value $tpmReady))
    Write-Host ('Enabled   : {0}' -f (ConvertTo-BooleanDisplay -Value $tpmEnabled))

    if ((ConvertTo-BooleanOrNull -Value $tpmPresent) -eq $false -or
        (ConvertTo-BooleanOrNull -Value $tpmReady) -eq $false -or
        (ConvertTo-BooleanOrNull -Value $tpmEnabled) -eq $false) {
        Write-WdtFinding -Severity WARN -Code 'SECURITY_TPM_NOT_READY' -Message 'TPM is not present, enabled, or ready.' -Evidence $tpm.Source
    }
}

Write-Section 'BitLocker'
$bitLocker = Get-BitLockerVolumes
if ($null -ne $bitLocker.Error -or $bitLocker.Volumes.Count -eq 0) {
    Write-Host 'Unavailable'
    Write-WdtFinding -Severity WARN -Code 'SECURITY_BITLOCKER_UNAVAILABLE' -Message 'BitLocker volume status is unavailable.' -Evidence $bitLocker.Error
}
else {
    $unprotectedVolumes = New-Object System.Collections.Generic.List[string]
    foreach ($volume in $bitLocker.Volumes) {
        Write-Host ('Volume            : {0}' -f $volume.MountPoint)
        Write-Host ('Protection status : {0}' -f $volume.ProtectionStatus)
        Write-Host ('Volume status     : {0}' -f $volume.VolumeStatus)
        Write-Host ('Source            : {0}' -f $volume.Source)
        Write-Host ''

        if ($volume.ProtectionStatus -eq 'Off') {
            $unprotectedVolumes.Add($volume.MountPoint)
        }
    }

    if ($unprotectedVolumes.Count -gt 0) {
        Write-WdtFinding -Severity WARN -Code 'SECURITY_BITLOCKER_NOT_PROTECTED' -Message 'One or more BitLocker volumes are not protected.' -Evidence ($unprotectedVolumes -join ', ')
    }
}
