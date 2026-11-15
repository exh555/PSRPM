# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.15.0] - 2026-11-15

### Added
- **Multi-Host `-ComputerName` Session Bar Lifecycle (`PSRPM.psm1`, `RunspaceEngine.ps1`, `ViewModelClasses.ps1`, `ConnectDialog.xaml`)**:
  - Added multi-computer `-ComputerName` support with 10-host cap, deduplication, `-LocalOnly` conflict handling, and dormant `NotConnected -> Connecting -> Offline` tab lifecycle with mid-connect cancellation.

### Fixed
- **WPF Blank Modal / Window Surface Stall Mitigation (`PSRPM.psm1`, `Test-PSRPMEngine.ps1`)**:
  - Added `$attachRenderResizeNudge` across `MainWindow` and all 7 modal/modeless child windows (`SelectColumnsWindow`, `ServiceDetailWindow`, `PropertiesWindow`, `ConnectDialog`, `SystemInfoWindow`, `HelpWindow`, `FindHandleWindow`) to schedule a post-`ContentRendered` `+1 px` width resize after `1000 ms` followed `5 ms` later by a `-1 px` shrink back, forcing an `HwndTarget` swapchain reset on GPU drivers that stall initial frame presentation.

## [1.14.1] - 2026-11-15

### Added
- **Custom Theme Registry & Sandbox (`ViewModelClasses.ps1`, `tools/Theme-Sandbox.ps1`, `tools/sample-theme.json`, `tools/sample-vscode-theme.json`)**:
  - Added `[PSRPMThemeRegistry]::RegisterPalette`, `ClearCustomPalettes`, `GetBuiltInNames`, deep palette cloning/section merging, and `_CustomPalettes` lookup support.
  - Added offline `tools/Theme-Sandbox.ps1` interactive theme previewer, JSON importer, and WCAG contrast auditor along with sample theme JSON presets.

### Changed
- **Fast Cached Theme Switching (`PSRPM.psm1`, `ViewModelClasses.ps1`)**:
  - Replaced per-key `$window.Resources[$key] = $b` brush updates in `$applyTheme` and `$syncDialogThemeBrushes` with frozen-brush caching (`$getFrozenBrush`) and cached per-theme `ResourceDictionary` swapping via `MergedDictionaries[0]` (`$getThemeResourceDict`), stripping initial direct `Brush*`/`ColTint_*` resource keys once on startup.
  - Optimized `ProcessItemViewModel.SetThemeMode` to fetch the resolved palette once and pass it directly to `RefreshRowColors([hashtable]$palette)`, skipped duplicate active-tab `ProcessMap` and network collection passes in `$applyTheme` / `$script:RefreshNetworkThemeBrushes`, and converted `PSRPMThemeRegistry::NormalizeMode` to a `switch`.
- **`FindHandles` System Scan Allocation & Loop Optimization (`DeepInspector.ps1`)**:
  - Hoisted module enumeration buffers (`$modBuf`, `$sbModPath`) outside the per-process loop in `FindHandles` and kept bulk handle inspection inline without per-handle scriptblock invocation overhead.

### Fixed
- **Hover Tooltip `MethodNotFound` Error on Theme Switch (`PSRPM.psm1`)**:
  - Fixed `$applyTheme` passing `$hoverSt.ResourceWindow` (`[System.Windows.Window]`) instead of `$hoverSt.ResourceWindow.Resources` (`[System.Windows.ResourceDictionary]`) to `$syncHoverTipBrushes`, eliminating `[System.Windows.Window] does not contain a method named 'Contains'` errors during theme changes, and hardened `$syncHoverTipBrushes` to unwrap `.Resources` if a `Window` is passed and verify `[System.Collections.IDictionary]`.
- **`GetFileType` Kernel Deadlock on `SYNCHRONIZE`-Only `File` Handles (`DeepInspector.ps1`)**:
  - Gated `GetFileType` and `GetFinalPathNameByHandleW` in both `FindHandles` and `Handles` modes with `($acc -band 0x0001FFFFL) -ne 0L` to skip `SYNCHRONIZE`/standard-rights-only `File` handles (e.g., `0x00100000` driver control handles such as `WebClient` `svchost`) that can block indefinitely in `GetFileType`.

## [1.14.0] - 2026-11-15

### Changed
- **Minimum-Move DataGrid Reconciliation (`RunspaceEngine.ps1`)**:
  - Replaced the left-pull loop in `$reconcileCollection` with an exact `(M - LIS)` minimum-move reconciler using `Dictionary[Object, int]`, Patience-Sorting Longest Increasing Subsequence (`LIS`), and anchored `Move`/`Insert` operations while preserving `SelectedItems`/`SelectedItem` restoration. Eliminates cascading moves when active processes drop back into sorted tails during dynamic column sorting (e.g., `CPU` descending).
  - Optimized `$recalculateTreeCpu` to iterate `$processMap.Values` and skip rounding on `0.0%` rows, removed redundant `@(...)` copying when building Flat Mode `$desiredList` (safely handling single-item unwrapping), gated latency tooltip rebuilds on state/latency changes, and skipped `$updateViewCollections` when dynamic/dead arrays are empty and structure is unchanged.
- **Local Loopback GZIP Bypass (`DataCollector.ps1`, `RunspaceEngine.ps1`)**:
  - Added optional `[bool]$SkipCompression = $false` parameter to `$script:PSRPMCollectorScriptBlock` so local loopback ticks (`$activeSessObj.IsLocal`) return raw `$jsonOut` directly without GZIP compression/decompression overhead while preserving remote WinRM GZIP compression unchanged.
- **ViewModel Binding & Tooltip Churn Reduction (`ViewModelClasses.ps1`)**:
  - Added `[PSRPMThemeRegistry]::GetPropArgs` (`_PropArgsCache`) and updated `OnPropertyChanged` across all 5 ViewModel classes (`ProcessItemViewModel`, `ServiceItemViewModel`, `CpuCoreGraphViewModel`, `SystemSummaryViewModel`, `HostTabItemViewModel`) to reuse frozen `PropertyChangedEventArgs` instances.
  - Split `RefreshHoverToolTip` into `RefreshProcessHoverToolTipOnly`, `RefreshPrivateCellToolTip`, `RefreshWsCellToolTip`, and `RefreshHandlesCellToolTip` so `UpdateDynamic` only rebuilds tooltips for columns whose formatted display values actually changed.
  - Removed redundant `OnPropertyChanged` notifications on unbound raw numeric properties (`CPU`, `PeakCPU`, `MemoryBytes`, `PeakMemoryBytes`, `PrivateBytes`, `PeakPrivateBytes`, `Handles`, `PeakHandles`, `CPUDelta`, `PrivateBytesDelta`, `MemoryDelta`, `HandlesDelta`, `TreeCPU`, `NetRxBps`, `NetTxBps`, `NetTotalBps`, `TreeNetRxBps`, `TreeNetTxBps`, `TreeNetTotalBps`).
- **WPF DataGrid Virtualization Cache Tuning (`MainWindow.xaml`)**:
  - Reduced `GridProcesses` `VirtualizingPanel.CacheLength` from `"20,20"` to `"3,3"` (`CacheLengthUnit="Item"`) to lower off-screen row container churn during dynamic re-sorting.

### Benchmarks
- **Local `powershell.exe` GUI Live CPU Profile** (~12s window, 1s poll interval, 204-214 live local processes, Windows 11 Pro 26H2, 4 cores):
  - **Flat View Sorted by `CPU` Descending**: Total `powershell.exe` process CPU dropped from `2734.4 ms` (`22.79%` of 1 core / `5.70%` of 4 cores over `12.00s`) to `1312.5 ms` (`10.88%` of 1 core / `2.72%` of 4 cores over `12.07s`, **-52.3%**); WPF UI thread CPU dropped from `170.6 ms/s` (`2046.9 ms`) to `71.2 ms/s` (`859.4 ms`, **-58.3%**).
  - **Tree View (Default)**: Total `powershell.exe` process CPU `781.3 ms` (`6.51%` of 1 core / `1.63%` of 4 cores over `12.00s`); WPF UI thread CPU `23.4 ms/s` (`281.3 ms`).
