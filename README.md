# Windows Diagnostics Toolkit

[![Windows 10/11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows)](https://github.com/0x0bug/windows-diagnostics-toolkit)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE?logo=powershell)](https://github.com/0x0bug/windows-diagnostics-toolkit)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![No telemetry](https://img.shields.io/badge/telemetry-none-2ea44f)](SECURITY.md)

<p align="center">
  <img src="site/assets/tui-wide-real.png" alt="Windows Diagnostics Toolkit interactive Wide dashboard" width="100%">
</p>

**Generate a local Windows support report with diagnostics that are read-only by design and guarded by automated safety checks.**

Windows Diagnostics Toolkit is an open-source PowerShell toolkit for Windows 10 and Windows 11. It collects security, performance, network, disk, crash, service, Event Log, time-sync, and Windows Update context into local TXT and optional Markdown reports.

- Read-only by design with automated safety checks
- Interactive responsive terminal interface
- No installer or third-party PowerShell modules
- No telemetry, upload, remote collection, or automatic fixes
- Local reports with an aggregated `OK` / `WARN` / `ERROR` findings summary
- Optional Privacy Mode for reports that will be shared
- Compatible with Windows PowerShell 5.1 and PowerShell 7

[Project website](https://0x0bug.github.io/windows-diagnostics-toolkit/) · [Usage guide](docs/usage.md) · [Anonymized report example](docs/report-example.md) · [Report a problem](https://github.com/0x0bug/windows-diagnostics-toolkit/issues/new/choose)

## Quick start

Clone the repository and run the entry point without switches:

```powershell
git clone https://github.com/0x0bug/windows-diagnostics-toolkit.git
cd windows-diagnostics-toolkit
.\Invoke-WindowsDiagnostics.ps1
```

The planned `v0.1.0-beta` publication will also make this fixed-release bootstrap available:

```powershell
irm https://0x0bug.github.io/windows-diagnostics-toolkit/run.ps1 | iex
```

Until that beta is published, use the clone command above. The bootstrap downloads only the `v0.1.0-beta` GitHub Release ZIP and verifies its published SHA-256 checksum before extraction or execution. To inspect the bootstrap first:

```powershell
irm https://0x0bug.github.io/windows-diagnostics-toolkit/run.ps1 -OutFile .\wdt-run.ps1
notepad .\wdt-run.ps1
.\wdt-run.ps1
```

The checksum protects the release ZIP after download, but `irm | iex` still requires trust in the bootstrap delivered through GitHub Pages. Cloning remains the development and source-inspection method.

Running without switches opens the interactive TUI. Recommended diagnostics, Privacy Mode, and Markdown export are enabled by default.

If Windows PowerShell reports that script execution is disabled, use this process-only launch command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-WindowsDiagnostics.ps1
```

The one-run execution-policy bypass applies only to the new PowerShell process. It does not change the machine-wide or current-user execution policy.

If PowerShell reports that `pwsh` is not recognized, PowerShell 7 is not installed or is not available on `PATH`; installing PowerShell 7 is optional because the toolkit supports the built-in Windows PowerShell 5.1 command above.

## Interactive TUI

The dashboard lets you select diagnostics, toggle Privacy Mode and Markdown export, choose an output directory, run collection, and return to the menu without restarting the script.

| Key | Action |
| --- | --- |
| `Up` / `Down` | Move through menu items |
| `Space` | Toggle the selected diagnostic or option |
| `Enter` | Run the highlighted action |
| `A` | Select all diagnostics |
| `R` | Restore the recommended selection |
| `Esc` | Exit |

The layout responds to terminal resizing and preserves the current selection:

| Layout | Minimum terminal size | Behavior |
| --- | ---: | --- |
| Wide | `110x28` | Full two-column dashboard and large logo |
| WideShort | `110x22` | Two columns with a compact header |
| Normal | `60x25` | Single-column interface |
| Compact | `40x18` | Scrollable viewport |
| TooSmall | below `40x18` | Resize prompt |

A terminal around `120x30` or larger is recommended for the full dashboard.

### Unicode and ASCII logo modes

In automatic mode, the Wide dashboard uses the Unicode block logo when output is interactive and UTF-8. PowerShell sessions using an OEM encoding such as `cp866`, redirected output, and unsupported hosts receive the printable ASCII fallback.

Override the logo selection for the current PowerShell process:

```powershell
$env:WDT_TUI_LOGO = 'auto'
$env:WDT_TUI_LOGO = 'unicode'
$env:WDT_TUI_LOGO = 'ascii'
```

`unicode` is still blocked for redirected output. Remove the override with:

```powershell
Remove-Item Env:WDT_TUI_LOGO -ErrorAction SilentlyContinue
```

### Review the result

After collection completes, the TUI shows the elapsed time, report paths, and the number of `WARN` and `ERROR` findings. `Enter` returns to the menu and `Esc` exits.

<p align="center">
  <img src="site/assets/tui-result-real.png" alt="Windows Diagnostics Toolkit completed diagnostics screen" width="100%">
</p>

A `WARN` means the toolkit found a condition worth reviewing. It does not mean the collection failed. A non-zero module exit code is reported separately as an execution failure.

## Command-line mode

Explicit module switches run diagnostics immediately without opening the TUI:

```powershell
.\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
.\Invoke-WindowsDiagnostics.ps1 -Module System,Network
.\Invoke-WindowsDiagnostics.ps1 -Module Events,Updates
.\Invoke-WindowsDiagnostics.ps1 -System -Security -Network
.\Invoke-WindowsDiagnostics.ps1 -Network -NoExternalNetworkTests
.\Invoke-WindowsDiagnostics.ps1 -Network -NetworkDnsTestName www.microsoft.com -NetworkHttpsEndpoint https://www.microsoft.com/ -NetworkIcmpTarget 1.1.1.1
```

`-Module` is the general selector for built-in registry IDs. IDs are matched without regard to case, duplicates are removed, and execution follows registry order. It can be combined with the legacy switches below. `-All` discovers every reviewed manifest under `modules/`; external plugin directories are not supported.

Each module has an independent 180-second timeout by default; change it with `-ModuleTimeoutSeconds`. On timeout WDT makes a bounded best-effort cleanup of the process tree it observed, revalidating PID, parent relationship, and creation time before termination. Cleanup failures are reported explicitly; absolute protection from every PID-reuse race is not claimed. Other module results are preserved, and the report records `MODULE_EXECUTION_TIMEOUT`, execution status, duration, and partial completeness.

Windows PowerShell 5.1 non-interactive example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
```

Without module selectors the Windows PowerShell command opens the TUI. With `-All`, `-Module`, or one or more legacy module switches it runs directly in command-line mode.

Reports are written to the current directory unless `-OutputDirectory` is provided:

```text
WindowsDiagnosticsReport-YYYYMMDD-HHMMSS.txt
WindowsDiagnosticsReport-YYYYMMDD-HHMMSS.md
```

## What it checks

| Area | Read-only context collected |
| --- | --- |
| System | Windows version, CPU, memory, GPU, uptime, system drive |
| Security | Defender, Firewall, Secure Boot, TPM, BitLocker status |
| Performance | Memory, three short CPU samples, pagefile, process CPU activity deltas, memory and cumulative CPU time |
| Network | Adapters, route/default gateway, system DNS resolution, TCP to a configured HTTPS endpoint, and optional ICMP |
| Time | W32Time service, timezone, clock, source, status, optional events |
| Storage | Windows-reported storage state, available reliability counters, and volume free space |
| Crashes | Grouped Application Error, Application Hang, WER, BugCheck, Reliability Monitor, and dump-file context; findings account for recency and repetition |
| Event Log | Grouped recent Critical and Error context from System and Application; only a small documented high-signal subset creates findings |
| Services | Service states, startup entries with conservative `Enabled`/`Disabled`/`Unknown` state, and scheduled tasks; stopped services and optional inventories remain context unless a stronger signal is present |
| Windows Update | Version, recent updates, reboot indicators, service context, and grouped installation or download failures |

The report begins with a findings summary so the user can see what needs attention before reading every section.

Event Log severity by itself does not prove that Windows is unhealthy: generic Critical and Error events remain diagnostic context rather than automatic `WARN` or `ERROR` findings. Repeated evidence is grouped with a count and first/last timestamps. The default lookback is 24 hours for Event Log, 7 days for crashes and hangs, and 30 days for Windows Update; evidence outside the selected window does not affect findings. A stopped Windows Update service is also context because manual and trigger-start services can be idle normally.

## Share reports safely

Use Privacy Mode when attaching a report to a GitHub issue, forum post, chat, or support request:

```powershell
.\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
```

Privacy Mode replaces identifying values with stable per-report tokens:

```text
<HOST-1>
<USER-1>
<IP-1>
<MAC-1>
<ID-1>
```

Process, application, and dump-file names remain visible because they are diagnostically useful. Proxy credentials and sensitive URL query values are removed from combined reports even when Privacy Mode is disabled.

Review every report before publishing it. Standalone module output is raw and local; Privacy Mode applies to reports generated by `Invoke-WindowsDiagnostics.ps1`. Privacy Mode cannot guarantee removal of arbitrary sensitive text embedded in Windows Event Log messages.

## Run selected checks

Use registry IDs for the general selector:

```powershell
.\Invoke-WindowsDiagnostics.ps1 -Module System,Network
.\Invoke-WindowsDiagnostics.ps1 -Module Events,Updates
```

The existing individual switches remain supported for compatibility:

```powershell
.\Invoke-WindowsDiagnostics.ps1 -System
.\Invoke-WindowsDiagnostics.ps1 -Security
.\Invoke-WindowsDiagnostics.ps1 -Performance
.\Invoke-WindowsDiagnostics.ps1 -Network
.\Invoke-WindowsDiagnostics.ps1 -Time
.\Invoke-WindowsDiagnostics.ps1 -Disk
.\Invoke-WindowsDiagnostics.ps1 -Crashes
.\Invoke-WindowsDiagnostics.ps1 -Events
.\Invoke-WindowsDiagnostics.ps1 -Services
.\Invoke-WindowsDiagnostics.ps1 -Updates
```

Selectors can be combined:

```powershell
.\Invoke-WindowsDiagnostics.ps1 -System -Network -Disk -OutputDirectory .\reports
```

See the [usage guide](docs/usage.md) for standalone module parameters, TUI behavior, output semantics, and troubleshooting.

## Safety model

The production scripts do not change network, disk, registry, services, scheduled tasks, Windows Update, firewall, DNS, routing, power, or system configuration.

Repository validation includes:

- strict declarative manifest and package-containment checks
- PowerShell parser checks
- an AST-based guard against dangerous or mutating commands for every package `.ps1`
- narrow allowlists for reviewed diagnostic-only native process calls
- detection of generated reports, logs, temporary files, and backup files left in the repository
- tests in both PowerShell 7 and Windows PowerShell 5.1

The safety guard reduces accidental scope expansion, but it is not a formal proof. Review the source before running any administrative tool on a sensitive machine.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+
- No third-party runtime dependencies
- Administrator rights are not required for normal use where Windows exposes the requested data to the current user

Reports state elevation and execution completeness: `Success` is `Complete`, timeout or non-zero exit is `Partial`, and launch failure or cancellation is `Unavailable`. Overall collection is `Unavailable` only when every selected module is unavailable, `Partial` when any result is partial or unavailable alongside another result, and otherwise `Complete`. Standard-user execution is not itself a problem. Completeness does not infer individual data-source availability from finding names.

## Validation

PowerShell 7:

```powershell
pwsh -NoProfile -File .\scripts\validate.ps1
```

Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1
```

The GitHub Actions workflow runs validation, dependency-free tests, and a report smoke test on pull requests and pushes to `main`.

## Documentation

- [Detailed usage](docs/usage.md)
- [Built-in module authoring](docs/module-authoring.md)
- [Anonymized TXT and Markdown report](docs/report-example.md)
- [Project website and troubleshooting cases](site/index.html)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

MIT. See [LICENSE](LICENSE).
