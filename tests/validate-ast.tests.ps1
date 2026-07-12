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
        'netsh.exe winhttp show proxy',
        '& NETSH.EXE winhttp show proxy',
        'Get-CimInstance -ClassName Win32_OperatingSystem',
        'Get-NetAdapter',
        'Get-ChildItem .',
        'Test-Path .',
        '[System.Guid]::TryParse("00000000-0000-0000-0000-000000000000", [ref]$guid)',
        '[System.Text.RegularExpressions.Regex]::Replace("a", "a", "b")',
        '$value.Trim().Replace("a", "b")'
    )) { Assert-Allowed $source }

Assert-Allowed '. $PSScriptRoot\report-common.ps1' 'scripts\disk-health.ps1'
Assert-Allowed '. $PSScriptRoot\scripts\report-common.ps1' 'Invoke-WindowsDiagnostics.ps1'
Assert-Allowed '. $PSScriptRoot\scripts\diagnostic-catalog.ps1' 'Invoke-WindowsDiagnostics.ps1'
Assert-Allowed '. $PSScriptRoot\scripts\tui.ps1' 'Invoke-WindowsDiagnostics.ps1'
Assert-Allowed '. $PSScriptRoot\validation-policy.ps1' 'scripts\validate.ps1'
Assert-Allowed '[System.IO.File]::WriteAllLines($textReportPath, $textLines, [System.Text.Encoding]::UTF8)' 'Invoke-WindowsDiagnostics.ps1'
Assert-Allowed 'function Invoke-DiagnosticScript { $process.Start() }' 'Invoke-WindowsDiagnostics.ps1'
Assert-Allowed 'function Wait-WdtTuiEvent { [System.Console]::ReadKey($true) }' 'scripts\tui.ps1'
Assert-Allowed 'function Wait-WdtTuiEvent { [System.Console]::KeyAvailable }' 'scripts\tui.ps1'
Assert-Allowed 'function Invoke-WdtInteractiveSession { Read-Host ''Output directory'' }' 'scripts\tui.ps1'
Assert-Allowed 'function Show-WdtTuiFrame { Clear-Host; [System.Console]::SetCursorPosition($column, $row) }' 'scripts\tui.ps1'
Assert-Allowed 'function Invoke-WdtInteractiveSession { $old = [System.Console]::CursorVisible; [System.Console]::CursorVisible = $false; [System.Console]::CursorVisible = $old }' 'scripts\tui.ps1'
Assert-Allowed 'function Invoke-WdtInteractiveSession { Invoke-WdtReport @reportParameters }' 'scripts\tui.ps1'
Assert-Allowed 'function Get-WdtOemEncoding { $oemCodePage = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage; [System.Text.Encoding]::GetEncoding($oemCodePage) }' 'scripts\time-sync-diagnostics.ps1'
Assert-Allowed 'function ConvertFrom-WdtOemBytes { param($Bytes, $Encoding); $Encoding.GetString($Bytes) }' 'scripts\time-sync-diagnostics.ps1'
Assert-Allowed 'function Invoke-W32tmQuery { $startInfo = New-Object System.Diagnostics.ProcessStartInfo; $process = New-Object System.Diagnostics.Process; [void]$process.Start(); $stdoutReader.Dispose(); $stderrReader.Dispose(); $process.Dispose() }' 'scripts\time-sync-diagnostics.ps1'

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
        'w32tm.exe /query /source',
        'w32tm.exe /query /status /verbose',
        'w32tm.exe /query /status extra',
        'w32tm.exe /query $mode',
        'w32tm.exe /query $mode /source',
        'W32TM.EXE /resync'
    )) { Assert-Denied $source '*Native executable is not in the read-only allowlist*' }
