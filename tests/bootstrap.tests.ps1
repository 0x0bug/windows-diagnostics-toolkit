[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw ("{0} Expected: '{1}'. Actual: '{2}'." -f $Message, $Expected, $Actual)
    }
}

function Get-ContainingFunctionName {
    param([System.Management.Automation.Language.Ast]$Node)

    $current = $Node.Parent
    while ($null -ne $current) {
        if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $current.Name
        }
        $current = $current.Parent
    }

    return $null
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$bootstrapPath = Join-Path -Path $repositoryRoot -ChildPath 'tools\bootstrap.ps1'
$readmePath = Join-Path -Path $repositoryRoot -ChildPath 'README.md'

Assert-True (Test-Path -LiteralPath $bootstrapPath -PathType Leaf) 'Bootstrap script is missing.'

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($bootstrapPath, [ref]$tokens, [ref]$parseErrors)
Assert-True (@($parseErrors).Count -eq 0) ('Bootstrap did not parse in this PowerShell version: {0}' -f (($parseErrors | ForEach-Object Message) -join '; '))

$locationBeforeDotSource = (Get-Location).Path
$securityProtocolBeforeDotSource = [System.Net.ServicePointManager]::SecurityProtocol
. $bootstrapPath
Assert-Equal $locationBeforeDotSource (Get-Location).Path 'Dot-sourcing bootstrap changed the working directory.'
Assert-Equal $securityProtocolBeforeDotSource ([System.Net.ServicePointManager]::SecurityProtocol) 'Dot-sourcing bootstrap changed the process TLS setting.'

Assert-True (Test-WdtBootstrapPowerShellVersion -Version ([version]'5.1')) 'PowerShell 5.1 must be supported.'
Assert-True (Test-WdtBootstrapPowerShellVersion -Version ([version]'7.0')) 'PowerShell 7 must be supported.'
Assert-True (-not (Test-WdtBootstrapPowerShellVersion -Version ([version]'5.0'))) 'PowerShell versions below 5.1 must be rejected.'

$expectedDownloadUri = 'https://github.com/0x0bug/windows-diagnostics-toolkit/archive/refs/heads/main.zip'
$downloadUri = [uri](Get-WdtBootstrapDownloadUri)
Assert-Equal $expectedDownloadUri $downloadUri.AbsoluteUri 'Bootstrap download URL is not fixed to repository main.zip.'
Assert-Equal 'github.com' $downloadUri.Host 'Bootstrap download host is not GitHub.'
Assert-True ($downloadUri.AbsolutePath -eq '/0x0bug/windows-diagnostics-toolkit/archive/refs/heads/main.zip') 'Bootstrap repository or ref is not fixed.'

Assert-True ($null -ne $ast.ParamBlock) 'Bootstrap must declare an explicit top-level parameter block.'
Assert-True (@($ast.ParamBlock.Parameters).Count -eq 0) 'Bootstrap must not accept a user-supplied URL or other top-level parameters.'

$stringLiterals = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true))
$httpLiterals = @($stringLiterals | Where-Object { $_.Value -match '^https?://' })
Assert-Equal 1 $httpLiterals.Count 'Bootstrap must contain exactly one network URL literal.'
Assert-Equal $expectedDownloadUri $httpLiterals[0].Value 'Bootstrap contains an unexpected network URL.'

$commands = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true))
$commandNames = @($commands | ForEach-Object { $_.GetCommandName() } | Where-Object { $null -ne $_ })

$restCommands = @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-RestMethod' })
Assert-Equal 1 $restCommands.Count 'Bootstrap must use exactly one Invoke-RestMethod download.'
Assert-True ($restCommands[0].Extent.Text -match '(?i)-OutFile\s+\$archivePath') 'Download must write the ZIP to the owned workspace.'
Assert-True ($restCommands[0].Extent.Text -match '(?i)-ErrorAction\s+Stop') 'Download must stop on network errors.'

$forbiddenCommands = @(
    'Invoke-Expression', 'iex', 'Start-Process', 'Invoke-WebRequest',
    'Set-ExecutionPolicy', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty',
    'Start-Service', 'Stop-Service', 'Set-Service', 'New-Service',
    'Register-ScheduledTask', 'Unregister-ScheduledTask', 'Set-NetFirewallProfile',
    'Add-MpPreference', 'Set-MpPreference', 'reg.exe', 'sc.exe', 'schtasks.exe',
    'powershell.exe', 'pwsh.exe', 'cmd.exe'
)
foreach ($forbiddenCommand in $forbiddenCommands) {
    Assert-True ($forbiddenCommand -notin $commandNames) ("Bootstrap contains forbidden command: {0}" -f $forbiddenCommand)
}

