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
        [string]$InspectMode = "Core"
    )

    if (-not ('PSRPM.NativeInspectorV2' -as [type])) {
        $dynAsm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
            [System.Reflection.AssemblyName]::new("PSRPMNativeInspectorV2Asm"),
            [System.Reflection.Emit.AssemblyBuilderAccess]::Run
        )
        $dynMod = $dynAsm.DefineDynamicModule("PSRPMNativeInspectorV2Mod")
        $tb = $dynMod.DefineType("PSRPM.NativeInspectorV2", [System.Reflection.TypeAttributes]"Public,Abstract,Sealed")

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

        [void]$tb.CreateType()
    }

    if (-not $script:DllMetaCache)    { $script:DllMetaCache    = @{} }
    if (-not $script:HandleTypeCache) { $script:HandleTypeCache = @{} }

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
        $hProc = [PSRPM.NativeInspectorV2]::OpenProcess(0x1450, 0, $TargetPid)
        if ($hProc -eq [IntPtr]::Zero) {
            $hProc = [PSRPM.NativeInspectorV2]::OpenProcess(0x1040, 0, $TargetPid)
        }
        if ($hProc -eq [IntPtr]::Zero) {
            $hProc = [PSRPM.NativeInspectorV2]::OpenProcess(0x1410, 0, $TargetPid)
        }
        if ($hProc -eq [IntPtr]::Zero) {
            $hProc = [PSRPM.NativeInspectorV2]::OpenProcess(0x1000, 0, $TargetPid)
        }
    }

    $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(262144)
    $objBuf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4096)
    try {
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
                    if ([PSRPM.NativeInspectorV2]::QueryFullProcessImageNameW($hProc, 0, $sbPath, [ref]$cap) -ne 0) {
                        $exePath = $sbPath.ToString()
                    }
                }
                if ($cmdLine -eq "N/A") {
                    $cmdRet = 0
                    if ([PSRPM.NativeInspectorV2]::NtQueryInformationProcess($hProc, 60, $buf, 8192, [ref]$cmdRet) -eq 0) {
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
                                    $tsSeconds = [uint32][BitConverter]::ToInt32($hdr, $peOffset + 8)
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

            # 3. Hosted Services & Autostart Detection (Uses in-memory CachedServices first for 0ms WMI overhead)
            $autostartHits = [System.Collections.Generic.List[string]]::new()
            try {
                if ($null -ne $script:CachedServices) {
                    foreach ($cs in $script:CachedServices) {
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
                    $runPaths = @(
                        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
                        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
                    )
                    foreach ($rp in $runPaths) {
                        if (Test-Path $rp) {
                            $props = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
                            if ($props) {
                                foreach ($p in $props.PSObject.Properties) {
                                    if ($p.Name -notmatch '^PS' -and ([string]$p.Value) -like "*$leafName*") {
                                        $autostartHits.Add("$rp\$($p.Name)")
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {}
            if ($autostartHits.Count -gt 0) { $result.Autostart = ($autostartHits -join "; ") }

            # 4. PEB CurrentDirectory & Environment, Cycles & GUI Handles
            if ($hProc -ne [IntPtr]::Zero) {
                $retLen = 0
                if ([IntPtr]::Size -eq 8 -and [PSRPM.NativeInspectorV2]::NtQueryInformationProcess($hProc, 0, $buf, 48, [ref]$retLen) -eq 0) {
                    $pebAddr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf, 8)
                    $bytesRead = [IntPtr]::Zero
                    if ($pebAddr -ne [IntPtr]::Zero -and [PSRPM.NativeInspectorV2]::ReadProcessMemory($hProc, [IntPtr]::Add($pebAddr, 0x20), $buf, [IntPtr]8, [ref]$bytesRead) -ne 0) {
                        $procParams = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf, 0)
                        if ($procParams -ne [IntPtr]::Zero) {
                            # Read CurrentDirectory UNICODE_STRING at +0x38
                            if ([PSRPM.NativeInspectorV2]::ReadProcessMemory($hProc, [IntPtr]::Add($procParams, 0x38), $buf, [IntPtr]16, [ref]$bytesRead) -ne 0) {
                                $cdLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($buf, 0)
                                $cdPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf, 8)
                                if ($cdLen -gt 0 -and $cdLen -le 2048 -and [PSRPM.NativeInspectorV2]::ReadProcessMemory($hProc, $cdPtr, $buf, [IntPtr]$cdLen, [ref]$bytesRead) -ne 0) {
                                    $result.CurrentDirectory = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($buf, [int]($cdLen / 2))
                                }
                            }
                            # Read Environment Pointer at +0x80 and EnvironmentSize at +0x3F0
                            $envPtr  = [IntPtr]::Zero
                            $envSize = 0L
                            if ([PSRPM.NativeInspectorV2]::ReadProcessMemory($hProc, [IntPtr]::Add($procParams, 0x80), $buf, [IntPtr]8, [ref]$bytesRead) -ne 0) {
                                $envPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf, 0)
                            }
                            if ([PSRPM.NativeInspectorV2]::ReadProcessMemory($hProc, [IntPtr]::Add($procParams, 0x3F0), $buf, [IntPtr]8, [ref]$bytesRead) -ne 0) {
                                $envSize = [System.Runtime.InteropServices.Marshal]::ReadInt64($buf, 0)
                            }
                            if ($envPtr -ne [IntPtr]::Zero -and $envSize -gt 0 -and $envSize -le 65536) {
                                if ([PSRPM.NativeInspectorV2]::ReadProcessMemory($hProc, $envPtr, $buf, [IntPtr]$envSize, [ref]$bytesRead) -ne 0) {
                                    $pos = 0
                                    while ($pos -lt ($envSize - 2)) {
                                        $entry = [System.Runtime.InteropServices.Marshal]::PtrToStringUni([IntPtr]::Add($buf, $pos))
                                        if ([string]::IsNullOrEmpty($entry)) { break }
                                        $eqIdx = $entry.IndexOf('=')
                                        if ($eqIdx -gt 0) {
                                            $result.Environment.Add(@{
                                                Key   = $entry.Substring(0, $eqIdx)
                                                Value = $entry.Substring($eqIdx + 1)
                                            })
                                        }
                                        $pos += ($entry.Length + 1) * 2
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
                [void][PSRPM.NativeInspectorV2]::QueryProcessCycleTime($hProc, [ref]$cycles)
                $gdiHandles  = [PSRPM.NativeInspectorV2]::GetGuiResources($hProc, 0)
                $userHandles = [PSRPM.NativeInspectorV2]::GetGuiResources($hProc, 1)
                $result.Performance["Cycles"]      = $cycles.ToString("N0")
                $result.Performance["GdiHandles"]  = $gdiHandles
                $result.Performance["UserHandles"] = $userHandles
            }

            # 5. Extract Detailed Performance & I/O Counters from SystemProcessInformation
            $sysLen = 524288
            $sysPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($sysLen)
            try {
                $ret = 0
                $st = [PSRPM.NativeInspectorV2]::NtQuerySystemInformation(5, $sysPtr, $sysLen, [ref]$ret)
                while ($st -eq -1073741820) {
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sysPtr)
                    $sysLen = [Math]::Max($sysLen * 2, $ret + 65536)
                    $sysPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($sysLen)
                    $st = [PSRPM.NativeInspectorV2]::NtQuerySystemInformation(5, $sysPtr, $sysLen, [ref]$ret)
                }
                if ($st -eq 0) {
                    $is64 = ([IntPtr]::Size -eq 8)
                    $offPid = if ($is64) { 80 } else { 68 }

                    $off = 0
                    while ($true) {
                        $cPtr   = [IntPtr]::Add($sysPtr, $off)
                        $nxt    = [System.Runtime.InteropServices.Marshal]::ReadInt32($cPtr, 0)
                        $pIdCur = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($cPtr, $offPid).ToInt32()
                        if ($pIdCur -eq $TargetPid) {
                            $uTime = [TimeSpan]::FromTicks([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 40))
                            $kTime = [TimeSpan]::FromTicks([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 48))
                            $result.Performance["UserTime"]     = $uTime.ToString("hh\:mm\:ss\.fff")
                            $result.Performance["KernelTime"]   = $kTime.ToString("hh\:mm\:ss\.fff")
                            $result.Performance["TotalCpuTime"] = ($uTime + $kTime).ToString("hh\:mm\:ss\.fff")

                            if ($is64) {
                                $result.Performance["PeakWorkingSet"] = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 136) / 1KB, 0).ToString('N0')) K"
                                $result.Performance["WorkingSet"]     = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 144) / 1KB, 0).ToString('N0')) K"
                                $result.Performance["PrivateBytes"]   = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 184) / 1KB, 0).ToString('N0')) K"
                                $result.Performance["VirtualSize"]    = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 120) / 1MB, 1)) MB"
                                $result.Performance["PageFaults"]     = ([uint32][System.Runtime.InteropServices.Marshal]::ReadInt32($cPtr, 128)).ToString("N0")
                                $result.Performance["PagedPool"]      = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 160) / 1KB, 1)) K"
                                $result.Performance["NonPagedPool"]   = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 176) / 1KB, 1)) K"
                                $result.Performance["IoReadOps"]      = [System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 208).ToString("N0")
                                $result.Performance["IoWriteOps"]     = [System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 216).ToString("N0")
                                $result.Performance["IoReadBytes"]    = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 232) / 1KB, 1).ToString('N1')) K"
                                $result.Performance["IoWriteBytes"]   = "$([Math]::Round([System.Runtime.InteropServices.Marshal]::ReadInt64($cPtr, 240) / 1KB, 1).ToString('N1')) K"
                            }
                            break
                        }
                        if ($nxt -eq 0) { break }
                        $off += $nxt
                    }
                }
            } finally {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sysPtr)
            }
        } # end if ($runPerformance)

        if ($runCore) {
            # 6. Fast Native TCP/UDP Connections (iphlpapi!GetExtendedTcpTable - Zero CIM/WMI overhead)
            $tcpStates = @("Closed","Listen","SynSent","SynReceived","Established","FinWait1","FinWait2","CloseWait","Closing","LastAck","TimeWait","DeleteTcb")
            $tSize = 262144
            if ([PSRPM.NativeInspectorV2]::GetExtendedTcpTable($buf, [ref]$tSize, 1, 2, 5, 0) -eq 0) {
                $numTcp = [System.Runtime.InteropServices.Marshal]::ReadInt32($buf, 0)
                for ($i = 0; $i -lt $numTcp; $i++) {
                    $rowOff = 4 + ($i * 24)
                    if (($rowOff + 24) -gt 262144) { break }
                    $ownPid = [System.Runtime.InteropServices.Marshal]::ReadInt32($buf, $rowOff + 20)
                    if ($ownPid -eq $TargetPid) {
                        $stVal = [System.Runtime.InteropServices.Marshal]::ReadInt32($buf, $rowOff)
                        $lAddr = [System.Net.IPAddress]::new(([int64]([uint32][System.Runtime.InteropServices.Marshal]::ReadInt32($buf, $rowOff + 4)))).ToString()
                        $lPort = [System.Net.IPAddress]::NetworkToHostOrder([int16][System.Runtime.InteropServices.Marshal]::ReadInt32($buf, $rowOff + 8)) -band 0xFFFF
                        $rAddr = [System.Net.IPAddress]::new(([int64]([uint32][System.Runtime.InteropServices.Marshal]::ReadInt32($buf, $rowOff + 12)))).ToString()
                        $rPort = [System.Net.IPAddress]::NetworkToHostOrder([int16][System.Runtime.InteropServices.Marshal]::ReadInt32($buf, $rowOff + 16)) -band 0xFFFF
                        $stStr = if ($stVal -ge 1 -and $stVal -le $tcpStates.Count) { $tcpStates[$stVal - 1] } else { "$stVal" }
                        $result.Connections.Add(@{
                            Protocol       = "TCP"
                            LocalEndpoint  = "${lAddr}:${lPort}"
                            RemoteEndpoint = "${rAddr}:${rPort}"
                            State          = $stStr
                        })
                    }
                }
            }

            # UDP IPv4 Endpoints
            $uSize = 262144
            if ([PSRPM.NativeInspectorV2]::GetExtendedUdpTable($buf, [ref]$uSize, 1, 2, 1, 0) -eq 0) {
                $numUdp = [System.Runtime.InteropServices.Marshal]::ReadInt32($buf, 0)
                for ($i = 0; $i -lt $numUdp; $i++) {
                    $rowOff = 4 + ($i * 12)
                    if (($rowOff + 12) -gt 262144) { break }
                    $ownPid = [System.Runtime.InteropServices.Marshal]::ReadInt32($buf, $rowOff + 8)
                    if ($ownPid -eq $TargetPid) {
                        $lAddr = [System.Net.IPAddress]::new(([int64]([uint32][System.Runtime.InteropServices.Marshal]::ReadInt32($buf, $rowOff)))).ToString()
                        $lPort = [System.Net.IPAddress]::NetworkToHostOrder([int16][System.Runtime.InteropServices.Marshal]::ReadInt32($buf, $rowOff + 4)) -band 0xFFFF
                        $result.Connections.Add(@{
                            Protocol       = "UDP"
                            LocalEndpoint  = "${lAddr}:${lPort}"
                            RemoteEndpoint = "*:*"
                            State          = "Listening"
                        })
                    }
                }
            }
        }

        # Lazy On-Demand Section A: Loaded DLLs / Modules
        if ($runModules) {
            $hModProc = if ($TargetPid -gt 4) { [PSRPM.NativeInspectorV2]::OpenProcess(0x0410, 0, $TargetPid) } else { [IntPtr]::Zero }
            $closeModProc = ($hModProc -ne [IntPtr]::Zero)
            if ($hModProc -eq [IntPtr]::Zero) { $hModProc = $hProc }

            try {
                $cbNeeded = [uint32]0
                if ($hModProc -ne [IntPtr]::Zero -and [PSRPM.NativeInspectorV2]::EnumProcessModulesEx($hModProc, $buf, 65536, [ref]$cbNeeded, 0x03) -ne 0 -and $cbNeeded -gt 0) {
                    $ptrSize = [IntPtr]::Size
                    $modCount = [Math]::Min([int]($cbNeeded / $ptrSize), 1024)
                    $seenModPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

                    for ($mIdx = 0; $mIdx -lt $modCount; $mIdx++) {
                        $hMod = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf, $mIdx * $ptrSize)
                        $sbPath.Length = 0
                        if ([PSRPM.NativeInspectorV2]::GetModuleFileNameExW($hModProc, $hMod, $sbPath, 1024) -gt 0) {
                            $mPath = $sbPath.ToString()
                            if (-not $seenModPaths.Add($mPath)) { continue }

                            $mName = [System.IO.Path]::GetFileName($mPath)
                            $baseAddr = "0x" + $hMod.ToInt64().ToString("X")
                            $sizeKB = "N/A"
                            if ([PSRPM.NativeInspectorV2]::GetModuleInformation($hModProc, $hMod, $objBuf, 24) -ne 0) {
                                $imgSize = [uint32][System.Runtime.InteropServices.Marshal]::ReadInt32($objBuf, $ptrSize)
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
                if ($closeModProc) { [void][PSRPM.NativeInspectorV2]::CloseHandle($hModProc) }
            }

            # Fallback to .NET Process.Modules if EnumProcessModulesEx returned 0 entries
            if ($result.Modules.Count -eq 0 -and $TargetPid -gt 4) {
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
                } catch {}
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
            $hDupProc = if ($TargetPid -gt 4) { [PSRPM.NativeInspectorV2]::OpenProcess(0x1440, 0, $TargetPid) } else { [IntPtr]::Zero }
            if ($hDupProc -eq [IntPtr]::Zero -and $TargetPid -gt 4) {
                $hDupProc = [PSRPM.NativeInspectorV2]::OpenProcess(0x1040, 0, $TargetPid)
            }
            $closeDupProc = ($hDupProc -ne [IntPtr]::Zero)
            if ($hDupProc -eq [IntPtr]::Zero) { $hDupProc = $hProc }

            $hBufLen = 262144
            $hBufPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($hBufLen)
            try {
                if ($hDupProc -ne [IntPtr]::Zero -and [IntPtr]::Size -eq 8) {
                    $hRetLen = 0
                    $hSt = [PSRPM.NativeInspectorV2]::NtQueryInformationProcess($hDupProc, 51, $hBufPtr, $hBufLen, [ref]$hRetLen)
                    while ($hSt -eq -1073741820) {
                        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($hBufPtr)
                        $hBufLen = [Math]::Max($hBufLen * 2, $hRetLen + 65536)
                        $hBufPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($hBufLen)
                        $hSt = [PSRPM.NativeInspectorV2]::NtQueryInformationProcess($hDupProc, 51, $hBufPtr, $hBufLen, [ref]$hRetLen)
                    }

                    if ($hSt -eq 0) {
                        $numHandles = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($hBufPtr, 0).ToInt64()
                        $maxScan = [Math]::Min($numHandles, 1500L)
                        $currProc = [PSRPM.NativeInspectorV2]::GetCurrentProcess()
                        # Skip kernel object types that have no name or whose QueryNameProcedure (File/Pipe) can block on synchronous IPC
                        $skipTypes = @("File", "WaitCompletionPacket", "IRTimer", "TpWorkerFactory", "IoCompletion", "EtwRegistration", "DxgkCompositionObject")

                        for ($hIdx = 0; $hIdx -lt $maxScan; $hIdx++) {
                            $entryOff = 16 + ($hIdx * 40)
                            if (($entryOff + 40) -gt $hBufLen) { break }

                            $hVal = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($hBufPtr, $entryOff)
                            $acc  = [uint32][System.Runtime.InteropServices.Marshal]::ReadInt32($hBufPtr, $entryOff + 24)
                            $tIdx = [uint32][System.Runtime.InteropServices.Marshal]::ReadInt32($hBufPtr, $entryOff + 28)

                            if ($script:HandleTypeCache.ContainsKey($tIdx) -and $script:HandleTypeCache[$tIdx] -in $skipTypes) {
                                continue
                            }

                            $dup = [IntPtr]::Zero
                            if ([PSRPM.NativeInspectorV2]::DuplicateHandle($hDupProc, $hVal, $currProc, [ref]$dup, 0, 0, 2) -ne 0) {
                                try {
                                    $oRet = 0
                                    $tName = if ($script:HandleTypeCache.ContainsKey($tIdx)) {
                                        $script:HandleTypeCache[$tIdx]
                                    } else {
                                        $tn = ""
                                        if ([PSRPM.NativeInspectorV2]::NtQueryObject($dup, 2, $objBuf, 4096, [ref]$oRet) -eq 0) {
                                            $tLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($objBuf, 0)
                                            $tPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($objBuf, 8)
                                            if ($tLen -gt 0 -and $tPtr -ne [IntPtr]::Zero) {
                                                $tn = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($tPtr, [int]($tLen / 2))
                                            }
                                        }
                                        if ($tn) { $script:HandleTypeCache[$tIdx] = $tn }
                                        $tn
                                    }

                                    if (-not $tName -or $tName -in $skipTypes) { continue }

                                    $nStr = ""
                                    if ([PSRPM.NativeInspectorV2]::NtQueryObject($dup, 1, $objBuf, 4096, [ref]$oRet) -eq 0) {
                                        $nLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($objBuf, 0)
                                        $nPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($objBuf, 8)
                                        if ($nLen -gt 0 -and $nPtr -ne [IntPtr]::Zero) {
                                            $nStr = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($nPtr, [int]($nLen / 2))
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
                                    [void][PSRPM.NativeInspectorV2]::CloseHandle($dup)
                                }
                            }
                        }
                    }
                }
            } finally {
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($hBufPtr)
                if ($closeDupProc) { [void][PSRPM.NativeInspectorV2]::CloseHandle($hDupProc) }
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
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($objBuf)
        if ($hProc -ne [IntPtr]::Zero) { [void][PSRPM.NativeInspectorV2]::CloseHandle($hProc) }
    }

    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
    $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $jss.MaxJsonLength = 10485760
    return $jss.Serialize($result)
}
