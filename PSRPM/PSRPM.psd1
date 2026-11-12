@{
    # Script module or binary module file associated with this manifest.
    RootModule        = 'PSRPM.psm1'

    # Version number of this module.
    ModuleVersion     = '1.6.2'

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
PSRPM v1.6.2 - UI Ergonomics, Typography Refinement, Responsive Status Bar & Modeless Safety
- Persistent Process Action Bar: Integrated persistent bottom action controls (Suspend/Resume, Create Dump, Kill Process, Kill Tree) across all 7 tabs of the Deep Process Inspector.
- Responsive Status Bar & Overflow Engine: Refactored bottom status bar into elastic left telemetry, scrollable center legend with horizontal wheel support, right-pinned Audit Console, and dynamic auto-overflow button.
- In-Place Service Control Lifecycle: Maintained Service Details & Dependencies modal open across Start/Stop/Restart operations with live in-flight status transitions and background refresh timers.
- Typography & Font-Weight Anti-Cascade Hardening: Eliminated accidental bold text cascading across DataGrids in MainWindow, PropertiesWindow, FindHandleWindow, and ServiceDetailWindow, ensuring clean, restrained tabular typography.
- Modeless Dialog Safety & Crash Prevention: Removed hazardous IsCancel="True" from modeless System Information window and added clean Escape key event dispatch.
- Process Tree Unrolling: Enhanced service-to-process navigation to traverse and expand collapsed ancestor nodes up to root before selecting target host processes.
- Launch Options: Added -Dark and -Theme parameters to Start-PSRPM for direct dark-mode and custom theme execution.
'@
        }
    }
}
