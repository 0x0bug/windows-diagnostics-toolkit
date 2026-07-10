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
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $scripts = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $entrypoint = Join-Path -Path $RepositoryRoot -ChildPath 'Invoke-WindowsDiagnostics.ps1'
    if (Test-Path -LiteralPath $entrypoint -PathType Leaf) {
        $scripts.Add((Get-Item -LiteralPath $entrypoint))
    }

    $scriptsDirectory = Join-Path -Path $RepositoryRoot -ChildPath 'scripts'
    if (Test-Path -LiteralPath $scriptsDirectory -PathType Container) {
        foreach ($script in @(Get-RepositoryChildItem -RootPath $scriptsDirectory | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.ps1' } | Sort-Object -Property FullName)) {
            $scripts.Add($script)
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
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    foreach ($issue in @(Get-WdtSafetyIssues -Ast $Ast -ScriptPath $ScriptPath -RepositoryRoot $RepositoryRoot)) {
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

                $directories.Enqueue($item)
            }

            Write-Output $item
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

$productionScripts = @(Get-ProductionScript -RepositoryRoot $repositoryRoot)
$parserIssues = New-Object System.Collections.Generic.List[object]
$safetyIssues = New-Object System.Collections.Generic.List[object]

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

    if (@($parseErrors).Count -eq 0) {
        foreach ($issue in @(Get-SafetyIssue -Ast $ast -ScriptPath $script.FullName -RepositoryRoot $repositoryRoot)) {
            $safetyIssues.Add($issue)
        }
    }
}

$generatedIssues = @(Get-GeneratedFileIssue -RepositoryRoot $repositoryRoot)

Write-Host ''
Write-Host 'Summary'
Write-Host ('Parser issues      : {0}' -f $parserIssues.Count)
Write-Host ('Safety issues      : {0}' -f $safetyIssues.Count)
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

if ($parserIssues.Count -gt 0 -or $safetyIssues.Count -gt 0 -or $generatedIssues.Count -gt 0) {
    Write-Host ''
    Write-Host 'Validation failed.'
    exit 1
}

Write-Host ''
Write-Host 'Validation passed.'
