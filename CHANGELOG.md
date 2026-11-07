# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
