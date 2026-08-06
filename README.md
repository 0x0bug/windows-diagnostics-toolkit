# Windows Diagnostics Toolkit

[![PowerShell Validation](https://github.com/0x0bug/windows-diagnostics-toolkit/actions/workflows/powershell-validation.yml/badge.svg)](https://github.com/0x0bug/windows-diagnostics-toolkit/actions/workflows/powershell-validation.yml)
[![Release](https://img.shields.io/badge/release-v0.1.0--beta-orange)](https://github.com/0x0bug/windows-diagnostics-toolkit/releases/tag/v0.1.0-beta)
[![Windows 10/11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows)](https://github.com/0x0bug/windows-diagnostics-toolkit)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE?logo=powershell)](https://github.com/0x0bug/windows-diagnostics-toolkit)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![No telemetry](https://img.shields.io/badge/telemetry-none-2ea44f)](SECURITY.md)

<p align="center">
  <img src="https://wdt.digital/assets/tui-wide-real.png" alt="Windows Diagnostics Toolkit interactive Wide dashboard" width="100%">
</p>

**One command. One local Windows support report. No automatic fixes, uploads, or configuration changes.**

Windows Diagnostics Toolkit (WDT) is an open-source PowerShell toolkit for the first-pass diagnosis of Windows 10 and Windows 11 systems. It collects high-signal system, security, performance, network, storage, crash, service, Event Log, time-sync, and Windows Update context into a readable local report.

WDT is useful when you need to:

- collect consistent diagnostic context before troubleshooting;
- prepare a report for a system administrator or support engineer;
- compare several Windows machines using the same checks;
- gather evidence without installing an agent or changing system settings;
- share a redacted report through Privacy Mode.

[Project website](https://wdt.digital/) · [Usage guide](docs/usage.md) · [Anonymized report example](docs/report-example.md) · [`v0.1.0-beta` release](https://github.com/0x0bug/windows-diagnostics-toolkit/releases/tag/v0.1.0-beta) · [Report a problem](https://github.com/0x0bug/windows-diagnostics-toolkit/issues/new/choose)

## Why WDT

| Property | What it means |
| --- | --- |
| Read-only by design | Production diagnostics collect state; they do not repair or reconfigure Windows |
| Local-first | Reports stay on the machine unless you choose to share them |
| Actionable summary | Findings are grouped as `OK`, `WARN`, or `ERROR` before the detailed evidence |
| No installation | No installer, service, agent, or third-party PowerShell module is required |
| Shareable output | TXT output is built in; Markdown and Privacy Mode are available |
| Broad compatibility | Windows PowerShell 5.1 and PowerShell 7 are supported |

## Quick start

`v0.1.0-beta` is available as a public prerelease.

```powershell
irm https://wdt.digital/run.ps1 | iex
```

The fixed-release bootstrap downloads only the `v0.1.0-beta` ZIP and its `.sha256` file from the [GitHub prerelease](https://github.com/0x0bug/windows-diagnostics-toolkit/releases/tag/v0.1.0-beta). It verifies the ZIP before extraction; if the hash does not match, nothing is extracted or executed. The toolkit runs from a temporary directory and is not installed permanently.

To inspect the bootstrap before running it:

```powershell
irm https://wdt.digital/run.ps1 -OutFile .\wdt-run.ps1
notepad .\wdt-run.ps1
.\wdt-run.ps1
```

SHA-256 verification protects the downloaded release ZIP, not `run.ps1`. The `irm | iex` form still requires trust in the bootstrap served by GitHub Pages. Inspect it first on sensitive systems.

### Clone and inspect the complete source

```powershell
git clone https://github.com/0x0bug/windows-diagnostics-toolkit.git
cd windows-diagnostics-toolkit
.\Invoke-WindowsDiagnostics.ps1
```

Running without switches opens the interactive TUI. Recommended diagnostics, Privacy Mode, and Markdown export are enabled by default.

If Windows PowerShell reports that script execution is disabled, use this process-only launch command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-WindowsDiagnostics.ps1
```

The one-run execution-policy bypass applies only to the new PowerShell process. It does not change the machine-wide or current-user execution policy.

If PowerShell reports that `pwsh` is not recognized, PowerShell 7 is not installed or is not available on `PATH`; installing PowerShell 7 is optional because WDT supports the built-in Windows PowerShell 5.1 command above.

## What happens during a run

1. WDT discovers the reviewed built-in diagnostic modules.
2. Each selected module runs in an isolated child PowerShell process with an independent timeout.
3. Results are normalized into a combined findings summary and detailed evidence sections.
4. WDT writes the report locally and displays its path and completion status.

Default output depends on launch mode:

| Mode | Default report directory |
| --- | --- |
| Interactive TUI | `.\WindowsDiagnosticsReports` |
| Command-line mode | Current working directory |

Use `-OutputDirectory` to override the default in either mode.

Generated filenames:

```text
WindowsDiagnosticsReport-YYYYMMDD-HHMMSS.txt
WindowsDiagnosticsReport-YYYYMMDD-HHMMSS.md
```

When report generation succeeds, WDT writes TXT even if some selected modules are partial or unavailable. Markdown export is optional in command-line mode and enabled by default in the interactive TUI.

## What it checks

| Area | Diagnostic context |
| --- | --- |
| System | Windows version, CPU, memory, GPU, uptime, and system drive |
| Security | Microsoft Defender, Firewall, Secure Boot, TPM, and BitLocker status |
| Performance | Memory, short CPU samples, pagefile, and process activity snapshots |
| Network | Adapters, routes, gateway, DNS, proxy context, TCP reachability, and optional ICMP |
| Time | Windows Time service, timezone, clock, source, status, and optional events |
| Storage | Windows-reported storage state, available reliability counters, and free space |
| Crashes | Application crashes, hangs, WER, BugChecks, Reliability Monitor, and dump metadata |
| Event Log | Grouped recent high-signal System and Application events |
| Services | Services, startup entries, and scheduled tasks with conservative classification |
| Windows Update | Installed updates, reboot indicators, services, and grouped failures |

WDT does not treat every stopped service or every Critical/Error event as proof of a fault. Findings are created only where the available evidence meets the module's documented classification rules.

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

The interface adapts to the terminal size and preserves the current selection:

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

### Result screen

After collection completes, WDT shows the elapsed time, report paths, collection completeness, and the number of `WARN` and `ERROR` findings.

<p align="center">
  <img src="https://wdt.digital/assets/tui-result-real.png" alt="Windows Diagnostics Toolkit completed diagnostics screen" width="100%">
</p>

A `WARN` means the toolkit found a condition worth reviewing. It does not mean the collection failed. Module execution failures and diagnostic findings are reported separately.

## Command-line mode

Use `-All`, `-Module`, or individual module switches to skip the TUI:

```powershell
.\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
.\Invoke-WindowsDiagnostics.ps1 -Module System,Network
.\Invoke-WindowsDiagnostics.ps1 -Module Events,Updates
.\Invoke-WindowsDiagnostics.ps1 -System -Security -Network
.\Invoke-WindowsDiagnostics.ps1 -Network -NoExternalNetworkTests
```

`-Module` accepts built-in manifest IDs without regard to case. Duplicate IDs are removed, and modules execute in registry order. It can be combined with the individual compatibility switches.

With `-All`, `-Module`, or one or more legacy module switches it runs directly in command-line mode.

Windows PowerShell 5.1 non-interactive example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
```

Choose a report directory explicitly when needed:

```powershell
.\Invoke-WindowsDiagnostics.ps1 -System -Network -Disk `
  -OutputDirectory .\reports
```

Each module has an independent 180-second timeout by default. Change it with `-ModuleTimeoutSeconds`. A timed-out or failed module is reported as partial or unavailable while results from other modules are preserved.

See the [usage guide](docs/usage.md) for all parameters, standalone module commands, classification semantics, and troubleshooting.

## Share reports safely

Enable Privacy Mode before attaching a report to an issue, forum post, chat, or support request:

```powershell
.\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
```

Privacy Mode replaces identifying values with stable per-report tokens such as:

```text
<HOST-1>
<USER-1>
<IP-1>
<MAC-1>
<ID-1>
```

Process, application, and dump-file names remain visible because they are diagnostically useful. Proxy credentials and sensitive URL query values are removed from combined reports even when Privacy Mode is disabled.

Review every report before publishing it. Privacy Mode cannot guarantee removal of arbitrary sensitive text embedded in Windows Event Log messages. Standalone module output is raw and local; Privacy Mode applies to combined reports generated by `Invoke-WindowsDiagnostics.ps1`.

## Safety and trust model

Production diagnostics do not change network, disk, registry, services, scheduled tasks, Windows Update, firewall, DNS, routing, power, or system configuration.

Repository validation includes:

- strict module manifest and package-containment checks;
- PowerShell parser validation;
- an AST-based guard against dangerous or mutating commands in package scripts;
- narrow allowlists for reviewed diagnostic-only native process calls;
- checks for generated reports, logs, temporary files, and backups left in the repository;
- tests in PowerShell 7 and Windows PowerShell 5.1.

These controls reduce accidental scope expansion; they are not a formal proof of safety. Review the source before running any administrative tool on a sensitive machine.

## Requirements and limitations

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+
- No third-party runtime dependencies
- Administrator rights are optional

Some Windows data sources expose less detail without elevation. WDT records unavailable data and continues where possible. Standard-user execution is not itself a failure.

WDT is a collection and triage tool, not a repair utility, antivirus product, complete SMART/NVMe diagnostic, packet capture system, or substitute for expert incident response.

## Development

Run repository validation with PowerShell 7:

```powershell
pwsh -NoProfile -File .\scripts\validate.ps1
```

Or with Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1
```

GitHub Actions runs validation, dependency-free tests, and a live report smoke test on pull requests and pushes to `main`.

Contributor documentation:

- [Built-in module authoring](docs/module-authoring.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## Documentation

- [Detailed usage](docs/usage.md)
- [Anonymized TXT and Markdown report](docs/report-example.md)
- [Project website](https://wdt.digital/)
- [Issue tracker](https://github.com/0x0bug/windows-diagnostics-toolkit/issues)

## License

MIT. See [LICENSE](LICENSE).
