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
        foreach ($script in @(Get-ChildItem -LiteralPath $scriptsDirectory -Filter '*.ps1' | Where-Object { -not $_.PSIsContainer } | Sort-Object -Property FullName)) {
            $scripts.Add($script)
        }
    }

    return @($scripts.ToArray())
}

function Test-AllowedNewItemCommand {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$CommandAst,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    if ((Split-Path -Leaf $ScriptPath) -ne 'Invoke-WindowsDiagnostics.ps1') {
        return $false
    }

    $elements = @($CommandAst.CommandElements)
    $hasDirectoryItemType = $false
    $hasOutputDirectoryPath = $false
    $hasForce = $false

    for ($index = 0; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }

        if ($element.ParameterName -eq 'Force') {
            $hasForce = $true
            continue
        }

        if ($index + 1 -ge $elements.Count) {
            continue
        }

        $nextElement = $elements[$index + 1]
        if ($element.ParameterName -eq 'ItemType' -and $nextElement.Extent.Text.Trim("'`"") -eq 'Directory') {
            $hasDirectoryItemType = $true
            continue
        }

        if ($element.ParameterName -eq 'Path' -and
            $nextElement -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $nextElement.VariablePath.UserPath -eq 'resolvedOutputDirectory') {
            $hasOutputDirectoryPath = $true
        }
    }

    return ($hasDirectoryItemType -and $hasOutputDirectoryPath -and $hasForce)
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

    $forbiddenExactCommands = @{}
    foreach ($commandName in @(
        'Invoke-Expression',
        'iex',
        'Invoke-WebRequest',
        'iwr',
        'Invoke-RestMethod',
        'irm',
        'Start-Process',
        'Start-Service',
        'Stop-Service',
        'Restart-Service',
        'Set-Service',
        'New-Service',
        'Remove-Service',
        'Set-ItemProperty',
        'New-ItemProperty',
        'Remove-ItemProperty',
        'Remove-Item',
        'Clear-EventLog',
        'wevtutil',
        'wevtutil.exe',
        'reg',
        'reg.exe',
        'netsh',
        'netsh.exe',
        'sc',
        'sc.exe',
        'bcdedit',
        'bcdedit.exe',
        'powercfg',
        'powercfg.exe'
    )) {
        $forbiddenExactCommands[$commandName] = $true
    }

    $forbiddenPrefixes = @(
        'Install-*',
        'Update-*',
        'Reset-*',
        'Enable-*',
        'Disable-*',
        'Clear-*'
    )

    $commandAsts = $Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true)

    foreach ($commandAst in @($commandAsts)) {
        $commandName = $commandAst.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($commandName)) {
            continue
        }

        $isForbidden = $false
        $reason = $null

        if ($commandName -eq 'New-Item') {
            if (-not (Test-AllowedNewItemCommand -CommandAst $commandAst -ScriptPath $ScriptPath)) {
                $isForbidden = $true
                $reason = 'New-Item is only allowed in Invoke-WindowsDiagnostics.ps1 for -OutputDirectory creation.'
            }
        }
        elseif ($forbiddenExactCommands.ContainsKey($commandName)) {
            $isForbidden = $true
            $reason = 'Forbidden command.'
        }
        else {
            foreach ($prefix in $forbiddenPrefixes) {
                if ($commandName -like $prefix) {
                    $isForbidden = $true
                    $reason = "Forbidden command prefix: $prefix"
                    break
                }
            }
        }

        if ($isForbidden) {
            [pscustomobject]@{
                Type    = 'Safety'
                Path    = Get-RelativeDisplayPath -BasePath $RepositoryRoot -TargetPath $ScriptPath
                Line    = $commandAst.Extent.StartLineNumber
                Column  = $commandAst.Extent.StartColumnNumber
                Command = $commandName
                Message = $reason
            }
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
