[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-RepositoryRoot {
    if ($PSScriptRoot) {
        return (Split-Path -Parent $PSScriptRoot)
    }

    return (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
}

function Get-RelativeDisplayPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $baseUri = New-Object -TypeName System.Uri -ArgumentList (($BasePath.TrimEnd('\') + '\'))
    $targetUri = New-Object -TypeName System.Uri -ArgumentList $TargetPath
    $relativePath = $baseUri.MakeRelativeUri($targetUri).ToString()
    return [System.Uri]::UnescapeDataString($relativePath).Replace('/', '\')
}

function Get-ProductionScript {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]$RegistrySnapshot
    )

    $scripts = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $seenPaths = @{}
    $entrypoint = Join-Path -Path $RepositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1'
    if (Test-Path -LiteralPath $entrypoint -PathType Leaf) {
        $entrypointItem = Get-Item -LiteralPath $entrypoint
        $scripts.Add($entrypointItem)
        $seenPaths[$entrypointItem.FullName] = $true
    }

    $scriptsDirectory = Join-Path -Path $RepositoryRoot -ChildPath 'scripts'
    if (Test-Path -LiteralPath $scriptsDirectory -PathType Container) {
        foreach ($script in @(Get-RepositoryChildItem -RootPath $scriptsDirectory | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.ps1' } | Sort-Object -Property FullName)) {
            if (-not $seenPaths.ContainsKey($script.FullName)) {
                $scripts.Add($script)
                $seenPaths[$script.FullName] = $true
            }
        }
    }

    foreach ($definition in @($RegistrySnapshot.Modules)) {
        foreach ($scriptPath in @($definition.ScriptPaths)) {
            $script = Get-Item -LiteralPath $scriptPath
            if (-not $seenPaths.ContainsKey($script.FullName)) {
                $scripts.Add($script)
                $seenPaths[$script.FullName] = $true
            }
        }
    }

    return @($scripts.ToArray())
}

function Get-ParserIssue {
    param(
        [Parameter(Mandatory = $true)]$ParseErrors,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    foreach ($parseError in @($ParseErrors)) {
        [pscustomobject]@{
            Type    = 'Parser'
            Path    = Get-RelativeDisplayPath -BasePath $RepositoryRoot -TargetPath $ScriptPath
            Line    = $parseError.Extent.StartLineNumber
            Column  = $parseError.Extent.StartColumnNumber
            Message = $parseError.Message
        }
    }
}

function Get-SafetyIssue {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]$RegistrySnapshot,
        $ModuleDefinition,
        [string[]]$PackageFunctionNames = @()
    )

    foreach ($issue in @(Get-WdtSafetyIssues -Ast $Ast -ScriptPath $ScriptPath -RepositoryRoot $RepositoryRoot -RegistrySnapshot $RegistrySnapshot -ModuleDefinition $ModuleDefinition -PackageFunctionNames $PackageFunctionNames)) {
        [pscustomobject]@{
            Type    = $issue.Type
            Path    = Get-RelativeDisplayPath -BasePath $RepositoryRoot -TargetPath $ScriptPath
            Line    = $issue.Line
            Column  = $issue.Column
            Command = $issue.Command
            Message = $issue.Message
        }
    }
}

function Get-RepositoryChildItem {
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $rootItem = Get-Item -LiteralPath $RootPath
    $directories = New-Object 'System.Collections.Generic.Queue[System.IO.DirectoryInfo]'
    $directories.Enqueue($rootItem)

    while ($directories.Count -gt 0) {
        $directory = $directories.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue)) {
            if ($item.PSIsContainer) {
                if ($item.Name -eq '.git') {
                    continue
                }

                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Write-Output $item
                    continue
                }

                $directories.Enqueue($item)
            }

            Write-Output $item
        }
    }
}

