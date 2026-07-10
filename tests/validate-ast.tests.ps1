[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-FixtureAst {
    param([string]$Source)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('Fixture did not parse: {0}' -f $Source) }
    return $ast
}

function Get-FixtureIssues {
    param([string]$Source, [string]$RelativePath = 'scripts\fixture.ps1')
    $scriptPath = Join-Path $repositoryRoot $RelativePath
    return @(Get-WdtSafetyIssues -Ast (Get-FixtureAst $Source) -ScriptPath $scriptPath -RepositoryRoot $repositoryRoot)
}

function Assert-Allowed {
    param([string]$Source, [string]$RelativePath = 'scripts\fixture.ps1')
    $issues = @(Get-FixtureIssues $Source $RelativePath)
    Assert-True ($issues.Count -eq 0) ("Allowed fixture was rejected: {0}`n{1}" -f $Source, (($issues | ForEach-Object Message) -join '; '))
}

function Assert-Denied {
    param([string]$Source, [string]$MessagePattern, [string]$RelativePath = 'scripts\fixture.ps1')
    $issues = @(Get-FixtureIssues $Source $RelativePath)
    Assert-True ($issues.Count -gt 0) ("Forbidden fixture was accepted: {0}" -f $Source)
    $matchingIssues = @($issues | Where-Object { $_.Message -like $MessagePattern })
    Assert-True ($matchingIssues.Count -gt 0) ("Fixture did not produce expected issue '$MessagePattern': {0}`nActual: {1}" -f $Source, (($issues | ForEach-Object Message) -join '; '))
    foreach ($issue in $matchingIssues) {
        Assert-True ($issue.Type -eq 'Safety') 'Safety issue has an unexpected type.'
        Assert-True ($issue.Line -gt 0 -and $issue.Column -gt 0) 'Safety issue has invalid line or column.'
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\validation-policy.ps1')

foreach ($source in @(
        'w32tm.exe /query /source',
        'w32tm.exe /query /status /verbose',
        '& W32TM.EXE /query /source',
        '& C:\Windows\System32\w32tm.exe /query /source',
        'netsh.exe winhttp show proxy',
        '& NETSH.EXE winhttp show proxy',
        'Get-CimInstance -ClassName Win32_OperatingSystem',
        'Get-NetAdapter',
        'Get-ChildItem .',
        'Test-Path .',
        'Resolve-Path .',
        '[guid]::Parse("00000000-0000-0000-0000-000000000000")',
        '[System.Text.RegularExpressions.Regex]::Replace("a", "a", "b")',
        '$value.Trim().Replace("a", "b")'
    )) { Assert-Allowed $source }

Assert-Allowed '. $PSScriptRoot\report-common.ps1' 'scripts\disk-health.ps1'
Assert-Allowed '. $PSScriptRoot\scripts\report-common.ps1' 'Invoke-WindowsDiagnostics.ps1'
Assert-Allowed '. $PSScriptRoot\validation-policy.ps1' 'scripts\validate.ps1'
Assert-Allowed '[System.IO.File]::WriteAllLines($textReportPath, $textLines, [System.Text.Encoding]::UTF8)' 'Invoke-WindowsDiagnostics.ps1'
Assert-Allowed 'function Invoke-DiagnosticScript { $process.Start() }' 'Invoke-WindowsDiagnostics.ps1'

$allowedCallbacks = @'
function Protect-WdtRegexMatches {
    [bool](& $Validator $value $valueMatch $Text)
    [string](& $TokenValueSelector $value)
}
'@
Assert-Allowed $allowedCallbacks 'scripts\report-common.ps1'

foreach ($method in @('GetProtectionStatus', 'GetConversionStatus')) {
    Assert-Allowed ("Invoke-CimMethod -InputObject `$volume -MethodName '$method' -ErrorAction Stop") 'scripts\security-posture.ps1'
}

$nativeFixtures = @(
    'cmd.exe /c echo test',
    'cmd /c echo test',
    'powershell.exe -Command "Write-Host test"',
    'pwsh.exe -Command "Write-Host test"',
    'rundll32.exe something.dll,EntryPoint',
    'regsvr32.exe file.dll',
    'schtasks.exe /create /tn Test /tr calc.exe',
    'fsutil.exe file createnew test.bin 1',
    'diskpart.exe /s script.txt',
    'wmic.exe process call create calc.exe',
    'sc.exe create Test binPath= calc.exe',
    'reg.exe add HKCU\Software\Test /v Value /d Data',
    'bcdedit.exe /set testsigning on',
    'powercfg.exe /change monitor-timeout-ac 0',
    'C:\Windows\System32\cmd.exe /c echo test',
    'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -Command "Write-Host test"',
    'unknown-tool.exe --read',
    'CMD.EXE /c echo test'
)
foreach ($source in $nativeFixtures) { Assert-Denied $source '*Native executable is not in the read-only allowlist*' }

foreach ($source in @(
        'w32tm.exe /query /status extra',
        'w32tm.exe /query $mode',
        'w32tm.exe /query $mode /source',
        'netsh.exe winhttp show proxy extra',
        'netsh.exe winhttp $action proxy',
        'W32TM.EXE /resync'
    )) { Assert-Denied $source '*Native executable arguments are not an allowed read-only form*' }

foreach ($source in @(
        '$command = "cmd.exe"; & $command /c echo test',
        '& (Get-Command cmd.exe) /c echo test',
        '& $env:ComSpec /c echo test',
        'function Invoke-Anything { param([scriptblock]$ScriptBlock) & $ScriptBlock }',
        '& $OtherCallback $value'
    )) { Assert-Denied $source '*Dynamic command invocation is not allowed*' }
Assert-Denied '${function:SomeFunction}' '*Dynamic function provider access is not allowed*'

foreach ($source in @(
        '. $dynamicPath',
        '. $env:USERPROFILE\script.ps1',
        '. (Join-Path $PSScriptRoot $childPath)'
    )) { Assert-Denied $source '*not an approved repository helper*' }
Assert-Denied '& $PSScriptRoot\report-common.ps1' '*Dynamic command invocation is not allowed*'

Assert-Denied 'function Other { & $Validator $value $valueMatch $Text }' '*Only approved internal callbacks are permitted*' 'scripts\report-common.ps1'
Assert-Denied 'function Protect-WdtRegexMatches { & $Validator $value $valueMatch $Text $extra }' '*Only approved internal callbacks are permitted*' 'scripts\report-common.ps1'
Assert-Denied 'function Protect-WdtRegexMatches { & $Validator $value $valueMatch $Text > output.txt }' '*Only approved internal callbacks are permitted*' 'scripts\report-common.ps1'
Assert-Denied 'function Protect-WdtRegexMatches { & $Validator $Text }' '*Only approved internal callbacks are permitted*' 'scripts\report-common.ps1'
Assert-Denied 'function Other { & $TokenValueSelector $value }' '*Only approved internal callbacks are permitted*' 'scripts\report-common.ps1'
Assert-Denied 'function Protect-WdtRegexMatches { & $TokenValueSelector (Get-Content file) }' '*Only approved internal callbacks are permitted*' 'scripts\report-common.ps1'

foreach ($source in @(
        'Invoke-CimMethod -InputObject $volume -MethodName Encrypt',
        'Invoke-CimMethod -InputObject $volume -MethodName DisableKeyProtectors',
        'Invoke-CimMethod -InputObject $volume -MethodName $method',
        'Invoke-CimMethod -InputObject $other -MethodName GetProtectionStatus',
        'Invoke-CimMethod -ClassName Win32_Process -MethodName Create',
        'Invoke-CimMethod -InputObject $volume -MethodName GetProtectionStatus -Arguments @{ X = 1 }'
    )) { Assert-Denied $source '*only allowed for approved read-only BitLocker status queries*' 'scripts\security-posture.ps1' }
Assert-Denied 'Invoke-CimMethod -InputObject $volume -MethodName GetProtectionStatus -ErrorAction Stop' '*only allowed for approved read-only BitLocker status queries*' 'scripts\fixture.ps1'

foreach ($source in @(
        'Add-Type -TypeDefinition "public class X {}"',
        'New-Object -ComObject WScript.Shell',
        'New-Object -TypeName $typeName',
        'Invoke-Command -ScriptBlock { Get-Date }',
        'Start-Job { Get-Date }',
        'New-Alias bad Get-ChildItem',
        'Set-Alias bad Get-ChildItem',
        'iex "Get-Date"'
    )) { Assert-Denied $source '*not permitted*' }

foreach ($source in @(
        '[Microsoft.Win32.Registry]::SetValue("HKCU\Software\Test", "X", "Y")',
        '[Microsoft.Win32.RegistryKey]::OpenBaseKey("CurrentUser", "Default")',
        '[System.IO.File]::Delete("file")',
        '[System.IO.File]::WriteAllText("file", "x")',
        '[System.IO.Directory]::Delete("dir")',
        '[System.Diagnostics.Process]::Start("calc.exe")',
        '[System.Reflection.Assembly]::Load($bytes)',
        '[System.Activator]::CreateInstance($type)',
        '[System.Environment]::SetEnvironmentVariable("X", "Y")',
        '[type]::GetType($name)',
        '[System.IO.File]::WriteAllLines($otherPath, $lines, [System.Text.Encoding]::UTF8)'
    )) { Assert-Denied $source '*Static method can mutate system state or load dynamic code*' }
Assert-Denied '[System.IO.File]::WriteAllLines($textReportPath, $lines, [System.Text.Encoding]::UTF8)' '*Static method can mutate system state or load dynamic code*' 'scripts\fixture.ps1'

foreach ($source in @(
        '$object.Delete()', '$object.Remove()', '$object.Put()', '$object.SetValue("x", "y")',
        '$service.Start()', '$process.Kill()', '$stream.Write($bytes)', '$client.DownloadFile("x", "y")'
    )) { Assert-Denied $source '*Instance method can mutate system state*' }
Assert-Denied '$process.Start()' '*Instance method can mutate system state*' 'scripts\fixture.ps1'

Write-Host 'Validation AST policy tests passed.'