foreach ($source in @('netsh.exe winhttp show proxy extra', 'netsh.exe winhttp $action proxy')) {
    Assert-Denied $source '*Native executable arguments are not an allowed read-only form*'
}
Assert-Denied 'function Other { $oemCodePage = 437; [System.Text.Encoding]::GetEncoding($oemCodePage) }' '*Static method is not in the reviewed safe allowlist*' 'scripts\time-sync-diagnostics.ps1'
Assert-Denied 'function Other { $process = New-Object System.Diagnostics.Process }' '*New-Object type is not in the reviewed safe-type allowlist*' 'scripts\time-sync-diagnostics.ps1'
Assert-Denied 'function Other { $process.Dispose() }' '*Instance method is not in the reviewed safe allowlist*' 'scripts\time-sync-diagnostics.ps1'

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
Assert-Denied '. $PSScriptRoot\scripts\tui.ps1' '*not an approved repository helper*' 'scripts\disk-health.ps1'
Assert-Denied '. $PSScriptRoot\scripts\diagnostic-catalog.ps1' '*not an approved repository helper*' 'scripts\disk-health.ps1'
Assert-Denied '. $tuiPath' '*not an approved repository helper*' 'Invoke-WindowsDiagnostics.ps1'
Assert-Denied 'Invoke-WdtReport @reportParameters' '*only callable from the approved interactive session*' 'scripts\tui.ps1'

foreach ($source in @(
        '[System.Console]::SetOut($writer)',
        '[System.Console]::SetIn($reader)',
        '[System.Console]::OpenStandardInput()',
        '[System.Console]::UnknownMethod()'
    )) { Assert-Denied $source '*Static method is not in the reviewed safe allowlist*' 'scripts\tui.ps1' }
Assert-Denied 'function Other { [System.Console]::ReadKey($true) }' '*Static method is not in the reviewed safe allowlist*' 'scripts\tui.ps1'
Assert-Denied 'function Wait-WdtTuiEvent { [System.Console]::ReadKey($false) }' '*Static method is not in the reviewed safe allowlist*' 'scripts\tui.ps1'
Assert-Denied 'function Wait-WdtTuiEvent { [System.Console]::ReadKey() }' '*Static method is not in the reviewed safe allowlist*' 'scripts\tui.ps1'
Assert-Denied 'function Other { [System.Console]::KeyAvailable }' '*key availability is only allowed*' 'scripts\tui.ps1'
Assert-Denied 'function Other { [System.Console]::SetCursorPosition(0, 0) }' '*Static method is not in the reviewed safe allowlist*' 'scripts\tui.ps1'
Assert-Denied 'function Show-WdtTuiFrame { [System.Console]::SetCursorPosition(0, $row) }' '*Static method is not in the reviewed safe allowlist*' 'scripts\tui.ps1'
Assert-Denied 'function Show-WdtTuiFrame { [System.Console]::SetCursorPosition($row, $column) }' '*Static method is not in the reviewed safe allowlist*' 'scripts\tui.ps1'
Assert-Denied 'function Other { [System.Console]::CursorVisible = $false }' '*cursor visibility is only allowed*' 'scripts\tui.ps1'

foreach ($source in @(
        'Start-Process calc.exe',
        'Invoke-RestMethod https://example.com',
        'Invoke-Expression ''Get-Date'''
    )) { Assert-Denied $source '*PowerShell command is not in the reviewed read-only allowlist*' 'scripts\tui.ps1' }

foreach ($source in @('Read-Host ''Value''', 'Clear-Host')) {
    Assert-Denied $source '*only allowed*' 'scripts\disk-health.ps1'
}
Assert-Denied 'function Other { Read-Host ''Value'' }' '*Read-Host is only allowed*' 'scripts\tui.ps1'
Assert-Denied 'function Other { Clear-Host }' '*Clear-Host is only allowed*' 'scripts\tui.ps1'
Assert-Denied 'function Invoke-WdtInteractiveSession { Read-Host ''Value'' > output.txt }' '*Read-Host is only allowed*' 'scripts\tui.ps1'

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
        'Invoke-Command -ScriptBlock { Get-Date }',
        'Start-Job { Get-Date }',
        'New-Alias bad Get-ChildItem',
        'Set-Alias bad Get-ChildItem',
        'iex "Get-Date"'
    )) { Assert-Denied $source '*reviewed read-only allowlist*' }
foreach ($source in @(
        'New-Object -ComObject WScript.Shell',
        'New-Object -TypeName $typeName'
    )) { Assert-Denied $source '*reviewed safe-type allowlist*' }

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
    )) { Assert-Denied $source '*Static method is not in the reviewed safe allowlist*' }
Assert-Denied '[System.IO.File]::WriteAllLines($textReportPath, $lines, [System.Text.Encoding]::UTF8)' '*Static method is not in the reviewed safe allowlist*' 'scripts\fixture.ps1'