function Get-ModuleLayoutIssue {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]$RegistrySnapshot
    )

    $moduleRoot = Join-Path -Path $RepositoryRoot -ChildPath 'modules'
    foreach ($item in @(Get-RepositoryChildItem -RootPath $moduleRoot)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            [pscustomobject]@{
                Type    = 'Layout'
                Path    = Get-RelativeDisplayPath -BasePath $RepositoryRoot -TargetPath $item.FullName
                Message = 'Reparse points are not permitted in the production module tree.'
            }
            continue
        }
        if ($item.PSIsContainer -or $item.Extension -ine '.ps1') { continue }

        $classification = Get-WdtModuleScriptClassification -ScriptPath $item.FullName -RegistrySnapshot $RegistrySnapshot
        if ($classification -eq 'Orphan') {
            [pscustomobject]@{
                Type    = 'Layout'
                Path    = Get-RelativeDisplayPath -BasePath $RepositoryRoot -TargetPath $item.FullName
                Message = 'Orphan PowerShell script is outside a valid registered module directory.'
            }
        }
        elseif ($classification -eq 'SnapshotMismatch') {
            [pscustomobject]@{
                Type    = 'Layout'
                Path    = Get-RelativeDisplayPath -BasePath $RepositoryRoot -TargetPath $item.FullName
                Message = 'Module tree changed after registry discovery; script is not present in the immutable registry snapshot.'
            }
        }
    }
}

function Get-GeneratedFileIssue {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    foreach ($item in @(Get-RepositoryChildItem -RootPath $RepositoryRoot)) {
        if ($item.PSIsContainer -and $item.Name -in @('reports', 'reports-test')) {
            [pscustomobject]@{
                Type    = 'Generated'
                Path    = Get-RelativeDisplayPath -BasePath $RepositoryRoot -TargetPath $item.FullName
                Message = 'Generated reports directory is present.'
            }
            continue
        }

        if ($item.PSIsContainer) {
            continue
        }

        $isGeneratedFile =
            $item.Name -like 'WindowsDiagnosticsReport-*.txt' -or
            $item.Name -like 'WindowsDiagnosticsReport-*.md' -or
            $item.Name -like '*.log' -or
            $item.Name -like '*.tmp' -or
            $item.Name -like '*.bak'

        if ($isGeneratedFile) {
            [pscustomobject]@{
                Type    = 'Generated'
                Path    = Get-RelativeDisplayPath -BasePath $RepositoryRoot -TargetPath $item.FullName
                Message = 'Generated report, log, temporary, or backup file is present.'
            }
        }
    }
}

$repositoryRoot = Get-RepositoryRoot
$validationPolicyPath = Join-Path -Path $PSScriptRoot -ChildPath 'validation-policy.ps1'
if (-not (Test-Path -LiteralPath $validationPolicyPath -PathType Leaf)) {
    throw "Validation policy is missing: $validationPolicyPath"
}

. $PSScriptRoot\validation-policy.ps1
$moduleRegistryPath = Join-Path -Path $PSScriptRoot -ChildPath 'module-registry.ps1'
if (-not (Test-Path -LiteralPath $moduleRegistryPath -PathType Leaf)) {
    throw "Module registry is missing: $moduleRegistryPath"
}
. $PSScriptRoot\module-registry.ps1

$moduleRoot = Join-Path -Path $repositoryRoot -ChildPath 'modules'
$registrySnapshot = Get-WdtModuleRegistry -ModuleRoot $moduleRoot
$productionScripts = @(Get-ProductionScript -RepositoryRoot $repositoryRoot -RegistrySnapshot $registrySnapshot)
$parserIssues = New-Object System.Collections.Generic.List[object]
$safetyIssues = New-Object System.Collections.Generic.List[object]
$parsedScripts = New-Object System.Collections.Generic.List[object]

Write-Host 'Windows Diagnostics Toolkit validation'
Write-Host ('Repository root    : {0}' -f $repositoryRoot)
Write-Host ('Production scripts : {0}' -f $productionScripts.Count)

