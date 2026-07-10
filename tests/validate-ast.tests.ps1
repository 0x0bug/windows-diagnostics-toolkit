[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-CommandAst {
    param([Parameter(Mandatory = $true)][string]$Source)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw ('Fixture did not parse: {0}' -f $Source)
    }

    $command = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Select-Object -First 1)
    if ($command.Count -ne 1) {
        throw ('Fixture did not contain exactly one command: {0}' -f $Source)
    }

    return $command[0]
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $repositoryRoot -ChildPath 'scripts\validation-policy.ps1')

foreach ($source in @(
        'w32tm.exe /query /source',
        'w32tm.exe /query /status /verbose'
    )) {
    Assert-True -Condition (Test-WdtAllowedW32tmCommand -CommandAst (Get-CommandAst -Source $source)) -Message ("Allowed W32Time query was rejected: {0}" -f $source)
}

foreach ($source in @(
        'w32tm.exe /query /status',
        'w32tm.exe /query /source /verbose',
        'w32tm.exe /config /update',
        'w32tm.exe /resync',
        'w32tm.exe /register'
    )) {
    Assert-True -Condition (-not (Test-WdtAllowedW32tmCommand -CommandAst (Get-CommandAst -Source $source))) -Message ("Forbidden W32Time command was accepted: {0}" -f $source)
}

Assert-True -Condition (Test-WdtAllowedNetshCommand -CommandAst (Get-CommandAst -Source 'netsh.exe winhttp show proxy')) -Message 'Allowed WinHTTP proxy query was rejected.'

foreach ($source in @(
        'netsh.exe winhttp show proxy extra',
        'netsh.exe winhttp set proxy server:8080',
        'netsh.exe interface show interface',
        'netsh winhttp show proxy'
    )) {
    Assert-True -Condition (-not (Test-WdtAllowedNetshCommand -CommandAst (Get-CommandAst -Source $source))) -Message ("Forbidden netsh command was accepted: {0}" -f $source)
}

Write-Host 'Validation AST policy tests passed.'
