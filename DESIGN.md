# DESIGN.md -- PSRPM Visual System & Operate Mode Specification

## 1. Visual Authority & Design Philosophy

- **Surface Mode**: `Operate`
- **Visual Anchor**: Sysinternals Process Explorer (`procexp64.exe`), elevated with high-DPI WPF vector geometry, modern typographic hierarchy, and WCAG AA (`>= 4.5:1`) contrast across both **Clean Light** and **Precision Dark** themes.
- **Operate Mode Principles**:
  - **Density & Scanability**: High information density without visual noise. Tabular numeric columns, right alignment, and immediate visual hierarchy outrank decorative expression.
  - **Vector Geometry Over Text Glyphs**: Tree hierarchy lines, expander arrows, status indicators, and chart curves are rendered with crisp, pixel-snapped WPF `<Path>` and `<Polygon>` vectors--never Unicode text characters (`+`, `-`, `|`, `\`) that misalign across fonts and DPI scaling.
  - **Zero Visual Gimmicks**: No decorative drop shadows, glass/blur effects, rainbow gradients, or floating card containers. Every pixel serves diagnostic utility.
  - **In-Place UI Reconciliation**: Live collections update properties in-place via dirty-checked `INotifyPropertyChanged`. The UI never calls `.Clear()` on live grids, ensuring scroll position, selected rows, and expander states remain rock-solid.

---

## 2. Typography & Numerical Formatting

| Hierarchy Role | Font Family | Size | Weight | Alignment | Context / Usage |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Grid Data (Text)** | `Segoe UI` | `12px` | Normal | Left | Process Names, Descriptions, Companies, Users |
| **Grid Data (Numeric)** | `Segoe UI` | `12px` | Normal | **Right** | CPU, Private Bytes, Working Set, PID, Handles, Threads |
| **Grid Headers** | `Segoe UI` | `11px` | SemiBold | Match Column | DataGrid column header titles |
| **Tab Titles (Active)** | `Segoe UI` | `11px` | Bold | Left | Selected Host Session Tab |
| **Tab Titles (Standby)**| `Segoe UI` | `11px` | Normal | Left | Inactive Host Session Tabs |
| **Metric Badges / Pills**| `Segoe UI` | `8.5-9px` | Bold | Center | Transport Badges (`LOCAL`, `WINRM`), Filter Pills |
| **Modal Titles** | `Segoe UI` | `14px` | Bold | Left | Window headers, Section titles |
| **Status Bar Telemetry**| `Segoe UI` | `11px` | Normal | Left | Global summary metrics, wire transfer statistics |
| **Audit Console / Logs**| `Consolas` | `11px` | Normal | Left | Activity console, hex addresses, SIDs, CLI commands |

> **Tabular Numeric Standard**: Every numeric column enforces `TextAlignment="Right"` and `Typography.NumeralAlignment="Tabular"`. Figures never wobble horizontally as numbers tick.

---

## 3. Complete Color Token Palette

### A. Surface & Structural Chrome
| Token Name | Clean Light | Precision Dark | Visual Role |
| :--- | :--- | :--- | :--- |
| `BrushWindowBg` | `#F8FAFC` | `#0B0F17` | Window background and outer frame |
| `BrushToolbarBg` | `#F1F5F9` | `#111827` | Toolbar, command bar, and summary strip |
| `BrushSurfaceBg` | `#FFFFFF` | `#0F172A` | DataGrid background and dialog surfaces |
| `BrushHeaderBg` | `#E2E8F0` | `#1E293B` | Menu bar, column headers, and status bar |
| `BrushBorderSubtle` | `#CBD5E1` | `#26334D` | 1px dividers, grid lines, and panel borders |
| `BrushTreeLine` | `#64748B` | `#64748B` | Pixel-snapped parent-child tree vectors |
| `BrushTextPrimary` | `#0F172A` | `#F8FAFC` | Primary data, process names, headings |
| `BrushTextSecondary` | `#334155` | `#CBD5E1` | Descriptions, company names, secondary values |
| `BrushTextMuted` | `#64748B` | `#94A3B8` | Watermarks, zero values, dimmed filter ancestors |
| `BrushMenuBg` | `#FFFFFF` | `#161F30` | Dropdown menu and context menu popup background |
| `BrushMenuBorder` | `#CBD5E1` | `#334155` | Menu popup 1px perimeter border |
| `BrushMenuHover` | `#F1F5F9` | `#26354D` | Menu and context item interactive hover background |

### B. Process Explorer Semantic Row Categories
Semantic row coloring matches Sysinternals Process Explorer conventions, ordered by strict precedence:

| Category | Precedence | Clean Light | Precision Dark | Operational Meaning |
| :--- | :---: | :--- | :--- | :--- |
| **New Process** | 1 (Highest) | `#86EFAC` | `#14532D` | Process spawned in the current tick (1-tick Lime Green flash) |
| **Exiting Process** | 2 | `#FCA5A5` | `#7F1D1D` | Process exited in the current tick (1-tick Crimson Red flash) |
| **Suspended** | 3 | `#CBD5E1` | `#334155` | All threads suspended (`WaitReason == Suspended`) |
| **High CPU (>50%)** | 4 | `#FDE68A` | `#451A03` | Process consuming > 50% CPU |
| **Packaged / WebView2**| 5 | `#A5F3FC` | `#0E3A47` | AppContainer / UWP / `msedgewebview2` / `RuntimeBroker` |
| **Service Process** | 6 | `#FFE4E6` | `#3B1824` | Hosts Windows Services (`svchost.exe`, `services.exe`) |
| **Own / User Process** | 7 | `#E0E7FF` | `#1E2646` | Process running in operator's interactive user session |
| **System / Kernel** | 8 (Default) | `#FFFFFF` | `#0F172A` | System / Kernel Session 0 background process |

### C. Vertical Column Metric Tints
Vertical column highlights provide immediate peripheral vision for resource utilization:
- **`ColTint_CPU`**: `#2222C55E` (Light) / `#1422C55E` (Dark) -- Soft Emerald Green
- **`ColTint_PrivateBytes`**: `#28EAB308` (Light) / `#14EAB308` (Dark) -- Soft Amber Yellow
- **`ColTint_WorkingSet`**: `#22F97316` (Light) / `#14F97316` (Dark) -- Soft Tangerine Orange

### D. Interactive States
- **Row Selected**: `BrushRowSelectedBg` (`#006CBE` Light / `#0369A1` Dark) with `BrushRowSelectedFg = #FFFFFF` across all cells.
- **Row Hover**: `BrushRowHover` (`#220284C7` Light / `#330284C7` Dark).
- **Sparkline Canvas**: `BrushSparkBg` (`#FFFFFF` Light / `#090D16` Dark) with `BrushSparkBorder` (`#94A3B8` Light / `#334155` Dark).

---

## 4. Multi-Host Tabbed Session Bar UX

Located at the top of the main window directly below the menu bar, the **Host Tab Bar** orchestrates multi-endpoint monitoring:

```text
+-----------------------------------------------------------------------------------------+
| [* SRV-PROD-01 WINRM 42ms]  [* WKSTN-LOCAL-01 LOCAL 18ms  x]                 [+ Add Host] |
+-----------------------------------------------------------------------------------------+
```

### Visual Specifications
- **Active Tab**:
  - Background: `BrushSurfaceBg` (`#FFFFFF` Light / `#0F172A` Dark).
  - Top Accent Border: `2px` solid `#0284C7` (Sky Blue).
  - Title Font: `11px`, **Bold**, `BrushTextPrimary`.
  - Status Dot: `#16A34A` (Green: Connected) / `#DC2626` (Red: Disconnected) / `#EAB308` (Yellow: Paused).
  - Close Button (`x`): Visible only when multiple tabs are open (`hostTabsCollection.Count > 1`).
- **Standby Tab**:
  - Background: `BrushToolbarBg` (`#F1F5F9` Light / `#111827` Dark).
  - Border: `1px` subtle border, no top accent line.
  - Title Font: `11px`, Normal weight, `BrushTextSecondary`.
- **Transport Badge Pills**:
  - `LOCAL`: Background `#0D9488` (Teal), Foreground `#FFFFFF`, Font `8.5px Bold`.
  - `WINRM`: Background `#0284C7` (Sky Blue), Foreground `#FFFFFF`, Font `8.5px Bold`.
  - `WINRM-SSL`: Background `#7C3AED` (Purple), Foreground `#FFFFFF`, Font `8.5px Bold`.

---

## 5. Tree-Grid Vector Geometry Specifications

PSPRM rejects Unicode box-drawing characters in favor of resolution-independent WPF vector paths:

### Parent-Child Connector Geometry
- **Vertical Pass-Through Line** (`|`):
  ```xaml
  <Path Data="M 7.5,0 L 7.5,18" Stroke="{DynamicResource BrushTreeLine}" StrokeThickness="1" SnapsToDevicePixels="True"/>
  ```
- **Branch Connector** (`+-`):
  ```xaml
  <Path Data="M 7.5,0 L 7.5,18 M 7.5,9 L 16,9" Stroke="{DynamicResource BrushTreeLine}" StrokeThickness="1" SnapsToDevicePixels="True"/>
  ```
- **Terminal Child Connector** (`\-`):
  ```xaml
  <Path Data="M 7.5,0 L 7.5,9 L 16,9" Stroke="{DynamicResource BrushTreeLine}" StrokeThickness="1" SnapsToDevicePixels="True"/>
  ```

### Vector Node Expanders
- **Collapsed Node** (`+`): Chevron pointing right `M 3,1 L 8,6 L 3,11`.
- **Expanded Node** (`-`): Chevron pointing down `M 1,3 L 6,8 L 11,3`.
- **Indentation Depth**: Node indent is strictly `Level * 16px`.

---

## 6. Live System Information Modal Specifications (`Ctrl+I`)

The System Information window faithfully reproduces Sysinternals Process Explorer's visual monitoring suite:

```text
+-----------------------------------------------------------------------------------------+
| System Information [SRV-PROD-01]                                              -  [ ]  X   |
+-----------------------------------------------------------------------------------------+
| [Summary]  [CPU]  [Memory]  [I/O]                                                       |
|                                                                                         |
| +--- CPU Usage -------------------------+  +--- System Commit ------------------------+ |
| | [Bar] | [360x120 Area Chart: Total+K] |  | [Bar] | [360x120 Area Chart: Commit]     | |
| +---------------------------------------+  +------------------------------------------+ |
| +--- Physical Memory -------------------+  +--- I/O Rate -----------------------------+ |
| | [Bar] | [360x120 Area Chart: RAM]     |  | [Bar] | [360x120 Area Chart: Read+Write] | |
| +---------------------------------------+  +------------------------------------------+ |
+-----------------------------------------------------------------------------------------+
```

### Chart Coordinate System & Curves
- **Canvas Size**: Standardized `360 x 120` coordinate space (`Viewbox`).
- **History Depth**: Exactly `120` points (2 minutes of 1-second telemetry ticks).
- **Dual-Layer Area Curves**:
  - **CPU Graph**: Green total line (`#22C55E`, fill `#3322C55E`) overlaying Red kernel line (`#EF4444`, fill `#44EF4444`).
  - **Commit Graph**: Olive/gold total line (`#84CC16`, fill `#3384CC16`).
  - **Physical Memory Graph**: Amber/orange total line (`#F97316`, fill `#33F97316`).
  - **I/O Graph**: Cobalt blue total rate (`#3B82F6`, fill `#333B82F6`) overlaying Violet write rate (`#8B5CF6`, fill `#448B5CF6`).
- **Vertical Gauges**: Dynamic bar heights mapped from `0` to `120px` with formatted readouts underneath (`12.4%`, `4.8 GB`, `2.1 MB/s`).
- **Per-Core CPU Grid**: When `Show one graph per CPU` is toggled, switches to a dynamic `UniformGrid` displaying individual core curves (`CPU 0`, `CPU 1`, etc.).

---

## 7. Deep Process Properties Inspector (7-Tab Layout)

- **Header Band**: 32x32 process icon, bold process name, PID, path, and action buttons (`Suspend`/`Resume`, `Kill Process`, `Kill Tree`).
- **Tabs**:
  1. **Image**: File version, linker build timestamp, path, command line, PEB current directory, autostart location, and interactive **Verify** Authenticode signature button.
  2. **Performance**: Total/Kernel/User CPU time, cycles, working set, private bytes, virtual size, page faults, kernel pool counters, and I/O read/write deltas.
  3. **DLLs (Lazy)**: DataGrid displaying loaded modules, descriptions, versions, sizes, base addresses, and paths.
  4. **Handles (Lazy)**: DataGrid displaying open kernel handle types, names, handle values, and access masks.
  5. **TCP/IP**: Active IPv4/IPv6 TCP endpoints (`LocalEndpoint`, `RemoteEndpoint`, `State`) and UDP listening sockets.
  6. **Services**: Windows Services hosted inside the process (Name, DisplayName, Status, StartType, Account).
  7. **Environment**: Remote process PEB environment variables (Key/Value pairs) with search and clipboard copy.

---

## 8. Live Audit & Telemetry Console (`Ctrl+L`)

- **Placement**: Collapsible bottom dock panel (split grid with drag splitter).
- **Header Badges**:
  - `Transport`: RTT latency (`ms`) and rolling session average.
  - `Payload`: Wire size vs. Raw size with GZIP compression percentage (`80% GZIP`).
  - `Network`: Throughput (`KB/s`) and cumulative data received (`RX`).
  - `Delta`: Sequence number, dynamic change count (`Dyn`), spawned (`+Meta`), and exited (`-Exit`).
- **Console Stream**: Monospace `Consolas 11px` log with event category tags: `[INIT]`, `[SYNC]`, `[TELEM]`, `[PROC+]`, `[PROC-]`, `[INSPECT]`, `[ACTION]`, `[SERVICE]`, and `[CLIPBOARD]`.
- **Memory Cap**: Rolling text buffer capped at 24,000 characters, automatically trimming oldest 8,000 characters when full.
