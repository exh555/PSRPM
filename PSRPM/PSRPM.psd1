@{
    # Script module or binary module file associated with this manifest.
    RootModule        = 'PSRPM.psm1'

    # Version number of this module.
    ModuleVersion     = '1.16.0'

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
- Display Density Modes: Standard (18px), Compact Density (Ctrl+Shift+C, 14px across Processes/Services/TCPView), and Mini Monitor (Ctrl+Shift+M, chromeless pinned widget).
- In-App UI Zoom (75%-200%, Ctrl++ / Ctrl+- / Ctrl+0) propagated across all 7 child windows and persisted as UiScalePct.
- Process Explorer-aligned tree indentation, 150% DPI-safe aliased expanders, View -> Show Tree Lines toggle, Menu UX overhaul, and double-click empty HostTabBar to open New Host Tab.
- 6-minute (360-sample) rolling System Information charts with 1-minute vertical gridlines, stepped 1m->2m->3m->6m buckets, and pre-session zero-line suppression.
- Make-before-break async WinRM connection probing with mid-flight cancellation so failed connects never drop the active session.
- Fileless SHLoadIndirectString (PSRPM.NativeMuiV1) MUI service description resolution cached per service with zero steady-state overhead.
'@
        }
    }
}
