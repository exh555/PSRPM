# Requires -Version 5.1
# PSRPM Pure PowerShell 5.1 Native ViewModel Classes
# 100% In-Memory Reflection.Emit Class Compilation (Zero DLL Writes, Zero csc.exe)
# Dirty-Checked INotifyPropertyChanged + Process Explorer Tree Geometry & Sparkline Builders

class ProcessItemViewModel : System.ComponentModel.INotifyPropertyChanged {
    [int]$PID
    [string]$PIDDisplay
    [long]$CreateTime
    [string]$Name
    [int]$ParentPID
    [double]$CPU
    [string]$CPUFormatted
    [long]$MemoryBytes
    [string]$MemoryFormatted
    [long]$PrivateBytes
    [string]$PrivateBytesFormatted
    [string]$Status
    [string]$User
    [string]$Description
    [string]$CompanyName
    [int]$Threads
    [int]$Handles
    [string]$HandlesFormatted
    [string]$Path
    [string]$CommandLine
    [string]$StartTime
    [string]$Architecture
    [int]$SessionId
    [int]$BasePriority
    [string]$Category
    [string]$HostedServices
    [int]$LifecycleState # 0 = Normal, 1 = New (Lime Flash), 2 = Exiting (Crimson Flash)

    # Tree-Grid Visual State Properties
    [bool]$IsExpanded
    [bool]$HasChildren
    [int]$Level
    [bool]$IsTreeMode
    [double]$IndentWidth
    [string]$TreeGuideVisibility
    [string]$TreeGuideGeometry
    [string]$ToggleVisibility
    [string]$LeafVisibility
    [string]$ExpanderGeometry
    [Object]$IconSource
    [string]$FallbackIconVisibility
    [string]$NameFontWeight
    [string]$RowBackground
    [string]$RowForeground
    [double]$RowOpacity
    [bool]$IsDarkTheme