- **Collector & Wire Efficiency Benchmarks** (`Test-PSRPMEngine.ps1`, `Test-PSRPMExtendedQA.ps1`, `Test-GzipPerformance.ps1`):
  - **Collector (`NtQuerySystemInformation(5)`, 219 processes / 268 services)**: Initial Full Sync `513 ms` (`39.74 KB` GZIP); 30-tick steady-state mean `6.4 ms` (`P95 = 15 ms`, `0.96 KB` avg differential wire).
  - **50-Tick Sustained Stress (`Test-PSRPMExtendedQA.ps1`)**: Median `5 ms`, `P95 = 17 ms`, `0.58 KB/tick` avg differential wire.
  - **Remote GZIP Transport (`Test-GzipPerformance.ps1`)**: Tick 1 wire savings `80.9%` (`203.67 KB -> 38.95 KB`); steady-state wire savings `34.5%` (`2.35 KB -> 1.54 KB/tick`); delta compression CPU `0.0875 ms` target / `0.0641 ms` client.

## [1.13.1] - 2026-11-15

### Changed
- **Windows PowerShell 5.1 (`Desktop`) Support Clarification (`PSRPM.psd1`, `PSRPM.psm1`, `README.md`, `PRODUCT.md`, `docs/FEATURE_PROPOSAL_MASTER_PLAN.md`)**:
  - Updated `CompatiblePSEditions` in `PSRPM.psd1` from `@('Desktop', 'Core')` to `@('Desktop')` and aligned documentation with Windows PowerShell 5.1 requirements (`Add-Type -AssemblyName System.Web.Extensions` and desktop WPF UI).
  - Added an early `$PSVersionTable.PSEdition -ne 'Desktop'` runtime guard in `Start-PSRPM` (also covering `Start-RemoteProcessManager`) for clear failure diagnostics on unsupported PowerShell editions.

### Fixed
- **Multi-Tab Sync, Sequence-Gap Recovery & Full-Resync Pruning (`RunspaceEngine.ps1`, `PSRPM.psm1`)**:
  - Tracked dropped background/mismatched/sequence-gapped payloads per tab via `TabNeedsResync`, preserved pending `ForceFullSync` during `SelectTabSession` and `CloseTabSession`, and routed explicit `NextTabId` and `NextForceFullSync` from UI tab teardown.
  - Pruned stale cached processes missing from full recovery snapshots (`full = 1`) via a 1-tick exit flash (`LifecycleState = 2`, `[Resync Pruned]`) followed by next-tick eviction, and pruned stale cached services on `svcFull = 1`.
- **Self-PID Process Tree Termination & Suspend Protection (`ProcessActions.ps1`)**:
  - Prevented self-deadlock in `KillTree` by skipping Phase 1 `NtSuspendProcess` when `$orderedTree` includes PSRPM's own host `$PID`, terminating descendant and sibling processes bottom-up first, closing handles, and terminating `$PID` last.
  - Added an explicit refusal guard in `SuspendProcess` when targeting PSRPM's own host `$PID` (`Status = "Refused"`, `ErrorId = "PSRPM.Process.Refused"`).
- **Host-Switch Window Binding (`PSRPM.psm1`)**:
  - Updated `$actionSelectHostTab` and `$syncTargetSwitchUi` to reset/re-scope `FindHandleWindow` (`$script:ResetFindHandleForHostChange`, `TabId`/`Host` stamping on results, and mismatch guards on async completion, `CloseHandle`, and `GoToProcess`) and dynamically rebind an open `SystemInfoWindow` (`$script:RebindActiveSysInfoWindow`, dynamic `$sysWin.DataContext` lookup).
- **Global `Ctrl+D` Theme Cycling Across Child Windows (`PSRPM.psm1`)**:
  - Added `$activeChildDialogs`, `$getActiveChildWindows`, and `$registerChildWindow` so pressing `Ctrl+D` cycles themes directly from any modal or modeless child window (`SystemInfoWindow`, `PropertiesWindow`, `FindHandleWindow`, `ServiceDetailWindow`, `SelectColumnsWindow`, `ConnectDialog`, and `HelpWindow`), while keeping all open child windows, active hover tooltips (`$syncHoverTipBrushes`), and `Topmost` state synchronized.
- **Dark-Theme Contrast & Tab Control Styling (`SystemInfoWindow.xaml`, `HelpWindow.xaml`, `FindHandleWindow.xaml`)**:
  - Fixed black text on dark themes in `SystemInfoWindow.xaml` (card titles, vertical gauge percentages, `GroupBox` headers, and the `Show one graph per CPU` `CheckBox`) and `HelpWindow.xaml` by adding `BrushRowHover` fallback brushes along with theme-aware `TabControl`, `TabItem`, `GroupBox`, and `CheckBox` styles overriding WPF Aero defaults, and added an explicit unselected cell `Foreground` setter to `FindHandleWindow.xaml`.
- **Live Sorting, Inspector State, >24h CPU Formatting & I/O Rate Accuracy (`RunspaceEngine.ps1`, `DeepInspector.ps1`, `ViewModelClasses.ps1`, `DataCollector.ps1`)**:
  - Added `"CPUDelta"` to `$dynSortProps` in `RunspaceEngine.ps1` so live flat/sorted views re-sort dynamically on every differential tick.
  - Persisted TCP EStats access-denied state across connections in `DeepInspector.ps1` using a reference hashtable (`$estatsState = @{ SetBlocked = $false }`) and formatted >24-hour CPU times (`UserTime`, `KernelTime`, `TotalCpuTime`) using `[Math]::Floor($ts.TotalHours)` instead of `hh\:mm\:ss\.fff`.
  - Passed actual `$elapsedSec` to 3-argument `UpdateExtendedTelemetry` in `ViewModelClasses.ps1` (retaining the 2-arg `1.0`s overload) so `IoTotalHistory240`, `IoWriteHistory240`, `IoGaugeText`, and `IoTotalRateFormatted` report accurate per-second byte rates, and decoupled `DiskReadKBs`, `DiskWriteKBs`, and `DiskQueueDepth` in `DataCollector.ps1` from network `GetIfTable2` availability using elapsed collector tick intervals (`$ioSec`).
- **Regression Test Coverage (`Tests/Test-PSRPMEngine.ps1`)**:
  - Added Tests `12Q`, `12R`, and `12S` covering RunspaceEngine resync pruning (processes + services), `TabNeedsResync`/`CloseTabSession`, live `CPUDelta` re-sort, self-PID `SuspendProcess` refusal and self-PID `KillTree` non-hang, >24h CPU formatting, `$estatsState` persistence, elapsed-time I/O rate scaling, DataCollector Disk KB/s decoupling, host-switch window hooks, the `Desktop` edition guard, global `Ctrl+D` child-window registration, and dark-theme visual foreground compliance in `SystemInfoWindow.xaml` and `HelpWindow.xaml`.

## [1.13.0] - 2026-11-15

### Added
- **Zero-Argument Local Mode, Non-Blocking Default & `-Defaults` Bypass (`PSRPM.psm1`, `PRODUCT.md`, `README.md`, `docs/USER_GUIDE.md`, `HelpWindow.xaml`)**:
  - Calling `Start-PSRPM` / `Start-RemoteProcessManager` (`psrpm`) without `-ComputerName`, `-Credential`, `-Port`, or `-UseSSL` now defaults to Local-Only Mode and launches asynchronously in a background STA runspace.
  - Added `[switch]$Wait` to block the calling terminal until closed (retaining `-NoWait` / `-Background` as backwards-compatible switches).
  - Added `[switch]$Defaults` (`-Default`, `-NoConfig`, `-NoPreferences`) to temporarily skip loading saved `%LOCALAPPDATA%\PSRPM\preferences.json` without modifying config on disk.
- **`CPUDelta` Baseline Column & 31-Column Catalog (`ViewModelClasses.ps1`, `RunspaceEngine.ps1`, `PSRPM.psm1`, `MainWindow.xaml`, `SelectColumnsWindow.xaml`)**:
  - Added `CPUDelta` (`ColCpuDelta` / `CPU Delta`) as the 31st column in `Get-PSRPMColumnCatalog` with `BaselineCPU` / `CPUDelta` tracking, numeric sorting, 6-argument `SetBaselineState` (retaining the 5-argument overload), and baseline CPU tooltips.
- **WCAG 2.1 AA Contrast, UIA Accessibility & Test `12P` (`ViewModelClasses.ps1`, `UI/*.xaml`, `Tests/Test-PSRPMEngine.ps1`)**:
  - Added `AutomationProperties.Name` UIA accessibility labels across all 8 XAML windows and dialogs.
  - Added Test `12P` in `Tests/Test-PSRPMEngine.ps1` covering 6-theme WCAG 2.1 AA contrast (`>= 4.5:1`), 8-XAML UIA coverage, `Space`/`Return` focus isolation, zero-arg Local Mode & `-Wait`/`-Defaults`, opt-in preferences cues, and Win32/SCM `Hint:` enrichment.
