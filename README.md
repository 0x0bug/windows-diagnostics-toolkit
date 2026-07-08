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
service, firewall, DNS, routing, power, or system configuration.

Some Windows storage and network cmdlets may expose less detail without elevated
permissions. When a command is unavailable or access is restricted, scripts print
a warning and continue where possible.

## Quick Start

Clone the repository and run a script from the repository root:

```powershell
git clone https://github.com/0x0bug/windows-diagnostics-toolkit.git
cd windows-diagnostics-toolkit

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\system-info.ps1
pwsh -NoProfile -File .\scripts\network-check.ps1
pwsh -NoProfile -File .\scripts\disk-health.ps1
```

If your execution policy blocks local scripts, use the one-command bypass shown
above for that script run. The command does not change the machine-wide execution
policy.

## Scripts

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
