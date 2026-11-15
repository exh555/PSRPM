# Requires -Version 5.1
# PSRPM On-Demand Deep Process Inspector
# Zero Monitoring Overhead - Executed Only When Inspecting a Specific PID
# Supports Lazy Tab-Activated Modes:
#   - "Core"    : Image, PEB, Performance/IO/GUI, Services, TCP/UDP (< 20 ms, < 2 KB wire size)
#   - "Modules" : On-Demand Loaded DLLs via EnumProcessModulesEx + Process.Modules fallback
#   - "Handles" : On-Demand Open Kernel Handles via NtQueryInformationProcess(51) + DuplicateHandle
#   - "All"     : Full inspection (used by automated test suite)

$script:PSRPMDeepInspectorScriptBlock = {
    param(
        [int]$TargetPid,
        [bool]$VerifySignature = $false,
        [string]$InspectMode = "Core",
        [string]$Query = ""
    )

    if (-not ('PSRPM.NativeInspectorV3' -as [type])) {
        $dynAsm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
            [System.Reflection.AssemblyName]::new("PSRPMNativeInspectorV3Asm"),
            [System.Reflection.Emit.AssemblyBuilderAccess]::Run
        )
        $dynMod = $dynAsm.DefineDynamicModule("PSRPMNativeInspectorV3Mod")
        $tb = $dynMod.DefineType("PSRPM.NativeInspectorV3", [System.Reflection.TypeAttributes]"Public,Abstract,Sealed")

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

        &$addPInvoke "OpenProcess"                "kernel32.dll" ([IntPtr]) @([uint32], [int], [int])
        &$addPInvoke "CloseHandle"                "kernel32.dll" ([int])    @([IntPtr])
        &$addPInvoke "GetCurrentProcess"          "kernel32.dll" ([IntPtr]) @()
        &$addPInvoke "DuplicateHandle"            "kernel32.dll" ([int])    @([IntPtr], [IntPtr], [IntPtr], [IntPtr].MakeByRefType(), [uint32], [int], [uint32])
        &$addPInvoke "ReadProcessMemory"          "kernel32.dll" ([int])    @([IntPtr], [IntPtr], [IntPtr], [IntPtr], [IntPtr].MakeByRefType())
        &$addPInvoke "QueryProcessCycleTime"      "kernel32.dll" ([int])    @([IntPtr], [uint64].MakeByRefType())
        &$addPInvoke "QueryFullProcessImageNameW" "kernel32.dll" ([int])    @([IntPtr], [uint32], [System.Text.StringBuilder], [int].MakeByRefType())
        &$addPInvoke "GetFileType"                "kernel32.dll" ([uint32]) @([IntPtr])
        &$addPInvoke "GetFinalPathNameByHandleW"  "kernel32.dll" ([uint32]) @([IntPtr], [System.Text.StringBuilder], [uint32], [uint32])
        &$addPInvoke "GetGuiResources"            "user32.dll"   ([uint32]) @([IntPtr], [uint32])
        &$addPInvoke "NtQueryInformationProcess"  "ntdll.dll"    ([int])    @([IntPtr], [int], [IntPtr], [int], [int].MakeByRefType())
        &$addPInvoke "NtQuerySystemInformation"   "ntdll.dll"    ([int])    @([int], [IntPtr], [int], [int].MakeByRefType())
        &$addPInvoke "NtQueryObject"              "ntdll.dll"    ([int])    @([IntPtr], [int], [IntPtr], [int], [int].MakeByRefType())
        &$addPInvoke "EnumProcessModulesEx"       "psapi.dll"    ([int])    @([IntPtr], [IntPtr], [uint32], [uint32].MakeByRefType(), [uint32])
        &$addPInvoke "GetModuleFileNameExW"       "psapi.dll"    ([uint32]) @([IntPtr], [IntPtr], [System.Text.StringBuilder], [uint32])
        &$addPInvoke "GetModuleInformation"       "psapi.dll"    ([int])    @([IntPtr], [IntPtr], [IntPtr], [uint32])
        &$addPInvoke "GetExtendedTcpTable"        "iphlpapi.dll" ([uint32]) @([IntPtr], [int].MakeByRefType(), [int], [uint32], [int], [uint32])
        &$addPInvoke "GetExtendedUdpTable"        "iphlpapi.dll" ([uint32]) @([IntPtr], [int].MakeByRefType(), [int], [uint32], [int], [uint32])
        &$addPInvoke "GetOwnerModuleFromTcpEntry"  "iphlpapi.dll" ([uint32]) @([IntPtr], [int], [IntPtr], [int].MakeByRefType())
        &$addPInvoke "GetOwnerModuleFromTcp6Entry" "iphlpapi.dll" ([uint32]) @([IntPtr], [int], [IntPtr], [int].MakeByRefType())
        &$addPInvoke "GetOwnerModuleFromUdpEntry"  "iphlpapi.dll" ([uint32]) @([IntPtr], [int], [IntPtr], [int].MakeByRefType())
        &$addPInvoke "GetOwnerModuleFromUdp6Entry" "iphlpapi.dll" ([uint32]) @([IntPtr], [int], [IntPtr], [int].MakeByRefType())
        &$addPInvoke "GetPerTcpConnectionEStats"   "iphlpapi.dll" ([uint32]) @([IntPtr], [int], [IntPtr], [uint32], [uint32], [IntPtr], [uint32], [uint32], [IntPtr], [uint32], [uint32])
        &$addPInvoke "SetPerTcpConnectionEStats"   "iphlpapi.dll" ([uint32]) @([IntPtr], [int], [IntPtr], [uint32], [uint32], [uint32])
        &$addPInvoke "GetPerTcp6ConnectionEStats"  "iphlpapi.dll" ([uint32]) @([IntPtr], [int], [IntPtr], [uint32], [uint32], [IntPtr], [uint32], [uint32], [IntPtr], [uint32], [uint32])
        &$addPInvoke "SetPerTcp6ConnectionEStats"  "iphlpapi.dll" ([uint32]) @([IntPtr], [int], [IntPtr], [uint32], [uint32], [uint32])

        [void]$tb.CreateType()
    }

    if (-not $script:DllMetaCache)      { $script:DllMetaCache      = @{} }
    if (-not $script:HandleTypeCache)   { $script:HandleTypeCache   = @{} }
    if (-not $script:EnabledEStatsKeys) { $script:EnabledEStatsKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal) }
    if ($script:DllMetaCache.Count -gt 2048)      { $script:DllMetaCache.Clear() }
    if ($script:HandleTypeCache.Count -gt 512)    { $script:HandleTypeCache.Clear() }
    if ($script:EnabledEStatsKeys.Count -gt 4096) { $script:EnabledEStatsKeys.Clear() }

    $ptrSize     = [IntPtr]::Size
    $snapHdrSize = 2 * $ptrSize
    $snapEntSize = (3 * $ptrSize) + 16
    $offSnapAcc  = 3 * $ptrSize
    $offSnapTyp  = (3 * $ptrSize) + 4

    if ($InspectMode -eq "FindHandles") {
        $findResults = [System.Collections.Generic.List[Object]]::new()
        if (-not [string]::IsNullOrWhiteSpace($Query)) {
            $qClean = $Query.Trim()
            $qLower = $qClean.ToLowerInvariant()
            $qNormalized = $qLower.Replace('/', '\')

            $allProcs = [System.Diagnostics.Process]::GetProcesses()
            $currProc = [PSRPM.NativeInspectorV3]::GetCurrentProcess()
            $hBufLen  = 262144
            $hBufPtr  = [IntPtr]::Zero
            $objBuf   = [IntPtr]::Zero
            $sbPath   = [System.Text.StringBuilder]::new(1024)
            $skipTypes = @("WaitCompletionPacket", "IRTimer", "TpWorkerFactory", "IoCompletion", "EtwRegistration", "DxgkCompositionObject")

            try {
                $hBufPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($hBufLen)
                $objBuf  = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4096)
                foreach ($p in $allProcs) {
                    $pidVal = $p.Id
                    if ($pidVal -le 4) { continue }
                    $pName = $p.ProcessName

                    # Check loaded modules (DLLs)
                    $hProc = [PSRPM.NativeInspectorV3]::OpenProcess(0x0410, 0, $pidVal)
                    if ($hProc -ne [IntPtr]::Zero) {
                        try {
                            $modBufSz = 8192
                            $modBuf   = [IntPtr]::Zero
                            try {
                                $modBuf   = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($modBufSz)
                                $cbNeeded = 0
                                $enumOk   = [PSRPM.NativeInspectorV3]::EnumProcessModulesEx($hProc, $modBuf, $modBufSz, [ref]$cbNeeded, 0x03)
                                if ($enumOk -ne 0 -and $cbNeeded -gt $modBufSz -and $cbNeeded -le 262144) {
                                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($modBuf)
                                    $modBuf   = [IntPtr]::Zero
                                    $modBufSz = $cbNeeded
                                    $modBuf   = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($modBufSz)
                                    $enumOk   = [PSRPM.NativeInspectorV3]::EnumProcessModulesEx($hProc, $modBuf, $modBufSz, [ref]$cbNeeded, 0x03)
                                }
                                if ($enumOk -ne 0 -and $cbNeeded -gt 0) {
                                    $effBytes  = [Math]::Min($cbNeeded, $modBufSz)
                                    $numMods   = [int]($effBytes / $ptrSize)
                                    $sbModPath = [System.Text.StringBuilder]::new(1024)
                                    for ($mIdx = 0; $mIdx -lt $numMods; $mIdx++) {
                                        $hMod = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($modBuf, $mIdx * $ptrSize)
                                        [void]$sbModPath.Clear()
                                        if ([PSRPM.NativeInspectorV3]::GetModuleFileNameExW($hProc, $hMod, $sbModPath, 1024) -gt 0) {
                                            $mPath = $sbModPath.ToString()
                                            if ($mPath.ToLowerInvariant().Replace('/', '\').Contains($qNormalized)) {
                                                $findResults.Add(@{
                                                    ProcessName = $pName
                                                    PID         = $pidVal
                                                    Type        = "DLL"
                                                    Handle      = ("0x{0:X8}" -f $hMod.ToInt64())
                                                    Name        = $mPath
                                                })
                                            }
                                        }
                                    }
                                }
                            } finally {
                                if ($modBuf -ne [IntPtr]::Zero) {
                                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($modBuf)
                                    $modBuf = [IntPtr]::Zero
                                }
                            }
                        } finally {
                            [void][PSRPM.NativeInspectorV3]::CloseHandle($hProc)
                        }
                    }

                    # Check open kernel handles
                    $hDupProc = [PSRPM.NativeInspectorV3]::OpenProcess(0x1440, 0, $pidVal)
                    if ($hDupProc -eq [IntPtr]::Zero) {
                        $hDupProc = [PSRPM.NativeInspectorV3]::OpenProcess(0x1040, 0, $pidVal)
                    }
                    if ($hDupProc -ne [IntPtr]::Zero) {
                        try {
                            $hRetLen = 0
                            $hSt = [PSRPM.NativeInspectorV3]::NtQueryInformationProcess($hDupProc, 51, $hBufPtr, $hBufLen, [ref]$hRetLen)
                            $hAttempts = 0
                            while ($hSt -eq -1073741820 -and $hAttempts -lt 6 -and $hBufLen -lt 67108864) {
                                $hAttempts++
                                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($hBufPtr)
                                $hBufPtr = [IntPtr]::Zero
                                $hBufLen = [Math]::Min(67108864, [Math]::Max($hBufLen * 2, $hRetLen + 65536))
                                $hBufPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($hBufLen)
                                $hSt = [PSRPM.NativeInspectorV3]::NtQueryInformationProcess($hDupProc, 51, $hBufPtr, $hBufLen, [ref]$hRetLen)
                            }

                            if ($hSt -eq 0) {
                                $numHandles = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($hBufPtr, 0).ToInt64()
                                $maxScan = [Math]::Min($numHandles, 65536L)

                                for ($hIdx = 0; $hIdx -lt $maxScan; $hIdx++) {
                                    $entryOff = $snapHdrSize + ($hIdx * $snapEntSize)
                                    if (($entryOff + $snapEntSize) -gt $hBufLen) { break }

                                    $hVal = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($hBufPtr, $entryOff)
                                    $tIdx = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($hBufPtr, $entryOff + $offSnapTyp) -band 0xFFFFFFFFL)

                                    if ($script:HandleTypeCache.ContainsKey($tIdx) -and $script:HandleTypeCache[$tIdx] -in $skipTypes) {
                                        continue
                                    }

                                    $dup = [IntPtr]::Zero
                                    if ([PSRPM.NativeInspectorV3]::DuplicateHandle($hDupProc, $hVal, $currProc, [ref]$dup, 0, 0, 2) -ne 0) {
                                        try {
                                            $tName = if ($script:HandleTypeCache.ContainsKey($tIdx)) {
                                                $script:HandleTypeCache[$tIdx]
                                            } else {
                                                $tn = ""
                                                $oRet = 0
                                                if ([PSRPM.NativeInspectorV3]::NtQueryObject($dup, 2, $objBuf, 4096, [ref]$oRet) -eq 0) {
                                                    $tLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($objBuf, 0)
                                                    $tPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($objBuf, $ptrSize)
                                                    if ($tLen -gt 0 -and $tPtr -ne [IntPtr]::Zero) {
                                                        $tn = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($tPtr, [int]($tLen / 2))
                                                    }
                                                }
                                                if ($tn) { $script:HandleTypeCache[$tIdx] = $tn }
                                                $tn
                                            }

                                            if (-not $tName -or $tName -in $skipTypes) { continue }

                                            $nStr = ""
                                            if ($tName -eq "File") {
                                                # Query disk files/folders safely. Non-disk/pipe handles are skipped to prevent synchronous pipe deadlocks.
                                                $fType = [PSRPM.NativeInspectorV3]::GetFileType($dup)
                                                if ($fType -eq 1) {
                                                    [void]$sbPath.Clear()
                                                    $fLen = [PSRPM.NativeInspectorV3]::GetFinalPathNameByHandleW($dup, $sbPath, 1024, 0)
                                                    if ($fLen -gt 0) {
                                                        $nStr = $sbPath.ToString() -replace '^\\\\\?\\UNC\\', '\\' -replace '^\\\\\?\\', ''
                                                    }
                                                }
                                            } else {
                                                $oRet = 0
                                                if ([PSRPM.NativeInspectorV3]::NtQueryObject($dup, 1, $objBuf, 4096, [ref]$oRet) -eq 0) {
                                                    $nLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($objBuf, 0)
                                                    $nPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($objBuf, $ptrSize)
                                                    if ($nLen -gt 0 -and $nPtr -ne [IntPtr]::Zero) {
                                                        $nStr = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($nPtr, [int]($nLen / 2))
                                                    }
                                                }
                                            }

                                            if ($nStr -and $nStr.ToLowerInvariant().Replace('/', '\').Contains($qNormalized)) {
                                                $findResults.Add(@{
                                                    ProcessName = $pName
                                                    PID         = $pidVal
                                                    Type        = $tName
                                                    Handle      = ("0x{0:X4}" -f $hVal.ToInt64())
                                                    Name        = $nStr
                                                })
                                            }
                                        } finally {
                                            [void][PSRPM.NativeInspectorV3]::CloseHandle($dup)
                                        }
                                    }
                                }
                            }
                        } finally {
                            [void][PSRPM.NativeInspectorV3]::CloseHandle($hDupProc)
                        }
                    }

                    if ($findResults.Count -ge 1000) { break }
                }
            } finally {
                if ($allProcs) {
                    foreach ($pr in $allProcs) { try { $pr.Dispose() } catch {} }
                }
                if ($hBufPtr -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($hBufPtr)
                    $hBufPtr = [IntPtr]::Zero
                }
                if ($objBuf -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($objBuf)
                    $objBuf = [IntPtr]::Zero
                }
            }
        }

        Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
        $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
        $jss.MaxJsonLength = 10485760
        return $jss.Serialize($findResults)
    }

    # Shared Native TCP/UDP OWNER_MODULE + Per-Connection EStats Enumerator (IPv4 + IPv6, Zero OpenProcess/DNS)
    $collectSockets = {
        param([int]$filterPid, $destList)
        $includeAllFields = ($filterPid -le 0)
        $tcpStates = @("Closed", "Listen", "Syn Sent", "Syn Received", "Established", "Fin Wait 1", "Fin Wait 2", "Close Wait", "Closing", "Last Ack", "Time Wait", "Delete TCB")

        $decodePort = {
            param([int]$raw)
            $u = $raw -band 0xFFFF
            return ((($u -band 0xFF) -shl 8) -bor (($u -band 0xFF00) -shr 8))
        }

        $formatFileTime = {
            param([long]$ft)
            if ($ft -gt 0L -and $ft -lt 2650467743999999999L) {
                try {
                    $dt = [DateTime]::FromFileTime($ft)
                    return @([long]$dt.Ticks, $dt.ToString("yyyy-MM-dd HH:mm:ss"))
                } catch {}
            }
            return @([long]0L, "")
        }

        $modBufCap = 4096
        $modBuf    = [IntPtr]::Zero
        $rwBuf     = [IntPtr]::Zero
        $roBuf     = [IntPtr]::Zero
        $tcp4Row   = [IntPtr]::Zero
        $tcp6Row   = [IntPtr]::Zero
        $estatsState = @{ SetBlocked = $false }

        try {
            if ($includeAllFields) {
                $modBuf  = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($modBufCap)
                $rwBuf   = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(16)
                for ($zi = 0; $zi -lt 16; $zi += 4) { [System.Runtime.InteropServices.Marshal]::WriteInt32($rwBuf, $zi, 0) }
                [System.Runtime.InteropServices.Marshal]::WriteInt32($rwBuf, 0, 1)
                $roBuf   = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(128)
                $tcp4Row = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(20)
                $tcp6Row = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(52)
            }

            $resolveModuleName = {
                param([string]$kind, [IntPtr]$rowPtr)
                if ($modBuf -eq [IntPtr]::Zero) { return "" }
                $szNeeded = $modBufCap
                $mr = switch ($kind) {
                    "Tcp4" { [PSRPM.NativeInspectorV3]::GetOwnerModuleFromTcpEntry($rowPtr, 0, $modBuf, [ref]$szNeeded) }
                    "Tcp6" { [PSRPM.NativeInspectorV3]::GetOwnerModuleFromTcp6Entry($rowPtr, 0, $modBuf, [ref]$szNeeded) }
                    "Udp4" { [PSRPM.NativeInspectorV3]::GetOwnerModuleFromUdpEntry($rowPtr, 0, $modBuf, [ref]$szNeeded) }
                    "Udp6" { [PSRPM.NativeInspectorV3]::GetOwnerModuleFromUdp6Entry($rowPtr, 0, $modBuf, [ref]$szNeeded) }
                    default { 87 }
                }
                if ($mr -eq 0) {
                    $pName = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($modBuf, 0)
                    if ($pName -ne [IntPtr]::Zero) {
                        $mStr = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($pName)
                        if ($mStr) { return $mStr }
                    }
                }
                return ""
            }

            $queryTcpEStats = {
                param([bool]$isV6, [IntPtr]$rowPtr, [string]$eKey)
                $outVals = @(0L, 0L, 0L, 0L) # SentPackets, RecvPackets, SentBytes, RecvBytes
                if ($isV6) {
                    [System.Runtime.InteropServices.Marshal]::WriteInt32($tcp6Row, 0, [System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 48))
                    for ($k = 0; $k -lt 48; $k += 4) {
                        [System.Runtime.InteropServices.Marshal]::WriteInt32($tcp6Row, 4 + $k, [System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, $k))
                    }
                    if (-not $estatsState.SetBlocked -and -not $script:EnabledEStatsKeys.Contains($eKey)) {
                        $sr = [PSRPM.NativeInspectorV3]::SetPerTcp6ConnectionEStats($tcp6Row, 1, $rwBuf, 0, 1, 0)
                        if ($sr -eq 0) {
                            [void]$script:EnabledEStatsKeys.Add($eKey)
                        } elseif ($sr -eq 5) {
                            $estatsState.SetBlocked = $true
                        }
                    }
                    $gr = [PSRPM.NativeInspectorV3]::GetPerTcp6ConnectionEStats($tcp6Row, 1, $rwBuf, 0, 1, [IntPtr]::Zero, 0, 0, $roBuf, 0, 96)
                } else {
                    for ($k = 0; $k -lt 20; $k += 4) {
                        [System.Runtime.InteropServices.Marshal]::WriteInt32($tcp4Row, $k, [System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, $k))
                    }
                    if (-not $estatsState.SetBlocked -and -not $script:EnabledEStatsKeys.Contains($eKey)) {
                        $sr = [PSRPM.NativeInspectorV3]::SetPerTcpConnectionEStats($tcp4Row, 1, $rwBuf, 0, 1, 0)
                        if ($sr -eq 0) {
                            [void]$script:EnabledEStatsKeys.Add($eKey)
                        } elseif ($sr -eq 5) {
                            $estatsState.SetBlocked = $true
                        }
                    }
                    $gr = [PSRPM.NativeInspectorV3]::GetPerTcpConnectionEStats($tcp4Row, 1, $rwBuf, 0, 1, [IntPtr]::Zero, 0, 0, $roBuf, 0, 96)
                }
                if ($gr -eq 0) {
                    $bOut = [System.Runtime.InteropServices.Marshal]::ReadInt64($roBuf, 0)
                    $sOut = [System.Runtime.InteropServices.Marshal]::ReadInt64($roBuf, 8)
                    $bIn  = [System.Runtime.InteropServices.Marshal]::ReadInt64($roBuf, 16)
                    $sIn  = [System.Runtime.InteropServices.Marshal]::ReadInt64($roBuf, 24)
                    $outVals[0] = if ($sOut -gt 0L) { $sOut } else { 0L }
                    $outVals[1] = if ($sIn  -gt 0L) { $sIn }  else { 0L }
                    $outVals[2] = if ($bOut -gt 0L) { $bOut } else { 0L }
                    $outVals[3] = if ($bIn  -gt 0L) { $bIn }  else { 0L }
                }
                return $outVals
            }

            # TCP IPv4 (AF_INET = 2) and IPv6 (AF_INET6 = 23) using TCP_TABLE_OWNER_MODULE_ALL (8)
            foreach ($af in @(2, 23)) {
                $tSize = 262144
                $tPtr  = [IntPtr]::Zero
                try {
                    $tPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($tSize)
                    $tRet = [PSRPM.NativeInspectorV3]::GetExtendedTcpTable($tPtr, [ref]$tSize, 1, [uint32]$af, 8, 0)
                    $tTry = 0
                    while ($tRet -eq 122 -and $tTry -lt 4 -and $tSize -le 16777216) {
                        $tTry++
                        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($tPtr)
                        $tPtr = [IntPtr]::Zero
                        $tPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($tSize)
                        $tRet = [PSRPM.NativeInspectorV3]::GetExtendedTcpTable($tPtr, [ref]$tSize, 1, [uint32]$af, 8, 0)
                    }
                    if ($tRet -eq 0) {
                        $numTcp = [System.Runtime.InteropServices.Marshal]::ReadInt32($tPtr, 0)
                        $rowStride = if ($af -eq 2) { 160 } else { 192 }
                        if ($af -eq 2) {
                            for ($i = 0; $i -lt $numTcp; $i++) {
                                $rowOff = 8 + ($i * $rowStride)
                                if (($rowOff + $rowStride) -gt $tSize) { break }
                                $rowPtr = [IntPtr]::Add($tPtr, $rowOff)
                                $ownPid = [System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 20)
                                if ($includeAllFields -or $ownPid -eq $filterPid) {
                                    $stVal    = [System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 0)
                                    $rawLAddr = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 4) -band 0xFFFFFFFFL)
                                    $lAddr    = [System.Net.IPAddress]::new($rawLAddr).ToString()
                                    $lPort    = &$decodePort ([System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 8))
                                    $rawRAddr = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 12) -band 0xFFFFFFFFL)
                                    $rAddr    = [System.Net.IPAddress]::new($rawRAddr).ToString()
                                    $rPort    = &$decodePort ([System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 16))
                                    $stStr    = if ($stVal -ge 1 -and $stVal -le $tcpStates.Count) { $tcpStates[$stVal - 1] } else { "$stVal" }
                                    if ($includeAllFields) {
                                        $ft    = [System.Runtime.InteropServices.Marshal]::ReadInt64($rowPtr, 24)
                                        $ftRes = &$formatFileTime $ft
                                        $mName = if ($ownPid -gt 0) { &$resolveModuleName "Tcp4" $rowPtr } else { "" }
                                        $est   = if ($stVal -eq 5) {
                                            &$queryTcpEStats $false $rowPtr ("TCP4|${lAddr}:${lPort}|${rAddr}:${rPort}|${ft}")
                                        } else {
                                            @(0L, 0L, 0L, 0L)
                                        }
                                        $destList.Add(@{
                                            PID             = $ownPid
                                            Protocol        = "TCP"
                                            LocalAddress    = $lAddr
                                            LocalPort       = $lPort
                                            RemoteAddress   = $rAddr
                                            RemotePort      = $rPort
                                            LocalEndpoint   = "${lAddr}:${lPort}"
                                            RemoteEndpoint  = "${rAddr}:${rPort}"
                                            State           = $stStr
                                            CreateTimestamp = $ftRes[0]
                                            CreateTime      = $ftRes[1]
                                            ModuleName      = $mName
                                            SentPackets     = $est[0]
                                            RecvPackets     = $est[1]
                                            SentBytes       = $est[2]
                                            RecvBytes       = $est[3]
                                        })
                                    } else {
                                        $destList.Add(@{
                                            Protocol       = "TCP"
                                            LocalEndpoint  = "${lAddr}:${lPort}"
                                            RemoteEndpoint = "${rAddr}:${rPort}"
                                            State          = $stStr
                                        })
                                    }
                                }
                            }
                        } else {
                            $lBytes = [byte[]]::new(16)
                            $rBytes = [byte[]]::new(16)
                            for ($i = 0; $i -lt $numTcp; $i++) {
                                $rowOff = 8 + ($i * $rowStride)
                                if (($rowOff + $rowStride) -gt $tSize) { break }
                                $rowPtr = [IntPtr]::Add($tPtr, $rowOff)
                                $ownPid = [System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 52)
                                if ($includeAllFields -or $ownPid -eq $filterPid) {
                                    [System.Runtime.InteropServices.Marshal]::Copy($rowPtr, $lBytes, 0, 16)
                                    $lAddr = [System.Net.IPAddress]::new($lBytes).ToString()
                                    $lPort = &$decodePort ([System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 20))
                                    [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($rowPtr, 24), $rBytes, 0, 16)
                                    $rAddr = [System.Net.IPAddress]::new($rBytes).ToString()
                                    $rPort = &$decodePort ([System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 44))
                                    $stVal = [System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 48)
                                    $stStr = if ($stVal -ge 1 -and $stVal -le $tcpStates.Count) { $tcpStates[$stVal - 1] } else { "$stVal" }
                                    if ($includeAllFields) {
                                        $ft    = [System.Runtime.InteropServices.Marshal]::ReadInt64($rowPtr, 56)
                                        $ftRes = &$formatFileTime $ft
                                        $mName = if ($ownPid -gt 0) { &$resolveModuleName "Tcp6" $rowPtr } else { "" }
                                        $est   = if ($stVal -eq 5) {
                                            &$queryTcpEStats $true $rowPtr ("TCP6|${lAddr}:${lPort}|${rAddr}:${rPort}|${ft}")
                                        } else {
                                            @(0L, 0L, 0L, 0L)
                                        }
                                        $destList.Add(@{
                                            PID             = $ownPid
                                            Protocol        = "TCPv6"
                                            LocalAddress    = $lAddr
                                            LocalPort       = $lPort
                                            RemoteAddress   = $rAddr
                                            RemotePort      = $rPort
                                            LocalEndpoint   = "[${lAddr}]:${lPort}"
                                            RemoteEndpoint  = "[${rAddr}]:${rPort}"
                                            State           = $stStr
                                            CreateTimestamp = $ftRes[0]
                                            CreateTime      = $ftRes[1]
                                            ModuleName      = $mName
                                            SentPackets     = $est[0]
                                            RecvPackets     = $est[1]
                                            SentBytes       = $est[2]
                                            RecvBytes       = $est[3]
                                        })
                                    } else {
                                        $destList.Add(@{
                                            Protocol       = "TCPv6"
                                            LocalEndpoint  = "[${lAddr}]:${lPort}"
                                            RemoteEndpoint = "[${rAddr}]:${rPort}"
                                            State          = $stStr
                                        })
                                    }
                                }
                            }
                        }
                    }
                } finally {
                    if ($tPtr -ne [IntPtr]::Zero) {
                        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($tPtr)
                        $tPtr = [IntPtr]::Zero
                    }
                }
            }

            # UDP IPv4 (AF_INET = 2) and IPv6 (AF_INET6 = 23) using UDP_TABLE_OWNER_MODULE (2)
            foreach ($af in @(2, 23)) {
                $uSize = 262144
                $uPtr  = [IntPtr]::Zero
                try {
                    $uPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($uSize)
                    $uRet = [PSRPM.NativeInspectorV3]::GetExtendedUdpTable($uPtr, [ref]$uSize, 1, [uint32]$af, 2, 0)
                    $uTry = 0
                    while ($uRet -eq 122 -and $uTry -lt 4 -and $uSize -le 16777216) {
                        $uTry++
                        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($uPtr)
                        $uPtr = [IntPtr]::Zero
                        $uPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($uSize)
                        $uRet = [PSRPM.NativeInspectorV3]::GetExtendedUdpTable($uPtr, [ref]$uSize, 1, [uint32]$af, 2, 0)
                    }
                    if ($uRet -eq 0) {
                        $numUdp = [System.Runtime.InteropServices.Marshal]::ReadInt32($uPtr, 0)
                        $rowStride = if ($af -eq 2) { 160 } else { 176 }
                        if ($af -eq 2) {
                            for ($i = 0; $i -lt $numUdp; $i++) {
                                $rowOff = 8 + ($i * $rowStride)
                                if (($rowOff + $rowStride) -gt $uSize) { break }
                                $rowPtr     = [IntPtr]::Add($uPtr, $rowOff)
                                $ownPid     = [System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 8)
                                if ($includeAllFields -or $ownPid -eq $filterPid) {
                                    $rawUdpAddr = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 0) -band 0xFFFFFFFFL)
                                    $lAddr      = [System.Net.IPAddress]::new($rawUdpAddr).ToString()
                                    $lPort      = &$decodePort ([System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 4))
                                    if ($includeAllFields) {
                                        $ft    = [System.Runtime.InteropServices.Marshal]::ReadInt64($rowPtr, 16)
                                        $ftRes = &$formatFileTime $ft
                                        $mName = if ($ownPid -gt 0) { &$resolveModuleName "Udp4" $rowPtr } else { "" }
                                        $destList.Add(@{
                                            PID             = $ownPid
                                            Protocol        = "UDP"
                                            LocalAddress    = $lAddr
                                            LocalPort       = $lPort
                                            RemoteAddress   = "*"
                                            RemotePort      = 0
                                            LocalEndpoint   = "${lAddr}:${lPort}"
                                            RemoteEndpoint  = "*:*"
                                            State           = "Listening"
                                            CreateTimestamp = $ftRes[0]
                                            CreateTime      = $ftRes[1]
                                            ModuleName      = $mName
                                            SentPackets     = 0L
                                            RecvPackets     = 0L
                                            SentBytes       = 0L
                                            RecvBytes       = 0L
                                        })
                                    } else {
                                        $destList.Add(@{
                                            Protocol       = "UDP"
                                            LocalEndpoint  = "${lAddr}:${lPort}"
                                            RemoteEndpoint = "*:*"
                                            State          = "Listening"
                                        })
                                    }
                                }
                            }
                        } else {
                            $lBytes = [byte[]]::new(16)
                            for ($i = 0; $i -lt $numUdp; $i++) {
                                $rowOff = 8 + ($i * $rowStride)
                                if (($rowOff + $rowStride) -gt $uSize) { break }
                                $rowPtr = [IntPtr]::Add($uPtr, $rowOff)
                                $ownPid = [System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 24)
                                if ($includeAllFields -or $ownPid -eq $filterPid) {
                                    [System.Runtime.InteropServices.Marshal]::Copy($rowPtr, $lBytes, 0, 16)
                                    $lAddr = [System.Net.IPAddress]::new($lBytes).ToString()
                                    $lPort = &$decodePort ([System.Runtime.InteropServices.Marshal]::ReadInt32($rowPtr, 20))
                                    if ($includeAllFields) {
                                        $ft    = [System.Runtime.InteropServices.Marshal]::ReadInt64($rowPtr, 32)
                                        $ftRes = &$formatFileTime $ft
                                        $mName = if ($ownPid -gt 0) { &$resolveModuleName "Udp6" $rowPtr } else { "" }
                                        $destList.Add(@{
                                            PID             = $ownPid
                                            Protocol        = "UDPv6"
                                            LocalAddress    = $lAddr
                                            LocalPort       = $lPort
                                            RemoteAddress   = "*"
                                            RemotePort      = 0
                                            LocalEndpoint   = "[${lAddr}]:${lPort}"
                                            RemoteEndpoint  = "*:*"
                                            State           = "Listening"
                                            CreateTimestamp = $ftRes[0]
                                            CreateTime      = $ftRes[1]
                                            ModuleName      = $mName
                                            SentPackets     = 0L
                                            RecvPackets     = 0L
                                            SentBytes       = 0L
                                            RecvBytes       = 0L
                                        })
                                    } else {
                                        $destList.Add(@{
                                            Protocol       = "UDPv6"
                                            LocalEndpoint  = "[${lAddr}]:${lPort}"
                                            RemoteEndpoint = "*:*"
                                            State          = "Listening"
                                        })
                                    }
                                }
                            }
                        }
                    }
                } finally {
                    if ($uPtr -ne [IntPtr]::Zero) {
                        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($uPtr)
                        $uPtr = [IntPtr]::Zero
                    }
                }
            }
        } finally {
            if ($modBuf -ne [IntPtr]::Zero) {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($modBuf)
                $modBuf = [IntPtr]::Zero
            }
            if ($rwBuf -ne [IntPtr]::Zero) {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($rwBuf)
                $rwBuf = [IntPtr]::Zero
            }
            if ($roBuf -ne [IntPtr]::Zero) {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($roBuf)
                $roBuf = [IntPtr]::Zero
            }
            if ($tcp4Row -ne [IntPtr]::Zero) {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($tcp4Row)
                $tcp4Row = [IntPtr]::Zero
            }
            if ($tcp6Row -ne [IntPtr]::Zero) {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($tcp6Row)
                $tcp6Row = [IntPtr]::Zero
            }
        }
    }

    if ($InspectMode -eq "AllSockets") {
        $allSockets = [System.Collections.Generic.List[hashtable]]::new(256)
        &$collectSockets 0 $allSockets
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
        $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
        $jss.MaxJsonLength = 10485760
        return $jss.Serialize(@{
            Success = $true
            Count   = $allSockets.Count
            Sockets = $allSockets
        })
    }

    $runCore        = ($InspectMode -eq "Core" -or $InspectMode -eq "All")
    $runPerformance = ($InspectMode -eq "Performance" -or $runCore)
    $runModules     = ($InspectMode -eq "Modules" -or $InspectMode -eq "All")
    $runHandles     = ($InspectMode -eq "Handles" -or $InspectMode -eq "All")

    $result = @{
        PID              = $TargetPid
        InspectMode      = $InspectMode
        CurrentDirectory = "N/A"
        CommandLine      = "N/A"
        ExecutablePath   = "N/A"
        Autostart        = "n/a"
        ImageDetails     = @{
            FileDescription  = "N/A"
            CompanyName      = "N/A"
            ProductName      = "N/A"
            FileVersion      = "N/A"
            ProductVersion   = "N/A"
            BuildTime        = "N/A"
            FileSizeKB       = 0
        }
        Signature        = @{
            Status        = if ($VerifySignature) { "Unknown" } else { "NotVerified" }
            StatusMessage = if ($VerifySignature) { "Unable to verify" } else { "Click 'Verify' to check Authenticode signature" }
            Signer        = "N/A"
            Issuer        = "N/A"
            Thumbprint    = "N/A"
        }
        Performance      = @{
            UserTime       = "00:00:00.000"
            KernelTime     = "00:00:00.000"
            TotalCpuTime   = "00:00:00.000"
            Cycles         = "0"
            PrivateBytes   = "0 K"
            WorkingSet     = "0 K"
            PeakWorkingSet = "0 K"
            VirtualSize    = "0 MB"
            PageFaults     = "0"
            PagedPool      = "0 K"
            NonPagedPool   = "0 K"
            IoReadOps      = "0"
            IoWriteOps     = "0"
            IoReadBytes    = "0 K"
            IoWriteBytes   = "0 K"
            GdiHandles     = 0
            UserHandles    = 0
        }
        Modules          = [System.Collections.Generic.List[Object]]::new()
        Handles          = [System.Collections.Generic.List[Object]]::new()
        Connections      = [System.Collections.Generic.List[Object]]::new()
        Services         = [System.Collections.Generic.List[Object]]::new()
        Environment      = [System.Collections.Generic.List[Object]]::new()
    }

    # Open Process Handle with Appropriate Least-Privilege Fallbacks
    # 0x1450 = PROCESS_QUERY_LIMITED_INFORMATION (0x1000) | PROCESS_QUERY_INFORMATION (0x0400) | PROCESS_DUP_HANDLE (0x0040) | PROCESS_VM_READ (0x0010)
    $hProc = [IntPtr]::Zero
    if ($TargetPid -gt 4) {
        $hProc = [PSRPM.NativeInspectorV3]::OpenProcess(0x1450, 0, $TargetPid)
        if ($hProc -eq [IntPtr]::Zero) {
            $hProc = [PSRPM.NativeInspectorV3]::OpenProcess(0x1040, 0, $TargetPid)
        }
        if ($hProc -eq [IntPtr]::Zero) {
            $hProc = [PSRPM.NativeInspectorV3]::OpenProcess(0x1410, 0, $TargetPid)
        }
        if ($hProc -eq [IntPtr]::Zero) {
            $hProc = [PSRPM.NativeInspectorV3]::OpenProcess(0x1000, 0, $TargetPid)
        }
    }

    $buf = [IntPtr]::Zero
    $objBuf = [IntPtr]::Zero
    try {
        $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(262144)
        $objBuf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4096)
        $sbPath = [System.Text.StringBuilder]::new(1024)

        if ($runCore) {
            # 1. Resolve ExecutablePath & CommandLine from cache or live handle
            $compKey = if ($script:ActivePidToKey -and $script:ActivePidToKey.ContainsKey($TargetPid)) { $script:ActivePidToKey[$TargetPid] } else { $null }
            $cachedMeta = if ($compKey -and $script:ProcMetaCache -and $script:ProcMetaCache.ContainsKey($compKey)) { $script:ProcMetaCache[$compKey] } else { $null }
            $exePath = if ($cachedMeta -and $cachedMeta.path) { [string]$cachedMeta.path } else { "N/A" }
            $cmdLine = if ($cachedMeta -and $cachedMeta.cmd)  { [string]$cachedMeta.cmd }  else { "N/A" }

            if ($hProc -ne [IntPtr]::Zero) {
                if ($exePath -eq "N/A") {
                    $cap = $sbPath.Capacity
                    if ([PSRPM.NativeInspectorV3]::QueryFullProcessImageNameW($hProc, 0, $sbPath, [ref]$cap) -ne 0) {
                        $exePath = $sbPath.ToString()
                    }
                }
                if ($cmdLine -eq "N/A") {
                    $cmdRet = 0
                    if ([PSRPM.NativeInspectorV3]::NtQueryInformationProcess($hProc, 60, $buf, 8192, [ref]$cmdRet) -eq 0) {
                        $cLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($buf, 0)
                        $cPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf, [IntPtr]::Size)
                        if ($cPtr -ne [IntPtr]::Zero -and $cLen -gt 0) {
                            $cmdLine = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($cPtr, [int]($cLen / 2))
                        }
                    }
                }
            }

            $result.ExecutablePath = $exePath
            $result.CommandLine    = $cmdLine

            # 2. Image Details, PE Linker Build Timestamp & Optional Authenticode Signature
            if ($exePath -ne "N/A" -and [System.IO.File]::Exists($exePath)) {
                try {
                    $fi  = [System.IO.FileInfo]::new($exePath)
                    $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exePath)

                    $buildTimeStr = $fi.LastWriteTime.ToString("ddd MMM dd HH:mm:ss yyyy")
                    try {
                        $fs = [System.IO.File]::Open($exePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        try {
                            $hdr = [byte[]]::new(1024)
                            $read = $fs.Read($hdr, 0, 1024)
                            if ($read -ge 64 -and $hdr[0] -eq 0x4D -and $hdr[1] -eq 0x5A) {
                                $peOffset = [BitConverter]::ToInt32($hdr, 60)
                                if ($peOffset -gt 0 -and ($peOffset + 12) -le $read) {
                                    $tsSeconds = ([long][BitConverter]::ToInt32($hdr, $peOffset + 8) -band 0xFFFFFFFFL)
                                    if ($tsSeconds -gt 0 -and $tsSeconds -lt 2147483647) {
                                        $dtBuild = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddSeconds($tsSeconds).ToLocalTime()
                                        $buildTimeStr = $dtBuild.ToString("ddd MMM dd HH:mm:ss yyyy")
                                    }
                                }
                            }
                        } finally {
                            $fs.Close()
                        }
                    } catch {}

                    $result.ImageDetails = @{
                        FileDescription  = if ($fvi.FileDescription) { [string]$fvi.FileDescription } else { $fi.Name }
                        CompanyName      = if ($fvi.CompanyName)     { [string]$fvi.CompanyName }     else { "N/A" }
                        ProductName      = if ($fvi.ProductName)     { [string]$fvi.ProductName }     else { "N/A" }
                        FileVersion      = if ($fvi.FileVersion)     { [string]$fvi.FileVersion }     else { "N/A" }
                        ProductVersion   = if ($fvi.ProductVersion)  { [string]$fvi.ProductVersion }  else { "N/A" }
                        BuildTime        = $buildTimeStr
                        FileSizeKB       = [Math]::Round($fi.Length / 1KB, 1)
                    }
                } catch {}

                if ($VerifySignature) {
                    try {
                        $sig = Get-AuthenticodeSignature -FilePath $exePath -ErrorAction SilentlyContinue
                        if ($sig) {
                            $signerName = if ($sig.SignerCertificate) {
                                if ($sig.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)) {
                                    $sig.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
                                } else {
                                    $sig.SignerCertificate.Subject
                                }
                            } else { "Not Signed" }

                            $result.Signature = @{
                                Status        = [string]$sig.Status
                                StatusMessage = [string]$sig.StatusMessage
                                Signer        = $signerName
                                Issuer        = if ($sig.SignerCertificate) { $sig.SignerCertificate.Issuer } else { "N/A" }
                                Thumbprint    = if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { "N/A" }
                            }
                        }
                    } catch {}
                }
            }

            # 3. Hosted Services & Autostart Detection (Reads shared AppDomain service list first for 0ms WMI overhead)
            $autostartHits = [System.Collections.Generic.List[string]]::new()
            try {
                $sharedSvcs = $null
                try { $sharedSvcs = [AppDomain]::CurrentDomain.GetData("PSRPM_CachedServices") } catch {}
                if ($null -eq $sharedSvcs) { $sharedSvcs = $script:CachedServices }

                if ($null -ne $sharedSvcs) {
                    foreach ($cs in $sharedSvcs) {
                        if ($cs.p -eq $TargetPid) {
                            $result.Services.Add(@{
                                Name        = [string]$cs.n
                                DisplayName = [string]$cs.d
                                Status      = [string]$cs.st
                                StartType   = [string]$cs.sm
                                User        = [string]$cs.u
                            })
                            $autostartHits.Add("HKLM\SYSTEM\CurrentControlSet\Services\$($cs.n)")
                        }
                    }
                } else {
                    $hostedSvcs = Get-CimInstance Win32_Service -Filter "ProcessId=$TargetPid" -Property Name, DisplayName, State, StartMode, StartName, PathName -ErrorAction SilentlyContinue
                    if ($hostedSvcs) {
                        foreach ($hs in $hostedSvcs) {
                            $result.Services.Add(@{
                                Name        = [string]$hs.Name
                                DisplayName = [string]$hs.DisplayName
                                Status      = [string]$hs.State
                                StartType   = [string]$hs.StartMode
                                User        = if ($hs.StartName) { [string]$hs.StartName } else { "LocalSystem" }
                            })
                            $autostartHits.Add("HKLM\SYSTEM\CurrentControlSet\Services\$($hs.Name)")
                        }
                    }
                }
                if ($autostartHits.Count -eq 0 -and $exePath -ne "N/A") {
                    $leafName = [System.IO.Path]::GetFileName($exePath)
                    $runSubKeys = @(
                        "Software\Microsoft\Windows\CurrentVersion\Run",
                        "Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
                    )
                    foreach ($rSub in $runSubKeys) {
                        try {
                            $rk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($rSub)
                            if ($rk) {
                                foreach ($vName in $rk.GetValueNames()) {
                                    $vStr = [string]$rk.GetValue($vName)
                                    if ($vStr -and $vStr.IndexOf($leafName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                                        $autostartHits.Add("HKLM\$rSub\$vName")
                                    }
                                }
                                $rk.Close()
                            }
                        } catch {}
                    }
                    try {
                        $hkuRoot = [Microsoft.Win32.Registry]::Users
                        if ($hkuRoot) {
                            foreach ($sidName in $hkuRoot.GetSubKeyNames()) {
                                if ($sidName -match '_Classes$' -or $sidName -eq '.DEFAULT') { continue }
                                foreach ($rSub in $runSubKeys) {
                                    try {
                                        $uk = $hkuRoot.OpenSubKey("$sidName\$rSub")
                                        if ($uk) {
                                            foreach ($vName in $uk.GetValueNames()) {
                                                $vStr = [string]$uk.GetValue($vName)
                                                if ($vStr -and $vStr.IndexOf($leafName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                                                    $autostartHits.Add("HKU\$sidName\$rSub\$vName")
                                                }
                                            }
                                            $uk.Close()
                                        }
                                    } catch {}
                                }
                            }
                        }
                    } catch {}
                }
            } catch {}
            if ($autostartHits.Count -gt 0) { $result.Autostart = ($autostartHits -join "; ") }

            # 4. PEB CurrentDirectory & Environment, Cycles & GUI Handles
            if ($hProc -ne [IntPtr]::Zero) {
                $retLen = 0
                if ([IntPtr]::Size -eq 8 -and [PSRPM.NativeInspectorV3]::NtQueryInformationProcess($hProc, 0, $buf, 48, [ref]$retLen) -eq 0) {
                    $pebAddr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf, 8)
                    $bytesRead = [IntPtr]::Zero
                    if ($pebAddr -ne [IntPtr]::Zero -and [PSRPM.NativeInspectorV3]::ReadProcessMemory($hProc, [IntPtr]::Add($pebAddr, 0x20), $buf, [IntPtr]8, [ref]$bytesRead) -ne 0) {
                        $procParams = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf, 0)
                        if ($procParams -ne [IntPtr]::Zero) {
                            # Read CurrentDirectory UNICODE_STRING at +0x38
                            if ([PSRPM.NativeInspectorV3]::ReadProcessMemory($hProc, [IntPtr]::Add($procParams, 0x38), $buf, [IntPtr]16, [ref]$bytesRead) -ne 0) {
                                $cdLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($buf, 0)
                                $cdPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf, 8)
                                if ($cdLen -gt 0 -and $cdLen -le 2048 -and [PSRPM.NativeInspectorV3]::ReadProcessMemory($hProc, $cdPtr, $buf, [IntPtr]$cdLen, [ref]$bytesRead) -ne 0) {
                                    $result.CurrentDirectory = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($buf, [int]($cdLen / 2))
                                }
                            }
                            # Read Environment Pointer at +0x80 and EnvironmentSize at +0x3F0
                            $envPtr  = [IntPtr]::Zero
                            $envSize = 0L
                            if ([PSRPM.NativeInspectorV3]::ReadProcessMemory($hProc, [IntPtr]::Add($procParams, 0x80), $buf, [IntPtr]8, [ref]$bytesRead) -ne 0) {
                                $envPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf, 0)
                            }
                            if ([PSRPM.NativeInspectorV3]::ReadProcessMemory($hProc, [IntPtr]::Add($procParams, 0x3F0), $buf, [IntPtr]8, [ref]$bytesRead) -ne 0) {
                                $envSize = [System.Runtime.InteropServices.Marshal]::ReadInt64($buf, 0)
                            }
                            if ($envPtr -ne [IntPtr]::Zero -and $envSize -gt 0 -and $envSize -le 65536) {
                                if ([PSRPM.NativeInspectorV3]::ReadProcessMemory($hProc, $envPtr, $buf, [IntPtr]$envSize, [ref]$bytesRead) -ne 0) {
                                    $readLen = [Math]::Min([int]$bytesRead.ToInt64(), [int]$envSize)
                                    $charCount = [int]([Math]::Floor($readLen / 2))
                                    if ($charCount -gt 0) {
                                        $envRawStr = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($buf, $charCount)
                                        $pos = 0
                                        while ($pos -lt $envRawStr.Length) {
                                            $nulIdx = $envRawStr.IndexOf([char]0, $pos)
                                            $entry = if ($nulIdx -ge 0) { $envRawStr.Substring($pos, $nulIdx - $pos) } else { $envRawStr.Substring($pos) }
                                            if ([string]::IsNullOrEmpty($entry)) { break }
                                            $eqIdx = $entry.IndexOf('=')
                                            if ($eqIdx -gt 0) {
                                                $result.Environment.Add(@{
                                                    Key   = $entry.Substring(0, $eqIdx)
                                                    Value = $entry.Substring($eqIdx + 1)
                                                })
                                            }
                                            if ($nulIdx -lt 0) { break }
                                            $pos = $nulIdx + 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } # end if ($runCore)

        # Section: CPU Cycles, GUI Handles & Detailed Performance / I/O Counters
        if ($runPerformance) {
            if ($hProc -ne [IntPtr]::Zero) {
                [uint64]$cycles = 0
                [void][PSRPM.NativeInspectorV3]::QueryProcessCycleTime($hProc, [ref]$cycles)
                $gdiHandles  = [PSRPM.NativeInspectorV3]::GetGuiResources($hProc, 0)
                $userHandles = [PSRPM.NativeInspectorV3]::GetGuiResources($hProc, 1)
                $result.Performance["Cycles"]      = $cycles.ToString("N0")
                $result.Performance["GdiHandles"]  = $gdiHandles
                $result.Performance["UserHandles"] = $userHandles
            }

            # 5. Extract Detailed Performance & I/O Counters from SystemProcessInformation
            $sysLen = 524288
            $sysPtr = [IntPtr]::Zero
            try {
                $sysPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($sysLen)
                $ret = 0
                $st = [PSRPM.NativeInspectorV3]::NtQuerySystemInformation(5, $sysPtr, $sysLen, [ref]$ret)
                $sysAttempts = 0
                while ($st -eq -1073741820 -and $sysAttempts -lt 6 -and $sysLen -lt 67108864) {
                    $sysAttempts++
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sysPtr)
                    $sysPtr = [IntPtr]::Zero
                    $sysLen = [Math]::Min(67108864, [Math]::Max($sysLen * 2, $ret + 65536))
                    $sysPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($sysLen)
                    $st = [PSRPM.NativeInspectorV3]::NtQuerySystemInformation(5, $sysPtr, $sysLen, [ref]$ret)
                }
                if ($st -eq 0) {
                    $is64     = ([IntPtr]::Size -eq 8)
                    $offPid   = if ($is64) { 80 } else { 68 }
                    $spiSize  = if ($is64) { 256 } else { 184 }
                    $validLen = if ($ret -gt 0 -and $ret -le $sysLen) { $ret } else { $sysLen }

                    $off = 0
                    while (($off + $spiSize) -le $validLen) {
                        $cPtr   = [IntPtr]::Add($sysPtr, $off)
                        $nxt    = [System.Runtime.InteropServices.Marshal]::ReadInt32($cPtr, 0)
                        if ($nxt -lt 0) { break }
                        $pIdCur = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($cPtr, $offPid).ToInt32()
                        if ($pIdCur -eq $TargetPid) {
                            $formatCpuTime = {
                                param([TimeSpan]$ts)
                                if ($ts.Ticks -lt 0L) { $ts = [TimeSpan]::Zero }
                                $hrs = [long][Math]::Floor($ts.TotalHours)
                                return ("{0:D2}:{1:D2}:{2:D2}.{3:D3}" -f $hrs, $ts.Minutes, $ts.Seconds, $ts.Milliseconds)
                            }
                            $uTime = [TimeSpan]::FromTicks([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 40))
                            $kTime = [TimeSpan]::FromTicks([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 48))
                            $result.Performance["UserTime"]     = &$formatCpuTime $uTime
                            $result.Performance["KernelTime"]   = &$formatCpuTime $kTime
                            $result.Performance["TotalCpuTime"] = &$formatCpuTime ($uTime + $kTime)

                            if ($is64) {
                                $result.Performance["PeakWorkingSet"] = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 136) / 1KB, 0).ToString('N0')) K"
                                $result.Performance["WorkingSet"]     = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 144) / 1KB, 0).ToString('N0')) K"
                                $result.Performance["PrivateBytes"]   = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 184) / 1KB, 0).ToString('N0')) K"
                                $result.Performance["VirtualSize"]    = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 120) / 1MB, 1)) MB"
                                $result.Performance["PageFaults"]     = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($cPtr, 128) -band 0xFFFFFFFFL).ToString("N0")
                                $result.Performance["PagedPool"]      = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 160) / 1KB, 1)) K"
                                $result.Performance["NonPagedPool"]   = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 176) / 1KB, 1)) K"
                                $result.Performance["IoReadOps"]      = [System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 208).ToString("N0")
                                $result.Performance["IoWriteOps"]     = [System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 216).ToString("N0")
                                $result.Performance["IoReadBytes"]    = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 232) / 1KB, 1).ToString('N1')) K"
                                $result.Performance["IoWriteBytes"]   = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 240) / 1KB, 1).ToString('N1')) K"
                            } else {
                                $vSize = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($cPtr, 92)  -band 0xFFFFFFFFL)
                                $pFlts = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($cPtr, 96)  -band 0xFFFFFFFFL)
                                $pWs   = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($cPtr, 100) -band 0xFFFFFFFFL)
                                $ws    = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($cPtr, 104) -band 0xFFFFFFFFL)
                                $pp    = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($cPtr, 112) -band 0xFFFFFFFFL)
                                $npp   = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($cPtr, 120) -band 0xFFFFFFFFL)
                                $pb    = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($cPtr, 132) -band 0xFFFFFFFFL)
                                $result.Performance["PeakWorkingSet"] = "$([Math]::Round($pWs / 1KB, 0).ToString('N0')) K"
                                $result.Performance["WorkingSet"]     = "$([Math]::Round($ws / 1KB, 0).ToString('N0')) K"
                                $result.Performance["PrivateBytes"]   = "$([Math]::Round($pb / 1KB, 0).ToString('N0')) K"
                                $result.Performance["VirtualSize"]    = "$([Math]::Round($vSize / 1MB, 1)) MB"
                                $result.Performance["PageFaults"]     = $pFlts.ToString("N0")
                                $result.Performance["PagedPool"]      = "$([Math]::Round($pp / 1KB, 1)) K"
                                $result.Performance["NonPagedPool"]   = "$([Math]::Round($npp / 1KB, 1)) K"
                                $result.Performance["IoReadOps"]      = [System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 136).ToString("N0")
                                $result.Performance["IoWriteOps"]     = [System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 144).ToString("N0")
                                $result.Performance["IoReadBytes"]    = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 160) / 1KB, 1).ToString('N1')) K"
                                $result.Performance["IoWriteBytes"]   = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 168) / 1KB, 1).ToString('N1')) K"
                            }
                            break
                        }
                        if ($nxt -le 0 -or ($off + $nxt) -gt $validLen) { break }
                        $off += $nxt
                    }
                }
            } finally {
                if ($sysPtr -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sysPtr)
                    $sysPtr = [IntPtr]::Zero
                }
            }
        } # end if ($runPerformance)

        if ($runCore) {
            # 6. Fast Native TCP/UDP Connections (Shared Enumerator Filtered to $TargetPid)
            &$collectSockets $TargetPid $result.Connections
        }

        # Lazy On-Demand Section A: Loaded DLLs / Modules
        if ($runModules) {
            $hModProc = if ($TargetPid -gt 4) { [PSRPM.NativeInspectorV3]::OpenProcess(0x0410, 0, $TargetPid) } else { [IntPtr]::Zero }
            $closeModProc = ($hModProc -ne [IntPtr]::Zero)
            if ($hModProc -eq [IntPtr]::Zero) { $hModProc = $hProc }

            $modBuf      = $buf
            $modBufSize  = 65536
            $modBufAlloc = $false
            try {
                $cbNeeded = [uint32]0
                if ($hModProc -ne [IntPtr]::Zero -and [PSRPM.NativeInspectorV3]::EnumProcessModulesEx($hModProc, $modBuf, [uint32]$modBufSize, [ref]$cbNeeded, 0x03) -ne 0 -and $cbNeeded -gt 0) {
                    if ([int]$cbNeeded -gt $modBufSize) {
                        $reqModSize = [Math]::Min(262144, [int]$cbNeeded)
                        $newModBuf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($reqModSize)
                        $modBuf = $newModBuf
                        $modBufSize = $reqModSize
                        $modBufAlloc = $true
                        $cbNeeded2 = [uint32]0
                        if ([PSRPM.NativeInspectorV3]::EnumProcessModulesEx($hModProc, $modBuf, [uint32]$modBufSize, [ref]$cbNeeded2, 0x03) -ne 0 -and $cbNeeded2 -gt 0) {
                            $cbNeeded = $cbNeeded2
                        }
                    }
                    $ptrSize = [IntPtr]::Size
                    $allocSlots = [int]($modBufSize / $ptrSize)
                    $modCount = [Math]::Min([int]([Math]::Floor($cbNeeded / $ptrSize)), $allocSlots)
                    $seenModPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

                    for ($mIdx = 0; $mIdx -lt $modCount; $mIdx++) {
                        $hMod = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($modBuf, $mIdx * $ptrSize)
                        $sbPath.Length = 0
                        if ([PSRPM.NativeInspectorV3]::GetModuleFileNameExW($hModProc, $hMod, $sbPath, 1024) -gt 0) {
                            $mPath = $sbPath.ToString()
                            if (-not $seenModPaths.Add($mPath)) { continue }

                            $mName = [System.IO.Path]::GetFileName($mPath)
                            $baseAddr = "0x" + $hMod.ToInt64().ToString("X")
                            $sizeKB = "N/A"
                            $cbModInfo = if ($ptrSize -eq 8) { [uint32]24 } else { [uint32]12 }
                            if ([PSRPM.NativeInspectorV3]::GetModuleInformation($hModProc, $hMod, $objBuf, $cbModInfo) -ne 0) {
                                $imgSize = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($objBuf, $ptrSize) -band 0xFFFFFFFFL)
                                $sizeKB = "$([Math]::Round($imgSize / 1KB, 0).ToString('N0')) K"
                            }

                            $pathKey = $mPath.ToLowerInvariant()
                            $mDesc = ""
                            $mComp = ""
                            $mVer  = ""
                            if ($script:DllMetaCache.ContainsKey($pathKey)) {
                                $cachedDll = $script:DllMetaCache[$pathKey]
                                $mDesc = $cachedDll.d
                                $mComp = $cachedDll.c
                                $mVer  = $cachedDll.v
                            } else {
                                try {
                                    if ([System.IO.File]::Exists($mPath)) {
                                        $dllFvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($mPath)
                                        $mDesc  = [string]$dllFvi.FileDescription
                                        $mComp  = [string]$dllFvi.CompanyName
                                        $mVer   = [string]$dllFvi.FileVersion
                                    }
                                } catch {}
                                $script:DllMetaCache[$pathKey] = @{ d = $mDesc; c = $mComp; v = $mVer }
                            }

                            $result.Modules.Add(@{
                                Name        = $mName
                                Description = $mDesc
                                CompanyName = $mComp
                                Version     = $mVer
                                BaseAddress = $baseAddr
                                Size        = $sizeKB
                                Path        = $mPath
                            })
                        }
                    }
                }
            } finally {
                if ($modBufAlloc -and $modBuf -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($modBuf)
                    $modBuf = [IntPtr]::Zero
                }
                if ($closeModProc) { [void][PSRPM.NativeInspectorV3]::CloseHandle($hModProc) }
            }

            # Fallback to .NET Process.Modules if EnumProcessModulesEx returned 0 entries
            if ($result.Modules.Count -eq 0 -and $TargetPid -gt 4) {
                $netProc = $null
                try {
                    $netProc = [System.Diagnostics.Process]::GetProcessById($TargetPid)
                    foreach ($pm in $netProc.Modules) {
                        $mPath = [string]$pm.FileName
                        $fvi = $pm.FileVersionInfo
                        $result.Modules.Add(@{
                            Name        = [string]$pm.ModuleName
                            Description = if ($fvi) { [string]$fvi.FileDescription } else { "" }
                            CompanyName = if ($fvi) { [string]$fvi.CompanyName } else { "" }
                            Version     = if ($fvi) { [string]$fvi.FileVersion } else { "" }
                            BaseAddress = "0x" + $pm.BaseAddress.ToInt64().ToString("X")
                            Size        = "$([Math]::Round($pm.ModuleMemorySize / 1KB, 0).ToString('N0')) K"
                            Path        = $mPath
                        })
                    }
                } catch {} finally {
                    if ($netProc) { try { $netProc.Dispose() } catch {} }
                }
            }

            if ($result.Modules.Count -eq 0) {
                $result.Modules.Add(@{
                    Name        = "[Access Denied / Protected Process]"
                    Description = "Run PSRPM as Administrator to enumerate loaded DLLs for PID $TargetPid"
                    CompanyName = "N/A"
                    Version     = "N/A"
                    BaseAddress = "N/A"
                    Size        = "0 K"
                    Path        = "Protected or elevated process memory space"
                })
            }
        }

        # Lazy On-Demand Section B: Open Kernel Handles via NtQueryInformationProcess(ProcessHandleInformation = 51)
        if ($runHandles) {
            $hDupProc = if ($TargetPid -gt 4) { [PSRPM.NativeInspectorV3]::OpenProcess(0x1440, 0, $TargetPid) } else { [IntPtr]::Zero }
            if ($hDupProc -eq [IntPtr]::Zero -and $TargetPid -gt 4) {
                $hDupProc = [PSRPM.NativeInspectorV3]::OpenProcess(0x1040, 0, $TargetPid)
            }
            $closeDupProc = ($hDupProc -ne [IntPtr]::Zero)
            if ($hDupProc -eq [IntPtr]::Zero) { $hDupProc = $hProc }

            $hBufLen = 262144
            $hBufPtr = [IntPtr]::Zero
            try {
                $hBufPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($hBufLen)
                if ($hDupProc -ne [IntPtr]::Zero) {
                    $hRetLen = 0
                    $hSt = [PSRPM.NativeInspectorV3]::NtQueryInformationProcess($hDupProc, 51, $hBufPtr, $hBufLen, [ref]$hRetLen)
                    $hAttempts = 0
                    while ($hSt -eq -1073741820 -and $hAttempts -lt 6 -and $hBufLen -lt 67108864) {
                        $hAttempts++
                        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($hBufPtr)
                        $hBufPtr = [IntPtr]::Zero
                        $hBufLen = [Math]::Min(67108864, [Math]::Max($hBufLen * 2, $hRetLen + 65536))
                        $hBufPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($hBufLen)
                        $hSt = [PSRPM.NativeInspectorV3]::NtQueryInformationProcess($hDupProc, 51, $hBufPtr, $hBufLen, [ref]$hRetLen)
                    }

                    if ($hSt -eq 0) {
                        $numHandles = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($hBufPtr, 0).ToInt64()
                        $maxScan = [Math]::Min($numHandles, 65536L)
                        $currProc = [PSRPM.NativeInspectorV3]::GetCurrentProcess()
                        $sbPath = [System.Text.StringBuilder]::new(1024)
                        # Skip kernel object types that have no name or are irrelevant high-frequency objects
                        $skipTypes = @("WaitCompletionPacket", "IRTimer", "TpWorkerFactory", "IoCompletion", "EtwRegistration", "DxgkCompositionObject")

                        for ($hIdx = 0; $hIdx -lt $maxScan; $hIdx++) {
                            $entryOff = $snapHdrSize + ($hIdx * $snapEntSize)
                            if (($entryOff + $snapEntSize) -gt $hBufLen) { break }

                            $hVal = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($hBufPtr, $entryOff)
                            $acc  = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($hBufPtr, $entryOff + $offSnapAcc) -band 0xFFFFFFFFL)
                            $tIdx = ([long][System.Runtime.InteropServices.Marshal]::ReadInt32($hBufPtr, $entryOff + $offSnapTyp) -band 0xFFFFFFFFL)

                            if ($script:HandleTypeCache.ContainsKey($tIdx) -and $script:HandleTypeCache[$tIdx] -in $skipTypes) {
                                continue
                            }

                            $dup = [IntPtr]::Zero
                            if ([PSRPM.NativeInspectorV3]::DuplicateHandle($hDupProc, $hVal, $currProc, [ref]$dup, 0, 0, 2) -ne 0) {
                                try {
                                    $oRet = 0
                                    $tName = if ($script:HandleTypeCache.ContainsKey($tIdx)) {
                                        $script:HandleTypeCache[$tIdx]
                                    } else {
                                        $tn = ""
                                        if ([PSRPM.NativeInspectorV3]::NtQueryObject($dup, 2, $objBuf, 4096, [ref]$oRet) -eq 0) {
                                            $tLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($objBuf, 0)
                                            $tPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($objBuf, $ptrSize)
                                            if ($tLen -gt 0 -and $tPtr -ne [IntPtr]::Zero) {
                                                $tn = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($tPtr, [int]($tLen / 2))
                                            }
                                        }
                                        if ($tn) { $script:HandleTypeCache[$tIdx] = $tn }
                                        $tn
                                    }

                                    if (-not $tName -or $tName -in $skipTypes) { continue }

                                    $nStr = ""
                                    if ($tName -eq "File") {
                                        # Query disk files/folders safely. Non-disk/pipe handles are skipped to prevent synchronous pipe deadlocks.
                                        $fType = [PSRPM.NativeInspectorV3]::GetFileType($dup)
                                        if ($fType -eq 1) {
                                            [void]$sbPath.Clear()
                                            $fLen = [PSRPM.NativeInspectorV3]::GetFinalPathNameByHandleW($dup, $sbPath, 1024, 0)
                                            if ($fLen -gt 0) {
                                                $nStr = $sbPath.ToString() -replace '^\\\\\?\\UNC\\', '\\' -replace '^\\\\\?\\', ''
                                            }
                                        }
                                    } else {
                                        if ([PSRPM.NativeInspectorV3]::NtQueryObject($dup, 1, $objBuf, 4096, [ref]$oRet) -eq 0) {
                                            $nLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($objBuf, 0)
                                            $nPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($objBuf, $ptrSize)
                                            if ($nLen -gt 0 -and $nPtr -ne [IntPtr]::Zero) {
                                                $nStr = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($nPtr, [int]($nLen / 2))
                                            }
                                        }
                                    }

                                    if ($nStr) {
                                        $result.Handles.Add(@{
                                            Type   = $tName
                                            Name   = $nStr
                                            Handle = ("0x{0:X4}" -f $hVal.ToInt64())
                                            Access = ("0x{0:X8}" -f $acc)
                                        })
                                    }
                                } finally {
                                    [void][PSRPM.NativeInspectorV3]::CloseHandle($dup)
                                }
                            }
                        }
                    }
                }
            } finally {
                if ($hBufPtr -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($hBufPtr)
                    $hBufPtr = [IntPtr]::Zero
                }
                if ($closeDupProc) { [void][PSRPM.NativeInspectorV3]::CloseHandle($hDupProc) }
            }

            if ($result.Handles.Count -eq 0) {
                $result.Handles.Add(@{
                    Type   = "[Access Denied / Protected]"
                    Name   = "Run PSRPM as Administrator to duplicate and query kernel handles for PID $TargetPid"
                    Handle = "N/A"
                    Access = "N/A"
                })
            }
        }
    } finally {
        if ($buf -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
            $buf = [IntPtr]::Zero
        }
        if ($objBuf -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($objBuf)
            $objBuf = [IntPtr]::Zero
        }
        if ($hProc -ne [IntPtr]::Zero) { [void][PSRPM.NativeInspectorV3]::CloseHandle($hProc) }
    }

    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
    $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $jss.MaxJsonLength = 10485760
    return $jss.Serialize($result)
}
