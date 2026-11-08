@{
    # Script module or binary module file associated with this manifest.
    RootModule        = 'PSRPM.psm1'

    # Version number of this module.
    ModuleVersion     = '1.3.0'

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
PSRPM v1.3.0 - Remote Session-Cached Invokers, 75% Remote CPU Reduction & Zero-Allocation Serialization
- WinRM Remote Session-Cached Invoker Architecture: Replaced per-tick ScriptBlock re-transmission and JIT compilation over WinRM with session-cached remote invokers, reducing request wire payload by 99.9% (from 46 KB/s to 44 bytes/s).
- Target CPU Consumption Slashed: Reduced remote wsmprovhost.exe CPU usage by ~75% and EDR/AMSI inspection overhead to a one-time scan during initial PSSession registration.
- Automatic Session Resilience: Built-in state detection that transparently re-initializes cached invokers if a remote session is recycled without dropping a single tick of telemetry.
- In-Process Telemetry Collector Streamlining: Pre-allocated reusable JavaScriptSerializer instances, zero-allocation empty update emission, and direct collection traversal for dead PID pruning.
- Native Memory Reads: Prioritized native psapi!GetPerformanceInfo unmanaged reads for RAM and commit charge, bypassing private reflection on steady-state ticks.
'@
        }
    }
}
