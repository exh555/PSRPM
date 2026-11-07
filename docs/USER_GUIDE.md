# PSRPM Operator User Guide & WinRM Troubleshooting

This guide covers day-to-day workflows for system administrators and desktop engineers using **PSRPM (PowerShell Remote Process Manager)**.

---

## 1. Launching PSRPM

### Connecting to a Remote Computer (`-ComputerName`)
```powershell
Import-Module .\PSRPM\PSRPM.psd1 -Force

# Standard connection using current user credentials
Start-PSRPM -ComputerName "WORKSTATION-42"

# Connecting with explicit domain/local admin credentials
Start-PSRPM -ComputerName "10.10.50.12" -Credential (Get-Credential)

# Connecting with a faster 500ms refresh rate
Start-PSRPM -ComputerName "APP-SRV-01" -RefreshIntervalMs 500
```

### Running Locally Without WinRM (`-LocalOnly` / `-Local`)
If you are testing on a local workstation where WinRM is disabled or running under a non-administrative account:
```powershell
Start-PSRPM -LocalOnly
```

### Switching Targets Live Inside the App (`Ctrl+K`)
You do not need to close PSRPM to switch computers. Press **`Ctrl+K`** (or click **Connect** in the toolbar) to open the **Connect to Target System** dialog, where you can connect to a different remote hostname/IP, specify alternate credentials, enable SSL, or switch to `-LocalOnly` mode.

---

## 2. Navigating the Process Tree-Grid

### Tree View vs. Flat View
- **Tree View (Default)**: Displays parent-child process relationships with crisp vector connector lines (`│`, `├─`, `└─`) and `[+]`/`[-]` expanders.
  - **Mouse**: Click `[+]` or `[-]` next to any parent process to expand or collapse its subtree, or use **View -> Expand All / Collapse All**.
  - **Keyboard (`Left` / `Right` Arrows)**:
    - Press **`Left Arrow`** on an expanded parent node to collapse its branch; press **`Left Arrow`** on a collapsed or leaf node to jump directly to its parent process.
    - Press **`Right Arrow`** on a collapsed parent node to expand its branch; press **`Right Arrow`** on an expanded parent node to select its first child.
- **Automatic Flat View on Column Sort**:
  - When you click any column header (`CPU`, `Private Bytes`, `Working Set`, `PID`, `Name`, `Handles`) to sort, PSRPM automatically switches from Tree View to **Flat View** so processes are ranked globally across the entire machine.
  - Clicking the **Tree** button on the toolbar (or pressing **`Ctrl+T`**) immediately restores the hierarchical Tree View.

### Semantic Process Color Legend
The bottom status bar displays the interactive color legend (matching Sysinternals Process Explorer):
- **Services (Soft Rose)**: Processes hosting Windows Services (`svchost.exe`, `services.exe`, `spoolsv.exe`, etc.). Click the **Services** pill in the status bar to filter exclusively to service processes.
- **Own / User (Soft Indigo)**: Interactive user-session processes. Click the **Own / User** pill to filter to user processes.
- **Packaged / WebView (Cyan)**: UWP, AppContainer, and `msedgewebview2.exe` processes.
- **Suspended (Slate Grey)**: Processes whose threads are all suspended (`WaitReason == Suspended`).
- **New (Lime Green Flash)**: Flashes for 1 tick when a process spawns.
- **Exiting (Crimson Flash)**: Flashes for 1 tick when a process terminates before removal.

---

## 3. Using the 7-Tab Process Properties Inspector

Double-click any process row (or press **`Enter`**) to open the **Process Properties** dialog:

1. **Image Tab**:
   - Displays high-resolution icon, File Description, Company Name, File Version, PE Linker Build Timestamp, Executable Path (`Copy Path`), Command Line (`Copy Cmd`), remote PEB Current Directory, Autostart registry/service entry, Parent PID, User, Start Time, Architecture (`x64`, `x86`, `Arm64`), and on-demand Authenticode signature verification (**Verify** button).
   - Direct action buttons to **Suspend / Resume**, **Kill Process**, or **Kill Process Tree**.
2. **Performance Tab**:
   - Displays CPU usage, Base Priority, Total/Kernel/User Processor Time, CPU Cycles, Handle breakdown (`Total`, `GDI`, `USER`), Private Bytes, Working Set & Peak Working Set, Virtual Size, Page Faults, Paged/Non-Paged Pool, I/O Read/Write bytes and operation counts, plus a live **Process Ancestry & Descendant Tree**.
3. **DLLs Tab *(Lazy Loaded On-Demand)***:
   - Queries all loaded modules (`Name`, `Description`, `Company Name`, `Version`, `Size`, `Base Address`, `Path`) when the tab is selected.
4. **Handles Tab *(Lazy Loaded On-Demand)***:
   - Queries named kernel handles (`Type`, `Name`, `Handle`, `Access`) when the tab is selected.
5. **TCP/IP Tab**:
   - Lists active TCP connections and listening UDP endpoints owned by the process.
6. **Services Tab**:
   - Lists all Windows Services hosted inside the selected process (especially useful for inspecting `svchost.exe` instances).
