# PSRPM Engineering Playbook: Mission, Guardrails, "Never-To-Do's" & Roadmap

This document captures the core architectural philosophy, strict performance budgets, hard-won PowerShell 5.1 / Win32 engineering lessons, and future roadmap for **PSRPM (PowerShell Remote Process Manager)**.

> **Who is this for?**
> Human maintainers, contributors, and AI coding assistants working on PSRPM. Read this playbook before modifying the telemetry collector, runspace engine, or WPF UI.

---

## 1. Mission & Non-Negotiable Priorities

PSRPM exists to give Windows System Administrators, Desktop Engineers, and Security Analysts the power of **Sysinternals Process Explorer** over a standard **WinRM `PSSession`** (or `-LocalOnly`) with **zero remote installation** and **near-zero target impact**.

Every design decision is governed by four pillars, in strict priority order:

1. **Connectivity (`-ComputerName` & `-LocalOnly`)**:
   - Must work over a single persistent WinRM `PSSession` without opening secondary ports, RPC/DCOM channels, or SMB file shares.
   - Must also run locally (`-LocalOnly` / `-Local`) without requiring WinRM or elevation.
2. **Performance Budget (`< 0.25%` Remote CPU, `< 1.5 KB/s` Steady-State Network)**:
   - Remote per-tick collection must complete in **`2 – 10 ms`** using a single kernel transition (`NtQuerySystemInformation`).
   - Steady-state network payloads must remain **`~1.1 – 1.8 KB/s`** by transmitting only differential changes compressed with GZIP.
   - Local workstation memory for historical graphs must remain strictly bounded (`< 12 KB` via fixed-size circular ring buffers).
3. **UX & Visual Fidelity (Process Explorer Ergonomics)**:
   - Single-surface hierarchical **Tree-Grid** with pixel-snapped vector connectors (`│`, `├─`, `└─`), semantic row colors, instant ancestor-preserving search, auto-flat column sorting, a lazy-loaded **7-tab Process Properties Inspector**, a live **4-tab System Information** window, and a real-time **Audit & Network Telemetry Console**.
4. **100% Fileless & EDR-Safe Security Posture**:
   - **Zero `csc.exe` invocations** and **zero temporary `.dll` or `.cs` files** dropped to disk on either the local workstation or the remote target.

---

## 2. The "Never-To-Do" List (Hard Guardrails & Lessons Learned)

Every rule below was learned from real-world failure modes during PSRPM's development. **Never violate these rules.**

### 🚫 1. NEVER use `Add-Type -TypeDefinition` or `Add-Type -MemberDefinition`
- **Why**: Both invoke `csc.exe` on disk and write temporary `.cs` and `.dll` files into `%TEMP%`. On enterprise endpoints, compiling C# inside a remote `wsmprovhost.exe` WinRM process triggers EDR behavioral alerts and adds 500–1,200 ms of cold-start latency.
- **Do This Instead**:
  - For Win32 / NTAPI P/Invoke signatures: Use in-memory `.NET Reflection.Emit` (`DefineDynamicAssembly` with `AssemblyBuilderAccess::Run` and `DefinePInvokeMethod`), as implemented in [`DataCollector.ps1`](../PSRPM/Private/DataCollector.ps1) and [`DeepInspector.ps1`](../PSRPM/Private/DeepInspector.ps1).
  - For ViewModels: Use pure PowerShell 5.1 native `class` declarations (`class ProcessItemViewModel : System.ComponentModel.INotifyPropertyChanged`), which the PowerShell AST compiler emits directly into memory via `Reflection.Emit`.

### 🚫 2. NEVER put non-ASCII Unicode characters inside `.ps1` or `.psm1` files
- **Why**: Windows PowerShell 5.1 reads `.ps1` and `.psm1` files without a UTF-8 BOM using the legacy `Windows-1252` codepage. Multi-byte UTF-8 characters such as `Δ` (`0xCE 0x94`), `—` (`0xE2 0x80 0x94`), or smart quotes contain byte `0x94`, which Windows-1252 interprets as a closing double-quote (`”`), silently corrupting string literals and causing fatal parser errors.
- **Do This Instead**:
  - Keep all `.ps1` and `.psm1` files strictly **7-bit ASCII**.
  - Put Unicode symbols or XML entities (`&#x...;`, `&amp;`) inside `.xaml` files (which are parsed as UTF-8 XML streams) or construct them via `[char]0x...` if ever needed in code.