- **Crisp 96 DPI Screenshot Gallery & Network Activity Capture (`tools/Capture-Screenshots.ps1`, `docs/screenshots/`, `screenshots/`, `README.md`)**:
  - Added `12_network_activity_sockets_etw_light.png` illustrating TCPView-style Active Sockets, quick filter chips, and opt-in Kernel ETW telemetry, and updated `Capture-Screenshots.ps1` to render crisp 96 DPI offscreen WPF frames across all 12 captures.

### Changed
- **6-Theme Contrast Refinement & UX Polish (`ViewModelClasses.ps1`, `PSRPM.psm1`, `UI/*.xaml`)**:
  - Updated muted text, accent, badge, status, service pill, and Help card tokens (`BrushBadgeFg`, `BrushHelpSuccessFg`, `BrushHelpAmberFg`, `BrushHelpVioletFg`) across all 6 themes (`Light`, `Dark`, `TokyoNight`, `TokyoNightLight`, `Classic`, `HighContrast`) to meet `>= 4.5:1` WCAG AA contrast.
  - Added opt-in unsaved preferences dirty indicator (`*` + changed-area tooltip on `MenuSavePreferences`), responsive toolbar `WrapPanel` layout, centered filter empty-state overlays (`ProcEmptyStateOverlay`, `SvcEmptyStateOverlay`) with clear buttons, `Return` and double-click jump-to-tree navigation from `GridNetworkSockets` and `GridNetworkTimeline`, `(+Z ETW off)` visibility counts in `SelectColumnsWindow`, wider `PropertiesWindow` (`980x660`) with `TextTrimming` tooltips, and an explicit `Open Network tab ->` button (`BtnOpenNetworkTab`) in `SystemInfoWindow`.
- **Release Automation Synchronization (`tools/Set-ReleaseVersion.ps1`, `Tests/Test-ReleaseReadiness.ps1`, `.agent/skills/release/SKILL.md`)**:
  - Extended `Set-ReleaseVersion.ps1` and `Test-ReleaseReadiness.ps1` to synchronize and verify `PSRPM.psm1` (`$script:AppVersion`), `README.md` comparison header and SemVer footer, and `docs/USER_GUIDE.md` About version alongside the 5 core assets, and updated the release skill protocol to require secondary reference checks and `Test-PSRPMExtendedQA.ps1 -WriteTrackedReport`.

### Fixed
- **Input Isolation, Inline Validation, Search Cancellation & Action Hints (`PSRPM.psm1`, `ProcessActions.ps1`, `ConnectDialog.xaml`, `FindHandleWindow.xaml`)**:
  - Guarded global `Space` pause/resume via `$isInteractiveKeyTarget` so interactive controls receive `Space` natively.
  - Replaced modal `ConnectDialog` error popups and full-window disabling with inline validation (`1`–`65535` port validation), inline progress/error banners (`TxtConnectProgress`, `BdConnectError`, `TxtConnectError`), and targeted busy-control states.
  - Made `FindHandleWindow` searches cancellable via `BtnCancelSearchHandle` / `Esc`, generation-guarded async callbacks, indeterminate `PbHandleSearch`, and a live elapsed timer.
  - Fixed window-close ETW cleanup to check `$isLocalMode` instead of `$LocalOnly` so zero-arg local sessions tear down `PSRPM.EtwNetConsumerV1` cleanly.
  - Enriched `ProcessActions.ps1` failures with actionable `Hint:` messages for common Win32 (`5`, `87`, `299`, `740`, `1053`, `1056`, `1058`, `1060`, `1062`) and NTSTATUS (`C0000022`, `C000010A`) error codes.

## [1.12.0] - 2026-11-14

### Added
- **Documentation Overhaul & Regression Coverage (`README.md`, `Test-PSRPMEngine.ps1`)**:
  - Restructured `README.md` with hero Tree-Grid preview, **10-Second Quickstart**, **Why PSRPM?** engineering problem/benchmark breakdown, full TCPView-style **Network Activity** + opt-in Kernel ETW documentation, 5-tab System Information, 6-theme showcase, 30-column catalog, and complete parameter/shortcut/RBAC reference.
  - Added Test `12O` in `Tests/Test-PSRPMEngine.ps1` covering coordinator shutdown disposal, local collector unmanaged cleanup, same-tick PID-reuse eviction, `CloseTcpConnection` / `KillTree` guards, clipboard wrappers, 6-theme parity, `< 256 B` GZIP bypass, and `PendingNetTimeline`.

### Changed
- **Performance, Memory & 6-Theme Consistency (`DataCollector.ps1`, `ViewModelClasses.ps1`, `PSRPM.psm1`, `UI/*.xaml`)**:
  - Added dynamic Class 8 scratch buffer scaling in `DataCollector.ps1` (`8 KB` up to `CoreCount * 48` / `128 KB`) to support systems with `> 170` logical processors.
  - Added `< 256`-byte raw UTF-8 JSON wire bypass in `DataCollector.ps1` (`Test-GzipPerformance.ps1`) to eliminate compression expansion on tiny idle payloads.
  - Cached frozen `PSRPMThemeRegistry` palettes (`_PaletteCache`), cached frozen UI indicator brushes, switched `GridNetworkSockets` to keyed in-place diff reconciliation, added `2,000`-event off-tab `PendingNetTimeline` queueing, unified `$appendLogSafe` with sticky-bottom auto-scroll, and normalized mini-card double-clicks across tabs `1`–`4`.
  - Migrated hardcoded light-mode brushes and DataGrid selection styles across `ServiceDetailWindow.xaml`, `SystemInfoWindow.xaml`, `PropertiesWindow.xaml`, and `MainWindow.xaml` to `DynamicResource` tokens, and updated `HelpWindow.xaml`, `DESIGN.md`, `PRODUCT.md`, `ENGINEERING_PLAYBOOK.md`, `TELEMETRY_AND_PROTOCOL.md`, and `USER_GUIDE.md`.
- **Extended QA Suite Reliability (`Test-PSRPMExtendedQA.ps1`, `Test-ReleaseReadiness.ps1`)**:
  - Eliminated Windows `Start-Sleep` timer flake in `Suite 8.2`, synchronized `Suite 8.4`–`8.6` UI settle checks, expanded XAML/theme/log-cap assertions to 8 dialogs / 6 themes / `72,000` chars, added `-WriteTrackedReport` opt-in reporting, and updated `[CHECK 6]` banner to `12-Suite Verification`.

### Fixed
- **Async Closures, Shutdown Teardown & Action Hardening (`PSRPM.psm1`, `RunspaceEngine.ps1`, `DataCollector.ps1`, `ProcessActions.ps1`, `DeepInspector.ps1`)**:
  - Fixed `ServiceDetailWindow` `$bc.ConvertFromString` `InvokeMethodOnNull` crash via `DynamicResource` badge style resolution.
  - Captured async `.GetNewClosure()` variables and gated completion updates on `$ok` across `PropertiesWindow` (`Suspend/Resume`, `KillProcess`, `KillTree`) and `ServiceDetailWindow`, and captured `$localWindow` with ownerless `MessageBox` fallback in `$invokeProcessAction`.
  - Fixed coordinator worker shutdown (`CoordLocalWorker.WakeEvent`) and added `DataCollector` `"Dispose"` unmanaged `AllocHGlobal` cleanup on tab close, target switch, and shutdown.
  - Hardened same-tick PID reuse eviction (`RunspaceEngine.ps1`), `CloseTcpConnection` `PID > 4` & socket-owner checks plus `KillTree` root-open refusal (`ProcessActions.ps1`), bounded PEB Unicode reads and dynamic up-to-`262,144`-byte module enumeration (`DeepInspector.ps1`), `try/catch` clipboard helpers (`$copyToClipboardSafe`), `MenuSwitchLocal` reset parity, `-LiteralPath` CSV export, filter-aware `$jumpToProcessInMainGrid`, and `10 MB` `$jssAction.MaxJsonLength`.

## [1.11.0] - 2026-11-14

