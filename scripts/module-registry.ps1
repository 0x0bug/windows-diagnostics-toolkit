[CmdletBinding()]
param()

function New-WdtReadOnlyObjectDictionary {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Values
    )

    $dictionary = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($key in $Values.Keys) {
        $dictionary.Add([string]$key, $Values[$key])
    }

    return ,([System.Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($dictionary))
}

function New-WdtReadOnlyStringDictionary {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Values
    )

    $dictionary = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($key in $Values.Keys) {
        $dictionary.Add([string]$key, [string]$Values[$key])
    }

    return ,([System.Collections.ObjectModel.ReadOnlyDictionary[string, string]]::new($dictionary))
}

function New-WdtReadOnlyStringCollection {
    param(
        [AllowEmptyCollection()]
        [string[]]$Values = @()
    )

    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Values)) {
        $list.Add($value)
    }

    return ,$list.AsReadOnly()
}

function Test-WdtPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $prefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar

    return $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-WdtNormalizedDirectoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath
    }

    return $fullPath.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Assert-WdtNotReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context '$fullPath' must not be a reparse point."
    }
}

function Get-WdtCoreOptionSchema {
    return @(
        [pscustomobject]@{ Name = 'NoExternalNetworkTests'; Kind = 'Boolean' },
        [pscustomobject]@{ Name = 'NetworkDnsTestName'; Kind = 'String' },
        [pscustomobject]@{ Name = 'NetworkHttpsEndpoint'; Kind = 'String' },
        [pscustomobject]@{ Name = 'NetworkIcmpTarget'; Kind = 'String' }
    )
}

function Get-WdtSinglePipelineExpression {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$ValueAst
    )

    if ($ValueAst -isnot [System.Management.Automation.Language.PipelineAst]) {
        return $null
    }

    $elements = @($ValueAst.PipelineElements)
    if ($elements.Count -ne 1 -or
        $elements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
        return $null
    }

    return $elements[0].Expression
}

function Test-WdtLiteralStringArrayExpression {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$ExpressionAst
    )

    $valueExpression = $ExpressionAst
    if ($ExpressionAst -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        $statements = @($ExpressionAst.SubExpression.Statements)
        if ($statements.Count -eq 0) {
            return $true
        }
        if ($statements.Count -ne 1) {
            return $false
        }

        $valueExpression = Get-WdtSinglePipelineExpression -ValueAst $statements[0]
        if ($null -eq $valueExpression) {
            return $false
        }
    }

    if ($valueExpression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $true
    }
    if ($valueExpression -isnot [System.Management.Automation.Language.ArrayLiteralAst]) {
        return $false
    }

    foreach ($element in $valueExpression.Elements) {
        if ($element -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return $false
        }
    }
    return $true
}

function Test-WdtLiteralStringDictionaryExpression {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$ExpressionAst
    )

    if ($ExpressionAst -isnot [System.Management.Automation.Language.HashtableAst]) {
        return $false
    }

    foreach ($pair in $ExpressionAst.KeyValuePairs) {
        if ($pair.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return $false
        }
        $valueExpression = Get-WdtSinglePipelineExpression -ValueAst $pair.Item2
        if ($valueExpression -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return $false
        }
    }
    return $true
}

function Test-WdtManifestLiteralValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$ValueAst
    )

    $expression = Get-WdtSinglePipelineExpression -ValueAst $ValueAst
    if ($null -eq $expression) {
        return $false
    }

    if ($Key -iin @('SchemaVersion', 'Order')) {
        return (
            $expression -is [System.Management.Automation.Language.ConstantExpressionAst] -and
            $expression.Value -is [int]
        )
    }
    if ($Key -iin @('Id', 'Title', 'Label', 'Description', 'EntryPoint')) {
        return $expression -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }
    if ($Key -ieq 'Recommended') {
        return (
            $expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $expression.VariablePath.UserPath -iin @('true', 'false')
        )
    }
    if ($Key -ieq 'DefaultArguments') {
        return Test-WdtLiteralStringArrayExpression -ExpressionAst $expression
    }
    if ($Key -ieq 'OptionBindings') {
        return Test-WdtLiteralStringDictionaryExpression -ExpressionAst $expression
    }

    return $false
}