7. **Environment Tab**:
   - Reads the process's live environment variables directly from its remote PEB (`RTL_USER_PROCESS_PARAMETERS`).

---

## 4. System Information Graphs (`Ctrl+I` / Double-Click Mini Graphs)

Double-click any of the 3 mini-graphs in the top toolbar (`CPU`, `Commit`, `Phys RAM`) or press **`Ctrl+I`** (**View -> System Information...**) to open the live **System Information** window:

- **Summary Tab**: Displays static **System** (`Machine`, `Host`, `Operating System`, `CPU`, `Architecture`, `Cores`) and **Storage** (`Memory`, `Commit Limit`, `Boot Drive`, `Capacity`, `Available`, `File System`, `Type`) metadata alongside a 2×2 grid of live 2-minute history graphs (**CPU Usage**, **System Commit**, **Physical Memory**, and **I/O**). Double-clicking any of the 4 quadrant graphs jumps directly to its dedicated tab.
- **CPU Tab**: Full-size **Total CPU (Green)** + **Kernel CPU (Red)** history graph with a vertical bar gauge, live **Totals** (`Handles`, `Threads`, `Processes`), **CPU Deltas** (`Context Switch Delta`, `Interrupt Delta`, `System Call Delta`), **Topology** (`Cores`, `Sockets`, `Logical Processors`), and a **`Show one graph per CPU`** checkbox for per-core graphs.
- **Memory Tab**: Full-size **System Commit** and **Physical Memory** graphs plus exact kilobyte (`K`) breakdowns for **Commit Charge (K)** (`Current`, `Limit`, `Peak`, `Peak/Limit`, `Current/Limit`), **Physical Memory (K)** (`Total`, `Available`, `In Use`, `System Cache`), **Kernel Memory (K)** (`Paged Pool`, `Nonpaged Pool`, `Total Kernel`), and **Paging** (`Page Fault Delta`, `Page Read Delta`, `Paging File Write Delta`, `Mapped File Write Delta`).
- **I/O Tab**: Live **I/O Bytes History** graph (Blue: Total Read+Write+Other, Pink: Write+Other) with per-tick transfer deltas and session cumulative I/O.

---

## 5. Multi-Host Tabbed Sessions & Zero-Bandwidth Standby

PSRPM supports opening multiple target computers simultaneously in dedicated tabs within a single window:

- **Add a Host Tab (`Ctrl+Shift+K` or `[+] Add Host`)**:
  - Opens the Connect dialog with **"Open in a new Host Tab (keep current session warm in standby)"** checked.
  - Enter a remote hostname, IP address, or select `-LocalOnly`.
  - The new session is initialized and becomes active immediately.
- **Instant Tab Switching (`< 5 ms`)**:
  - Click any tab in the host tab bar or press **`Ctrl+Tab`** / **`Ctrl+Shift+Tab`** to cycle between hosts.
  - Each tab caches its own `ProcessMap`, `ServicesMap`, `SummaryVm`, and telemetry metrics. Switching targets swaps in-memory references instantly without redrawing or refetching over the network.
- **Zero Standby Bandwidth (`0 KB/s` & `0%` remote CPU)**:
  - While a tab is in the background ("Standby"), its WinRM `PSSession` remains connected and authenticated, but all background polling is paused. Inactive hosts consume 0 KB/s wire traffic and 0% remote CPU.
- **Close Tab (`Ctrl+W` or `x`)**:
  - Closes the active tab, terminates its background session cleanly, and automatically activates the nearest remaining tab.

---

## 6. Connecting to Workgroup or Non-Domain Computers (`TrustedHosts`)

When connecting by IP address or to a machine outside an Active Directory domain:
```powershell
# Run once in an elevated PowerShell session on your local workstation:
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "10.20.30.45" -Concatenate -Force

# Connect with explicit credentials:
Start-PSRPM -ComputerName "10.20.30.45" -Credential (Get-Credential)
```

---

## 7. Help, Keyboard Shortcuts & Diagnostics Modal (`F1` / `Help` Menu)

Press **`F1`**, select **Help -> Keyboard Shortcuts & Reference...**, use **File -> Help & Shortcuts...**, or click the **`?`** button on the toolbar to open the **Help & Information Reference** modal:

- **Shortcuts Tab**: Complete matrix of keyboard accelerators categorized by Navigation & View Controls, Process Operations, Multi-Host Session Management, and File/Application.
- **Architecture & Safety Tab**: Architectural reference documenting 100% fileless security, ultra-low remote target overhead (< 0.25% CPU), differential wire streaming (~1.1-1.8 KB/s), zero-leak circular ring buffers, and named-pipe kernel deadlock prevention.
- **Connectivity Tab**: In-app remoting guide explaining WinRM setup, non-domain `TrustedHosts` configuration, zero-privilege `-LocalOnly` local monitoring, and the semantic process row color legend.
- **About Tab**: Version details (v1.1.0), licensing, and live runtime environment diagnostics (local workstation, operator identity, current target endpoint, transport protocol, PowerShell version, CLR/.NET runtime, and process architecture).