### Added
- **Network Activity Workspace Tab & Active Socket Inspector (`MainWindow.xaml`, `DeepInspector.ps1`, `ProcessActions.ps1`, `PSRPM.psm1`)**:
  - Added the `Network Activity` workspace tab (`TabNetworkActivity`) featuring **Active Sockets** (`GridNetworkSockets`, Sysinternals TCPView-style live IPv4/IPv6 TCP/UDP endpoint view with protocol/state filter chips, search, 2-second auto-refresh, and CSV export) and **ETW Activity Stream** (`GridNetworkTimeline`).
  - Added `AllSockets` mode and shared native `OWNER_MODULE` + per-connection EStats (`GetPerTcpConnectionEStats` / `GetPerTcp6ConnectionEStats`) enumeration in `DeepInspector.ps1` (`PSRPM.NativeInspectorV3`).
  - Added `CloseTcpConnection` action backed by `iphlpapi.dll!SetTcpEntry` in `ProcessActions.ps1` (`PSRPM.NativeActionsV4`).
- **System Information `Network` Tab & Interactive Graph Hover Telemetry (`SystemInfoWindow.xaml`, `ViewModelClasses.ps1`, `PSRPM.psm1`, `MainWindow.xaml`)**:
  - Added a 5th `Network` tab and `QuadNet` Summary strip to System Information plus the `BorderTelemNetRate` toolbar pill, powered by 240-sample auto-scaled Rx/Tx history and session totals in `SystemSummaryViewModel`.
  - Added interactive crosshair hover tooltips with timestamped top-process attribution (`RecordTopProcessSample`, `GetGraphHoverInfo`, `GetCoreHoverInfo`) across toolbar mini sparklines (`GridMiniCpu`, `GridMiniCommit`, `GridMiniRam`) and System Information charts.
- **Process Baseline Snapshots, Session Peaks & 30-Column Catalog (`ViewModelClasses.ps1`, `RunspaceEngine.ps1`, `SelectColumnsWindow.xaml`, `PSRPM.psm1`, `MainWindow.xaml`)**:
  - Added `Ctrl+B` Process Baseline Snapshots (`MenuViewBaseline` / `MenuViewClearBaseline` / `BadgeBaselineActive`) with PID-reuse `CreateTime` protection (`[NEW]` markers), inline memory delta badges, and theme-aware delta brushes.
  - Added 4 opt-in columns (`Peak CPU`, `Peak Private`, `Private Delta`, `WS Delta`), expanding `Get-PSRPMColumnCatalog` and `SelectColumnsWindow.xaml` from 26 to 30 columns with numeric sorting (`RunspaceEngine.ps1`) and preference persistence support.
  - Added enriched row (`ProcessHoverToolTip`) and cell (`CpuCellToolTip`, `PrivateCellToolTip`, `WsCellToolTip`, `HandlesCellToolTip`) hover tooltips on `ProcessItemViewModel`.
- **Tokyo Night Themes & Centralized Theme Registry (`ViewModelClasses.ps1`, `PSRPM.psm1`, `DESIGN.md`)**:
  - Added `PSRPMThemeRegistry` and two new themes (`TokyoNight`, `TokyoNightLight`) for a 6-theme engine (`Light`, `Dark`, `TokyoNight`, `TokyoNightLight`, `Classic`, `HighContrast`) exposed via `-Theme`, `Options -> Theme`, `Ctrl+D`, and `preferences.json`.
- **Expanded Automated Verification (`Tests/Test-PSRPMEngine.ps1`)**:
  - Added tests `12L`, `12M`, and `12N` covering the 6-theme registry and WCAG contrast, Network SysInfo/AllSockets/`CloseTcpConnection`, session peaks/baseline diffs with PID-reuse protection, 30-column preferences, and 240/30/60 circular graph hover attribution.

### Changed
- **Dynamic Theme Token Migration & Screenshot Tooling (`MainWindow.xaml`, `HelpWindow.xaml`, `PropertiesWindow.xaml`, `tools/Capture-Screenshots.ps1`)**:
  - Migrated remaining hardcoded accent, badge, status swatch, and action button colors across `MainWindow.xaml`, `HelpWindow.xaml`, and `PropertiesWindow.xaml` to `DynamicResource` theme tokens.
  - Updated `New-ModernWindowFrame` in `tools/Capture-Screenshots.ps1` to preserve parent `<Window.Resources>` before detaching window content and regenerated the 2x Retina screenshots.

## [1.10.0] - 2026-11-14

### Added
- **Select Process Columns Dialog & Expanded Column Catalog (`SelectColumnsWindow.xaml`, `PSRPM.psm1`, `MainWindow.xaml`)**:
  - Added the `Select Process Columns` dialog (`MenuViewSelectColumns` / header context menu) with live search filtering, column visibility toggles, display-order adjustment, and presets (`Default (10)`, `Process Explorer`, `Forensic / Security`).
  - Added `FileVersion` (`ver` / `ColVersion`), `ColBasePriority`, and `ColCategory` columns along with numeric and dynamic sorting for `ParentPID`, `SessionId`, `BasePriority`, `CreateTime`, and `Status` in `RunspaceEngine.ps1`.
- **Explicit User Preferences Persistence (`PSRPM.psm1`, `MainWindow.xaml`, `Test-PSRPMEngine.ps1`)**:
  - Added `Save Preferences` (`MenuSavePreferences`) and `Reset Preferences` (`MenuResetPreferences`) persisted to `%LOCALAPPDATA%\PSRPM\preferences.json`, covering theme, window pinning, category highlights, tree/sort settings, refresh interval, log console visibility/height/auto-scroll, and visible/ordered/sized columns.
  - Added field-level sanitization and malformed JSON fail-open resilience, verified by automated Test `12K`.
- **`FileVersion` Static Process Metadata (`DataCollector.ps1`, `ViewModelClasses.ps1`)**:
  - Collected and cached `FileVersionInfo.FileVersion` (`ver`) in `$script:FileMetaCache` and exposed `FileVersion` on `ProcessItemViewModel`.

### Changed
- **Modal Dialog Theme Synchronization & DataGrid Virtualization (`PSRPM.psm1`, `ConnectDialog.xaml`, `HelpWindow.xaml`, `MainWindow.xaml`, `FindHandleWindow.xaml`, `PropertiesWindow.xaml`, `ServiceDetailWindow.xaml`)**:
  - Updated `ConnectDialog.xaml` and `HelpWindow.xaml` to use `DynamicResource` theme brushes synced via `$syncDialogThemeBrushes`, and added `MenuThemeCycle` to cycle themes from the menu bar.
  - Enabled row virtualization (`VirtualizingPanel.IsVirtualizing`, `VirtualizationMode="Recycling"`, `EnableRowVirtualization`) on `GridServices`, `FindHandleWindow`, `GridPropDlls`, and `GridPropHandles`.
  - Updated `SetPriority` menu bindings to use `Tag` dispatch and refined action tooltips/button labels across `MainWindow.xaml`, `PropertiesWindow.xaml`, and `FindHandleWindow.xaml`.

### Fixed
- **Native Memory & Handle Lifecycle Hardening (`DeepInspector.ps1`, `ProcessActions.ps1`)**:
  - Initialized unmanaged pointers (`$hBufPtr`, `$objBuf`, `$modBuf`, `$sysBufPtr`) to `[IntPtr]::Zero` before `AllocHGlobal` and guarded `FreeHGlobal` in `try/finally` blocks.
  - Wrapped `DuplicateHandle` probe handles in `try/finally` cleanup and disposed `WindowsIdentity` in `CreateDump`.

## [1.9.0] - 2026-11-14

### Added
- **Always On Top Window Pinning (`PSRPM.psm1`, `HelpWindow.xaml`)**:
  - Added `-AlwaysOnTop` (`-Topmost`) switch parameter to `Start-PSRPM` and `Start-RemoteProcessManager`, plus `Ctrl+Shift+T` keyboard shortcut to toggle window pinning.
- **4-Way Process Column Sort Cycling (`PSRPM.psm1`, `RunspaceEngine.ps1`, `Test-PSRPMEngine.ps1`)**:
  - Extended `Get-PSRPMNextColumnSortState` so clicking the `Process` column header cycles `Tree View (Newest First) -> Tree View (Classic Oldest First) -> Flat Ascending -> Flat Descending -> Tree View (Newest First)`.
- **Resizable Audit & Telemetry Console with Auto-Scroll Toggle (`MainWindow.xaml`, `PSRPM.psm1`)**:
  - Added a draggable resize grip thumb above the bottom Audit & Network Telemetry Console pane and an `Auto-Scroll` checkbox (`ChkLogAutoScroll`) that pauses on manual scroll-up and resumes when scrolled to the bottom.

