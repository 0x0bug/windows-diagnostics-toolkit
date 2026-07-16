[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $repositoryRoot -ChildPath 'scripts\report-common.ps1')

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" } }
function Import-TestFunctions {
    param([string]$Path, [string[]]$Names)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 @($errors).Count "Startup module did not parse: $Path"
    foreach ($name in $Names) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        Assert-True ($null -ne $definition) "Missing startup function: $name"
        $scriptDefinition = $definition.Extent.Text -replace ('^function\s+' + [regex]::Escape($name)), ('function script:' + $name)
        Invoke-Expression $scriptDefinition
    }
}

function New-TestApprovalInventory {
    param(
        [hashtable]$Values = @{},
        [bool]$Exists = $true,
        [string]$ErrorMessage
    )

    return [pscustomobject]@{
        Path   = 'HKCU:\Fixture\StartupApproved'
        Exists = $Exists
        Values = $Values
        Error  = $ErrorMessage
    }
}

function New-TestStartupEntry {
    param(
        [string]$State,
        [string]$SourceType,
        [string]$Location,
        [string]$Name,
        [string]$Command,
        [int]$Ordinal = 0
    )

    return [pscustomobject]@{
        State       = $State
        StateSource = 'HKCU:\Fixture\StartupApproved'
        SourceType  = $SourceType
        Location    = $Location
        Name        = $Name
        Command     = $Command
        Ordinal     = $Ordinal
    }
}

$servicesScript = Join-Path -Path $repositoryRoot -ChildPath 'modules\services\diagnostic.ps1'
Import-TestFunctions -Path $servicesScript -Names @(
    'Write-ItemLimitNote',
    'ConvertTo-SafeSingleLine',
    'Get-StartupSourceDefinitions',
    'ConvertFrom-StartupApprovedValue',
    'Get-StartupApprovalInventory',
    'Resolve-StartupEntryState',
    'Get-StartupFolderSourceInventory',
    'Merge-StartupInventory',
    'Get-StartupEntriesForDisplay',
    'Write-StartupEntryRows'
)

$enabledValue = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
$disabledValue = [byte[]](3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)

# 1. The documented enabled prefix is accepted only in a complete record.
Assert-Equal 'Enabled' (ConvertFrom-StartupApprovedValue -Value $enabledValue) 'A recognized enabled record was not parsed.'

# 2. The documented disabled prefix is accepted only in a complete record.
Assert-Equal 'Disabled' (ConvertFrom-StartupApprovedValue -Value $disabledValue) 'A recognized disabled record was not parsed.'

# 3. Unknown state values stay conservative.
Assert-Equal 'Unknown' (ConvertFrom-StartupApprovedValue -Value ([byte[]](7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))) 'An unknown state prefix must remain Unknown.'

# 4. Truncated, oversized, and non-binary records stay conservative.
foreach ($invalidValue in @([byte[]](2, 0, 0, 0), [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0), '02')) {
    Assert-Equal 'Unknown' (ConvertFrom-StartupApprovedValue -Value $invalidValue) 'An invalid StartupApproved value must remain Unknown.'
}

# 5. A missing StartupApproved key does not imply enabled or disabled.
$missingKeyState = Resolve-StartupEntryState -Name 'Fixture' -ApprovalInventory (New-TestApprovalInventory -Exists $false)
Assert-Equal 'Unknown' $missingKeyState.State 'A missing StartupApproved key must remain Unknown.'
Assert-True $missingKeyState.StateSource.Contains('key missing') 'A missing key must be explained by StateSource.'

# 6. A missing matching value does not inherit another entry's state.
$missingValueState = Resolve-StartupEntryState -Name 'Missing' -ApprovalInventory (New-TestApprovalInventory -Values @{ Other = $enabledValue })
Assert-Equal 'Unknown' $missingValueState.State 'A missing StartupApproved value must remain Unknown.'
Assert-True $missingValueState.StateSource.Contains('value missing') 'A missing value must be explained by StateSource.'

