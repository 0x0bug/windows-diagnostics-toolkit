[CmdletBinding()]
param()

function Test-WdtAllowedNetshCommand {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot)

    $elements = @($CommandAst.CommandElements)
    if ($elements.Count -ne 4 -or -not (Test-WdtAllowedNativeRedirection $CommandAst)) { return $false }
    foreach ($element in @($elements | Select-Object -Skip 1)) {
        if ($element -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
    }
    if ($elements[1].Value -ne 'winhttp' -or $elements[2].Value -ne 'show' -or $elements[3].Value -ne 'proxy') { return $false }

    $rawName = $CommandAst.GetCommandName()
    if (-not [string]::IsNullOrWhiteSpace($rawName)) {
        return (Split-Path -Leaf ($rawName -replace '/', '\')) -ieq 'netsh.exe'
    }

    if ($CommandAst.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Ampersand -or
        -not (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'modules\network\diagnostic.ps1') -or
        (Get-WdtEnclosingFunctionName $CommandAst) -cne 'Get-WinHttpProxy') { return $false }

    $commandExpression = $elements[0]
    if ($commandExpression -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
        $commandExpression.VariablePath.UserPath -cne 'netshPath') { return $false }

    $functionAst = Get-WdtEnclosingFunctionAst -Ast $CommandAst
    $assignments = @($functionAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -ceq '$netshPath'
            }, $true))
    return $assignments.Count -eq 1 -and
        (ConvertTo-WdtNormalizedAstText -Ast $assignments[0]) -ceq '$netshPath = Resolve-WdtSystemExecutablePath -FileName ''netsh.exe'''
}

function New-WdtSafetyIssue {
    param($Ast, [string]$Message)
    [pscustomobject]@{ Type = 'Safety'; Line = $Ast.Extent.StartLineNumber; Column = $Ast.Extent.StartColumnNumber; Command = $Ast.Extent.Text; Message = $Message }
}

function Test-WdtEntrypointPath {
    param([string]$ScriptPath, [string]$RepositoryRoot)
    return [string]::Equals([IO.Path]::GetFullPath($ScriptPath), [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'Invoke-WindowsDiagnostics.ps1')), [StringComparison]::OrdinalIgnoreCase)
}

function Test-WdtProcessRunnerPath {
    param([string]$ScriptPath, [string]$RepositoryRoot)
    return Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\process-runner.ps1'
}

function Test-WdtModuleRegistryPath {
    param([string]$ScriptPath, [string]$RepositoryRoot)
    return Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\module-registry.ps1'
}