### Changed
- **Minimized Window & Row Color Refresh Optimization (`ViewModelClasses.ps1`, `PSRPM.psm1`, `PropertiesWindow.xaml`)**:
  - Skipped sparkline geometry rebuilds while the main window is minimized (`IsWindowMinimized`) and gated `RefreshRowColors()` in `UpdateDynamic()` to status or high-CPU threshold transitions.
  - Added default Clean Light fallback brushes to `PropertiesWindow.xaml`.

## [1.8.2] - 2026-11-14

## [1.8.0] - 2026-11-12

### Added
- **Opt-In Per-Process & Tree Kernel Network ETW Telemetry (`DataCollector.ps1`, `RunspaceEngine.ps1`, `ViewModelClasses.ps1`, `MainWindow.xaml`)**:
  - Added a lazy-initialized, zero-cost-when-off pure-IL (`Reflection.Emit`) ETW consumer supporting classic System Logger MOF (`TcpIpGuid`/`UdpIpGuid`) and `Microsoft-Windows-Kernel-Network` fallback sessions.
  - Added lock-free double-buffered slot recycling (`DrainAndReset`), a 25k/50k events/sec circuit breaker, non-admin Tier 1 graceful fallback banner, and 4 opt-in DataGrid columns (`Network`, `Tree Net`, `Net Recv`, `Net Send`) with 3-tier `TreeNet` hierarchy rollup and numeric sorting.
- **Multi-Select Process Selection & Batch Actions (`MainWindow.xaml`, `PSRPM.psm1`, `RunspaceEngine.ps1`, `HelpWindow.xaml`)**:
  - Enabled `Extended` selection (`Ctrl+Click`, `Shift+Click`, `Shift+Arrows`) and right-click multi-selection preservation on `GridProcesses`.
  - Added batch command dispatch for `KillProcess`, `KillTree` (with ancestor deduplication to avoid redundant child kills), `SuspendProcess`, `ResumeProcess`, and `SetPriority`, while protecting `PID <= 4` kernel processes.
- **Expanded ETW & Batch Verification (`Tests/Test-PSRPMEngine.ps1`)**:
  - Added Test 12 covering the ETW zero-cost off path, pure-IL `OnEventRecord`/`DrainAndReset`, live `OpenTraceW`+`ProcessTrace` callback delivery, 3-tier `TreeNet` rollup, >4096 PID double-bank slot recycling, per-tab ETW banner isolation, strict 7-bit ASCII audit, and multi-select batch dispatch verification.

### Changed
- **Per-Tab ETW Lifecycle & Selection Preservation (`RunspaceEngine.ps1`, `PSRPM.psm1`)**:
  - Isolated `NetEtwCap`, `NetEtwEventsPerSec`, and banner dismissal state per host tab, with automatic ETW session teardown on tab switch, tab close, or disconnect.
  - Preserved multi-row selection across differential tree reconciliations and reorders.

## [1.7.0] - 2026-11-12

### Added
- **Tree CPU Usage Column (`MainWindow.xaml`, `ViewModelClasses.ps1`, `RunspaceEngine.ps1`)**:
  - Added `Tree CPU Usage` column (`TreeCPU` / `TreeCPUFormatted`) aggregating self plus descendant CPU usage across the process hierarchy in both Tree and Flat views.
- **Process Explorer 3-Way Header Sort Cycling (`PSRPM.psm1`, `README.md`)**:
  - Added `Get-PSRPMNextColumnSortState` so clicking the `Process` column header cycles `Tree View -> Flat Ascending -> Flat Descending -> Tree View`, while other columns toggle Flat sort direction.
- **Differential Windows Services Streaming & Sub-Tick CPU Detection (`DataCollector.ps1`, `RunspaceEngine.ps1`)**:
  - Added delta service tracking (`LastSvcState` + `svcDead`) to transmit only changed or removed Windows services rather than resending the full service catalog.
  - Added `ProcCycleCache` (`CycleTime`) sub-tick CPU activity detection to display `< 0.01` when CPU activity occurs below a single scheduler tick.
- **Standalone GZIP Performance Benchmark (`Tests/Test-GzipPerformance.ps1`)**:
  - Added an end-to-end and microbenchmark test script comparing GZIP-compressed vs. raw JSON telemetry payload size, CPU cost, and latency locally or over WinRM.

### Changed
- **High-Speed Tree/Flat Sorting & Zero-Clear Reconciliation (`RunspaceEngine.ps1`, `PSRPM.psm1`, `ViewModelClasses.ps1`)**:
  - Replaced `Sort-Object` pipeline sorting with `Array.Sort` key/item sorting and in-place `vm.Children` reconciliation without `.Clear()`.
  - Updated multi-host tab switching to preserve per-tab `ConnState` and `TelemStats` and reconcile `ServicesCollection` and `CoreGraphs` in-place.
  - Added bounded cache eviction for `FileMetaCache`, `SidCache`, `DllMetaCache`, `HandleTypeCache`, `iconCache`, audit log text buffers, and completed background runspaces.
- **Reflection.Emit `SetLastError` & 32/64-Bit Struct Parameterization (`DataCollector.ps1`, `DeepInspector.ps1`, `ProcessActions.ps1`)**:
  - Switched `Reflection.Emit` P/Invoke registration from `DefinePInvokeMethod` to `DefineMethod` with `DllImportAttribute(SetLastError = true)` so `Marshal.GetLastWin32Error()` reports authentic Win32 error codes.
  - Parameterized 32-bit/64-bit handle snapshot offsets in `DeepInspector.ps1` and bounded `NtQuerySystemInformation` / `NtQueryInformationProcess` reallocation loops.

### Fixed
- **Fail-Closed Process Action Identity Verification & Dump ACL Hardening (`ProcessActions.ps1`)**:
  - Added unified `verifyProcessIdentity` (`CreationTime` + executable image leaf name) checks across `KillProcess`, `KillProcessTree`, `SuspendProcess`, `ResumeProcess`, `CloseHandle`, and `CreateDump`.
  - Moved memory dump staging out of shared `C:\temp` into privilege-scoped directories (`%SystemRoot%\Temp\PSRPM_Dumps` when elevated, `%LOCALAPPDATA%\PSRPM\Dumps` otherwise) with explicit non-inherited ACLs and reparse-point validation.
- **Expanded Verification Suite (`Tests/Test-PSRPMEngine.ps1`)**:
  - Added automated verification for the 3-way Process header sort cycle, `SetLastError=87` accuracy, `RealTime` priority refusal, unknown `ControlService` refusal, and PID-reuse identity verification.

## [1.6.3] - 2026-11-11

## [1.6.2] - 2026-11-11

### Added
- **Persistent Bottom Action Bar Across All Inspector Tabs (`PropertiesWindow.xaml`)**:
  - Pinned core process actions (`Suspend`/`Resume`, `Create Dump`, `Kill Process`, `Kill Tree`) to the bottom dock of the Process Properties Inspector, keeping them accessible across all 7 tabs (Image, Performance, DLLs, Handles, TCP/IP, Services, Environment).
- **Responsive Status Bar Layout & Overflow Indicator (`MainWindow.xaml`, `PSRPM.psm1`)**:
  - Restructured status bar into a 3-column elastic grid: left telemetry clamped to `440px` with ellipsis truncation, center scrollable legend with horizontal mouse-wheel panning, and right-pinned `Audit Console (Ctrl+L)` button.
  - Implemented automatic overflow detection with dynamic `[>> More]` / `[<< Start]` button appearing when window width is narrow.
- **Direct Dark Theme & Palette Launch Parameters (`PSRPM.psm1`, `PRODUCT.md`)**:
  - Added `-Dark` switch and `-Theme <String>` parameter to `Start-PSRPM` and `Start-RemoteProcessManager`, allowing immediate launch into Precision Dark or custom palettes.

### Changed
- **Modern Segmented Workspace Tabs & Mini Sparkline Cards (`MainWindow.xaml`)**:
  - Elevated Processes and Services tab headers with clean segmented indicators.
  - Styled CPU, Commit Charge, and Physical RAM toolbar sparklines with rounded borders and hover states.