### 🚫 3. NEVER use custom PowerShell 5.1 `class` types as generic type parameters inside `.GetNewClosure()`
- **Why**: When you call `{ ... }.GetNewClosure()` in PowerShell 5.1, PowerShell binds the scriptblock to an isolated dynamic module. Inside that closure, expressions like `[System.Collections.Generic.List[InspectorModuleItem]]::new()` fail at runtime with `Unable to find type [System.Collections.Generic.List]` because the CLR type resolver cannot bind custom PowerShell classes inside generic type parameters across dynamic closure modules.
- **Do This Instead**:
  - Inside UI callbacks or `.GetNewClosure()` blocks, always use `[System.Collections.Generic.List[Object]]::new()` and populate items with `[PSCustomObject]@{ ... }` (WPF `DataGrid` binds to `PSCustomObject` properties natively).

### 🚫 4. NEVER nest `.GetNewClosure()` inside another `.GetNewClosure()`
- **Why**: Nested closures in PowerShell 5.1 frequently drop parent-scope variables (`$engineHandle`, `$jss`, `$window`), causing silent `$null` invocations when async callbacks return.
- **Do This Instead**:
  - Capture required outer variables into explicit local variables immediately before creating the single `.GetNewClosure()` callback passed to `SendCommand`.

### 🚫 5. NEVER cast `Marshal::ReadInt32` directly to `[uint32]` or use C# `0UL` suffixes
- **Why**:
  - PowerShell 5.1 does not support the `UL` unsigned-long literal suffix (`0UL` causes a syntax error).
  - `Marshal::ReadInt32($ptr, $offset)` returns a signed `[int32]`. When a 32-bit kernel counter (such as `PageFaultCount`, `ContextSwitches`, or `InterruptCount`) exceeds `2,147,483,647` (`0x80000000`), `ReadInt32` returns a negative number, and `[uint32](-6627701)` throws a runtime `InvalidCastIConvertible` exception!
- **Do This Instead**:
  - Always convert unsigned 32-bit integers read from unmanaged memory using bitwise masking on `[long]`:
    ```powershell
    $val = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($ptr, $offset) -band 0xFFFFFFFFL)
    ```

### 🚫 6. NEVER query `"File"` handles synchronously during bulk handle enumeration
- **Why**: Calling `GetFileType`, `GetFinalPathNameByHandleW`, or `NtQueryObject(..., ObjectNameInformation = 1, ...)` on a synchronous named pipe handle (especially Chromium / `msedgewebview2.exe` Mojo IPC pipes) blocks inside the Windows kernel waiting for the pipe reader/writer, freezing the remote runspace indefinitely.
- **Do This Instead**:
  - In [`DeepInspector.ps1`](../PSRPM/Private/DeepInspector.ps1) (`Handles` mode), always keep `"File"` in `$skipTypes` so `NtQueryObject(ObjectNameInformation)` is only invoked on non-blocking Object Manager types (`Key`, `Section`, `Mutant`, `Event`, `ALPC Port`, `Directory`, `Semaphore`, `Job`, `Desktop`, `WindowStation`).

### 🚫 7. NEVER eagerly load `DLLs` or `Handles` when opening Process Properties
- **Why**: Enumerating 150+ loaded DLLs (`GetVersionInfo` disk reads) and 1,000+ kernel handles takes ~60 ms and 40+ KB of JSON. Doing that every time the user double-clicks a process makes the UI feel sluggish.
- **Do This Instead**:
  - Always open Process Properties in `"Core"` mode (`< 15 ms`, `< 2 KB`), which populates `Image`, `Performance`, `TCP/IP`, `Services`, and `Environment` immediately.
  - Trigger `"Modules"` (`DLLs` tab) or `"Handles"` (`Handles` tab) lazily via `PropTabControl.add_SelectionChanged` only when the user clicks those tabs.

### 🚫 8. NEVER call `Win32_Process`, `GetOwner()`, or `$Process.Responding` on steady-state ticks
- **Why**:
  - `Get-CimInstance Win32_Process` and `Invoke-CimMethod -MethodName GetOwner` cause `WmiPrvSE.exe` to spike remote CPU to 15–25%.
  - Accessing `.Responding` on a `System.Diagnostics.Process` object calls `user32!SendMessageTimeout` with a 5,000 ms timeout per window, freezing the collector whenever any GUI app on the remote machine is busy.
- **Do This Instead**:
  - Read process state from `NtQuerySystemInformation(5)` (`SYSTEM_PROCESS_INFORMATION` + `SYSTEM_THREAD_INFORMATION` `WaitReason == 5`), resolve SIDs once per new process via `OpenProcessToken` + `$script:SidCache`, and query `Win32_Service` at most once every 30 seconds.