function Resolve-WdtStaticScriptRootPath {
    param($PathAst, [string]$ScriptPath)

    if ($PathAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $PathAst -isnot [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return $null }

    $text = $PathAst.Extent.Text.Trim()
    if ($text.Length -ge 2 -and $text[0] -eq "'" -and $text[$text.Length - 1] -eq "'") { return $null }
    if ($text.Length -ge 2 -and $text[0] -eq '"' -and $text[$text.Length - 1] -eq '"') {
        $text = $text.Substring(1, $text.Length - 2)
    }

    $prefix = '$PSScriptRoot'
    if (-not $text.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    $relativePath = $text.Substring($prefix.Length)
    if ($relativePath.Length -lt 2 -or $relativePath[0] -notin @('\', '/')) { return $null }
    $relativePath = $relativePath.TrimStart('\', '/')
    if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath -match '[`$():]') { return $null }

    try {
        return [System.IO.Path]::GetFullPath((Join-Path -Path (Split-Path -Parent $ScriptPath) -ChildPath $relativePath))
    }
    catch {
        return $null
    }
}

function Test-WdtPathInCollection {
    param([string]$Path, $Paths)

    foreach ($candidate in @($Paths)) {
        if ([string]::Equals([System.IO.Path]::GetFullPath([string]$Path), [System.IO.Path]::GetFullPath([string]$candidate), [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-WdtPathWithinDirectory {
    param([string]$Path, [string]$Directory)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $prefix = $fullDirectory + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-WdtModuleScriptClassification {
    param([string]$ScriptPath, $RegistrySnapshot)

    foreach ($definition in @($RegistrySnapshot.Modules)) {
        if (-not (Test-WdtPathWithinDirectory -Path $ScriptPath -Directory $definition.ModuleDirectory)) { continue }
        if (Test-WdtPathInCollection -Path $ScriptPath -Paths $definition.ScriptPaths) { return 'Registered' }
        return 'SnapshotMismatch'
    }

    return 'Orphan'
}

function Get-WdtModuleDefinitionForScript {
    param([string]$ScriptPath, $RegistrySnapshot)

    if ($null -eq $RegistrySnapshot) { return $null }
    foreach ($definition in @($RegistrySnapshot.Modules)) {
        if (Test-WdtPathInCollection -Path $ScriptPath -Paths $definition.ScriptPaths) {
            return $definition
        }
    }

    return $null
}

function Test-WdtAllowedDotSource {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot, $RegistrySnapshot, $ModuleDefinition)

    if ($CommandAst.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Dot -or
        $CommandAst.CommandElements.Count -ne 1 -or $CommandAst.Redirections.Count -ne 0) { return $false }

    $targetPath = Resolve-WdtStaticScriptRootPath -PathAst $CommandAst.CommandElements[0] -ScriptPath $ScriptPath
    if ([string]::IsNullOrWhiteSpace($targetPath)) { return $false }

    $fixedImports = @(
        [pscustomobject]@{ Caller = 'scripts\validate.ps1'; Target = 'scripts\validation-policy.ps1' },
        [pscustomobject]@{ Caller = 'scripts\validate.ps1'; Target = 'scripts\module-registry.ps1' },
        [pscustomobject]@{ Caller = 'Invoke-WindowsDiagnostics.ps1'; Target = 'scripts\module-registry.ps1' },
        [pscustomobject]@{ Caller = 'Invoke-WindowsDiagnostics.ps1'; Target = 'scripts\report-common.ps1' },
        [pscustomobject]@{ Caller = 'Invoke-WindowsDiagnostics.ps1'; Target = 'scripts\process-runner.ps1' },
        [pscustomobject]@{ Caller = 'Invoke-WindowsDiagnostics.ps1'; Target = 'scripts\tui.ps1' }
    )
    foreach ($fixedImport in $fixedImports) {
        if ((Test-WdtScriptPath $ScriptPath $RepositoryRoot $fixedImport.Caller) -and
            (Test-WdtScriptPath $targetPath $RepositoryRoot $fixedImport.Target)) { return $true }
    }

    if ($null -eq $ModuleDefinition) {
        $ModuleDefinition = Get-WdtModuleDefinitionForScript -ScriptPath $ScriptPath -RegistrySnapshot $RegistrySnapshot
    }
    if ($null -eq $ModuleDefinition) { return $false }

    if (Test-WdtPathInCollection -Path $targetPath -Paths $ModuleDefinition.ScriptPaths) { return $true }
    return (Test-WdtPathInCollection -Path $ScriptPath -Paths @($ModuleDefinition.EntryPoint)) -and
        (Test-WdtScriptPath $targetPath $RepositoryRoot 'scripts\report-common.ps1')
}

function Test-WdtTerminalTopLevelCommand {
    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$CommandAst)

    if ($null -ne (Get-WdtEnclosingFunctionAst -Ast $CommandAst)) { return $false }
    if ($CommandAst.Parent -isnot [System.Management.Automation.Language.PipelineAst]) { return $false }
    $pipeline = $CommandAst.Parent
    if (@($pipeline.PipelineElements).Count -ne 1 -or
        -not [System.Object]::ReferenceEquals($pipeline.PipelineElements[0], $CommandAst)) { return $false }

    $current = $pipeline.Parent
    while ($null -ne $current -and $current -isnot [System.Management.Automation.Language.ScriptBlockAst]) {
        $current = $current.Parent
    }
    if ($null -eq $current -or $null -eq $current.EndBlock) { return $false }
    $statements = @($current.EndBlock.Statements)
    return $statements.Count -gt 0 -and [System.Object]::ReferenceEquals($statements[$statements.Count - 1], $pipeline)
}

function Test-WdtAllowedRegisteredScriptInvocation {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot, $RegistrySnapshot, $ModuleDefinition)

    if ($CommandAst.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Ampersand -or
        $CommandAst.Redirections.Count -ne 0 -or $CommandAst.CommandElements.Count -lt 1) { return $false }

    $targetPath = Resolve-WdtStaticScriptRootPath -PathAst $CommandAst.CommandElements[0] -ScriptPath $ScriptPath
    if ([string]::IsNullOrWhiteSpace($targetPath)) { return $false }

    if ($null -eq $ModuleDefinition) {
        $ModuleDefinition = Get-WdtModuleDefinitionForScript -ScriptPath $ScriptPath -RegistrySnapshot $RegistrySnapshot
    }
    if ($null -ne $ModuleDefinition) {
        return Test-WdtPathInCollection -Path $targetPath -Paths $ModuleDefinition.ScriptPaths
    }

    $scriptsDirectory = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'scripts'))
    if (-not [string]::Equals([System.IO.Path]::GetFullPath((Split-Path -Parent $ScriptPath)), $scriptsDirectory, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not (Test-WdtTerminalTopLevelCommand -CommandAst $CommandAst)) { return $false }
    if ($CommandAst.CommandElements.Count -ne 2) { return $false }
    $forwardedParameters = $CommandAst.CommandElements[1]
    if ($forwardedParameters -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
        -not $forwardedParameters.Splatted -or $forwardedParameters.VariablePath.UserPath -cne 'PSBoundParameters') { return $false }

    $launcherTargets = @{
        'crash-hang-diagnostics.ps1' = 'modules\crashes\diagnostic.ps1'
        'disk-health.ps1' = 'modules\disk\diagnostic.ps1'
        'event-log-check.ps1' = 'modules\events\diagnostic.ps1'
        'network-check.ps1' = 'modules\network\diagnostic.ps1'
        'performance-snapshot.ps1' = 'modules\performance\diagnostic.ps1'
        'security-posture.ps1' = 'modules\security\diagnostic.ps1'
        'services-check.ps1' = 'modules\services\diagnostic.ps1'
        'system-info.ps1' = 'modules\system\diagnostic.ps1'
        'time-sync-diagnostics.ps1' = 'modules\time\diagnostic.ps1'
        'windows-update-check.ps1' = 'modules\updates\diagnostic.ps1'
    }
    $launcherName = Split-Path -Leaf $ScriptPath
    if (-not $launcherTargets.ContainsKey($launcherName)) { return $false }
    $expectedTarget = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $launcherTargets[$launcherName]))
    if (-not [string]::Equals($targetPath, $expectedTarget, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }

    foreach ($definition in @($RegistrySnapshot.Modules)) {
        if (Test-WdtPathInCollection -Path $expectedTarget -Paths @($definition.EntryPoint)) { return $true }
    }

    return $false
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

    $functionAst = Get-WdtEnclosingFunctionAst -Ast $Ast
    if ($null -ne $functionAst) { return $functionAst.Name }
    return $null
}

function Get-WdtEnclosingFunctionAst {
    param([System.Management.Automation.Language.Ast]$Ast)

    $current = $Ast.Parent
    while ($null -ne $current) {
        if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $current
        }

        $current = $current.Parent
    }

    return $null
}

function ConvertTo-WdtNormalizedAstText {
    param([Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast)
    return (($Ast.Extent.Text -replace '\s+', ' ').Trim())
}

function Test-WdtAllowedW32tmProcessShape {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast,
        [string]$ScriptPath,
        [string]$RepositoryRoot,
        [string[]]$LocalFunctionNames
    )

    if (-not (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'modules\time\diagnostic.ps1')) { return $false }

    $functionAst = Get-WdtEnclosingFunctionAst -Ast $Ast
    if ($null -eq $functionAst -or $functionAst.Name -cne 'Invoke-W32tmQuery') { return $false }

    $expectedCommands = @(
        "Resolve-WdtSystemExecutablePath -FileName 'w32tm.exe'",
        'Get-WdtOemEncoding',
        'New-Object System.Diagnostics.Process',
        'New-Object System.Diagnostics.ProcessStartInfo',
        'New-WdtW32tmResult -Stdout $stdout -Stderr $stderr -ExitCode $exitCode'
    ) | Sort-Object
    $actualCommands = @($functionAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { ConvertTo-WdtNormalizedAstText -Ast $_ } | Sort-Object)
    if ($actualCommands.Count -ne $expectedCommands.Count) { return $false }
    for ($index = 0; $index -lt $expectedCommands.Count; $index++) {
        if ($actualCommands[$index] -cne $expectedCommands[$index]) { return $false }
    }

    $expectedAssignments = @(
        '$commandPath = Resolve-WdtSystemExecutablePath -FileName ''w32tm.exe''',
        '$exitCode = $process.ExitCode',
        '$oemEncoding = Get-WdtOemEncoding',
        '$process = $null',
        '$process = New-Object System.Diagnostics.Process',
        '$process.StartInfo = $startInfo',
        '$stderr = $stderrReader.ReadToEnd()',
        '$stderrReader = $null',
        '$stderrReader = $process.StandardError',
        '$startInfo = New-Object System.Diagnostics.ProcessStartInfo',
        '$startInfo.Arguments = if ($Query -eq ''Source'') { ''/query /source'' } else { ''/query /status /verbose'' }',
        '$startInfo.CreateNoWindow = $true',
        '$startInfo.FileName = $commandPath',
        '$startInfo.RedirectStandardError = $true',
        '$startInfo.RedirectStandardOutput = $true',
        '$startInfo.StandardErrorEncoding = $oemEncoding',
        '$startInfo.StandardOutputEncoding = $oemEncoding',
        '$startInfo.UseShellExecute = $false',
        '$stdout = $stdoutReader.ReadToEnd()',
        '$stdoutReader = $null',
        '$stdoutReader = $process.StandardOutput'
    ) | Sort-Object
    $actualAssignments = @($functionAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
            ForEach-Object { ConvertTo-WdtNormalizedAstText -Ast $_ } | Sort-Object)
    if ($actualAssignments.Count -ne $expectedAssignments.Count) { return $false }
    for ($index = 0; $index -lt $expectedAssignments.Count; $index++) {
        if ($actualAssignments[$index] -cne $expectedAssignments[$index]) { return $false }
    }

    $expectedMemberCalls = @(
        '[string]::IsNullOrWhiteSpace($commandPath)',
        '$process.Dispose()',
        '$process.Start()',
        '$process.WaitForExit()',
        '$stderrReader.Dispose()',
        '$stderrReader.ReadToEnd()',
        '$stdoutReader.Dispose()',
        '$stdoutReader.ReadToEnd()'
    ) | Sort-Object
    $actualMemberCalls = @($functionAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
            ForEach-Object { ConvertTo-WdtNormalizedAstText -Ast $_ } | Sort-Object)
    if ($actualMemberCalls.Count -ne $expectedMemberCalls.Count) { return $false }
    for ($index = 0; $index -lt $expectedMemberCalls.Count; $index++) {
        if ($actualMemberCalls[$index] -cne $expectedMemberCalls[$index]) { return $false }
    }

    return $true
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

    if (-not (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'modules\security\diagnostic.ps1')) { return $false }
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
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot, [string[]]$LocalFunctionNames)

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
        'System.Collections.Generic.List[int]',
        'System.Collections.Generic.List[double]',
        'System.Collections.Generic.List[System.IO.FileInfo]',
        'System.Collections.Generic.Queue[System.IO.DirectoryInfo]',
        'System.Collections.Generic.Dictionary[string,object]',
        'System.Collections.ObjectModel.ReadOnlyDictionary[string,object]'
    )
    if ($typeName -in $safeTypes) { return $true }

    if ($typeName -eq 'char[]' -and
        (Test-WdtProcessRunnerPath $ScriptPath $RepositoryRoot) -and
        (Get-WdtEnclosingFunctionName $CommandAst) -ceq 'New-WdtStreamCaptureState' -and
        $CommandAst.Extent.Text -ceq 'New-Object char[] $script:WdtProcessRunnerConfig.StreamBufferSize') { return $true }

    if ($typeName -eq 'System.Net.Sockets.TcpClient' -and
        (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'modules\network\diagnostic.ps1') -and
        (Get-WdtEnclosingFunctionName $CommandAst) -ceq 'Test-TcpEndpointConnection' -and
        $CommandAst.CommandElements.Count -eq 2) { return $true }

    if ($typeName -in @('System.Diagnostics.ProcessStartInfo', 'System.Diagnostics.Process') -and
        (Test-WdtProcessRunnerPath $ScriptPath $RepositoryRoot) -and
        (Get-WdtEnclosingFunctionName $CommandAst) -ceq 'Invoke-DiagnosticScript' -and
        $CommandAst.CommandElements.Count -eq 2) {
        return $true
    }
    if ($typeName -in @('System.Diagnostics.ProcessStartInfo', 'System.Diagnostics.Process') -and
        (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'modules\time\diagnostic.ps1') -and
        (Get-WdtEnclosingFunctionName $CommandAst) -ceq 'Invoke-W32tmQuery' -and
        $CommandAst.CommandElements.Count -eq 2 -and
        (Test-WdtAllowedW32tmProcessShape -Ast $CommandAst -ScriptPath $ScriptPath -RepositoryRoot $RepositoryRoot -LocalFunctionNames $LocalFunctionNames)) {
        return $true
    }

    return $false
}

function Test-WdtAllowedPowerShellCommand {
    param([string]$CommandName)

    return $CommandName -in @(
        'Add-Member',
        'Confirm-SecureBootUEFI',
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
        'Get-StorageReliabilityCounter',
        'Get-TimeZone',
        'Get-Tpm',
        'Get-Volume',
        'Get-WinEvent',
        'Group-Object',
        'Join-Path',
        'Measure-Object',
        'Out-Null',
        'Resolve-DnsName',
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

function Test-WdtAllowedVersionRead {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot)

    if (-not (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot) -or
        $CommandAst.GetCommandName() -ine 'Get-Content' -or
        $null -ne (Get-WdtEnclosingFunctionName $CommandAst) -or
        $CommandAst.Redirections.Count -ne 0) { return $false }

    $elements = @($CommandAst.CommandElements)
    return $elements.Count -eq 4 -and
        $elements[1] -is [System.Management.Automation.Language.CommandParameterAst] -and
        $elements[1].ParameterName -ieq 'LiteralPath' -and
        (Test-WdtSimpleVariable $elements[2] 'versionPath') -and
        $elements[3] -is [System.Management.Automation.Language.CommandParameterAst] -and
        $elements[3].ParameterName -ieq 'Raw'
}

function Test-WdtAllowedManifestImport {
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot)

    if (-not (Test-WdtModuleRegistryPath $ScriptPath $RepositoryRoot) -or
        $CommandAst.GetCommandName() -ine 'Import-PowerShellDataFile' -or
        $CommandAst.Redirections.Count -ne 0) { return $false }

    $elements = @($CommandAst.CommandElements)
    if ($elements.Count -ne 5) { return $false }
    return $elements[1] -is [System.Management.Automation.Language.CommandParameterAst] -and
        $elements[1].ParameterName -ieq 'LiteralPath' -and
        (Test-WdtSimpleVariable $elements[2] 'fullManifestPath') -and
        $elements[3] -is [System.Management.Automation.Language.CommandParameterAst] -and
        $elements[3].ParameterName -ieq 'ErrorAction' -and
        $elements[4] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $elements[4].Value -ieq 'Stop'
}

function Test-WdtAllowedParserParseFile {
    param($MemberAst, [string]$ScriptPath, [string]$RepositoryRoot)

    if ($MemberAst.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst] -or
        $MemberAst.Expression.TypeName.FullName -ne 'System.Management.Automation.Language.Parser' -or
        [string]$MemberAst.Member.Value -ne 'ParseFile' -or $MemberAst.Arguments.Count -ne 3) { return $false }

    $arguments = @($MemberAst.Arguments | ForEach-Object { ConvertTo-WdtNormalizedAstText -Ast $_ })
    $functionName = Get-WdtEnclosingFunctionName $MemberAst
    if ((Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\validate.ps1') -and $null -eq $functionName) {
        return $arguments[0] -ceq '$script.FullName' -and $arguments[1] -ceq '[ref]$tokens' -and $arguments[2] -ceq '[ref]$parseErrors'
    }
    if ((Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\validation-policy.ps1') -and $functionName -ceq 'Get-WdtSafetyIssues') {
        return $arguments[0] -ceq '$helperPath' -and $arguments[1] -ceq '[ref]$helperTokens' -and $arguments[2] -ceq '[ref]$helperErrors'
    }
    if ((Test-WdtModuleRegistryPath $ScriptPath $RepositoryRoot) -and $functionName -ceq 'Import-WdtModuleManifest') {
        $manifestForm = $arguments[0] -ceq '$fullManifestPath' -and $arguments[1] -ceq '[ref]$tokens' -and $arguments[2] -ceq '[ref]$parseErrors'
        $entrypointForm = $arguments[0] -ceq '$entryPointPath' -and $arguments[1] -ceq '[ref]$entryTokens' -and $arguments[2] -ceq '[ref]$entryErrors'
        return $manifestForm -or $entrypointForm
    }

    return $false
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
    param($CommandAst, [string]$ScriptPath, [string]$RepositoryRoot, [string[]]$LocalFunctionNames, $RegistrySnapshot, $ModuleDefinition)
    if ($CommandAst.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) {
        if (-not (Test-WdtAllowedDotSource $CommandAst $ScriptPath $RepositoryRoot $RegistrySnapshot $ModuleDefinition)) { return New-WdtSafetyIssue $CommandAst 'Dot-sourced script is not an approved repository helper.' }
        return
    }
    if (Test-WdtAllowedRegisteredScriptInvocation $CommandAst $ScriptPath $RepositoryRoot $RegistrySnapshot $ModuleDefinition) { return }
    $rawName = $CommandAst.GetCommandName()
    if (Test-WdtAllowedNetshCommand $CommandAst $ScriptPath $RepositoryRoot) { return }
    if ([string]::IsNullOrWhiteSpace($rawName)) {
        if (Test-WdtAllowedInternalCallbackInvocation $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'Dynamic command invocation is not allowed in production scripts. Only approved internal callbacks are permitted.'
    }
    $leaf = Split-Path -Leaf ($rawName -replace '/', '\\')
    if ($rawName -match '^[A-Za-z0-9_.-]+\\[A-Za-z][A-Za-z0-9]*-[A-Za-z][A-Za-z0-9]*$') {
        return New-WdtSafetyIssue $CommandAst 'Module-qualified PowerShell commands are not allowed in production scripts.'
    }

    if ($leaf -eq 'Invoke-DiagnosticScript' -and (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot)) { return }
    if ($leaf -in @('Resolve-WdtDiagnosticResult', 'New-WdtFindingObject') -and (Test-WdtProcessRunnerPath $ScriptPath $RepositoryRoot)) { return }
    if ($leaf -eq 'Get-Content') {
        if (Test-WdtAllowedVersionRead $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'Get-Content is only allowed for the root VERSION file read in the entrypoint.'
    }
    if ($CommandAst.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and $leaf -ne 'netsh.exe') { return New-WdtSafetyIssue $CommandAst 'Dynamic command invocation is not allowed in production scripts.' }

    if ($leaf -eq 'Invoke-CimMethod') {
        if (Test-WdtAllowedBitLockerCimQuery $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'Invoke-CimMethod is only allowed for approved read-only BitLocker status queries.'
    }

    if ($leaf -eq 'Import-PowerShellDataFile') {
        if (Test-WdtAllowedManifestImport $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'Import-PowerShellDataFile is only allowed for the exact registry manifest importer form.'
    }

    if ($leaf -eq 'Invoke-WdtReport') {
        if ($leaf -in $LocalFunctionNames) { return }
        if (Test-WdtAllowedTuiReportInvocation $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'The report runner is only callable from the approved interactive session.'
    }

    if ($leaf -eq 'Read-Host') {
        if ((Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\tui.ps1') -and
            (Get-WdtEnclosingFunctionName $CommandAst) -ceq 'Invoke-WdtInteractiveSession' -and
            $CommandAst.Redirections.Count -eq 0) { return }
        return New-WdtSafetyIssue $CommandAst 'Read-Host is only allowed in Invoke-WdtInteractiveSession without redirection.'
    }

    if ($leaf -eq 'Clear-Host') {
        if ((Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\tui.ps1') -and
            (Get-WdtEnclosingFunctionName $CommandAst) -ceq 'Show-WdtTuiFrame' -and
            $CommandAst.Redirections.Count -eq 0) { return }
        return New-WdtSafetyIssue $CommandAst 'Clear-Host is only allowed in approved TUI rendering functions without redirection.'
    }

    if ($leaf -eq 'New-Item') {
        if (Test-WdtAllowedNewItemCommand $CommandAst $ScriptPath $RepositoryRoot) { return }
        return New-WdtSafetyIssue $CommandAst 'New-Item is only allowed in Invoke-WindowsDiagnostics.ps1 for -OutputDirectory creation.'
    }

    if ($leaf -eq 'New-Object') {
        if (Test-WdtAllowedNewObjectCommand $CommandAst $ScriptPath $RepositoryRoot $LocalFunctionNames) { return }
        return New-WdtSafetyIssue $CommandAst 'New-Object type is not in the reviewed safe-type allowlist.'
    }

    if ($leaf -eq 'netsh.exe') {
        if (-not (Test-WdtAllowedNativeRedirection $CommandAst)) { return New-WdtSafetyIssue $CommandAst 'PowerShell redirection is not permitted in production scripts.' }
        if (Test-WdtAllowedNetshCommand $CommandAst $ScriptPath $RepositoryRoot) { return }
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
    param($MemberAst, [string]$ScriptPath, [string]$RepositoryRoot, [string[]]$LocalFunctionNames)
    $member = [string]$MemberAst.Member.Value
    $argumentCount = $MemberAst.Arguments.Count
    $isStatic = $MemberAst.Expression -is [System.Management.Automation.Language.TypeExpressionAst]
    if ($isStatic) {
        $typeName = $MemberAst.Expression.TypeName.FullName
        if (Test-WdtModuleRegistryPath $ScriptPath $RepositoryRoot) {
            $registryStaticMethods = @(
                'System.Collections.Generic.Dictionary[string,object]::new',
                'System.Collections.Generic.Dictionary[string,string]::new',
                'System.Collections.Generic.HashSet[string]::new',
                'System.Collections.Generic.List[object]::new',
                'System.Collections.Generic.List[string]::new',
                'System.Collections.Generic.Queue[string]::new',
                'System.Collections.ObjectModel.ReadOnlyDictionary[string,object]::new',
                'System.Collections.ObjectModel.ReadOnlyDictionary[string,string]::new',
                'System.Array::Sort',
                'System.IO.Directory::Exists',
                'System.IO.File::Exists',
                'System.IO.Path::GetFileName',
                'System.IO.Path::IsPathRooted'
            )
            if (("{0}::{1}" -f $typeName, $member) -in $registryStaticMethods) { return }
        }
        if ((Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\tui.ps1') -and
            ("{0}::{1}" -f $typeName, $member) -in @(
                'System.Collections.Generic.Dictionary[string,object]::new',
                'System.Collections.ObjectModel.ReadOnlyDictionary[string,object]::new'
            )) { return }
        if ($typeName -eq 'System.Console' -and $member -eq 'ReadKey' -and
            (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\tui.ps1') -and
            (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Wait-WdtTuiEvent' -and
            $argumentCount -eq 1 -and $MemberAst.Arguments[0].Extent.Text -ceq '$true') {
            return
        }
        if ($typeName -eq 'System.Console' -and $member -eq 'SetCursorPosition' -and
            (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\tui.ps1') -and
            (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Show-WdtTuiFrame' -and
            $argumentCount -eq 2 -and
            $MemberAst.Arguments[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $MemberAst.Arguments[0].VariablePath.UserPath -ceq 'column' -and
            $MemberAst.Arguments[1] -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $MemberAst.Arguments[1].VariablePath.UserPath -ceq 'row') {
            return
        }
        if ($typeName -eq 'System.Console' -and $member -eq 'SetCursorPosition' -and
            (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\tui.ps1') -and
            (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Complete-WdtTuiConsoleFrame' -and
            $argumentCount -eq 2 -and
            $MemberAst.Arguments[0].Extent.Text -ceq '0' -and
            $MemberAst.Arguments[1] -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $MemberAst.Arguments[1].VariablePath.UserPath -ceq 'anchorRow') {
            return
        }
        if ($typeName -eq 'System.Text.Encoding' -and $member -eq 'GetEncoding' -and
            (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'modules\time\diagnostic.ps1') -and
            (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Get-WdtOemEncoding' -and
            $argumentCount -eq 1 -and $MemberAst.Arguments[0].Extent.Text -ceq '$oemCodePage') {
            return
        }
        if ($typeName -eq 'System.IO.File' -and $member -eq 'WriteAllLines' -and (Test-WdtEntrypointPath $ScriptPath $RepositoryRoot) -and $argumentCount -eq 3) {
            $pathVariable = if ($MemberAst.Arguments[0] -is [System.Management.Automation.Language.VariableExpressionAst]) { $MemberAst.Arguments[0].VariablePath.UserPath } else { '' }
            $linesVariable = if ($MemberAst.Arguments[1] -is [System.Management.Automation.Language.VariableExpressionAst]) { $MemberAst.Arguments[1].VariablePath.UserPath } else { '' }
            $isReportPair = ($pathVariable -ceq 'textReportPath' -and $linesVariable -ceq 'textLines') -or
                ($pathVariable -ceq 'markdownReportPath' -and $linesVariable -ceq 'markdownLines')
            if ($isReportPair -and $MemberAst.Arguments[2].Extent.Text -ceq '[System.Text.Encoding]::UTF8') { return }
        }
        if ((Test-WdtProcessRunnerPath $ScriptPath $RepositoryRoot) -and
            (($typeName -eq 'System.Diagnostics.Process' -and $member -eq 'GetProcessById' -and (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Stop-WdtProcessTree') -or
             ($typeName -eq 'System.Diagnostics.Stopwatch' -and $member -eq 'StartNew' -and (Get-WdtEnclosingFunctionName $MemberAst) -in @('Invoke-DiagnosticScript', 'Stop-WdtProcessTree')))) { return }
        if ((Test-WdtEntrypointPath $ScriptPath $RepositoryRoot) -and
            $typeName -eq 'Security.Principal.WindowsIdentity' -and $member -eq 'GetCurrent' -and
            (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Invoke-WdtReport') { return }
        if ($typeName -eq 'System.Management.Automation.Language.Parser' -and $member -eq 'ParseFile') {
            if (Test-WdtAllowedParserParseFile -MemberAst $MemberAst -ScriptPath $ScriptPath -RepositoryRoot $RepositoryRoot) { return }
            return New-WdtSafetyIssue $MemberAst 'Parser::ParseFile is only allowed for exact production validation and registry parser forms.'
        }

        $safeStaticMethods = @(
            'IO.Path::GetExtension',
            'IO.Path::GetFullPath',
            'Management.ManagementDateTimeConverter::ToDateTime',
            'Math::Max',
            'Math::Min',
            'Math::Floor',
            'string::Equals',
            'string::IsNullOrEmpty',
            'string::IsNullOrWhiteSpace',
            'System.Diagnostics.Process::GetCurrentProcess',
            'System.Convert::ToBase64String',
            'System.Guid::NewGuid',
            'System.Guid::TryParse',
            'System.Object::ReferenceEquals',
            'System.IO.Directory::GetParent',
            'System.IO.Path::GetExtension',
            'System.IO.Path::GetFullPath',
            'System.IO.Path::GetPathRoot',
            'System.Net.Dns::GetHostAddresses',
            'System.Net.IPAddress::TryParse',
            'System.Text.RegularExpressions.Regex::Escape',
            'System.Text.RegularExpressions.Regex::Matches',
            'System.Text.RegularExpressions.Regex::Replace',
            'System.Text.RegularExpressions.Regex::Split',
            'System.Uri::UnescapeDataString'
        )
        if (("{0}::{1}" -f $typeName, $member) -in $safeStaticMethods) { return }
        return New-WdtSafetyIssue $MemberAst 'Static method is not in the reviewed safe allowlist.'
    }

    $receiver = if ($MemberAst.Expression -is [System.Management.Automation.Language.VariableExpressionAst]) { $MemberAst.Expression.VariablePath.UserPath } else { '' }
    if ((Test-WdtModuleRegistryPath $ScriptPath $RepositoryRoot) -and $member -eq 'AsReadOnly' -and
        $receiver -in @('list', 'moduleList') -and $argumentCount -eq 0) { return }
    if ($member -eq 'Start' -and $receiver -ceq 'process' -and $argumentCount -eq 0 -and (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Invoke-DiagnosticScript' -and (Test-WdtProcessRunnerPath $ScriptPath $RepositoryRoot)) { return }
    if ((Test-WdtProcessRunnerPath $ScriptPath $RepositoryRoot) -and (
            (((Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Stop-WdtProcessTree') -and $member -in @('Kill', 'WaitForExit', 'Dispose')) -or
            ((Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Stop-WdtProcessTree' -and $member -eq 'Stop') -or
            ((Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Invoke-DiagnosticScript' -and $member -in @('Stop', 'Dispose'))
        )) { return }
    if ((Test-WdtEntrypointPath $ScriptPath $RepositoryRoot) -and (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Invoke-WdtReport' -and $member -eq 'IsInRole') { return }
    if ((Test-WdtProcessRunnerPath $ScriptPath $RepositoryRoot) -and
        (Get-WdtEnclosingFunctionName $MemberAst) -in @('New-WdtStreamCaptureState', 'Read-WdtCompletedStreamChunks') -and
        $member -eq 'ReadAsync' -and $argumentCount -eq 3) { return }
    if ((Test-WdtProcessRunnerPath $ScriptPath $RepositoryRoot) -and
        (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Invoke-DiagnosticScript' -and
        $member -eq 'GetBytes' -and $argumentCount -eq 1 -and
        $MemberAst.Expression.Extent.Text -ceq '[System.Text.Encoding]::Unicode' -and
        $MemberAst.Arguments[0].Extent.Text -ceq '$commandText') { return }
    if ((Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\report-common.ps1') -and
        (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Write-WdtFinding' -and
        $member -eq 'WriteLine' -and $argumentCount -eq 1 -and
        $MemberAst.Expression.Extent.Text -ceq '[System.Console]::Out' -and
        $MemberAst.Arguments[0].Extent.Text -ceq '$marker') { return }
    if ((Test-WdtScriptPath $ScriptPath $RepositoryRoot 'modules\network\diagnostic.ps1') -and
        (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Test-TcpEndpointConnection' -and
        $member -in @('ConnectAsync', 'Wait', 'Dispose')) { return }
    if ((Test-WdtScriptPath $ScriptPath $RepositoryRoot 'modules\time\diagnostic.ps1') -and
        (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'Invoke-W32tmQuery' -and
        (Test-WdtAllowedW32tmProcessShape -Ast $MemberAst -ScriptPath $ScriptPath -RepositoryRoot $RepositoryRoot -LocalFunctionNames $LocalFunctionNames) -and
        (($member -eq 'Start' -and $receiver -ceq 'process' -and $argumentCount -eq 0) -or
            ($member -eq 'Dispose' -and $receiver -in @('process', 'stdoutReader', 'stderrReader') -and $argumentCount -eq 0))) {
        return
    }

    if ($member -eq 'GetString' -and $receiver -ceq 'Encoding' -and $argumentCount -eq 1 -and
        (Test-WdtScriptPath $ScriptPath $RepositoryRoot 'modules\time\diagnostic.ps1') -and
        (Get-WdtEnclosingFunctionName $MemberAst) -ceq 'ConvertFrom-WdtOemBytes') {
        return
    }

    $safeInstanceMethods = @(
        'Add',
        'AddDays',
        'AddHours',
        'AddMilliseconds',
        'AddSeconds',
        'Append',
        'Contains',
        'ContainsKey',
        'Dequeue',
        'Enqueue',
        'Equals',
        'FindAll',
        'GetAddressBytes',
        'GetCommandName',
        'GetEnumerator',
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
        'TrimStart',
        'WaitForExit'
    )
    if ($member -in $safeInstanceMethods) { return }
    return New-WdtSafetyIssue $MemberAst 'Instance method is not in the reviewed safe allowlist.'
}

function Get-WdtConsolePropertySafetyIssue {
    param($MemberAst, [string]$ScriptPath, [string]$RepositoryRoot)

    if ($MemberAst.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { return }
    if ($MemberAst.Expression.TypeName.FullName -ne 'System.Console') { return }
    $member = [string]$MemberAst.Member.Value
    $isTuiScript = Test-WdtScriptPath $ScriptPath $RepositoryRoot 'scripts\tui.ps1'
    $enclosingFunction = Get-WdtEnclosingFunctionName $MemberAst

    if ($member -eq 'CursorVisible') {
        if ($isTuiScript -and $enclosingFunction -ceq 'Invoke-WdtInteractiveSession') { return }
        return New-WdtSafetyIssue $MemberAst 'Console cursor visibility is only allowed in Invoke-WdtInteractiveSession.'
    }

    if ($member -eq 'KeyAvailable') {
        if ($isTuiScript -and $enclosingFunction -ceq 'Wait-WdtTuiEvent') { return }
        return New-WdtSafetyIssue $MemberAst 'Console key availability is only allowed in Wait-WdtTuiEvent.'
    }
}

function Get-WdtSafetyIssues {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        $RegistrySnapshot,
        $ModuleDefinition,
        [string[]]$PackageFunctionNames = @()
    )

    if ($null -eq $ModuleDefinition) {
        $ModuleDefinition = Get-WdtModuleDefinitionForScript -ScriptPath $ScriptPath -RegistrySnapshot $RegistrySnapshot
    }
    $localFunctionNames = @($PackageFunctionNames) + @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    $approvedImports = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object { Test-WdtAllowedDotSource $_ $ScriptPath $RepositoryRoot $RegistrySnapshot $ModuleDefinition })
    foreach ($import in $approvedImports) {
        $helperPath = Resolve-WdtStaticScriptRootPath -PathAst $import.CommandElements[0] -ScriptPath $ScriptPath
        if ([string]::IsNullOrWhiteSpace($helperPath) -or -not (Test-Path -LiteralPath $helperPath -PathType Leaf)) { continue }
        $helperTokens = $null
        $helperErrors = $null
        $helperAst = [System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$helperTokens, [ref]$helperErrors)
        if (@($helperErrors).Count -eq 0) {
            $localFunctionNames += @($helperAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        }
    }
    $localFunctionNames = @($localFunctionNames | Sort-Object -Unique)
    foreach ($command in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) { Get-WdtCommandSafetyIssue $command $ScriptPath $RepositoryRoot $localFunctionNames $RegistrySnapshot $ModuleDefinition }
    foreach ($member in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) { Get-WdtMemberSafetyIssue $member $ScriptPath $RepositoryRoot $localFunctionNames }
    foreach ($member in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) { Get-WdtConsolePropertySafetyIssue $member $ScriptPath $RepositoryRoot }
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