- **In-Place Service Actions Lifecycle (`ServiceDetailWindow.xaml`, `PSRPM.psm1`)**:
  - Kept Service Details & Dependencies modal open when clicking Start, Stop, or Restart Service, displaying amber in-flight badges (`STARTING...`, `STOPPING...`, `RESTARTING...`) and automatically refreshing status in place via a 1-second timer.

### Fixed
- **Typography & Font-Weight Anti-Cascade Hardening (`MainWindow.xaml`, `PropertiesWindow.xaml`, `FindHandleWindow.xaml`, `ServiceDetailWindow.xaml`)**:
  - Eliminated accidental bold font-weight inheritance caused by WPF `TabItem` dependency property cascading.
  - Removed hardcoded `FontWeight="SemiBold"` on columns in Find Handle (Process, Type) and Properties (DLL Name, Handle Type, Service Name, Variable Name).
  - Explicitly set `FontWeight="Normal"` and `FontSize="12"` on `DataGridRow`, `RightTabularText`, and `EllipsisCellText` across all DataGrids.
- **Modeless Window Crash Hazard (`SystemInfoWindow.xaml`, `PSRPM.psm1`)**:
  - Removed `IsCancel="True"` on `BtnSysInfoOk` in modeless System Information window, preventing `InvalidOperationException` when pressing Escape.
  - Replaced hardcoded `#FFFFFF` button background with dynamic theme brush and wired an explicit Escape `KeyDown` handler to close cleanly.
- **Service-to-Process Parent Tree Expansion (`PSRPM.psm1`)**:
  - Fixed "Select Host Process in Tree" action by traversing and expanding collapsed parent nodes up to root before selecting target host processes in the tree-grid.


## [1.6.1] - 2026-11-08

### Added
- **4-Minute System Telemetry History Depth (`ViewModelClasses.ps1`, `SystemInfoWindow.xaml`)**:
  - Expanded circular ring buffer capacities from 120 samples (2 minutes) to 240 samples (4 minutes) across all 8 telemetry queues (`CpuHistory240`, `KernelHistory240`, `CommitHistory240`, `RamHistory240`, `IoTotalHistory240`, `IoWriteHistory240`, `NetRxHistory240`, `NetTxHistory240`).
  - Added backward-compatible aliases and getter methods (`GetCpuHistory240()`, `GetKernelHistory240()`, etc.) ensuring full compatibility with existing consumers.
  - Dynamically rescaled SVG area curve coordinate interpolation across the 240-sample window ($step = 360.0 / 239.0 \approx 1.506$ px/pt) on the standardized 360x120 canvas.
  - Updated System Information dashboard UI to reflect 4-minute window peak I/O throughput (`Peak I/O Rate (4m Window)`).
- **Forensic Snapshot Serialization (`PSRPM.psm1`)**:
  - Extended JSON forensic evidence export (`Ctrl+S`) to serialize the complete 240-sample historical ring buffer package under `History240` (and `History120`).
- **Dynamic Module Versioning Single Source of Truth (`PSRPM.psm1`, `HelpWindow.xaml`)**:
  - Dynamically resolved `$script:AppVersion` at module initialization from `PSRPM.psd1` (`Import-PowerShellDataFile`), eliminating hardcoded version numbers.
  - Dynamically bound Help & About window version badges (`TxtHeaderBadge`, `TxtAboutVersion`) on dialog load.
- **Release Readiness Version Synchronization Check (`Test-ReleaseReadiness.ps1`)**:
  - Added Check 5 to validate that `HelpWindow.xaml` version tags strictly synchronize with `PSRPM.psd1`.

### Changed
- **Memory Footprint Documentation (`AGENTS.md`, `DESIGN.md`, `PRODUCT.md`, `README.md`, `ENGINEERING_PLAYBOOK.md`)**:
  - Updated architectural documentation and memory budget from < 12 KB to < 20 KB local memory per host session to account for 240 samples.
- **Protocol Version Header (`DataCollector.ps1`)**:
  - Synchronized collector protocol version `colVer` string in differential JSON stream from `"1.5.0"` to `"1.6.1"`.

### Fixed
- **Handle Closure Multi-Threading UI Dispatch (`PSRPM.psm1`)**:
  - Dispatched observable collection item removal in `closeCallback` via `$win.Dispatcher.Invoke(...)`, preventing cross-thread collection modification exceptions when handle actions complete on a background runspace thread.
- **Bracketed Type Wildcard Pattern Safeguard (`PSRPM.psm1`)**:
  - Replaced wildcard string matching (`-like "[*"`) with `$tVal.StartsWith("[")`, eliminating wildcard parsing errors when handling bracketed module and pseudo-handle entries.

## [1.6.0] - 2026-11-08

### Added
- **Interactive Handle Closure in 7-Tab Process Properties (`PropertiesWindow.xaml`, `PSRPM.psm1`)**:
  - Added right-click context menu (`Close Selected Handle`, `Copy Handle Name`, `Copy Handle Value`) and `Delete` keyboard shortcut directly on the `Handles` tab DataGrid (`GridPropHandles`).
  - Added safety confirmation dialog displaying target process name, PID, handle type, and object path.
  - Implemented in-place observable collection removal (`RemoveAt`) to instantly update the UI without reloading the inspector.
- **Protocol Versioning & Sequence Gap Detection (`DataCollector.ps1`, `RunspaceEngine.ps1`)**:
  - Added protocol version headers (`"ver": 1, "colVer": "1.6.0"`) to telemetry payloads.
  - Implemented sequence number tracking (`Seq #`) with automatic baseline resynchronization upon detecting sequence gaps or collector restarts.
- **WinRM 4-State Lifecycle Machine (`RunspaceEngine.ps1`, `ViewModelClasses.ps1`, `MainWindow.xaml`)**:
  - Formalized session states: `Connected`, `Degraded`, `Reconnecting`, and `Disconnected`.
  - Added 2-stage transparent auto-recovery attempting fast `Connect-PSSession` before falling back to `New-PSSession` with bounded exponential backoff (1s, 2s, 4s, 8s, up to 16s).
  - Added visual connection status indicators and audit trail logging across all state transitions.
- **Wall-Clock Anchored Drift-Compensating Scheduler & Telemetry Freshness (`RunspaceEngine.ps1`, `ViewModelClasses.ps1`)**:
  - Replaced uncompensated `Thread.Sleep` loops with a wall-clock anchored scheduler tracking target interval boundaries to eliminate cumulative polling drift.
  - Added telemetry freshness tracking (`Fresh` <= 2.5s, `Stale` 2.5s-6s, `Frozen` > 6s) with visual status dot indicators.
- **Expanded 11-Suite Engine Verification Suite (`Tests/Test-PSRPMEngine.ps1`)**:
  - Added Tests 8 through 11 covering PID reuse race prevention, memory dump non-inherited ACL validation, atomic tree termination hierarchy, and telemetry freshness/reconnect transitions.
  - Added statistical benchmark gates: Mean collection latency <= 25 ms, P95 latency <= 35 ms, and wire payload <= 3.5 KB.
- **Two-Tier Least Privilege Architecture & RBAC Documentation (`PRODUCT.md`, `README.md`, `ENGINEERING_PLAYBOOK.md`)**:
  - Documented explicit privileges required for Tier 1 (Read-Only Monitoring) vs Tier 2 (Mutating Administrative Actions: Terminate, Suspend, Handle Closure, Dumps).
  - Qualified "100% Fileless" architecture documentation with security product visibility disclosures.

### Changed
- **Honest Kernel System I/O Throughput & IOPS (`DataCollector.ps1`, `MainWindow.xaml`, `SystemInfoWindow.xaml`)**:
  - Re-scoped telemetry indices 29-31 to genuine kernel System I/O Throughput (Read KB/s, Write KB/s) and System IOPS from Class 2 `SYSTEM_PERFORMANCE_INFORMATION`, replacing simulated queue depth.
  - Updated summary bar pills and tooltips to clearly reflect `SYS I/O: 12.4 MB/s | IOPS: 1,842`.
- **64-Bit Network Interface Polling (`DataCollector.ps1`)**:
  - Upgraded network throughput calculation from 32-bit `iphlpapi.dll!GetIfTable` to modern 64-bit `iphlpapi.dll!GetIfTable2` / `FreeMibTable`, eliminating persistent 32 KB unmanaged scratch buffers.
- **Consistent Telemetry Number Formatting (`RunspaceEngine.ps1`, `ViewModelClasses.ps1`)**:
  - Enforced single-decimal fixed-point (`F1`) formatting across all network rates, disk throughput, and cumulative wire transfer metrics (`(RX: 686.0 KB)`), eliminating fluctuating decimal places.

