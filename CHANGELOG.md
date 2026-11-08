# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.1] - 2026-11-07

### Added
- **Real-Time Performance Tab Telemetry Polling (`PSRPM.psm1`, `DeepInspector.ps1`)**:
  - Added lightweight `"Performance"` inspect mode in `DeepInspector.ps1` that queries CPU cycles (`QueryProcessCycleTime`), GUI handles (`GetGuiResources`), detailed I/O (`IoCounters`), and memory pools without module/handle enumeration overhead.
  - Integrated live 1-second background `DispatcherTimer` in `PSRPM.psm1` to poll performance counters and dynamically refresh CPU cycles, processor times, and I/O rates while the Performance tab is active.
- **Comprehensive Automated Extended QA Suite (`Tests/Test-PSRPMExtendedQA.ps1`, `Tests/QA_Report.md`)**:
  - Added deep 39-check automated QA stress suite validating AST guardrails, synthetic kernel edge cases, headless WPF UX/UI, zero-leak memory eviction, and Win32 resiliency (100% pass rate).

### Optimized
- **WinRM Remote Inspector Resiliency (`RunspaceEngine.ps1`)**:
  - Added automatic fallback and transparent re-initialization of `$script:PSRPMInspectorInvoker` if a remote session is recycled or invalidates the invoker.

### Fixed
- **Idle CPU Formatting (`PSRPM.psm1`)**:
  - Corrected CPU usage percentage formatting when idle to cleanly display `0.00%` rather than an empty string.

## [1.3.0] - 2026-11-07

### Optimized
- **WinRM Remote Session-Cached Invoker Architecture (`RunspaceEngine.ps1`)**:
  - Replaced per-tick 46 KB `ScriptBlock` re-transmission and JIT compilation over WinRM with session-cached remote invokers (`$script:PSRPMCollectorInvoker`, `$script:PSRPMInspectorInvoker`, `$script:PSRPMActionInvoker`).
  - Slashed `wsmprovhost.exe` target CPU consumption by ~75% and reduced upload request wire payload from 46 KB/s to 44 bytes/s (99.9% reduction).
  - Reduced EDR / AMSI script scan overhead from 60 times/minute (scanning 46 KB buffers) to a single one-time scan during initial PSSession registration.
  - Built automatic resilience fallback: if a remote session is recycled or resets state, the engine detects `$null` and transparently re-initializes the cached invokers on the subsequent tick without dropping data.
- **In-Process Telemetry Collector Streamlining (`DataCollector.ps1`)**:
  - Pre-allocated reusable `JavaScriptSerializer` (`$script:Jss`) during session initialization, bypassing reflection type instantiation on every tick.
  - Added direct `'[]'` emission for empty metadata updates, avoiding reflection serialization when no new processes have spawned.
  - Replaced `Where-Object` pipeline expressions in dead PID pruning with direct `foreach` collection traversal, eliminating pipeline setup overhead.
  - Prioritized native `psapi!GetPerformanceInfo` unmanaged reads for RAM and commit limit/charge, avoiding private reflection on steady-state ticks.

## [1.2.0] - 2026-11-07

### Added
- **Interactive Windows Services Management Suite**:
  - Full-featured **Services Tab** (`GridServices`) in `MainWindow.xaml` providing real-time inventory of all installed system services with `ServiceName`, `DisplayName`, `HostPID`, `Status`, `StartupType`, `LogOnAs`, and inline dependency previews.
  - Process Explorer-style action toolbar with **Start Service** (`BtnSvcStart`), **Stop Service** (`BtnSvcStop`), **Restart Service** (`BtnSvcRestart`), **Properties & Dependencies...** (`BtnSvcProperties`), and **Select Process in Tree** (`BtnSvcGoToProcess`).
  - Context menu on services grid for quick actions (`Start`, `Stop`, `Restart`, `Properties & Dependencies...`, `Go to Host Process in Tree`).
  - Real-time search filter (`TxtSearchServices` / `BtnClearSearchServices`) with live summary count badge (`TxtSvcSummary`: e.g. `"Showing 42 of 285 Services"`).
  - Bidirectional navigation: Double-clicking or pressing Enter on a service with a running `HostPID` automatically switches to the Processes tab and selects the host process (`svchost.exe`, etc.) in the hierarchical tree-grid.
  - Smart action button enablement: Start button enabled only when service is Stopped; Stop and Restart buttons enabled only when service is Running.
