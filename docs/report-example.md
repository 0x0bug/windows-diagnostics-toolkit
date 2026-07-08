# Support Report Example

This is an anonymized example of the report structure created by
`Invoke-WindowsDiagnostics.ps1`. Values such as computer names, addresses, MAC
addresses, and labels are placeholders.

## TXT Report

```text
Windows Diagnostics Toolkit - Support Report
Created at    : 2026-07-09 10:15:30 +02:00
Computer name : DESKTOP-EXAMPLE
Mode          : read-only
Output        : C:\Example\WindowsDiagnosticsReport-20260709-101530.txt
Selected      : System Information, Network Check, Disk Health

== System Information ==
Command: pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\system-info.ps1
Exit code: 0

Windows Diagnostics Toolkit - System Information
Mode: read-only

== Windows ==
Computer name : DESKTOP-EXAMPLE
Caption       : Microsoft Windows 11 Pro
Version       : 10.0.26100
Build number  : 26100
Last boot     : 07/09/2026 08:12:00
Uptime        : 0 days, 02:03:30

== Hardware ==
CPU           : Example CPU
Memory        : 32.00 GB
GPU           : Example GPU

== System Drive ==
Drive         : C:
File system   : NTFS
Size          : 930.00 GB
Free space    : 420.00 GB
Free percent  : 45.2%

== Network Check ==
Command: pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\network-check.ps1
Exit code: 0

Windows Diagnostics Toolkit - Network Check
Mode: read-only

== Active Network Adapters ==
Name        : Ethernet
Description : Example Network Adapter
Status      : Up
MAC         : 00-00-00-00-00-00
IPv4        : 192.0.2.10
IPv6        : None
Gateway     : 192.0.2.1
DNS servers : 192.0.2.53

== Gateway Reachability ==
192.0.2.1: Reachable

== DNS Resolution ==
github.com: Resolved: 192.0.2.80

== Internet Connectivity ==
8.8.8.8: Reachable

== Disk Health ==
Command: pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\disk-health.ps1
Exit code: 0

Windows Diagnostics Toolkit - Disk Health
Mode: read-only

== Physical Disks ==
Name         : ExampleDisk
Model        : ExampleDisk
Media type   : SSD
Health       : Healthy
Size         : 930.00 GB
Source       : Get-PhysicalDisk

== Volumes ==
Drive        : C:
Label        : ExampleDrive
File system  : NTFS
Size         : 930.00 GB
Free space   : 420.00 GB
Free percent : 45.2%
Source       : Get-Volume
```

## Markdown Report

````markdown
# Windows Diagnostics Toolkit - Support Report

- Created at: `2026-07-09 10:15:30 +02:00`
- Computer name: `DESKTOP-EXAMPLE`
- Mode: `read-only`
- TXT report: `C:\Example\WindowsDiagnosticsReport-20260709-101530.txt`
- Selected: `System Information`

## System Information

- Command: `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\system-info.ps1`
- Exit code: `0`

```text
Windows Diagnostics Toolkit - System Information
Mode: read-only

== Windows ==
Computer name : DESKTOP-EXAMPLE
Caption       : Microsoft Windows 11 Pro
Version       : 10.0.26100
Build number  : 26100
```
````
