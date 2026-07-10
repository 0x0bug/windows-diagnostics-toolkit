# Windows Diagnostics Toolkit

A small PowerShell toolkit for basic read-only diagnostics on Windows 10 and
Windows 11.

The scripts are designed for quick local checks without third-party
dependencies. They print diagnostic information and do not change system
settings.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+
- No third-party PowerShell modules
- Administrator rights are not required for normal use where Windows exposes the
  data to the current user

## Safety

These scripts are read-only. They do not change network, disk, registry,
service, scheduled task, Windows Update, firewall, DNS, routing, power, or
system configuration.

Some Windows storage and network cmdlets may expose less detail without elevated
permissions. When a command is unavailable or access is restricted, scripts print
a warning and continue where possible.

## Validation

Run repository validation locally with PowerShell 7:

```powershell
pwsh -NoProfile -File .\scripts\validate.ps1
```

Run the same validation with Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1
```

Validation checks:

- PowerShell parser errors in production scripts
- AST-based read-only safety guard for dangerous commands
- generated reports, logs, temporary files, and backup files left in the repository

## Quick Start

Clone the repository and create a support report from the repository root:

```powershell
git clone https://github.com/0x0bug/windows-diagnostics-toolkit.git
cd windows-diagnostics-toolkit

pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -All -ExportMarkdown
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -Security
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -Events
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -Services
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -Updates
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -System -Network -OutputDirectory .\reports
```

The wrapper writes `WindowsDiagnosticsReport-YYYYMMDD-HHMMSS.txt` to the current
directory by default. Use `-ExportMarkdown` to also create a Markdown report.

Reports created by the wrapper include a `Findings Summary` before the detailed
module output. Findings use `OK`, `WARN`, and `ERROR` statuses and are grouped by
severity; overall status follows `ERROR` > `WARN` > `OK`. A diagnostic finding
does not change the wrapper exit code; a non-zero
exit code still indicates that a module failed to execute. Internal finding
markers emitted by modules are consumed by the wrapper and are not shown in TXT
or Markdown reports.

Use the wrapper's opt-in `-PrivacyMode` when a combined report will be shared.
The wrapper centrally redacts captured module output, findings, headers, and report
paths before writing TXT or Markdown. Repeated values receive the same typed token
within one report, such as `<HOST-1>`, `<USER-1>`, `<IP-1>`, `<MAC-1>`, or
`<ID-1>`; the token map is reset for every report. Process,
application, and dump-file names remain visible for diagnostic context. Standalone
scripts do not apply this wrapper option and continue to print raw local output.
The toolkit does not explicitly query process command lines or BitLocker recovery keys.
Proxy URL credentials and sensitive query values are replaced with `<REDACTED>`
in combined reports even when Privacy Mode is disabled.

You can also run individual scripts directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\system-info.ps1
pwsh -NoProfile -File .\scripts\network-check.ps1
pwsh -NoProfile -File .\scripts\disk-health.ps1
pwsh -NoProfile -File .\scripts\event-log-check.ps1
pwsh -NoProfile -File .\scripts\services-check.ps1
pwsh -NoProfile -File .\scripts\windows-update-check.ps1
```

If your execution policy blocks local scripts, use the one-command bypass shown
above for that script run. The command does not change the machine-wide execution
policy.

## Scripts

### `Invoke-WindowsDiagnostics.ps1`

Creates a support report by running the existing read-only diagnostics scripts.

Run all checks and save a TXT report in the current directory:

```powershell
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1
```

Run all checks and also export Markdown:

```powershell
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -All -ExportMarkdown
```

Create the same reports with identifying values redacted:

```powershell
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
```

Run selected checks into a custom output directory:

```powershell
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -System -Disk -OutputDirectory .\reports
```

Run only Event Log diagnostics:

```powershell
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -Events
```

Run only Services diagnostics:

```powershell
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -Services
```

Run only Windows Update diagnostics:

```powershell
pwsh -NoProfile -File .\Invoke-WindowsDiagnostics.ps1 -Updates
```

Available parameters:

- `-All` - run system, security, network, disk, Event Log, Services, and Windows Update checks
- `-System` - run only system information unless combined with other selectors
- `-Security` - run only Security Posture diagnostics unless combined with other selectors
- `-Network` - run only network checks unless combined with other selectors
- `-Disk` - run only disk checks unless combined with other selectors
- `-Events` - run only Event Log diagnostics unless combined with other selectors
- `-Services` - run only Services diagnostics unless combined with other selectors
- `-Updates` - run only Windows Update diagnostics unless combined with other selectors
- `-OutputDirectory` - choose where report files are written
- `-ExportMarkdown` - also write a `.md` report
- `-PrivacyMode` - redact identifying values in combined TXT and Markdown reports