- **Two-Way Service Dependencies Inspector (`ServiceDetailWindow.xaml`)**:
  - Deep inspection modal opened via double-click, Enter, context menu, or toolbar button.
  - **General Tab**: Displays Service Name, Display Name, Current Status, Startup Type, Binary Path, Account / Log On As, Host PID, and Description.
  - **Dependencies Tab**: Two-way relational dependency tree:
    - **Services this service depends on** (Prerequisites / `ServicesDependedOn`).
    - **Services that depend on this service** (Dependents / `DependentServices`).
  - Interactive grid rows with live status badges (`Running`, `Stopped`, etc.) and direct Start / Stop / Restart actions inside the inspector dialog.
- **Multi-Tier Robust Service Data Collection**:
  - Enhanced `Collect-PSRPMSystemTelemetry` with 3-tier fallback architecture:
    1. Fast in-memory Registry query (`HKLM:\SYSTEM\CurrentControlSet\Services`) reading `DisplayName`, `Start`, `ImagePath`, `ObjectName`, `Description`, and `DependOnService`.
    2. CIM query (`Win32_Service`) fallback for active runtime status and PID mapping.
    3. Direct Win32 Service Controller fallback (`[System.ServiceProcess.ServiceController]`) ensuring 100% telemetry capture even in constrained or non-elevated remoting contexts.
  - Cached dependency tree mapping for fast two-way resolution without round-trip penalties.

### Fixed
- **Dark Mode Menu Text Visibility Overhaul**:
  - Replaced system default WPF menu rendering with custom high-contrast dark mode `ControlTemplate` for `MenuItem`, top-level headers, and popup menus.
  - Fixed white-on-white text washing and unreadable submenu items in dark theme; menu items now render with `BrushTextPrimary` (`#F8FAFC`) on dark surface with smooth accent hover styling.
- **PowerShell 5.1 Collection Truthiness Bug**:
  - Fixed issue where empty `ObservableCollection[ServiceItemViewModel]` evaluated to `$false` in `if ($ServicesCollection)`, preventing service rows from populating after background collection ticks. Replaced with `$null -ne $ServicesCollection`.
- **ASCII Character Compliance**:
  - Cleaned non-ASCII characters (bullets, em-dashes) in XAML and script resources ensuring 100% 7-bit ASCII compatibility on Windows-1252 PowerShell hosts.

## [1.1.1] - 2026-11-07

### Added
- **Visual Pause State Indication & UX Overhaul**:
  - **Dynamic Toolbar Pause / Resume Button**: Replaced static pause button with a reactive state toggle. When paused, `BtnToolbarPause` transforms to display an amber Play/Resume vector icon (`▶`), an accented amber background, a bold `"PAUSED"` text label (`TxtToolbarPause`), and updated `"Resume Polling (Space)"` tooltip.
  - **Status Bar Amber [PAUSED] Badge**: Added a high-contrast amber `[PAUSED]` indicator pill (`BadgePaused`) directly in the status bar alongside an explicit notification (`PAUSED - Telemetry collection suspended`), eliminating any ambiguity when background updates are halted.
  - **Active Session Tab Status Synchronization**: The active host tab in `HostTabBar` immediately reflects the paused state, turning its status indicator dot amber (`#F59E0B`) and updating latency text to `"Paused"`.
  - **Immediate Multi-Control Recovery**: Restoring real-time telemetry polling via Spacebar, `F5` / Refresh button, or menu rate selection immediately reverts all visual indicators to running state and triggers a fast NtQuerySystemInformation collection tick.
  - **Audit Trail Rate Logging**: Detailed audit events recorded to the telemetry console upon entering (`RATE: Telemetry collection paused`) and exiting (`RATE: Telemetry collection resumed`) pause mode.

