@{
    # Script module or binary module file associated with this manifest.
    RootModule        = 'PSRPM.psm1'

    # Version number of this module.
    ModuleVersion     = '1.18.0'

    # Supported PSEditions
    CompatiblePSEditions = @('Desktop')

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
        'UI\SelectColumnsWindow.xaml',
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
v1.18.0 - Host PC CPU & Dynamic Sorting Performance Optimization:
- Added pure PowerShell 5.1 PSRPMProcessCollection.ReplaceOrder() for atomic silent-swap + Replace reconciliation during bulk flat-mode dynamic sorting (cutting WPF frame time by ~74% while preserving selection, multi-select, CurrentItem, and scroll position).
- Added pre-frozen native WPF brush, geometry, visibility, font-weight, and sparkline PointCollection properties across ProcessItemViewModel, HostTabItemViewModel, and SystemSummaryViewModel, and removed redundant DataGridCell.Foreground bindings.
- Fixed background coordinator 10 ms busy-spin when paused, disconnected, dormant, or waiting on payload handoff (dropping idle paused host CPU to ~0%).
- Dirty-checked HostTabItemViewModel.UpdateVisualState() and SystemSummaryViewModel.UpdateSummary(), tracked active flashing and TreeCPU/TreeNet PIDs with multi-tab resync guards, and added Suite 12W regression tests.
'@
        }
    }
}
