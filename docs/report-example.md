# Support Report Example

This page shows illustrative anonymized excerpts of the TXT and Markdown report format produced by:

```powershell
.\Invoke-WindowsDiagnostics.ps1 -All -PrivacyMode -ExportMarkdown
```

Privacy Mode assigns stable typed tokens within one report and resets the token map before the next report. Process, application, and dump-file names remain visible because they are diagnostically useful.

## TXT report

```text
Windows Diagnostics Toolkit - Support Report
Toolkit version : 0.2.0-beta.2
Created at    : 2026-07-12 10:15:30 +02:00
Computer name : <HOST-1>
Mode          : read-only
Privacy mode  : enabled
Elevation     : Standard user
Collection completeness: Complete
Output        : <USER-1>\WindowsDiagnosticsReport-20260712-101530-0123456789abcdef0123456789abcdef.txt
Selected      : System Information, Security Posture, Performance Snapshot, Network Check, Time Sync Diagnostics, Disk Health, Crash and Hang Diagnostics, Event Log Check, Services Check, Windows Update Check

== Findings Summary ==
Overall status : WARN
Errors         : 0
Warnings       : 3
OK modules     : 7

[WARN] Security Posture / SECURITY_BITLOCKER_NOT_PROTECTED - One or more BitLocker volumes are not protected.
[WARN] Time Sync Diagnostics / TIME_SOURCE_LOCAL_CLOCK - Windows Time is using a local clock source.
[WARN] Services Check / SERVICE_EXIT_CODE_NONZERO - 1 service(s) report an actionable non-zero service exit code. Evidence: ExampleService=Stopped (Auto), ExitCode=1067
[OK] System Information - No findings.
[OK] Performance Snapshot - No findings.
[OK] Network Check - No findings.
[OK] Disk Health - No findings.
[OK] Crash and Hang Diagnostics - No findings.
[OK] Event Log Check - No findings.
[OK] Windows Update Check - No findings.

== System Information ==
Command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File modules\system\diagnostic.ps1
Exit code: 0

Windows Diagnostics Toolkit - System Information
Mode: read-only

== Windows ==
Computer name : <HOST-1>
Caption       : Microsoft Windows 11 Pro
Version       : 10.0.26100
Build number  : 26100
Last boot     : 07/12/2026 08:12:00
Uptime        : 0 days, 02:03:30

== Hardware ==
CPU           : Example CPU
Memory        : 32.00 GB
GPU           : Example GPU

== Security Posture ==
Command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File modules\security\diagnostic.ps1
Exit code: 0

== Defender ==
Antivirus enabled    : Enabled
Real-time protection : Enabled

== Firewall Profiles ==
Domain  : Enabled
Private : Enabled
Public  : Enabled

== BitLocker ==
Volume            : C:\
Protection status : Off
Volume status     : FullyDecrypted

== Network Check ==
Command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File modules\network\diagnostic.ps1
Exit code: 0

== Active Network Adapters ==
Name        : Ethernet
Status      : Up
MAC         : <MAC-1>
IPv4        : <IP-1>
Gateway     : <IP-2>
DNS servers : <IP-3>
DHCP        : Enabled

== WinINET Proxy ==
Enabled        : Enabled
Proxy server   : <ID-1>
Auto config URL: <ID-2>

== Time Sync Diagnostics ==
Command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File modules\time\diagnostic.ps1
Exit code: 0

== Windows Time Service ==
Name          : W32Time
State         : Running
Start mode    : Auto
Domain joined : False

== Time Source ==
Source: Local CMOS Clock

== W32tm Status ==
Source: Local CMOS Clock

== Disk Health ==
Command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File modules\disk\diagnostic.ps1
Exit code: 0

== Physical Disks ==
Name       : ExampleDisk
Media type : SSD
Health     : Healthy
Size       : 930.00 GB

== Services Check ==
Command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File modules\services\diagnostic.ps1
Exit code: 0

== Services With Actionable Exit Codes ==
Name        : ExampleService
DisplayName : Example Service
State       : Stopped
StartMode   : Auto
ExitCode    : 1067

== Windows Update Check ==
Command: powershell.exe -NoProfile -ExecutionPolicy Bypass -File modules\updates\diagnostic.ps1
Exit code: 0

== Pending Reboot ==
Pending reboot : No
Indicators found: None
```

## Markdown report

````markdown
# Windows Diagnostics Toolkit - Support Report

- Toolkit version: `0.2.0-beta.2`
- Created at: `2026-07-12 10:15:30 +02:00`
- Computer name: `<HOST-1>`
- Mode: `read-only`
- Privacy mode: `enabled`
- Elevation: `Standard user`
- Collection completeness: `Complete`
- TXT report: `<USER-1>\WindowsDiagnosticsReport-20260712-101530-0123456789abcdef0123456789abcdef.txt`
- Selected: `System Information, Security Posture, Performance Snapshot, Network Check, Time Sync Diagnostics, Disk Health, Crash and Hang Diagnostics, Event Log Check, Services Check, Windows Update Check`

## Findings Summary

- Overall status: `WARN`
- Errors: `0`
- Warnings: `3`
- OK modules: `7`

- `[WARN]` **Security Posture / SECURITY_BITLOCKER_NOT_PROTECTED** - One or more BitLocker volumes are not protected.
- `[WARN]` **Time Sync Diagnostics / TIME_SOURCE_LOCAL_CLOCK** - Windows Time is using a local clock source.
- `[WARN]` **Services Check / SERVICE_EXIT_CODE_NONZERO** - 1 service(s) report an actionable non-zero service exit code. Evidence: ExampleService=Stopped (Auto), ExitCode=1067
- `[OK]` **System Information** - No findings.
- `[OK]` **Performance Snapshot** - No findings.
- `[OK]` **Network Check** - No findings.
- `[OK]` **Disk Health** - No findings.
- `[OK]` **Crash and Hang Diagnostics** - No findings.
- `[OK]` **Event Log Check** - No findings.
- `[OK]` **Windows Update Check** - No findings.

## System Information

- Exit code: `0`

```text
Windows Diagnostics Toolkit - System Information
Mode: read-only

== Windows ==
Computer name : <HOST-1>
Caption       : Microsoft Windows 11 Pro
Build number  : 26100
```

## Time Sync Diagnostics

- Exit code: `0`

```text
== Windows Time Service ==
Name          : W32Time
State         : Running
Start mode    : Auto

== Time Source ==
Source: Local CMOS Clock
```
````

The real report includes execution status, duration, completeness, and available output for every selected module. These excerpts omit some fields and sections. An automatic service being stopped alone remains indeterminate; this example's warning requires the actionable exit code. Privacy Mode protects complete proxy/PAC values with opaque ID tokens, not just embedded credentials. Always review the generated file before posting it publicly.