### 🚫 9. NEVER call `$ObservableCollection.Clear()` on live-updating DataGrids
- **Why**: Calling `.Clear()` and re-adding items every second destroys the user's selected row, keyboard focus, and vertical scroll position.
- **Do This Instead**:
  - Always use the in-place diff reconciler (`$reconcileCollection` in [`RunspaceEngine.ps1`](../PSRPM/Private/RunspaceEngine.ps1)) and update existing `ProcessItemViewModel` properties in-place via dirty-checked `INotifyPropertyChanged`.

### 🚫 10. NEVER use unbounded history arrays or build hidden chart strings every tick
- **Why**: Unbounded metric lists leak memory over multi-hour sessions, and building large `PointCollection` strings when a modal is closed wastes UI thread CPU.
- **Do This Instead**:
  - Store history in fixed-capacity circular `Queue[double]` ring buffers (`120` samples = `< 12 KB` total RAM) and only execute `RefreshSysInfoGraphs()` when `$summaryVm.IsSysInfoOpen -eq $true`.

---

## 3. Zero-Leak Memory Architecture & Eviction Standards (Remote & Local)

PSRPM is designed for multi-day uninterrupted operations. Any persistent monitoring tool must guarantee zero memory growth over time. Contributors must adhere to these five memory rules:

### A. Remote Host Memory Boundaries
1. **Unmanaged Heap Pre-allocation**: Fixed buffers (`512 KB` for process enumeration and `8 KB` for scratch memory) are allocated once at session start (`[Marshal]::AllocHGlobal`). Never allocate unmanaged memory inside the per-tick collector loop.
2. **Synchronous Dead-Process Eviction**: At the end of every tick, any PID or `${PID}_${CreateTime}` key that no longer exists in `currKeys` must be pruned immediately via `.Remove()` from `$script:ProcCpuCache`, `$script:ProcMetaCache`, `$script:LastDynState`, and `$script:ActivePidToKey`.
3. **Static Metadata Suppression**: Process strings (`Path`, `CommandLine`, `Description`, `CompanyName`, `User`, `Architecture`) are serialized to the wire **only once per process lifetime**. Once recorded in `$script:SentMetaKeys`, they are never re-serialized.
4. **0.00% Remote CPU & 0 KB/s Wire in Standby**: Inactive tabs in the Multi-Host Session Bar are skipped by the polling coordinator. Standby sessions maintain an idle TCP connection without executing any remote collector code.

### B. Local Workstation Memory Boundaries
1. **Fixed Ring Buffers**: Metric histories (CPU, Kernel, Commit, RAM, I/O rates, per-core CPU) are backed by `Queue[double]` ring buffers strictly capped at **30 samples** (toolbar sparklines) and **120 samples** (2 minutes for System Information). Total historical telemetry memory is hard-capped at **< 12 KB per host session**.
2. **Lazy UI Rendering**: Vector path strings and geometry calculations (`SysCpuPoints`, `SysCommitPoints`, per-core charts) are evaluated only when the System Information modal is open (`$summaryVm.IsSysInfoOpen -eq $true`).
3. **In-Place Diff Reconciliation**: Never call `.Clear()` on live `ObservableCollection` bindings. Update existing nodes in-place via dirty-checked `INotifyPropertyChanged`.
4. **Two-Stage Process Node Reaping**: Exited processes flash red for 1 tick (`LifecycleState = 2`) and are purged from `ProcessMap` and the UI `ObservableCollection` on the subsequent tick, freeing them for immediate Garbage Collection.
5. **Bounded Log Buffers**: Activity log text boxes are capped at 24,000 characters, discarding the oldest 8,000 characters when full.
6. **WPF Freezable Protection**: All brushes, pens, and icons call `.Freeze()` to detach from WPF dependency property change-tracking graphs.

---

## 4. Standard Operating Procedures ("Do's")

1. **Bump Dynamic Assembly Type Names When Changing P/Invoke Signatures**:
   - Once a `Reflection.Emit` type (e.g., `PSRPM.NativeCollectorV2` or `PSRPM.NativeInspectorV2`) is loaded into an `AppDomain`, it cannot be unloaded without restarting PowerShell. If you add a new P/Invoke method during development, increment the suffix (`V3`) so `Import-Module -Force` compiles the updated signature immediately in existing sessions.
2. **Maintain Backward Compatibility in the Differential Wire Array**:
   - Keep existing index positions in `"sys":[...]` and `"dyn":[...]` stable; always append new metrics to the end of the array and check `$sysArr.Count` before reading extended indices.