foreach ($script in $productionScripts) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors)

    foreach ($issue in @(Get-ParserIssue -ParseErrors $parseErrors -ScriptPath $script.FullName -RepositoryRoot $repositoryRoot)) {
        $parserIssues.Add($issue)
    }

    $parsedScripts.Add([pscustomobject]@{
        Script           = $script
        Ast              = $ast
        ParseErrors      = @($parseErrors)
        ModuleDefinition = Get-WdtModuleDefinitionForScript -ScriptPath $script.FullName -RegistrySnapshot $registrySnapshot
    })
}

$packageFunctionNames = @{}
foreach ($definition in @($registrySnapshot.Modules)) {
    $functionNames = New-Object System.Collections.Generic.List[string]
    foreach ($parsedScript in @($parsedScripts.ToArray())) {
        if ($null -eq $parsedScript.ModuleDefinition -or $parsedScript.ModuleDefinition.Id -ine $definition.Id -or $parsedScript.ParseErrors.Count -ne 0) { continue }
        foreach ($function in @($parsedScript.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            if (-not $functionNames.Contains($function.Name)) { $functionNames.Add($function.Name) }
        }
    }
    $packageFunctionNames[$definition.Id] = @($functionNames.ToArray())
}

foreach ($parsedScript in @($parsedScripts.ToArray())) {
    if ($parsedScript.ParseErrors.Count -ne 0) { continue }
    $definition = $parsedScript.ModuleDefinition
    $functionNames = if ($null -ne $definition) { @($packageFunctionNames[$definition.Id]) } else { @() }
    foreach ($issue in @(Get-SafetyIssue -Ast $parsedScript.Ast -ScriptPath $parsedScript.Script.FullName -RepositoryRoot $repositoryRoot -RegistrySnapshot $registrySnapshot -ModuleDefinition $definition -PackageFunctionNames $functionNames)) {
        $safetyIssues.Add($issue)
    }
}

$generatedIssues = @(Get-GeneratedFileIssue -RepositoryRoot $repositoryRoot)
$layoutIssues = @(Get-ModuleLayoutIssue -RepositoryRoot $repositoryRoot -RegistrySnapshot $registrySnapshot)

Write-Host ''
Write-Host 'Summary'
Write-Host ('Parser issues      : {0}' -f $parserIssues.Count)
Write-Host ('Safety issues      : {0}' -f $safetyIssues.Count)
Write-Host ('Module layout      : {0}' -f $layoutIssues.Count)
Write-Host ('Generated issues   : {0}' -f $generatedIssues.Count)

if ($parserIssues.Count -gt 0) {
    Write-Host ''
    Write-Host 'Parser errors:'
    foreach ($issue in $parserIssues) {
        Write-Host ('- {0}:{1}:{2} {3}' -f $issue.Path, $issue.Line, $issue.Column, $issue.Message)
    }
}

if ($safetyIssues.Count -gt 0) {
    Write-Host ''
    Write-Host 'Read-only safety violations:'
    foreach ($issue in $safetyIssues) {
        Write-Host ('- {0}:{1}:{2} {3} - {4}' -f $issue.Path, $issue.Line, $issue.Column, $issue.Command, $issue.Message)
    }
}

if ($generatedIssues.Count -gt 0) {
    Write-Host ''
    Write-Host 'Generated files or directories:'
    foreach ($issue in $generatedIssues) {
        Write-Host ('- {0} - {1}' -f $issue.Path, $issue.Message)
    }
}

if ($layoutIssues.Count -gt 0) {
    Write-Host ''
    Write-Host 'Module layout issues:'
    foreach ($issue in $layoutIssues) {
        Write-Host ('- {0} - {1}' -f $issue.Path, $issue.Message)
    }
}

if ($parserIssues.Count -gt 0 -or $safetyIssues.Count -gt 0 -or $layoutIssues.Count -gt 0 -or $generatedIssues.Count -gt 0) {
    Write-Host ''
    Write-Host 'Validation failed.'
    exit 1
}

Write-Host ''
Write-Host 'Validation passed.'
