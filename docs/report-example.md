# Support Report Example

This is an anonymized example of the report structure created by
`Invoke-WindowsDiagnostics.ps1 -PrivacyMode`. Privacy Mode assigns stable typed
tokens within one report and resets its token map before the next report. The
examples use `<HOST-1>`, `<USER-1>`, `<IP-1>`, and `<MAC-1>`;
when present, SIDs, GUIDs, and device identifiers use tokens such as `<ID-1>`.
Process, application, and dump-file names remain visible for diagnostic context.

## TXT Report

```text
Windows Diagnostics Toolkit - Support Report
Created at    : 2026-07-09 10:15:30 +02:00
Computer name : <HOST-1>
Mode          : read-only
Privacy mode  : enabled
Output        : <USER-1>\WindowsDiagnosticsReport-20260709-101530.txt
Selected      : System Information, Security Posture, Network Check, Disk Health, Event Log Check, Services Check, Windows Update Check

== Findings Summary ==
Overall status : ERROR
Errors         : 1
Warnings       : 4
OK modules     : 2

[ERROR] Disk Health / DISK_UNHEALTHY - An example disk reported an unhealthy state. Evidence: Health=Unhealthy
[WARN] Security Posture / SECURITY_BITLOCKER_NOT_PROTECTED - One or more BitLocker volumes are not protected.
[WARN] Network Check / NETWORK_DNS_FAILED - DNS resolution did not complete successfully.
[WARN] Event Log Check / RECENT_ERROR_EVENTS - Recent error events were found.
[WARN] Services Check / SERVICE_STATE_ISSUES - One or more services need attention.
[OK] System Information - No findings.
[OK] Windows Update Check - No findings.

== System Information ==
Command: pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\system-info.ps1
Exit code: 0

Windows Diagnostics Toolkit - System Information
Mode: read-only

== Windows ==
Computer name : <HOST-1>
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

== Security Posture ==
Command: pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\security-posture.ps1
Exit code: 0

Windows Diagnostics Toolkit - Security Posture
Mode: read-only

== Defender ==
Source              : Get-MpComputerStatus
Antivirus enabled   : Enabled
Real-time protection: Enabled

== Firewall Profiles ==
Domain              : Enabled (Get-NetFirewallProfile)
Private             : Enabled (Get-NetFirewallProfile)
Public              : Enabled (Get-NetFirewallProfile)

== Secure Boot ==
Source  : Confirm-SecureBootUEFI
Enabled : Enabled

== TPM ==
Present   : Enabled
Ready     : Enabled

== BitLocker ==
Volume            : C:\
Protection status : Off
Volume status     : FullyDecrypted

== Network Check ==
Command: pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\network-check.ps1
Exit code: 0

Windows Diagnostics Toolkit - Network Check
Mode: read-only

== Active Network Adapters ==
Name        : Ethernet
Description : Example Network Adapter
Status      : Up
MAC         : <MAC-1>
IPv4        : <IP-1>
IPv6        : None
Gateway     : <IP-2>
DNS servers : <IP-3>

== Gateway Reachability ==
<IP-2>: Reachable

== DNS Resolution ==
example.invalid: Resolution failed.

== Internet Connectivity ==
<IP-4>: Reachable

== Disk Health ==
Command: pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\disk-health.ps1
Exit code: 0

Windows Diagnostics Toolkit - Disk Health
Mode: read-only

== Physical Disks ==
Name         : ExampleDisk
Model        : ExampleDisk
Media type   : SSD
Health       : Unhealthy
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

== Event Log Check ==
Command: pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\event-log-check.ps1
Exit code: 0

Windows Diagnostics Toolkit - Event Log Check
Mode: read-only

== Summary ==
Time window     : Last 24 hour(s), since 07/09/2026 10:15:30
Logs checked    : System, Application
Levels included : Critical, Error
Total events    : 2
Displayed events: 2
System         : 1 event(s)
Application    : 1 event(s)

== Top Sources ==
ExampleProvider                                       2

== Recent Events ==
TimeCreated    : 07/09/2026 09:58:00
LogName        : System
Level          : Error
Id             : 1001
ProviderName   : ExampleProvider
Message        : Example service reported a recoverable error.

TimeCreated    : 07/09/2026 09:45:00
LogName        : Application
Level          : Error
Id             : 2002
ProviderName   : ExampleProvider
Message        : Example application event message.

== Services Check ==
Command: pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\services-check.ps1
Exit code: 0

Windows Diagnostics Toolkit - Services Check
Mode: read-only

== Summary ==
Total services                 : 250
Running services               : 120
Automatic services not running : 1
Non-OK service states          : 1
Startup entries included       : False
Scheduled tasks included       : False

== Automatic Services Not Running ==
Name       : ExampleService
DisplayName: Example Service
State      : Stopped
StartMode  : Auto
ExitCode   : 0
ProcessId  : 0

== Non-OK Service States ==
Name       : ExamplePendingService
DisplayName: Example Pending Service
State      : Start Pending
StartMode  : Manual
ExitCode   : 0
ProcessId  : 1234

== Startup Entries ==
Skipped. Use -IncludeStartup to include read-only startup entry checks.

== Scheduled Tasks With Non-Zero Last Result ==
Skipped. Use -IncludeScheduledTasks to include read-only scheduled task checks.

== Windows Update Check ==
Command: pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\windows-update-check.ps1
Exit code: 0

Windows Diagnostics Toolkit - Windows Update Check
Mode: read-only

== Summary ==
Time window         : Last 30 day(s)
Pending reboot     : No
Recent updates     : 2
Event log check    : Skipped
Services checked   : 5

== Windows Version ==
Caption       : Microsoft Windows 11 Pro
Version       : 10.0.26100
BuildNumber   : 26100
InstallDate   : 07/01/2026 10:00:00
LastBootUpTime: 07/09/2026 08:12:00

== Pending Reboot ==
Pending reboot: No
Indicators found: None

== Recent Installed Updates ==
HotFixID   : KB5000001
Description: Security Update
InstalledOn: 07/08/2026 00:00:00
InstalledBy: <USER-1>

HotFixID   : KB5000002
Description: Update
InstalledOn: 07/05/2026 00:00:00
InstalledBy: <USER-1>

== Windows Update Services ==
Name       : wuauserv
DisplayName: Windows Update
State      : Running
StartMode  : Manual

Name       : bits
DisplayName: Background Intelligent Transfer Service
State      : Running
StartMode  : Manual

== Windows Update Events ==
Skipped. Use -IncludeEventLog to include recent Windows Update related events.
```