$dynamicCodePatterns = @(
    '[scriptblock]::Create',
    '.InvokeScript(',
    '.AddScript('
)
foreach ($pattern in $dynamicCodePatterns) {
    Assert-True (-not $ast.Extent.Text.Contains($pattern)) ("Bootstrap contains dynamic code execution pattern: {0}" -f $pattern)
}

$tempBasePath = Get-WdtBootstrapTempBasePath -TempPath $env:TEMP
$identifier = [guid]'01234567-89ab-cdef-0123-456789abcdef'
$tempRootPath = Get-WdtBootstrapTempRootPath -TempBasePath $tempBasePath -Identifier $identifier
Assert-True (Test-WdtBootstrapPathWithin -CandidatePath $tempRootPath -RootPath $tempBasePath) 'Generated bootstrap workspace is not contained by TEMP.'
Assert-True (Test-WdtBootstrapOwnedTempRoot -Path $tempRootPath -TempBasePath $tempBasePath) 'Generated bootstrap workspace does not satisfy the cleanup ownership boundary.'
Assert-True ((Split-Path -Path $tempRootPath -Leaf) -eq 'wdt-bootstrap-0123456789abcdef0123456789abcdef') 'Bootstrap workspace name is not unique-GUID based.'

$siblingPath = Join-Path -Path $tempBasePath -ChildPath 'wdt-bootstrap-not-owned'
Assert-True (-not (Test-WdtBootstrapOwnedTempRoot -Path $siblingPath -TempBasePath $tempBasePath)) 'Cleanup boundary accepted a non-GUID sibling path.'
$outsidePath = [System.IO.Path]::GetFullPath((Join-Path -Path $tempBasePath -ChildPath '..\wdt-bootstrap-0123456789abcdef0123456789abcdef'))
Assert-True (-not (Test-WdtBootstrapOwnedTempRoot -Path $outsidePath -TempBasePath $tempBasePath)) 'Cleanup boundary accepted a path outside TEMP.'

$expectedRequiredFiles = @(
    'Invoke-WindowsDiagnostics.ps1'
    'scripts\validate.ps1'
    'scripts\validation-policy.ps1'
    'scripts\tui.ps1'
)
$requiredFiles = @(Get-WdtBootstrapRequiredFile)
Assert-Equal ($expectedRequiredFiles -join '|') ($requiredFiles -join '|') 'Bootstrap required-file inventory changed unexpectedly.'
Assert-Equal 0 @(Get-WdtBootstrapMissingRequiredFile -RelativePaths $requiredFiles).Count 'A complete toolkit layout was rejected.'
foreach ($requiredFile in $requiredFiles) {
    $incompleteFiles = @($requiredFiles | Where-Object { $_ -ne $requiredFile })
    $missingFiles = @(Get-WdtBootstrapMissingRequiredFile -RelativePaths $incompleteFiles)
    Assert-Equal 1 $missingFiles.Count ("Removing required file '{0}' did not invalidate the toolkit layout." -f $requiredFile)
    Assert-Equal $requiredFile $missingFiles[0] 'Toolkit layout reported the wrong missing file.'
}

Assert-True (Test-WdtBootstrapSingleArchiveRoot -Items @([pscustomobject]@{ PSIsContainer = $true })) 'A single archive root directory must be accepted.'
Assert-True (-not (Test-WdtBootstrapSingleArchiveRoot -Items @())) 'An empty archive must be rejected.'
Assert-True (-not (Test-WdtBootstrapSingleArchiveRoot -Items @(
                [pscustomobject]@{ PSIsContainer = $true },
                [pscustomobject]@{ PSIsContainer = $true }
            ))) 'An archive with multiple roots must be rejected.'
Assert-True (-not (Test-WdtBootstrapSingleArchiveRoot -Items @([pscustomobject]@{ PSIsContainer = $false }))) 'An archive with a root file must be rejected.'

