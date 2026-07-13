[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}

function Get-ScriptAst {
    param([Parameter(Mandatory = $true)][string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "Parser errors in $Path`: $($errors[0].Message)" }
    return $ast
}

function Normalize-Text {
    param([AllowEmptyString()][string]$Text)
    return (($Text -replace "`r`n", "`n") -replace '\s+', ' ').Trim()
}

function Normalize-ProcessText {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    return $normalized.TrimEnd([char[]]"`n")
}

function ConvertTo-NativeArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-IsolatedPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [hashtable]$Environment = @{}
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $PowerShellPath
    $nativeArguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ScriptArguments)
    $startInfo.Arguments = (@($nativeArguments | ForEach-Object { ConvertTo-NativeArgument -Value ([string]$_) }) -join ' ')
    $startInfo.WorkingDirectory = Split-Path -Parent $ScriptPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($key in $Environment.Keys) {
        $startInfo.EnvironmentVariables[[string]$key] = [string]$Environment[$key]
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Failed to start isolated PowerShell process for '$ScriptPath'." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw "Isolated PowerShell process timed out for '$ScriptPath'."
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = Normalize-ProcessText -Text $stdout
            StdErr   = Normalize-ProcessText -Text $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

function Set-FixtureDiagnostic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ParameterBlock,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body
    )

    $content = "[CmdletBinding()]`r`n$ParameterBlock`r`n`r`n$Body`r`n"
    [System.IO.File]::WriteAllText($Path, $content)
}

$contracts = @(
    [pscustomobject]@{ Legacy = 'system-info.ps1'; Slug = 'system'; Args = @(); Expected = '' },
    [pscustomobject]@{ Legacy = 'security-posture.ps1'; Slug = 'security'; Args = @(); Expected = '' },
    [pscustomobject]@{ Legacy = 'performance-snapshot.ps1'; Slug = 'performance'; Args = @('-TopProcessCount', '7'); Expected = 'TopProcessCount=7' },
    [pscustomobject]@{ Legacy = 'network-check.ps1'; Slug = 'network'; Args = @('-NoExternalNetworkTests'); Expected = 'NoExternalNetworkTests=True' },
    [pscustomobject]@{ Legacy = 'time-sync-diagnostics.ps1'; Slug = 'time'; Args = @('-IncludeTimeServiceEvents'); Expected = 'IncludeTimeServiceEvents=True' },
    [pscustomobject]@{ Legacy = 'disk-health.ps1'; Slug = 'disk'; Args = @('-LowFreeSpacePercent', '17'); Expected = 'LowFreeSpacePercent=17' },
    [pscustomobject]@{ Legacy = 'crash-hang-diagnostics.ps1'; Slug = 'crashes'; Args = @('-MaxDumpFiles', '3'); Expected = 'MaxDumpFiles=3' },
    [pscustomobject]@{ Legacy = 'event-log-check.ps1'; Slug = 'events'; Args = @('-IncludeWarnings'); Expected = 'IncludeWarnings=True' },
    [pscustomobject]@{ Legacy = 'services-check.ps1'; Slug = 'services'; Args = @('-IncludeStartup'); Expected = 'IncludeStartup=True' },
    [pscustomobject]@{ Legacy = 'windows-update-check.ps1'; Slug = 'updates'; Args = @('-IncludeEventLog'); Expected = 'IncludeEventLog=True' }
)

$shellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$tempRoot = Join-Path $env:TEMP ('wdt-compatibility-' + [guid]::NewGuid().ToString('N'))
$fixtureScripts = Join-Path $tempRoot 'scripts'
$fixtureModules = Join-Path $tempRoot 'modules'
$parameterBlocks = @{}
try {
    New-Item -ItemType Directory -Path $fixtureScripts -Force | Out-Null
    New-Item -ItemType Directory -Path $fixtureModules -Force | Out-Null

    foreach ($contract in $contracts) {
        $legacyPath = Join-Path $repositoryRoot ('scripts\' + $contract.Legacy)
        $entrypointPath = Join-Path $repositoryRoot ('modules\' + $contract.Slug + '\diagnostic.ps1')
        Assert-True (Test-Path -LiteralPath $legacyPath -PathType Leaf) "Missing compatibility launcher: $($contract.Legacy)"
        Assert-True (Test-Path -LiteralPath $entrypointPath -PathType Leaf) "Missing module entrypoint: $($contract.Slug)"

        $legacyAst = Get-ScriptAst -Path $legacyPath
        $entrypointAst = Get-ScriptAst -Path $entrypointPath
        Assert-Equal (Normalize-Text $entrypointAst.ParamBlock.Extent.Text) (Normalize-Text $legacyAst.ParamBlock.Extent.Text) "Parameter contract changed for $($contract.Legacy)."

        $invocations = @($legacyAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand
                }, $true))
        Assert-Equal 1 $invocations.Count "Launcher must contain one delegated invocation: $($contract.Legacy)."
        Assert-True ($invocations[0].Extent.Text -like '*@PSBoundParameters*') "Launcher does not forward PSBoundParameters: $($contract.Legacy)."
        Assert-Equal 0 $invocations[0].Redirections.Count "Launcher must not redirect diagnostic streams: $($contract.Legacy)."
        Assert-Equal 0 @($legacyAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.ExitStatementAst] }, $true)).Count "Launcher must not rewrite exit status: $($contract.Legacy)."
        Assert-Equal 0 @($legacyAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.TryStatementAst] -or $node -is [System.Management.Automation.Language.TrapStatementAst] }, $true)).Count "Launcher must not catch diagnostic errors: $($contract.Legacy)."

        $fixtureModule = Join-Path $fixtureModules $contract.Slug
        New-Item -ItemType Directory -Path $fixtureModule -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $fixtureScripts $contract.Legacy), [System.IO.File]::ReadAllText($legacyPath))
        $parameterBlocks[$contract.Slug] = $entrypointAst.ParamBlock.Extent.Text
    }

    foreach ($contract in $contracts) {
        $fixtureLauncher = Join-Path $fixtureScripts $contract.Legacy
        $fixtureDiagnostic = Join-Path (Join-Path $fixtureModules $contract.Slug) 'diagnostic.ps1'
        $parameterNames = @((Get-ScriptAst -Path (Join-Path $repositoryRoot ('modules\' + $contract.Slug + '\diagnostic.ps1'))).ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $parameterNameLiteral = if ($parameterNames.Count -eq 0) {
            '@()'
        }
        else {
            "@('" + (($parameterNames | ForEach-Object { $_.Replace("'", "''") }) -join "','") + "')"
        }
        $parameterProbeBody = @"
`$parameterNames = $parameterNameLiteral
`$renderedValues = @(`$parameterNames | ForEach-Object {
    `$parameterValue = Get-Variable -Name `$_ -ValueOnly
    if (`$parameterValue -is [System.Management.Automation.SwitchParameter]) { `$parameterValue = [bool]`$parameterValue }
    '{0}={1}' -f `$_, `$parameterValue
})
Write-Output ('Bound=' + (@(`$PSBoundParameters.Keys | Sort-Object) -join ','))
Write-Output ('Values=' + (`$renderedValues -join ';'))
"@
        Set-FixtureDiagnostic -Path $fixtureDiagnostic -ParameterBlock $parameterBlocks[$contract.Slug] -Body $parameterProbeBody

        $directDefaults = Invoke-IsolatedPowerShell -PowerShellPath $shellPath -ScriptPath $fixtureDiagnostic
        $launcherDefaults = Invoke-IsolatedPowerShell -PowerShellPath $shellPath -ScriptPath $fixtureLauncher
        Assert-Equal 0 $directDefaults.ExitCode "Default fixture failed directly: $($contract.Legacy)."
        Assert-Equal 0 $launcherDefaults.ExitCode "Launcher failed with defaults: $($contract.Legacy)."
        Assert-Equal '' $directDefaults.StdErr "Default fixture wrote unexpected stderr directly: $($contract.Legacy)."
        Assert-Equal '' $launcherDefaults.StdErr "Launcher changed default stderr: $($contract.Legacy)."
        Assert-Equal $directDefaults.StdOut $launcherDefaults.StdOut "Launcher changed default parameter binding: $($contract.Legacy)."
        Assert-True ($launcherDefaults.StdOut -match '(?m)^Bound=$') "Launcher bound default values explicitly: $($contract.Legacy)."

        if ($contract.Slug -eq 'services') {
            Assert-True ($launcherDefaults.StdOut.Contains('IncludeStartup=False')) 'Services standalone launcher applied the manifest IncludeStartup default.'
            Assert-True ($launcherDefaults.StdOut.Contains('IncludeScheduledTasks=False')) 'Services standalone launcher applied the manifest IncludeScheduledTasks default.'
        }

        if ($contract.Args.Count -eq 0) { continue }
        $forwardArgs = @($contract.Args)
        $directExplicit = Invoke-IsolatedPowerShell -PowerShellPath $shellPath -ScriptPath $fixtureDiagnostic -ScriptArguments $forwardArgs
        $launcherExplicit = Invoke-IsolatedPowerShell -PowerShellPath $shellPath -ScriptPath $fixtureLauncher -ScriptArguments $forwardArgs
        Assert-Equal 0 $directExplicit.ExitCode "Explicit parameter fixture failed directly: $($contract.Legacy)."
        Assert-Equal 0 $launcherExplicit.ExitCode "Launcher failed with explicit parameters: $($contract.Legacy)."
        Assert-Equal '' $launcherExplicit.StdErr "Launcher changed explicit parameter stderr: $($contract.Legacy)."
        Assert-Equal $directExplicit.StdOut $launcherExplicit.StdOut "Launcher did not preserve explicit parameter binding: $($contract.Legacy)."
        Assert-True ($launcherExplicit.StdOut.Contains($contract.Expected)) "Launcher did not forward expected parameter value: $($contract.Legacy)."
    }

    $stdoutDiagnostic = Join-Path (Join-Path $fixtureModules 'system') 'diagnostic.ps1'
    Set-FixtureDiagnostic -Path $stdoutDiagnostic -ParameterBlock $parameterBlocks['system'] -Body "Write-Output 'stdout-first'`r`nWrite-Output 'stdout-second'"
    $stdoutResult = Invoke-IsolatedPowerShell -PowerShellPath $shellPath -ScriptPath (Join-Path $fixtureScripts 'system-info.ps1')
    Assert-Equal 0 $stdoutResult.ExitCode 'Launcher changed successful stdout exit status.'
    Assert-Equal "stdout-first`nstdout-second" $stdoutResult.StdOut 'Launcher changed stdout content or ordering.'
    Assert-Equal '' $stdoutResult.StdErr 'Launcher redirected stdout to stderr.'

    $stderrDiagnostic = Join-Path (Join-Path $fixtureModules 'security') 'diagnostic.ps1'
    Set-FixtureDiagnostic -Path $stderrDiagnostic -ParameterBlock $parameterBlocks['security'] -Body "[System.Console]::Error.WriteLine('stderr-marker')"
    $stderrResult = Invoke-IsolatedPowerShell -PowerShellPath $shellPath -ScriptPath (Join-Path $fixtureScripts 'security-posture.ps1')
    Assert-Equal 0 $stderrResult.ExitCode 'Launcher changed plain stderr exit status.'
    Assert-Equal '' $stderrResult.StdOut 'Launcher redirected stderr to stdout.'
    Assert-Equal 'stderr-marker' $stderrResult.StdErr 'Launcher changed plain stderr content.'

    $nonterminatingDiagnostic = Join-Path (Join-Path $fixtureModules 'performance') 'diagnostic.ps1'
    $nonterminatingBody = @'
Write-Output 'before-nonterminating'
Write-Error 'nonterminating-marker' -ErrorAction Continue
Write-Output 'after-nonterminating'
'@
    Set-FixtureDiagnostic -Path $nonterminatingDiagnostic -ParameterBlock $parameterBlocks['performance'] -Body $nonterminatingBody
    $nonterminatingResult = Invoke-IsolatedPowerShell -PowerShellPath $shellPath -ScriptPath (Join-Path $fixtureScripts 'performance-snapshot.ps1')
    Assert-Equal 0 $nonterminatingResult.ExitCode 'Launcher converted a nonterminating error into process failure.'
    Assert-Equal "before-nonterminating`nafter-nonterminating" $nonterminatingResult.StdOut 'Launcher interrupted output after a nonterminating error.'
    Assert-True ($nonterminatingResult.StdErr.Contains('nonterminating-marker')) 'Launcher suppressed a nonterminating error.'

    $terminatingDiagnostic = Join-Path (Join-Path $fixtureModules 'network') 'diagnostic.ps1'
    $terminatingBody = @'
Write-Output 'before-terminating'
throw 'terminating-marker'
Write-Output 'after-terminating'
'@
    Set-FixtureDiagnostic -Path $terminatingDiagnostic -ParameterBlock $parameterBlocks['network'] -Body $terminatingBody
    $terminatingResult = Invoke-IsolatedPowerShell -PowerShellPath $shellPath -ScriptPath (Join-Path $fixtureScripts 'network-check.ps1')
    Assert-Equal 1 $terminatingResult.ExitCode 'Launcher did not preserve terminating error process failure.'
    Assert-Equal 'before-terminating' $terminatingResult.StdOut 'Launcher changed stdout before a terminating error.'
    Assert-True (-not $terminatingResult.StdOut.Contains('after-terminating')) 'Launcher continued after a terminating error.'
    Assert-True ($terminatingResult.StdErr.Contains('terminating-marker')) 'Launcher suppressed a terminating error.'

    $exitDiagnostic = Join-Path (Join-Path $fixtureModules 'services') 'diagnostic.ps1'
    $exitBody = @'
Write-Output 'before-explicit-exit'
[System.Environment]::Exit(37)
'@
    Set-FixtureDiagnostic -Path $exitDiagnostic -ParameterBlock $parameterBlocks['services'] -Body $exitBody
    $exitResult = Invoke-IsolatedPowerShell -PowerShellPath $shellPath -ScriptPath (Join-Path $fixtureScripts 'services-check.ps1')
    Assert-Equal 37 $exitResult.ExitCode 'Launcher intercepted an explicit diagnostic host exit code.'
    Assert-Equal 'before-explicit-exit' $exitResult.StdOut 'Launcher changed stdout before an explicit host exit.'
    Assert-Equal '' $exitResult.StdErr 'Launcher added stderr for an explicit host exit.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

$global:LASTEXITCODE = 0
Write-Host 'Module compatibility tests passed.'
