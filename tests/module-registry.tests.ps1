[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\module-registry.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    $expectedArray = @($Expected)
    $actualArray = @($Actual)
    if ($expectedArray.Count -ne $actualArray.Count -or (Compare-Object $expectedArray $actualArray -SyncWindow 0)) {
        throw "$Message Expected=$($expectedArray -join ',') Actual=$($actualArray -join ',')"
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $caught = $null
    try { & $Action | Out-Null }
    catch { $caught = $_ }
    if ($null -eq $caught) { throw "$Message Expected an exception." }
    if (-not [string]::IsNullOrWhiteSpace($Pattern) -and $caught.Exception.Message -notlike $Pattern) {
        throw "$Message Unexpected error: $($caught.Exception.Message)"
    }
}

function New-FixtureRoot {
    $path = Join-Path $script:tempRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-FixtureEntrypoint {
    param([string]$ParameterBlock = @'
param(
    [switch]$Flag,
    [string]$Name,
    [int]$Count
)
'@)
    return "[CmdletBinding()]`r`n$ParameterBlock`r`n'fixture'`r`n"
}

function Get-FixtureManifest {
    param(
        [string]$Id = 'Fixture',
        [string]$EntryPoint = 'diagnostic.ps1',
        [string]$SchemaVersion = '1',
        [string]$Recommended = '$true',
        [string]$Order = '10',
        [string]$DefaultArguments = '@()',
        [string]$OptionBindings = '@{}',
        [string]$Additional = ''
    )
    return @"
@{
    SchemaVersion = $SchemaVersion
    Id = '$Id'
    Title = 'Fixture Diagnostics'
    Label = 'Fixture diagnostics'
    Description = 'Safe fixture diagnostics.'
    EntryPoint = '$EntryPoint'
    Recommended = $Recommended
    Order = $Order
    DefaultArguments = $DefaultArguments
    OptionBindings = $OptionBindings
    $Additional
}
"@
}

function Add-FixtureModule {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Slug = 'fixture',
        [AllowNull()][string]$Manifest,
        [AllowNull()][string]$Entrypoint = (Get-FixtureEntrypoint),
        [string]$EntrypointName = 'diagnostic.ps1',
        [switch]$SkipEntrypoint
    )
    $directory = Join-Path $Root $Slug
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    if ([string]::IsNullOrEmpty($Manifest)) { $Manifest = Get-FixtureManifest }
    [IO.File]::WriteAllText((Join-Path $directory 'module.psd1'), $Manifest)
    if (-not $SkipEntrypoint) { [IO.File]::WriteAllText((Join-Path $directory $EntrypointName), $Entrypoint) }
    return $directory
}

function New-CoreOptions {
    param(
        [object]$NoExternal = $false,
        [object]$Dns = 'www.microsoft.com',
        [object]$Https = 'https://www.microsoft.com/',
        [object]$Icmp = '1.1.1.1'
    )
    return @{
        NoExternalNetworkTests = $NoExternal
        NetworkDnsTestName = $Dns
        NetworkHttpsEndpoint = $Https
        NetworkIcmpTarget = $Icmp
    }
}

function Get-ParameterAst {
    param([Parameter(Mandatory = $true)][string]$Declaration)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput("[CmdletBinding()] param($Declaration)", [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw $errors[0].Message }
    return $ast.ParamBlock.Parameters[0]
}

$tempRoot = Join-Path $env:TEMP ('wdt-module-registry-tests-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $production = Get-WdtModuleRegistry -ModuleRoot (Join-Path $repositoryRoot 'modules')
    $expectedIds = @('System','Security','Performance','Network','Time','Disk','Crashes','Events','Services','Updates')
    Assert-Equal $expectedIds @($production.Modules | ForEach-Object { [string]$_.Id }) 'Production module order changed.'
    Assert-Equal 10 $production.Modules.Count 'Production registry count is incorrect.'
    Assert-Equal 10 $production.ById.Count 'Production ID lookup count is incorrect.'
    Assert-Equal 7 @($production.Modules | Where-Object { [bool]$_.Recommended }).Count 'Recommended module set changed.'
    foreach ($definition in $production.Modules) {
        foreach ($field in @('SchemaVersion','Id','Title','Label','Description','EntryPoint','Recommended','Order','DefaultArguments','OptionBindings','ManifestPath','ModuleDirectory','ScriptPaths')) {
            Assert-True $definition.ContainsKey($field) "Normalized definition is missing $field for $($definition.Id)."
        }
        Assert-True ([IO.Path]::IsPathRooted([string]$definition.EntryPoint)) "Entrypoint is not absolute for $($definition.Id)."
        Assert-True (Test-Path -LiteralPath $definition.EntryPoint -PathType Leaf) "Entrypoint is missing for $($definition.Id)."
        Assert-True ($definition.ScriptPaths -contains $definition.EntryPoint) "Entrypoint is absent from ScriptPaths for $($definition.Id)."
    }
    $moduleList = [System.Collections.IList]$production.Modules
    Assert-True $moduleList.IsReadOnly 'Registry module collection does not report read-only state.'
    Assert-Throws { $production['Modules'] = $null } '' 'Registry snapshot dictionary is mutable.'
    Assert-Throws { $moduleList.Add($production.Modules[0]) } '' 'Registry module collection is mutable.'
    Assert-Throws { $production.ById['System'] = $null } '' 'Registry ID lookup is mutable.'
    Assert-Throws { $production.Modules[0]['Id'] = 'Changed' } '' 'Registry definition is mutable.'
    Assert-Throws { $production.ById['System'].DefaultArguments.Add('-Changed') } '' 'DefaultArguments is mutable.'
    Assert-Throws { $production.ById['Network'].OptionBindings['NetworkDnsTestName'] = 'Changed' } '' 'OptionBindings is mutable.'
    Assert-Throws { $production.Modules[0].ScriptPaths.Add('x.ps1') } '' 'ScriptPaths is mutable.'

    $root = New-FixtureRoot
    $package = Add-FixtureModule -Root $root
    New-Item -ItemType Directory -Path (Join-Path $package 'helpers') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $package 'helpers\shared.ps1'), "function Get-FixtureValue { 'ok' }")
    $fixture = Get-WdtModuleRegistry -ModuleRoot $root
    Assert-Equal 1 $fixture.Modules.Count 'Valid fixture was not discovered.'
    Assert-Equal 2 $fixture.Modules[0].ScriptPaths.Count 'Module-local helper was not discovered.'

    $trailingRoot = New-FixtureRoot
    Add-FixtureModule -Root $trailingRoot | Out-Null
    $trimmedTrailingRoot = $trailingRoot.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    foreach ($separator in @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) {
        $trailingRegistry = Get-WdtModuleRegistry -ModuleRoot ($trimmedTrailingRoot + $separator)
        Assert-Equal @('Fixture') @($trailingRegistry.Modules | ForEach-Object { [string]$_.Id }) "ModuleRoot with trailing separator '$separator' was rejected."
    }

    $mixedRoot = New-FixtureRoot
    $mixedManifest = @'
@{
    schemaversion = 1
    ID = 'Mixed'
    title = 'Mixed Diagnostics'
    LABEL = 'Mixed diagnostics'
    description = 'Mixed-case keys.'
    ENTRYPOINT = 'diagnostic.ps1'
    recommended = $true
    ORDER = 12
    defaultarguments = @()
    optionbindings = @{}
}
'@
    Add-FixtureModule -Root $mixedRoot -Manifest $mixedManifest | Out-Null
    $mixed = Get-WdtModuleRegistry -ModuleRoot $mixedRoot
    Assert-Equal 'Mixed' $mixed.Modules[0].Id 'Mixed-case manifest keys were not normalized.'
    Assert-True $mixed.Modules[0].ContainsKey('SchemaVersion') 'Canonical normalized key is missing.'

    $emptyRoot = New-FixtureRoot
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $emptyRoot } '*no*module*' 'Empty registry must fail.'

    $missingKeyRoot = New-FixtureRoot
    Add-FixtureModule -Root $missingKeyRoot -Manifest ((Get-FixtureManifest) -replace "(?m)^\s*Description\s*=.*\r?\n", '') | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $missingKeyRoot } '*Description*' 'Missing manifest key was accepted.'

    $unknownKeyRoot = New-FixtureRoot
    Add-FixtureModule -Root $unknownKeyRoot -Manifest (Get-FixtureManifest -Additional "Unexpected = 'value'") | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $unknownKeyRoot } '*Unexpected*' 'Unknown manifest key was accepted.'

    $duplicateKeyRoot = New-FixtureRoot
    Add-FixtureModule -Root $duplicateKeyRoot -Manifest ((Get-FixtureManifest) -replace "(?m)^\s*Id\s*=\s*'Fixture'", "    Id = 'Fixture'`r`n    id = 'Duplicate'") | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $duplicateKeyRoot } '*duplicate*' 'Case-insensitive duplicate manifest key was accepted.'

    foreach ($invalidCase in @(
            [pscustomobject]@{ Name='Schema'; Manifest=(Get-FixtureManifest -SchemaVersion '2'); Pattern='*SchemaVersion*' },
            [pscustomobject]@{ Name='Id'; Manifest=(Get-FixtureManifest -Id 'bad-id'); Pattern='*Id*' },
            [pscustomobject]@{ Name='LowercaseId'; Manifest=(Get-FixtureManifest -Id 'fixture'); Pattern='*Id*' },
            [pscustomobject]@{ Name='ShortId'; Manifest=(Get-FixtureManifest -Id 'A'); Pattern='*Id*' },
            [pscustomobject]@{ Name='LongId'; Manifest=(Get-FixtureManifest -Id ('A' + ('b' * 32))); Pattern='*Id*' },
            [pscustomobject]@{ Name='Boolean'; Manifest=(Get-FixtureManifest -Recommended "'true'"); Pattern='*Recommended*' },
            [pscustomobject]@{ Name='Order'; Manifest=(Get-FixtureManifest -Order "'10'"); Pattern='*Order*' },
            [pscustomobject]@{ Name='Arguments'; Manifest=(Get-FixtureManifest -DefaultArguments "'-Flag'"); Pattern='*DefaultArguments*' },
            [pscustomobject]@{ Name='BlankArgument'; Manifest=(Get-FixtureManifest -DefaultArguments "@('   ')"); Pattern='*DefaultArguments*' },
            [pscustomobject]@{ Name='ParenthesizedInteger'; Manifest=(Get-FixtureManifest -SchemaVersion '(1)'); Pattern='*SchemaVersion*literal*' },
            [pscustomobject]@{ Name='CastInteger'; Manifest=(Get-FixtureManifest -Order '[int]10'); Pattern='*Order*literal*' },
            [pscustomobject]@{ Name='ParenthesizedString'; Manifest=((Get-FixtureManifest) -replace "Title = 'Fixture Diagnostics'", "Title = ('Fixture Diagnostics')"); Pattern='*Title*literal*' },
            [pscustomobject]@{ Name='NestedArgument'; Manifest=(Get-FixtureManifest -DefaultArguments "@(@('-Flag'))"); Pattern='*DefaultArguments*literal*' },
            [pscustomobject]@{ Name='BindingExpression'; Manifest=(Get-FixtureManifest -OptionBindings "@{ NetworkDnsTestName = ('Name') }"); Pattern='*OptionBindings*literal*' },
            [pscustomobject]@{ Name='ScriptBlock'; Manifest=((Get-FixtureManifest) -replace "Description = 'Safe fixture diagnostics.'", 'Description = { Get-Date }'); Pattern='*Description*' }
        )) {
        $invalidRoot = New-FixtureRoot
        Add-FixtureModule -Root $invalidRoot -Manifest $invalidCase.Manifest | Out-Null
        Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $invalidRoot } $invalidCase.Pattern "$($invalidCase.Name) manifest value was accepted."
    }

    $absoluteRoot = New-FixtureRoot
    Add-FixtureModule -Root $absoluteRoot -Manifest (Get-FixtureManifest -EntryPoint 'C:\Windows\fixture.ps1') | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $absoluteRoot } '*relative*' 'Absolute entrypoint was accepted.'

    $traversalRoot = New-FixtureRoot
    [IO.File]::WriteAllText((Join-Path $traversalRoot 'outside.ps1'), "'outside'")
    Add-FixtureModule -Root $traversalRoot -Manifest (Get-FixtureManifest -EntryPoint '..\outside.ps1') -SkipEntrypoint | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $traversalRoot } '*..*' 'Traversal entrypoint was accepted.'

    $extensionRoot = New-FixtureRoot
    Add-FixtureModule -Root $extensionRoot -Manifest (Get-FixtureManifest -EntryPoint 'diagnostic.txt') -EntrypointName 'diagnostic.txt' | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $extensionRoot } '*.ps1*' 'Non-PowerShell entrypoint was accepted.'

    $missingScriptRoot = New-FixtureRoot
    Add-FixtureModule -Root $missingScriptRoot -SkipEntrypoint | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $missingScriptRoot } '*diagnostic.ps1*' 'Missing entrypoint was accepted.'

    $entryPointCaseRoot = New-FixtureRoot
    $entryPointCasePackage = Add-FixtureModule -Root $entryPointCaseRoot -Manifest (Get-FixtureManifest -EntryPoint 'DIAGNOSTIC.ps1')
    $entryPointCaseRegistry = Get-WdtModuleRegistry -ModuleRoot $entryPointCaseRoot
    $expectedEntryPointPath = [IO.Path]::GetFullPath((Join-Path $entryPointCasePackage 'diagnostic.ps1'))
    Assert-True $entryPointCaseRegistry.Modules[0].EntryPoint.Equals($expectedEntryPointPath, [StringComparison]::Ordinal) 'Entrypoint casing was not normalized to the discovered ScriptPaths value.'

    $duplicateIdRoot = New-FixtureRoot
    Add-FixtureModule -Root $duplicateIdRoot -Slug 'one' -Manifest (Get-FixtureManifest -Id 'Duplicate') | Out-Null
    Add-FixtureModule -Root $duplicateIdRoot -Slug 'two' -Manifest (Get-FixtureManifest -Id 'duplicate') | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $duplicateIdRoot } '*duplicate*' 'Case-insensitive duplicate module IDs were accepted.'

    $bindingCases = @(
        [pscustomobject]@{ Name='UnknownSource'; Bindings="@{ UnknownOption = 'Flag' }"; Params='param([switch]$Flag)'; Pattern='*UnknownOption*' },
        [pscustomobject]@{ Name='UnsafeTarget'; Bindings="@{ NoExternalNetworkTests = 'Bad-Target' }"; Params='param([switch]$Flag)'; Pattern='*Bad-Target*' },
        [pscustomobject]@{ Name='MissingTarget'; Bindings="@{ NoExternalNetworkTests = 'Missing' }"; Params='param([switch]$Flag)'; Pattern='*Missing*' },
        [pscustomobject]@{ Name='BooleanToBool'; Bindings="@{ NoExternalNetworkTests = 'Flag' }"; Params='param([bool]$Flag)'; Pattern='*Boolean*' },
        [pscustomobject]@{ Name='StringToInt'; Bindings="@{ NetworkDnsTestName = 'Count' }"; Params='param([int]$Count)'; Pattern='*String*' },
        [pscustomobject]@{ Name='AliasOnly'; Bindings="@{ NetworkDnsTestName = 'AliasName' }"; Params="param([Alias('AliasName')][string]`$Name)"; Pattern='*AliasName*' },
        [pscustomobject]@{ Name='DuplicateTarget'; Bindings="@{ NetworkDnsTestName = 'Name'; NetworkHttpsEndpoint = 'name' }"; Params='param([string]$Name)'; Pattern='*duplicate*target*' },
        [pscustomobject]@{ Name='TrueSwitchDefault'; Bindings="@{ NoExternalNetworkTests = 'Flag' }"; Params='param([switch]$Flag = $true)'; Pattern='*Boolean*' }
    )
    foreach ($bindingCase in $bindingCases) {
        $bindingRoot = New-FixtureRoot
        Add-FixtureModule -Root $bindingRoot -Manifest (Get-FixtureManifest -OptionBindings $bindingCase.Bindings) -Entrypoint (Get-FixtureEntrypoint -ParameterBlock $bindingCase.Params) | Out-Null
        Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $bindingRoot } $bindingCase.Pattern "$($bindingCase.Name) binding was accepted."
    }

    $nestedTargetRoot = New-FixtureRoot
    $nestedSource = @'