3. **Run the Automated 7-Suite Verification Script Before Every Commit**:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-PSRPMEngine.ps1
   ```
   All 7 test suites (Fileless EDR Audit, Manifest Exports, Collector Delta Benchmark, DeepInspector Lazy Modes, ProcessActions, XAML Template Integrity, and End-to-End RunspaceEngine Reconciliation) must pass with `exit 0`.

---

## 5. Version Management & Release Strategy (Going Forward)

To maintain enterprise stability and predictable updates, PSRPM adheres to strict **Semantic Versioning (SemVer 2.0.0)**.

### A. Semantic Versioning Rules (`MAJOR.MINOR.PATCH`)
- **`MAJOR` (e.g., `1.0.0` -> `2.0.0`)**:
  - Incompatible wire protocol schema changes between collector and UI runspaces.
  - Breaking modifications to public cmdlet signatures (`Start-PSRPM`, `Start-RemoteProcessManager`).
  - Dropping Windows PowerShell 5.1 backwards compatibility.
- **`MINOR` (e.g., `1.0.0` -> `1.1.0`)**:
  - Backwards-compatible new features (e.g., adding the `Threads` tab to Process Properties, global handle/DLL search, new telemetry counters, or new visual themes).
  - New parameter additions to existing cmdlets.
- **`PATCH` (e.g., `1.0.0` -> `1.0.1`)**:
  - Backwards-compatible bug fixes, UI styling refinements, memory leak repairs, or OS-specific edge cases (e.g., Windows 11 24H2 kernel offsets).
  - Performance and garbage collection optimizations.

### B. Single Source of Truth & The 6-Point Release Gate
The authoritative source of truth for the active release version is **`PSRPM/PSRPM.psd1`** (`ModuleVersion`). Before tagging or publishing any new release, complete this 6-point checklist:

1. **Module Manifest Version**: Bump `ModuleVersion` in `PSRPM/PSRPM.psd1`.
2. **Release Notes in Manifest**: Update `PrivateData.PSData.ReleaseNotes` in `PSRPM/PSRPM.psd1` (used by PowerShell Gallery).
3. **Changelog Record**: Move staged changes under `## [Unreleased]` in `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD`.
4. **README Version Badge**: Update the version badge in `README.md` (`img.shields.io/badge/version-X.Y.Z-0284c7.svg`).
5. **AppUserModelID / Assembly Suffix**: If P/Invoke signatures changed, bump dynamic type suffixes (e.g., `V2` -> `V3`) and update the `AppUserModelID` in `PSRPM.psm1`.
6. **Automated Verification**: Run `Test-ModuleManifest` and `Tests/Test-PSRPMEngine.ps1` to ensure all 7 verification suites pass with zero errors.

### C. Publishing to the PowerShell Gallery
```powershell
# 1. Validate manifest integrity
Test-ModuleManifest .\PSRPM\PSRPM.psd1

# 2. Run automated test suite
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-PSRPMEngine.ps1

# 3. Publish to PowerShell Gallery
Publish-Module -Path .\PSRPM -NuGetApiKey $env:PSGALLERY_API_KEY -Verbose
```

---

## 6. Prioritized Roadmap / Future Enhancements ("To-Do's")

When extending PSRPM in future iterations, prioritize features that preserve the `< 0.25%` remote CPU budget:

- [ ] **Thread Stack & Start Address Tab (`Threads` Tab in Process Properties)**:
  - Enumerate `SYSTEM_EXTENDED_THREAD_INFORMATION` (`Class 64`) on-demand to display each thread's `TID`, `CPUDelta`, `CyclesDelta`, `StartAddress` (`Module!Offset`), `Priority`, and `WaitReason`.
- [ ] **On-Demand Handle Search (`Ctrl+F` Global Handle / DLL Finder)**:
  - Allow searching across all processes on the remote machine for a locked file path, registry key, or loaded DLL name using a single on-demand remote scan.
- [x] **Multi-Host Tabbed Session Bar** *(Completed)*:
  - Supports multiple concurrent remote (`-ComputerName` via WinRM) and local targets in switchable tabs with `< 5ms` in-place swapping, state caching (`ProcessMap`, `ServicesMap`, `SummaryVm`), keyboard navigation (`Ctrl+Shift+K`, `Ctrl+W`, `Ctrl+Tab`), and 0 KB/s standby bandwidth on inactive tabs.
- [ ] **ETW / Event Log Correlation Snippet (On-Demand)**:
  - In Process Properties, optionally query recent Application Error / WER crash events (`EventID 1000 / 1001`) matching the selected executable name.
