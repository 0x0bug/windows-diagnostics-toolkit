function Test-IdentityFieldLeak {
    param([string]$Text, [string]$ComputerName, [string]$UserName)

    $fieldPatterns = @(
        @{ Pattern = '(?im)^\s*(?:-\s*)?(?:Computer name|Computer Name|Host Name|Machine Name|System Name|Host|Computer)\s*[:=]\s*(?<Value>[^;\r\n]*)'; Identity = $ComputerName; IsHost = $true },
        @{ Pattern = '(?im)^\s*(?:-\s*)?(?:InstalledBy|UserName|RunAs|Owner|Account|User)\s*[:=]\s*(?<Value>[^;\r\n]*)'; Identity = $UserName; IsHost = $false }
    )
    foreach ($field in $fieldPatterns) {
        if ([string]::IsNullOrWhiteSpace($field.Identity)) { continue }
        foreach ($match in [regex]::Matches($Text, $field.Pattern)) {
            $value = $match.Groups['Value'].Value.Trim().Trim('`', '"', "'")
            if ($value.Equals($field.Identity, [System.StringComparison]::OrdinalIgnoreCase) -or
                $value.EndsWith(('\' + $field.Identity), [System.StringComparison]::OrdinalIgnoreCase) -or
                ($field.IsHost -and $value.StartsWith(($field.Identity + '.'), [System.StringComparison]::OrdinalIgnoreCase))) {
                return $true
            }
        }
    }
    return $false
}