### Fixed
- **Process Identity Verification & PID Reuse Guard (`ProcessActions.ps1`)**:
  - Validated target process identity in `KillProcess` using dual `StartTime` FILETIME ticks and `QueryFullProcessImageNameW`, preventing collateral termination if a PID was recycled by the OS.
- **Atomic Pinned Process Tree Termination (`ProcessActions.ps1`)**:
  - Replaced slow WMI queries in `KillTree` with sub-millisecond `NtQuerySystemInformation(5)`.
  - Pinned target process handles during discovery and executed a strict two-phase protocol: top-down process suspension followed by bottom-up termination, guaranteeing supervisor processes cannot respawn child workers during termination.
- **Hardened Memory Dump Creation (`ProcessActions.ps1`)**:
  - Enforced atomic non-inherited `FileSecurity` ACLs on memory dump files at creation time using `[System.IO.FileStream]::new`, strictly restricting access to `SYSTEM`, `Administrators`, and the current user.
- **Dual-Phase Handle Closure Verification (`ProcessActions.ps1`)**:
  - Added a non-destructive verification probe using `DuplicateHandle(DUPLICATE_SAME_ACCESS)` prior to calling `DUPLICATE_CLOSE_SOURCE`, eliminating race conditions and accidental invalidation of newly recycled handle values.
- **x86 WOW64 Structure Offset Correction (`DataCollector.ps1`)**:
  - Corrected `WorkingSetSize` structure offset from 112 to 104 in 32-bit mode and added a 16 MB buffer ceiling check to prevent buffer overflow exceptions.

## [1.5.0] - 2026-11-08

### Added
- **Process Explorer-Style Full Command Line Hover Tooltips (`MainWindow.xaml`, `ViewModelClasses.ps1`)**:
  - Interactive hover tooltips for all process rows in the main Process Tree column, displaying full application launch arguments and executable path formatted in Sysinternals Process Explorer syntax:
    ```text
    Path: C:\Windows\System32\svchost.exe
    Command line: C:\Windows\System32\svchost.exe -k LocalService
    ```
  - **Cursor-Relative Non-Obstructive Positioning**: Configured `Placement="Mouse"` with `HorizontalOffset="20"` and `VerticalOffset="8"` so the tooltip anchors directly below the hovered row and offset to the right of the cursor point. This guarantees the tooltip never covers any part of the row being inspected, prevents the mouse cursor from obscuring the text, and leaves the process tree hierarchy to the left visible.
  - **Instantaneous UX Response & Ergonomics**: Set `InitialShowDelay="150"` ms for rapid appearance, `BetweenShowDelay="2000"` ms for immediate 0 ms transition when sweeping the cursor across process rows, and `ShowDuration="60000"` ms so long commands remain visible while reading. The tooltip closes immediately when moving off the row.
  - **Adaptive Text Wrapping & Monospace Typography**: Rendered in `Consolas` with `TextWrapping="Wrap"` capped at `MaxWidth="750"` to ensure long command lines (such as Chromium/Edge flags, Electron arguments, or deep PowerShell commands) wrap cleanly without horizontal truncation or multi-monitor stretching.
  - **Tree Expander Isolation**: Explicitly disabled tooltips on tree expander hit targets (`Border x:Name="BtnToggleExpander" ToolTipService.IsEnabled="False"`) to ensure clean, distraction-free node expansion and collapse.
  - **Dynamic Theme Palette Adaptation**: Integrated base `Style TargetType="ToolTip"` in `MainWindow.xaml` with dynamic resource brush bindings (`BrushSurfaceBg`, `BrushBorderSubtle`, `BrushTextPrimary`) so tooltips seamlessly harmonize across Clean Light, Precision Dark, Sysinternals Classic, and High-Contrast WCAG AAA palettes.
  - **ViewModel Infrastructure (`ViewModelClasses.ps1`)**: Added `[string]$CommandLineToolTip` and `UpdateCommandLineToolTip()` to `ProcessItemViewModel` with fallback handling for processes with inaccessible or empty command lines.
  - **Automated Verification Coverage (`Tests/Test-PSRPMEngine.ps1`)**: Added explicit unit assertions verifying `CommandLineToolTip` generation and format across 100% of the test suite.

## [1.4.0] - 2026-11-08

### Added
- **Extended Hardware Telemetry Strip & Network/Storage Counters (`DataCollector.ps1`, `ViewModelClasses.ps1`, `MainWindow.xaml`)**:
  - Added native kernel network interface bytes polling (`iphlpapi!GetIfTable`) to compute real-time Network Rx / Tx throughput in KB/s and MB/s over persistent ticks with zero WMI overhead.
  - Appended network and storage metrics to the end of the `sys` telemetry tuple with strict backward compatibility (`$sysArr.Count -gt 27`).
  - Added dedicated real-time hardware telemetry pill in `SummaryBar` (`TxtTelemNetRate`, `TxtTelemDiskRate`) displaying live `NET: v 1.2 MB/s ^ 420 KB/s` and `DISK: 4.5 MB/s Q: 0.1`.
  - Added 120-sample circular ring buffers for `NetRxHistory120` and `NetTxHistory120` in `SystemSummaryViewModel` and integrated them into the JSON forensic export.
- **Sysinternals Classic & High-Contrast WCAG AAA Themes (`ViewModelClasses.ps1`, `MainWindow.xaml`, `PSRPM.psm1`)**:
  - Integrated 4-theme palette system under `_Options -> Theme`: **Clean Light** (Sysinternals Default), **Precision Dark** (`Ctrl+D`), **Sysinternals Classic** (authentic Win32 retro `#ECE9D8` dialog face with classic pastel categories), and **High-Contrast Monochrome** (WCAG AAA compliant pure black `#000000` canvas with 21:1 contrast ratio text `#FFFFFF` and phosphor indicator pills).
  - Configured toolbar theme toggle button (`BtnToolbarTheme`) to dynamically cycle through all 4 themes.
  - Ensured lifecycle flashes (Lime Green `#86EFAC` & Crimson Red `#FCA5A5`) strictly retain priority across all 4 themes.
- **Find Handle or DLL Dialog (`FindHandleWindow.xaml`, `PSRPM.psm1`, `DeepInspector.ps1`)**:
  - Full-featured Sysinternals-inspired search dialog accessible via `Ctrl+Shift+F`, `_Find -> Find Handle or DLL...`, or toolbar binoculars button (`BtnFindHandleOrDll`).
  - Scans across all active remote/local processes for loaded DLL modules (`EnumProcessModulesEx`) and open named kernel objects (`Key`, `Section`, `Mutant`, `Event`, etc.) while strictly skipping `File` and pipe handles to prevent kernel deadlocks.
  - Interactive results grid (`GridHandleResults`) with context menu and action buttons: **Close Selected Handle** (with safety confirmation), **Go to Process in Tree** (auto-expands hierarchical ancestors in `GridProcesses`), and **Copy Path** (`Ctrl+C`).
- **Atomic Handle Invalidation / File Unlock (`ProcessActions.ps1`)**:
  - Implemented `"CloseHandle"` action using unmanaged `DuplicateHandle` with `DUPLICATE_CLOSE_SOURCE = 0x0001` to invalidate target process handles directly in kernel memory without killing host processes.
