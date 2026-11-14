# Requires -Version 5.1
# PSRPM Differential & State-Cached Telemetry Collector
# 100% Fileless In-Memory Reflection.Emit + NtQuerySystemInformation(5)
# Zero Disk Writes, Zero csc.exe, Zero Steady-State WMI

$script:PSRPMCollectorScriptBlock = {
    param(
        [bool]$ForceFullSync = $false,
        [bool]$EnableNetEtw = $false,
        [string]$NetEtwAction = ""
    )

    $swCol = [System.Diagnostics.Stopwatch]::StartNew()

    # 1. One-Time In-Memory Native P/Invoke & State Initialization (0 Disk Writes, 0 csc.exe)
    if (-not ('PSRPM.NativeCollectorV3' -as [type])) {
        $dynAsm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
            [System.Reflection.AssemblyName]::new("PSRPMNativeCollectorV3Asm"),
            [System.Reflection.Emit.AssemblyBuilderAccess]::Run
        )
        $dynMod = $dynAsm.DefineDynamicModule("PSRPMNativeCollectorV3Mod")
        $tb = $dynMod.DefineType("PSRPM.NativeCollectorV3", [System.Reflection.TypeAttributes]"Public,Abstract,Sealed")

        $dllImpCtor = [System.Runtime.InteropServices.DllImportAttribute].GetConstructor(@([string]))
        $fSetLast   = [System.Runtime.InteropServices.DllImportAttribute].GetField("SetLastError")
        $fCharSet   = [System.Runtime.InteropServices.DllImportAttribute].GetField("CharSet")
        $fCallConv  = [System.Runtime.InteropServices.DllImportAttribute].GetField("CallingConvention")
        $fEntryPt   = [System.Runtime.InteropServices.DllImportAttribute].GetField("EntryPoint")

        $addPInvoke = {
            param($name, $dll, $retType, [type[]]$paramTypes)
            $mb = $tb.DefineMethod(
                $name,
                [System.Reflection.MethodAttributes]"Public,Static,PinvokeImpl",
                $retType, $paramTypes
            )
            $mb.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
            $cab = [System.Reflection.Emit.CustomAttributeBuilder]::new(
                $dllImpCtor,
                @($dll),
                @($fSetLast, $fCharSet, $fCallConv, $fEntryPt),
                @([bool]$true, [System.Runtime.InteropServices.CharSet]::Unicode, [System.Runtime.InteropServices.CallingConvention]::Winapi, $name)
            )
            $mb.SetCustomAttribute($cab)
        }

        &$addPInvoke "NtQuerySystemInformation"   "ntdll.dll"    ([int])    @([int], [IntPtr], [int], [int].MakeByRefType())
        &$addPInvoke "NtQueryInformationProcess"  "ntdll.dll"    ([int])    @([IntPtr], [int], [IntPtr], [int], [int].MakeByRefType())
        &$addPInvoke "OpenProcess"                "kernel32.dll" ([IntPtr]) @([uint32], [int], [int])
        &$addPInvoke "CloseHandle"                "kernel32.dll" ([int])    @([IntPtr])
        &$addPInvoke "QueryFullProcessImageNameW" "kernel32.dll" ([int])    @([IntPtr], [uint32], [System.Text.StringBuilder], [int].MakeByRefType())
        &$addPInvoke "IsWow64Process"             "kernel32.dll" ([int])    @([IntPtr], [int].MakeByRefType())
        &$addPInvoke "OpenProcessToken"           "advapi32.dll" ([int])    @([IntPtr], [uint32], [IntPtr].MakeByRefType())
        &$addPInvoke "GetTokenInformation"        "advapi32.dll" ([int])    @([IntPtr], [int], [IntPtr], [int], [int].MakeByRefType())
        &$addPInvoke "GetPerformanceInfo"         "psapi.dll"    ([int])    @([IntPtr], [uint32])
        &$addPInvoke "GetIfTable2"                "iphlpapi.dll" ([int])    @([IntPtr].MakeByRefType())
        &$addPInvoke "FreeMibTable"               "iphlpapi.dll" ([void])   @([IntPtr])

        [void]$tb.CreateType()
    }

    # Native Service Control Manager Enumeration Type (EnumServicesStatusExW - Zero WMI)
    if (-not ('PSRPM.NativeServiceEnumV1' -as [type])) {
        $svcAsm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
            [System.Reflection.AssemblyName]::new("PSRPMNativeServiceEnumV1Asm"),
            [System.Reflection.Emit.AssemblyBuilderAccess]::Run
        )
        $svcMod = $svcAsm.DefineDynamicModule("PSRPMNativeServiceEnumV1Mod")
        $svcTb  = $svcMod.DefineType("PSRPM.NativeServiceEnumV1", [System.Reflection.TypeAttributes]"Public,Abstract,Sealed")

        $dllImpCtorS = [System.Runtime.InteropServices.DllImportAttribute].GetConstructor(@([string]))
        $fSetLastS   = [System.Runtime.InteropServices.DllImportAttribute].GetField("SetLastError")
        $fCharSetS   = [System.Runtime.InteropServices.DllImportAttribute].GetField("CharSet")
        $fCallConvS  = [System.Runtime.InteropServices.DllImportAttribute].GetField("CallingConvention")
        $fEntryPtS   = [System.Runtime.InteropServices.DllImportAttribute].GetField("EntryPoint")

        $addSvcPInvoke = {
            param($name, $dll, $retType, [type[]]$paramTypes)
            $mb = $svcTb.DefineMethod(
                $name,
                [System.Reflection.MethodAttributes]"Public,Static,PinvokeImpl",
                $retType, $paramTypes
            )
            $mb.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
            $cab = [System.Reflection.Emit.CustomAttributeBuilder]::new(
                $dllImpCtorS,
                @($dll),
                @($fSetLastS, $fCharSetS, $fCallConvS, $fEntryPtS),
                @([bool]$true, [System.Runtime.InteropServices.CharSet]::Unicode, [System.Runtime.InteropServices.CallingConvention]::Winapi, $name)
            )
            $mb.SetCustomAttribute($cab)
        }

        &$addSvcPInvoke "OpenSCManagerW"        "advapi32.dll" ([IntPtr]) @([IntPtr], [IntPtr], [uint32])
        &$addSvcPInvoke "EnumServicesStatusExW" "advapi32.dll" ([int])    @([IntPtr], [int], [uint32], [uint32], [IntPtr], [uint32], [uint32].MakeByRefType(), [uint32].MakeByRefType(), [uint32].MakeByRefType(), [IntPtr])
        &$addSvcPInvoke "CloseServiceHandle"    "advapi32.dll" ([int])    @([IntPtr])

        [void]$svcTb.CreateType()
    }

    if (-not $script:CollectorInitialized) {
        $script:SeqNumber      = 0
        $script:LastSnapTicks  = [DateTime]::UtcNow.Ticks
        $script:LastIdleCpu    = 0L
        $script:CoreCount      = [Environment]::ProcessorCount
        $script:Is64BitOS      = [Environment]::Is64BitOperatingSystem
        $script:PtrSize        = [IntPtr]::Size

        # System-Wide Kernel Delta Tracking (Zero Per-Tick Allocation)
        $script:LastSysIdleTicks   = 0L
        $script:LastSysKernTicks   = 0L
        $script:LastSysUserTicks   = 0L
        $script:LastSysInterrupts  = 0L
        $script:LastCoreIdle       = [long[]]::new($script:CoreCount)
        $script:LastCoreKern       = [long[]]::new($script:CoreCount)
        $script:LastCoreUser       = [long[]]::new($script:CoreCount)
        $script:LastPageFaults     = 0L
        $script:LastPageReads      = 0L
        $script:LastPageFileWrites = 0L
        $script:LastMappedWrites   = 0L
        $script:LastCtxSwitches    = 0L
        $script:LastSysCalls       = 0L
        $script:LastIoReadBytes    = 0L
        $script:LastIoWriteBytes   = 0L
        $script:LastIoOtherBytes   = 0L
        $script:LastIoReadOps      = 0L
        $script:LastIoWriteOps     = 0L
        $script:HasKernelBaseline  = $false

        # Network & Storage Hardware Throughput Tracking
        $script:LastNetRx          = 0L
        $script:LastNetTx          = 0L
        $script:LastNetTicks       = 0L

        # Opt-In Per-Process Kernel Network ETW Tracking (Lazy-Initialized on First Enable)
        $script:EtwNetInitialized  = $false
        $script:EtwNetActive       = $false
        $script:EtwNetCap          = 0 # 0=Off, 1=Active, 2=AutoPaused, 3=AccessDenied, 4=Error
        $script:EtwLastErr         = ""
        $script:EtwLastSentCap     = 0
        $script:EtwBreakerTripped  = $false
        $script:EtwHighRateTicks   = 0
        $script:EtwSessionHandle   = [uint64]0
        $script:EtwTraceHandle     = [uint64]::MaxValue
        $script:EtwPropsPtr        = [IntPtr]::Zero
        $script:EtwLogFilePtr      = [IntPtr]::Zero
        $script:EtwLogNamePtr      = [IntPtr]::Zero
        $script:EtwEventDelegate   = $null
        $script:EtwConsumerThread  = $null
        $script:EtwSessionName     = "PSRPM_NetMon_$PID"
        $script:EtwLastDrainTicks  = 0L
        $script:EtwDrainPids       = $null
        $script:EtwDrainRx         = $null
        $script:EtwDrainTx         = $null
        $script:EtwNetRates        = @{} # Key: int PID -> [long rxBps, long txBps]

        # One-Time Static System & Storage Metadata (Registry + DriveInfo, 0 WMI)
        $machineStr = "Windows PC"
        $osStr      = [Environment]::OSVersion.VersionString
        $cpuNameStr = "x64 Processor"
        $archStr    = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE } elseif ($script:Is64BitOS) { "x64" } else { "x86" }
        $bootDrive  = if ($env:SystemDrive) { "$($env:SystemDrive)\" } else { "C:\" }
        $fsName     = "NTFS"
        $drvType    = "Fixed"
        $drvRo      = "No"
        $capGB      = 0.0
        $availGB    = 0.0
        try {
            $bios = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction SilentlyContinue
            if ($bios -and $bios.SystemProductName) { $machineStr = [string]$bios.SystemProductName }
        } catch {}
        try {
            $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
            if ($cv -and $cv.ProductName) {
                $pName = [string]$cv.ProductName
                $buildNum = try { [int]$cv.CurrentBuildNumber } catch { 0 }
                if ($buildNum -ge 22000 -and $pName -match "Windows 10") {
                    $pName = $pName -replace "Windows 10", "Windows 11"
                }
                $dispVer = if ($cv.DisplayVersion) { ", $($cv.DisplayVersion)" } else { "" }
                $osStr = "${pName}${dispVer} (Build $($cv.CurrentBuildNumber))"
            }
        } catch {}
        try {
            $c0 = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue
            if ($c0 -and $c0.ProcessorNameString) { $cpuNameStr = ([string]$c0.ProcessorNameString).Trim() }
        } catch {}
        try {
            $di = [System.IO.DriveInfo]::new($bootDrive)
            if ($di.IsReady) {
                $fsName  = [string]$di.DriveFormat
                $drvType = [string]$di.DriveType
                $capGB   = [Math]::Round($di.TotalSize / 1GB, 1)
                $availGB = [Math]::Round($di.AvailableFreeSpace / 1GB, 1)
            }
        } catch {}

        $script:CachedHwInfo = @{
            machine = $machineStr
            host    = [string]$env:COMPUTERNAME
            os      = $osStr
            cpu     = $cpuNameStr
            arch    = $archStr
            cores   = $script:CoreCount
            logical = $script:CoreCount
            sockets = 1
            boot    = $bootDrive
            fs      = $fsName
            type    = $drvType
            ro      = $drvRo
            capGB   = $capGB
            availGB = $availGB
        }

        # Reusable Unmanaged Buffers (Zero Per-Tick Allocation Churn)
        $script:SysBufSize     = 524288 # 512 KB initial buffer for SystemProcessInformation
        $script:SysBufPtr      = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($script:SysBufSize)
        $script:SvcBufSize     = 262144 # 256 KB initial buffer for EnumServicesStatusExW
        $script:SvcBufPtr      = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($script:SvcBufSize)
        $script:ScratchBufPtr  = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(8192)
        $script:ExePathSb      = [System.Text.StringBuilder]::new(1024)

        # Pre-allocated JSON Serializer (Zero Per-Tick Allocation Churn)
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
        $script:Jss            = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
        $script:Jss.MaxJsonLength = 10485760

        # mscorlib GlobalMemoryStatusEx Reflection Binding (Fallback)
        $wnType = [int].Assembly.GetType("Microsoft.Win32.Win32Native")
        $script:GmsMethod      = $wnType.GetMethod("GlobalMemoryStatusEx", [System.Reflection.BindingFlags]"Public,NonPublic,Static")
        $msType                = $wnType.GetNestedType("MEMORYSTATUSEX", [System.Reflection.BindingFlags]"Public,NonPublic")
        $script:MemStatInst    = [Activator]::CreateInstance($msType, $true)
        $script:F_TotalPhys    = $msType.GetField("totalPhys", [System.Reflection.BindingFlags]"Public,NonPublic,Instance")
        $script:F_AvailPhys    = $msType.GetField("availPhys", [System.Reflection.BindingFlags]"Public,NonPublic,Instance")
        $script:F_TotalPage    = $msType.GetField("totalPageFile", [System.Reflection.BindingFlags]"Public,NonPublic,Instance")
        $script:F_AvailPage    = $msType.GetField("availPageFile", [System.Reflection.BindingFlags]"Public,NonPublic,Instance")

        # Persistent Session Caches
        $script:ProcCpuCache   = @{} # Key: "PID_CreateTime" -> long (UserTime + KernelTime in 100ns ticks)
        $script:ProcCycleCache = @{} # Key: "PID_CreateTime" -> long (CycleTime for sub-tick CPU activity)
        $script:ProcMetaCache  = @{} # Key: "PID_CreateTime" -> Hashtable static metadata
        $script:PendingMetaMap = @{} # Key: "PID_CreateTime" -> @{ sid = string; path = string } for time-budgeted deferred lookups
        $script:SentMetaKeys   = [System.Collections.Generic.HashSet[string]]::new()
        $script:LastDynState   = @{} # Key: "PID_CreateTime" -> [double cpu, long ws, long pb, int th, int hnd, int flags]
        $script:ActivePidToKey = @{} # Key: int PID -> "PID_CreateTime"
        $script:ServicePidSet  = [System.Collections.Generic.HashSet[int]]::new()
        $script:LastSvcState   = @{}
        $script:SvcStaticCache = @{} # Key: ServiceName -> @{ sm; u; dep; rev; dsc; bin } (cached 10 min)
        $script:LastSvcStaticRefresh = [DateTime]::MinValue
        $script:CachedServices = $null
        $script:FileMetaCache  = @{
            "n/a" = @{ d = ""; c = "" }
        }
        $script:SidCache       = @{
            "S-1-5-18" = "NT AUTHORITY\SYSTEM"
            "S-1-5-19" = "NT AUTHORITY\LOCAL SERVICE"
            "S-1-5-20" = "NT AUTHORITY\NETWORK SERVICE"
        }
        $script:PackagedExeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($pn in @(
            'msedgewebview2.exe', 'RuntimeBroker.exe', 'ApplicationFrameHost.exe',
            'SearchHost.exe', 'StartMenuExperienceHost.exe', 'ShellExperienceHost.exe',
            'Widgets.exe', 'WidgetService.exe', 'UserOOBEBroker.exe', 'ShellHost.exe',
            'SystemSettings.exe', 'TextInputHost.exe', 'LockApp.exe', 'SearchApp.exe'
        )) {
            [void]$script:PackagedExeSet.Add($pn)
        }
        $script:ServiceExeSet  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($sn in @(
            'services.exe', 'svchost.exe', 'WmiPrvSE.exe', 'spoolsv.exe', 'lsass.exe',
            'SearchIndexer.exe', 'MsMpEng.exe', 'NisSrv.exe', 'dasHost.exe', 'dllhost.exe'
        )) {
            [void]$script:ServiceExeSet.Add($sn)
        }

        $script:LastSvcRefresh = [DateTime]::MinValue
        $script:CollectorInitialized = $true
    }

    if ($ForceFullSync) {
        $script:SentMetaKeys.Clear()
        $script:LastDynState.Clear()
        $script:LastSvcState.Clear()
        $script:SvcStaticCache.Clear()
        $script:LastSvcStaticRefresh = [DateTime]::MinValue
        $script:LastSvcRefresh = [DateTime]::MinValue
    }

    # 1B. Lazy Opt-In Per-Process Network ETW Manager (0 overhead if never enabled)
    $ensureEtwConsumerType = {
        if (-not ('PSRPM.EtwNetConsumerV1' -as [type])) {
            $eAsm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
                [System.Reflection.AssemblyName]::new("PSRPMEtwNetConsumerV1Asm"),
                [System.Reflection.Emit.AssemblyBuilderAccess]::Run
            )
            $eMod = $eAsm.DefineDynamicModule("PSRPMEtwNetConsumerV1Mod")

            # Unmanaged Winapi callback delegate for ProcessTrace
            $delTb = $eMod.DefineType(
                "PSRPM.EtwEventRecordCallback",
                [System.Reflection.TypeAttributes]"Public,Sealed,AutoClass,AnsiClass",
                [System.MulticastDelegate]
            )
            $ufpCtor = [System.Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor([type[]]@([System.Runtime.InteropServices.CallingConvention]))
            $delTb.SetCustomAttribute([System.Reflection.Emit.CustomAttributeBuilder]::new($ufpCtor, @([System.Runtime.InteropServices.CallingConvention]::Winapi)))
            $delCtor = $delTb.DefineConstructor(
                [System.Reflection.MethodAttributes]"Public,HideBySig,SpecialName,RTSpecialName",
                [System.Reflection.CallingConventions]::Standard,
                [type[]]@([object], [IntPtr])
            )
            $delCtor.SetImplementationFlags([System.Reflection.MethodImplAttributes]"Runtime,Managed")
            $delInv = $delTb.DefineMethod(
                "Invoke",
                [System.Reflection.MethodAttributes]"Public,HideBySig,NewSlot,Virtual",
                [void],
                [type[]]@([IntPtr])
            )
            $delInv.SetImplementationFlags([System.Reflection.MethodImplAttributes]"Runtime,Managed")
            [void]$delTb.CreateType()

            $etwTb = $eMod.DefineType("PSRPM.EtwNetConsumerV1", [System.Reflection.TypeAttributes]"Public,Abstract,Sealed")
            $fSlotPids   = $etwTb.DefineField("SlotPids",          [int[]],  [System.Reflection.FieldAttributes]"Public,Static")
            $fSlotRx     = $etwTb.DefineField("SlotRx",            [long[]], [System.Reflection.FieldAttributes]"Public,Static")
            $fSlotTx     = $etwTb.DefineField("SlotTx",            [long[]], [System.Reflection.FieldAttributes]"Public,Static")
            $fSlotPids2  = $etwTb.DefineField("SlotPids2",         [int[]],  [System.Reflection.FieldAttributes]"Public,Static")
            $fSlotRx2    = $etwTb.DefineField("SlotRx2",           [long[]], [System.Reflection.FieldAttributes]"Public,Static")
            $fSlotTx2    = $etwTb.DefineField("SlotTx2",           [long[]], [System.Reflection.FieldAttributes]"Public,Static")
            $fSlotMask   = $etwTb.DefineField("SlotMask",          [int],    [System.Reflection.FieldAttributes]"Public,Static")
            $fActive     = $etwTb.DefineField("Active",            [int],    [System.Reflection.FieldAttributes]"Public,Static")
            $fActiveBank = $etwTb.DefineField("ActiveBank",        [int],    [System.Reflection.FieldAttributes]"Public,Static")
            $fInFlight0  = $etwTb.DefineField("InFlight0",         [int],    [System.Reflection.FieldAttributes]"Public,Static")
            $fInFlight1  = $etwTb.DefineField("InFlight1",         [int],    [System.Reflection.FieldAttributes]"Public,Static")
            $fTotalEv    = $etwTb.DefineField("TotalEvents",       [int],    [System.Reflection.FieldAttributes]"Public,Static")
            $fTraceHnd   = $etwTb.DefineField("ActiveTraceHandle", [uint64], [System.Reflection.FieldAttributes]"Public,Static")
            $fSessName   = $etwTb.DefineField("SessionName",       [string], [System.Reflection.FieldAttributes]"Public,Static")

            $dllCtor  = [System.Runtime.InteropServices.DllImportAttribute].GetConstructor([type[]]@([string]))
            $fLastErr = [System.Runtime.InteropServices.DllImportAttribute].GetField("SetLastError")
            $fCSet    = [System.Runtime.InteropServices.DllImportAttribute].GetField("CharSet")
            $fCConv   = [System.Runtime.InteropServices.DllImportAttribute].GetField("CallingConvention")
            $fEntry   = [System.Runtime.InteropServices.DllImportAttribute].GetField("EntryPoint")

            $addEtwPInvoke = {
                param($name, $retType, [type[]]$pTypes)
                $mb = $etwTb.DefineMethod($name, [System.Reflection.MethodAttributes]"Public,Static,PinvokeImpl", $retType, $pTypes)
                $mb.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
                $mb.SetCustomAttribute([System.Reflection.Emit.CustomAttributeBuilder]::new(
                    $dllCtor, @("advapi32.dll"),
                    @($fLastErr, $fCSet, $fCConv, $fEntry),
                    @([bool]$true, [System.Runtime.InteropServices.CharSet]::Unicode, [System.Runtime.InteropServices.CallingConvention]::Winapi, $name)
                ))
                return $mb
            }

            [void](&$addEtwPInvoke "StartTraceW"    ([uint32]) @([uint64].MakeByRefType(), [string], [IntPtr]))
            $mCtrlTrace  = &$addEtwPInvoke "ControlTraceW"  ([uint32]) @([uint64], [string], [IntPtr], [uint32])
            [void](&$addEtwPInvoke "EnableTraceEx2" ([uint32]) @([uint64], [Guid].MakeByRefType(), [uint32], [byte], [uint64], [uint64], [uint32], [IntPtr]))
            [void](&$addEtwPInvoke "OpenTraceW"     ([uint64]) @([IntPtr]))
            $mProcTrace  = &$addEtwPInvoke "ProcessTrace" ([uint32]) @([uint64[]], [uint32], [IntPtr], [IntPtr])
            $mCloseTrace = &$addEtwPInvoke "CloseTrace"     ([uint32]) @([uint64])

            # Pure-IL OnProcessExit(object sender, EventArgs e) so AppDomain.ProcessExit runs with zero PowerShell runspace
            $mProcExit = $etwTb.DefineMethod("OnProcessExit", [System.Reflection.MethodAttributes]"Public,Static", [void], [type[]]@([object], [EventArgs]))
            $ilPe = $mProcExit.GetILGenerator()
            [void]$ilPe.DeclareLocal([IntPtr]) # 0: ptr
            [void]$ilPe.DeclareLocal([int])    # 1: zi
            $lblPeRet  = $ilPe.DefineLabel()
            $lblPeZLp  = $ilPe.DefineLabel()
            $lblPeZDn  = $ilPe.DefineLabel()
            $lblPeNoTh = $ilPe.DefineLabel()

            $mAllocH   = [System.Runtime.InteropServices.Marshal].GetMethod("AllocHGlobal",  [type[]]@([int]))
            $mFreeH    = [System.Runtime.InteropServices.Marshal].GetMethod("FreeHGlobal",   [type[]]@([IntPtr]))
            $mWriteI32 = [System.Runtime.InteropServices.Marshal].GetMethod("WriteInt32",    [type[]]@([IntPtr], [int], [int]))
            $mWriteI64 = [System.Runtime.InteropServices.Marshal].GetMethod("WriteInt64",    [type[]]@([IntPtr], [int], [long]))

            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fActive)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Brfalse, $lblPeRet)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Stsfld, $fActive)

            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fTraceHnd)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, 0L)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblPeNoTh)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fTraceHnd)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, -1L)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblPeNoTh)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fTraceHnd)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Call, $mCloseTrace)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Pop)

            $ilPe.MarkLabel($lblPeNoTh)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSessName)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Brfalse, $lblPeRet)

            $peBase  = 120
            $peTotal = $peBase + 512
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4, $peTotal)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Call, $mAllocH)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Stloc_0)

            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Stloc_1)
            $ilPe.MarkLabel($lblPeZLp)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4, $peTotal)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Bge, $lblPeZDn)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, 0L)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Call, $mWriteI64)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_8)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Add)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Stloc_1)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Br, $lblPeZLp)

            $ilPe.MarkLabel($lblPeZDn)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4, $peTotal)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Call, $mWriteI32)

            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]44)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4, 0x00020000)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Call, $mWriteI32)

            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4, 108 + [IntPtr]::Size)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4, $peBase)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Call, $mWriteI32)

            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, 0L)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSessName)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Call, $mCtrlTrace)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Pop)

            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Call, $mFreeH)

            $ilPe.MarkLabel($lblPeRet)
            $ilPe.Emit([System.Reflection.Emit.OpCodes]::Ret)

            # Pure-IL TraceThreadMain() for background OS thread (Zero PowerShell runspace overhead)
            $fThreadAlive = $etwTb.DefineField("TraceThreadRunning", [int], [System.Reflection.FieldAttributes]"Public,Static")
            $fLastTraceSt = $etwTb.DefineField("LastTraceStatus",    [int], [System.Reflection.FieldAttributes]"Public,Static")
            $mThreadMain  = $etwTb.DefineMethod("TraceThreadMain", [System.Reflection.MethodAttributes]"Public,Static", [void], [type[]]@())
            $ilTm = $mThreadMain.GetILGenerator()
            $fZeroPtr = [IntPtr].GetField("Zero")
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Stsfld, $fThreadAlive)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Stsfld, $fLastTraceSt)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Newarr, [uint64])
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Dup)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fTraceHnd)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Stelem_I8)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fZeroPtr)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fZeroPtr)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Call, $mProcTrace)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Stsfld, $fLastTraceSt)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Stsfld, $fThreadAlive)
            $ilTm.Emit([System.Reflection.Emit.OpCodes]::Ret)

            # Pure-IL ClearSlots() - clears both Bank 0 and Bank 1 safely
            $mClr = $etwTb.DefineMethod("ClearSlots", [System.Reflection.MethodAttributes]"Public,Static", [void], [type[]]@())
            $ilClr = $mClr.GetILGenerator()
            $mArrClr = [Array].GetMethod("Clear", [type[]]@([Array], [int], [int]))
            foreach ($fld in @($fSlotPids, $fSlotRx, $fSlotTx, $fSlotPids2, $fSlotRx2, $fSlotTx2)) {
                $lblSkipClr = $ilClr.DefineLabel()
                $ilClr.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fld)
                $ilClr.Emit([System.Reflection.Emit.OpCodes]::Brfalse, $lblSkipClr)
                $ilClr.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fld)
                $ilClr.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
                $ilClr.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fld)
                $ilClr.Emit([System.Reflection.Emit.OpCodes]::Ldlen)
                $ilClr.Emit([System.Reflection.Emit.OpCodes]::Conv_I4)
                $ilClr.Emit([System.Reflection.Emit.OpCodes]::Call, $mArrClr)
                $ilClr.MarkLabel($lblSkipClr)
            }
            $ilClr.Emit([System.Reflection.Emit.OpCodes]::Ret)

            # Pure-IL OnEventRecord(IntPtr pRec)
            $mOnEv = $etwTb.DefineMethod("OnEventRecord", [System.Reflection.MethodAttributes]"Public,Static", [void], [type[]]@([IntPtr]))
            $il = $mOnEv.GetILGenerator()
            [void]$il.DeclareLocal([int])    # 0: opcode
            [void]$il.DeclareLocal([int])    # 1: task
            [void]$il.DeclareLocal([int])    # 2: dir (1=Tx, 2=Rx)
            [void]$il.DeclareLocal([IntPtr]) # 3: userData
            [void]$il.DeclareLocal([int])    # 4: pid
            [void]$il.DeclareLocal([long])   # 5: size
            [void]$il.DeclareLocal([int])    # 6: idx
            [void]$il.DeclareLocal([int])    # 7: probe
            [void]$il.DeclareLocal([int])    # 8: curPid
            [void]$il.DeclareLocal([int])    # 9: curBank
            [void]$il.DeclareLocal([int[]])  # 10: pArr
            [void]$il.DeclareLocal([long[]]) # 11: rArr
            [void]$il.DeclareLocal([long[]]) # 12: tArr

            $mPtrEq    = [IntPtr].GetMethod("op_Equality", [type[]]@([IntPtr], [IntPtr]))
            $mReadByte = [System.Runtime.InteropServices.Marshal].GetMethod("ReadByte",   [type[]]@([IntPtr], [int]))
            $mReadI16  = [System.Runtime.InteropServices.Marshal].GetMethod("ReadInt16",  [type[]]@([IntPtr], [int]))
            $mReadI32  = [System.Runtime.InteropServices.Marshal].GetMethod("ReadInt32",  [type[]]@([IntPtr], [int]))
            $mReadI64  = [System.Runtime.InteropServices.Marshal].GetMethod("ReadInt64",  [type[]]@([IntPtr], [int]))
            $mReadPtr  = [System.Runtime.InteropServices.Marshal].GetMethod("ReadIntPtr", [type[]]@([IntPtr], [int]))
            $mIncInt   = [System.Threading.Interlocked].GetMethod("Increment",       [type[]]@([int].MakeByRefType()))
            $mDecInt   = [System.Threading.Interlocked].GetMethod("Decrement",       [type[]]@([int].MakeByRefType()))
            $mCexInt   = [System.Threading.Interlocked].GetMethod("CompareExchange", [type[]]@([int].MakeByRefType(), [int], [int]))
            $mAddLong  = [System.Threading.Interlocked].GetMethod("Add",             [type[]]@([long].MakeByRefType(), [long]))
            $mExchInt  = [System.Threading.Interlocked].GetMethod("Exchange",        [type[]]@([int].MakeByRefType(), [int]))
            $mSpinWait = [System.Threading.Thread].GetMethod("SpinWait",             [type[]]@([int]))

            $lblRet        = $il.DefineLabel()
            $lblExitBank   = $il.DefineLabel()
            $lblDec1       = $il.DefineLabel()
            $lblTx         = $il.DefineLabel()
            $lblRx         = $il.DefineLabel()
            $lblCheckTask  = $il.DefineLabel()
            $lblCheckUdp   = $il.DefineLabel()
            $lblCheckLen   = $il.DefineLabel()
            $lblPickBank   = $il.DefineLabel()
            $lblTryB1      = $il.DefineLabel()
            $lblUseB0      = $il.DefineLabel()
            $lblUseB1      = $il.DefineLabel()
            $lblStartProbe = $il.DefineLabel()
            $lblLoop       = $il.DefineLabel()
            $lblNextProbe  = $il.DefineLabel()
            $lblFound      = $il.DefineLabel()
            $lblAddTx      = $il.DefineLabel()

            $tcpGuidBytes = ([Guid]"9a280ac0-c8e0-11d1-84e2-00c04fb998a2").ToByteArray()
            $udpGuidBytes = ([Guid]"bf3a50c5-a9c9-4988-a005-2df0b7c80f80").ToByteArray()
            $tcpLo = [BitConverter]::ToInt64($tcpGuidBytes, 0)
            $tcpHi = [BitConverter]::ToInt64($tcpGuidBytes, 8)
            $udpLo = [BitConverter]::ToInt64($udpGuidBytes, 0)
            $udpHi = [BitConverter]::ToInt64($udpGuidBytes, 8)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fActive)
            $il.Emit([System.Reflection.Emit.OpCodes]::Brfalse, $lblRet)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fZeroPtr)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mPtrEq)
            $il.Emit([System.Reflection.Emit.OpCodes]::Brtrue, $lblRet)

            # Count every ETW record reaching OnEventRecord so connect/disconnect storms still trip the circuit breaker
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fTotalEv)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mIncInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Pop)

            # Match classic MOF + Kernel-Network opcodes:
            # TX = 10 (TCP/UDP v4), 26 (TCP/UDP v6), 42 (KernelNet UDP v4), 58 (KernelNet UDP v6)
            # RX = 11 (TCP/UDP v4), 27 (TCP/UDP v6), 43 (KernelNet UDP v4), 59 (KernelNet UDP v6)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]45)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mReadByte)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc_0)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]10)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblTx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]26)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblTx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]42)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblTx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]58)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblTx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]11)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblRx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]27)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblRx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]43)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblRx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]59)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblRx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Br, $lblRet)

            $il.MarkLabel($lblTx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc_2)
            $il.Emit([System.Reflection.Emit.OpCodes]::Br, $lblCheckTask)

            $il.MarkLabel($lblRx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_2)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc_2)

            # Accept Microsoft-Windows-Kernel-Network tasks (10=TCP, 11=UDP) OR Task==0 for classic TcpIpGuid/UdpIpGuid MOF events
            $il.MarkLabel($lblCheckTask)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]46)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mReadI16)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc_1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]10)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblCheckLen)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]11)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblCheckLen)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Brtrue, $lblRet)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]24)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mReadI64)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, $tcpLo)
            $il.Emit([System.Reflection.Emit.OpCodes]::Bne_Un, $lblCheckUdp)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]32)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mReadI64)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, $tcpHi)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblCheckLen)
            $il.Emit([System.Reflection.Emit.OpCodes]::Br, $lblRet)

            $il.MarkLabel($lblCheckUdp)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]24)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mReadI64)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, $udpLo)
            $il.Emit([System.Reflection.Emit.OpCodes]::Bne_Un, $lblRet)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]32)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mReadI64)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, $udpHi)
            $il.Emit([System.Reflection.Emit.OpCodes]::Bne_Un, $lblRet)

            $il.MarkLabel($lblCheckLen)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]86)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mReadI16)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_8)
            $il.Emit([System.Reflection.Emit.OpCodes]::Blt, $lblRet)

            $offUd = 88 + [IntPtr]::Size
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]$offUd)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mReadPtr)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc_3)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_3)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fZeroPtr)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mPtrEq)
            $il.Emit([System.Reflection.Emit.OpCodes]::Brtrue, $lblRet)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_3)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mReadI32)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 4)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 4)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ble, $lblRet)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_3)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_4)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mReadI32)
            $il.Emit([System.Reflection.Emit.OpCodes]::Conv_I8)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, 0xFFFFFFFFL)
            $il.Emit([System.Reflection.Emit.OpCodes]::And)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 5)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 5)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, 0L)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ble, $lblRet)

            # Lock-free InFlight guard on double-buffered banks so DrainAndReset reclaims dead PIDs safely every tick
            $il.MarkLabel($lblPickBank)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fActiveBank)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mCexInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 9)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 9)
            $il.Emit([System.Reflection.Emit.OpCodes]::Brtrue, $lblTryB1)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fInFlight0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mIncInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Pop)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fActiveBank)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mCexInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Brfalse, $lblUseB0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fInFlight0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mDecInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Pop)
            $il.Emit([System.Reflection.Emit.OpCodes]::Br, $lblPickBank)

            $il.MarkLabel($lblUseB0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotPids)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 10)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotRx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 11)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotTx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 12)
            $il.Emit([System.Reflection.Emit.OpCodes]::Br, $lblStartProbe)

            $il.MarkLabel($lblTryB1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fInFlight1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mIncInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Pop)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fActiveBank)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mCexInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Brtrue, $lblUseB1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fInFlight1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mDecInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Pop)
            $il.Emit([System.Reflection.Emit.OpCodes]::Br, $lblPickBank)

            $il.MarkLabel($lblUseB1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotPids2)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 10)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotRx2)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 11)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotTx2)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 12)

            $il.MarkLabel($lblStartProbe)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 7)

            $il.MarkLabel($lblLoop)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 7)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]64)
            $il.Emit([System.Reflection.Emit.OpCodes]::Bge, $lblExitBank)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 4)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4, 0x45D9F3B)
            $il.Emit([System.Reflection.Emit.OpCodes]::Mul)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 7)
            $il.Emit([System.Reflection.Emit.OpCodes]::Add)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotMask)
            $il.Emit([System.Reflection.Emit.OpCodes]::And)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 6)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 10)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 6)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldelema, [int])
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mCexInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 8)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 8)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 4)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblFound)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 8)
            $il.Emit([System.Reflection.Emit.OpCodes]::Brtrue, $lblNextProbe)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 10)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 6)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldelema, [int])
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 4)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mCexInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 8)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 8)
            $il.Emit([System.Reflection.Emit.OpCodes]::Brfalse, $lblFound)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 8)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 4)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblFound)

            $il.MarkLabel($lblNextProbe)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 7)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Add)
            $il.Emit([System.Reflection.Emit.OpCodes]::Stloc, 7)
            $il.Emit([System.Reflection.Emit.OpCodes]::Br, $lblLoop)

            $il.MarkLabel($lblFound)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc_2)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Beq, $lblAddTx)

            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 11)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 6)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldelema, [long])
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 5)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mAddLong)
            $il.Emit([System.Reflection.Emit.OpCodes]::Pop)
            $il.Emit([System.Reflection.Emit.OpCodes]::Br, $lblExitBank)

            $il.MarkLabel($lblAddTx)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 12)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 6)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldelema, [long])
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 5)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mAddLong)
            $il.Emit([System.Reflection.Emit.OpCodes]::Pop)

            $il.MarkLabel($lblExitBank)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 9)
            $il.Emit([System.Reflection.Emit.OpCodes]::Brtrue, $lblDec1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fInFlight0)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mDecInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Pop)
            $il.Emit([System.Reflection.Emit.OpCodes]::Br, $lblRet)

            $il.MarkLabel($lblDec1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fInFlight1)
            $il.Emit([System.Reflection.Emit.OpCodes]::Call, $mDecInt)
            $il.Emit([System.Reflection.Emit.OpCodes]::Pop)

            $il.MarkLabel($lblRet)
            $il.Emit([System.Reflection.Emit.OpCodes]::Ret)

            # Pure-IL DrainAndReset(int[] outPids, long[] outRx, long[] outTx, out int totalEvents) -> int count
            $mDrain = $etwTb.DefineMethod("DrainAndReset", [System.Reflection.MethodAttributes]"Public,Static", [int], [type[]]@([int[]], [long[]], [long[]], [int].MakeByRefType()))
            $ilD = $mDrain.GetILGenerator()
            [void]$ilD.DeclareLocal([int])    # 0: count
            [void]$ilD.DeclareLocal([int])    # 1: i
            [void]$ilD.DeclareLocal([int])    # 2: len
            [void]$ilD.DeclareLocal([int])    # 3: pid
            [void]$ilD.DeclareLocal([long])   # 4: rx
            [void]$ilD.DeclareLocal([long])   # 5: tx
            [void]$ilD.DeclareLocal([int])    # 6: prevBank
            [void]$ilD.DeclareLocal([int[]])  # 7: pArr
            [void]$ilD.DeclareLocal([long[]]) # 8: rArr
            [void]$ilD.DeclareLocal([long[]]) # 9: tArr

            $lblDWait0 = $ilD.DefineLabel()
            $lblDUse0  = $ilD.DefineLabel()
            $lblDWait1 = $ilD.DefineLabel()
            $lblDUse1  = $ilD.DefineLabel()
            $lblDScan  = $ilD.DefineLabel()
            $lblDLoop  = $ilD.DefineLabel()
            $lblDNext  = $ilD.DefineLabel()
            $lblDDone  = $ilD.DefineLabel()

            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldarg_3)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fTotalEv)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Call, $mExchInt)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stind_I4)

            # Swap ActiveBank atomically, drain the quiesced previous bank, and reclaim its slots
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fActiveBank)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Xor)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc, 6)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fActiveBank)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 6)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Call, $mExchInt)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc, 6)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 6)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Brtrue, $lblDWait1)

            $ilD.MarkLabel($lblDWait0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fInFlight0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Call, $mCexInt)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ble, $lblDUse0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Call, $mSpinWait)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Br, $lblDWait0)

            $ilD.MarkLabel($lblDUse0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotPids)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc, 7)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotRx)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc, 8)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotTx)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc, 9)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Br, $lblDScan)

            $ilD.MarkLabel($lblDWait1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldsflda, $fInFlight1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Call, $mCexInt)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ble, $lblDUse1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Call, $mSpinWait)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Br, $lblDWait1)

            $ilD.MarkLabel($lblDUse1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotPids2)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc, 7)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotRx2)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc, 8)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldsfld, $fSlotTx2)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc, 9)

            $ilD.MarkLabel($lblDScan)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 7)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldlen)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Conv_I4)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc_2)

            $ilD.MarkLabel($lblDLoop)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_2)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Bge, $lblDDone)

            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 7)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldelem_I4)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc_3)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_3)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ble, $lblDNext)

            # Quiesced bank: read & zero Rx/Tx and clear pArr[i]=0 so dead PIDs never accumulate
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 8)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldelem_I8)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc, 4)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 8)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, 0L)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stelem_I8)

            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 9)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldelem_I8)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc, 5)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 9)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, 0L)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stelem_I8)

            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 7)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stelem_I4)

            $lblDEmit = $ilD.DefineLabel()
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 4)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, 0L)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Bgt, $lblDEmit)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 5)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I8, 0L)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ble, $lblDNext)

            $ilD.MarkLabel($lblDEmit)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldlen)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Conv_I4)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Bge, $lblDDone)

            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldarg_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_3)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stelem_I4)

            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldarg_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 4)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stelem_I8)

            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldarg_2)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc, 5)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stelem_I8)

            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Add)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc_0)

            $ilD.MarkLabel($lblDNext)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldc_I4_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Add)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Stloc_1)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Br, $lblDLoop)

            $ilD.MarkLabel($lblDDone)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ldloc_0)
            $ilD.Emit([System.Reflection.Emit.OpCodes]::Ret)

            [void]$etwTb.CreateType()
        }

        if ($null -eq [PSRPM.EtwNetConsumerV1]::SlotPids) {
            [PSRPM.EtwNetConsumerV1]::SlotPids  = [int[]]::new(4096)
            [PSRPM.EtwNetConsumerV1]::SlotRx    = [long[]]::new(4096)
            [PSRPM.EtwNetConsumerV1]::SlotTx    = [long[]]::new(4096)
            [PSRPM.EtwNetConsumerV1]::SlotPids2 = [int[]]::new(4096)
            [PSRPM.EtwNetConsumerV1]::SlotRx2   = [long[]]::new(4096)
            [PSRPM.EtwNetConsumerV1]::SlotTx2   = [long[]]::new(4096)
            [PSRPM.EtwNetConsumerV1]::SlotMask  = 4095
            [PSRPM.EtwNetConsumerV1]::Active    = 0
            [PSRPM.EtwNetConsumerV1]::ActiveBank = 0
            [PSRPM.EtwNetConsumerV1]::InFlight0  = 0
            [PSRPM.EtwNetConsumerV1]::InFlight1  = 0
            [PSRPM.EtwNetConsumerV1]::TotalEvents = 0
            [PSRPM.EtwNetConsumerV1]::ActiveTraceHandle = [uint64]::MaxValue
        }
        if (-not $script:EtwDrainPids) {
            $script:EtwDrainPids = [int[]]::new(4096)
            $script:EtwDrainRx   = [long[]]::new(4096)
            $script:EtwDrainTx   = [long[]]::new(4096)
        }
        $script:EtwNetInitialized = $true
    }

    $stopNetEtw = {
        if (-not ('PSRPM.EtwNetConsumerV1' -as [type])) {
            $script:EtwNetActive = $false
            if ($script:EtwNetCap -eq 1) { $script:EtwNetCap = 0 }
            $script:EtwNetRates.Clear()
            return
        }
        [PSRPM.EtwNetConsumerV1]::Active = 0

        if ($script:EtwTraceHandle -ne [uint64]::MaxValue -and $script:EtwTraceHandle -ne [uint64]0) {
            try { [void][PSRPM.EtwNetConsumerV1]::CloseTrace($script:EtwTraceHandle) } catch {}
            $script:EtwTraceHandle = [uint64]::MaxValue
            [PSRPM.EtwNetConsumerV1]::ActiveTraceHandle = [uint64]::MaxValue
        }

        # Stop kernel session by handle and/or session name (EVENT_TRACE_CONTROL_STOP = 1)
        $propBase  = 120
        $propTotal = $propBase + 512
        if ($script:EtwPropsPtr -eq [IntPtr]::Zero) {
            $script:EtwPropsPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($propTotal)
        }
        for ($zi = 0; $zi -lt $propTotal; $zi += 8) {
            [System.Runtime.InteropServices.Marshal]::WriteInt64($script:EtwPropsPtr, $zi, 0L)
        }
        [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 0, $propTotal)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 44, 0x00020000) # WNODE_FLAG_TRACED_GUID
        [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 108 + [IntPtr]::Size, $propBase)

        if ($script:EtwSessionHandle -ne [uint64]0) {
            try { [void][PSRPM.EtwNetConsumerV1]::ControlTraceW($script:EtwSessionHandle, $null, $script:EtwPropsPtr, [uint32]1) } catch {}
            $script:EtwSessionHandle = [uint64]0
        }
        try { [void][PSRPM.EtwNetConsumerV1]::ControlTraceW([uint64]0, $script:EtwSessionName, $script:EtwPropsPtr, [uint32]1) } catch {}

        if ($script:EtwConsumerThread) {
            try { [void]$script:EtwConsumerThread.Join(350) } catch {}
            $script:EtwConsumerThread = $null
        }
        if ($script:EtwLogFilePtr -ne [IntPtr]::Zero) {
            try { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($script:EtwLogFilePtr) } catch {}
            $script:EtwLogFilePtr = [IntPtr]::Zero
        }
        if ($script:EtwLogNamePtr -ne [IntPtr]::Zero) {
            try { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($script:EtwLogNamePtr) } catch {}
            $script:EtwLogNamePtr = [IntPtr]::Zero
        }
        if ($script:EtwPropsPtr -ne [IntPtr]::Zero) {
            try { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($script:EtwPropsPtr) } catch {}
            $script:EtwPropsPtr = [IntPtr]::Zero
        }

        [PSRPM.EtwNetConsumerV1]::ClearSlots()
        [PSRPM.EtwNetConsumerV1]::TotalEvents = 0
        $script:EtwNetRates.Clear()
        $script:EtwNetActive = $false
        $script:EtwHighRateTicks = 0
        if ($script:EtwNetCap -eq 1) { $script:EtwNetCap = 0 }
    }

    $startNetEtw = {
        &$ensureEtwConsumerType
        [PSRPM.EtwNetConsumerV1]::SessionName = $script:EtwSessionName
        if (-not $script:EtwExitHooked) {
            $script:EtwExitHooked = $true
            try {
                $exitDel = [Delegate]::CreateDelegate([EventHandler], ([PSRPM.EtwNetConsumerV1]).GetMethod("OnProcessExit"))
                [AppDomain]::CurrentDomain.add_ProcessExit($exitDel)
            } catch {}
        }

        if ($script:EtwNetActive) { return }
        $is64 = ([IntPtr]::Size -eq 8)
        $script:EtwLastErr = ""

        # Clean up any orphaned session with our PID name first
        $propBase  = 120
        $propTotal = $propBase + 512
        if ($script:EtwPropsPtr -eq [IntPtr]::Zero) {
            $script:EtwPropsPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($propTotal)
        }
        $sessionGuidBytes = ([Guid]::NewGuid()).ToByteArray()

        $initProps = {
            param([int]$logMode, [int]$enFlags)
            for ($zi = 0; $zi -lt $propTotal; $zi += 8) {
                [System.Runtime.InteropServices.Marshal]::WriteInt64($script:EtwPropsPtr, $zi, 0L)
            }
            [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 0, $propTotal)   # Wnode.BufferSize
            [System.Runtime.InteropServices.Marshal]::Copy($sessionGuidBytes, 0, [IntPtr]::Add($script:EtwPropsPtr, 24), 16) # Wnode.Guid
            [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 40, 1)          # Wnode.ClientContext = QPC
            [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 44, 0x00020000) # WNODE_FLAG_TRACED_GUID
            [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 48, 64)         # BufferSize (64 KB)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 52, 4)          # MinimumBuffers
            [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 56, 32)         # MaximumBuffers
            [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 64, $logMode)   # LogFileMode
            [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 68, 1)          # FlushTimer (1 sec)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 72, $enFlags)   # EnableFlags
            [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwPropsPtr, 108 + [IntPtr]::Size, $propBase) # LoggerNameOffset
        }

        # Primary: Private System Logger session (EVENT_TRACE_SYSTEM_LOGGER_MODE 0x02000000 | REAL_TIME 0x00000100) + EVENT_TRACE_FLAG_NETWORK_TCPIP (0x00010000)
        $useSysLogger = $true
        &$initProps 0x02000100 0x00010000
        $sHandle = [uint64]0
        $errStart = [PSRPM.EtwNetConsumerV1]::StartTraceW([ref]$sHandle, $script:EtwSessionName, $script:EtwPropsPtr)
        if ($errStart -eq 183) {
            # ERROR_ALREADY_EXISTS: stop orphan and retry once
            &$initProps 0x02000100 0x00010000
            [void][PSRPM.EtwNetConsumerV1]::ControlTraceW([uint64]0, $script:EtwSessionName, $script:EtwPropsPtr, [uint32]1)
            &$initProps 0x02000100 0x00010000
            $sHandle = [uint64]0
            $errStart = [PSRPM.EtwNetConsumerV1]::StartTraceW([ref]$sHandle, $script:EtwSessionName, $script:EtwPropsPtr)
        }
        if ($errStart -ne 0 -and $errStart -ne 5) {
            # Fallback for pre-Win8 or saturated 8-slot System Logger limit: standard real-time session + EnableTraceEx2
            $useSysLogger = $false
            &$initProps 0x00000100 0
            $sHandle = [uint64]0
            $errStart = [PSRPM.EtwNetConsumerV1]::StartTraceW([ref]$sHandle, $script:EtwSessionName, $script:EtwPropsPtr)
            if ($errStart -eq 183) {
                &$initProps 0x00000100 0
                [void][PSRPM.EtwNetConsumerV1]::ControlTraceW([uint64]0, $script:EtwSessionName, $script:EtwPropsPtr, [uint32]1)
                &$initProps 0x00000100 0
                $sHandle = [uint64]0
                $errStart = [PSRPM.EtwNetConsumerV1]::StartTraceW([ref]$sHandle, $script:EtwSessionName, $script:EtwPropsPtr)
            }
        }

        if ($errStart -eq 5) {
            # ERROR_ACCESS_DENIED -> Tier 1 Non-Admin Graceful Fallback
            &$stopNetEtw
            $script:EtwLastErr = "StartTrace=5"
            $script:EtwNetCap = 3
            return
        }
        if ($errStart -ne 0) {
            &$stopNetEtw
            $script:EtwLastErr = "StartTrace=$errStart"
            $script:EtwNetCap = 4
            return
        }
        $script:EtwSessionHandle = $sHandle

        if (-not $useSysLogger) {
            # Enable Microsoft-Windows-Kernel-Network {7dd42a49-5329-4832-8dfd-43d979153a88} on fallback session
            $netGuid = [Guid]"7dd42a49-5329-4832-8dfd-43d979153a88"
            $errEn = [PSRPM.EtwNetConsumerV1]::EnableTraceEx2(
                $script:EtwSessionHandle,
                [ref]$netGuid,
                [uint32]1,      # EVENT_CONTROL_CODE_ENABLE_PROVIDER
                [byte]5,        # TRACE_LEVEL_VERBOSE
                [uint64]0x30,   # KERNEL_NETWORK_KEYWORD_IPV4 | IPV6
                [uint64]0,
                [uint32]0,
                [IntPtr]::Zero
            )
            if ($errEn -ne 0) {
                &$stopNetEtw
                $script:EtwLastErr = "EnableTraceEx2=$errEn"
                $script:EtwNetCap = if ($errEn -eq 5) { 3 } else { 4 }
                return
            }
        }

        # Prepare rooted Winapi delegate for ProcessTrace
        if ($null -eq $script:EtwEventDelegate) {
            $delType = 'PSRPM.EtwEventRecordCallback' -as [type]
            $onEvMethod = ([PSRPM.EtwNetConsumerV1]).GetMethod("OnEventRecord")
            $script:EtwEventDelegate = [Delegate]::CreateDelegate($delType, $onEvMethod)
        }
        $cbPtr = [System.Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($script:EtwEventDelegate)

        # Build EVENT_TRACE_LOGFILEW (x64: 448 bytes, Callback@424; x86: 416 bytes, Callback@400)
        $lfSize = if ($is64) { 448 } else { 416 }
        $script:EtwLogFilePtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($lfSize)
        for ($zi = 0; $zi -lt $lfSize; $zi++) { [System.Runtime.InteropServices.Marshal]::WriteByte($script:EtwLogFilePtr, $zi, 0) }
        $script:EtwLogNamePtr = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($script:EtwSessionName)

        $offLoggerName = [IntPtr]::Size
        $offProcMode   = if ($is64) { 28 } else { 20 }
        $offCallback   = if ($is64) { 424 } else { 400 }
        [System.Runtime.InteropServices.Marshal]::WriteIntPtr($script:EtwLogFilePtr, $offLoggerName, $script:EtwLogNamePtr)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($script:EtwLogFilePtr, $offProcMode, 0x10000100) # REAL_TIME | EVENT_RECORD
        [System.Runtime.InteropServices.Marshal]::WriteIntPtr($script:EtwLogFilePtr, $offCallback, $cbPtr)

        $tHandle = [PSRPM.EtwNetConsumerV1]::OpenTraceW($script:EtwLogFilePtr)
        $openErr = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $invTraceHnd = if ($is64) { [uint64]::MaxValue } else { [uint64]0xFFFFFFFFL }
        if ($tHandle -eq $invTraceHnd -or $tHandle -eq [uint64]0) {
            &$stopNetEtw
            $script:EtwLastErr = "OpenTrace=$openErr"
            $script:EtwNetCap = if ($openErr -eq 5) { 3 } else { 4 }
            return
        }

        [PSRPM.EtwNetConsumerV1]::ClearSlots()
        [PSRPM.EtwNetConsumerV1]::ActiveBank = 0
        [PSRPM.EtwNetConsumerV1]::InFlight0  = 0
        [PSRPM.EtwNetConsumerV1]::InFlight1  = 0
        [PSRPM.EtwNetConsumerV1]::TotalEvents = 0
        [PSRPM.EtwNetConsumerV1]::Active = 1
        [PSRPM.EtwNetConsumerV1]::ActiveTraceHandle = $tHandle
        $script:EtwTraceHandle = $tHandle
        $script:EtwNetActive = $true
        $script:EtwNetCap = 1
        $script:EtwBreakerTripped = $false
        $script:EtwHighRateTicks = 0
        $script:EtwLastDrainTicks = [DateTime]::UtcNow.Ticks

        $ts = [System.Threading.ThreadStart]::CreateDelegate([System.Threading.ThreadStart], ([PSRPM.EtwNetConsumerV1]).GetMethod("TraceThreadMain"))
        $script:EtwConsumerThread = [System.Threading.Thread]::new($ts)
        $script:EtwConsumerThread.IsBackground = $true
        $script:EtwConsumerThread.Name = "PSRPM_ETW_Net"
        $script:EtwConsumerThread.Start()

        [System.Threading.Thread]::Sleep(15)
        $tsErr = [PSRPM.EtwNetConsumerV1]::LastTraceStatus
        if ((-not $script:EtwConsumerThread.IsAlive) -and $tsErr -ne 0 -and $tsErr -ne 1223) {
            &$stopNetEtw
            $script:EtwLastErr = "ProcessTrace=$tsErr"
            $script:EtwNetCap = if ($tsErr -eq 5) { 3 } else { 4 }
            return
        }
    }

    if ($NetEtwAction -eq "Stop") {
        $script:EtwBreakerTripped = $false
        &$stopNetEtw
        $script:EtwLastErr = ""
        $script:EtwNetCap = 0
        $script:EtwLastSentCap = 0
        return "STOPPED"
    }

    if ($NetEtwAction -eq "ResetBreaker") {
        $script:EtwBreakerTripped = $false
        $script:EtwHighRateTicks = 0
        if ($script:EtwNetCap -eq 2) { $script:EtwNetCap = 0 }
    }

    if ($EnableNetEtw) {
        if (-not $script:EtwBreakerTripped -and -not $script:EtwNetActive -and $script:EtwNetCap -ne 3) {
            &$startNetEtw
        }
    } else {
        if ($script:EtwNetActive -or $script:EtwNetCap -eq 1) {
            $script:EtwBreakerTripped = $false
            &$stopNetEtw
            $script:EtwNetCap = 0
        }
    }

    if ($script:FileMetaCache.Count -gt 4096) {
        $script:FileMetaCache.Clear()
        $script:FileMetaCache["n/a"] = @{ d = ""; c = "" }
    }
    if ($script:SidCache.Count -gt 1024) {
        $script:SidCache.Clear()
        $script:SidCache["S-1-5-18"] = "NT AUTHORITY\SYSTEM"
        $script:SidCache["S-1-5-19"] = "NT AUTHORITY\LOCAL SERVICE"
        $script:SidCache["S-1-5-20"] = "NT AUTHORITY\NETWORK SERVICE"
    }

    # Refresh Windows Services Cache first on initial sync, early refresh flag, or every 15s so ServicePidSet is ready
    $servicesPayload = $null
    $deadSvcNames    = [System.Collections.Generic.List[string]]::new()
    $svcMs           = 0
    $svcFullNum      = 0
    $nowUtc          = [DateTime]::UtcNow

    try {
        if ([bool][AppDomain]::CurrentDomain.GetData("PSRPM_ForceSvcRefresh")) {
            [AppDomain]::CurrentDomain.SetData("PSRPM_ForceSvcRefresh", $false)
            $script:LastSvcRefresh = [DateTime]::MinValue
        }
    } catch {}

    if (($nowUtc - $script:LastSvcRefresh).TotalSeconds -ge 15.0) {
        $swSvc = [System.Diagnostics.Stopwatch]::StartNew()

        # 1. Static Registry Service Metadata (Cached 10 min, reset on full sync)
        if ($script:SvcStaticCache.Count -eq 0 -or ($nowUtc - $script:LastSvcStaticRefresh).TotalMinutes -ge 10.0) {
            $newStatic = @{}
            $revMap    = @{}
            try {
                $regServices = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services")
                if ($regServices) {
                    foreach ($subName in $regServices.GetSubKeyNames()) {
                        try {
                            $sKey = $regServices.OpenSubKey($subName)
                            if ($sKey) {
                                $depStr = ""
                                $rawDeps = $sKey.GetValue("DependOnService")
                                if ($rawDeps) {
                                    $dList = [System.Collections.Generic.List[string]]::new()
                                    foreach ($d in $rawDeps) {
                                        $dClean = [string]$d
                                        if ($dClean.StartsWith("+")) { $dClean = $dClean.Substring(1) }
                                        if (-not [string]::IsNullOrWhiteSpace($dClean)) {
                                            $dList.Add($dClean)
                                            if (-not $revMap.ContainsKey($dClean)) {
                                                $revMap[$dClean] = [System.Collections.Generic.List[string]]::new()
                                            }
                                            $revMap[$dClean].Add($subName)
                                        }
                                    }
                                    if ($dList.Count -gt 0) {
                                        $depStr = ($dList -join ", ")
                                    }
                                }

                                $startVal = $sKey.GetValue("Start")
                                $sm = switch ($startVal) {
                                    2 { "Auto" }
                                    3 { "Manual" }
                                    4 { "Disabled" }
                                    0 { "Boot" }
                                    1 { "System" }
                                    default { "Manual" }
                                }
                                $usr = [string]$sKey.GetValue("ObjectName")
                                if ([string]::IsNullOrWhiteSpace($usr)) { $usr = "LocalSystem" }

                                $descVal = $sKey.GetValue("Description")
                                $dscStr  = if ($descVal -and -not [string]::IsNullOrWhiteSpace($descVal)) { [string]$descVal } else { "" }

                                $imgPath = $sKey.GetValue("ImagePath")
                                $binStr  = if ($imgPath -and -not [string]::IsNullOrWhiteSpace($imgPath)) { [string]$imgPath } else { "" }

                                $newStatic[$subName] = @{
                                    sm  = $sm
                                    u   = $usr
                                    dep = $depStr
                                    rev = ""
                                    dsc = $dscStr
                                    bin = $binStr
                                }
                                $sKey.Close()
                            }
                        } catch {}
                    }
                    $regServices.Close()
                }
                foreach ($rk in $revMap.Keys) {
                    if ($newStatic.ContainsKey($rk)) {
                        $newStatic[$rk].rev = ($revMap[$rk] -join ", ")
                    }
                }
                if ($newStatic.Count -gt 0) {
                    $script:SvcStaticCache = $newStatic
                    $script:LastSvcStaticRefresh = $nowUtc
                }
            } catch {}
        }

        # 2. Live Service State & PID via Native EnumServicesStatusExW (No WMI, No Fallback on Failure)
        $hScm = [PSRPM.NativeServiceEnumV1]::OpenSCManagerW([IntPtr]::Zero, [IntPtr]::Zero, [uint32]0x0004) # SC_MANAGER_ENUMERATE_SERVICE
        if ($hScm -ne [IntPtr]::Zero) {
            try {
                $bytesNeeded  = [uint32]0
                $svcsReturned = [uint32]0
                $resumeHandle = [uint32]0
                # InfoLevel = 0 (SC_ENUM_PROCESS_INFO), dwServiceType = 0x30 (SERVICE_WIN32), dwServiceState = 0x03 (SERVICE_STATE_ALL)
                $okEnum = [PSRPM.NativeServiceEnumV1]::EnumServicesStatusExW(
                    $hScm, 0, [uint32]0x30, [uint32]0x03,
                    $script:SvcBufPtr, [uint32]$script:SvcBufSize,
                    [ref]$bytesNeeded, [ref]$svcsReturned, [ref]$resumeHandle, [IntPtr]::Zero
                )
                $maxSvcBufSize = 4194304 # 4 MB ceiling
                $svcRealloc = 0
                while ($okEnum -eq 0 -and [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() -eq 234 -and $svcRealloc -lt 4 -and $script:SvcBufSize -lt $maxSvcBufSize) {
                    $svcRealloc++
                    $reqBytes = [int]$bytesNeeded + 16384
                    $newSvcSz = [Math]::Min($maxSvcBufSize, [Math]::Max($script:SvcBufSize * 2, $reqBytes))
                    if ($newSvcSz -le $script:SvcBufSize) { break }
                    $newSvcPtr = [IntPtr]::Zero
                    try {
                        $newSvcPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($newSvcSz)
                    } catch {
                        break
                    }
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($script:SvcBufPtr)
                    $script:SvcBufPtr  = $newSvcPtr
                    $script:SvcBufSize = $newSvcSz
                    $bytesNeeded  = [uint32]0
                    $svcsReturned = [uint32]0
                    $resumeHandle = [uint32]0
                    $okEnum = [PSRPM.NativeServiceEnumV1]::EnumServicesStatusExW(
                        $hScm, 0, [uint32]0x30, [uint32]0x03,
                        $script:SvcBufPtr, [uint32]$script:SvcBufSize,
                        [ref]$bytesNeeded, [ref]$svcsReturned, [ref]$resumeHandle, [IntPtr]::Zero
                    )
                }

                if ($okEnum -ne 0 -and $svcsReturned -gt 0) {
                    $svcArr = [System.Collections.Generic.List[Object]]::new([int]$svcsReturned)
                    $script:ServicePidSet.Clear()

                    $is64Svc     = ([IntPtr]::Size -eq 8)
                    $ptrSzSvc    = [IntPtr]::Size
                    $svcStride   = if ($is64Svc) { 56 } else { 44 }
                    $offSvcState = ($ptrSzSvc * 2) + 4
                    $offSvcPid   = ($ptrSzSvc * 2) + 28
                    $countSvc    = [int]$svcsReturned

                    for ($si = 0; $si -lt $countSvc; $si++) {
                        $ePtr    = [IntPtr]::Add($script:SvcBufPtr, $si * $svcStride)
                        $pName   = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($ePtr, 0)
                        $pDisp   = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($ePtr, $ptrSzSvc)
                        $stCode  = [System.Runtime.InteropServices.Marshal]::ReadInt32($ePtr, $offSvcState)
                        $sPid    = [int]([long][System.Runtime.InteropServices.Marshal]::ReadInt32($ePtr, $offSvcPid) -band 0xFFFFFFFFL)

                        $sName = if ($pName -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::PtrToStringUni($pName) } else { "" }
                        if ([string]::IsNullOrWhiteSpace($sName)) { continue }
                        $sDisp = if ($pDisp -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::PtrToStringUni($pDisp) } else { $sName }
                        if ([string]::IsNullOrWhiteSpace($sDisp)) { $sDisp = $sName }

                        if ($sPid -gt 0) {
                            [void]$script:ServicePidSet.Add($sPid)
                        }

                        $sState = switch ($stCode) {
                            4 { "Running" }
                            1 { "Stopped" }
                            2 { "Start Pending" }
                            3 { "Stop Pending" }
                            5 { "Continue Pending" }
                            6 { "Pause Pending" }
                            7 { "Paused" }
                            default { "Stopped" }
                        }

                        $stMeta = if ($script:SvcStaticCache.ContainsKey($sName)) {
                            $script:SvcStaticCache[$sName]
                        } elseif ($sName -match '^(.+)_[0-9a-fA-F]{4,8}$' -and $script:SvcStaticCache.ContainsKey($matches[1])) {
                            $script:SvcStaticCache[$matches[1]]
                        } else {
                            $null
                        }

                        $svcArr.Add(@{
                            n   = $sName
                            d   = $sDisp
                            p   = $sPid
                            st  = $sState
                            sm  = if ($stMeta) { $stMeta.sm }  else { "Manual" }
                            u   = if ($stMeta) { $stMeta.u }   else { "LocalSystem" }
                            dep = if ($stMeta) { $stMeta.dep } else { "" }
                            rev = if ($stMeta) { $stMeta.rev } else { "" }
                            dsc = if ($stMeta) { $stMeta.dsc } else { "" }
                            bin = if ($stMeta) { $stMeta.bin } else { "" }
                        })
                    }

                    # Publish live service list to script & AppDomain data so Properties and async workers read it in 0ms
                    $script:CachedServices = $svcArr
                    try {
                        [AppDomain]::CurrentDomain.SetData("PSRPM_CachedServices", $svcArr)
                    } catch {}

                    $sendFullSvc = ($script:LastSvcState.Count -eq 0 -or $ForceFullSync)
                    if ($sendFullSvc) { $svcFullNum = 1 }
                    $deltaSvc = [System.Collections.Generic.List[Object]]::new()
                    $seenSvcNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

                    foreach ($entry in $svcArr) {
                        $sKey = [string]$entry.n
                        [void]$seenSvcNames.Add($sKey)
                        $sig = "$($entry.p)|$($entry.st)|$($entry.sm)|$($entry.u)|$($entry.d)|$($entry.dep)|$($entry.rev)|$($entry.dsc)|$($entry.bin)"
                        if ($sendFullSvc -or -not $script:LastSvcState.ContainsKey($sKey) -or $script:LastSvcState[$sKey] -ne $sig) {
                            $script:LastSvcState[$sKey] = $sig
                            $deltaSvc.Add($entry)
                        }
                    }

                    $oldSvcKeys = @($script:LastSvcState.Keys)
                    foreach ($oldKey in $oldSvcKeys) {
                        if (-not $seenSvcNames.Contains($oldKey)) {
                            [void]$script:LastSvcState.Remove($oldKey)
                            $deadSvcNames.Add($oldKey)
                        }
                    }

                    if ($deltaSvc.Count -gt 0) {
                        $servicesPayload = $deltaSvc
                    }
                    $script:LastSvcRefresh = $nowUtc
                }
            } finally {
                [void][PSRPM.NativeServiceEnumV1]::CloseServiceHandle($hScm)
            }
        }
        $swSvc.Stop()
        $svcMs = [int]$swSvc.ElapsedMilliseconds
    }

    $script:SeqNumber++
    $nowTicks = [DateTime]::UtcNow.Ticks
    $wallDeltaTicks = $nowTicks - $script:LastSnapTicks
    if ($wallDeltaTicks -le 0L) { $wallDeltaTicks = 10000000L } # 1s fallback in 100ns units
    $totalCapacityTicks = [double]($wallDeltaTicks * $script:CoreCount)

    # 1C. Opt-In Kernel Network ETW Drain & 25k ev/s Circuit Breaker
    $netEvRate = 0
    if ($script:EtwNetActive -and ('PSRPM.EtwNetConsumerV1' -as [type])) {
        $etwDeltaTicks = $nowTicks - $script:EtwLastDrainTicks
        if ($etwDeltaTicks -le 0L) { $etwDeltaTicks = $wallDeltaTicks }
        $etwDtSec = [double]$etwDeltaTicks / 10000000.0
        if ($etwDtSec -lt 0.1) { $etwDtSec = 0.1 }
        $script:EtwLastDrainTicks = $nowTicks

        $totalEv = 0
        $drainedCount = [PSRPM.EtwNetConsumerV1]::DrainAndReset(
            $script:EtwDrainPids, $script:EtwDrainRx, $script:EtwDrainTx, [ref]$totalEv
        )
        $netEvRate = [int][Math]::Round([double]$totalEv / $etwDtSec)

        # Circuit breaker: immediate spike >50k/s OR 2 consecutive ticks >25k/s -> auto-pause
        $tripBreaker = $false
        if ($netEvRate -gt 50000) {
            $tripBreaker = $true
        } elseif ($netEvRate -gt 25000) {
            $script:EtwHighRateTicks++
            if ($script:EtwHighRateTicks -ge 2) { $tripBreaker = $true }
        } else {
            $script:EtwHighRateTicks = 0
        }

        if ($tripBreaker) {
            $script:EtwBreakerTripped = $true
            &$stopNetEtw
            $script:EtwNetCap = 2 # AutoPaused
        } else {
            $script:EtwNetRates.Clear()
            for ($ei = 0; $ei -lt $drainedCount; $ei++) {
                $ePid = $script:EtwDrainPids[$ei]
                if ($ePid -gt 0) {
                    $rBps = [long][Math]::Round([double]$script:EtwDrainRx[$ei] / $etwDtSec)
                    $tBps = [long][Math]::Round([double]$script:EtwDrainTx[$ei] / $etwDtSec)
                    if ($rBps -gt 0L -or $tBps -gt 0L) {
                        $script:EtwNetRates[$ePid] = [long[]]@($rBps, $tBps)
                    }
                }
            }
            if ($drainedCount -gt 2048) {
                [PSRPM.EtwNetConsumerV1]::ClearSlots()
            }
        }
    }
    $etwRateActive = ($script:EtwNetCap -eq 1)

    # 2. Query SystemProcessInformation (Class 5) in a Single Kernel Transition
    $retLen = 0
    $status = [PSRPM.NativeCollectorV3]::NtQuerySystemInformation(5, $script:SysBufPtr, $script:SysBufSize, [ref]$retLen)
    $maxSysBufSize = 16777216 # 16 MB ceiling (prevents unbounded memory growth)
    $reallocAttempts = 0
    while ($status -eq -1073741820 -and $reallocAttempts -lt 5 -and $script:SysBufSize -lt $maxSysBufSize) { # STATUS_INFO_LENGTH_MISMATCH (0xC0000004)
        $reallocAttempts++
        $newSize = [Math]::Min($maxSysBufSize, [Math]::Max($script:SysBufSize * 2, $retLen + 65536))
        if ($newSize -le $script:SysBufSize) { break }
        $newPtr = [IntPtr]::Zero
        try {
            $newPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($newSize)
        } catch {
            break
        }
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($script:SysBufPtr)
        $script:SysBufPtr  = $newPtr
        $script:SysBufSize = $newSize
        $status = [PSRPM.NativeCollectorV3]::NtQuerySystemInformation(5, $script:SysBufPtr, $script:SysBufSize, [ref]$retLen)
    }

    if ($status -ne 0) {
        return $null
    }

    $currKeys     = [System.Collections.Generic.HashSet[string]]::new()
    $currPids     = [System.Collections.Generic.HashSet[int]]::new()
    $newMetaList  = [System.Collections.Generic.List[Object]]::new()
    $dynDeltaList = [System.Collections.Generic.List[string]]::new()

    $totalProcs   = 0
    $totalThreads = 0
    $totalHandles = 0
    $procCpuSum   = 0.0
    $idleCpuDelta = 0L

    # Struct Offsets (x64 vs x86)
    $is64         = ([IntPtr]::Size -eq 8)
    $offNamePtr   = if ($is64) { 64 }  else { 60 }
    $offBasePrio  = if ($is64) { 72 }  else { 64 }
    $offPid       = if ($is64) { 80 }  else { 68 }
    $offPpid      = if ($is64) { 88 }  else { 72 }
    $offHandles   = if ($is64) { 96 }  else { 76 }
    $offSession   = if ($is64) { 100 } else { 80 }
    $offWsBytes   = if ($is64) { 144 } else { 104 } # Fixed: x86 WorkingSetSize is at offset 104
    $offPrivBytes = if ($is64) { 184 } else { 132 }
    $spiSize      = if ($is64) { 256 } else { 184 }
    $stiSize      = if ($is64) { 80 }  else { 64 }
    $offThState   = if ($is64) { 68 }  else { 52 }
    $offThWait    = if ($is64) { 72 }  else { 56 }

    $validLen = if ($retLen -gt 0 -and $retLen -le $script:SysBufSize) { $retLen } else { $script:SysBufSize }
    $swMeta = [System.Diagnostics.Stopwatch]::StartNew()
    $metaBudgetMs = if ($script:SeqNumber -eq 1 -or $ForceFullSync) { 600 } else { 15 }
    $offset = 0
    while (($offset + $spiSize) -le $validLen) {
        $curPtr     = [IntPtr]::Add($script:SysBufPtr, $offset)
        $nextOffset = [System.Runtime.InteropServices.Marshal]::ReadInt32($curPtr, 0)
        $numThreads = [System.Runtime.InteropServices.Marshal]::ReadInt32($curPtr, 4)
        $createTime = [System.Runtime.InteropServices.Marshal]::ReadInt64($curPtr, 32)
        $userTime   = [System.Runtime.InteropServices.Marshal]::ReadInt64($curPtr, 40)
        $kernelTime = [System.Runtime.InteropServices.Marshal]::ReadInt64($curPtr, 48)
        $pidVal     = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($curPtr, $offPid).ToInt32()

        if ($pidVal -eq 0) {
            # System Idle Process (PID 0)
            $idleTotal = $userTime + $kernelTime
            if ($script:LastIdleCpu -gt 0L) {
                $idleCpuDelta = $idleTotal - $script:LastIdleCpu
            }
            $script:LastIdleCpu = $idleTotal
        } else {
            $totalProcs++
            [void]$currPids.Add($pidVal)
            $compKey = "${pidVal}_${createTime}"
            [void]$currKeys.Add($compKey)
            $script:ActivePidToKey[$pidVal] = $compKey

            $ppidVal   = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($curPtr, $offPpid).ToInt32()
            $handles   = [System.Runtime.InteropServices.Marshal]::ReadInt32($curPtr, $offHandles)
            $sessionId = [System.Runtime.InteropServices.Marshal]::ReadInt32($curPtr, $offSession)
            $basePrio  = [System.Runtime.InteropServices.Marshal]::ReadInt32($curPtr, $offBasePrio)
            $wsBytes   = if ($is64) { [System.Runtime.InteropServices.Marshal]::ReadInt64($curPtr, $offWsBytes) } else { ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($curPtr, $offWsBytes) -band 0xFFFFFFFFL) }
            $privBytes = if ($is64) { [System.Runtime.InteropServices.Marshal]::ReadInt64($curPtr, $offPrivBytes) } else { ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($curPtr, $offPrivBytes) -band 0xFFFFFFFFL) }

            $totalThreads += $numThreads
            $totalHandles += $handles

            # Exact Suspended Status Detection via SYSTEM_THREAD_INFORMATION array (0ms overhead)
            $isSuspended = $false
            if ($numThreads -gt 0) {
                $recEnd = if ($nextOffset -gt 0) { $offset + $nextOffset } else { $validLen }
                if ($recEnd -gt $validLen) { $recEnd = $validLen }
                $availBytes = $recEnd - ($offset + $spiSize)
                $safeThreads = [Math]::Min($numThreads, [int]($availBytes / $stiSize))

                if ($safeThreads -gt 0) {
                    $allSusp = $true
                    for ($t = 0; $t -lt $safeThreads; $t++) {
                        $tPtr   = [IntPtr]::Add($curPtr, $spiSize + ($t * $stiSize))
                        $tState = [System.Runtime.InteropServices.Marshal]::ReadInt32($tPtr, $offThState)
                        $tWait  = [System.Runtime.InteropServices.Marshal]::ReadInt32($tPtr, $offThWait)
                        if ($tState -ne 5 -or $tWait -ne 5) { # 5 = Waiting, 5 = Suspended
                            $allSusp = $false
                            break
                        }
                    }
                    $isSuspended = $allSusp
                }
            }
            $statusFlags = if ($isSuspended) { 1 } else { 0 }

            # Delta CPU % Calculation
            $totCpuTicks = $userTime + $kernelTime
            $cycleTime   = [System.Runtime.InteropServices.Marshal]::ReadInt64($curPtr, 24)
            $cpuPct = 0.0
            if ($script:ProcCpuCache.ContainsKey($compKey)) {
                $cpuDiff = $totCpuTicks - $script:ProcCpuCache[$compKey]
                if ($cpuDiff -gt 0L) {
                    $cpuPct = [Math]::Round(($cpuDiff / $totalCapacityTicks) * 100.0, 2)
                    if ($cpuPct -gt 100.0) { $cpuPct = 100.0 }
                    elseif ($cpuPct -le 0.0) { $cpuPct = 0.001 }
                } elseif ($script:ProcCycleCache.ContainsKey($compKey)) {
                    $cycleDiff = $cycleTime - $script:ProcCycleCache[$compKey]
                    if ($cycleDiff -gt 0L) {
                        # Sub-tick CPU activity (< 1 scheduler clock tick) -> triggers "< 0.01" display
                        $cpuPct = 0.001
                    }
                }
            }
            $script:ProcCpuCache[$compKey]   = $totCpuTicks
            $script:ProcCycleCache[$compKey] = $cycleTime
            $procCpuSum += $cpuPct

            # 3. Static Metadata Enrichment (Executed ONLY ONCE when a new PID+CreateTime spawns; slow SID/FileVersionInfo time-budgeted)
            if (-not $script:ProcMetaCache.ContainsKey($compKey)) {
                $nameLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($curPtr, 56)
                $namePtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($curPtr, $offNamePtr)
                $pName   = if ($namePtr -ne [IntPtr]::Zero -and $nameLen -gt 0) {
                    [System.Runtime.InteropServices.Marshal]::PtrToStringUni($namePtr, [int]($nameLen / 2))
                } else {
                    if ($pidVal -eq 4) { "System" } else { "Process_$pidVal" }
                }

                $exePath = "N/A"
                $cmdLine = "N/A"
                $userStr = if ($pidVal -in @(4, 124) -or $sessionId -eq 0) { "NT AUTHORITY\SYSTEM" } else { "N/A" }
                $archStr = if ($script:Is64BitOS) { "x64" } else { "x86" }
                $descStr = ""
                $compStr = ""
                $startStr = if ($createTime -gt 0) {
                    try { [DateTime]::FromFileTimeUtc($createTime).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") } catch { "N/A" }
                } else { "N/A" }

                $sidDeferred  = $false
                $pendSidVal   = ""
                $fileDeferred = $false
                $withinBudget = ($swMeta.ElapsedMilliseconds -lt $metaBudgetMs) -or ($pidVal -eq $PID)

                # Open PROCESS_QUERY_LIMITED_INFORMATION (0x1000) once for this new PID
                if ($pidVal -gt 4) {
                    $hProc = [PSRPM.NativeCollectorV3]::OpenProcess(0x1000, 0, $pidVal)
                    if ($hProc -ne [IntPtr]::Zero) {
                        try {
                            # A. Executable Path via QueryFullProcessImageNameW
                            $script:ExePathSb.Length = 0
                            $cap = $script:ExePathSb.Capacity
                            if ([PSRPM.NativeCollectorV3]::QueryFullProcessImageNameW($hProc, 0, $script:ExePathSb, [ref]$cap) -ne 0) {
                                $exePath = $script:ExePathSb.ToString()
                            }

                            # B. Command Line via NtQueryInformationProcess(ProcessCommandLineInformation = 60)
                            $cmdRet = 0
                            if ([PSRPM.NativeCollectorV3]::NtQueryInformationProcess($hProc, 60, $script:ScratchBufPtr, 8192, [ref]$cmdRet) -eq 0) {
                                $cLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($script:ScratchBufPtr, 0)
                                $cPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($script:ScratchBufPtr, $script:PtrSize)
                                if ($cPtr -ne [IntPtr]::Zero -and $cLen -gt 0) {
                                    $cmdLine = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($cPtr, [int]($cLen / 2))
                                }
                            }

                            # C. Architecture via IsWow64Process
                            if ($script:Is64BitOS) {
                                $wow64 = 0
                                if ([PSRPM.NativeCollectorV3]::IsWow64Process($hProc, [ref]$wow64) -ne 0 -and $wow64 -ne 0) {
                                    $archStr = "x86"
                                }
                            }

                            # D. User Account via OpenProcessToken + SidCache (Zero WMI GetOwner, Time-Budgeted)
                            $hTok = [IntPtr]::Zero
                            if ([PSRPM.NativeCollectorV3]::OpenProcessToken($hProc, 0x0008, [ref]$hTok) -ne 0) {
                                try {
                                    $tokRet = 0
                                    if ([PSRPM.NativeCollectorV3]::GetTokenInformation($hTok, 1, $script:ScratchBufPtr, 256, [ref]$tokRet) -ne 0) {
                                        $sidPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($script:ScratchBufPtr, 0)
                                        $sidObj = [System.Security.Principal.SecurityIdentifier]::new($sidPtr)
                                        $sidVal = $sidObj.Value
                                        if ($script:SidCache.ContainsKey($sidVal)) {
                                            $userStr = $script:SidCache[$sidVal]
                                        } elseif ($withinBudget) {
                                            try {
                                                $userStr = $sidObj.Translate([System.Security.Principal.NTAccount]).Value
                                            } catch {
                                                $userStr = $sidVal
                                            }
                                            $script:SidCache[$sidVal] = $userStr
                                        } else {
                                            $userStr     = $sidVal
                                            $sidDeferred = $true
                                            $pendSidVal  = $sidVal
                                        }
                                    }
                                } finally {
                                    [void][PSRPM.NativeCollectorV3]::CloseHandle($hTok)
                                }
                            }
                        } finally {
                            [void][PSRPM.NativeCollectorV3]::CloseHandle($hProc)
                        }
                    }
                }

                # E. FileVersionInfo (Cached per Unique Executable Path, Time-Budgeted)
                $withinBudgetFile = ($swMeta.ElapsedMilliseconds -lt $metaBudgetMs) -or ($pidVal -eq $PID)
                if ($exePath -ne "N/A") {
                    $pathKey = $exePath.ToLowerInvariant()
                    if ($script:FileMetaCache.ContainsKey($pathKey)) {
                        $fMeta   = $script:FileMetaCache[$pathKey]
                        $descStr = $fMeta.d
                        $compStr = $fMeta.c
                    } elseif ($withinBudgetFile) {
                        try {
                            if ([System.IO.File]::Exists($exePath)) {
                                $fvi     = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
                                $descStr = [string]$fvi.FileDescription
                                $compStr = [string]$fvi.CompanyName
                            }
                        } catch {}
                        $script:FileMetaCache[$pathKey] = @{ d = $descStr; c = $compStr }
                    } else {
                        $fileDeferred = $true
                    }
                }

                if ([string]::IsNullOrWhiteSpace($descStr)) {
                    if ($pName -eq "System") { $descStr = "NT Kernel & System"; $compStr = "Microsoft Corporation" }
                    elseif ($pName -eq "Registry") { $descStr = "Windows Registry Kernel Store"; $compStr = "Microsoft Corporation" }
                    elseif ($pName -eq "Memory Compression") { $descStr = "Windows Memory Compression"; $compStr = "Microsoft Corporation" }
                    elseif ($pName -eq "smss.exe") { $descStr = "Windows Session Manager"; $compStr = "Microsoft Corporation" }
                    elseif ($pName -eq "csrss.exe") { $descStr = "Client Server Runtime Process"; $compStr = "Microsoft Corporation" }
                    elseif ($pName -eq "wininit.exe") { $descStr = "Windows Start-Up Application"; $compStr = "Microsoft Corporation" }
                    elseif ($pName -eq "services.exe") { $descStr = "Services and Controller app"; $compStr = "Microsoft Corporation" }
                    elseif ($pName -eq "svchost.exe") { $descStr = "Host Process for Windows Services"; $compStr = "Microsoft Corporation" }
                }

                # F. Semantic Category Classification (Process Explorer Colors)
                $catStr = "System"
                if ($script:PackagedExeSet.Contains($pName) -or ($exePath -ne "N/A" -and ($exePath -match "WindowsApps|SystemApps|EdgeWebView"))) {
                    $catStr = "Packaged"
                } elseif ($script:ServicePidSet.Contains($pidVal) -or $script:ServiceExeSet.Contains($pName)) {
                    $catStr = "Service"
                } elseif ($sessionId -gt 0) {
                    $catStr = "Own"
                }

                $script:ProcMetaCache[$compKey] = @{
                    id    = $pidVal
                    ct    = $createTime
                    n     = $pName
                    p     = $ppidVal
                    u     = $userStr
                    arch  = $archStr
                    path  = $exePath
                    cmd   = $cmdLine
                    desc  = $descStr
                    comp  = $compStr
                    start = $startStr
                    sid   = $sessionId
                    prio  = $basePrio
                    cat   = $catStr
                }

                if ($sidDeferred -or $fileDeferred) {
                    $script:PendingMetaMap[$compKey] = @{
                        sid  = $pendSidVal
                        path = if ($fileDeferred) { $exePath } else { "" }
                    }
                }
            } elseif ($script:PendingMetaMap.ContainsKey($compKey) -and $swMeta.ElapsedMilliseconds -lt $metaBudgetMs) {
                $pendItem = $script:PendingMetaMap[$compKey]
                $mEntry   = $script:ProcMetaCache[$compKey]
                $updated  = $false

                if (-not [string]::IsNullOrEmpty($pendItem.sid)) {
                    $sVal = [string]$pendItem.sid
                    if ($script:SidCache.ContainsKey($sVal)) {
                        $mEntry.u = $script:SidCache[$sVal]
                        $pendItem.sid = ""
                        $updated = $true
                    } elseif ($swMeta.ElapsedMilliseconds -lt $metaBudgetMs) {
                        $uResolved = $sVal
                        try {
                            $uResolved = [System.Security.Principal.SecurityIdentifier]::new($sVal).Translate([System.Security.Principal.NTAccount]).Value
                        } catch {}
                        $script:SidCache[$sVal] = $uResolved
                        $mEntry.u = $uResolved
                        $pendItem.sid = ""
                        $updated = $true
                    }
                }

                if (-not [string]::IsNullOrEmpty($pendItem.path)) {
                    $pVal = [string]$pendItem.path
                    $pKey = $pVal.ToLowerInvariant()
                    if ($script:FileMetaCache.ContainsKey($pKey)) {
                        $fm = $script:FileMetaCache[$pKey]
                        if (-not [string]::IsNullOrWhiteSpace($fm.d)) { $mEntry.desc = $fm.d }
                        if (-not [string]::IsNullOrWhiteSpace($fm.c)) { $mEntry.comp = $fm.c }
                        $pendItem.path = ""
                        $updated = $true
                    } elseif ($swMeta.ElapsedMilliseconds -lt $metaBudgetMs) {
                        $dRes = ""
                        $cRes = ""
                        try {
                            if ([System.IO.File]::Exists($pVal)) {
                                $fvi  = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($pVal)
                                $dRes = [string]$fvi.FileDescription
                                $cRes = [string]$fvi.CompanyName
                            }
                        } catch {}
                        $script:FileMetaCache[$pKey] = @{ d = $dRes; c = $cRes }
                        if (-not [string]::IsNullOrWhiteSpace($dRes)) { $mEntry.desc = $dRes }
                        if (-not [string]::IsNullOrWhiteSpace($cRes)) { $mEntry.comp = $cRes }
                        $pendItem.path = ""
                        $updated = $true
                    }
                }

                if ([string]::IsNullOrEmpty($pendItem.sid) -and [string]::IsNullOrEmpty($pendItem.path)) {
                    [void]$script:PendingMetaMap.Remove($compKey)
                }
                if ($updated) {
                    [void]$script:SentMetaKeys.Remove($compKey)
                }
            }

            # Emit Static Metadata ONLY if not yet sent to Host
            if (-not $script:SentMetaKeys.Contains($compKey)) {
                [void]$script:SentMetaKeys.Add($compKey)
                $m = $script:ProcMetaCache[$compKey]
                $newMetaList.Add($m)
            }

            # 4. Differential Dynamic State Comparison
            # Only emit dynamic row if CPU, WorkingSet (>4KB), PrivateBytes (>4KB), Threads, Handles, Status (or Net when ETW active) changed
            $rxBps = 0L
            $txBps = 0L
            if ($etwRateActive -and $script:EtwNetRates.ContainsKey($pidVal)) {
                $nr = $script:EtwNetRates[$pidVal]
                $rxBps = $nr[0]
                $txBps = $nr[1]
            }

            $emitDyn = $true
            if ($script:LastDynState.ContainsKey($compKey)) {
                $prev = $script:LastDynState[$compKey]
                $baseUnchanged = (
                    $prev[0] -eq $cpuPct -and
                    [Math]::Abs($wsBytes - $prev[1]) -lt 4096L -and
                    [Math]::Abs($privBytes - $prev[2]) -lt 4096L -and
                    $prev[3] -eq $numThreads -and
                    $prev[4] -eq $handles -and
                    $prev[5] -eq $statusFlags
                )
                if ($baseUnchanged) {
                    if (-not $etwRateActive) {
                        if ($prev.Count -eq 6) { $emitDyn = $false }
                    } else {
                        if ($prev.Count -ge 8) {
                            $prevRx = $prev[6]
                            $prevTx = $prev[7]
                            $rxZeroEdge = (($prevRx -eq 0L) -ne ($rxBps -eq 0L))
                            $txZeroEdge = (($prevTx -eq 0L) -ne ($txBps -eq 0L))
                            if (-not $rxZeroEdge -and -not $txZeroEdge -and
                                [Math]::Abs($rxBps - $prevRx) -lt 1024L -and
                                [Math]::Abs($txBps - $prevTx) -lt 1024L) {
                                $emitDyn = $false
                            }
                        }
                    }
                }
            }
            if ($emitDyn) {
                $cpuStr = $cpuPct.ToString([System.Globalization.CultureInfo]::InvariantCulture)
                if ($etwRateActive) {
                    $script:LastDynState[$compKey] = @($cpuPct, $wsBytes, $privBytes, $numThreads, $handles, $statusFlags, $rxBps, $txBps)
                    $dynDeltaList.Add("[$pidVal,$cpuStr,$wsBytes,$privBytes,$numThreads,$handles,$statusFlags,$rxBps,$txBps]")
                } else {
                    $script:LastDynState[$compKey] = @($cpuPct, $wsBytes, $privBytes, $numThreads, $handles, $statusFlags)
                    $dynDeltaList.Add("[$pidVal,$cpuStr,$wsBytes,$privBytes,$numThreads,$handles,$statusFlags]")
                }
            }
        }

        if ($nextOffset -le 0 -or ($offset + $nextOffset) -gt $validLen) { break }
        $offset += $nextOffset
    }

    # 5. Reclaim Dead Process Keys & Build Dead PIDs List
    $deadPids = [System.Collections.Generic.List[int]]::new()
    $staleKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($sk in $script:ProcCpuCache.Keys) {
        if (-not $currKeys.Contains($sk)) { $staleKeys.Add($sk) }
    }
    foreach ($sk in $staleKeys) {
        $script:ProcCpuCache.Remove($sk)
        $script:ProcCycleCache.Remove($sk)
        $script:ProcMetaCache.Remove($sk)
        $script:PendingMetaMap.Remove($sk)
        $script:LastDynState.Remove($sk)
        [void]$script:SentMetaKeys.Remove($sk)
    }
    $stalePids = [System.Collections.Generic.List[int]]::new()
    foreach ($sp in $script:ActivePidToKey.Keys) {
        if (-not $currPids.Contains($sp)) { $stalePids.Add($sp) }
    }
    foreach ($sp in $stalePids) {
        $script:ActivePidToKey.Remove($sp)
        [void]$script:EtwNetRates.Remove($sp)
        $deadPids.Add($sp)
    }

    # 6. Zero-WMI System Memory, Kernel Performance & Per-Core CPU Calculation (< 0.02 ms)
    # psapi.dll!GetPerformanceInfo (Exact KB Commit Charge, Physical Cache & Kernel Pool Counters)
    $commitCurKB      = 0L
    $commitLimKB      = 0L
    $commitPeakKB     = 0L
    $physTotalKB      = 0L
    $physAvailKB      = 0L
    $sysCacheKB       = 0L
    $kernelPagedKB    = 0L
    $kernelNonPagedKB = 0L

    $perfCb = if ($is64) { 104 } else { 56 }
    [System.Runtime.InteropServices.Marshal]::WriteInt32($script:ScratchBufPtr, 0, $perfCb)
    $perfSuccess = ([PSRPM.NativeCollectorV3]::GetPerformanceInfo($script:ScratchBufPtr, [uint32]$perfCb) -ne 0)

    if ($perfSuccess) {
        if ($is64) {
            $pageSz    = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 80)
            $pageMulKB = if ($pageSz -gt 0L) { [long]($pageSz / 1024L) } else { 4L }
            $commitCurKB      = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 8)  * $pageMulKB
            $commitLimKB      = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 16) * $pageMulKB
            $commitPeakKB     = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 24) * $pageMulKB
            $physTotalKB      = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 32) * $pageMulKB
            $physAvailKB      = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 40) * $pageMulKB
            $sysCacheKB       = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 48) * $pageMulKB
            $kernelPagedKB    = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 64) * $pageMulKB
            $kernelNonPagedKB = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 72) * $pageMulKB
        } else {
            $pageSz    = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 40) -band 0xFFFFFFFFL)
            $pageMulKB = if ($pageSz -gt 0L) { [long]($pageSz / 1024L) } else { 4L }
            $commitCurKB      = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 4)  -band 0xFFFFFFFFL) * $pageMulKB
            $commitLimKB      = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 8)  -band 0xFFFFFFFFL) * $pageMulKB
            $commitPeakKB     = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 12) -band 0xFFFFFFFFL) * $pageMulKB
            $physTotalKB      = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 16) -band 0xFFFFFFFFL) * $pageMulKB
            $physAvailKB      = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 20) -band 0xFFFFFFFFL) * $pageMulKB
            $sysCacheKB       = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 24) -band 0xFFFFFFFFL) * $pageMulKB
            $kernelPagedKB    = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 32) -band 0xFFFFFFFFL) * $pageMulKB
            $kernelNonPagedKB = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 36) -band 0xFFFFFFFFL) * $pageMulKB
        }
        $ramTotalMB    = [Math]::Round($physTotalKB / 1024L)
        $ramAvailMB    = [Math]::Round($physAvailKB / 1024L)
        $ramUsedMB     = [Math]::Max(0L, $ramTotalMB - $ramAvailMB)
        $commitLimitMB = [Math]::Round($commitLimKB / 1024L)
        $commitUsedMB  = [Math]::Round($commitCurKB / 1024L)
    } else {
        $gmsArgs = [object[]]@($script:MemStatInst)
        [void]$script:GmsMethod.Invoke($null, $gmsArgs)
        $msOut         = $gmsArgs[0]
        $ramTotalMB    = [Math]::Round([long]$script:F_TotalPhys.GetValue($msOut) / 1MB)
        $ramAvailMB    = [Math]::Round([long]$script:F_AvailPhys.GetValue($msOut) / 1MB)
        $ramUsedMB     = [Math]::Max(0L, $ramTotalMB - $ramAvailMB)
        $commitLimitMB = [Math]::Round([long]$script:F_TotalPage.GetValue($msOut) / 1MB)
        $commitUsedMB  = $commitLimitMB - [Math]::Round([long]$script:F_AvailPage.GetValue($msOut) / 1MB)
        $commitCurKB   = $commitUsedMB * 1024L
        $commitLimKB   = $commitLimitMB * 1024L
        $commitPeakKB  = $commitCurKB
        $physTotalKB   = $ramTotalMB * 1024L
        $physAvailKB   = $ramAvailMB * 1024L
    }

    $systemCpu = if ($idleCpuDelta -gt 0L -and $totalCapacityTicks -gt 0) {
        $busyPct = 100.0 - (($idleCpuDelta / $totalCapacityTicks) * 100.0)
        [Math]::Max(0.0, [Math]::Min(100.0, [Math]::Round($busyPct, 2)))
    } else {
        [Math]::Min(100.0, [Math]::Round($procCpuSum, 2))
    }
    $kernelCpu = 0.0
    $intrDelta = 0L
    $coreTuples = [System.Collections.Generic.List[string]]::new()
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    # A. SystemProcessorPerformanceInformation (Class 8: 48 bytes per logical CPU)
    $sppiLen = $script:CoreCount * 48
    $sppiRet = 0
    if ($sppiLen -le 8192 -and [PSRPM.NativeCollectorV3]::NtQuerySystemInformation(8, $script:ScratchBufPtr, $sppiLen, [ref]$sppiRet) -eq 0) {
        $totIdle = 0L
        $totKern = 0L
        $totUser = 0L
        $totIntr = 0L
        for ($c = 0; $c -lt $script:CoreCount; $c++) {
            $cBase   = $c * 48
            $cIdle   = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, $cBase)
            $cKernRw = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, $cBase + 8)
            $cUser   = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, $cBase + 16)
            $cIntr   = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, $cBase + 40) -band 0xFFFFFFFFL)
            $cKern   = [Math]::Max(0L, $cKernRw - $cIdle)

            $totIdle += $cIdle
            $totKern += $cKern
            $totUser += $cUser
            $totIntr += $cIntr

            $coreTotPct  = 0.0
            $coreKernPct = 0.0
            if ($script:HasKernelBaseline) {
                $dIdle = [Math]::Max(0L, $cIdle - $script:LastCoreIdle[$c])
                $dKern = [Math]::Max(0L, $cKern - $script:LastCoreKern[$c])
                $dUser = [Math]::Max(0L, $cUser - $script:LastCoreUser[$c])
                $dAll  = $dIdle + $dKern + $dUser
                if ($dAll -gt 0L) {
                    $coreTotPct  = [Math]::Min(100.0, [Math]::Round((($dKern + $dUser) / [double]$dAll) * 100.0, 1))
                    $coreKernPct = [Math]::Min($coreTotPct, [Math]::Round(($dKern / [double]$dAll) * 100.0, 1))
                }
            }
            $script:LastCoreIdle[$c] = $cIdle
            $script:LastCoreKern[$c] = $cKern
            $script:LastCoreUser[$c] = $cUser
            $coreTuples.Add("[$($coreTotPct.ToString($inv)),$($coreKernPct.ToString($inv))]")
        }

        if ($script:HasKernelBaseline) {
            $dSysIdle = [Math]::Max(0L, $totIdle - $script:LastSysIdleTicks)
            $dSysKern = [Math]::Max(0L, $totKern - $script:LastSysKernTicks)
            $dSysUser = [Math]::Max(0L, $totUser - $script:LastSysUserTicks)
            $dSysAll  = $dSysIdle + $dSysKern + $dSysUser
            if ($dSysAll -gt 0L) {
                $systemCpu = [Math]::Min(100.0, [Math]::Round((($dSysKern + $dSysUser) / [double]$dSysAll) * 100.0, 2))
                $kernelCpu = [Math]::Min($systemCpu, [Math]::Round(($dSysKern / [double]$dSysAll) * 100.0, 2))
            }
            if ($totIntr -ge $script:LastSysInterrupts) {
                $intrDelta = $totIntr - $script:LastSysInterrupts
            }
        }
        $script:LastSysIdleTicks  = $totIdle
        $script:LastSysKernTicks  = $totKern
        $script:LastSysUserTicks  = $totUser
        $script:LastSysInterrupts = $totIntr
    }

    # B. SystemPerformanceInformation (Class 2: System-wide I/O, Paging & Context Switch Totals)
    $pfDelta      = 0L
    $prDelta      = 0L
    $pfwDelta     = 0L
    $mfwDelta     = 0L
    $csDelta      = 0L
    $scDelta      = 0L
    $ioReadDelta  = 0L
    $ioWriteDelta = 0L
    $ioOtherDelta = 0L
    $ioOpsDelta   = 0L
    $spi2Ret = 0
    if ([PSRPM.NativeCollectorV3]::NtQuerySystemInformation(2, $script:ScratchBufPtr, 512, [ref]$spi2Ret) -eq 0 -and $spi2Ret -ge 312) {
        $curIoR   = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 8)
        $curIoW   = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 16)
        $curIoO   = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 24)
        $curIoROp = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 32) -band 0xFFFFFFFFL)
        $curIoWOp = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 36) -band 0xFFFFFFFFL)
        $curPf    = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 60)  -band 0xFFFFFFFFL)
        $curPr    = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 80)  -band 0xFFFFFFFFL)
        $curPfw   = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 96)  -band 0xFFFFFFFFL)
        $curMfw   = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 104) -band 0xFFFFFFFFL)
        $curCs    = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 296) -band 0xFFFFFFFFL)
        $curSc    = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 308) -band 0xFFFFFFFFL)

        if ($script:HasKernelBaseline) {
            if ($curIoR   -ge $script:LastIoReadBytes)  { $ioReadDelta  = $curIoR - $script:LastIoReadBytes }
            if ($curIoW   -ge $script:LastIoWriteBytes) { $ioWriteDelta = $curIoW - $script:LastIoWriteBytes }
            if ($curIoO   -ge $script:LastIoOtherBytes) { $ioOtherDelta = $curIoO - $script:LastIoOtherBytes }
            if ($curIoROp -ge $script:LastIoReadOps -and $curIoWOp -ge $script:LastIoWriteOps) {
                $ioOpsDelta = ($curIoROp - $script:LastIoReadOps) + ($curIoWOp - $script:LastIoWriteOps)
            }
            if ($curPf    -ge $script:LastPageFaults)     { $pfDelta      = $curPf  - $script:LastPageFaults }
            if ($curPr    -ge $script:LastPageReads)      { $prDelta      = $curPr  - $script:LastPageReads }
            if ($curPfw   -ge $script:LastPageFileWrites) { $pfwDelta     = $curPfw - $script:LastPageFileWrites }
            if ($curMfw   -ge $script:LastMappedWrites)   { $mfwDelta     = $curMfw - $script:LastMappedWrites }
            if ($curCs    -ge $script:LastCtxSwitches)    { $csDelta      = $curCs  - $script:LastCtxSwitches }
            if ($curSc    -ge $script:LastSysCalls)       { $scDelta      = $curSc  - $script:LastSysCalls }
        }

        $script:LastIoReadBytes    = $curIoR
        $script:LastIoWriteBytes   = $curIoW
        $script:LastIoOtherBytes   = $curIoO
        $script:LastIoReadOps      = $curIoROp
        $script:LastIoWriteOps     = $curIoWOp
        $script:LastPageFaults     = $curPf
        $script:LastPageReads      = $curPr
        $script:LastPageFileWrites = $curPfw
        $script:LastMappedWrites   = $curMfw
        $script:LastCtxSwitches    = $curCs
        $script:LastSysCalls       = $curSc
    }
    $script:HasKernelBaseline = $true

    # C. psapi.dll!GetPerformanceInfo counters already computed natively in Section 6

    # D. Extended Hardware Counters (iphlpapi!GetIfTable2 64-bit Network & Storage Activity)
    $netRxKBs       = 0.0
    $netTxKBs       = 0.0
    $diskReadKBs    = 0.0
    $diskWriteKBs   = 0.0
    $diskQueueDepth = 0.0

    try {
        [IntPtr]$tblPtr = [IntPtr]::Zero
        $ifRet = [PSRPM.NativeCollectorV3]::GetIfTable2([ref]$tblPtr)
        if ($ifRet -eq 0 -and $tblPtr -ne [IntPtr]::Zero) {
            try {
                $numIf = [System.Runtime.InteropServices.Marshal]::ReadInt32($tblPtr, 0)
                $totRx = 0L
                $totTx = 0L
                $startOff = 8
                $rowSize  = 1352

                for ($ifIdx = 0; $ifIdx -lt $numIf; $ifIdx++) {
                    $rowPtr = [IntPtr]::Add($tblPtr, $startOff + ($ifIdx * $rowSize))
                    $ifType = [System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 1128)
                    if ($ifType -eq 24) { continue } # skip loopback

                    $flagsByte = [System.Runtime.InteropServices.Marshal]::ReadByte($rowPtr, 1152)
                    if (($flagsByte -band 2) -ne 0) { continue } # skip NDIS filter drivers (prevents duplicate counting)

                    $totRx += [System.Runtime.InteropServices.Marshal]::ReadInt64($rowPtr, 1208)
                    $totTx += [System.Runtime.InteropServices.Marshal]::ReadInt64($rowPtr, 1280)
                }

                $curNetTicks = [DateTime]::UtcNow.Ticks
                if ($script:LastNetTicks -gt 0L) {
                    $netSec = [Math]::Max(0.1, ($curNetTicks - $script:LastNetTicks) / 10000000.0)
                    if ($totRx -ge $script:LastNetRx) {
                        $netRxKBs = [Math]::Round((($totRx - $script:LastNetRx) / 1024.0) / $netSec, 1)
                    } else {
                        $netRxKBs = [Math]::Round(($totRx / 1024.0) / $netSec, 1)
                    }
                    if ($totTx -ge $script:LastNetTx) {
                        $netTxKBs = [Math]::Round((($totTx - $script:LastNetTx) / 1024.0) / $netSec, 1)
                    } else {
                        $netTxKBs = [Math]::Round(($totTx / 1024.0) / $netSec, 1)
                    }
                    $diskReadKBs    = [Math]::Round(($ioReadDelta / 1024.0) / $netSec, 1)
                    $diskWriteKBs   = [Math]::Round(($ioWriteDelta / 1024.0) / $netSec, 1)
                    $diskQueueDepth = [Math]::Round(($ioOpsDelta / $netSec), 1)
                }
                $script:LastNetRx    = $totRx
                $script:LastNetTx    = $totTx
                $script:LastNetTicks = $curNetTicks
            } finally {
                [PSRPM.NativeCollectorV3]::FreeMibTable($tblPtr)
            }
        }
    } catch {}

    $script:LastSnapTicks = $nowTicks

    # 7. Fast Compact JSON Construction + GZip Compression
    $jss = if ($script:Jss) { $script:Jss } else {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
        [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    }

    $sysCpuStr  = $systemCpu.ToString($inv)
    $kernCpuStr = $kernelCpu.ToString($inv)
    $isFullNum  = if ($script:SeqNumber -eq 1 -or $ForceFullSync) { 1 } else { 0 }
    $hwJson     = if ($isFullNum -eq 1) { $jss.Serialize($script:CachedHwInfo) } else { 'null' }
    $metaJson    = if ($newMetaList.Count -gt 0) { $jss.Serialize($newMetaList) } else { '[]' }
    $svcJson     = if ($null -ne $servicesPayload) { $jss.Serialize($servicesPayload) } else { 'null' }
    $svcDeadJson = if ($deadSvcNames.Count -gt 0) { $jss.Serialize($deadSvcNames) } else { '[]' }

    $swCol.Stop()
    $colMs        = [int]$swCol.ElapsedMilliseconds
    $metaPendCnt  = $script:PendingMetaMap.Count

    $sb = [System.Text.StringBuilder]::new(8192)
    [void]$sb.Append('{"ver":1,"colVer":"1.8.2","seq":').Append($script:SeqNumber)
    [void]$sb.Append(',"full":').Append($isFullNum)
    [void]$sb.Append(',"colMs":').Append($colMs)
    [void]$sb.Append(',"svcMs":').Append($svcMs)
    [void]$sb.Append(',"svcFull":').Append($svcFullNum)
    [void]$sb.Append(',"metaPend":').Append($metaPendCnt)
    [void]$sb.Append(',"sys":[').Append("$sysCpuStr,$ramUsedMB,$ramTotalMB,$totalProcs,$totalThreads,$totalHandles,$commitUsedMB,$commitLimitMB,$kernCpuStr,$commitCurKB,$commitLimKB,$commitPeakKB,$physTotalKB,$physAvailKB,$sysCacheKB,$kernelPagedKB,$kernelNonPagedKB,$pfDelta,$prDelta,$pfwDelta,$mfwDelta,$csDelta,$intrDelta,$scDelta,$ioReadDelta,$ioWriteDelta,$ioOtherDelta,$($netRxKBs.ToString($inv)),$($netTxKBs.ToString($inv)),$($diskReadKBs.ToString($inv)),$($diskWriteKBs.ToString($inv)),$($diskQueueDepth.ToString($inv))").Append(']')
    [void]$sb.Append(',"cores":[').Append(($coreTuples -join ',')).Append(']')
    [void]$sb.Append(',"hw":').Append($hwJson)
    [void]$sb.Append(',"dead":[').Append(($deadPids -join ',')).Append(']')
    [void]$sb.Append(',"meta":').Append($metaJson)
    [void]$sb.Append(',"svc":').Append($svcJson)
    [void]$sb.Append(',"svcDead":').Append($svcDeadJson)
    if ($script:EtwNetCap -ne 0 -or $script:EtwLastSentCap -ne 0) {
        [void]$sb.Append(',"netCap":').Append($script:EtwNetCap).Append(',"netEv":').Append($netEvRate)
        if ($script:EtwNetCap -ge 2 -and -not [string]::IsNullOrEmpty($script:EtwLastErr)) {
            [void]$sb.Append(',"netErr":').Append($jss.Serialize([string]$script:EtwLastErr))
        }
        $script:EtwLastSentCap = $script:EtwNetCap
    }
    [void]$sb.Append(',"dyn":[').Append(($dynDeltaList -join ',')).Append(']}')

    $rawBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $ms = [System.IO.MemoryStream]::new()
    $gs = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
    $gs.Write($rawBytes, 0, $rawBytes.Length)
    $gs.Close()
    return "GZIP:" + [Convert]::ToBase64String($ms.ToArray())
}