See [docs/report-example.md](docs/report-example.md) for an anonymized report
example.

### `scripts/system-info.ps1`

Prints a compact system summary:

- Windows caption, version, and build number
- CPU model
- total physical memory
- GPU model
- last boot time and uptime
- system drive size and free space

Run:

```powershell
pwsh -NoProfile -File .\scripts\system-info.ps1
```

### `scripts/security-posture.ps1`

Reports a read-only security posture summary:

- Microsoft Defender component status
- Windows Firewall profile state
- Secure Boot and TPM availability
- BitLocker volume protection state without recovery keys or key protectors

Unavailable Windows components produce findings with `WARN` and do not make the
standalone script fail.

Run:

```powershell
pwsh -NoProfile -File .\scripts\security-posture.ps1
```

### `scripts/network-check.ps1`

Checks current network state:

- active network adapters
- current IPv4 and IPv6 addresses
- DNS servers
- IPv4 gateway
- gateway reachability
- DNS resolution
- internet reachability

Run:

```powershell
pwsh -NoProfile -File .\scripts\network-check.ps1
```

Optional parameters:

```powershell
pwsh -NoProfile -File .\scripts\network-check.ps1 -DnsTestName example.com -InternetTestHost 1.1.1.1 -TimeoutSeconds 5
```

### `scripts/disk-health.ps1`

Reports disk and volume status:

- physical disk list
- disk model
- media type
- health status
- volume size and free space
- warning when free space is below the configured threshold

Run:

```powershell
pwsh -NoProfile -File .\scripts\disk-health.ps1
```

Optional threshold:

```powershell
pwsh -NoProfile -File .\scripts\disk-health.ps1 -LowFreeSpacePercent 20
```

### `scripts/event-log-check.ps1`

Reads recent Windows Event Log entries from the `System` and `Application` logs.
The script uses `Get-WinEvent` in read-only mode and reports Critical/Error
events from the last 24 hours by default.

Run:

```powershell
pwsh -NoProfile -File .\scripts\event-log-check.ps1
```

Include warnings and adjust the time window:

```powershell
pwsh -NoProfile -File .\scripts\event-log-check.ps1 -SinceHours 48 -IncludeWarnings -MaxEvents 20
```

### `scripts/services-check.ps1`

Checks Windows services and optionally includes read-only startup entry and
scheduled task diagnostics. The script does not start, stop, restart, or modify
services, registry keys, or scheduled tasks.

Run:

```powershell
pwsh -NoProfile -File .\scripts\services-check.ps1
```

Include startup entries and scheduled tasks with non-zero last results:

```powershell
pwsh -NoProfile -File .\scripts\services-check.ps1 -IncludeStartup -IncludeScheduledTasks -MaxItems 20
```

### `scripts/windows-update-check.ps1`

Checks Windows Update related state from built-in read-only sources. The script
does not install updates, start update scans, reset Windows Update components,
clean `SoftwareDistribution`, change services, or write registry values.

Run:

```powershell
pwsh -NoProfile -File .\scripts\windows-update-check.ps1
```

Include recent Windows Update related Event Log entries:

```powershell
pwsh -NoProfile -File .\scripts\windows-update-check.ps1 -IncludeEventLog -SinceDays 14 -MaxEvents 20
```

## Example Output

```text
Windows Diagnostics Toolkit - System Information
Mode: read-only

== Windows ==
Computer name : DESKTOP-EXAMPLE
Caption       : Microsoft Windows 11 Pro
Version       : 10.0.26100
Build number  : 26100
Last boot     : 07/08/2026 09:12:34
Uptime        : 0 days, 05:43:21

== Hardware ==
CPU           : AMD Ryzen 7 5800X 8-Core Processor
Memory        : 32.00 GB
GPU           : NVIDIA GeForce RTX 4070

== System Drive ==
Drive         : C:
File system   : NTFS
Size          : 930.86 GB
Free space    : 421.18 GB
Free percent  : 45.2%
```

## Documentation

See [docs/usage.md](docs/usage.md) for detailed usage, verification commands,
and a note on real co-authored commits.

## License

MIT. See [LICENSE](LICENSE).