$callerDirectory = Join-Path -Path $tempBasePath -ChildPath 'wdt-bootstrap-test-caller'
$outputDirectory = Get-WdtBootstrapInitialOutputDirectory -CallerDirectory $callerDirectory
Assert-Equal 'WindowsDiagnosticsReports' (Split-Path -Path $outputDirectory -Leaf) 'Initial report directory has an unexpected name.'
Assert-True (Test-WdtBootstrapPathWithin -CandidatePath $outputDirectory -RootPath $callerDirectory) 'Initial report directory is not based on the caller directory.'
Assert-True (-not (Test-WdtBootstrapPathWithin -CandidatePath $outputDirectory -RootPath $tempRootPath)) 'Initial report directory is inside the disposable bootstrap workspace.'

$removeCommands = @($commands | Where-Object { $_.GetCommandName() -eq 'Remove-Item' })
Assert-Equal 1 $removeCommands.Count 'Bootstrap cleanup must have exactly one Remove-Item call.'
Assert-Equal 'Remove-WdtBootstrapTempRoot' (Get-ContainingFunctionName -Node $removeCommands[0]) 'Remove-Item is outside the guarded cleanup helper.'
Assert-True ($removeCommands[0].Extent.Text -match '(?i)-LiteralPath\s+\$Path') 'Cleanup must remove only its validated path parameter.'
Assert-True ($removeCommands[0].Extent.Text -match '(?i)-Recurse') 'Cleanup must remove the complete temporary workspace.'
Assert-True ($removeCommands[0].Extent.Text -match '(?i)-ErrorAction\s+Stop') 'Cleanup errors must be catchable.'

$cleanupFunction = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-WdtBootstrapTempRoot'
        }, $true))
Assert-Equal 1 $cleanupFunction.Count 'Guarded cleanup helper is missing.'
Assert-True ($cleanupFunction[0].Extent.Text.Contains('Test-WdtBootstrapOwnedTempRoot')) 'Cleanup helper does not enforce the owned TEMP boundary.'
Assert-True (-not $cleanupFunction[0].Extent.Text.Contains('$PSCommandPath')) 'Cleanup must not remove the user-created bootstrap script.'

$entrypointInvocations = @($commands | Where-Object {
        $_.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
        $_.Extent.Text -match '^&\s+\$entrypointPath\b'
    })
Assert-Equal 1 $entrypointInvocations.Count 'Downloaded entrypoint invocation is missing or ambiguous.'
Assert-True ($entrypointInvocations[0].Extent.Text -match '(?i)-Interactive\b') 'Downloaded entrypoint is not launched in interactive mode.'
Assert-True ($entrypointInvocations[0].Extent.Text -match '(?i)-OutputDirectory\s+\$outputDirectory') 'Downloaded entrypoint does not receive the caller-based output directory.'

$validationInvocations = @($commands | Where-Object {
        $_.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
        $_.Extent.Text -match '^&\s+\$validationPath\b'
    })
Assert-Equal 1 $validationInvocations.Count 'Downloaded validation script invocation is missing or ambiguous.'
Assert-True ($ast.Extent.Text -match '(?s)&\s+\$validationPath.*?\$LASTEXITCODE\s+-ne\s+0') 'Bootstrap does not stop after a failed downloaded validation.'

Assert-True ($ast.Extent.Text -match '(?s)finally\s*\{.*ServicePointManager\]::SecurityProtocol\s*=\s*\$originalSecurityProtocol') 'Bootstrap does not restore a process-local TLS change in finally.'
Assert-True ($ast.Extent.Text -match '(?s)finally\s*\{.*Remove-WdtBootstrapTempRoot') 'Bootstrap does not clean its temporary workspace in finally.'

$readme = Get-Content -LiteralPath $readmePath -Raw
$rawBootstrapUrl = 'https://raw.githubusercontent.com/0x0bug/windows-diagnostics-toolkit/main/tools/bootstrap.ps1'
$remoteLaunchLines = @($readme -split "`r?`n" | Where-Object { $_.Contains($rawBootstrapUrl) })
Assert-True ($remoteLaunchLines.Count -ge 1) 'README does not contain the fixed remote bootstrap URL.'
Assert-True (@($remoteLaunchLines | Where-Object { $_ -match '(?i)\birm\b' -and $_ -match '(?i)-OutFile\s+\$p' -and $_ -match '&\s*\$p' }).Count -ge 1) 'README remote launch must download to a file and then execute that file.'
Assert-True ($readme -notmatch '(?im)\birm\b[^\r\n]*\|\s*(iex|Invoke-Expression)\b') 'README must not recommend piping irm into Invoke-Expression.'

Write-Host 'Bootstrap tests passed.'
