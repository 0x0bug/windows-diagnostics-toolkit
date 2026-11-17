# Windows Diagnostics Toolkit

[![PowerShell Validation](https://github.com/0x0bug/windows-diagnostics-toolkit/actions/workflows/powershell-validation.yml/badge.svg)](https://github.com/0x0bug/windows-diagnostics-toolkit/actions/workflows/powershell-validation.yml)
[![Release](https://img.shields.io/badge/release-v0.2.0--beta.2-orange)](https://github.com/0x0bug/windows-diagnostics-toolkit/releases/tag/v0.2.0-beta.2)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Read-only Windows diagnostics for PowerShell. WDT collects system state and recent failure evidence into a local support report, with a findings summary and optional Privacy Mode.

[Website](https://wdt.digital/) · [Report example](docs/report-example.md) · [Report a problem](https://github.com/0x0bug/windows-diagnostics-toolkit/issues/new/choose)

## Quick start

Requires Windows 10/11 and Windows PowerShell 5.1 or PowerShell 7+. No third-party modules; administrator rights are optional.

```powershell
irm https://wdt.digital/run.ps1 | iex
```

The bootstrap downloads the fixed `v0.2.0-beta.2` release, verifies the ZIP's SHA-256, and runs it from a temporary folder without installation.

SHA-256 verification protects the downloaded release ZIP, not `run.ps1`. Inspect the bootstrap first on sensitive systems; see [installation and source review](docs/usage.md#installation).

Running without switches opens the interactive TUI. Recommended diagnostics, Privacy Mode, and Markdown export are enabled by default.

## What it checks

| Module | Evidence collected |
| --- | --- |
| System | Windows, hardware, memory and uptime |
| Security | Defender, Firewall, Secure Boot, TPM and BitLocker |
| Performance | CPU, memory, pagefile and process activity |
| Network | Adapters, DNS, routes, proxy and reachability |
| Time | Clock, timezone and Windows Time source/status |
| Disk | Storage state, reliability counters and free space |
| Crashes | Application failures, hangs, BugChecks and dump metadata |
| Events | Grouped System and Application events |
| Services | Services, startup entries and scheduled tasks |
| Updates | Installed updates, failures and reboot indicators |

Reports use TXT with optional Markdown. Advanced workflows include [JSON snapshots and offline comparison](docs/usage.md#structured-snapshots-and-offline-comparison) and [incident timelines](docs/usage.md#incident-investigation-by-symptom-and-time).

![WDT interactive diagnostics dashboard](https://wdt.digital/assets/tui-wide-real.png)

## Command-line mode

From an extracted release or a [source checkout](docs/usage.md#installation):

```powershell
.\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
.\Invoke-WindowsDiagnostics.ps1 -Module System,Network -NoExternalNetworkTests -OutputDirectory .\reports
```

For built-in Windows PowerShell, including when script execution is disabled:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
```

The bypass applies only to this process. TUI reports default to `.\WindowsDiagnosticsReports`; CLI reports default to the current directory. Set `-OutputDirectory` to choose another folder.

## Privacy and safety

WDT writes local reports without changing Windows configuration. There are no automatic fixes, telemetry, or report uploads. Network checks can perform DNS, TCP and ICMP probes; use `-NoExternalNetworkTests` to disable external probes.

Privacy Mode redacts common identifiers in combined reports. Standalone output is raw. Review reports before sharing: arbitrary sensitive text in Event Log messages may remain.

Findings and collection status are separate: a warning is not an execution failure, and missing data is not proof of a healthy system. See [findings and exit codes](docs/usage.md#findings-and-exit-codes).

## Documentation

| Guide | Contents |
| --- | --- |
| [Usage guide](docs/usage.md) | TUI controls, options, module reference and troubleshooting |
| [Built-in module authoring](docs/module-authoring.md) | Module manifests, data contracts and safety checks |
| [Contributing](CONTRIBUTING.md) | Development, validation and pull requests |
| [Security policy](SECURITY.md) | Trust boundaries, privacy and vulnerability reporting |
| [Release verification](docs/release-verification.md) | Packaging, delivery and client compatibility checklist |
| [Code of Conduct](CODE_OF_CONDUCT.md) | Community guidelines |