foreach ($source in @(
        '$object.Delete()', '$object.Remove()', '$object.Put()', '$object.SetValue("x", "y")',
        '$service.Start()', '$process.Kill()', '$stream.Write($bytes)', '$client.DownloadFile("x", "y")'
    )) { Assert-Denied $source '*Instance method is not in the reviewed safe allowlist*' }
Assert-Denied '$process.Start()' '*Instance method is not in the reviewed safe allowlist*' 'scripts\fixture.ps1'

foreach ($source in @(
        'Set-Content .\owned.txt ''data''',
        'Add-Content .\owned.txt ''data''',
        '''data'' | Out-File .\owned.txt',
        'Copy-Item source destination',
        'Move-Item source destination',
        'Rename-Item old new',
        'Stop-Process -Id $PID',
        'Import-Module .\untrusted.psm1'
    )) { Assert-Denied $source '*PowerShell command is not in the reviewed read-only allowlist*' }

foreach ($source in @(
        'Write-Output ''data'' > .\owned.txt',
        'Write-Output ''data'' >> .\owned.txt',
        'Get-ChildItem 2> .\error.txt',
        'Write-Output ''data'' *> .\owned.txt'
    )) { Assert-Denied $source '*PowerShell redirection is not permitted in production scripts*' }

foreach ($source in @(
        'New-Object System.IO.StreamWriter ''.\owned.txt''',
        'New-Object System.Management.Automation.PowerShell',
        'New-Object -TypeName System.Uri -ComObject WScript.Shell'
    )) { Assert-Denied $source '*New-Object type is not in the reviewed safe-type allowlist*' }

Assert-Denied '[System.IO.File]::Create(''.\owned.txt'')' '*Static method is not in the reviewed safe allowlist*'
Assert-Denied '[System.IO.File]::OpenWrite(''.\owned.txt'')' '*Static method is not in the reviewed safe allowlist*'
Assert-Denied '[System.IO.FileStream]::new(''.\owned.txt'', [System.IO.FileMode]::Create)' '*Static method is not in the reviewed safe allowlist*'
Assert-Denied '[System.IO.StreamWriter]::new(''.\owned.txt'')' '*Static method is not in the reviewed safe allowlist*'
Assert-Denied '([scriptblock]::Create(''Set-Content .\owned.txt data'')).Invoke()' '*reviewed safe allowlist*'
Assert-Denied '[System.Management.Automation.PowerShell]::Create().AddScript(''Set-Content .\owned.txt data'').Invoke()' '*reviewed safe allowlist*'
Assert-Denied '$ExecutionContext.InvokeCommand.InvokeScript(''Get-Date'')' '*Instance method is not in the reviewed safe allowlist*'

foreach ($source in @(
        'New-Item -ItemType Directory -Path $otherPath -Force',
        'New-Item -ItemType File -Path $resolvedOutputDirectory -Force',
        'New-Item -ItemType Directory -Path $resolvedOutputDirectory',
        'New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force -Name extra',
        'New-Item -ItemType Directory -Path $otherPath -Force -Name ''-Path $resolvedOutputDirectory''',
        'New-Item -Path $resolvedOutputDirectory -Path $otherPath -ItemType Directory -Force',
        'New-Item @parameters'
    )) { Assert-Denied $source '*New-Item is only allowed*' 'Invoke-WindowsDiagnostics.ps1' }

Assert-Denied 'using module .\module.psm1' '*Module import is not permitted in production scripts*'
Assert-Denied '#requires -Modules SomeModule' '*Script module requirements are not permitted in production scripts*'

function Assert-ProductionPolicyClassification {
    $productionScripts = @((Get-Item (Join-Path $repositoryRoot 'Invoke-WindowsDiagnostics.ps1'))) + @(Get-ChildItem (Join-Path $repositoryRoot 'scripts') -Filter '*.ps1' -File)
    foreach ($script in $productionScripts) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-True (@($parseErrors).Count -eq 0) ("Production script did not parse: {0}" -f $script.Name)
        $issues = @(Get-WdtSafetyIssues -Ast $ast -ScriptPath $script.FullName -RepositoryRoot $repositoryRoot)
        Assert-True ($issues.Count -eq 0) ("Production command inventory contains unclassified policy entries in {0}: {1}" -f $script.Name, (($issues | ForEach-Object Message) -join '; '))
    }
}

Assert-ProductionPolicyClassification

Write-Host 'Validation AST policy tests passed.'
