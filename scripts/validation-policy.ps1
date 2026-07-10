[CmdletBinding()]
param()

function Test-WdtAllowedW32tmCommand {
    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$CommandAst)

    if ((Split-Path -Leaf ($CommandAst.GetCommandName() -replace '/', '\\')) -ine 'w32tm.exe') { return $false }
    $elements = @($CommandAst.CommandElements)
    if ($elements.Count -notin @(3, 4)) { return $false }
    foreach ($element in @($elements | Select-Object -Skip 1)) {
        if ($element -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
    }

    return ($elements.Count -eq 3 -and $elements[1].Value -eq '/query' -and $elements[2].Value -eq '/source') -or
        ($elements.Count -eq 4 -and $elements[1].Value -eq '/query' -and $elements[2].Value -eq '/status' -and $elements[3].Value -eq '/verbose')
}

function Test-WdtAllowedNetshCommand {
    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$CommandAst)

    if ((Split-Path -Leaf ($CommandAst.GetCommandName() -replace '/', '\\')) -ine 'netsh.exe') { return $false }
    $elements = @($CommandAst.CommandElements)
    if ($elements.Count -ne 4) { return $false }
    foreach ($element in @($elements | Select-Object -Skip 1)) {
        if ($element -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
    }

    return $elements[1].Value -eq 'winhttp' -and $elements[2].Value -eq 'show' -and $elements[3].Value -eq 'proxy'
}

function New-WdtSafetyIssue {
    param($Ast, [string]$Message)
    [pscustomobject]@{ Type = 'Safety'; Line = $Ast.Extent.StartLineNumber; Column = $Ast.Extent.StartColumnNumber; Command = $Ast.Extent.Text; Message = $Message }
}

function Test-WdtEntrypointPath {
    param([string]$ScriptPath, [string]$RepositoryRoot)
    return [string]::Equals([IO.Path]::GetFullPath($ScriptPath), [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'Invoke-WindowsDiagnostics.ps1')), [StringComparison]::OrdinalIgnoreCase)
}

function Test-WdtAllowedDotSource {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot)
    if ($CommandAst.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Dot -or $CommandAst.CommandElements.Count -ne 1) { return $false }
    $text = $CommandAst.CommandElements[0].Extent.Text
    $allowed = @("`$PSScriptRoot\validation-policy.ps1", "`$PSScriptRoot\report-common.ps1", "`$PSScriptRoot\scripts\report-common.ps1", "`$PSScriptRoot\scripts\tui.ps1")
    if ($text -notin $allowed) { return $false }
    $scriptsPath = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'scripts'))
    $scriptDirectory = [System.IO.Path]::GetFullPath((Split-Path -Parent $ScriptPath))
    return ($text -eq "`$PSScriptRoot\validation-policy.ps1" -and (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\validate.ps1')) -or
        ($text -eq "`$PSScriptRoot\report-common.ps1" -and [string]::Equals($scriptDirectory, $scriptsPath, [System.StringComparison]::OrdinalIgnoreCase)) -or
        ($text -eq "`$PSScriptRoot\scripts\report-common.ps1" -and (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot)) -or
        ($text -eq "`$PSScriptRoot\scripts\tui.ps1" -and (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot))
}

function Test-WdtAllowedNewItemCommand {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot)
    if (-not (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot)) { return $false }
    if ($CommandAst.Redirections.Count -ne 0) { return $false }

    $elements = @($CommandAst.CommandElements)
    $parameters = @{}
    for ($index = 1; $index -lt $elements.Count; $index++) {
        if ($elements[$index] -isnot [System.Management.Automation.Language.CommandParameterAst]) { return $false }

        $parameter = $elements[$index]
        $name = $parameter.ParameterName
        if ($name -notin @('ItemType', 'Path', 'Force') -or $parameters.ContainsKey($name)) { return $false }
        if ($name -eq 'Force') {
            if ($parameter.ArgumentName) { return $false }
            $parameters[$name] = $true
            continue
        }

        if ($index + 1 -ge $elements.Count) { return $false }
        $parameters[$name] = $elements[$index + 1]
        $index++
    }

    if ($parameters.Count -ne 3 -or -not $parameters.ContainsKey('ItemType') -or -not $parameters.ContainsKey('Path') -or -not $parameters.ContainsKey('Force')) { return $false }
    return $parameters['ItemType'] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $parameters['ItemType'].Value -ceq 'Directory' -and
        (Test-WdtSimpleVariable $parameters['Path'] 'resolvedOutputDirectory')
}

