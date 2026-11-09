# PSRPM -- Agent & Contributor Instructions

Before modifying any code in this repository, read **[`docs/ENGINEERING_PLAYBOOK.md`](docs/ENGINEERING_PLAYBOOK.md)**.

## Core Mission & Priority Order
1. **Connectivity**: Connect to remote PCs via `-ComputerName` over a single persistent WinRM `PSSession`, plus `-LocalOnly` (`-Local`) for local execution without WinRM.
2. **Performance**: Keep remote CPU `< 0.25%` (`2-10 ms` per tick via `NtQuerySystemInformation`), steady-state network wire size `< 1.8 KB/s` (differential GZIP JSON), and local history memory `< 12 KB` (120-sample circular ring buffers).
3. **UX & Visuals**: Sysinternals Process Explorer-inspired hierarchical Tree-Grid, semantic row colors, lazy-loaded 7-tab Process Properties Inspector, 4-tab System Information graphs (`Ctrl+I` / double-click mini graphs), and live Audit & Network Telemetry Console (`Ctrl+L`).
4. **100% Fileless Security**: Zero `Add-Type -TypeDefinition` / `MemberDefinition`, zero `csc.exe`, and zero temporary `.dll`/`.cs` files on disk.

## Critical Guardrails ("Never-To-Do's")
- **NEVER** use `Add-Type -TypeDefinition` or `Add-Type -MemberDefinition` (always use `Reflection.Emit` or pure PowerShell 5.1 `class`).
- **NEVER** put non-ASCII Unicode characters (Greek letters, em-dashes, smart quotes) inside `.ps1` or `.psm1` files (PowerShell 5.1 reads BOM-less scripts as Windows-1252, where byte `0x94` breaks string parsing).
- **NEVER** use custom PowerShell 5.1 classes as generic type parameters inside `.GetNewClosure()` blocks (use `[System.Collections.Generic.List[Object]]::new()` + `[PSCustomObject]`).
- **NEVER** nest `.GetNewClosure()` inside another `.GetNewClosure()`.
- **NEVER** cast `Marshal::ReadInt32` directly to `[uint32]` or use `0UL` literals (use `([long][Marshal]::ReadInt32($ptr, $off) -band 0xFFFFFFFFL)`).
- **NEVER** query non-disk "File" handles (pipes, sockets, character devices) synchronously via `NtQueryObject(ObjectNameInformation)` during bulk handle enumeration (always gate file path queries with `GetFileType -eq 1` -> `GetFinalPathNameByHandleW` to prevent kernel named-pipe deadlocks on `msedgewebview2.exe` while enabling full disk file/folder discovery).
- **NEVER** eagerly load `DLLs` or `Handles` when opening Process Properties (keep dialog startup in `"Core"` mode and lazy-load `"Modules"` and `"Handles"` on tab selection).
- **NEVER** call `$ObservableCollection.Clear()` on live DataGrids (always use in-place diff reconciliation).
- **NEVER** instantiate module-scoped custom PowerShell classes inside `.GetNewClosure()` blocks (route through module-scoped factory scriptblocks captured by reference to avoid dynamic module type-resolution failures).
- **NEVER** use unbounded telemetry history arrays (always use fixed-capacity circular `Queue[double]` ring buffers capped at 120 samples).
- **NEVER** use `IsCancel="True"` on buttons in modeless (`.Show()`) WPF windows (setting `DialogResult` on modeless windows throws `InvalidOperationException`).
- **NEVER** reference function-local variables inside event handlers on modeless (`.Show()`) windows (the opening function returns immediately, destroying local scope; route through module-scoped control registries or capture via `.GetNewClosure()`).
- **NEVER** use `ObservableCollection.Remove($sel)` with `[PSCustomObject]` instances across closures or runspaces (always scan in reverse by index and use `.RemoveAt($i)` matching unique keys like `PID` and `Handle`).
- **NEVER** assign to unqualified outer variables inside event scriptblocks without container wrapping (use `$credHolder = @{ Value = $Credential }` to prevent implicit scriptblock-local variable shadowing in PowerShell 5.1).
- **NEVER** create persistent WPF collection filter predicates without `.GetNewClosure()` (assigning `Filter = [Predicate[Object]]{...}` without a closure causes captured filter variables to resolve to `$null` after the setup function exits, throwing `ArgumentNullException` on `IndexOf`).
- **NEVER** hardcode 64-bit structure sizes in P/Invoke calls (always parameterize Win32 structure sizes such as `sizeof(MODULEINFO)` based on `[IntPtr]::Size`).

## Verification Requirement
Run the automated verification suite after every change:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-PSRPMEngine.ps1
```