function Test-WdtOptionBindingType {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Boolean', 'String', 'Integer')]
        [string]$SourceKind,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.ParameterAst]$ParameterAst
    )

    if ($SourceKind -eq 'String') {
        return $ParameterAst.StaticType -eq [string]
    }

    if ($SourceKind -eq 'Integer') {
        return $ParameterAst.StaticType -eq [int]
    }

    if ($ParameterAst.StaticType -ne [System.Management.Automation.SwitchParameter]) {
        return $false
    }

    if ($null -eq $ParameterAst.DefaultValue) {
        return $true
    }

    return (
        $ParameterAst.DefaultValue -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $ParameterAst.DefaultValue.VariablePath.UserPath -ieq 'false'
    )
}

function Resolve-WdtModuleEntryPoint {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ModuleDirectory,
        [Parameter(Mandatory = $true)][string]$ModuleRoot,
        [Parameter(Mandatory = $true)][string]$EntryPoint
    )

    $fullManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
    $fullModuleDirectory = [System.IO.Path]::GetFullPath($ModuleDirectory)
    $fullModuleRoot = Get-WdtNormalizedDirectoryPath -Path $ModuleRoot

    if (-not (Test-WdtPathWithinRoot -Path $fullModuleDirectory -Root $fullModuleRoot)) {
        throw "Module directory '$fullModuleDirectory' is outside module root '$fullModuleRoot'."
    }
    if (-not (Test-WdtPathWithinRoot -Path $fullManifestPath -Root $fullModuleDirectory)) {
        throw "Module manifest '$fullManifestPath' is outside module directory '$fullModuleDirectory'."
    }
    if ([System.IO.Path]::IsPathRooted($EntryPoint) -or $EntryPoint -notmatch '\.ps1\z') {
        throw "Module manifest '$fullManifestPath' requires EntryPoint '$EntryPoint' to be a relative .ps1 path."
    }

    $entryPointSegments = @($EntryPoint -split '[\\/]')
    if ($entryPointSegments.Count -eq 0 -or
        @($entryPointSegments | Where-Object { [string]::IsNullOrEmpty($_) -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
        throw "Module manifest '$fullManifestPath' has an invalid relative EntryPoint '$EntryPoint'."
    }

    $entryPointPath = [System.IO.Path]::GetFullPath((Join-Path -Path $fullModuleDirectory -ChildPath $EntryPoint))
    if (-not (Test-WdtPathWithinRoot -Path $entryPointPath -Root $fullModuleDirectory)) {
        throw "Module manifest '$fullManifestPath' has an EntryPoint '$EntryPoint' outside its module directory: '$entryPointPath'."
    }
    $currentPath = $fullModuleDirectory
    foreach ($segment in $entryPointSegments) {
        $currentPath = [System.IO.Path]::GetFullPath((Join-Path -Path $currentPath -ChildPath $segment))
        if (-not (Test-Path -LiteralPath $currentPath)) {
            throw "Module manifest '$fullManifestPath' references a missing EntryPoint '$entryPointPath'."
        }
        Assert-WdtNotReparsePoint -Path $currentPath -Context 'Module entrypoint path item'
    }
    if (-not [System.IO.File]::Exists($entryPointPath)) {
        throw "Module manifest '$fullManifestPath' requires EntryPoint '$entryPointPath' to be a file."
    }

    Assert-WdtNotReparsePoint -Path $fullManifestPath -Context 'Module manifest'
    return $entryPointPath
}

function Get-WdtPackageScriptPaths {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ModuleDirectory,
        [Parameter(Mandatory = $true)][string]$ModuleRoot
    )

    $fullManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
    $fullModuleDirectory = [System.IO.Path]::GetFullPath($ModuleDirectory)
    $fullModuleRoot = Get-WdtNormalizedDirectoryPath -Path $ModuleRoot

    Assert-WdtNotReparsePoint -Path $fullModuleRoot -Context 'Module root'
    Assert-WdtNotReparsePoint -Path $fullModuleDirectory -Context 'Module directory'
    Assert-WdtNotReparsePoint -Path $fullManifestPath -Context 'Module manifest'

    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($fullModuleDirectory)
    $scriptPaths = [System.Collections.Generic.List[string]]::new()

    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        $children = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop | Sort-Object -Property FullName)
        foreach ($child in $children) {
            $childPath = [System.IO.Path]::GetFullPath($child.FullName)
            if (-not (Test-WdtPathWithinRoot -Path $childPath -Root $fullModuleDirectory)) {
                throw "Module package item '$childPath' is outside module directory '$fullModuleDirectory'."
            }
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Module package item '$childPath' must not be a reparse point."
            }

            if ($child.PSIsContainer) {
                $queue.Enqueue($childPath)
                continue
            }

            if ($child.Name -ieq 'module.psd1' -and
                -not $childPath.Equals($fullManifestPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Nested module manifest '$childPath' is not allowed."
            }
            if ($child.Extension -ieq '.ps1') {
                $scriptPaths.Add($childPath)
            }
        }
    }

    $paths = $scriptPaths.ToArray()
    [System.Array]::Sort($paths, [System.StringComparer]::OrdinalIgnoreCase)
    return New-WdtReadOnlyStringCollection -Values $paths
}

