# Requires -Version 5.1
# PSRPM Remote & Local Process & Service Control Actions
# 100% Fileless Reflection.Emit P/Invoke for Native Actions
# Best-Effort Hierarchical Tree Termination with Pinned Handles & CreationTime Validation

$script:PSRPMActionScriptBlock = {
    param(
        [string]$Action,
        [int]$TargetPid = 0,
        [string]$ExpectedName = "",
        [string]$ServiceName = "",
        [string]$Priority = "Normal",
        [string]$HandleId = "",
        [string]$DumpType = "Mini",
        [long]$ExpectedStartTime = 0L
    )

    if (-not ('PSRPM.NativeActionsV3' -as [type])) {
        $dynAsm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
            [System.Reflection.AssemblyName]::new("PSRPMNativeActionsV3Asm"),
            [System.Reflection.Emit.AssemblyBuilderAccess]::Run
        )
        $dynMod = $dynAsm.DefineDynamicModule("PSRPMNativeActionsV3Mod")
        $tb = $dynMod.DefineType("PSRPM.NativeActionsV3", [System.Reflection.TypeAttributes]"Public,Abstract,Sealed")

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
        &$addPInvoke "TerminateProcess"           "kernel32.dll" ([int])    @([IntPtr], [uint32])
        &$addPInvoke "GetProcessTimes"            "kernel32.dll" ([int])    @([IntPtr], [long].MakeByRefType(), [long].MakeByRefType(), [long].MakeByRefType(), [long].MakeByRefType())
        &$addPInvoke "QueryFullProcessImageNameW" "kernel32.dll" ([int])    @([IntPtr], [uint32], [System.Text.StringBuilder], [int].MakeByRefType())
        &$addPInvoke "NtSuspendProcess"           "ntdll.dll"    ([int])    @([IntPtr])
        &$addPInvoke "NtResumeProcess"            "ntdll.dll"    ([int])    @([IntPtr])
        &$addPInvoke "NtQuerySystemInformation"  "ntdll.dll"    ([int])    @([int], [IntPtr], [int], [int].MakeByRefType())
        &$addPInvoke "MiniDumpWriteDump"          "dbghelp.dll"  ([int])    @([IntPtr], [uint32], [IntPtr], [int], [IntPtr], [IntPtr], [IntPtr])

        [void]$tb.CreateType()
    }

    $res = @{
        Success = $false
        Status  = "Failed"
        ErrorId = ""
        Action  = $Action
        PID     = $TargetPid
        Message = ""
    }

    $verifyProcessIdentity = {
        param([IntPtr]$hTarget, [int]$procId, [long]$expStart, [string]$expImgName)
        if ($expStart -gt 0L) {
            $ftC = 0L; $ftE = 0L; $ftK = 0L; $ftU = 0L
            if ([PSRPM.NativeActionsV3]::GetProcessTimes($hTarget, [ref]$ftC, [ref]$ftE, [ref]$ftK, [ref]$ftU) -eq 0) {
                $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "PID $procId identity verification failed: unable to query CreationTime (Win32 Error: $err). Aborting action."
            }
            if ([Math]::Abs($ftC - $expStart) -gt 100000L) {
                throw "PID $procId reuse detected (CreationTime mismatch). Aborting action."
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($expImgName)) {
            $sbImg = [System.Text.StringBuilder]::new(1024)
            $imgCap = $sbImg.Capacity
            if ([PSRPM.NativeActionsV3]::QueryFullProcessImageNameW($hTarget, 0, $sbImg, [ref]$imgCap) -eq 0) {
                $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "PID $procId identity verification failed: unable to query executable image name (Win32 Error: $err). Aborting action."
            }
            $actLeaf  = [System.IO.Path]::GetFileName($sbImg.ToString())
            $baseLeaf = if ($actLeaf.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) { $actLeaf.Substring(0, $actLeaf.Length - 4) } else { $actLeaf }
            $expLeaf  = if ($expImgName.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) { $expImgName.Substring(0, $expImgName.Length - 4) } else { $expImgName }
            if (-not $baseLeaf.Equals($expLeaf, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "PID $procId reuse detected (expected '$expImgName', found '$actLeaf'). Aborting action."
            }
        }
    }

    try {
        switch ($Action) {
            "KillProcess" {
                if ($TargetPid -le 4) {
                    throw "Cannot terminate critical system process (PID $TargetPid)."
                }
                $needsIdentityCheck = ($ExpectedStartTime -gt 0L) -or (-not [string]::IsNullOrWhiteSpace($ExpectedName))
                # Open with PROCESS_QUERY_LIMITED_INFORMATION (0x1000) | PROCESS_TERMINATE (0x0001)
                $hProc = [PSRPM.NativeActionsV3]::OpenProcess(0x1001, 0, $TargetPid)
                if ($hProc -eq [IntPtr]::Zero) {
                    if ($needsIdentityCheck) {
                        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        throw "PID $TargetPid identity verification failed: cannot open with query+terminate access (Win32 Error: $err)."
                    }
                    # Fallback to PROCESS_TERMINATE (0x0001) only when no identity expectations were supplied
                    $hProc = [PSRPM.NativeActionsV3]::OpenProcess(0x0001, 0, $TargetPid)
                }
                if ($hProc -eq [IntPtr]::Zero) {
                    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    throw "Cannot open process (PID $TargetPid) for termination (Win32 Error: $err)."
                }
                try {
                    &$verifyProcessIdentity $hProc $TargetPid $ExpectedStartTime $ExpectedName
                    if ([PSRPM.NativeActionsV3]::TerminateProcess($hProc, 1) -eq 0) {
                        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        throw "TerminateProcess failed on PID $TargetPid (Win32 Error: $err)."
                    }
                    $res.Success = $true
                    $res.Status  = "Success"
                    $res.Message = "Terminated process '$ExpectedName' (PID: $TargetPid)."
                } finally {
                    [void][PSRPM.NativeActionsV3]::CloseHandle($hProc)
                }
            }

            "KillTree" {
                if ($TargetPid -le 4) {
                    throw "Cannot terminate process tree rooted at system process (PID $TargetPid)."
                }
                # Fast Sub-Millisecond Native Snapshot via NtQuerySystemInformation(5) (Zero WMI, < 3 ms)
                $sysBufSize = 524288 # 512 KB
                $sysBufPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($sysBufSize)
                $retLen = 0
                $status = [PSRPM.NativeActionsV3]::NtQuerySystemInformation(5, $sysBufPtr, $sysBufSize, [ref]$retLen)
                $reallocAttempts = 0
                while ($status -eq -1073741820 -and $reallocAttempts -lt 6 -and $sysBufSize -lt 67108864) { # STATUS_INFO_LENGTH_MISMATCH
                    $reallocAttempts++
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sysBufPtr)
                    $sysBufSize = [Math]::Min(67108864, [Math]::Max($sysBufSize * 2, $retLen + 65536))
                    $sysBufPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($sysBufSize)
                    $status = [PSRPM.NativeActionsV3]::NtQuerySystemInformation(5, $sysBufPtr, $sysBufSize, [ref]$retLen)
                }

                $childrenByParent = @{}
                $createTimeByPid  = @{}
                $nameByPid        = @{}

                try {
                    if ($status -ne 0) {
                        throw "NtQuerySystemInformation failed while enumerating process tree (NTSTATUS 0x$($status.ToString('X8')))."
                    }
                    $is64        = ([IntPtr]::Size -eq 8)
                    $offPid      = if ($is64) { 80 } else { 68 }
                    $offPpid     = if ($is64) { 88 } else { 72 }
                    $offNamePtr  = if ($is64) { 64 } else { 60 }
                    $spiSize     = if ($is64) { 256 } else { 184 }
                    $validLen    = if ($retLen -gt 0 -and $retLen -le $sysBufSize) { $retLen } else { $sysBufSize }
                    $offset      = 0

                    while (($offset + $spiSize) -le $validLen) {
                        $curPtr     = [IntPtr]::Add($sysBufPtr, $offset)
                        $nextOffset = [System.Runtime.InteropServices.Marshal]::ReadInt32($curPtr, 0)
                        if ($nextOffset -lt 0) { break }
                        $cTime      = [System.Runtime.InteropServices.Marshal]::ReadInt64($curPtr, 32)
                        $itemPid  = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($curPtr, $offPid).ToInt32()
                        $itemPpid = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($curPtr, $offPpid).ToInt32()

                        $pName = ""
                        $nameLen = [System.Runtime.InteropServices.Marshal]::ReadInt16($curPtr, 56)
                        if ($nameLen -gt 0) {
                            $nameBuf = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($curPtr, $offNamePtr)
                            if ($nameBuf -ne [IntPtr]::Zero) {
                                $pName = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($nameBuf, [int]($nameLen / 2))
                            }
                        }

                        if ($itemPid -gt 0) {
                            $createTimeByPid[$itemPid] = $cTime
                            $nameByPid[$itemPid]       = $pName
                            if (-not $childrenByParent.ContainsKey($itemPpid)) {
                                $childrenByParent[$itemPpid] = [System.Collections.Generic.List[int]]::new()
                            }
                            $childrenByParent[$itemPpid].Add($itemPid)
                        }

                        if ($nextOffset -le 0 -or ($offset + $nextOffset) -gt $validLen) { break }
                        $offset += $nextOffset
                    }
                } finally {
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($sysBufPtr)
                }

                if (-not $createTimeByPid.ContainsKey($TargetPid)) {
                    throw "Target PID $TargetPid is not running in current process snapshot."
                }
                if ($ExpectedStartTime -gt 0L -and $createTimeByPid[$TargetPid] -gt 0L) {
                    if ([Math]::Abs([long]$createTimeByPid[$TargetPid] - $ExpectedStartTime) -gt 100000L) {
                        throw "PID $TargetPid reuse detected (snapshot CreationTime mismatch). Aborting tree termination."
                    }
                }

                $orderedTree = [System.Collections.Generic.List[int]]::new()
                $visited     = [System.Collections.Generic.HashSet[int]]::new()

                $collectDescendants = {
                    param([int]$currPid)
                    if (-not $visited.Add($currPid)) { return }
                    $orderedTree.Add($currPid)
                    if ($childrenByParent.ContainsKey($currPid)) {
                        $parentCreate = if ($createTimeByPid.ContainsKey($currPid)) { $createTimeByPid[$currPid] } else { 0L }
                        foreach ($childPid in $childrenByParent[$currPid]) {
                            if ($childPid -eq $currPid) { continue }
                            $childCreate = if ($createTimeByPid.ContainsKey($childPid)) { $createTimeByPid[$childPid] } else { 0L }
                            # Validation: Child creation must be >= parent creation
                            if ($parentCreate -eq 0L -or $childCreate -eq 0L -or $childCreate -ge $parentCreate) {
                                & $collectDescendants $childPid
                            }
                        }
                    }
                }

                & $collectDescendants $TargetPid

                # Open & Pin handles for all processes in the tree (always keep PROCESS_QUERY_LIMITED_INFORMATION 0x1000)
                $openHandles = @{}
                $failedPids  = [System.Collections.Generic.List[int]]::new()

                foreach ($pIdVal in $orderedTree) {
                    if ($pIdVal -le 4) { continue }
                    # Open with PROCESS_SUSPEND_RESUME (0x0800) | PROCESS_QUERY_LIMITED_INFORMATION (0x1000) | PROCESS_TERMINATE (0x0001)
                    $h = [PSRPM.NativeActionsV3]::OpenProcess(0x1801, 0, $pIdVal)
                    if ($h -eq [IntPtr]::Zero) {
                        # Fallback without suspend, keeping query + terminate rights
                        $h = [PSRPM.NativeActionsV3]::OpenProcess(0x1001, 0, $pIdVal)
                    }
                    if ($h -ne [IntPtr]::Zero) {
                        $expTimeForPid = if ($pIdVal -eq $TargetPid -and $ExpectedStartTime -gt 0L) {
                            $ExpectedStartTime
                        } elseif ($createTimeByPid.ContainsKey($pIdVal)) {
                            [long]$createTimeByPid[$pIdVal]
                        } else {
                            0L
                        }
                        $expNameForPid = if ($pIdVal -eq $TargetPid -and $ExpectedName) {
                            $ExpectedName
                        } elseif ($nameByPid.ContainsKey($pIdVal)) {
                            [string]$nameByPid[$pIdVal]
                        } else {
                            ""
                        }
                        $verified = $false
                        try {
                            &$verifyProcessIdentity $h $pIdVal $expTimeForPid $expNameForPid
                            $verified = $true
                        } catch {
                            $verified = $false
                            if ($pIdVal -eq $TargetPid) {
                                [void][PSRPM.NativeActionsV3]::CloseHandle($h)
                                throw
                            }
                        }
                        if ($verified) {
                            $openHandles[$pIdVal] = $h
                        } else {
                            [void][PSRPM.NativeActionsV3]::CloseHandle($h)
                            $failedPids.Add($pIdVal)
                        }
                    } else {
                        $failedPids.Add($pIdVal)
                    }
                }

                try {
                    # Phase 1: Top-Down Suspend (Freezes supervisors & watchdogs so they cannot respawn workers)
                    foreach ($pIdVal in $orderedTree) {
                        if ($openHandles.ContainsKey($pIdVal)) {
                            [void][PSRPM.NativeActionsV3]::NtSuspendProcess($openHandles[$pIdVal])
                        }
                    }

                    # Phase 2: Bottom-Up Termination (Leaves first, root last, using the pinned handles)
                    $killedCount = 0
                    for ($i = $orderedTree.Count - 1; $i -ge 0; $i--) {
                        $killId = $orderedTree[$i]
                        if ($openHandles.ContainsKey($killId)) {
                            $ok = [PSRPM.NativeActionsV3]::TerminateProcess($openHandles[$killId], 1)
                            if ($ok -ne 0) {
                                $killedCount++
                            } else {
                                $failedPids.Add($killId)
                            }
                        }
                    }

                    $script:LastSvcRefresh = [DateTime]::MinValue
                    try { [AppDomain]::CurrentDomain.SetData("PSRPM_ForceSvcRefresh", $true) } catch {}
                    $res.Success         = ($killedCount -gt 0)
                    $res.Status          = if ($failedPids.Count -eq 0) { "Success" } elseif ($killedCount -gt 0) { "PartialSuccess" } else { "Failed" }
                    $res.TotalTargets    = $orderedTree.Count
                    $res.SuccessfulCount = $killedCount
                    $res.FailedCount     = $failedPids.Count
                    $res.Message         = "Terminated process tree rooted at PID $TargetPid ($killedCount of $($orderedTree.Count) processes terminated)."
                } finally {
                    # Phase 3: Guaranteed Cleanup & Resumption (Resume any survivors, close all pinned handles)
                    foreach ($h in $openHandles.Values) {
                        try { [void][PSRPM.NativeActionsV3]::NtResumeProcess($h) } catch {}
                        try { [void][PSRPM.NativeActionsV3]::CloseHandle($h) } catch {}
                    }
                }
            }

            "SuspendProcess" {
                if ($TargetPid -le 4) {
                    throw "Cannot suspend critical system process (PID $TargetPid)."
                }
                # PROCESS_SUSPEND_RESUME (0x0800) | PROCESS_QUERY_LIMITED_INFORMATION (0x1000)
                $hProc = [PSRPM.NativeActionsV3]::OpenProcess(0x1800, 0, $TargetPid)
                if ($hProc -eq [IntPtr]::Zero) {
                    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    throw "Access denied opening PID $TargetPid for PROCESS_SUSPEND_RESUME | QUERY (Win32 Error: $err)."
                }
                try {
                    &$verifyProcessIdentity $hProc $TargetPid $ExpectedStartTime $ExpectedName
                    $ntStatus = [PSRPM.NativeActionsV3]::NtSuspendProcess($hProc)
                    if ($ntStatus -ne 0) {
                        throw "NtSuspendProcess failed with NTSTATUS 0x$($ntStatus.ToString('X8'))."
                    }
                } finally {
                    [void][PSRPM.NativeActionsV3]::CloseHandle($hProc)
                }
                if ($script:LastDynState -and $script:ActivePidToKey -and $script:ActivePidToKey.ContainsKey($TargetPid)) {
                    $script:LastDynState.Remove($script:ActivePidToKey[$TargetPid])
                }
                $res.Success = $true
                $res.Status  = "Success"
                $res.Message = "Suspended process '$ExpectedName' (PID: $TargetPid)."
            }

            "ResumeProcess" {
                if ($TargetPid -le 4) {
                    throw "Cannot resume critical system process (PID $TargetPid)."
                }
                # PROCESS_SUSPEND_RESUME (0x0800) | PROCESS_QUERY_LIMITED_INFORMATION (0x1000)
                $hProc = [PSRPM.NativeActionsV3]::OpenProcess(0x1800, 0, $TargetPid)
                if ($hProc -eq [IntPtr]::Zero) {
                    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    throw "Access denied opening PID $TargetPid for PROCESS_SUSPEND_RESUME | QUERY (Win32 Error: $err)."
                }
                try {
                    &$verifyProcessIdentity $hProc $TargetPid $ExpectedStartTime $ExpectedName
                    $ntStatus = [PSRPM.NativeActionsV3]::NtResumeProcess($hProc)
                    if ($ntStatus -ne 0) {
                        throw "NtResumeProcess failed with NTSTATUS 0x$($ntStatus.ToString('X8'))."
                    }
                } finally {
                    [void][PSRPM.NativeActionsV3]::CloseHandle($hProc)
                }
                if ($script:LastDynState -and $script:ActivePidToKey -and $script:ActivePidToKey.ContainsKey($TargetPid)) {
                    $script:LastDynState.Remove($script:ActivePidToKey[$TargetPid])
                }
                $res.Success = $true
                $res.Status  = "Success"
                $res.Message = "Resumed process '$ExpectedName' (PID: $TargetPid)."
            }

            "CloseHandle" {
                if ($TargetPid -le 4) {
                    throw "Cannot close handle on protected System process (PID $TargetPid)."
                }
                if ([string]::IsNullOrWhiteSpace($HandleId)) {
                    throw "HandleId is required to close handle."
                }
                $hValLong = 0L
                if ($HandleId.StartsWith("0x", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $hValLong = [Convert]::ToInt64($HandleId.Substring(2), 16)
                } else {
                    $hValLong = [long]$HandleId
                }
                $targetHandle = [IntPtr]$hValLong

                # Open target process with PROCESS_QUERY_LIMITED_INFORMATION (0x1000) | PROCESS_DUP_HANDLE (0x0040)
                $hProc = [PSRPM.NativeActionsV3]::OpenProcess(0x1040, 0, $TargetPid)
                if ($hProc -eq [IntPtr]::Zero) {
                    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    throw "Failed to open target process (PID $TargetPid) with PROCESS_DUP_HANDLE | QUERY (Win32 Error: $err)."
                }

                try {
                    &$verifyProcessIdentity $hProc $TargetPid $ExpectedStartTime $ExpectedName

                    # Dual-Phase Verification: Probe handle validity first with DUPLICATE_SAME_ACCESS (0x02)
                    $dupProbe = [IntPtr]::Zero
                    $hCurrentProc = [PSRPM.NativeActionsV3]::GetCurrentProcess()
                    $probeRet = [PSRPM.NativeActionsV3]::DuplicateHandle($hProc, $targetHandle, $hCurrentProc, [ref]$dupProbe, 0, 0, 2)
                    if ($probeRet -eq 0) {
                        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        throw "Handle verification failed: Handle $HandleId in process (PID: $TargetPid) is invalid or already closed (Win32 Error: $err)."
                    }
                    [void][PSRPM.NativeActionsV3]::CloseHandle($dupProbe)

                    # Execution Phase: Close source handle via DUPLICATE_CLOSE_SOURCE (0x01)
                    $dup = [IntPtr]::Zero
                    $ret = [PSRPM.NativeActionsV3]::DuplicateHandle($hProc, $targetHandle, [IntPtr]::Zero, [ref]$dup, 0, 0, 1)
                    if ($ret -eq 0) {
                        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        throw "DuplicateHandle(DUPLICATE_CLOSE_SOURCE) failed with Win32 error code: $err."
                    }
                    $res.Success = $true
                    $res.Status  = "Success"
                    $res.Message = "Closed handle $HandleId in process (PID: $TargetPid)."
                } finally {
                    [void][PSRPM.NativeActionsV3]::CloseHandle($hProc)
                }
            }

            "CreateDump" {
                if ($TargetPid -le 4) {
                    throw "Cannot generate memory dump for System process (PID $TargetPid)."
                }

                # Open process first with PROCESS_QUERY_INFORMATION (0x0400) | PROCESS_VM_READ (0x0010) and verify identity
                $hProc = [PSRPM.NativeActionsV3]::OpenProcess(0x0410, 0, $TargetPid)
                if ($hProc -eq [IntPtr]::Zero) {
                    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    throw "Failed to open process (PID $TargetPid) for memory dump (Win32 error: $err)."
                }

                $p = $null
                $dumpCreated = $false
                $dumpFilePath = ""
                try {
                    &$verifyProcessIdentity $hProc $TargetPid $ExpectedStartTime $ExpectedName

                    $p = [System.Diagnostics.Process]::GetProcessById($TargetPid)
                    $pName = if ($ExpectedName) { $ExpectedName } else { $p.ProcessName }
                    if ($pName.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $pName = $pName.Substring(0, $pName.Length - 4)
                    }
                    $wsBytes = [long]$p.WorkingSet64

                    $curIdent = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                    $curUserSid = $curIdent.User
                    $isAdmin = [System.Security.Principal.WindowsPrincipal]::new($curIdent).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

                    # Stage dumps in a privilege-scoped private directory (never shared C:\temp)
                    $tempDir = if ($isAdmin) {
                        [System.IO.Path]::Combine($env:SystemRoot, "Temp", "PSRPM_Dumps")
                    } else {
                        [System.IO.Path]::Combine($env:LOCALAPPDATA, "PSRPM", "Dumps")
                    }

                    $adminSid  = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
                    $systemSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18")

                    $dirAcl = [System.Security.AccessControl.DirectorySecurity]::new()
                    $dirAcl.SetOwner($curUserSid)
                    $dirAcl.SetAccessRuleProtection($true, $false)
                    $dirAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($adminSid,  "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"))
                    $dirAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($systemSid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"))
                    $dirAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($curUserSid,"FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"))

                    if (-not [System.IO.Directory]::Exists($tempDir)) {
                        $parentDir = [System.IO.Path]::GetDirectoryName($tempDir)
                        if ($parentDir -and -not [System.IO.Directory]::Exists($parentDir)) {
                            [void][System.IO.Directory]::CreateDirectory($parentDir)
                        }
                        [void][System.IO.Directory]::CreateDirectory($tempDir, $dirAcl)
                    }

                    # Reject junctions / symlinks and untrusted owners on the dump staging directory
                    if (([System.IO.File]::GetAttributes($tempDir) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "Cannot generate memory dump: directory '$tempDir' is a reparse point."
                    }
                    $ownerSid = [System.IO.Directory]::GetAccessControl($tempDir).GetOwner([System.Security.Principal.SecurityIdentifier])
                    if ($ownerSid.Value -notin @($adminSid.Value, $systemSid.Value, $curUserSid.Value)) {
                        throw "Cannot generate memory dump: untrusted owner ($($ownerSid.Value)) on '$tempDir'."
                    }

                    # Pre-flight disk space check on drive
                    $driveRoot = [System.IO.Path]::GetPathRoot($tempDir)
                    if (-not $driveRoot) { $driveRoot = "C:\" }
                    $di = [System.IO.DriveInfo]::new($driveRoot)
                    $freeBytes = $di.AvailableFreeSpace
                    $neededBytes = if ($DumpType -eq "Full") { $wsBytes + 524288000L } else { 104857600L }
                    if ($freeBytes -lt $neededBytes) {
                        throw "Insufficient disk space on $driveRoot (Available: $([Math]::Round($freeBytes/1MB,1)) MB, Required: $([Math]::Round($neededBytes/1MB,1)) MB)."
                    }

                    $ts = (Get-Date).ToString("yyyyMMdd_HHmmss")
                    $randTag = [guid]::NewGuid().ToString("N").Substring(0, 8)
                    $cleanPName = ($pName -replace '[\<\>\:\"\/\\\|\?\*]', '_')
                    $dumpFileName = "PSRPM_Dump_${cleanPName}_PID${TargetPid}_${DumpType}_${ts}_${randTag}.dmp"
                    $dumpFilePath = [System.IO.Path]::Combine($tempDir, $dumpFileName)

                    # MiniDumpNormal = 0x00000000; MiniDumpWithFullMemory = 0x00000002
                    $dumpTypeFlags = if ($DumpType -eq "Full") { 2 } else { 0 }
                    # Build non-inherited ACL with explicit Owner protecting process dump (SYSTEM + Administrators + Current User only)
                    $acl = [System.Security.AccessControl.FileSecurity]::new()
                    $acl.SetOwner($curUserSid)
                    $acl.SetAccessRuleProtection($true, $false)
                    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($adminSid,   "FullControl", "Allow"))
                    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($systemSid,  "FullControl", "Allow"))
                    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($curUserSid, "FullControl", "Allow"))

                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    # FileMode.CreateNew fails if file pre-exists (prevents pre-creation ownership & overwrite attacks)
                    $fs = [System.IO.FileStream]::new(
                        $dumpFilePath,
                        [System.IO.FileMode]::CreateNew,
                        [System.Security.AccessControl.FileSystemRights]::FullControl,
                        [System.IO.FileShare]::None,
                        65536,
                        [System.IO.FileOptions]::None,
                        $acl
                    )
                    try {
                        $hFile = $fs.SafeFileHandle.DangerousGetHandle()
                        $ok = [PSRPM.NativeActionsV3]::MiniDumpWriteDump($hProc, [uint32]$TargetPid, $hFile, $dumpTypeFlags, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
                        if ($ok -eq 0) {
                            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                            throw "MiniDumpWriteDump failed (Win32 error: $err)."
                        }
                        $dumpCreated = $true
                    } finally {
                        $fs.Close()
                        if (-not $dumpCreated -and $dumpFilePath -and [System.IO.File]::Exists($dumpFilePath)) {
                            try { [System.IO.File]::Delete($dumpFilePath) } catch {}
                        }
                    }
                    $sw.Stop()

                    $fi = [System.IO.FileInfo]::new($dumpFilePath)
                    $fileSizeMB = [Math]::Round($fi.Length / 1MB, 2)
                    $res.Success       = $true
                    $res.Status        = "Success"
                    $res.Message       = "Created $DumpType Dump for '$pName' (PID: $TargetPid) at '$dumpFilePath' ($fileSizeMB MB in $($sw.ElapsedMilliseconds) ms)."
                    $res.DumpPath      = $dumpFilePath
                    $res.FileSizeBytes = $fi.Length
                    $res.ElapsedMs     = $sw.ElapsedMilliseconds
                } finally {
                    if ($p) { $p.Dispose() }
                    [void][PSRPM.NativeActionsV3]::CloseHandle($hProc)
                }
            }

            "SetPriority" {
                if ($TargetPid -le 4) {
                    throw "Cannot change priority of critical system process (PID $TargetPid)."
                }
                $allowedPriorities = @("Idle", "BelowNormal", "Normal", "AboveNormal", "High")
                if ($Priority -notin $allowedPriorities) {
                    throw "Refused priority '$Priority': allowed values are $($allowedPriorities -join ', ')."
                }
                $hId = [PSRPM.NativeActionsV3]::OpenProcess(0x1000, 0, $TargetPid) # PROCESS_QUERY_LIMITED_INFORMATION
                if ($hId -eq [IntPtr]::Zero) {
                    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    throw "PID $TargetPid identity verification failed opening process (Win32 Error: $err)."
                }
                $p = $null
                try {
                    &$verifyProcessIdentity $hId $TargetPid $ExpectedStartTime $ExpectedName
                    $p = [System.Diagnostics.Process]::GetProcessById($TargetPid)
                    $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$Priority
                } finally {
                    if ($p) { $p.Dispose() }
                    [void][PSRPM.NativeActionsV3]::CloseHandle($hId)
                }
                $res.Success = $true
                $res.Status  = "Success"
                $res.Message = "Set priority of '$ExpectedName' (PID: $TargetPid) to $Priority."
            }

            "ControlService" {
                # ExpectedName holds the service operation: Start, Stop, or Restart
                $op = $ExpectedName
                if ($op -notin @("Start", "Stop", "Restart")) {
                    throw "Unknown service operation '$op'."
                }
                if ([string]::IsNullOrWhiteSpace($ServiceName) -or $ServiceName.IndexOfAny([char[]]@('*', '?', '[', ']')) -ge 0) {
                    throw "Refused service operation: wildcard or invalid service name '$ServiceName'."
                }

                Add-Type -AssemblyName System.ServiceProcess -ErrorAction SilentlyContinue
                $sc = [System.ServiceProcess.ServiceController]::new($ServiceName)
                try {
                    $sc.Refresh()
                    $timeout = [TimeSpan]::FromSeconds(30)
                    $swSvcOp = [System.Diagnostics.Stopwatch]::StartNew()
                    if ($op -eq "Start") {
                        if ($sc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
                            $sc.Start()
                            $sc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, $timeout)
                        }
                    } elseif ($op -eq "Stop") {
                        if ($sc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                            $sc.Stop()
                            $sc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, $timeout)
                        }
                    } elseif ($op -eq "Restart") {
                        if ($sc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                            $sc.Stop()
                            $sc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, $timeout)
                        }
                        $remSec = [Math]::Max(5.0, 30.0 - $swSvcOp.Elapsed.TotalSeconds)
                        $sc.Start()
                        $sc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds($remSec))
                    }
                } finally {
                    $sc.Dispose()
                }

                $script:LastSvcRefresh = [DateTime]::MinValue
                try { [AppDomain]::CurrentDomain.SetData("PSRPM_ForceSvcRefresh", $true) } catch {}
                $res.Success = $true
                $res.Status  = "Success"
                $res.Message = "Service '$ServiceName' action '$op' completed successfully."
            }

            default {
                throw "Unknown action '$Action'."
            }
        }
    } catch {
        $res.Success = $false
        $errMsg = $_.Exception.Message
        $res.Message = $errMsg
        if ($errMsg -match "reuse detected|identity verification failed|Cannot terminate|Cannot suspend|Cannot resume|Cannot close handle|Cannot generate memory dump|Cannot change priority|Refused") {
            $res.Status  = "Refused"
            $res.ErrorId = "PSRPM.Process.Refused"
        } else {
            $res.Status  = "Failed"
            $res.ErrorId = "PSRPM.Process.Failed"
        }
    }

    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
    $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    return $jss.Serialize($res)
}
