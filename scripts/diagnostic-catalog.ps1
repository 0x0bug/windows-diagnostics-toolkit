[CmdletBinding()]
param()

function Get-WdtDiagnosticDefinition {
    return @(
        [pscustomobject]@{ Name = 'System'; Title = 'System Information'; Label = 'System information'; Script = 'system-info.ps1'; Recommended = $true },
        [pscustomobject]@{ Name = 'Security'; Title = 'Security Posture'; Label = 'Security posture'; Script = 'security-posture.ps1'; Recommended = $true },
        [pscustomobject]@{ Name = 'Performance'; Title = 'Performance Snapshot'; Label = 'Performance snapshot'; Script = 'performance-snapshot.ps1'; Recommended = $true },
        [pscustomobject]@{ Name = 'Network'; Title = 'Network Check'; Label = 'Network'; Script = 'network-check.ps1'; Recommended = $true },
        [pscustomobject]@{ Name = 'Time'; Title = 'Time Sync Diagnostics'; Label = 'Time synchronization'; Script = 'time-sync-diagnostics.ps1'; Recommended = $true },
        [pscustomobject]@{ Name = 'Disk'; Title = 'Storage Status'; Label = 'Storage status'; Script = 'disk-health.ps1'; Recommended = $true },
        [pscustomobject]@{ Name = 'Crashes'; Title = 'Crash and Hang Diagnostics'; Label = 'Crashes and hangs'; Script = 'crash-hang-diagnostics.ps1'; Recommended = $false },
        [pscustomobject]@{ Name = 'Events'; Title = 'Event Log Check'; Label = 'Event logs'; Script = 'event-log-check.ps1'; Recommended = $false },
        [pscustomobject]@{ Name = 'Services'; Title = 'Services and Startup'; Label = 'Services and startup'; Script = 'services-check.ps1'; Recommended = $false },
        [pscustomobject]@{ Name = 'Updates'; Title = 'Windows Update Check'; Label = 'Windows Update'; Script = 'windows-update-check.ps1'; Recommended = $true }
    )
}

function Get-WdtLaunchMode {
    param(
        [bool]$InteractiveRequested,
        [bool]$HasExplicitModuleSelection,
        [bool]$AllRequested,
        [bool]$IsInputRedirected
    )

    if ($InteractiveRequested) {
        if ($IsInputRedirected) { return 'InteractiveUnavailable' }
        return 'Interactive'
    }
    if ($AllRequested -or $HasExplicitModuleSelection) { return 'CommandLine' }
    if ($IsInputRedirected) { return 'InteractiveUnavailable' }
    return 'Interactive'
}