function Import-WdtModuleManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ModuleRoot
    )

    $fullManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
    $fullModuleRoot = Get-WdtNormalizedDirectoryPath -Path $ModuleRoot
    $moduleDirectory = [System.IO.Path]::GetFullPath((Split-Path -Parent $fullManifestPath))
    $moduleParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $moduleDirectory))

    if (-not $moduleParent.Equals($fullModuleRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Module manifest '$fullManifestPath' must be directly inside a package under '$fullModuleRoot'."
    }
    if ([System.IO.Path]::GetFileName($fullManifestPath) -ine 'module.psd1') {
        throw "Module manifest path '$fullManifestPath' must be named 'module.psd1'."
    }

    Assert-WdtNotReparsePoint -Path $fullModuleRoot -Context 'Module root'
    Assert-WdtNotReparsePoint -Path $moduleDirectory -Context 'Module directory'
    Assert-WdtNotReparsePoint -Path $fullManifestPath -Context 'Module manifest'

    $tokens = $null
    $parseErrors = $null
    $manifestAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $fullManifestPath,
        [ref]$tokens,
        [ref]$parseErrors
    )

    $statements = @($manifestAst.EndBlock.Statements)
    $rootHashtable = $null
    if ($statements.Count -eq 1 -and
        $statements[0] -is [System.Management.Automation.Language.PipelineAst] -and
        @($statements[0].PipelineElements).Count -eq 1 -and
        $statements[0].PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
        $statements[0].PipelineElements[0].Expression -is [System.Management.Automation.Language.HashtableAst]) {
        $rootHashtable = $statements[0].PipelineElements[0].Expression
    }
    if ($null -eq $rootHashtable) {
        throw "Module manifest '$fullManifestPath' must contain exactly one top-level literal hashtable."
    }

    $canonicalKeys = @(
        'SchemaVersion',
        'Id',
        'Title',
        'Label',
        'Description',
        'EntryPoint',
        'Recommended',
        'Order',
        'DefaultArguments',
        'OptionBindings'
    )
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $manifestKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in $rootHashtable.KeyValuePairs) {
        $keyAst = $pair.Item1
        if ($keyAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            throw "Module manifest '$fullManifestPath' contains a non-literal key at line $($keyAst.Extent.StartLineNumber)."
        }
        $key = $keyAst.Value
        if (-not $seenKeys.Add($key)) {
            throw "Module manifest '$fullManifestPath' contains duplicate key '$key' (keys are case-insensitive)."
        }
        $manifestKeys.Add($key)
    }

    $allowedKeys = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$canonicalKeys,
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $unknownKeys = @($manifestKeys | Where-Object { -not $allowedKeys.Contains($_) } | Sort-Object)
    $missingKeys = @($canonicalKeys | Where-Object { -not $seenKeys.Contains($_) })
    if ($unknownKeys.Count -gt 0) {
        throw "Module manifest '$fullManifestPath' contains unknown keys: $($unknownKeys -join ', ')."
    }
    if ($missingKeys.Count -gt 0) {
        throw "Module manifest '$fullManifestPath' is missing required keys: $($missingKeys -join ', ')."
    }
    if (@($parseErrors).Count -gt 0) {
        $firstError = @($parseErrors)[0]
        throw "Module manifest '$fullManifestPath' has a parse error at line $($firstError.Extent.StartLineNumber): $($firstError.Message)"
    }

    foreach ($pair in $rootHashtable.KeyValuePairs) {
        $key = $pair.Item1.Value
        if (-not (Test-WdtManifestLiteralValue -Key $key -ValueAst $pair.Item2)) {
            throw "Module manifest '$fullManifestPath' requires '$key' to use its literal schema form without expressions or nested values."
        }
    }

    try {
        $manifestData = Import-PowerShellDataFile -LiteralPath $fullManifestPath -ErrorAction Stop
    }
    catch {
        throw "Module manifest '$fullManifestPath' could not be imported: $($_.Exception.Message)"
    }

    foreach ($stringKey in @('Id', 'Title', 'Label', 'Description', 'EntryPoint')) {
        $value = $manifestData[$stringKey]
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            throw "Module manifest '$fullManifestPath' requires '$stringKey' to be a non-empty string."
        }
    }
    if ($manifestData.SchemaVersion -isnot [int] -or $manifestData.SchemaVersion -ne 1) {
        throw "Module manifest '$fullManifestPath' requires SchemaVersion to be Int32 value 1."
    }
    if ($manifestData.Recommended -isnot [bool]) {
        throw "Module manifest '$fullManifestPath' requires Recommended to be Boolean."
    }
    if ($manifestData.Order -isnot [int]) {
        throw "Module manifest '$fullManifestPath' requires Order to be Int32."
    }
    if ($manifestData.Id -cnotmatch '\A[A-Z][A-Za-z0-9]{1,31}\z') {
        throw "Module manifest '$fullManifestPath' has invalid Id '$($manifestData.Id)'."
    }
    if ($manifestData.DefaultArguments -isnot [System.Array]) {
        throw "Module manifest '$fullManifestPath' requires DefaultArguments to be an array of strings."
    }

    $defaultArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in $manifestData.DefaultArguments) {
        if ($argument -isnot [string] -or [string]::IsNullOrWhiteSpace($argument) -or $argument -match "[\r\n`0]") {
            throw "Module manifest '$fullManifestPath' contains an invalid DefaultArguments token."
        }
        $defaultArguments.Add($argument)
    }
    if ($manifestData.OptionBindings -isnot [System.Collections.IDictionary]) {
        throw "Module manifest '$fullManifestPath' requires OptionBindings to be a string dictionary."
    }

    $entryPointPath = Resolve-WdtModuleEntryPoint `
        -ManifestPath $fullManifestPath `
        -ModuleDirectory $moduleDirectory `
        -ModuleRoot $fullModuleRoot `
        -EntryPoint $manifestData.EntryPoint

    $entryTokens = $null
    $entryErrors = $null
    $entryAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $entryPointPath,
        [ref]$entryTokens,
        [ref]$entryErrors
    )
    if (@($entryErrors).Count -gt 0) {
        $firstError = @($entryErrors)[0]
        throw "Module entrypoint '$entryPointPath' has a parse error at line $($firstError.Extent.StartLineNumber): $($firstError.Message)"
    }

    $parameters = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    if ($null -ne $entryAst.ParamBlock) {
        foreach ($parameter in $entryAst.ParamBlock.Parameters) {
            $parameterName = $parameter.Name.VariablePath.UserPath
            if ($parameters.ContainsKey($parameterName)) {
                throw "Module entrypoint '$entryPointPath' declares duplicate top-level parameter '$parameterName'."
            }
            $parameters.Add($parameterName, $parameter)
        }
    }

    $coreSchema = @{}
    foreach ($source in Get-WdtCoreOptionSchema) {
        $coreSchema[$source.Name] = $source
    }
    $normalizedBindings = @{}
    $targetNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($sourceNameValue in $manifestData.OptionBindings.Keys) {
        $targetNameValue = $manifestData.OptionBindings[$sourceNameValue]
        if ($sourceNameValue -isnot [string] -or $targetNameValue -isnot [string]) {
            throw "Module manifest '$fullManifestPath' requires OptionBindings keys and values to be strings."
        }

        $sourceName = [string]$sourceNameValue
        $targetName = [string]$targetNameValue
        if ($sourceName -notmatch '\A[A-Za-z][A-Za-z0-9]*\z' -or
            $targetName -notmatch '\A[A-Za-z][A-Za-z0-9]*\z') {
            throw "Module manifest '$fullManifestPath' has invalid OptionBindings entry '$sourceName' -> '$targetName'."
        }
        if (-not $coreSchema.ContainsKey($sourceName)) {
            throw "Module manifest '$fullManifestPath' binds unknown core option '$sourceName'."
        }
        if (-not $parameters.ContainsKey($targetName)) {
            throw "Module manifest '$fullManifestPath' binds '$sourceName' to missing top-level parameter '$targetName' in '$entryPointPath'."
        }

        $parameterAst = [System.Management.Automation.Language.ParameterAst]$parameters[$targetName]
        if (-not (Test-WdtOptionBindingType -SourceKind $coreSchema[$sourceName].Kind -ParameterAst $parameterAst)) {
            throw "Module manifest '$fullManifestPath' binds $($coreSchema[$sourceName].Kind) source '$sourceName' to incompatible parameter '$targetName' in '$entryPointPath'."
        }
        $canonicalTargetName = $parameterAst.Name.VariablePath.UserPath
        if (-not $targetNames.Add($canonicalTargetName)) {
            throw "Module manifest '$fullManifestPath' contains duplicate target binding '$canonicalTargetName'."
        }
        $normalizedBindings[$coreSchema[$sourceName].Name] = $canonicalTargetName
    }

    $scriptPaths = Get-WdtPackageScriptPaths `
        -ManifestPath $fullManifestPath `
        -ModuleDirectory $moduleDirectory `
        -ModuleRoot $fullModuleRoot
    $registeredEntryPoints = @($scriptPaths | Where-Object {
            $_.Equals($entryPointPath, [System.StringComparison]::OrdinalIgnoreCase)
        })
    if ($registeredEntryPoints.Count -ne 1) {
        throw "Module entrypoint '$entryPointPath' is not a registered package script."
    }
    $entryPointPath = $registeredEntryPoints[0]

    $definitionValues = [ordered]@{
        SchemaVersion    = [int]$manifestData.SchemaVersion
        Id               = [string]$manifestData.Id
        Title            = [string]$manifestData.Title
        Label            = [string]$manifestData.Label
        Description      = [string]$manifestData.Description
        EntryPoint       = $entryPointPath
        Recommended      = [bool]$manifestData.Recommended
        Order            = [int]$manifestData.Order
        DefaultArguments = New-WdtReadOnlyStringCollection -Values $defaultArguments.ToArray()
        OptionBindings   = New-WdtReadOnlyStringDictionary -Values $normalizedBindings
        ManifestPath     = $fullManifestPath
        ModuleDirectory  = $moduleDirectory
        ScriptPaths      = $scriptPaths
    }

    return New-WdtReadOnlyObjectDictionary -Values $definitionValues
}

function Get-WdtModuleRegistry {
    param(
        [Parameter(Mandatory = $true)][string]$ModuleRoot
    )

    $fullModuleRoot = Get-WdtNormalizedDirectoryPath -Path $ModuleRoot
    if (-not [System.IO.Directory]::Exists($fullModuleRoot)) {
        throw "Module root '$fullModuleRoot' does not exist."
    }
    Assert-WdtNotReparsePoint -Path $fullModuleRoot -Context 'Module root'

    $moduleDirectories = [System.Collections.Generic.List[string]]::new()
    $orphanPaths = [System.Collections.Generic.List[string]]::new()
    $rootItems = @(Get-ChildItem -LiteralPath $fullModuleRoot -Force -ErrorAction Stop | Sort-Object -Property FullName)
    foreach ($item in $rootItems) {
        $itemPath = [System.IO.Path]::GetFullPath($item.FullName)
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Module root item '$itemPath' must not be a reparse point."
        }
        if ($item.PSIsContainer) {
            $moduleDirectories.Add($itemPath)
        }
        elseif ($item.Extension -ieq '.ps1' -or $item.Name -ieq 'module.psd1') {
            $orphanPaths.Add($itemPath)
        }
    }
    if ($moduleDirectories.Count -eq 0) {
        throw "Module root '$fullModuleRoot' contains no module packages."
    }

    $definitions = [System.Collections.Generic.List[object]]::new()
    $byIdMutable = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($moduleDirectory in $moduleDirectories) {
        $manifestPath = [System.IO.Path]::GetFullPath((Join-Path -Path $moduleDirectory -ChildPath 'module.psd1'))
        if (-not [System.IO.File]::Exists($manifestPath)) {
            throw "Module directory '$moduleDirectory' is missing manifest '$manifestPath'."
        }

        $definition = Import-WdtModuleManifest -ManifestPath $manifestPath -ModuleRoot $fullModuleRoot
        if ($byIdMutable.ContainsKey($definition.Id)) {
            throw "Module root '$fullModuleRoot' contains duplicate module Id '$($definition.Id)'."
        }
        $definitions.Add($definition)
        $byIdMutable.Add($definition.Id, $definition)
    }
    if ($orphanPaths.Count -gt 0) {
        throw "Module root '$fullModuleRoot' contains script or manifest outside a package: '$($orphanPaths[0])'."
    }

    $orderedDefinitions = @($definitions | Sort-Object -Property @(
        @{ Expression = { $_.Order }; Ascending = $true },
        @{ Expression = { $_.Id }; Ascending = $true }
    ))
    $moduleList = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in $orderedDefinitions) {
        $moduleList.Add($definition)
    }

    $byId = [System.Collections.ObjectModel.ReadOnlyDictionary[string, object]]::new($byIdMutable)
    return New-WdtReadOnlyObjectDictionary -Values ([ordered]@{
        Modules = $moduleList.AsReadOnly()
        ById    = $byId
    })
}

function Resolve-WdtModuleSelection {
    param(
        [Parameter(Mandatory = $true)][object]$Registry,
        [AllowNull()][AllowEmptyCollection()][string[]]$ModuleIds = @(),
        [AllowNull()][System.Collections.IDictionary]$LegacySelections,
        [bool]$AllRequested = $false
    )

    $selectedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($moduleId in $ModuleIds) {
        if ([string]::IsNullOrWhiteSpace($moduleId)) {
            throw 'Module selection contains an empty module Id.'
        }
        if (-not $Registry.ById.ContainsKey($moduleId)) {
            throw "Unknown diagnostic module Id '$moduleId'."
        }
        [void]$selectedIds.Add($Registry.ById[$moduleId].Id)
    }

    if ($null -ne $LegacySelections) {
        foreach ($legacyIdValue in $LegacySelections.Keys) {
            $legacyId = [string]$legacyIdValue
            if (-not $Registry.ById.ContainsKey($legacyId)) {
                throw "Legacy diagnostic module Id '$legacyId' is not registered."
            }
            if ($LegacySelections[$legacyIdValue]) {
                [void]$selectedIds.Add($Registry.ById[$legacyId].Id)
            }
        }
    }

    if ($AllRequested) {
        return $Registry.Modules
    }

    foreach ($definition in $Registry.Modules) {
        if ($selectedIds.Contains($definition.Id)) {
            Write-Output $definition
        }
    }
}

function Get-WdtCoreOptionValue {
    param(
        [Parameter(Mandatory = $true)][object]$CoreOptions,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ref]$Value
    )

    if ($CoreOptions -is [System.Collections.IDictionary]) {
        foreach ($key in $CoreOptions.Keys) {
            if ([string]$key -ieq $Name) {
                $Value.Value = $CoreOptions[$key]
                return $true
            }
        }
        return $false
    }

    foreach ($property in $CoreOptions.PSObject.Properties) {
        if ($property.Name -ieq $Name) {
            $Value.Value = $property.Value
            return $true
        }
    }
    return $false
}

function Get-WdtModuleInvocationArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][object]$CoreOptions
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in $Definition.DefaultArguments) {
        $arguments.Add($argument)
    }

    foreach ($source in Get-WdtCoreOptionSchema) {
        if (-not $Definition.OptionBindings.ContainsKey($source.Name)) {
            continue
        }

        $value = $null
        if (-not (Get-WdtCoreOptionValue -CoreOptions $CoreOptions -Name $source.Name -Value ([ref]$value))) {
            throw "Core options are missing required source '$($source.Name)' for module '$($Definition.Id)'."
        }
        if ($null -eq $value) {
            continue
        }

        $targetName = $Definition.OptionBindings[$source.Name]
        if ($source.Kind -eq 'Boolean') {
            if ($value -isnot [bool]) {
                throw "Core option '$($source.Name)' for module '$($Definition.Id)' must be Boolean."
            }
            if ($value) {
                $arguments.Add("-$targetName")
            }
            continue
        }

        if ($source.Kind -eq 'String') {
            if ($value -isnot [string]) {
                throw "Core option '$($source.Name)' for module '$($Definition.Id)' must be String."
            }
            $arguments.Add("-$targetName")
            $arguments.Add($value)
            continue
        }

        if ($value -isnot [int]) {
            throw "Core option '$($source.Name)' for module '$($Definition.Id)' must be Int32."
        }
        $arguments.Add("-$targetName")
        $arguments.Add($value.ToString([System.Globalization.CultureInfo]::InvariantCulture))
    }

    return $arguments.ToArray()
}

function Get-WdtLaunchMode {
    param(
        [bool]$InteractiveRequested,
        [bool]$HasExplicitModuleSelection,
        [bool]$AllRequested,
        [bool]$IsInputRedirected
    )

    if ($InteractiveRequested) {
        if ($IsInputRedirected) { return 'InteractiveUnavailable' }
        return 'Interactive'
    }
    if ($AllRequested -or $HasExplicitModuleSelection) { return 'CommandLine' }
    if ($IsInputRedirected) { return 'InteractiveUnavailable' }
    return 'Interactive'
}