function Test-WdtScriptPath {
    param(
        [string]$ScriptPath,
        [string]$RepositoryRoot,
        [string]$RelativePath
    )

    $expectedPath = [System.IO.Path]::GetFullPath((Join-Path -Path $RepositoryRoot -ChildPath $RelativePath))
    $actualPath = [System.IO.Path]::GetFullPath($ScriptPath)
    return [string]::Equals($actualPath, $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-WdtEnclosingFunctionName {
    param([System.Management.Automation.Language.Ast]$Ast)

    $current = $Ast.Parent
    while ($null -ne $current) {
        if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $current.Name
        }

        $current = $current.Parent
    }

    return $null
}

function Test-WdtSimpleVariable {
    param($Ast, [string]$Name)

    return $Ast -is [System.Management.Automation.Language.VariableExpressionAst] -and
        -not $Ast.Splatted -and
        $Ast.VariablePath.UserPath -ceq $Name
}

function Test-WdtAllowedInternalCallbackInvocation {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot)

    if (-not (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\report-common.ps1')) { return $false }
    if ($CommandAst.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Ampersand) { return $false }
    if ((Get-WdtEnclosingFunctionName $CommandAst) -cne 'Protect-WdtRegexMatches') { return $false }
    if ($CommandAst.Redirections.Count -ne 0) { return $false }

    $elements = @($CommandAst.CommandElements)
    if ($elements.Count -eq 4 -and
        (Test-WdtSimpleVariable $elements[0] 'Validator') -and
        (Test-WdtSimpleVariable $elements[1] 'value') -and
        (Test-WdtSimpleVariable $elements[2] 'valueMatch') -and
        (Test-WdtSimpleVariable $elements[3] 'Text')) {
        return $true
    }

    return $elements.Count -eq 2 -and
        (Test-WdtSimpleVariable $elements[0] 'TokenValueSelector') -and
        (Test-WdtSimpleVariable $elements[1] 'value')
}

function Test-WdtAllowedBitLockerCimQuery {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot)

    if (-not (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\security-posture.ps1')) { return $false }
    if ($CommandAst.GetCommandName() -ine 'Invoke-CimMethod') { return $false }
    if ($CommandAst.Redirections.Count -ne 0) { return $false }

    $elements = @($CommandAst.CommandElements)
    $parameters = @{}
    for ($index = 1; $index -lt $elements.Count; $index += 2) {
        if ($elements[$index] -isnot [System.Management.Automation.Language.CommandParameterAst] -or $index + 1 -ge $elements.Count) {
            return $false
        }

        $parameterName = $elements[$index].ParameterName
        if ($parameterName -notin @('InputObject', 'MethodName', 'ErrorAction') -or $parameters.ContainsKey($parameterName)) {
            return $false
        }

        $parameters[$parameterName] = $elements[$index + 1]
    }

    if ($parameters.Count -lt 2 -or -not $parameters.ContainsKey('InputObject') -or -not $parameters.ContainsKey('MethodName')) { return $false }
    if (-not (Test-WdtSimpleVariable $parameters['InputObject'] 'volume')) { return $false }
    if ($parameters['MethodName'] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
    if ($parameters['MethodName'].Value -notin @('GetProtectionStatus', 'GetConversionStatus')) { return $false }
    if ($parameters.ContainsKey('ErrorAction')) {
        if ($parameters['ErrorAction'] -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or $parameters['ErrorAction'].Value -ine 'Stop') { return $false }
    }

    return $true
}

function Test-WdtAllowedNativeRedirection {
    param($CommandAst)

    if ($CommandAst.Redirections.Count -eq 0) { return $true }
    if ($CommandAst.Redirections.Count -ne 1) { return $false }

    $redirection = $CommandAst.Redirections[0]
    return $redirection -is [System.Management.Automation.Language.MergingRedirectionAst] -and
        $redirection.FromStream -eq [System.Management.Automation.Language.RedirectionStream]::Error -and
        $redirection.ToStream -eq [System.Management.Automation.Language.RedirectionStream]::Output
}

function Get-WdtNewObjectTypeName {
    param($CommandAst)

    $elements = @($CommandAst.CommandElements)
    if ($elements.Count -lt 2) { return $null }
    if ($elements[1] -is [System.Management.Automation.Language.CommandParameterAst]) {
        if ($elements[1].ParameterName -ine 'TypeName' -or $elements.Count -lt 3) { return $null }
        $typeElement = $elements[2]
    }
    else {
        $typeElement = $elements[1]
    }

    if ($typeElement -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
    return $typeElement.Value
}

function Test-WdtAllowedNewObjectCommand {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot)

    if ($CommandAst.Redirections.Count -ne 0) { return $false }
    $elements = @($CommandAst.CommandElements)
    $hasPositionalTypeName = $elements.Count -gt 1 -and $elements[1] -isnot [System.Management.Automation.Language.CommandParameterAst]
    $seenParameters = @{}
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) { return $false }
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }

        $parameterName = $element.ParameterName
        if ($parameterName -notin @('TypeName', 'ArgumentList') -or $seenParameters.ContainsKey($parameterName)) { return $false }
        if ($hasPositionalTypeName -and $parameterName -eq 'TypeName') { return $false }
        $seenParameters[$parameterName] = $true
        if ($index + 1 -ge $elements.Count) { return $false }
        if ($parameterName -eq 'TypeName' -and $elements[$index + 1] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
        $index++
    }

    $typeName = Get-WdtNewObjectTypeName $CommandAst
    if ([string]::IsNullOrWhiteSpace($typeName)) { return $false }

    $safeTypes = @(
        'System.Uri',
        'System.Text.UTF8Encoding',
        'System.Collections.Hashtable',
        'System.Text.StringBuilder',
        'System.Text.RegularExpressions.Regex',
        'System.Collections.Generic.List[object]',
        'System.Collections.Generic.List[string]',
        'System.Collections.Generic.List[System.IO.FileInfo]',
        'System.Collections.Generic.Queue[System.IO.DirectoryInfo]'
    )
    if ($typeName -in $safeTypes) { return $true }

    if ($typeName -in @('System.Diagnostics.ProcessStartInfo', 'System.Diagnostics.Process') -and
        (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot) -and
        (Get-WdtEnclosingFunctionName $CommandAst) -ceq 'Invoke-DiagnosticScript' -and
        $CommandAst.CommandElements.Count -eq 2) {
        return $true
    }

    return $false
}

function Test-WdtAllowedPowerShellCommand {
    param([string]$CommandName)

    return $CommandName -in @(
        'Add-Member',
        'Confirm-SecureBootUEFI',
        'Clear-Host',
        'ConvertFrom-Json',
        'ConvertTo-Json',
        'ForEach-Object',
        'Get-BitLockerVolume',
        'Get-ChildItem',
        'Get-CimInstance',
        'Get-Command',
        'Get-Date',
        'Get-DnsClient',
        'Get-DnsClientGlobalSetting',
        'Get-HotFix',
        'Get-Item',
        'Get-ItemProperty',
        'Get-Location',
        'Get-MpComputerStatus',
        'Get-NetAdapter',
        'Get-NetFirewallProfile',
        'Get-NetIPConfiguration',
        'Get-NetIPInterface',
        'Get-NetRoute',
        'Get-PhysicalDisk',
        'Get-Process',
        'Get-ScheduledTask',
        'Get-ScheduledTaskInfo',
        'Get-TimeZone',
        'Get-Tpm',
        'Get-Volume',
        'Get-WinEvent',
        'Group-Object',
        'Join-Path',
        'Measure-Object',
        'Out-Null',
        'Resolve-DnsName',
        'Read-Host',
        'Select-Object',
        'Sort-Object',
        'Split-Path',
        'Start-Sleep',
        'Test-Connection',
        'Test-Path',
        'Where-Object',
        'Write-Host',
        'Write-Output',
        'Write-Warning'
    )
}

function Test-WdtAllowedTuiReportInvocation {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot)

    if (-not (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\tui.ps1')) { return $false }
    if ($CommandAst.GetCommandName() -ine 'Invoke-WdtReport') { return $false }
    if ((Get-WdtEnclosingFunctionName $CommandAst) -cne 'Invoke-WdtInteractiveSession') { return $false }
    if ($CommandAst.Redirections.Count -ne 0 -or $CommandAst.CommandElements.Count -ne 2) { return $false }

    $argument = $CommandAst.CommandElements[1]
    return $argument -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $argument.Splatted -and
        $argument.VariablePath.UserPath -ceq 'reportParameters'
}

function Get-WdtCommandSafetyIssue {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot, [string[]]$LocalFunctionNames)
    if ($CommandAst.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) {
        if (-not (Test-WdtAllowedDotSource $CommandAst $ScriptPath $RepositoryRoot)) { return New-WdtSafetyIssue $CommandAst 'Dot-sourced script is not an approved repository helper.' }
        return
    }
    $rawName = $CommandAst.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($rawName)) {
        if (Test-WdtAllowedInternalCallbackInvocation $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'Dynamic command invocation is not allowed in production scripts. Only approved internal callbacks are permitted.'
    }

    $leaf = Split-Path -Leaf ($rawName -replace '/', '\\')
    if ($CommandAst.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and $leaf -notin @('w32tm.exe', 'netsh.exe')) { return New-WdtSafetyIssue $CommandAst 'Dynamic command invocation is not allowed in production scripts.' }

    if ($leaf -eq 'Invoke-CimMethod') {
        if (Test-WdtAllowedBitLockerCimQuery $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'Invoke-CimMethod is only allowed for approved read-only BitLocker status queries.'
    }

    if ($leaf -eq 'Invoke-WdtReport') {
        if ($leaf -in $LocalFunctionNames) { return }
        if (Test-WdtAllowedTuiReportInvocation $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'The report runner is only callable from the approved interactive session.'
    }

    if ($leaf -eq 'New-Item') {
        if (Test-WdtAllowedNewItemCommand $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'New-Item is only allowed in Invoke-WindowsDiagnostics.ps1 for -OutputDirectory creation.'
    }

    if ($leaf -eq 'New-Object') {
        if (Test-WdtAllowedNewObjectCommand $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'New-Object type is not in the reviewed safe-type allowlist.'
    }

    if ($leaf -in @('w32tm.exe', 'netsh.exe')) {
        if (-not (Test-WdtAllowedNativeRedirection $CommandAst)) { return New-WdtSafetyIssue $CommandAst 'PowerShell redirection is not permitted in production scripts.' }
        if ($leaf -eq 'w32tm.exe' -and (Test-WdtAllowedW32tmCommand $CommandAst)) { return }
        if ($leaf -eq 'netsh.exe' -and (Test-WdtAllowedNetshCommand $CommandAst)) { return }
        return New-WdtSafetyIssue $CommandAst 'Native executable arguments are not an allowed read-only form.'
    }

    if ($leaf -in @('cmd', 'powershell', 'pwsh', 'rundll32', 'regsvr32', 'schtasks', 'fsutil', 'diskpart', 'wmic', 'sc', 'reg', 'bcdedit', 'powercfg', 'netsh', 'w32tm')) {
        return New-WdtSafetyIssue $CommandAst 'Native executable is not in the read-only allowlist.'
    }

    if ($CommandAst.Redirections.Count -ne 0) {
        return New-WdtSafetyIssue $CommandAst 'PowerShell redirection is not permitted in production scripts.'
    }

    if ($leaf -in $LocalFunctionNames) { return }
    if (Test-WdtAllowedPowerShellCommand $leaf) { return }

    if ([System.IO.Path]::GetExtension($leaf) -in @('.exe', '.com', '.cmd', '.bat')) {
        return New-WdtSafetyIssue $CommandAst 'Native executable is not in the read-only allowlist.'
    }

    return New-WdtSafetyIssue $CommandAst 'PowerShell command is not in the reviewed read-only allowlist.'
}

function Get-WdtMemberSafetyIssue {
    param($MemberAst, [string]$ScriptPath, [string]$RepositoryRoot)
    $member = [string]$MemberAst.Member.Value
    $argumentCount = $MemberAst.Arguments.Count
    $isStatic = $MemberAst.Expression -is [System.Management.Automation.Language.TypeExpressionAst]
    if ($isStatic) {
        $typeName = $MemberAst.Expression.TypeName.FullName
        if ($typeName -eq 'System.Console' -and $member -eq 'ReadKey' -and
            (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\tui.ps1') -and
            $argumentCount -eq 1 -and $MemberAst.Arguments[0].Extent.Text -ceq '$true') {
            return
        }
        if ($typeName -eq 'System.IO.File' -and $member -eq 'WriteAllLines' -and (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot) -and $argumentCount -eq 3) {
            $pathVariable = if ($MemberAst.Arguments[0] -is [System.Management.Automation.Language.VariableExpressionAst]) { $MemberAst.Arguments[0].VariablePath.UserPath } else { '' }
            $linesVariable = if ($MemberAst.Arguments[1] -is [System.Management.Automation.Language.VariableExpressionAst]) { $MemberAst.Arguments[1].VariablePath.UserPath } else { '' }
            $isReportPair = ($pathVariable -ceq 'textReportPath' -and $linesVariable -ceq 'textLines') -or
                ($pathVariable -ceq 'markdownReportPath' -and $linesVariable -ceq 'markdownLines')
            if ($isReportPair -and $MemberAst.Arguments[2].Extent.Text -ceq '[System.Text.Encoding]::UTF8') { return }
        }

        $safeStaticMethods = @(
            'IO.Path::GetExtension',
            'IO.Path::GetFullPath',
            'Management.ManagementDateTimeConverter::ToDateTime',
            'Math::Max',
            'string::Equals',
            'string::IsNullOrEmpty',
            'string::IsNullOrWhiteSpace',
            'System.Diagnostics.Process::GetCurrentProcess',
            'System.Guid::TryParse',
            'System.IO.Path::GetExtension',
            'System.IO.Path::GetFullPath',
            'System.Management.Automation.Language.Parser::ParseFile',
            'System.Net.Dns::GetHostAddresses',
            'System.Net.IPAddress::TryParse',
            'System.Text.RegularExpressions.Regex::Escape',
            'System.Text.RegularExpressions.Regex::Matches',
            'System.Text.RegularExpressions.Regex::Replace',
            'System.Uri::UnescapeDataString'
        )
        if (("{0}::{1}" -f $typeName, $member) -in $safeStaticMethods) { return }
        return New-WdtSafetyIssue $MemberAst 'Static method is not in the reviewed safe allowlist.'
    }

    $receiver = if ($MemberAst.Expression -is [System.Management.Automation.Language.VariableExpressionAst]) { $MemberAst.Expression.VariablePath.UserPath } else { '' }
    if ($member -eq 'Start' -and $receiver -ceq 'process' -and $argumentCount -eq 0 -and (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Invoke-DiagnosticScript' -and (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot)) { return }

    $safeInstanceMethods = @(
        'Add',
        'AddDays',
        'AddHours',
        'Append',
        'Contains',
        'ContainsKey',
        'Dequeue',
        'Enqueue',
        'Equals',
        'FindAll',
        'GetAddressBytes',
        'GetCommandName',
        'GetUnresolvedProviderPathFromPSPath',
        'IndexOf',
        'LastIndexOf',
        'MakeRelativeUri',
        'Matches',
        'ReadToEnd',
        'Replace',
        'StartsWith',
        'Substring',
        'ToArray',
        'ToLowerInvariant',
        'ToString',
        'ToUpperInvariant',
        'Trim',
        'TrimEnd',
        'WaitForExit'
    )
    if ($member -in $safeInstanceMethods) { return }
    return New-WdtSafetyIssue $MemberAst 'Instance method is not in the reviewed safe allowlist.'
}

function Get-WdtSafetyIssues {
    param([Parameter(Mandatory = $true)]$Ast, [Parameter(Mandatory = $true)][string]$ScriptPath, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $localFunctionNames = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    $approvedImports = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object { Test-WdtAllowedDotSource $_ $ScriptPath $RepositoryRoot })
    foreach ($import in $approvedImports) {
        $helperPath = if ($import.CommandElements[0].Extent.Text -like '*validation-policy.ps1') {
            Join-Path $RepositoryRoot 'scripts\validation-policy.ps1'
        }
        elseif ($import.CommandElements[0].Extent.Text -like '*tui.ps1') {
            Join-Path $RepositoryRoot 'scripts\tui.ps1'
        }
        else {
            Join-Path $RepositoryRoot 'scripts\report-common.ps1'
        }
        $helperTokens = $null
        $helperErrors = $null
        $helperAst = [System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$helperTokens, [ref]$helperErrors)
        if (@($helperErrors).Count -eq 0) {
            $localFunctionNames += @($helperAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        }
    }
    foreach ($command in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) { Get-WdtCommandSafetyIssue $command $ScriptPath $RepositoryRoot $localFunctionNames }
    foreach ($member in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) { Get-WdtMemberSafetyIssue $member $ScriptPath $RepositoryRoot }
    foreach ($variable in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -like 'function:*' }, $true))) {
        New-WdtSafetyIssue $variable 'Dynamic function provider access is not allowed in production scripts.'
    }
    foreach ($usingStatement in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.UsingStatementAst] -and $n.Extent.Text -match '(?i)^\s*using\s+module\b' }, $true))) {
        New-WdtSafetyIssue $usingStatement 'Module import is not permitted in production scripts.'
    }
    if ($null -ne $Ast.ScriptRequirements -and @($Ast.ScriptRequirements.RequiredModules).Count -gt 0) {
        New-WdtSafetyIssue $Ast 'Script module requirements are not permitted in production scripts.'
    }
}