- **Remote Process Memory Dumps (`MainWindow.xaml`, `ProcessActions.ps1`, `PSRPM.psm1`)**:
  - Integrated **Create Minidump** and **Create Full Memory Dump** options under `_Process -> Create Dump` and right-click process context menu.
  - Dynamically invokes `dbghelp!MiniDumpWriteDump` via in-memory `Reflection.Emit` (zero `csc.exe` or temporary C# compilation).
  - Pre-flight disk space safety check on `C:\` and direct file write to `C:\temp\PSRPM_Dump_<ProcessName>_PID<PID>_<DumpType>_<yyyyMMdd_HHmmss>.dmp` (0 MB network transfer over WinRM).
  - Auto-copies generated remote file path to local clipboard with informative confirmation dialog.
- **Selective Category Highlighting Toggle (`ViewModelClasses.ps1`, `MainWindow.xaml`, `PSRPM.psm1`)**:
  - Added ability to toggle static category row colors (Services, User Own, Packaged, Suspended) on/off via `_Options -> Highlight Process Categories` or status bar toggle button (`BtnToggleHighlights`).
  - **Dynamic Lifecycle Flashes Preserved**: New (Lime Green `#86EFAC` / `#14532D`) and Exiting (Crimson Red `#FCA5A5` / `#7F1D1D`) process flashes remain 100% active and unmuted regardless of the category highlight state.
- **Extended Forensic JSON Export (`PSRPM.psm1`)**:
  - Enriched `_File -> Export Forensic Snapshot (JSON)` to package host telemetry, CPU/Memory/I/O ring-buffer histories (120-sample circular arrays), and complete process lists.
- **New Automated Test Cases (`Tests/Test-PSRPMEngine.ps1`, `Tests/Test-PSRPMExtendedQA.ps1`)**:
  - Added `TC-HIGHLIGHT-01`, `TC-DUMP-01`, `TC-HANDLE-01`, and `TC-HANDLE-02` tests, increasing automated QA test suite coverage to 42 comprehensive checks (100% pass rate).

### Fixed
- **Full Disk File & Folder Handle Discovery (`DeepInspector.ps1`)**:
  - Fixed issue where searching for file/folder paths (such as `C:\Users\Pictures`) in Find Handle or inspecting the `Handles` tab in Process Properties returned 0 file matches because `"File"` was unconditionally excluded in `$skipTypes`.
  - Implemented deadlock-safe Win32 file object resolution: gates file handle path queries with `GetFileType($dup) -eq 1` (`FILE_TYPE_DISK`) before calling `GetFinalPathNameByHandleW`, resolving disk files, folders, and directories safely and rapidly (< 50 ms) while completely bypassing non-disk/synchronous named pipes (e.g. Chromium / `msedgewebview2.exe` Mojo IPC pipes) to prevent kernel thread stalls.
  - Upgraded `FindHandles` process access rights from `0x1040` to `0x1440` (`PROCESS_QUERY_INFORMATION | PROCESS_DUP_HANDLE | PROCESS_QUERY_LIMITED_INFORMATION`) with graceful fallback to `0x1040`.
  - Added dynamic buffer resizing on `STATUS_INFO_LENGTH_MISMATCH` (`-1073741820`) with 256 KB initial buffer, expanded per-process scan depth to 65,536 handles (scanning all handles of large processes like Explorer without arbitrary truncation), and increased maximum search matches from 200 to 1,000.
  - Added forward/backward slash path normalization (`/` vs `\`) for search queries.
- **Empty Rows / Invisible Text in Find Handle or DLL Results Grid (`PSRPM.psm1`, `FindHandleWindow.xaml`)**:
  - Resolved WPF DataGrid binding failure where deserialized JSON items were stored as raw dictionaries (`Dictionary<string, object>`), preventing WPF `PropertyDescriptor` from resolving column bindings (`ProcessName`, `PID`, `Type`, `Handle`, `Name`). Converted elements into explicit `[PSCustomObject]` instances.
  - Added explicit contrast-safe `DataGrid.ColumnHeaderStyle`, `DataGrid.RowStyle`, and `DataGrid.CellStyle` with DynamicResource brush references to `FindHandleWindow.xaml`, ensuring high-contrast readability in both Light and Dark themes.
  - Added theme brush synchronization on window open and dynamic theme toggle (`Ctrl+D`), plus double-click row navigation to jump directly to the matched process in the main process tree.
  - Added headless verification assertion in `Tests/Test-PSRPMEngine.ps1` ensuring `GridHandleResults` cells always display non-empty text when populated with matches.
- **Modeless Dialog Script Closure Scoping (`PSRPM.psm1`)**:
  - Hoisted `$executeHandleSearch`, `$closeSelectedHandle`, `$goToProcessInTree`, and `$copySelectedPath` to function persistent scope and bound them to script state containers (`$script:FindHandleControls`, `$script:FindHandleResultsCol`), preventing "bad expression after &" runtime errors when non-modal dialogs outlive caller scriptblock stacks.
- **Modeless Dialog Close Button & Scope Routing (`FindHandleWindow.xaml`, `PSRPM.psm1`)**:
  - Removed `IsCancel="True"` from `BtnCloseDlg` to prevent `InvalidOperationException` on modeless windows shown via `.Show()`.
  - Routed the dialog close button and window `Escape` key directly to `$script:ActiveFindHandleWin.Close()`, ensuring reliable teardown regardless of outer function lifetime.
  - Rewrote `add_MouseDoubleClick` and `add_KeyDown` handlers to reference `$script:FindHandleControls['GridHandleResults']`, resolving `$null` scope resolution errors after the opening function returns.
- **Closed Handle Reconciliation in DataGrid (`PSRPM.psm1`)**:
  - Fixed issue where successfully closed handles remained in `FindHandleWindow` until re-searching: resolved PowerShell 5.1 dynamic closure scoping where `$script:FindHandleResultsCol` resolved to `$null` inside nested `.GetNewClosure()`. Captured `$targetCol`, `$targetWin`, `$targetStatus`, and `$targetSel` before closure creation to execute `.RemoveAt($removeIdx)` immediately on the UI thread.
- **Hierarchical Ancestor Expansion in Process Tree (`PSRPM.psm1`)**:
  - In `goToProcessInTree`, replaced `.Parent` lookup with recursive `ParentPID` resolution against `$engineHandle.ProcessMap`, ensuring all ancestor nodes are expanded (`IsExpanded = $true`, `UpdateExpanderGeometry()`) and refreshed before scrolling to matched processes.
- **Signed Integer Pointer Cast Hardening (`DataCollector.ps1`, `DeepInspector.ps1`)**:
  - Replaced direct `[uint32]` casts on `Marshal::ReadInt32` and `BitConverter::ToInt32` with safe 64-bit masking `([long][Marshal]::ReadInt32(...) -band 0xFFFFFFFFL)` to eliminate `PSInvalidCastException` when bit 31 is set on handle access masks, timestamps, or memory counters.
- **Architecture-Adaptive `MODULEINFO` Buffer Sizing (`DeepInspector.ps1`)**:
  - Parameterized `GetModuleInformation` buffer size based on `[IntPtr]::Size` (24 bytes on x64 vs 12 bytes on x86) to prevent `ERROR_INVALID_PARAMETER` (87) on 32-bit PowerShell runtimes.
- **Services Filter Predicate Closure (`PSRPM.psm1`)**:
  - Closed over the search filter text via `$svcView.Filter = [Predicate[Object]]({ ... }.GetNewClosure())` to prevent `ArgumentNullException` on `string.IndexOf(null)` during background telemetry ticks.
- **Credential Picker Scope Shadowing (`PSRPM.psm1`)**:
  - Wrapped credentials in a reference container `$credHolder = @{ Value = $Credential }` to prevent child-local variable shadowing in `$btnPickCred.add_Click`.
- **System Information Multi-Session Isolation (`PSRPM.psm1`)**:
  - Bound `actionShowSystemInfo` to the active host tab's `SummaryVm`, ensuring remote session graphs and counters update accurately across multiple host tabs.
- **Forensic JSON Export Property Alignment (`PSRPM.psm1`)**:
  - Aligned JSON snapshot field names with `SystemSummaryViewModel` schema (`CpuUsage`, `KernelCpuUsage`, `CommitUsedMB`, `CommitLimitMB`, `RamTotalMB`, `RamUsedMB`).
- **Create Memory Dump Button in Process Properties Image Tab (`PropertiesWindow.xaml`, `PSRPM.psm1`)**:
  - Added direct **Create Dump** button (`BtnPropCreateDump`) to the Image tab of Process Properties (`PropertiesWindow.xaml`), enabling quick capture of minidumps directly while inspecting process metadata.
- **Port Number Integer Overflow (`DeepInspector.ps1`)**:
  - Replaced signed `[int16]` cast on network port conversions with bitwise byte-swapping `(($rawPort -band 0xFF) -shl 8) -bor (($rawPort -band 0xFF00) -shr 8)`, preventing overflow exceptions on ephemeral ports above 32767.

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
  - **Dynamic Toolbar Pause / Resume Button**: Replaced static pause button with a reactive state toggle. When paused, `BtnToolbarPause` transforms to display an amber Play/Resume vector icon (`>`), an accented amber background, a bold `"PAUSED"` text label (`TxtToolbarPause`), and updated `"Resume Polling (Space)"` tooltip.
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
  - Single-surface hierarchical process tree with continuous pixel-snapped vector guide lines (`|`, `+-`, `\-`), interactive `[+]`/`[-]` expanders, and 16x16 application icons.
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
