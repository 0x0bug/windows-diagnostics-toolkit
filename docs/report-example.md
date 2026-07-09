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
Selected      : System Information, Network Check, Disk Health, Event Log Check, Services Check, Windows Update Check

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
InstalledBy: ExampleUser

HotFixID   : KB5000002
Description: Update
InstalledOn: 07/05/2026 00:00:00
InstalledBy: ExampleUser

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
- Computer name: `DESKTOP-EXAMPLE`
- Mode: `read-only`
- TXT report: `C:\Example\WindowsDiagnosticsReport-20260709-101530.txt`
- Selected: `System Information, Event Log Check, Services Check, Windows Update Check`

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
