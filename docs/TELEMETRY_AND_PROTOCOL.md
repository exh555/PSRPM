# PSRPM Telemetry Engine & Differential Wire Protocol

This document explains the internal architecture of **PSRPM**'s remote collection engine ([`DataCollector.ps1`](../PSRPM/Private/DataCollector.ps1)), on-demand deep inspector ([`DeepInspector.ps1`](../PSRPM/Private/DeepInspector.ps1)), and host synchronization coordinator ([`RunspaceEngine.ps1`](../PSRPM/Private/RunspaceEngine.ps1)).

---

## 1. Design Goals

1. **Near-Zero Impact on the Remote Target (`< 0.25%` CPU)**:
   - Traditional PowerShell process tools call `Get-CimInstance Win32_Process` or `Invoke-CimMethod -MethodName GetOwner`, which spawns `WmiPrvSE.exe` RPC storms and consumes 10%–25% CPU on the remote system.
   - Even `.NET`'s `System.Diagnostics.Process.GetProcesses()` allocates hundreds of managed wrapper objects per second and triggers expensive `SendMessageTimeout` calls if `$proc.Responding` is accessed.
   - **PSRPM** bypasses both WMI and `System.Diagnostics.Process` during steady-state polling by invoking `ntdll.dll!NtQuerySystemInformation(SystemProcessInformation = 5)` directly into a persistent unmanaged memory buffer.
2. **Minimal Network Bandwidth (`~1.1 – 1.8 KB/s` steady state)**:
   - On a typical server or workstation with 175 processes, around 120 processes are completely idle on any given 1-second tick, and static strings (executable path, command line, file description, company name, user account) never change after process creation.
   - PSRPM caches static metadata in the remote runspace and transmits **only** compact numeric deltas for processes whose CPU, working set (`> 4 KB`), private bytes (`> 4 KB`), thread count, handle count, or suspended state changed during the last second.
3. **100% Fileless Execution (Zero `csc.exe`, Zero Temp DLLs)**:
   - All native Win32/NTAPI P/Invoke signatures are emitted directly into memory via `.NET Reflection.Emit` (`AssemblyBuilderAccess.Run`). No C# source files or `.dll` artifacts are ever written to `%TEMP%` on either the local workstation or the remote target.

---

## 2. Differential Wire Payload Schema

Every poll returns a compact JSON dictionary (automatically GZIP-compressed and prefixed with `GZIP:` whenever raw JSON exceeds `2,048` bytes):

```json
{
  "seq": 44,
  "sys": [5.3, 11240, 16384, 173, 2140, 74500, 14200, 24576],
  "meta": [
    {
      "id": 5748,
      "ct": 134070129640000000,
      "n": "svchost.exe",
      "p": 908,
      "u": "NT AUTHORITY\\SYSTEM",
      "arch": "x64",
      "path": "C:\\Windows\\System32\\svchost.exe",
      "cmd": "C:\\Windows\\System32\\svchost.exe -k LocalService -p",
      "desc": "Host Process for Windows Services",
      "comp": "Microsoft Corporation",
      "start": "12:56:44",
      "sid": 0,
      "prio": 8,
      "cat": "Service"
    }
  ],
  "dyn": [
    [5748, 0.42, 14827520, 4915200, 6, 184, 0],
    [4, 0.18, 356352, 184320, 162, 3290, 0]
  ],
  "dead": [9812],
  "svc": null
}
```

### Top-Level Payload Keys

| Key | Type | Frequency | Description |
| :--- | :--- | :--- | :--- |
| **`seq`** | `int` | Every tick | Monotonically increasing sequence number for the current session. |
| **`sys`** | `array[8]` | Every tick | System summary tuple: `[CpuPct, RamUsedMB, RamTotalMB, TotalProcs, TotalThreads, TotalHandles, CommitUsedMB, CommitLimitMB]`. |
| **`meta`** | `array[object]` | Only on `Seq #1` or new process spawn | Static metadata objects keyed by `${PID}_${CreateTime}` so PID reuse by the Windows kernel is immediately detected as a new process. |
| **`dyn`** | `array[tuple]` | Every tick (changed processes only) | 7-element numeric array: `[PID, CpuPct, WorkingSetBytes, PrivateBytes, Threads, Handles, StatusFlags]`. (`StatusFlags & 1` = `Suspended`). |
| **`dead`** | `array[int]` | Only when processes exit | List of PIDs that terminated since the previous tick. |
| **`svc`** | `array[object]` | On `Seq #1` and every `30s` | Compact service records (`n`: Name, `d`: DisplayName, `p`: Host PID, `st`: State, `sm`: StartMode, `u`: Account). |