    [System.Collections.ObjectModel.ObservableCollection[ProcessItemViewModel]]$Children

    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    ProcessItemViewModel() {
        $this.Children               = [System.Collections.ObjectModel.ObservableCollection[ProcessItemViewModel]]::new()
        $this.Handlers               = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.PIDDisplay             = "0"
        $this.Name                   = ""
        $this.User                   = "N/A"
        $this.Description            = ""
        $this.CompanyName            = ""
        $this.Path                   = "N/A"
        $this.CommandLine            = "N/A"
        $this.StartTime              = "N/A"
        $this.Architecture           = "x64"
        $this.Category               = "System"
        $this.HostedServices         = ""
        $this.Status                 = "Running"
        $this.CPU                    = 0.0
        $this.CPUFormatted           = ""
        $this.MemoryBytes            = 0L
        $this.MemoryFormatted        = "0 K"
        $this.PrivateBytes           = 0L
        $this.PrivateBytesFormatted  = "0 K"
        $this.Handles                = 0
        $this.HandlesFormatted       = "0"
        $this.Threads                = 0
        $this.LifecycleState         = 0
        $this.IsExpanded             = $true
        $this.HasChildren            = $false
        $this.Level                  = 0
        $this.IsTreeMode             = $true
        $this.IndentWidth            = 0.0
        $this.TreeGuideVisibility    = "Collapsed"
        $this.TreeGuideGeometry      = ""
        $this.ToggleVisibility       = "Collapsed"
        $this.LeafVisibility         = "Visible"
        $this.ExpanderGeometry       = "M 2,5.5 L 9,5.5"
        $this.IconSource             = $null
        $this.FallbackIconVisibility = "Visible"
        $this.NameFontWeight         = "Normal"
        $this.RowBackground          = "#FFFFFF"
        $this.RowForeground          = "#0F172A"
        $this.RowOpacity             = 1.0
        $this.IsDarkTheme            = $false
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        if ($this.Handlers.Count -eq 0) { return }
        $eventArgs = [System.ComponentModel.PropertyChangedEventArgs]::new($propertyName)
        for ($i = 0; $i -lt $this.Handlers.Count; $i++) {
            try { $this.Handlers[$i].Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] SetStaticMetadata([Object]$m, [bool]$isDark) {
        $this.PID          = [int]$m['id']
        $this.PIDDisplay   = $this.PID.ToString()
        $this.CreateTime   = [long]$m['ct']
        $this.Name         = [string]$m['n']
        $this.ParentPID    = [int]$m['p']
        $this.User         = [string]$m['u']
        $this.Architecture = [string]$m['arch']
        $this.Path         = [string]$m['path']
        $this.CommandLine  = [string]$m['cmd']
        $this.Description  = [string]$m['desc']
        $this.CompanyName  = [string]$m['comp']
        $this.StartTime    = [string]$m['start']
        $this.SessionId    = [int]$m['sid']
        $this.BasePriority = [int]$m['prio']
        if ($m['cat']) { $this.Category = [string]$m['cat'] }
        $this.IsDarkTheme  = $isDark

        $this.RefreshRowColors()

        $this.OnPropertyChanged('PID')
        $this.OnPropertyChanged('PIDDisplay')
        $this.OnPropertyChanged('Name')
        $this.OnPropertyChanged('ParentPID')
        $this.OnPropertyChanged('User')
        $this.OnPropertyChanged('Architecture')
        $this.OnPropertyChanged('Path')
        $this.OnPropertyChanged('CommandLine')
        $this.OnPropertyChanged('Description')
        $this.OnPropertyChanged('CompanyName')
        $this.OnPropertyChanged('StartTime')
    }

    [void] UpdateDynamic([double]$cpu, [long]$wsBytes, [long]$privBytes, [int]$threads, [int]$handles, [int]$flags) {
        $newStatus = if ($flags -band 1) { "Suspended" } else { "Running" }
        $statusChanged = ($this.Status -ne $newStatus)
        if ($statusChanged) {
            $this.Status = $newStatus
            $this.OnPropertyChanged('Status')
        }

        $cpuChanged = ($this.CPU -ne $cpu) -or $statusChanged
        if ($cpuChanged) {
            $this.CPU = $cpu
            $newCpuFmt = if ($this.Status -eq "Suspended") {
                "Suspended"
            } elseif ($cpu -le 0.0) {
                ""
            } elseif ($cpu -lt 0.05) {
                "< 0.01"
            } else {
                $cpu.ToString("F2")
            }
            $this.OnPropertyChanged('CPU')
            if ($this.CPUFormatted -ne $newCpuFmt) {
                $this.CPUFormatted = $newCpuFmt
                $this.OnPropertyChanged('CPUFormatted')
            }
        }

        if ($this.MemoryBytes -ne $wsBytes) {
            $this.MemoryBytes = $wsBytes
            $wsKB = [Math]::Round($wsBytes / 1KB, 0)
            $newWsFmt = "$($wsKB.ToString('N0')) K"
            $this.OnPropertyChanged('MemoryBytes')
            if ($this.MemoryFormatted -ne $newWsFmt) {
                $this.MemoryFormatted = $newWsFmt
                $this.OnPropertyChanged('MemoryFormatted')
            }
        }

        if ($this.PrivateBytes -ne $privBytes) {
            $this.PrivateBytes = $privBytes
            $pbKB = [Math]::Round($privBytes / 1KB, 0)
            $newPbFmt = "$($pbKB.ToString('N0')) K"
            $this.OnPropertyChanged('PrivateBytes')
            if ($this.PrivateBytesFormatted -ne $newPbFmt) {
                $this.PrivateBytesFormatted = $newPbFmt
                $this.OnPropertyChanged('PrivateBytesFormatted')
            }
        }

        if ($this.Threads -ne $threads) {
            $this.Threads = $threads
            $this.OnPropertyChanged('Threads')
        }

        if ($this.Handles -ne $handles) {
            $this.Handles = $handles
            $newHndFmt = $handles.ToString("N0")
            $this.OnPropertyChanged('Handles')
            if ($this.HandlesFormatted -ne $newHndFmt) {
                $this.HandlesFormatted = $newHndFmt
                $this.OnPropertyChanged('HandlesFormatted')
            }
        }

        $this.RefreshRowColors()
    }

    [void] SetTheme([bool]$isDark) {
        if ($this.IsDarkTheme -ne $isDark) {
            $this.IsDarkTheme = $isDark
            $this.RefreshRowColors()
        }
    }

    [void] SetLifecycleState([int]$state) {
        if ($this.LifecycleState -ne $state) {
            $this.LifecycleState = $state
            $this.RefreshRowColors()
        }
    }

    [void] RefreshRowColors() {
        $bg = "#FFFFFF"
        $fg = "#0F172A"

        if ($this.IsDarkTheme) {
            $fg = "#F1F5F9"
            if ($this.LifecycleState -eq 1) {
                $bg = "#14532D" # New Process Lime Dark
            } elseif ($this.LifecycleState -eq 2) {
                $bg = "#7F1D1D" # Exiting Process Crimson Dark
            } elseif ($this.Status -eq "Suspended") {
                $bg = "#334155" # Suspended Slate Dark
                $fg = "#CBD5E1"
            } elseif ($this.CPU -ge 50.0) {
                $bg = "#451A03" # High CPU Amber Dark
            } elseif ($this.Category -eq "Packaged") {
                $bg = "#0E3A47" # Packaged / WebView Cyan Dark
            } elseif ($this.Category -eq "Service") {
                $bg = "#3B1824" # Service Rose Dark
            } elseif ($this.Category -eq "Own") {
                $bg = "#1E2646" # Own User Periwinkle Dark
            } else {
                $bg = "#0F172A" # System Default Dark
            }
        } else {
            $fg = "#0F172A"
            if ($this.LifecycleState -eq 1) {
                $bg = "#86EFAC" # New Process Lime Light
            } elseif ($this.LifecycleState -eq 2) {
                $bg = "#FCA5A5" # Exiting Process Crimson Light
            } elseif ($this.Status -eq "Suspended") {
                $bg = "#94A3B8" # Suspended Slate Light (Process Explorer Gray)
            } elseif ($this.CPU -ge 50.0) {
                $bg = "#FDE68A" # High CPU Amber Light
            } elseif ($this.Category -eq "Packaged") {
                $bg = "#67E8F9" # Packaged / WebView Cyan Light (Process Explorer Cyan)
            } elseif ($this.Category -eq "Service") {
                $bg = "#FFE4E6" # Service Rose Pink Light (Process Explorer Pink)
            } elseif ($this.Category -eq "Own") {
                $bg = "#E0E7FF" # Own User Periwinkle Light (Process Explorer Lavender/Blue)
            } else {
                $bg = "#FFFFFF" # System Default White
            }
        }

        if ($this.RowBackground -ne $bg) {
            $this.RowBackground = $bg
            $this.OnPropertyChanged('RowBackground')
        }
        if ($this.RowForeground -ne $fg) {
            $this.RowForeground = $fg
            $this.OnPropertyChanged('RowForeground')
        }
    }

    [void] UpdateExpanderGeometry() {
        $newExpGeom = if ($this.IsExpanded) {
            "M 2,5.5 L 9,5.5"
        } else {
            "M 2,5.5 L 9,5.5 M 5.5,2 L 5.5,9"
        }
        if ($this.ExpanderGeometry -ne $newExpGeom) {
            $this.ExpanderGeometry = $newExpGeom
            $this.OnPropertyChanged('ExpanderGeometry')
        }
    }

    [void] UpdateTreeState([int]$level, [bool]$isTreeMode, [bool]$hasChildren, [string]$guideGeom, [double]$opacity) {
        $newIndent = if ($isTreeMode -and $level -gt 0) { [double]($level * 16) } else { 0.0 }
        $newGuideVis = if ($isTreeMode -and $level -gt 0) { "Visible" } else { "Collapsed" }
        $newToggleVis = if ($isTreeMode -and $hasChildren) { "Visible" } else { "Collapsed" }
        $newLeafVis = if ($isTreeMode -and -not $hasChildren) { "Visible" } else { "Collapsed" }
        $newExpGeom = if ($this.IsExpanded) {
            "M 2,5.5 L 9,5.5" # Crisp [-] minus bar
        } else {
            "M 2,5.5 L 9,5.5 M 5.5,2 L 5.5,9" # Crisp [+] plus cross
        }
        $newWeight = if ($hasChildren) { "SemiBold" } else { "Normal" }

        if ($this.HasChildren -ne $hasChildren) { $this.HasChildren = $hasChildren; $this.OnPropertyChanged('HasChildren') }
        if ($this.Level -ne $level) { $this.Level = $level; $this.OnPropertyChanged('Level') }
        if ($this.IsTreeMode -ne $isTreeMode) { $this.IsTreeMode = $isTreeMode; $this.OnPropertyChanged('IsTreeMode') }
        if ($this.IndentWidth -ne $newIndent) { $this.IndentWidth = $newIndent; $this.OnPropertyChanged('IndentWidth') }
        if ($this.TreeGuideVisibility -ne $newGuideVis) { $this.TreeGuideVisibility = $newGuideVis; $this.OnPropertyChanged('TreeGuideVisibility') }
        if ($this.TreeGuideGeometry -ne $guideGeom) { $this.TreeGuideGeometry = $guideGeom; $this.OnPropertyChanged('TreeGuideGeometry') }
        if ($this.ToggleVisibility -ne $newToggleVis) { $this.ToggleVisibility = $newToggleVis; $this.OnPropertyChanged('ToggleVisibility') }
        if ($this.LeafVisibility -ne $newLeafVis) { $this.LeafVisibility = $newLeafVis; $this.OnPropertyChanged('LeafVisibility') }
        if ($this.ExpanderGeometry -ne $newExpGeom) { $this.ExpanderGeometry = $newExpGeom; $this.OnPropertyChanged('ExpanderGeometry') }
        if ($this.NameFontWeight -ne $newWeight) { $this.NameFontWeight = $newWeight; $this.OnPropertyChanged('NameFontWeight') }
        if ($this.RowOpacity -ne $opacity) { $this.RowOpacity = $opacity; $this.OnPropertyChanged('RowOpacity') }
    }
}

class ServiceItemViewModel : System.ComponentModel.INotifyPropertyChanged {
    [string]$Name
    [string]$DisplayName
    [int]$PID
    [string]$Status
    [string]$StartType
    [string]$User
    [string]$StatusBrush

    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    ServiceItemViewModel() {
        $this.Handlers    = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.Status      = "Stopped"
        $this.StatusBrush = "#64748B"
        $this.StartType   = "Manual"
        $this.User        = "LocalSystem"
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        if ($this.Handlers.Count -eq 0) { return }
        $eventArgs = [System.ComponentModel.PropertyChangedEventArgs]::new($propertyName)
        for ($i = 0; $i -lt $this.Handlers.Count; $i++) {
            try { $this.Handlers[$i].Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] UpdateService([string]$name, [string]$disp, [int]$pidVal, [string]$status, [string]$startType, [string]$user) {
        if ($this.Name -ne $name)           { $this.Name = $name; $this.OnPropertyChanged('Name') }
        if ($this.DisplayName -ne $disp)    { $this.DisplayName = $disp; $this.OnPropertyChanged('DisplayName') }
        if ($this.PID -ne $pidVal)          { $this.PID = $pidVal; $this.OnPropertyChanged('PID') }
        if ($this.StartType -ne $startType) { $this.StartType = $startType; $this.OnPropertyChanged('StartType') }
        if ($this.User -ne $user)           { $this.User = $user; $this.OnPropertyChanged('User') }
        if ($this.Status -ne $status) {
            $this.Status = $status
            $this.StatusBrush = if ($status -eq "Running") { "#16A34A" } else { "#64748B" }
            $this.OnPropertyChanged('Status')
            $this.OnPropertyChanged('StatusBrush')
        }
    }
}

class CpuCoreGraphViewModel : System.ComponentModel.INotifyPropertyChanged {
    [int]$CoreIndex
    [string]$CoreLabel
    [string]$UsageFormatted
    [string]$TotalPoints
    [string]$TotalFillPoints
    [string]$KernelPoints
    [string]$KernelFillPoints

    hidden [System.Collections.Generic.Queue[double]] $TotalHistory
    hidden [System.Collections.Generic.Queue[double]] $KernelHistory
    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    CpuCoreGraphViewModel([int]$idx) {
        $this.CoreIndex        = $idx
        $this.CoreLabel        = "CPU $idx"
        $this.UsageFormatted   = "0.0%"
        $this.TotalPoints      = "0,79 180,79"
        $this.TotalFillPoints  = "0,80 0,79 180,79 180,80"
        $this.KernelPoints     = "0,79 180,79"
        $this.KernelFillPoints = "0,80 0,79 180,79 180,80"
        $this.TotalHistory     = [System.Collections.Generic.Queue[double]]::new()
        $this.KernelHistory    = [System.Collections.Generic.Queue[double]]::new()
        $this.Handlers         = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()

        for ($i = 0; $i -lt 60; $i++) {
            $this.TotalHistory.Enqueue(0.0)
            $this.KernelHistory.Enqueue(0.0)
        }
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        if ($this.Handlers.Count -eq 0) { return }
        $eventArgs = [System.ComponentModel.PropertyChangedEventArgs]::new($propertyName)
        for ($i = 0; $i -lt $this.Handlers.Count; $i++) {
            try { $this.Handlers[$i].Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] EnqueueSample([double]$totPct, [double]$kernPct, [bool]$buildGeom) {
        if ($this.TotalHistory.Count -ge 60)  { [void]$this.TotalHistory.Dequeue() }
        if ($this.KernelHistory.Count -ge 60) { [void]$this.KernelHistory.Dequeue() }
        $this.TotalHistory.Enqueue($totPct)
        $this.KernelHistory.Enqueue($kernPct)
        $this.UsageFormatted = "$($totPct.ToString('F1'))% (K: $($kernPct.ToString('F1'))%)"

        if ($buildGeom) {
            $this.BuildCoreGeometry()
        }
    }

    [void] BuildCoreGeometry() {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $totArr  = $this.TotalHistory.ToArray()
        $kernArr = $this.KernelHistory.ToArray()
        $maxIdx  = [Math]::Max(1, $totArr.Count - 1)
        $w = 180.0
        $h = 80.0

        $tLine = [System.Text.StringBuilder]::new(320)
        $tFill = [System.Text.StringBuilder]::new(340)
        $kLine = [System.Text.StringBuilder]::new(320)
        $kFill = [System.Text.StringBuilder]::new(340)
        [void]$tFill.Append("0,80.0 ")
        [void]$kFill.Append("0,80.0 ")

        for ($i = 0; $i -lt $totArr.Count; $i++) {
            $x  = [Math]::Round(($i / [double]$maxIdx) * $w, 1).ToString("F1", $inv)
            $tv = [Math]::Max(0.0, [Math]::Min(100.0, $totArr[$i]))
            $kv = [Math]::Max(0.0, [Math]::Min($tv, $kernArr[$i]))
            $ty = [Math]::Round(($h - 1.0) - (($tv / 100.0) * ($h - 4.0)), 1).ToString("F1", $inv)
            $ky = [Math]::Round(($h - 1.0) - (($kv / 100.0) * ($h - 4.0)), 1).ToString("F1", $inv)
            [void]$tLine.Append("$x,$ty ")
            [void]$tFill.Append("$x,$ty ")
            [void]$kLine.Append("$x,$ky ")
            [void]$kFill.Append("$x,$ky ")
        }
        [void]$tFill.Append("180.0,80.0")
        [void]$kFill.Append("180.0,80.0")

        $this.TotalPoints      = $tLine.ToString().Trim()
        $this.TotalFillPoints  = $tFill.ToString().Trim()
        $this.KernelPoints     = $kLine.ToString().Trim()
        $this.KernelFillPoints = $kFill.ToString().Trim()

        $this.OnPropertyChanged('UsageFormatted')
        $this.OnPropertyChanged('TotalPoints')
        $this.OnPropertyChanged('TotalFillPoints')
        $this.OnPropertyChanged('KernelPoints')
        $this.OnPropertyChanged('KernelFillPoints')
    }
}

class SystemSummaryViewModel : System.ComponentModel.INotifyPropertyChanged {
    # Main Window Toolbar Sparkline Properties
    [double]$CpuUsage
    [double]$KernelCpuUsage
    [string]$CpuSummaryFormatted
    [long]$RamUsedMB
    [long]$RamTotalMB
    [string]$RamSummaryFormatted
    [string]$RamPctFormatted
    [long]$CommitUsedMB
    [long]$CommitLimitMB
    [string]$CommitSummaryFormatted
    [double]$CommitPct
    [double]$RamPct
    [int]$ProcessCount
    [int]$ThreadCount
    [int]$HandleCount
    [string]$CpuPoints
    [string]$CpuFillPoints
    [string]$CommitPoints
    [string]$CommitFillPoints
    [string]$RamPoints
    [string]$RamFillPoints

    # System Information Modal State & Per-Core Toggle
    [bool]$IsSysInfoOpen
    [bool]$ShowOneGraphPerCpu
    [string]$SingleCpuGraphVisibility
    [string]$PerCpuGridVisibility
    [System.Collections.ObjectModel.ObservableCollection[Object]]$CoreGraphs

    # Summary Tab: Static System & Storage Metadata
    [string]$HwMachine
    [string]$HwHost
    [string]$HwOS
    [string]$HwCpuName
    [string]$HwArch
    [string]$HwCoresText
    [string]$HwCoresCount
    [string]$HwSocketsCount
    [string]$HwLogicalCount
    [string]$HwMemoryGBText
    [string]$HwCommitLimitGBText
    [string]$HwBootDrive
    [string]$HwDriveType
    [string]$HwCapacityGBText
    [string]$HwAvailableGBText
    [string]$HwFileSystem
    [string]$HwReadOnly

    # System Information 120-Sample Chart Point Collections (360x120 Viewbox Canvas)
    [string]$SysCpuPoints
    [string]$SysCpuFillPoints
    [string]$SysKernelPoints
    [string]$SysKernelFillPoints
    [string]$SysCommitPoints
    [string]$SysCommitFillPoints
    [string]$SysRamPoints
    [string]$SysRamFillPoints
    [string]$SysIoPoints
    [string]$SysIoFillPoints
    [string]$SysIoWritePoints
    [string]$SysIoWriteFillPoints

    # Vertical Bar Gauge Heights & Labels (44x120 Viewbox Canvas)
    [double]$CpuGaugeTotalHeight
    [double]$CpuGaugeTotalTop
    [double]$CpuGaugeKernelHeight
    [double]$CpuGaugeKernelTop
    [double]$CommitGaugeHeight
    [double]$CommitGaugeTop
    [double]$RamGaugeHeight
    [double]$RamGaugeTop
    [double]$IoGaugeHeight
    [double]$IoGaugeTop
    [string]$CpuGaugeText
    [string]$CommitGaugeText
    [string]$RamGaugeText
    [string]$IoGaugeText

    # CPU Tab Counters
    [string]$HandlesFormatted
    [string]$ThreadsFormatted
    [string]$ProcessesFormatted
    [string]$ContextSwitchDeltaFormatted
    [string]$InterruptDeltaFormatted
    [string]$SystemCallDeltaFormatted
    [string]$KernelCpuFormatted
    [string]$UserCpuFormatted

    # Memory Tab Counters (Exact KB matching Process Explorer)
    [string]$CommitCurrentK
    [string]$CommitLimitK
    [string]$CommitPeakK
    [string]$CommitPeakLimitPct
    [string]$CommitCurrentLimitPct
    [string]$PhysTotalK
    [string]$PhysAvailableK
    [string]$PhysInUseK
    [string]$SystemCacheK
    [string]$KernelPagedK
    [string]$KernelNonpagedK
    [string]$KernelTotalK
    [string]$PageFaultDeltaFormatted
    [string]$PageReadDeltaFormatted
    [string]$PageFileWriteDeltaFormatted
    [string]$MappedFileWriteDeltaFormatted

    # I/O Tab Counters
    [string]$IoTotalRateFormatted
    [string]$IoReadDeltaFormatted
    [string]$IoWriteDeltaFormatted
    [string]$IoOtherDeltaFormatted
    [string]$IoPeakRateFormatted
    [string]$IoSessionTotalFormatted

    hidden [System.Collections.Generic.Queue[double]] $CpuHistory
    hidden [System.Collections.Generic.Queue[double]] $CommitHistory
    hidden [System.Collections.Generic.Queue[double]] $RamHistory

    # 120-Sample (2-Minute) Circular Ring Buffers (< 6 KB Total Memory)
    hidden [System.Collections.Generic.Queue[double]] $CpuHistory120
    hidden [System.Collections.Generic.Queue[double]] $KernelHistory120
    hidden [System.Collections.Generic.Queue[double]] $CommitHistory120
    hidden [System.Collections.Generic.Queue[double]] $RamHistory120
    hidden [System.Collections.Generic.Queue[double]] $IoTotalHistory120
    hidden [System.Collections.Generic.Queue[double]] $IoWriteHistory120
    hidden [long] $SessionIoBytesTotal
    hidden [double] $PeakIoBytesDelta

    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    SystemSummaryViewModel() {
        $this.Handlers               = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.CpuHistory             = [System.Collections.Generic.Queue[double]]::new()
        $this.CommitHistory          = [System.Collections.Generic.Queue[double]]::new()
        $this.RamHistory             = [System.Collections.Generic.Queue[double]]::new()
        $this.CpuHistory120          = [System.Collections.Generic.Queue[double]]::new()
        $this.KernelHistory120       = [System.Collections.Generic.Queue[double]]::new()
        $this.CommitHistory120       = [System.Collections.Generic.Queue[double]]::new()
        $this.RamHistory120          = [System.Collections.Generic.Queue[double]]::new()
        $this.IoTotalHistory120      = [System.Collections.Generic.Queue[double]]::new()
        $this.IoWriteHistory120      = [System.Collections.Generic.Queue[double]]::new()
        $this.CoreGraphs             = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()

        $this.IsSysInfoOpen            = $false
        $this.ShowOneGraphPerCpu       = $false
        $this.SingleCpuGraphVisibility = "Visible"
        $this.PerCpuGridVisibility     = "Collapsed"
        $this.SessionIoBytesTotal      = 0L
        $this.PeakIoBytesDelta         = 1024.0

        $this.CpuUsage               = 0.0
        $this.KernelCpuUsage         = 0.0
        $this.CpuSummaryFormatted    = "0.0%"
        $this.RamUsedMB              = 0
        $this.RamTotalMB             = 0
        $this.RamSummaryFormatted    = "0 / 0 MB"
        $this.RamPctFormatted        = "0.0%"
        $this.CommitUsedMB           = 0
        $this.CommitLimitMB          = 0
        $this.CommitSummaryFormatted = "0.0%"
        $this.ProcessCount           = 0
        $this.ThreadCount            = 0
        $this.HandleCount            = 0
        $this.CpuPoints              = "0,25 92,25"
        $this.CpuFillPoints          = "0,26 0,25 92,25 92,26"
        $this.CommitPoints           = "0,25 98,25"
        $this.CommitFillPoints       = "0,26 0,25 98,25 98,26"
        $this.RamPoints              = "0,25 105,25"
        $this.RamFillPoints          = "0,26 0,25 105,25 105,26"

        # Default System Information Values
        $cores = [Environment]::ProcessorCount
        $this.HwMachine           = "Windows Workstation"
        $this.HwHost              = [string]$env:COMPUTERNAME
        $this.HwOS                = [Environment]::OSVersion.VersionString
        $this.HwCpuName           = "Processor"
        $this.HwArch              = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
        $this.HwCoresText         = "$cores physical / $cores logical"
        $this.HwCoresCount        = "$cores"
        $this.HwSocketsCount      = "1"
        $this.HwLogicalCount      = "$cores"
        $this.HwMemoryGBText      = "0.0 GB"
        $this.HwCommitLimitGBText = "0.0 GB"
        $this.HwBootDrive         = "C:\"
        $this.HwDriveType         = "Fixed"
        $this.HwCapacityGBText    = "0.0 GB"
        $this.HwAvailableGBText   = "0.0 GB"
        $this.HwFileSystem        = "NTFS"
        $this.HwReadOnly          = "No"

        $this.SysCpuPoints         = "0,119 360,119"
        $this.SysCpuFillPoints     = "0,120 0,119 360,119 360,120"
        $this.SysKernelPoints      = "0,119 360,119"
        $this.SysKernelFillPoints  = "0,120 0,119 360,119 360,120"
        $this.SysCommitPoints      = "0,119 360,119"
        $this.SysCommitFillPoints  = "0,120 0,119 360,119 360,120"
        $this.SysRamPoints         = "0,119 360,119"
        $this.SysRamFillPoints     = "0,120 0,119 360,119 360,120"
        $this.SysIoPoints          = "0,119 360,119"
        $this.SysIoFillPoints      = "0,120 0,119 360,119 360,120"
        $this.SysIoWritePoints     = "0,119 360,119"
        $this.SysIoWriteFillPoints = "0,120 0,119 360,119 360,120"

        $this.CpuGaugeTotalHeight  = 0.0
        $this.CpuGaugeTotalTop     = 120.0
        $this.CpuGaugeKernelHeight = 0.0
        $this.CpuGaugeKernelTop    = 120.0
        $this.CommitGaugeHeight    = 0.0
        $this.CommitGaugeTop       = 120.0
        $this.RamGaugeHeight       = 0.0
        $this.RamGaugeTop          = 120.0
        $this.IoGaugeHeight        = 0.0
        $this.IoGaugeTop           = 120.0

        $this.CpuGaugeText    = "0.00%"
        $this.CommitGaugeText = "0.0 GB"
        $this.RamGaugeText    = "0.0 GB"
        $this.IoGaugeText     = "0 B"

        $this.HandlesFormatted            = "0"
        $this.ThreadsFormatted            = "0"
        $this.ProcessesFormatted          = "0"
        $this.ContextSwitchDeltaFormatted = "0"
        $this.InterruptDeltaFormatted     = "0"
        $this.SystemCallDeltaFormatted    = "0"
        $this.KernelCpuFormatted          = "0.00%"
        $this.UserCpuFormatted            = "0.00%"

        $this.CommitCurrentK                = "0"
        $this.CommitLimitK                  = "0"
        $this.CommitPeakK                   = "0"
        $this.CommitPeakLimitPct            = "0.00%"
        $this.CommitCurrentLimitPct         = "0.00%"
        $this.PhysTotalK                    = "0"
        $this.PhysAvailableK                = "0"
        $this.PhysInUseK                    = "0"
        $this.SystemCacheK                  = "0"
        $this.KernelPagedK                  = "0"
        $this.KernelNonpagedK               = "0"
        $this.KernelTotalK                  = "0"
        $this.PageFaultDeltaFormatted       = "0"
        $this.PageReadDeltaFormatted        = "0"
        $this.PageFileWriteDeltaFormatted   = "0"
        $this.MappedFileWriteDeltaFormatted = "0"

        $this.IoTotalRateFormatted    = "0 B/s"
        $this.IoReadDeltaFormatted    = "0 B"
        $this.IoWriteDeltaFormatted   = "0 B"
        $this.IoOtherDeltaFormatted   = "0 B"
        $this.IoPeakRateFormatted     = "0 B/s"
        $this.IoSessionTotalFormatted = "0.0 MB"

        for ($i = 0; $i -lt 30; $i++) {
            $this.CpuHistory.Enqueue(0.0)
            $this.CommitHistory.Enqueue(0.0)
            $this.RamHistory.Enqueue(0.0)
        }
        for ($i = 0; $i -lt 120; $i++) {
            $this.CpuHistory120.Enqueue(0.0)
            $this.KernelHistory120.Enqueue(0.0)
            $this.CommitHistory120.Enqueue(0.0)
            $this.RamHistory120.Enqueue(0.0)
            $this.IoTotalHistory120.Enqueue(0.0)
            $this.IoWriteHistory120.Enqueue(0.0)
        }
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        if ($this.Handlers.Count -eq 0) { return }
        $eventArgs = [System.ComponentModel.PropertyChangedEventArgs]::new($propertyName)
        for ($i = 0; $i -lt $this.Handlers.Count; $i++) {
            try { $this.Handlers[$i].Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] SetPerCpuMode([bool]$perCpu) {
        $this.ShowOneGraphPerCpu       = $perCpu
        $this.SingleCpuGraphVisibility = if ($perCpu) { "Collapsed" } else { "Visible" }
        $this.PerCpuGridVisibility     = if ($perCpu) { "Visible" }   else { "Collapsed" }
        if ($perCpu) {
            foreach ($cg in $this.CoreGraphs) {
                $cg.BuildCoreGeometry()
            }
        }
        $this.OnPropertyChanged('ShowOneGraphPerCpu')
        $this.OnPropertyChanged('SingleCpuGraphVisibility')
        $this.OnPropertyChanged('PerCpuGridVisibility')
    }

    hidden [string] FormatBytesCompact([double]$bytes) {
        if ($bytes -le 0.0) { return "0" }
        if ($bytes -ge 1073741824.0) { return "$([Math]::Round($bytes / 1073741824.0, 2)) GB" }
        if ($bytes -ge 1048576.0)    { return "$([Math]::Round($bytes / 1048576.0, 1)) MB" }
        if ($bytes -ge 1024.0)       { return "$([Math]::Round($bytes / 1024.0, 1)) KB" }
        return "$([Math]::Round($bytes, 0)) B"
    }

    hidden [string[]] BuildSparkline([double[]]$arr, [double]$width, [double]$height) {
        $lineSb = [System.Text.StringBuilder]::new(256)
        $fillSb = [System.Text.StringBuilder]::new(280)
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $wStr = $width.ToString("F1", $inv)
        $hStr = $height.ToString("F1", $inv)
        [void]$fillSb.Append("0,$hStr ")

        $maxIdx = [Math]::Max(1, $arr.Count - 1)
        for ($i = 0; $i -lt $arr.Count; $i++) {
            $x = [Math]::Round(($i / [double]$maxIdx) * $width, 1)
            $val = [Math]::Max(0.0, [Math]::Min(100.0, $arr[$i]))
            $y = [Math]::Round(($height - 1.0) - (($val / 100.0) * ($height - 13.0)), 1)
            $pt = "$($x.ToString('F1', $inv)),$($y.ToString('F1', $inv)) "
            [void]$lineSb.Append($pt)
            [void]$fillSb.Append($pt)
        }
        [void]$fillSb.Append("$wStr,$hStr")
        return @($lineSb.ToString().Trim(), $fillSb.ToString().Trim())
    }

    hidden [string[]] BuildLargeChart([double[]]$arr, [double]$maxScale, [double]$width, [double]$height) {
        $lineSb = [System.Text.StringBuilder]::new(1024)
        $fillSb = [System.Text.StringBuilder]::new(1060)
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $wStr = $width.ToString("F1", $inv)
        $hStr = $height.ToString("F1", $inv)
        [void]$fillSb.Append("0,$hStr ")

        $safeMax = if ($maxScale -gt 0.0) { $maxScale } else { 100.0 }
        $maxIdx  = [Math]::Max(1, $arr.Count - 1)
        for ($i = 0; $i -lt $arr.Count; $i++) {
            $x   = [Math]::Round(($i / [double]$maxIdx) * $width, 1)
            $val = [Math]::Max(0.0, [Math]::Min($safeMax, $arr[$i]))
            $y   = [Math]::Round(($height - 1.0) - (($val / $safeMax) * ($height - 4.0)), 1)
            $pt  = "$($x.ToString('F1', $inv)),$($y.ToString('F1', $inv)) "
            [void]$lineSb.Append($pt)
            [void]$fillSb.Append($pt)
        }
        [void]$fillSb.Append("$wStr,$hStr")
        return @($lineSb.ToString().Trim(), $fillSb.ToString().Trim())
    }

    [void] UpdateHardwareInfo([Object]$hw) {
        if (-not $hw) { return }
        if ($hw['machine']) { $this.HwMachine      = [string]$hw['machine'] }
        if ($hw['host'])    { $this.HwHost         = [string]$hw['host'] }
        if ($hw['os'])      { $this.HwOS           = [string]$hw['os'] }
        if ($hw['cpu'])     { $this.HwCpuName      = [string]$hw['cpu'] }
        if ($hw['arch'])    { $this.HwArch         = [string]$hw['arch'] }
        $cCount = if ($hw['cores'])   { [int]$hw['cores'] }   else { [Environment]::ProcessorCount }
        $lCount = if ($hw['logical']) { [int]$hw['logical'] } else { $cCount }
        $sCount = if ($hw['sockets']) { [int]$hw['sockets'] } else { 1 }
        $this.HwCoresText    = "$cCount physical / $lCount logical"
        $this.HwCoresCount   = "$cCount"
        $this.HwLogicalCount = "$lCount"
        $this.HwSocketsCount = "$sCount"
        if ($hw['boot'])    { $this.HwBootDrive      = [string]$hw['boot'] }
        if ($hw['fs'])      { $this.HwFileSystem     = [string]$hw['fs'] }
        if ($hw['type'])    { $this.HwDriveType      = [string]$hw['type'] }
        if ($hw['ro'])      { $this.HwReadOnly       = [string]$hw['ro'] }
        if ($null -ne $hw['capGB'])   { $this.HwCapacityGBText  = "$([double]$hw['capGB']) GB" }
        if ($null -ne $hw['availGB']) { $this.HwAvailableGBText = "$([double]$hw['availGB']) GB" }

        $this.OnPropertyChanged('HwMachine')
        $this.OnPropertyChanged('HwHost')
        $this.OnPropertyChanged('HwOS')
        $this.OnPropertyChanged('HwCpuName')
        $this.OnPropertyChanged('HwArch')
        $this.OnPropertyChanged('HwCoresText')
        $this.OnPropertyChanged('HwCoresCount')
        $this.OnPropertyChanged('HwLogicalCount')
        $this.OnPropertyChanged('HwSocketsCount')
        $this.OnPropertyChanged('HwBootDrive')
        $this.OnPropertyChanged('HwFileSystem')
        $this.OnPropertyChanged('HwDriveType')
        $this.OnPropertyChanged('HwReadOnly')
        $this.OnPropertyChanged('HwCapacityGBText')
        $this.OnPropertyChanged('HwAvailableGBText')
    }

    [void] UpdateSummary([double]$cpu, [long]$ramUsed, [long]$ramTotal, [int]$procs, [int]$threads, [int]$handles, [long]$commitUsed, [long]$commitLimit) {
        $this.CpuUsage            = $cpu
        $this.CpuSummaryFormatted = "$($cpu.ToString('F1'))%"
        $this.RamUsedMB           = $ramUsed
        $this.RamTotalMB          = $ramTotal
        $this.RamPct              = if ($ramTotal -gt 0) { [Math]::Round(($ramUsed / [double]$ramTotal) * 100.0, 1) } else { 0.0 }
        $this.RamPctFormatted     = "$($this.RamPct.ToString('F1'))%"
        $this.RamSummaryFormatted = "Physical Memory: $($this.RamUsedMB.ToString('N0')) / $($this.RamTotalMB.ToString('N0')) MB ($($this.RamPctFormatted))"

        $this.CommitUsedMB           = $commitUsed
        $this.CommitLimitMB          = $commitLimit
        $this.CommitPct              = if ($commitLimit -gt 0) { [Math]::Round(($commitUsed / [double]$commitLimit) * 100.0, 1) } else { 0.0 }
        $this.CommitSummaryFormatted = "$($this.CommitPct.ToString('F1'))%"

        $this.ProcessCount       = $procs
        $this.ThreadCount        = $threads
        $this.HandleCount        = $handles
        $this.ProcessesFormatted = $procs.ToString("N0")
        $this.ThreadsFormatted   = $threads.ToString("N0")
        $this.HandlesFormatted   = $handles.ToString("N0")

        $this.HwMemoryGBText      = "$([Math]::Round($ramTotal / 1024.0, 1).ToString('F1')) GB"
        $this.HwCommitLimitGBText = "$([Math]::Round($commitLimit / 1024.0, 1).ToString('F1')) GB"

        if ($this.CpuHistory.Count -ge 30)    { [void]$this.CpuHistory.Dequeue() }
        if ($this.CommitHistory.Count -ge 30) { [void]$this.CommitHistory.Dequeue() }
        if ($this.RamHistory.Count -ge 30)    { [void]$this.RamHistory.Dequeue() }

        $this.CpuHistory.Enqueue($cpu)
        $this.CommitHistory.Enqueue($this.CommitPct)
        $this.RamHistory.Enqueue($this.RamPct)

        $cpuSpark = $this.BuildSparkline($this.CpuHistory.ToArray(), 86.0, 26.0)
        $this.CpuPoints     = $cpuSpark[0]
        $this.CpuFillPoints = $cpuSpark[1]

        $comSpark = $this.BuildSparkline($this.CommitHistory.ToArray(), 90.0, 26.0)
        $this.CommitPoints     = $comSpark[0]
        $this.CommitFillPoints = $comSpark[1]

        $ramSpark = $this.BuildSparkline($this.RamHistory.ToArray(), 96.0, 26.0)
        $this.RamPoints     = $ramSpark[0]
        $this.RamFillPoints = $ramSpark[1]

        $this.OnPropertyChanged('CpuUsage')
        $this.OnPropertyChanged('CpuSummaryFormatted')
        $this.OnPropertyChanged('RamUsedMB')
        $this.OnPropertyChanged('RamTotalMB')
        $this.OnPropertyChanged('RamPctFormatted')
        $this.OnPropertyChanged('RamSummaryFormatted')
        $this.OnPropertyChanged('CommitSummaryFormatted')
        $this.OnPropertyChanged('ProcessCount')
        $this.OnPropertyChanged('ThreadCount')
        $this.OnPropertyChanged('HandleCount')
        $this.OnPropertyChanged('CpuPoints')
        $this.OnPropertyChanged('CpuFillPoints')
        $this.OnPropertyChanged('CommitPoints')
        $this.OnPropertyChanged('CommitFillPoints')
        $this.OnPropertyChanged('RamPoints')
        $this.OnPropertyChanged('RamFillPoints')
    }

    [void] UpdateExtendedTelemetry([Object]$sysArr, [Object]$coresArr) {
        if (-not $sysArr -or $sysArr.Count -lt 27) { return }

        $cpuTot      = [double]$sysArr[0]
        $kernCpu     = [double]$sysArr[8]
        $userCpu     = [Math]::Max(0.0, [Math]::Round($cpuTot - $kernCpu, 2))
        $commitCurKB = [long]$sysArr[9]
        $commitLimKB = [long]$sysArr[10]
        $commitPkKB  = [long]$sysArr[11]
        $physTotKB   = [long]$sysArr[12]
        $physAvailKB = [long]$sysArr[13]
        $sysCacheKB  = [long]$sysArr[14]
        $kernPagedKB = [long]$sysArr[15]
        $kernNonpKB  = [long]$sysArr[16]
        $pfDelta     = [long]$sysArr[17]
        $prDelta     = [long]$sysArr[18]
        $pfwDelta    = [long]$sysArr[19]
        $mfwDelta    = [long]$sysArr[20]
        $csDelta     = [long]$sysArr[21]
        $intrDelta   = [long]$sysArr[22]
        $scDelta     = [long]$sysArr[23]
        $ioReadD     = [long]$sysArr[24]
        $ioWriteD    = [long]$sysArr[25]
        $ioOtherD    = [long]$sysArr[26]

        $this.KernelCpuUsage = $kernCpu
        $physUsedKB  = [Math]::Max(0L, $physTotKB - $physAvailKB)
        $kernTotalKB = $kernPagedKB + $kernNonpKB
        $ioTotalD    = $ioReadD + $ioWriteD + $ioOtherD
        $ioWriteAllD = $ioWriteD + $ioOtherD
        $this.SessionIoBytesTotal += $ioTotalD

        # 1. Enqueue 120-Sample Circular Ring Buffers (< 6 KB Total RAM)
        if ($this.CpuHistory120.Count -ge 120)     { [void]$this.CpuHistory120.Dequeue() }
        if ($this.KernelHistory120.Count -ge 120)  { [void]$this.KernelHistory120.Dequeue() }
        if ($this.CommitHistory120.Count -ge 120)  { [void]$this.CommitHistory120.Dequeue() }
        if ($this.RamHistory120.Count -ge 120)     { [void]$this.RamHistory120.Dequeue() }
        if ($this.IoTotalHistory120.Count -ge 120) { [void]$this.IoTotalHistory120.Dequeue() }
        if ($this.IoWriteHistory120.Count -ge 120) { [void]$this.IoWriteHistory120.Dequeue() }

        $comPctExact = if ($commitLimKB -gt 0L) { ($commitCurKB / [double]$commitLimKB) * 100.0 } else { $this.CommitPct }
        $ramPctExact = if ($physTotKB -gt 0L)   { ($physUsedKB  / [double]$physTotKB)   * 100.0 } else { $this.RamPct }

        $this.CpuHistory120.Enqueue($cpuTot)
        $this.KernelHistory120.Enqueue($kernCpu)
        $this.CommitHistory120.Enqueue($comPctExact)
        $this.RamHistory120.Enqueue($ramPctExact)
        $this.IoTotalHistory120.Enqueue([double]$ioTotalD)
        $this.IoWriteHistory120.Enqueue([double]$ioWriteAllD)

        # 2. Enqueue Per-Core CPU Ring Buffers
        if ($coresArr -and $coresArr.Count -gt 0) {
            while ($this.CoreGraphs.Count -lt $coresArr.Count) {
                $newCoreVm = [CpuCoreGraphViewModel]::new($this.CoreGraphs.Count)
                $this.CoreGraphs.Add($newCoreVm)
            }
            $buildCoresNow = ($this.IsSysInfoOpen -and $this.ShowOneGraphPerCpu)
            for ($c = 0; $c -lt $coresArr.Count; $c++) {
                $pair = $coresArr[$c]
                if ($pair -and $pair.Count -ge 2) {
                    $this.CoreGraphs[$c].EnqueueSample([double]$pair[0], [double]$pair[1], $buildCoresNow)
                }
            }
        }

        # 3. Update Formatted Counter Strings & Gauges
        $this.CpuGaugeText    = "$($cpuTot.ToString('F2'))%"
        $this.CommitGaugeText = "$([Math]::Round($commitCurKB / 1048576.0, 1).ToString('F1')) GB"
        $this.RamGaugeText    = "$([Math]::Round($physUsedKB / 1048576.0, 1).ToString('F1')) GB"
        $this.IoGaugeText     = $this.FormatBytesCompact([double]$ioTotalD)

        $this.ContextSwitchDeltaFormatted = $csDelta.ToString("N0")
        $this.InterruptDeltaFormatted     = $intrDelta.ToString("N0")
        $this.SystemCallDeltaFormatted    = $scDelta.ToString("N0")
        $this.KernelCpuFormatted          = "$($kernCpu.ToString('F2'))%"
        $this.UserCpuFormatted            = "$($userCpu.ToString('F2'))%"

        $this.CommitCurrentK        = $commitCurKB.ToString("N0")
        $this.CommitLimitK          = $commitLimKB.ToString("N0")
        $this.CommitPeakK           = $commitPkKB.ToString("N0")
        $pkPct = if ($commitLimKB -gt 0L) { ($commitPkKB / [double]$commitLimKB) * 100.0 } else { 0.0 }
        $this.CommitPeakLimitPct    = "$($pkPct.ToString('F2'))%"
        $this.CommitCurrentLimitPct = "$($comPctExact.ToString('F2'))%"

        $this.PhysTotalK      = $physTotKB.ToString("N0")
        $this.PhysAvailableK  = $physAvailKB.ToString("N0")
        $this.PhysInUseK      = $physUsedKB.ToString("N0")
        $this.SystemCacheK    = $sysCacheKB.ToString("N0")
        $this.KernelPagedK    = $kernPagedKB.ToString("N0")
        $this.KernelNonpagedK = $kernNonpKB.ToString("N0")
        $this.KernelTotalK    = $kernTotalKB.ToString("N0")

        $this.PageFaultDeltaFormatted       = $pfDelta.ToString("N0")
        $this.PageReadDeltaFormatted        = $prDelta.ToString("N0")
        $this.PageFileWriteDeltaFormatted   = $pfwDelta.ToString("N0")
        $this.MappedFileWriteDeltaFormatted = $mfwDelta.ToString("N0")

        $this.IoTotalRateFormatted    = "$($this.FormatBytesCompact([double]$ioTotalD))/s"
        $this.IoReadDeltaFormatted    = $this.FormatBytesCompact([double]$ioReadD)
        $this.IoWriteDeltaFormatted   = $this.FormatBytesCompact([double]$ioWriteD)
        $this.IoOtherDeltaFormatted   = $this.FormatBytesCompact([double]$ioOtherD)
        $this.IoSessionTotalFormatted = $this.FormatBytesCompact([double]$this.SessionIoBytesTotal)

        # Only build the 120-point UI strings and notify System Info properties when the System Info window is open!
        if ($this.IsSysInfoOpen) {
            $this.RefreshSysInfoGraphs()
        }
    }

    [void] RefreshSysInfoGraphs() {
        $cpuArr   = $this.CpuHistory120.ToArray()
        $kernArr  = $this.KernelHistory120.ToArray()
        $comArr   = $this.CommitHistory120.ToArray()
        $ramArr   = $this.RamHistory120.ToArray()
        $ioTotArr = $this.IoTotalHistory120.ToArray()
        $ioWrtArr = $this.IoWriteHistory120.ToArray()

        $maxIo = 65536.0 # 64 KB/s minimum full-scale so idle noise stays flat at bottom
        for ($i = 0; $i -lt $ioTotArr.Count; $i++) {
            if ($ioTotArr[$i] -gt $maxIo) { $maxIo = $ioTotArr[$i] }
        }
        $this.PeakIoBytesDelta = $maxIo
        $this.IoPeakRateFormatted = "$($this.FormatBytesCompact($maxIo))/s"

        $cTot  = $this.BuildLargeChart($cpuArr,   100.0,  360.0, 120.0)
        $cKern = $this.BuildLargeChart($kernArr,  100.0,  360.0, 120.0)
        $cCom  = $this.BuildLargeChart($comArr,   100.0,  360.0, 120.0)
        $cRam  = $this.BuildLargeChart($ramArr,   100.0,  360.0, 120.0)
        $cIoT  = $this.BuildLargeChart($ioTotArr, $maxIo, 360.0, 120.0)
        $cIoW  = $this.BuildLargeChart($ioWrtArr, $maxIo, 360.0, 120.0)

        $this.SysCpuPoints         = $cTot[0]
        $this.SysCpuFillPoints     = $cTot[1]
        $this.SysKernelPoints      = $cKern[0]
        $this.SysKernelFillPoints  = $cKern[1]
        $this.SysCommitPoints      = $cCom[0]
        $this.SysCommitFillPoints  = $cCom[1]
        $this.SysRamPoints         = $cRam[0]
        $this.SysRamFillPoints     = $cRam[1]
        $this.SysIoPoints          = $cIoT[0]
        $this.SysIoFillPoints      = $cIoT[1]
        $this.SysIoWritePoints     = $cIoW[0]
        $this.SysIoWriteFillPoints = $cIoW[1]

        # Vertical Gauge Bar Heights (0..120 px)
        $lastCpu  = if ($cpuArr.Count -gt 0)   { $cpuArr[$cpuArr.Count - 1] }     else { 0.0 }
        $lastKern = if ($kernArr.Count -gt 0)  { $kernArr[$kernArr.Count - 1] }   else { 0.0 }
        $lastCom  = if ($comArr.Count -gt 0)   { $comArr[$comArr.Count - 1] }     else { 0.0 }
        $lastRam  = if ($ramArr.Count -gt 0)   { $ramArr[$ramArr.Count - 1] }     else { 0.0 }
        $lastIo   = if ($ioTotArr.Count -gt 0) { $ioTotArr[$ioTotArr.Count - 1] } else { 0.0 }

        $this.CpuGaugeTotalHeight  = [Math]::Round(([Math]::Min(100.0, $lastCpu) / 100.0) * 120.0, 1)
        $this.CpuGaugeTotalTop     = [Math]::Round(120.0 - $this.CpuGaugeTotalHeight, 1)
        $this.CpuGaugeKernelHeight = [Math]::Round(([Math]::Min($lastCpu, $lastKern) / 100.0) * 120.0, 1)
        $this.CpuGaugeKernelTop    = [Math]::Round(120.0 - $this.CpuGaugeKernelHeight, 1)

        $this.CommitGaugeHeight    = [Math]::Round(([Math]::Min(100.0, $lastCom) / 100.0) * 120.0, 1)
        $this.CommitGaugeTop       = [Math]::Round(120.0 - $this.CommitGaugeHeight, 1)

        $this.RamGaugeHeight       = [Math]::Round(([Math]::Min(100.0, $lastRam) / 100.0) * 120.0, 1)
        $this.RamGaugeTop          = [Math]::Round(120.0 - $this.RamGaugeHeight, 1)

        $this.IoGaugeHeight        = [Math]::Round(([Math]::Min($maxIo, $lastIo) / $maxIo) * 120.0, 1)
        $this.IoGaugeTop           = [Math]::Round(120.0 - $this.IoGaugeHeight, 1)

        foreach ($prop in @(
            'SysCpuPoints', 'SysCpuFillPoints', 'SysKernelPoints', 'SysKernelFillPoints',
            'SysCommitPoints', 'SysCommitFillPoints', 'SysRamPoints', 'SysRamFillPoints',
            'SysIoPoints', 'SysIoFillPoints', 'SysIoWritePoints', 'SysIoWriteFillPoints',
            'CpuGaugeTotalHeight', 'CpuGaugeTotalTop', 'CpuGaugeKernelHeight', 'CpuGaugeKernelTop',
            'CommitGaugeHeight', 'CommitGaugeTop', 'RamGaugeHeight', 'RamGaugeTop',
            'IoGaugeHeight', 'IoGaugeTop', 'CpuGaugeText', 'CommitGaugeText', 'RamGaugeText', 'IoGaugeText',
            'HandlesFormatted', 'ThreadsFormatted', 'ProcessesFormatted',
            'ContextSwitchDeltaFormatted', 'InterruptDeltaFormatted', 'SystemCallDeltaFormatted',
            'KernelCpuFormatted', 'UserCpuFormatted',
            'CommitCurrentK', 'CommitLimitK', 'CommitPeakK', 'CommitPeakLimitPct', 'CommitCurrentLimitPct',
            'PhysTotalK', 'PhysAvailableK', 'PhysInUseK', 'SystemCacheK',
            'KernelPagedK', 'KernelNonpagedK', 'KernelTotalK',
            'PageFaultDeltaFormatted', 'PageReadDeltaFormatted', 'PageFileWriteDeltaFormatted', 'MappedFileWriteDeltaFormatted',
            'IoTotalRateFormatted', 'IoReadDeltaFormatted', 'IoWriteDeltaFormatted', 'IoOtherDeltaFormatted',
            'IoPeakRateFormatted', 'IoSessionTotalFormatted', 'HwMemoryGBText', 'HwCommitLimitGBText'
        )) {
            $this.OnPropertyChanged($prop)
        }
    }
}

class InspectorModuleItem {
    [string]$Name
    [string]$Description
    [string]$CompanyName
    [string]$Version
    [string]$Size
    [string]$BaseAddress
    [string]$Path

    InspectorModuleItem([Object]$d) {
        $this.Name        = [string]$d['Name']
        $this.Description = [string]$d['Description']
        $this.CompanyName = [string]$d['CompanyName']
        $this.Version     = [string]$d['Version']
        $this.Size        = [string]$d['Size']
        $this.BaseAddress = [string]$d['BaseAddress']
        $this.Path        = [string]$d['Path']
    }
}

class InspectorHandleItem {
    [string]$Type
    [string]$Name
    [string]$Handle
    [string]$Access

    InspectorHandleItem([Object]$d) {
        $this.Type   = [string]$d['Type']
        $this.Name   = [string]$d['Name']
        $this.Handle = [string]$d['Handle']
        $this.Access = [string]$d['Access']
    }
}

class InspectorConnectionItem {
    [string]$Protocol
    [string]$LocalEndpoint
    [string]$RemoteEndpoint
    [string]$State

    InspectorConnectionItem([Object]$d) {
        $this.Protocol       = [string]$d['Protocol']
        $this.LocalEndpoint  = [string]$d['LocalEndpoint']
        $this.RemoteEndpoint = [string]$d['RemoteEndpoint']
        $this.State          = [string]$d['State']
    }
}

class InspectorServiceItem {
    [string]$Name
    [string]$DisplayName
    [string]$Status
    [string]$StartType
    [string]$User

    InspectorServiceItem([Object]$d) {
        $this.Name        = [string]$d['Name']
        $this.DisplayName = [string]$d['DisplayName']
        $this.Status      = [string]$d['Status']
        $this.StartType   = [string]$d['StartType']
        $this.User        = [string]$d['User']
    }
}

class InspectorEnvItem {
    [string]$Key
    [string]$Value

    InspectorEnvItem([Object]$d) {
        $this.Key   = [string]$d['Key']
        $this.Value = [string]$d['Value']
    }
}

class HostTabItemViewModel : System.ComponentModel.INotifyPropertyChanged {
    [string]$TabId
    [string]$ComputerName
    [string]$Title
    [string]$Transport
    [string]$BadgeBackground
    [bool]$IsLocal
    [bool]$IsActive
    [bool]$IsDarkTheme
    [string]$StatusDotFill
    [string]$TabBackground
    [string]$TabBorderBrush
    [string]$TitleForeground
    [string]$TitleFontWeight
    [string]$AccentVisibility
    [string]$CloseVisibility
    [string]$LatencyText

    # Per-Tab Isolated State Caches (Enables <5ms Instant Tab Switching & 0 KB/s Standby)
    [Object]$ProcessMap
    [Object]$ServicesMap
    [Object]$PidServicesMap
    [Object]$SummaryVm
    [hashtable]$TelemStats

    hidden [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]] $Handlers

    HostTabItemViewModel([string]$tabId, [string]$compName, [string]$title, [string]$transport, [bool]$isLocal, [Object]$summaryVm) {
        $this.Handlers        = [System.Collections.Generic.List[System.ComponentModel.PropertyChangedEventHandler]]::new()
        $this.TabId           = $tabId
        $this.ComputerName    = $compName
        $this.Title           = $title
        $this.Transport       = $transport
        $this.BadgeBackground = if ($isLocal) { "#0D9488" } else { "#0284C7" }
        $this.IsLocal         = $isLocal
        $this.IsActive        = $true
        $this.IsDarkTheme     = $false
        $this.StatusDotFill   = "#16A34A"
        $this.TabBackground   = "#FFFFFF"
        $this.TabBorderBrush  = "#0284C7"
        $this.TitleForeground = "#0F172A"
        $this.TitleFontWeight = "Bold"
        $this.AccentVisibility = "Visible"
        $this.CloseVisibility = "Collapsed"
        $this.LatencyText     = ""

        $this.ProcessMap     = [System.Collections.Generic.Dictionary[int, Object]]::new()
        $this.ServicesMap    = [System.Collections.Generic.Dictionary[string, Object]]::new()
        $this.PidServicesMap = [System.Collections.Generic.Dictionary[int, System.Collections.Generic.List[string]]]::new()
        $this.SummaryVm      = if ($summaryVm) { $summaryVm } else { [SystemSummaryViewModel]::new() }
        $this.TelemStats     = @{
            TotalWireBytes = 0L
            TotalRawBytes  = 0L
            TotalTicks     = 0L
            TotalRttMs     = 0L
        }
    }

    [void] add_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { $this.Handlers.Add($handler) }
    }

    [void] remove_PropertyChanged([System.ComponentModel.PropertyChangedEventHandler]$handler) {
        if ($handler) { [void]$this.Handlers.Remove($handler) }
    }

    [void] OnPropertyChanged([string]$propertyName) {
        if ($this.Handlers.Count -eq 0) { return }
        $eventArgs = [System.ComponentModel.PropertyChangedEventArgs]::new($propertyName)
        for ($i = 0; $i -lt $this.Handlers.Count; $i++) {
            try { $this.Handlers[$i].Invoke($this, $eventArgs) } catch {}
        }
    }

    [void] UpdateVisualState([bool]$active, [bool]$isDark, [bool]$canClose, [string]$connState, [bool]$isPaused, [int]$rttMs) {
        $this.IsActive    = $active
        $this.IsDarkTheme = $isDark
        $this.CloseVisibility  = if ($canClose) { "Visible" } else { "Collapsed" }
        $this.AccentVisibility = if ($active)   { "Visible" } else { "Collapsed" }
        $this.TitleFontWeight  = if ($active)   { "Bold" }    else { "SemiBold" }
        $this.BadgeBackground  = if ($this.IsLocal) { "#0D9488" } else { "#0284C7" }

        if ($active) {
            $this.LatencyText = "${rttMs}ms"
            if ($isPaused) {
                $this.StatusDotFill = "#F59E0B"
            } elseif ($connState -in @("Connected", "LocalMode")) {
                $this.StatusDotFill = "#16A34A"
            } else {
                $this.StatusDotFill = "#DC2626"
            }
            if ($isDark) {
                $this.TabBackground   = "#0F172A"
                $this.TabBorderBrush  = "#38BDF8"
                $this.TitleForeground = "#F8FAFC"
            } else {
                $this.TabBackground   = "#FFFFFF"
                $this.TabBorderBrush  = "#0284C7"
                $this.TitleForeground = "#0F172A"
            }
        } else {
            $this.LatencyText   = "Standby"
            $this.StatusDotFill = "#64748B"
            if ($isDark) {
                $this.TabBackground   = "#1E293B"
                $this.TabBorderBrush  = "#334155"
                $this.TitleForeground = "#94A3B8"
            } else {
                $this.TabBackground   = "#E2E8F0"
                $this.TabBorderBrush  = "#CBD5E1"
                $this.TitleForeground = "#475569"
            }
        }

        foreach ($p in @(
            'Title', 'Transport', 'BadgeBackground', 'IsActive', 'StatusDotFill',
            'TabBackground', 'TabBorderBrush', 'TitleForeground', 'TitleFontWeight',
            'AccentVisibility', 'CloseVisibility', 'LatencyText'
        )) {
            $this.OnPropertyChanged($p)
        }
    }
}
