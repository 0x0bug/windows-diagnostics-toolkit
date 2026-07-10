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
    $allowed = @("`$PSScriptRoot\validation-policy.ps1", "`$PSScriptRoot\report-common.ps1", "`$PSScriptRoot\scripts\report-common.ps1")
    if ($text -notin $allowed) { return $false }
    $scriptsPath = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'scripts'))
    $scriptDirectory = [System.IO.Path]::GetFullPath((Split-Path -Parent $ScriptPath))
    return ($text -eq "`$PSScriptRoot\validation-policy.ps1" -and (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\validate.ps1')) -or
        ($text -eq "`$PSScriptRoot\report-common.ps1" -and [string]::Equals($scriptDirectory, $scriptsPath, [System.StringComparison]::OrdinalIgnoreCase)) -or
        ($text -eq "`$PSScriptRoot\scripts\report-common.ps1" -and (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot))
}

function Test-WdtAllowedNewItemCommand {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot)
    if (-not (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot)) { return $false }
    $elements = @($CommandAst.CommandElements)
    $text = $CommandAst.Extent.Text
    return $text -match '(?i)-ItemType\s+Directory' -and $text -match '(?i)-Path\s+\$resolvedOutputDirectory' -and $text -match '(?i)-Force'
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
    if ($CommandAst.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and $leaf -notmatch '(?i)^(w32tm|netsh)\.exe$') { return New-WdtSafetyIssue $CommandAst 'Dynamic command invocation is not allowed in production scripts.' }
    $extension = [IO.Path]::GetExtension($leaf)
    $resolved = Get-Command -Name $leaf -ErrorAction SilentlyContinue | Select-Object -First 1
    $name = if ($resolved -and $resolved.CommandType -eq 'Alias') { $resolved.ResolvedCommandName } else { $leaf }
    if ($name -in @('New-Alias', 'Set-Alias')) { return New-WdtSafetyIssue $CommandAst 'Alias creation is not permitted.' }
    if ($name -eq 'Invoke-CimMethod') {
        if (Test-WdtAllowedBitLockerCimQuery $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'Invoke-CimMethod is only allowed for approved read-only BitLocker status queries.'
    }
    $forbidden = @('Add-Type','Invoke-Command','Enter-PSSession','New-PSSession','Register-PSSessionConfiguration','Set-PSSessionConfiguration','Remove-PSSession','Start-Job','Start-ThreadJob','Register-ScheduledJob','Register-ObjectEvent','Register-WmiEvent','Invoke-WmiMethod','Set-WmiInstance','Remove-WmiObject','Invoke-Expression','Invoke-WebRequest','Invoke-RestMethod','Start-Process','Start-Service','Stop-Service','Restart-Service','Set-Service','New-Service','Remove-Service','Set-ItemProperty','New-ItemProperty','Remove-ItemProperty','Remove-Item','Clear-EventLog')
    if ($name -in $forbidden -or $name -like 'Install-*' -or $name -like 'Update-*' -or $name -like 'Reset-*' -or $name -like 'Enable-*' -or $name -like 'Disable-*' -or $name -like 'Clear-*') { return New-WdtSafetyIssue $CommandAst ("{0} is not permitted." -f $name) }
    if ($name -eq 'New-Object') {
        if ($CommandAst.Extent.Text -match '(?i)-(ComObject|TypeName)\s+(\$|\()') { return New-WdtSafetyIssue $CommandAst 'Dynamic COM object or type creation is not permitted.' }
        if ($CommandAst.Extent.Text -match '(?i)-ComObject') { return New-WdtSafetyIssue $CommandAst 'COM object creation is not permitted.' }
    }
    if ($name -eq 'New-Item' -and -not (Test-WdtAllowedNewItemCommand $CommandAst $ScriptPath $RepositoryRoot)) { return New-WdtSafetyIssue $CommandAst 'New-Item is only allowed in Invoke-WindowsDiagnostics.ps1 for -OutputDirectory creation.' }
    $isNative = $extension -in @('.exe','.com','.cmd','.bat') -or ($resolved -and $resolved.CommandType -eq 'Application')
    if ($isNative) {
        $nativeName = $leaf.ToLowerInvariant()
        if ($nativeName -eq 'w32tm.exe' -and (Test-WdtAllowedW32tmCommand $CommandAst)) { return }
        if ($nativeName -eq 'netsh.exe' -and (Test-WdtAllowedNetshCommand $CommandAst)) { return }
        if ($nativeName -in @('w32tm.exe','netsh.exe')) { return New-WdtSafetyIssue $CommandAst 'Native executable arguments are not an allowed read-only form.' }
        return New-WdtSafetyIssue $CommandAst 'Native executable is not in the read-only allowlist.'
    }
    if (-not $resolved -and $leaf -notin $LocalFunctionNames) { return New-WdtSafetyIssue $CommandAst 'Unresolved command is not allowed in production scripts.' }
}

function Get-WdtMemberSafetyIssue {
    param($MemberAst, [string]$ScriptPath, [string]$RepositoryRoot)
    $member = [string]$MemberAst.Member.Value
    $argumentCount = $MemberAst.Arguments.Count
    $isStatic = $MemberAst.Expression -is [System.Management.Automation.Language.TypeExpressionAst]
    if ($isStatic) {
        $typeName = $MemberAst.Expression.TypeName.FullName
        if ($typeName -eq 'System.IO.File' -and $member -eq 'WriteAllLines' -and (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot) -and $argumentCount -eq 3) {
            $pathVariable = if ($MemberAst.Arguments[0] -is [System.Management.Automation.Language.VariableExpressionAst]) { $MemberAst.Arguments[0].VariablePath.UserPath } else { '' }
            $linesVariable = if ($MemberAst.Arguments[1] -is [System.Management.Automation.Language.VariableExpressionAst]) { $MemberAst.Arguments[1].VariablePath.UserPath } else { '' }
            $isReportPair = ($pathVariable -ceq 'textReportPath' -and $linesVariable -ceq 'textLines') -or
                ($pathVariable -ceq 'markdownReportPath' -and $linesVariable -ceq 'markdownLines')
            if ($isReportPair -and $MemberAst.Arguments[2].Extent.Text -ceq '[System.Text.Encoding]::UTF8') { return }
        }
        if (($typeName -in @('Microsoft.Win32.Registry','Microsoft.Win32.RegistryKey','System.IO.File','IO.File','System.IO.Directory','IO.Directory','System.Diagnostics.Process','Diagnostics.Process','System.Reflection.Assembly','Reflection.Assembly','System.Activator','Activator','System.Runtime.InteropServices.Marshal','System.Environment','Environment','System.GC','GC','System.Type','type')) -and $member -in @('SetValue','OpenBaseKey','Delete','WriteAllText','AppendAllText','CreateDirectory','Start','Load','LoadFrom','LoadFile','LoadWithPartialName','CreateInstance','GetActiveObject','BindToMoniker','SetEnvironmentVariable','Collect','InvokeMember','GetType','WriteAllLines','Move','Copy','Replace')) { return New-WdtSafetyIssue $MemberAst 'Static method can mutate system state or load dynamic code.' }
        return
    }
    $receiver = if ($MemberAst.Expression -is [System.Management.Automation.Language.VariableExpressionAst]) { $MemberAst.Expression.VariablePath.UserPath } else { '' }
    if ($member -eq 'Start' -and $receiver -ceq 'process' -and $argumentCount -eq 0 -and (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Invoke-DiagnosticScript' -and (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot)) { return }
    if ($member -in @('Delete','Remove','Put','SetValue','Create','CreateInstance','InvokeMethod','CopyTo','MoveTo','Start','Stop','Kill','CloseMainWindow','RegisterTaskDefinition','Write','WriteLine','DownloadFile','UploadFile','InvokeMember')) { return New-WdtSafetyIssue $MemberAst 'Instance method can mutate system state.' }
}

function Get-WdtSafetyIssues {
    param([Parameter(Mandatory = $true)]$Ast, [Parameter(Mandatory = $true)][string]$ScriptPath, [Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $localFunctionNames = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    $approvedImports = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object { Test-WdtAllowedDotSource $_ $ScriptPath $RepositoryRoot })
    foreach ($import in $approvedImports) {
        $helperPath = if ($import.CommandElements[0].Extent.Text -like '*validation-policy.ps1') {
            Join-Path $RepositoryRoot 'scripts\validation-policy.ps1'
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
}