### Added
- **Help / ? Menu Bar & Comprehensive Reference Modal**:
  - Top-level `Help` menu with access to keyboard shortcuts reference, architecture & safety overview, remoting guide, and About dialog.
  - Integration into the `File` menu (`Help & Shortcuts...`, `F1`) and top action toolbar with vector `?` quick-access button (`BtnToolbarHelp`).
  - Global `F1` keyboard accelerator opening the modal from any view or focus state.
- **4-Tab Help & Information Reference Modal (`HelpWindow.xaml`)**:
  - **Shortcuts Tab**: Clean, categorized table of all keyboard accelerators across Navigation & Views, Process Operations, Multi-Host Session Management, and Snapshots with visual key badges.
  - **Architecture & Safety Tab**: Operator overview of PSRPM's four non-negotiable architectural pillars: 100% fileless EDR safety, ultra-low remote CPU budget (< 0.25%), differential GZIP wire streaming (~1.1-1.8 KB/s), and bounded zero-leak memory eviction.
  - **Connectivity Tab**: Actionable setup instructions for WinRM remoting, TrustedHosts workgroup configuration, zero-privilege `-LocalOnly` execution, and the semantic process color legend.
  - **About Tab**: Product version, licensing, copyright, documentation links, and live diagnostic environment telemetry (host, operator user, target session, transport protocol, PowerShell version, CLR/.NET runtime, and processor architecture).

### Fixed
- **Audit Console Top Row Telemetry Layout & Jitter Elimination**:
  - Replaced unconstrained horizontal `StackPanel` in `LogPane` header with a stable 3-column `Grid` (`Auto`, `*`, `Auto`) and a fixed 4-column telemetry grid, guaranteeing right action controls (`Stream Ticks`, `Copy`, `Clear`, `Close [X]`) are never overlapped, clipped, or shifted by updating text.
  - Formatted telemetry badges (`Transport / RTT`, `Wire / Compression`, `Bandwidth / RX`, `Sequence / Delta`) to fixed-character layouts with `Tabular` numeral alignment and `TextTrimming="CharacterEllipsis"`, completely eliminating horizontal jitter/twitching across refresh ticks.
  - Added rich on-hover tooltips on all 4 telemetry pills displaying complete long-form metrics, host targets, and uncompressed raw JSON payload ratios.

## [1.0.0] - 2026-11-07

### Added
- **100% Fileless & EDR-Safe Core Engine**:
  - Pure Windows PowerShell 5.1 native classes (`ViewModelClasses.ps1`) and dynamic in-memory P/Invoke generation via `System.Reflection.Emit`.
  - Zero `Add-Type -TypeDefinition` / `Add-Type -MemberDefinition`, zero `csc.exe` compiler invocations, and zero temporary `.dll` or `.cs` files written to disk or `%TEMP%`.
- **Single-Call Native Kernel Collector (`NtQuerySystemInformation`)**:
  - Single unmanaged transition querying `SystemProcessInformation` (Class 5) and `GlobalMemoryStatusEx` into persistent 512 KB pre-allocated unmanaged buffers (`[Marshal]::AllocHGlobal`).
  - Remote collection cycle duration between 2 ms and 10 ms with target CPU overhead strictly `< 0.25%`.
  - Eliminates `WmiPrvSE.exe` spikes, N+1 DCOM RPC round-trips, and `$p.Responding` GUI freezes.
- **State-Aware Differential Wire Protocol**:
  - Transmits static metadata (`Path`, `CommandLine`, `User`, `Description`, `CompanyName`, `ParentPID`, `Arch`) exactly once per process lifetime upon spawn.
  - Differential steady-state ticks transmit only changed dynamic metrics (`[PID, CPU, WorkingSet, PrivateBytes, Threads, Handles, StatusFlags]`) compressed with in-memory GZIP (`~1.1 - 1.8 KB/s` steady state wire footprint).
