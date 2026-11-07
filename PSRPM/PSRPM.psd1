@{
    # Script module or binary module file associated with this manifest.
    RootModule        = 'PSRPM.psm1'

    # Version number of this module.
    ModuleVersion     = '1.0.0'

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
    Description       = 'PSRPM (PowerShell Remote Process Manager) - Enterprise-grade, ultra-low-overhead, fileless remote and local process monitoring and management GUI built with WPF and native Reflection.Emit.'

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
        'Assets\psrpm.ico',
        'Assets\psrpm.png'
    )

    # Private data to pass to the module specified in RootModule/ModuleToProcess
    PrivateData       = @{
        PSData = @{
            Tags         = @('ProcessManager', 'TaskManager', 'ProcessExplorer', 'WinRM', 'RemoteAdministration', 'WPF', 'Sysinternals', 'Security')
            ProjectUri   = 'https://github.com/exh555/psrpm'
            LicenseUri   = 'https://github.com/exh555/psrpm/blob/main/LICENSE'
            ReleaseNotes = @'
PSRPM v1.0.0 - Initial Production Release
- 100% Fileless & EDR-Safe: Native in-memory Reflection.Emit P/Invoke and pure PS 5.1 classes. Zero csc.exe, zero temp DLLs on disk.
- Ultra-Low Target Impact: Single-call NtQuerySystemInformation(5) (< 0.25% CPU, 2-10ms per tick).
- Differential Wire Protocol: Transmits static metadata once per process; steady-state delta GZIP payloads ~1.1-1.8 KB/s.
- Process Explorer Unified Tree-Grid: Pixel-snapped vector connectors, semantic category colors, auto-flat column sorting, ancestor-preserving search.
- 7-Tab Process Properties Inspector: Instant Core mode (< 20ms) with lazy tab-activated DLLs and kernel Handles inspection.
- 4-Tab System Information Graphs: Summary, CPU, Memory, and I/O live graphs with bounded 120-sample (< 12 KB) circular ring buffers.
- Multi-Host Tabbed Sessions: Rapid switching (< 5ms) across concurrent remote/local sessions with 0 KB/s zero-bandwidth standby.
- Live Audit Trail & Network Telemetry Console (Ctrl+L) with real-time RTT, bandwidth, compression ratio, and event streams.
'@
        }
    }
}
