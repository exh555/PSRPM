@{
    # Script module or binary module file associated with this manifest.
    RootModule        = 'PSRPM.psm1'

    # Version number of this module.
    ModuleVersion     = '1.6.0'

    # Supported PSEditions
    CompatiblePSEditions = @('Desktop', 'Core')

    # ID used to uniquely identify this module
    GUID              = '8f4d9a2c-51b7-4e63-9c1e-3a7f2b8d9014'

    # Author of this module
    Author            = 'exh555'

    # Company or vendor of this module
    CompanyName       = 'PSRPM'

    # Copyright statement for this module
    Copyright         = '(c) 2026 exh555. All rights reserved. MIT License.'

    # Description of the functionality provided by this module
    Description       = 'PSRPM (PowerShell Remote Process Manager) - Enterprise-grade, ultra-low-overhead, fileless remote and local process monitoring and management GUI built with WPF and native Reflection.Emit. Documentation & source: https://github.com/exh555/psrpm'

    # Minimum version of the Windows PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Functions to export from this module
    FunctionsToExport = @('Start-PSRPM', 'Start-RemoteProcessManager')

    # Cmdlets to export from this module
    CmdletsToExport   = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport   = @('psrpm')

    # List of all files packaged with this module
    FileList          = @(
        'PSRPM.psd1',
        'PSRPM.psm1',
        'Private\DataCollector.ps1',
        'Private\DeepInspector.ps1',
        'Private\ProcessActions.ps1',
        'Private\RunspaceEngine.ps1',
        'Private\ViewModelClasses.ps1',
        'UI\MainWindow.xaml',
        'UI\PropertiesWindow.xaml',
        'UI\ConnectDialog.xaml',
        'UI\SystemInfoWindow.xaml',
        'UI\HelpWindow.xaml',
        'UI\ServiceDetailWindow.xaml',
        'UI\FindHandleWindow.xaml',
        'Assets\psrpm.ico',
        'Assets\psrpm.png',
        'Assets\psrpm.svg',
        'Assets\psrpm_16.png',
        'Assets\psrpm_16.svg',
        'Assets\psrpm_24.png',
        'Assets\psrpm_24.svg',
        'Assets\psrpm_256.png',
        'Assets\psrpm_256.svg',
        'Assets\psrpm_32.png',
        'Assets\psrpm_32.svg',
        'Assets\psrpm_48.png',
        'Assets\psrpm_48.svg'
    )

    # Private data to pass to the module specified in RootModule/ModuleToProcess
    PrivateData       = @{
        PSData = @{
            Tags         = @('ProcessManager', 'TaskManager', 'ProcessExplorer', 'WinRM', 'RemoteAdministration', 'WPF', 'Sysinternals', 'Security')
            ProjectUri   = 'https://github.com/exh555/psrpm'
            LicenseUri   = 'https://github.com/exh555/psrpm/blob/main/LICENSE'
            IconUri      = 'https://raw.githubusercontent.com/exh555/psrpm/main/PSRPM/Assets/psrpm_256.png'
            ReleaseNotes = @'
PSRPM v1.6.0 - Process Safety, WinRM Resilience, Honest Kernel I/O, RBAC & Hardened Security
- Process Safety & PID Reuse Guard: Validated process identity in KillProcess using dual StartTime FILETIME ticks and QueryFullProcessImageNameW, preventing accidental termination of reused PIDs.
- Atomic Pinned Tree Termination: Refactored KillTree to use sub-millisecond NtQuerySystemInformation(5), pinning process handles across top-down suspension and bottom-up termination with guaranteed survivor cleanup.
- WinRM 4-State Lifecycle Machine: Implemented Connected, Degraded, Reconnecting, and Disconnected states with 2-stage transparent auto-recovery (Connect-PSSession -> New-PSSession) and bounded exponential backoff.
- Drift-Compensating Scheduler & Freshness Tracking: Replaced Thread.Sleep with wall-clock anchored timer ticks and real-time Fresh, Stale, Frozen telemetry freshness indicators.
- Honest Kernel System I/O Throughput: Upgraded Class 2 SYSTEM_PERFORMANCE_INFORMATION to compute genuine System Read/Write KB/s and System IOPS, replacing simulated queue depth.
- 64-Bit Network Telemetry: Upgraded network interface throughput calculation to 64-bit iphlpapi!GetIfTable2 and FreeMibTable, eliminating persistent unmanaged scratch buffers.
- Hardened Memory Dump Security: Enforced atomic non-inherited FileSecurity ACLs restricting process memory dump access strictly to SYSTEM, Administrators, and the executing user.
- Interactive Handle Closure: Added Close Handle context menu (Del) directly in the 7-Tab Process Properties Handles grid with in-place UI row removal.
- Expanded 11-Suite Engine Verification: Added automated benchmark gates and unit suites covering PID reuse, dump ACLs, tree termination, and freshness transitions.
'@
        }
    }
}
