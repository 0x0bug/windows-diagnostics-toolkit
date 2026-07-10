# Usage Guide

This guide covers basic usage for Windows Diagnostics Toolkit. All scripts are
read-only and safe to run from a normal PowerShell session.

## Prerequisites

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+
- No third-party dependencies

Open PowerShell in the repository root before running examples.

## Run All Checks

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\system-info.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\network-check.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\disk-health.ps1
```

PowerShell 7 examples:

```powershell
pwsh -NoProfile -File .\scripts\system-info.ps1
pwsh -NoProfile -File .\scripts\network-check.ps1
pwsh -NoProfile -File .\scripts\disk-health.ps1
```

## Combined Support Reports

Run the wrapper to collect all checks in one TXT report:

```powershell
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -All
```

Add `-ExportMarkdown` to create a Markdown report alongside the TXT report:

```powershell
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -All -ExportMarkdown
```

Add the opt-in `-PrivacyMode` modifier when the combined report will be shared:

```powershell
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
```

Privacy Mode does not change which diagnostics run. It centrally redacts the
captured module output, findings, headers, and output paths before the wrapper
writes TXT or Markdown. Identical values receive the same typed token within a
report:

- `<HOST-1>` for a computer name
- `<USER-1>` for a user name
- `<IP-1>` for an IPv4 or IPv6 address
- `<MAC-1>` for a MAC address
- `<ID-1>` for a SID, GUID, or device identifier

The numbering is independent for each token type, and the map is reset for each
new report. Process names, application names, and dump-file names remain visible
for diagnostic context. Standalone scripts do not accept `-PrivacyMode`; their
output remains raw and local. The toolkit does not explicitly query process command
lines or BitLocker recovery keys.

Combined reports always replace proxy URL credentials and sensitive query values
with `<REDACTED>`, including when `-PrivacyMode` is not enabled.

Each report starts its diagnostic content with `Findings Summary`. The summary
uses only `OK`, `WARN`, and `ERROR`, groups findings by severity, and lists a
successfully completed module with no findings as `OK`. Overall status uses the
priority `ERROR` > `WARN` > `OK`.

Findings describe diagnostic state and do not change the wrapper exit code. A
non-zero exit code still means that a module failed to execute. Modules emit
internal finding markers for the wrapper to aggregate; those markers are removed
before TXT and Markdown reports are written.

## System Information

`scripts/system-info.ps1` prints operating system, CPU, memory, GPU, uptime, and
system drive information.

```powershell
pwsh -NoProfile -File .\scripts\system-info.ps1
```

Use this script first when you need a quick summary of the local machine.

## Security Posture

`scripts/security-posture.ps1` reads Defender, Windows Firewall, Secure Boot,
TPM, and BitLocker status. It uses read-only cmdlets with CIM fallback where
available. Missing components or access create `WARN` findings without changing
the standalone exit code. Recovery keys, key protectors, and hardening policies
are never displayed.

```powershell
pwsh -NoProfile -File .\scripts\security-posture.ps1
```

Run only this module through the combined-report runner:

```powershell
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -Security -ExportMarkdown
```

## Network Diagnostics

`scripts/network-check.ps1` prints active network adapters, IP addresses, DNS
servers, gateways, and simple connectivity checks.

```powershell
pwsh -NoProfile -File .\scripts\network-check.ps1
```

Optional parameters:

```powershell
pwsh -NoProfile -File .\scripts\network-check.ps1 -DnsTestName github.com -InternetTestHost 8.8.8.8 -TimeoutSeconds 3
```

- `DnsTestName` controls the hostname used for DNS resolution.
- `InternetTestHost` controls the host used for the internet reachability check.
- `TimeoutSeconds` controls the timeout for PowerShell 7 `Test-Connection`.

## Disk Health

`scripts/disk-health.ps1` prints physical disk and volume information. It warns
when a volume has less than 15% free space by default.

```powershell
pwsh -NoProfile -File .\scripts\disk-health.ps1
```

Use a custom warning threshold:

```powershell
pwsh -NoProfile -File .\scripts\disk-health.ps1 -LowFreeSpacePercent 20
```

## Syntax Verification

Check all scripts with the PowerShell parser:

```powershell
$scripts = Get-ChildItem -Path .\scripts -Filter *.ps1
foreach ($script in $scripts) {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $script.FullName,
        [ref]$null,
        [ref]$errors
    ) | Out-Null

    if ($errors.Count -gt 0) {
        Write-Error "$($script.Name) has parser errors"
        $errors | ForEach-Object { $_.Message }
    }
    else {
        Write-Host "$($script.Name): syntax ok"
    }
}
```

## Real Co-Authored Commit

Do not add a fake co-author. A `Co-authored-by` trailer should only be used when
another person made a real contribution to the commit.

A good small collaboration task for this repository is improving
`docs/usage.md`, for example:

- clarify a troubleshooting step
- add an example from another Windows version
- improve wording around elevated permissions

Ask the collaborator for their GitHub noreply email, or tell them how to find it:

1. Open GitHub settings.
2. Go to **Emails**.
3. Copy the noreply address shown by GitHub.

For many accounts it looks like this:

```text
12345678+username@users.noreply.github.com
```

After the collaborator provides a real change, include a trailer in the commit
message:

```text
Co-authored-by: Name <12345678+username@users.noreply.github.com>
```

Example commit command after staging the real shared change:

```powershell
git commit -m "docs: improve usage troubleshooting" -m "Co-authored-by: Name <12345678+username@users.noreply.github.com>"
```

Only use the collaborator's real name and GitHub email with their consent.
