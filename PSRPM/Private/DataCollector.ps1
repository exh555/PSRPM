# Requires -Version 5.1
# PSRPM Differential & State-Cached Telemetry Collector
# 100% Fileless In-Memory Reflection.Emit + NtQuerySystemInformation(5)
# Zero Disk Writes, Zero csc.exe, Zero Steady-State WMI

$script:PSRPMCollectorScriptBlock = {
    param(
        [bool]$ForceFullSync = $false
    )

    # 1. One-Time In-Memory Native P/Invoke & State Initialization (0 Disk Writes, 0 csc.exe)
    if (-not ('PSRPM.NativeCollectorV2' -as [type])) {
        $dynAsm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
            [System.Reflection.AssemblyName]::new("PSRPMNativeCollectorV2Asm"),
            [System.Reflection.Emit.AssemblyBuilderAccess]::Run
        )
        $dynMod = $dynAsm.DefineDynamicModule("PSRPMNativeCollectorV2Mod")
        $tb = $dynMod.DefineType("PSRPM.NativeCollectorV2", [System.Reflection.TypeAttributes]"Public,Abstract,Sealed")

        $addPInvoke = {
            param($name, $dll, $retType, [type[]]$paramTypes)
            $mb = $tb.DefinePInvokeMethod(
                $name, $dll,
                [System.Reflection.MethodAttributes]"Public,Static,PinvokeImpl",
                [System.Reflection.CallingConventions]::Standard,
                $retType, $paramTypes,
                [System.Runtime.InteropServices.CallingConvention]::Winapi,
                [System.Runtime.InteropServices.CharSet]::Unicode
            )
            $mb.SetImplementationFlags($mb.GetMethodImplementationFlags() -bor [System.Reflection.MethodImplAttributes]::PreserveSig)
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

        [void]$tb.CreateType()
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
        $script:HasKernelBaseline  = $false

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
        $script:ScratchBufPtr  = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(8192)
        $script:ExePathSb      = [System.Text.StringBuilder]::new(1024)

        # mscorlib GlobalMemoryStatusEx Reflection Binding
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
        $script:ProcMetaCache  = @{} # Key: "PID_CreateTime" -> Hashtable static metadata
        $script:SentMetaKeys   = [System.Collections.Generic.HashSet[string]]::new()
        $script:LastDynState   = @{} # Key: "PID_CreateTime" -> [double cpu, long ws, long pb, int th, int hnd, int flags]
        $script:ActivePidToKey = @{} # Key: int PID -> "PID_CreateTime"
        $script:ServicePidSet  = [System.Collections.Generic.HashSet[int]]::new()
        $script:CachedServices = [System.Collections.Generic.List[Object]]::new()
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
        $script:LastSvcRefresh = [DateTime]::MinValue
    }

    # Refresh Windows Services Cache first on initial sync or every 30s so ServicePidSet is ready
    $servicesPayload = $null
    $nowUtc = [DateTime]::UtcNow
    if (($nowUtc - $script:LastSvcRefresh).TotalSeconds -ge 30.0) {
        $svcArr = [System.Collections.Generic.List[Object]]::new()
        $script:ServicePidSet.Clear()

        # Extract service dependencies, descriptions, and binary paths from registry (fast ~25-45ms, 100% non-elevated)
        $depMap  = @{}
        $revMap  = @{}
        $descMap = @{}
        $binMap  = @{}
        try {
            $regServices = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services")
            if ($regServices) {
                foreach ($subName in $regServices.GetSubKeyNames()) {
                    try {
                        $sKey = $regServices.OpenSubKey($subName)
                        if ($sKey) {
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
                                    $depMap[$subName] = ($dList -join ", ")
                                }
                            }
                            $descVal = $sKey.GetValue("Description")
                            if ($descVal -and -not [string]::IsNullOrWhiteSpace($descVal)) {
                                $descMap[$subName] = [string]$descVal
                            }
                            $imgPath = $sKey.GetValue("ImagePath")
                            if ($imgPath -and -not [string]::IsNullOrWhiteSpace($imgPath)) {
                                $binMap[$subName] = [string]$imgPath
                            }
                            $sKey.Close()
                        }
                    } catch {}
                }
                $regServices.Close()
            }
        } catch {}

        # Tier 1: Query Win32_Service (ProcessId, State, StartMode, StartName)
        $svcs = $null
        try {
            $svcs = Get-CimInstance Win32_Service -Property Name, DisplayName, ProcessId, State, StartMode, StartName, Description, PathName -ErrorAction Stop
        } catch {}

        # Tier 2: Fallback to Get-Service if CIM fails
        if (-not $svcs -or $svcs.Count -eq 0) {
            try {
                $svcs = Get-Service -ErrorAction SilentlyContinue
            } catch {}
        }

        if ($svcs -and $svcs.Count -gt 0) {
            foreach ($s in $svcs) {
                $sName = [string]$s.Name
                if ([string]::IsNullOrWhiteSpace($sName)) { $sName = [string]$s.ServiceName }
                $sDisp = [string]$s.DisplayName
                if ([string]::IsNullOrWhiteSpace($sDisp)) { $sDisp = $sName }

                $sPid = 0
                if ($s.ProcessId) {
                    $sPid = try { [int]$s.ProcessId } catch { 0 }
                }
                if ($sPid -gt 0) {
                    [void]$script:ServicePidSet.Add($sPid)
                }

                $sState = if ($s.State) { [string]$s.State } elseif ($s.Status) { [string]$s.Status } else { "Stopped" }
                $sStart = if ($s.StartMode) { [string]$s.StartMode } elseif ($s.StartType) { [string]$s.StartType } else { "Manual" }
                $sUser  = if ($s.StartName) { [string]$s.StartName } else { "LocalSystem" }
                $sDesc  = if ($s.Description) { [string]$s.Description } elseif ($descMap.ContainsKey($sName)) { $descMap[$sName] } else { "" }
                $sBin   = if ($s.PathName) { [string]$s.PathName } elseif ($binMap.ContainsKey($sName)) { $binMap[$sName] } else { "" }

                $sDep = if ($depMap.ContainsKey($sName)) { $depMap[$sName] } else { "" }
                if (-not $sDep -and $s.ServicesDependedOn) {
                    $sDep = (($s.ServicesDependedOn | Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue) -join ", ")
                }
                $sRev = if ($revMap.ContainsKey($sName)) { ($revMap[$sName] -join ", ") } else { "" }

                $svcArr.Add(@{
                    n   = $sName
                    d   = $sDisp
                    p   = $sPid
                    st  = $sState
                    sm  = $sStart
                    u   = $sUser
                    dep = $sDep
                    rev = $sRev
                    dsc = $sDesc
                    bin = $sBin
                })
            }
        } elseif ($depMap.Count -gt 0 -or $binMap.Count -gt 0) {
            # Tier 3: Registry fallback when both CIM and SCM are restricted
            try {
                $regServices = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services")
                if ($regServices) {
                    foreach ($subName in $regServices.GetSubKeyNames()) {
                        try {
                            $sKey = $regServices.OpenSubKey($subName)
                            if ($sKey) {
                                $disp = [string]$sKey.GetValue("DisplayName")
                                if (-not $disp) { $disp = $subName }
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
                                if (-not $usr) { $usr = "LocalSystem" }
                                $sDep = if ($depMap.ContainsKey($subName)) { $depMap[$subName] } else { "" }
                                $sRev = if ($revMap.ContainsKey($subName)) { ($revMap[$subName] -join ", ") } else { "" }
                                $sDesc = if ($descMap.ContainsKey($subName)) { $descMap[$subName] } else { "" }
                                $sBin = if ($binMap.ContainsKey($subName)) { $binMap[$subName] } else { "" }

                                $svcArr.Add(@{
                                    n   = $subName
                                    d   = $disp
                                    p   = 0
                                    st  = "Stopped"
                                    sm  = $sm
                                    u   = $usr
                                    dep = $sDep
                                    rev = $sRev
                                    dsc = $sDesc
                                    bin = $sBin
                                })
                                $sKey.Close()
                            }
                        } catch {}
                    }
                    $regServices.Close()
                }
            } catch {}
        }

        $script:CachedServices = $svcArr
        $servicesPayload = $svcArr
        $script:LastSvcRefresh = $nowUtc
    }

    $script:SeqNumber++
    $nowTicks = [DateTime]::UtcNow.Ticks
    $wallDeltaTicks = $nowTicks - $script:LastSnapTicks
    if ($wallDeltaTicks -le 0L) { $wallDeltaTicks = 10000000L } # 1s fallback in 100ns units
    $totalCapacityTicks = [double]($wallDeltaTicks * $script:CoreCount)

    # 2. Query SystemProcessInformation (Class 5) in a Single Kernel Transition
    $retLen = 0
    $status = [PSRPM.NativeCollectorV2]::NtQuerySystemInformation(5, $script:SysBufPtr, $script:SysBufSize, [ref]$retLen)
    while ($status -eq -1073741820) { # STATUS_INFO_LENGTH_MISMATCH (0xC0000004)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($script:SysBufPtr)
        $script:SysBufSize = [Math]::Max($script:SysBufSize * 2, $retLen + 65536)
        $script:SysBufPtr  = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($script:SysBufSize)
        $status = [PSRPM.NativeCollectorV2]::NtQuerySystemInformation(5, $script:SysBufPtr, $script:SysBufSize, [ref]$retLen)
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
    $offWsBytes   = if ($is64) { 144 } else { 112 }
    $offPrivBytes = if ($is64) { 184 } else { 132 }
    $spiSize      = if ($is64) { 256 } else { 184 }
    $stiSize      = if ($is64) { 80 }  else { 64 }
    $offThState   = if ($is64) { 68 }  else { 52 }
    $offThWait    = if ($is64) { 72 }  else { 56 }

    $offset = 0
    while ($true) {
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
            $wsBytes   = if ($is64) { [System.Runtime.InteropServices.Marshal]::ReadInt64($curPtr, $offWsBytes) } else { [long][uint32][System.Runtime.InteropServices.Marshal]::ReadInt32($curPtr, $offWsBytes) }
            $privBytes = if ($is64) { [System.Runtime.InteropServices.Marshal]::ReadInt64($curPtr, $offPrivBytes) } else { [long][uint32][System.Runtime.InteropServices.Marshal]::ReadInt32($curPtr, $offPrivBytes) }

            $totalThreads += $numThreads
            $totalHandles += $handles

            # Exact Suspended Status Detection via SYSTEM_THREAD_INFORMATION array (0ms overhead)
            $isSuspended = $false
            if ($numThreads -gt 0) {
                $allSusp = $true
                for ($t = 0; $t -lt $numThreads; $t++) {
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
            $statusFlags = if ($isSuspended) { 1 } else { 0 }

            # Delta CPU % Calculation
            $totCpuTicks = $userTime + $kernelTime
            $cpuPct = 0.0
            if ($script:ProcCpuCache.ContainsKey($compKey)) {
                $cpuDiff = $totCpuTicks - $script:ProcCpuCache[$compKey]
                if ($cpuDiff -gt 0L) {
                    $cpuPct = [Math]::Round(($cpuDiff / $totalCapacityTicks) * 100.0, 2)
                    if ($cpuPct -gt 100.0) { $cpuPct = 100.0 }
                }
            }
            $script:ProcCpuCache[$compKey] = $totCpuTicks
            $procCpuSum += $cpuPct

            # 3. Static Metadata Enrichment (Executed ONLY ONCE when a new PID+CreateTime spawns)
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

                # Open PROCESS_QUERY_LIMITED_INFORMATION (0x1000) once for this new PID
                if ($pidVal -gt 4) {
                    $hProc = [PSRPM.NativeCollectorV2]::OpenProcess(0x1000, 0, $pidVal)
                    if ($hProc -ne [IntPtr]::Zero) {
                        try {
                            # A. Executable Path via QueryFullProcessImageNameW
                            $script:ExePathSb.Length = 0
                            $cap = $script:ExePathSb.Capacity
                            if ([PSRPM.NativeCollectorV2]::QueryFullProcessImageNameW($hProc, 0, $script:ExePathSb, [ref]$cap) -ne 0) {
                                $exePath = $script:ExePathSb.ToString()
                            }

                            # B. Command Line via NtQueryInformationProcess(ProcessCommandLineInformation = 60)
                            $cmdRet = 0
                            if ([PSRPM.NativeCollectorV2]::NtQueryInformationProcess($hProc, 60, $script:ScratchBufPtr, 8192, [ref]$cmdRet) -eq 0) {
                                $cLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($script:ScratchBufPtr, 0)
                                $cPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($script:ScratchBufPtr, $script:PtrSize)
                                if ($cPtr -ne [IntPtr]::Zero -and $cLen -gt 0) {
                                    $cmdLine = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($cPtr, [int]($cLen / 2))
                                }
                            }

                            # C. Architecture via IsWow64Process
                            if ($script:Is64BitOS) {
                                $wow64 = 0
                                if ([PSRPM.NativeCollectorV2]::IsWow64Process($hProc, [ref]$wow64) -ne 0 -and $wow64 -ne 0) {
                                    $archStr = "x86"
                                }
                            }

                            # D. User Account via OpenProcessToken + SidCache (Zero WMI GetOwner)
                            $hTok = [IntPtr]::Zero
                            if ([PSRPM.NativeCollectorV2]::OpenProcessToken($hProc, 0x0008, [ref]$hTok) -ne 0) {
                                try {
                                    $tokRet = 0
                                    if ([PSRPM.NativeCollectorV2]::GetTokenInformation($hTok, 1, $script:ScratchBufPtr, 256, [ref]$tokRet) -ne 0) {
                                        $sidPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($script:ScratchBufPtr, 0)
                                        $sidObj = [System.Security.Principal.SecurityIdentifier]::new($sidPtr)
                                        $sidVal = $sidObj.Value
                                        if ($script:SidCache.ContainsKey($sidVal)) {
                                            $userStr = $script:SidCache[$sidVal]
                                        } else {
                                            try {
                                                $userStr = $sidObj.Translate([System.Security.Principal.NTAccount]).Value
                                            } catch {
                                                $userStr = $sidVal
                                            }
                                            $script:SidCache[$sidVal] = $userStr
                                        }
                                    }
                                } finally {
                                    [void][PSRPM.NativeCollectorV2]::CloseHandle($hTok)
                                }
                            }
                        } finally {
                            [void][PSRPM.NativeCollectorV2]::CloseHandle($hProc)
                        }
                    }
                }

                # E. FileVersionInfo (Cached per Unique Executable Path)
                if ($exePath -ne "N/A") {
                    $pathKey = $exePath.ToLowerInvariant()
                    if ($script:FileMetaCache.ContainsKey($pathKey)) {
                        $fMeta   = $script:FileMetaCache[$pathKey]
                        $descStr = $fMeta.d
                        $compStr = $fMeta.c
                    } else {
                        try {
                            if ([System.IO.File]::Exists($exePath)) {
                                $fvi     = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)
                                $descStr = [string]$fvi.FileDescription
                                $compStr = [string]$fvi.CompanyName
                            }
                        } catch {}
                        $script:FileMetaCache[$pathKey] = @{ d = $descStr; c = $compStr }
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
            }

            # Emit Static Metadata ONLY if not yet sent to Host
            if (-not $script:SentMetaKeys.Contains($compKey)) {
                [void]$script:SentMetaKeys.Add($compKey)
                $m = $script:ProcMetaCache[$compKey]
                $newMetaList.Add($m)
            }

            # 4. Differential Dynamic State Comparison
            # Only emit dynamic row if CPU, WorkingSet (>4KB), PrivateBytes (>4KB), Threads, Handles, or Status changed
            $emitDyn = $true
            if ($script:LastDynState.ContainsKey($compKey)) {
                $prev = $script:LastDynState[$compKey]
                if ($prev[0] -eq $cpuPct -and
                    [Math]::Abs($wsBytes - $prev[1]) -lt 4096L -and
                    [Math]::Abs($privBytes - $prev[2]) -lt 4096L -and
                    $prev[3] -eq $numThreads -and
                    $prev[4] -eq $handles -and
                    $prev[5] -eq $statusFlags) {
                    $emitDyn = $false
                }
            }
            if ($emitDyn) {
                $script:LastDynState[$compKey] = @($cpuPct, $wsBytes, $privBytes, $numThreads, $handles, $statusFlags)
                $cpuStr = $cpuPct.ToString([System.Globalization.CultureInfo]::InvariantCulture)
                $dynDeltaList.Add("[$pidVal,$cpuStr,$wsBytes,$privBytes,$numThreads,$handles,$statusFlags]")
            }
        }

        if ($nextOffset -eq 0) { break }
        $offset += $nextOffset
    }

    # 5. Reclaim Dead Process Keys & Build Dead PIDs List
    $deadPids = [System.Collections.Generic.List[int]]::new()
    $staleKeys = @($script:ProcCpuCache.Keys | Where-Object { -not $currKeys.Contains($_) })
    foreach ($sk in $staleKeys) {
        $script:ProcCpuCache.Remove($sk)
        $script:ProcMetaCache.Remove($sk)
        $script:LastDynState.Remove($sk)
        [void]$script:SentMetaKeys.Remove($sk)
    }
    $stalePids = @($script:ActivePidToKey.Keys | Where-Object { -not $currPids.Contains($_) })
    foreach ($sp in $stalePids) {
        $script:ActivePidToKey.Remove($sp)
        $deadPids.Add($sp)
    }

    # 6. Zero-WMI System Memory, Kernel Performance & Per-Core CPU Calculation (< 0.02 ms)
    $gmsArgs = [object[]]@($script:MemStatInst)
    [void]$script:GmsMethod.Invoke($null, $gmsArgs)
    $msOut         = $gmsArgs[0]
    $ramTotalMB    = [Math]::Round([long]$script:F_TotalPhys.GetValue($msOut) / 1MB)
    $ramAvailMB    = [Math]::Round([long]$script:F_AvailPhys.GetValue($msOut) / 1MB)
    $ramUsedMB     = $ramTotalMB - $ramAvailMB
    $commitLimitMB = [Math]::Round([long]$script:F_TotalPage.GetValue($msOut) / 1MB)
    $commitUsedMB  = $commitLimitMB - [Math]::Round([long]$script:F_AvailPage.GetValue($msOut) / 1MB)

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
    if ($sppiLen -le 8192 -and [PSRPM.NativeCollectorV2]::NtQuerySystemInformation(8, $script:ScratchBufPtr, $sppiLen, [ref]$sppiRet) -eq 0) {
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
    $spi2Ret = 0
    if ([PSRPM.NativeCollectorV2]::NtQuerySystemInformation(2, $script:ScratchBufPtr, 512, [ref]$spi2Ret) -eq 0 -and $spi2Ret -ge 312) {
        $curIoR = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 8)
        $curIoW = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 16)
        $curIoO = [System.Runtime.InteropServices.Marshal]::ReadInt64($script:ScratchBufPtr, 24)
        $curPf  = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 60)  -band 0xFFFFFFFFL)
        $curPr  = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 80)  -band 0xFFFFFFFFL)
        $curPfw = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 96)  -band 0xFFFFFFFFL)
        $curMfw = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 104) -band 0xFFFFFFFFL)
        $curCs  = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 296) -band 0xFFFFFFFFL)
        $curSc  = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($script:ScratchBufPtr, 308) -band 0xFFFFFFFFL)

        if ($script:HasKernelBaseline) {
            if ($curIoR -ge $script:LastIoReadBytes)    { $ioReadDelta  = $curIoR - $script:LastIoReadBytes }
            if ($curIoW -ge $script:LastIoWriteBytes)   { $ioWriteDelta = $curIoW - $script:LastIoWriteBytes }
            if ($curIoO -ge $script:LastIoOtherBytes)   { $ioOtherDelta = $curIoO - $script:LastIoOtherBytes }
            if ($curPf  -ge $script:LastPageFaults)     { $pfDelta      = $curPf  - $script:LastPageFaults }
            if ($curPr  -ge $script:LastPageReads)      { $prDelta      = $curPr  - $script:LastPageReads }
            if ($curPfw -ge $script:LastPageFileWrites) { $pfwDelta     = $curPfw - $script:LastPageFileWrites }
            if ($curMfw -ge $script:LastMappedWrites)   { $mfwDelta     = $curMfw - $script:LastMappedWrites }
            if ($curCs  -ge $script:LastCtxSwitches)    { $csDelta      = $curCs  - $script:LastCtxSwitches }
            if ($curSc  -ge $script:LastSysCalls)       { $scDelta      = $curSc  - $script:LastSysCalls }
        }

        $script:LastIoReadBytes    = $curIoR
        $script:LastIoWriteBytes   = $curIoW
        $script:LastIoOtherBytes   = $curIoO
        $script:LastPageFaults     = $curPf
        $script:LastPageReads      = $curPr
        $script:LastPageFileWrites = $curPfw
        $script:LastMappedWrites   = $curMfw
        $script:LastCtxSwitches    = $curCs
        $script:LastSysCalls       = $curSc
    }
    $script:HasKernelBaseline = $true

    # C. psapi.dll!GetPerformanceInfo (Exact KB Commit Charge, Physical Cache & Kernel Pool Counters)
    $commitCurKB      = $commitUsedMB * 1024L
    $commitLimKB      = $commitLimitMB * 1024L
    $commitPeakKB     = $commitCurKB
    $physTotalKB      = $ramTotalMB * 1024L
    $physAvailKB      = $ramAvailMB * 1024L
    $sysCacheKB       = 0L
    $kernelPagedKB    = 0L
    $kernelNonPagedKB = 0L

    $perfCb = if ($is64) { 104 } else { 56 }
    [System.Runtime.InteropServices.Marshal]::WriteInt32($script:ScratchBufPtr, 0, $perfCb)
    if ([PSRPM.NativeCollectorV2]::GetPerformanceInfo($script:ScratchBufPtr, [uint32]$perfCb) -ne 0) {
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
    }

    $script:LastSnapTicks = $nowTicks

    # 7. Fast Compact JSON Construction + GZip Compression
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
    $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $jss.MaxJsonLength = 10485760

    $sysCpuStr  = $systemCpu.ToString($inv)
    $kernCpuStr = $kernelCpu.ToString($inv)
    $isFullNum  = if ($script:SeqNumber -eq 1 -or $ForceFullSync) { 1 } else { 0 }
    $hwJson     = if ($isFullNum -eq 1) { $jss.Serialize($script:CachedHwInfo) } else { 'null' }

    $sb = [System.Text.StringBuilder]::new(8192)
    [void]$sb.Append('{"seq":').Append($script:SeqNumber)
    [void]$sb.Append(',"full":').Append($isFullNum)
    [void]$sb.Append(',"sys":[').Append("$sysCpuStr,$ramUsedMB,$ramTotalMB,$totalProcs,$totalThreads,$totalHandles,$commitUsedMB,$commitLimitMB,$kernCpuStr,$commitCurKB,$commitLimKB,$commitPeakKB,$physTotalKB,$physAvailKB,$sysCacheKB,$kernelPagedKB,$kernelNonPagedKB,$pfDelta,$prDelta,$pfwDelta,$mfwDelta,$csDelta,$intrDelta,$scDelta,$ioReadDelta,$ioWriteDelta,$ioOtherDelta").Append(']')
    [void]$sb.Append(',"cores":[').Append(($coreTuples -join ',')).Append(']')
    [void]$sb.Append(',"hw":').Append($hwJson)
    [void]$sb.Append(',"dead":[').Append(($deadPids -join ',')).Append(']')
    [void]$sb.Append(',"meta":').Append($jss.Serialize($newMetaList))
    [void]$sb.Append(',"svc":').Append($(if ($null -ne $servicesPayload) { $jss.Serialize($servicesPayload) } else { 'null' }))
    [void]$sb.Append(',"dyn":[').Append(($dynDeltaList -join ',')).Append(']}')

    $rawBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $ms = [System.IO.MemoryStream]::new()
    $gs = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
    $gs.Write($rawBytes, 0, $rawBytes.Length)
    $gs.Close()
    return "GZIP:" + [Convert]::ToBase64String($ms.ToArray())
}