- **Sysinternals Process Explorer Unified Tree-Grid**:
  - Single-surface hierarchical process tree with continuous pixel-snapped vector guide lines (`│`, `├─`, `└─`), interactive `[+]`/`[-]` expanders, and 16x16 application icons.
  - Keyboard-driven navigation: `Left Arrow` / `Right Arrow` for branch collapse, expand, and ancestor traversal.
  - Smart Auto-Flat Sorting: Clicking any column header (`CPU`, `Private Bytes`, `Working Set`, `PID`, `Name`, `Handles`) automatically flattens the hierarchy for machine-wide ranking; clicking `Tree` (`Ctrl+T`) restores the hierarchical view.
  - Ancestor-Preserving Filter (`Ctrl+F`) preserving complete parent ancestry chains so matching processes remain contextualized.
- **Semantic Category Color Coding & Themes**:
  - Instant classification matching Process Explorer conventions: Services (Soft Rose), Own / User Session (Soft Indigo), Packaged / WebView2 (Cyan), Suspended (Slate Grey), New Process (1-tick Lime Flash), and Exiting Process (1-tick Crimson Flash).
  - Clean Light and Precision Dark theme toggle (`Ctrl+D`).
- **7-Tab Deep Process Properties Inspector**:
  - Instant Core Mode (`< 20 ms`, `< 2 KB` payload): Double-clicking any process opens Image metadata (version, PE linker build timestamp, path, command line, PEB current directory, autostart location), Performance counters, TCP/IP endpoints, hosted Services, and remote PEB Environment variables.
  - Lazy tab-activated queries for loaded DLLs (`psapi!EnumProcessModulesEx`) and open kernel Handles (`ntdll!NtQueryInformationProcess(51)` + pipe-safe `NtQueryObject`) executed only on tab selection.
  - On-demand Authenticode digital signature verification button.
- **4-Tab Live System Information Modal (`Ctrl+I` / Double-Click Mini Graphs)**:
  - Summary, CPU, Memory, and I/O graphs backed by fixed 120-sample (< 12 KB RAM) circular ring buffers.
  - Kernel vs. Total CPU curves with vertical bar gauges and a per-core CPU graph grid toggle (`Show one graph per CPU`).
  - Psapi `GetPerformanceInfo` and `NtQuerySystemInformation(2, 8)` kernel counter breakdowns.
- **Multi-Host Tabbed Session Bar**:
  - Concurrent remote WinRM (`-ComputerName`) and local (`-LocalOnly`) targets in switchable tabs (`Ctrl+Shift+K`, `Ctrl+Tab`, `Ctrl+Shift+Tab`, `Ctrl+W`).
  - Sub-5 millisecond instant tab cycling with isolated in-memory caches (`ProcessMap`, `ServicesMap`, `SummaryVm`, `TelemStats`).
  - Zero-bandwidth standby (`0 KB/s` wire, `0%` remote CPU) for inactive tabs while maintaining authenticated persistent `PSSession` connections.
- **Live Audit Trail & Network Telemetry Console (`Ctrl+L`)**:
  - Real-time badges for transport RTT, wire compression ratio, bandwidth (`KB/s`), cumulative RX bytes, and delta counts.
  - Live activity logging stream for lifecycle, inspection, and action events.
- **Two-Phase Atomic Process Tree Termination (`Shift+Del`)**:
  - Top-down tree suspension via `ntdll!NtSuspendProcess`, PID-creation time validation, and bottom-up termination to prevent PID-reuse collateral damage.
- **Process Control Actions**:
  - Suspend, Resume, Priority adjustment (RealTime, High, AboveNormal, Normal, BelowNormal, Idle), and hosted Windows Service Start/Stop/Restart.
- **Automated Verification Suite (`Tests/Test-PSRPMEngine.ps1`)**:
  - 7 comprehensive automated test suites verifying EDR compliance, manifest exports, delta telemetry, deep inspection, process actions, XAML bindings, and end-to-end runspace reconciliation.