param()
function Invoke-Nested { param([switch]$Flag) }
'@
    Add-FixtureModule -Root $nestedTargetRoot -Manifest (Get-FixtureManifest -OptionBindings "@{ NoExternalNetworkTests = 'Flag' }") -Entrypoint (Get-FixtureEntrypoint -ParameterBlock $nestedSource) | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $nestedTargetRoot } '*Flag*' 'Nested function parameter was accepted as an entrypoint target.'

    $validBindingRoot = New-FixtureRoot
    Add-FixtureModule -Root $validBindingRoot -Manifest (Get-FixtureManifest -OptionBindings "@{ NoExternalNetworkTests = 'flag'; NetworkDnsTestName = 'name' }") | Out-Null
    $validBinding = Get-WdtModuleRegistry -ModuleRoot $validBindingRoot
    Assert-Equal 'Flag' $validBinding.Modules[0].OptionBindings['NoExternalNetworkTests'] 'Target casing was not normalized.'
    Assert-True (Test-WdtOptionBindingType -SourceKind Boolean -ParameterAst (Get-ParameterAst '[switch]$Flag')) 'Boolean to switch compatibility failed.'
    Assert-True (-not (Test-WdtOptionBindingType -SourceKind Boolean -ParameterAst (Get-ParameterAst '[bool]$Flag'))) 'Boolean to bool compatibility was accepted.'
    Assert-True (Test-WdtOptionBindingType -SourceKind String -ParameterAst (Get-ParameterAst '[string]$Name')) 'String compatibility failed.'
    Assert-True (Test-WdtOptionBindingType -SourceKind Integer -ParameterAst (Get-ParameterAst '[int]$Count')) 'Integer compatibility failed.'
    Assert-True (-not (Test-WdtOptionBindingType -SourceKind Integer -ParameterAst (Get-ParameterAst '[long]$Count'))) 'Integer to Int64 compatibility was accepted.'

    $orphanRoot = New-FixtureRoot
    Add-FixtureModule -Root $orphanRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $orphanRoot 'orphan.ps1'), "'orphan'")
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $orphanRoot } '*orphan.ps1*' 'Root-level orphan script was accepted.'

    $noManifestRoot = New-FixtureRoot
    $noManifestPackage = Join-Path $noManifestRoot 'missing'
    New-Item -ItemType Directory -Path $noManifestPackage -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $noManifestPackage 'helper.ps1'), "'orphan'")
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $noManifestRoot } '*module.psd1*' 'Module directory without manifest was accepted.'

    $selected = @(Resolve-WdtModuleSelection -Registry $production -ModuleIds @('network','SYSTEM','Network') -LegacySelections @{ Disk = $true } -AllRequested:$false)
    Assert-Equal @('System','Network','Disk') @($selected | ForEach-Object { [string]$_.Id }) 'Generic and legacy selection was not normalized to registry order.'
    Assert-Equal 0 @(Resolve-WdtModuleSelection -Registry $production -ModuleIds @() -LegacySelections @{} -AllRequested:$false).Count 'Empty selection should remain empty.'
    Assert-Equal 10 @(Resolve-WdtModuleSelection -Registry $production -ModuleIds @() -LegacySelections @{} -AllRequested:$true).Count '-All did not select the complete registry.'
    Assert-Throws { Resolve-WdtModuleSelection -Registry $production -ModuleIds @('Unknown') -LegacySelections @{} -AllRequested:$true } '*Unknown*' 'Unknown explicit ID was hidden by -All.'
    [string[]]$typedNullModuleIds = $null
    $legacyOnlySelection = @(Resolve-WdtModuleSelection -Registry $production -ModuleIds $typedNullModuleIds -LegacySelections @{ Disk = $true } -AllRequested:$false)
    Assert-Equal @('Disk') @($legacyOnlySelection | ForEach-Object { [string]$_.Id }) 'Typed-null ModuleIds broke legacy-only selection.'

    $network = $production.ById['Network']
    $networkArguments = @(Get-WdtModuleInvocationArguments -Definition $network -CoreOptions (New-CoreOptions -NoExternal $true -Dns 'dns.fixture' -Https 'https://fixture/' -Icmp '192.0.2.10'))
    Assert-Equal @('-NoExternalNetworkTests','-DnsTestName','dns.fixture','-HttpsEndpoint','https://fixture/','-IcmpTarget','192.0.2.10') $networkArguments 'Network argument order changed.'
    $networkFalse = @(Get-WdtModuleInvocationArguments -Definition $network -CoreOptions (New-CoreOptions -NoExternal $false))
    Assert-True ($networkFalse -notcontains '-NoExternalNetworkTests') 'False boolean binding emitted a switch.'
    $networkNull = @(Get-WdtModuleInvocationArguments -Definition $network -CoreOptions (New-CoreOptions -Dns $null))
    Assert-True ($networkNull -notcontains '-DnsTestName') 'Null string binding was not skipped.'
    Assert-Equal @('-IncludeStartup','-IncludeScheduledTasks') @(Get-WdtModuleInvocationArguments -Definition $production.ById['Services'] -CoreOptions (New-CoreOptions)) 'Services default arguments changed.'
    Assert-Throws { Get-WdtModuleInvocationArguments -Definition $network -CoreOptions @{ NoExternalNetworkTests=$false } } '*NetworkDnsTestName*' 'Missing core option did not fail.'
    Assert-Throws { Get-WdtModuleInvocationArguments -Definition $network -CoreOptions (New-CoreOptions -Dns @('bad')) } '*NetworkDnsTestName*' 'Complex core option was accepted.'

    Assert-Equal 'Interactive' (Get-WdtLaunchMode -InteractiveRequested:$false -HasExplicitModuleSelection:$false -AllRequested:$false -IsInputRedirected:$false) 'Default interactive launch changed.'
    Assert-Equal 'InteractiveUnavailable' (Get-WdtLaunchMode -InteractiveRequested:$false -HasExplicitModuleSelection:$false -AllRequested:$false -IsInputRedirected:$true) 'Redirected-input launch changed.'
    Assert-Equal 'CommandLine' (Get-WdtLaunchMode -InteractiveRequested:$false -HasExplicitModuleSelection:$true -AllRequested:$false -IsInputRedirected:$false) 'Explicit selection launch changed.'
    Assert-Equal 'Interactive' (Get-WdtLaunchMode -InteractiveRequested:$true -HasExplicitModuleSelection:$true -AllRequested:$false -IsInputRedirected:$false) 'Requested interactive launch changed.'

    $junctionTarget = New-FixtureRoot
    Add-FixtureModule -Root $junctionTarget | Out-Null
    $junctionParent = New-FixtureRoot
    $junctionPath = Join-Path $junctionParent 'fixture'
    New-Item -ItemType Junction -Path $junctionPath -Target (Join-Path $junctionTarget 'fixture') | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $junctionParent } '*reparse*' 'Junction module directory was accepted.'

    $rootJunctionParent = New-FixtureRoot
    $rootJunction = Join-Path $rootJunctionParent 'modules-link'
    New-Item -ItemType Junction -Path $rootJunction -Target $junctionTarget | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $rootJunction } '*reparse*' 'Junction module root was accepted.'

    $nestedJunctionRoot = New-FixtureRoot
    $nestedJunctionPackage = Add-FixtureModule -Root $nestedJunctionRoot
    $nestedTarget = New-FixtureRoot
    [IO.File]::WriteAllText((Join-Path $nestedTarget 'helper.ps1'), "'helper'")
    New-Item -ItemType Junction -Path (Join-Path $nestedJunctionPackage 'helpers') -Target $nestedTarget | Out-Null
    Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $nestedJunctionRoot } '*reparse*' 'Nested package junction was accepted.'

    $symlinkTarget = Join-Path $tempRoot 'symlink-target.ps1'
    [IO.File]::WriteAllText($symlinkTarget, (Get-FixtureEntrypoint))
    $symlinkRoot = New-FixtureRoot
    $symlinkPackage = Add-FixtureModule -Root $symlinkRoot -SkipEntrypoint
    $fileSymlinkAvailable = $true
    try { New-Item -ItemType SymbolicLink -Path (Join-Path $symlinkPackage 'diagnostic.ps1') -Target $symlinkTarget -ErrorAction Stop | Out-Null }
    catch {
        $fileSymlinkAvailable = $false
        if ($env:CI -eq 'true') { throw "CI must exercise file reparse validation, but the symbolic-link fixture could not be created: $($_.Exception.Message)" }
        Write-Warning "File symbolic-link fixture was not available locally; the mandatory CI case remains enabled: $($_.Exception.Message)"
    }
    if ($fileSymlinkAvailable) {
        Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $symlinkRoot } '*reparse*' 'Symlink entrypoint was accepted.'

        $helperLinkRoot = New-FixtureRoot
        $helperLinkPackage = Add-FixtureModule -Root $helperLinkRoot
        New-Item -ItemType SymbolicLink -Path (Join-Path $helperLinkPackage 'helper.ps1') -Target $symlinkTarget -ErrorAction Stop | Out-Null
        Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $helperLinkRoot } '*reparse*' 'Symlink helper was accepted.'

        $manifestLinkTarget = Join-Path $tempRoot 'symlink-target-module.psd1'
        [IO.File]::WriteAllText($manifestLinkTarget, (Get-FixtureManifest))
        $manifestLinkRoot = New-FixtureRoot
        $manifestLinkPackage = Add-FixtureModule -Root $manifestLinkRoot
        [IO.File]::Delete((Join-Path $manifestLinkPackage 'module.psd1'))
        New-Item -ItemType SymbolicLink -Path (Join-Path $manifestLinkPackage 'module.psd1') -Target $manifestLinkTarget -ErrorAction Stop | Out-Null
        Assert-Throws { Get-WdtModuleRegistry -ModuleRoot $manifestLinkRoot } '*reparse*' 'Symlink manifest was accepted.'
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

$global:LASTEXITCODE = 0
Write-Host 'Module registry tests passed.'