# 7. A read error remains Unknown and retains source context.
$readErrorState = Resolve-StartupEntryState -Name 'Fixture' -ApprovalInventory (New-TestApprovalInventory -ErrorMessage 'fixture access denied')
Assert-Equal 'Unknown' $readErrorState.State 'An unavailable StartupApproved source must remain Unknown.'
Assert-True $readErrorState.StateSource.Contains('read failed') 'An unavailable approval source must be explained by StateSource.'

# A provider failure while checking the key is captured as source context.
function Test-Path { [CmdletBinding()] param([string]$LiteralPath); throw 'fixture provider unavailable' }
$providerErrorInventory = Get-StartupApprovalInventory -Path 'HKCU:\Fixture\StartupApproved'
Assert-True (-not [string]::IsNullOrWhiteSpace($providerErrorInventory.Error)) 'A StartupApproved provider failure must be captured.'
Assert-True $providerErrorInventory.Error.Contains('fixture provider unavailable') 'The StartupApproved provider error lost its cause.'
Remove-Item -Path Function:\Test-Path

# 8. Definitions cover Run, Run32, and both Startup folders for HKCU and HKLM.
$definitions = @(Get-StartupSourceDefinitions)
Assert-Equal 6 $definitions.Count 'The startup source inventory must contain six sources.'
Assert-Equal 4 @($definitions | Where-Object { $_.SourceType -eq 'Registry' }).Count 'Both registry views for HKCU and HKLM are required.'
Assert-Equal 2 @($definitions | Where-Object { $_.SourceType -eq 'StartupFolder' }).Count 'User and common Startup folders are required.'
Assert-Equal 2 @($definitions | Where-Object { $_.ApprovalLocation -like '*\Run32' }).Count 'Both Run32 approval sources are required.'
Assert-Equal 2 @($definitions | Where-Object { $_.ApprovalLocation -like '*\StartupFolder' }).Count 'Both StartupFolder approval sources are required.'

$temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$fixtureRoot = Join-Path -Path $temporaryRoot -ChildPath ('wdt-startup-' + [guid]::NewGuid().ToString('N'))
$temporaryRootPrefix = $temporaryRoot.TrimEnd('\') + '\'
try {
    $userFolder = Join-Path -Path $fixtureRoot -ChildPath 'UserStartup'
    $commonFolder = Join-Path -Path $fixtureRoot -ChildPath 'CommonStartup'
    New-Item -ItemType Directory -Path $userFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $commonFolder -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $userFolder 'Shared.lnk'), 'fixture', [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $commonFolder 'Shared.lnk'), 'fixture', [System.Text.Encoding]::UTF8)

    # 9. The user Startup folder is collected with its recognized state.
    $userDefinition = [pscustomobject]@{ SourceType = 'StartupFolder'; Location = $userFolder; ApprovalLocation = 'HKCU:\Fixture\StartupApproved' }
    $userInventory = Get-StartupFolderSourceInventory -Definition $userDefinition -ApprovalInventory (New-TestApprovalInventory -Values @{ 'Shared.lnk' = $enabledValue })
    Assert-Equal 1 @($userInventory.Entries).Count 'The user Startup folder fixture was not collected.'
    Assert-Equal 'Enabled' $userInventory.Entries[0].State 'The user Startup folder state was not resolved.'
    Assert-Equal 'StartupFolder' $userInventory.Entries[0].SourceType 'The user Startup folder source type is incorrect.'

    # 10. The common Startup folder is collected independently.
    $commonDefinition = [pscustomobject]@{ SourceType = 'StartupFolder'; Location = $commonFolder; ApprovalLocation = 'HKLM:\Fixture\StartupApproved' }
    $commonInventory = Get-StartupFolderSourceInventory -Definition $commonDefinition -ApprovalInventory (New-TestApprovalInventory -Values @{ 'Shared.lnk' = $disabledValue })
    Assert-Equal 1 @($commonInventory.Entries).Count 'The common Startup folder fixture was not collected.'
    Assert-Equal 'Disabled' $commonInventory.Entries[0].State 'The common Startup folder state was not resolved.'

    # 11. Equal names from different sources remain separate records.
    $combinedInventory = Merge-StartupInventory -SourceInventories @($userInventory, $commonInventory)
    Assert-Equal 2 @($combinedInventory.Entries | Where-Object { $_.Name -eq 'Shared.lnk' }).Count 'Equal names from different sources must not be merged.'

    # 12. One unavailable source does not discard entries from another source.
    $partialInventory = Merge-StartupInventory -SourceInventories @(
        $userInventory,
        [pscustomobject]@{ Entries = @(); Errors = @([pscustomobject]@{ Path = 'HKLM:\Fixture'; Error = 'fixture access denied' }) }
    )
    Assert-Equal 1 @($partialInventory.Entries).Count 'A partial source error discarded valid entries.'
    Assert-Equal 1 @($partialInventory.Errors).Count 'A partial source error was not retained as context.'

    # 13. Ordering is deterministic, preserves exact ties, and applies MaxItems globally.
    $tieOne = New-TestStartupEntry -State Enabled -SourceType Registry -Location 'B' -Name 'Same' -Command 'same' -Ordinal 1
    $tieTwo = New-TestStartupEntry -State Enabled -SourceType Registry -Location 'B' -Name 'Same' -Command 'same' -Ordinal 2
    $orderedEntries = @(Get-StartupEntriesForDisplay -Entries @(
            (New-TestStartupEntry -State Unknown -SourceType Registry -Location 'A' -Name 'Unknown' -Command 'unknown'),
            $tieOne,
            (New-TestStartupEntry -State Disabled -SourceType Registry -Location 'A' -Name 'Disabled' -Command 'disabled'),
            $tieTwo
        ) -Limit 3)
    Assert-Equal 3 $orderedEntries.Count 'MaxItems was not applied to the startup inventory.'
    Assert-Equal 1 $orderedEntries[0].Ordinal 'The first exact tie did not preserve input order.'
    Assert-Equal 2 $orderedEntries[1].Ordinal 'The second exact tie did not preserve input order.'
    Assert-Equal 'Disabled' $orderedEntries[2].State 'State ordering must place Disabled after Enabled and before Unknown.'

    # 14. Output exposes state provenance without turning Disabled or Unknown into findings, and Privacy Mode redacts the command line.
    $displayInventory = [pscustomobject]@{
        Entries = @(
            (New-TestStartupEntry -State Disabled -SourceType Registry -Location 'HKCU:\Fixture' -Name 'Fixture' -Command 'fixture.exe --token=super-secret'),
            (New-TestStartupEntry -State Unknown -SourceType StartupFolder -Location $userFolder -Name 'Unknown.lnk' -Command (Join-Path $userFolder 'Unknown.lnk'))
        )
        Errors = @()
    }
    $displayText = @(Write-StartupEntryRows -Inventory $displayInventory -Limit 10 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
    foreach ($label in @('State', 'State source', 'Source type', 'Location', 'Name', 'Startup Command Line')) {
        Assert-True $displayText.Contains($label) "Startup output is missing '$label'."
    }
    Assert-True (-not $displayText.Contains('@@WDT_FINDING@@')) 'Disabled and Unknown startup states must not emit findings.'
    Assert-True (-not ($displayText -match '(?m)^\s*\[?WARN\]?')) 'Disabled and Unknown startup states must not emit warnings.'
    $privacyContext = New-WdtRedactionContext -ComputerName '' -UserName '' -UserDomain '' -UserProfile ''
    $protectedDisplay = Protect-WdtText -Text $displayText -Context $privacyContext
    Assert-True (-not $protectedDisplay.Contains('super-secret')) 'Privacy Mode leaked a startup command line.'
    Assert-True $protectedDisplay.Contains('fixture.exe --token=<REDACTED>') 'Privacy Mode did not preserve the executable while redacting the startup command secret.'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedFixtureRoot = (Resolve-Path -LiteralPath $fixtureRoot).Path
        if (-not $resolvedFixtureRoot.StartsWith($temporaryRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a startup fixture outside the temporary root: $resolvedFixtureRoot"
        }

        Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force
    }
}

if (Test-Path -LiteralPath $fixtureRoot) {
    throw 'Startup inventory fixture directory was not removed.'
}

Write-Host 'Startup inventory tests passed.'