## Markdown Report

````markdown
# Windows Diagnostics Toolkit - Support Report

- Created at: `2026-07-09 10:15:30 +02:00`
- Computer name: `<HOST-1>`
- Mode: `read-only`
- Privacy mode: `enabled`
- TXT report: `<USER-1>\WindowsDiagnosticsReport-20260709-101530.txt`
- Selected: `System Information, Security Posture, Network Check, Disk Health, Event Log Check, Services Check, Windows Update Check`

## Findings Summary

- Overall status: `WARN`
- Errors: `0`
- Warnings: `3`
- OK modules: `2`

- `[WARN]` **Event Log Check / RECENT_ERROR_EVENTS** - Recent error events were found.
- `[WARN]` **Security Posture / SECURITY_BITLOCKER_NOT_PROTECTED** - One or more BitLocker volumes are not protected.
- `[WARN]` **Services Check / SERVICE_STATE_ISSUES** - One or more services need attention.
- `[OK]` **System Information** - No findings.
- `[OK]` **Windows Update Check** - No findings.

## System Information

- Command: `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\system-info.ps1`
- Exit code: `0`

```text
Windows Diagnostics Toolkit - System Information
Mode: read-only

== Windows ==
Computer name : <HOST-1>
Caption       : Microsoft Windows 11 Pro
Version       : 10.0.26100
Build number  : 26100
```

## Security Posture

- Command: `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\security-posture.ps1`
- Exit code: `0`

```text
Windows Diagnostics Toolkit - Security Posture
Mode: read-only

== Defender ==
Antivirus enabled   : Enabled
Real-time protection: Enabled

== BitLocker ==
Volume            : C:\
Protection status : Off
```

## Event Log Check

- Command: `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\event-log-check.ps1`
- Exit code: `0`

```text
Windows Diagnostics Toolkit - Event Log Check
Mode: read-only

== Summary ==
Time window     : Last 24 hour(s), since 07/09/2026 10:15:30
Logs checked    : System, Application
Levels included : Critical, Error
Total events    : 2
Displayed events: 2

== Recent Events ==
TimeCreated    : 07/09/2026 09:58:00
LogName        : System
Level          : Error
Id             : 1001
ProviderName   : ExampleProvider
Message        : Example service reported a recoverable error.
```

## Services Check

- Command: `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\services-check.ps1`
- Exit code: `0`

```text
Windows Diagnostics Toolkit - Services Check
Mode: read-only

== Summary ==
Total services                 : 250
Running services               : 120
Automatic services not running : 1
Non-OK service states          : 1

== Automatic Services Not Running ==
Name       : ExampleService
DisplayName: Example Service
State      : Stopped
StartMode  : Auto
ExitCode   : 0
ProcessId  : 0
```

## Windows Update Check

- Command: `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File scripts\windows-update-check.ps1`
- Exit code: `0`

```text
Windows Diagnostics Toolkit - Windows Update Check
Mode: read-only

== Summary ==
Time window         : Last 30 day(s)
Pending reboot     : No
Recent updates     : 2
Event log check    : Skipped
Services checked   : 5

== Windows Version ==
Caption       : Microsoft Windows 11 Pro
Version       : 10.0.26100
BuildNumber   : 26100

== Pending Reboot ==
Pending reboot: No
Indicators found: None

== Windows Update Events ==
Skipped. Use -IncludeEventLog to include recent Windows Update related events.
```
````