---

## 3. Lazy On-Demand Deep Inspector Modes (`DeepInspector.ps1`)

To guarantee that double-clicking a process is instantaneous and never floods the remote system or network, [`DeepInspector.ps1`](../PSRPM/Private/DeepInspector.ps1) supports three targeted execution modes:

1. **`InspectMode = "Core"` (Triggered when opening Process Properties)**:
   - Reads PE header linker timestamp, remote PEB `CurrentDirectory` and `Environment` block, extended `SystemProcessInformation` I/O and pool counters, GDI/USER handle counts, cached Windows Services for that PID, and `iphlpapi!GetExtendedTcpTable` / `GetExtendedUdpTable` endpoints.
   - **Skips** `DLLs` and `Handles` enumeration.
   - **Performance**: `~12–25 ms` execution time, `~1.5–2.5 KB` payload.
2. **`InspectMode = "Modules"` (Triggered lazily when clicking the `DLLs` tab)**:
   - Enumerates loaded modules via `psapi.dll!EnumProcessModulesEx` (`LIST_MODULES_ALL = 0x03`), caching `FileVersionInfo` metadata (`$script:DllMetaCache`) by lowercase file path across inspections so system DLLs (`ntdll.dll`, `kernel32.dll`, etc.) are read from disk at most once per session.
   - **Performance**: `~30–45 ms` execution time.
3. **`InspectMode = "Handles"` (Triggered lazily when clicking the `Handles` tab)**:
   - Queries `ntdll.dll!NtQueryInformationProcess(ProcessHandleInformation = 51)` and duplicates handles into the inspector process via `DuplicateHandle`.
   - **Deadlock Prevention**: Skips synchronous `"File"` / named-pipe IRP queries (which can deadlock in kernel mode when Chromium/`msedgewebview2.exe` worker threads block on synchronous Mojo pipes) and queries non-blocking Object Manager types (`Key`, `Section`, `Mutant`, `Event`, `ALPC Port`, `Directory`, `Semaphore`, `SymbolicLink`, `Job`, `Desktop`, `WindowStation`).
   - **Performance**: `~20–35 ms` execution time, zero pipe-hang risk.

---

## 4. Remote Memory Management & Dead State Pruning

To guarantee that long-running remote monitoring sessions never leak memory or trigger remote garbage collection spikes, [`DataCollector.ps1`](../PSRPM/Private/DataCollector.ps1) implements four strict memory boundaries:

1. **Pre-Allocated Unmanaged Memory Buffers**:
   - `NtQuerySystemInformation(5)` writes raw kernel structures into a reusable unmanaged buffer allocated once at session initialization (`[Marshal]::AllocHGlobal(524288)`).
   - Kernel performance metrics (`NtQuerySystemInformation(2, 8)`) use a separate reusable `8 KB` unmanaged scratch buffer (`$script:ScratchBufPtr`).
   - Zero per-tick heap allocations occur in unmanaged memory, avoiding LOH (Large Object Heap) fragmentation on the remote machine.
2. **Synchronous Dead-Process Eviction**:
   - Every tick, `$currKeys` and `$currPids` are gathered from the kernel snapshot.
   - Any PID or `${PID}_${CreateTime}` key that exited since the last tick is immediately removed from remote tracking caches (`$script:ProcCpuCache.Remove()`, `$script:ProcMetaCache.Remove()`, `$script:LastDynState.Remove()`, `$script:SentMetaKeys.Remove()`, and `$script:ActivePidToKey.Remove()`).
   - Terminated PIDs are packaged into the compact `"dead": [PID1, PID2, ...]` wire payload so the local client can purge them synchronously from UI memory.
3. **One-Time Static Metadata Serialization**:
   - Static strings (`Path`, `CommandLine`, `Description`, `CompanyName`, `User`, `Architecture`) are serialized only on process spawn.
   - Once added to `$script:SentMetaKeys`, the collector suppresses them on all subsequent ticks. Only 7-element dynamic numeric delta tuples are transmitted.
4. **Zero-Overhead Standby Hosts**:
   - When a tab is in standby mode in the Multi-Host Session Bar, the polling runspace excludes its session handle from polling.
   - Remote machines in standby consume **0.00% CPU** and transmit **0 KB/s**, while keeping the underlying WinRM TCP connection open and warm.
