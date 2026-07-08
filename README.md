# Windows Diagnostics Toolkit

Small PowerShell toolkit for read-only diagnostics on Windows 10 and Windows 11.

The project is intentionally dependency-free and safe to run on a local machine.
Scripts print diagnostic information and do not change system settings.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+
- No third-party modules

## Scripts

This repository will include:

- `scripts/system-info.ps1` - Windows, CPU, memory, GPU, uptime, and system drive summary
- `scripts/network-check.ps1` - network adapter, IP, DNS, gateway, DNS resolution, and internet checks
- `scripts/disk-health.ps1` - physical disk health and volume free-space checks

## Usage

Run scripts from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\system-info.ps1
pwsh -NoProfile -File .\scripts\network-check.ps1
pwsh -NoProfile -File .\scripts\disk-health.ps1
```

## Safety

These scripts are read-only. They collect and print local diagnostic data without
changing network, disk, registry, service, or system configuration.

## License

MIT
