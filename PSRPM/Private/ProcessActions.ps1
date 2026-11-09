# Requires -Version 5.1
# PSRPM Remote & Local Process & Service Control Actions
# 100% Fileless Reflection.Emit P/Invoke for NtSuspendProcess / NtResumeProcess
# Two-Phase Atomic Suspend-Then-Kill Tree Termination with CreationDate Validation

$script:PSRPMActionScriptBlock = {
    param(
        [string]$Action,
        [int]$TargetPid = 0,
        [string]$ExpectedName = "",
        [string]$ServiceName = "",
        [string]$Priority = "Normal",
        [string]$HandleId = "",
        [string]$DumpType = "Mini"
    )

    if (-not ('PSRPM.NativeActionsV2' -as [type])) {
        $dynAsm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
            [System.Reflection.AssemblyName]::new("PSRPMNativeActionsV2Asm"),
            [System.Reflection.Emit.AssemblyBuilderAccess]::Run
        )
        $dynMod = $dynAsm.DefineDynamicModule("PSRPMNativeActionsV2Mod")
        $tb = $dynMod.DefineType("PSRPM.NativeActionsV2", [System.Reflection.TypeAttributes]"Public,Abstract,Sealed")

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

        &$addPInvoke "OpenProcess"       "kernel32.dll" ([IntPtr]) @([uint32], [int], [int])
        &$addPInvoke "CloseHandle"       "kernel32.dll" ([int])    @([IntPtr])
        &$addPInvoke "DuplicateHandle"   "kernel32.dll" ([int])    @([IntPtr], [IntPtr], [IntPtr], [IntPtr].MakeByRefType(), [uint32], [int], [uint32])
        &$addPInvoke "NtSuspendProcess"  "ntdll.dll"    ([int])    @([IntPtr])
        &$addPInvoke "NtResumeProcess"   "ntdll.dll"    ([int])    @([IntPtr])
        &$addPInvoke "MiniDumpWriteDump" "dbghelp.dll"  ([int])    @([IntPtr], [uint32], [IntPtr], [int], [IntPtr], [IntPtr], [IntPtr])

        [void]$tb.CreateType()
    }

    $res = @{
        Success = $false
        Action  = $Action
        PID     = $TargetPid
        Message = ""
    }

    try {
        switch ($Action) {
            "KillProcess" {
                $p = [System.Diagnostics.Process]::GetProcessById($TargetPid)
                if ($ExpectedName -and $p.ProcessName -ne $ExpectedName -and "$($p.ProcessName).exe" -ne $ExpectedName) {
                    throw "PID $TargetPid reuse detected (expected '$ExpectedName', found '$($p.ProcessName)'). Aborting termination."
                }
                $p.Kill()
                $res.Success = $true
                $res.Message = "Terminated process '$ExpectedName' (PID: $TargetPid)."
            }

            "KillTree" {
                # Single Atomic WMI Snapshot + CreationDate Validation + Two-Phase Suspend-Then-Kill
                $allProcs = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate, Name -ErrorAction Stop
                $procById = @{}
                $childrenByParent = @{}
                foreach ($wp in $allProcs) {
                    $id = [int]$wp.ProcessId
                    $ppid = [int]$wp.ParentProcessId
                    $procById[$id] = $wp
                    if (-not $childrenByParent.ContainsKey($ppid)) {
                        $childrenByParent[$ppid] = [System.Collections.Generic.List[int]]::new()
                    }
                    $childrenByParent[$ppid].Add($id)
                }

                $orderedTree = [System.Collections.Generic.List[int]]::new()
                $visited = [System.Collections.Generic.HashSet[int]]::new()

                $collectDescendants = {
                    param([int]$currPid)
                    if (-not $visited.Add($currPid)) { return }
                    $orderedTree.Add($currPid)
                    if ($childrenByParent.ContainsKey($currPid)) {
                        $parentObj = $procById[$currPid]
                        foreach ($childPid in $childrenByParent[$currPid]) {
                            if ($childPid -eq $currPid) { continue }
                            $childObj = $procById[$childPid]
                            $validChild = $true
                            if ($parentObj -and $childObj -and $parentObj.CreationDate -and $childObj.CreationDate) {
                                if ($childObj.CreationDate -lt $parentObj.CreationDate) {
                                    $validChild = $false
                                }
                            }
                            if ($validChild) {
                                & $collectDescendants $childPid
                            }
                        }
                    }
                }

                & $collectDescendants $TargetPid

                # Phase 1: Top-Down Suspend (Prevents Watchdog Respawning)
                foreach ($pIdVal in $orderedTree) {
                    $hSusp = [PSRPM.NativeActionsV2]::OpenProcess(0x0800, 0, $pIdVal) # PROCESS_SUSPEND_RESUME
                    if ($hSusp -ne [IntPtr]::Zero) {
                        try { [void][PSRPM.NativeActionsV2]::NtSuspendProcess($hSusp) } finally { [void][PSRPM.NativeActionsV2]::CloseHandle($hSusp) }
                    }
                }

                # Phase 2: Bottom-Up Termination (Leaves first, Root last)
                $killedCount = 0
                for ($i = $orderedTree.Count - 1; $i -ge 0; $i--) {
                    $killId = $orderedTree[$i]
                    try {
                        [System.Diagnostics.Process]::GetProcessById($killId).Kill()
                        $killedCount++
                    } catch {}
                }

                # Force service cache refresh if any services were impacted
                $script:LastSvcRefresh = [DateTime]::MinValue
                $res.Success = $true
                $res.Message = "Terminated process tree rooted at PID $TargetPid ($killedCount of $($orderedTree.Count) processes terminated)."
            }

            "SuspendProcess" {
                $hProc = [PSRPM.NativeActionsV2]::OpenProcess(0x0800, 0, $TargetPid) # PROCESS_SUSPEND_RESUME
                if ($hProc -eq [IntPtr]::Zero) {
                    throw "Access denied opening PID $TargetPid for PROCESS_SUSPEND_RESUME (0x0800)."
                }
                try {
                    $ntStatus = [PSRPM.NativeActionsV2]::NtSuspendProcess($hProc)
                    if ($ntStatus -ne 0) {
                        throw "NtSuspendProcess failed with NTSTATUS 0x$($ntStatus.ToString('X8'))."
                    }
                } finally {
                    [void][PSRPM.NativeActionsV2]::CloseHandle($hProc)
                }
                if ($script:LastDynState -and $script:ActivePidToKey -and $script:ActivePidToKey.ContainsKey($TargetPid)) {
                    $script:LastDynState.Remove($script:ActivePidToKey[$TargetPid])
                }
                $res.Success = $true
                $res.Message = "Suspended process '$ExpectedName' (PID: $TargetPid)."
            }

            "ResumeProcess" {
                $hProc = [PSRPM.NativeActionsV2]::OpenProcess(0x0800, 0, $TargetPid) # PROCESS_SUSPEND_RESUME
                if ($hProc -eq [IntPtr]::Zero) {
                    throw "Access denied opening PID $TargetPid for PROCESS_SUSPEND_RESUME (0x0800)."
                }
                try {
                    $ntStatus = [PSRPM.NativeActionsV2]::NtResumeProcess($hProc)
                    if ($ntStatus -ne 0) {
                        throw "NtResumeProcess failed with NTSTATUS 0x$($ntStatus.ToString('X8'))."
                    }
                } finally {
                    [void][PSRPM.NativeActionsV2]::CloseHandle($hProc)
                }
                if ($script:LastDynState -and $script:ActivePidToKey -and $script:ActivePidToKey.ContainsKey($TargetPid)) {
                    $script:LastDynState.Remove($script:ActivePidToKey[$TargetPid])
                }
                $res.Success = $true
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

                # Open target process with PROCESS_DUP_HANDLE (0x0040)
                $hProc = [PSRPM.NativeActionsV2]::OpenProcess(0x0040, 0, $TargetPid)
                if ($hProc -eq [IntPtr]::Zero) {
                    throw "Failed to open target process (PID $TargetPid) with PROCESS_DUP_HANDLE."
                }

                try {
                    $dup = [IntPtr]::Zero
                    # DUPLICATE_CLOSE_SOURCE = 0x00000001
                    $ret = [PSRPM.NativeActionsV2]::DuplicateHandle($hProc, $targetHandle, [IntPtr]::Zero, [ref]$dup, 0, 0, 1)
                    if ($ret -eq 0) {
                        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        throw "DuplicateHandle(DUPLICATE_CLOSE_SOURCE) failed with Win32 error code: $err."
                    }
                    $res.Success = $true
                    $res.Message = "Closed handle $HandleId in process (PID: $TargetPid)."
                } finally {
                    [void][PSRPM.NativeActionsV2]::CloseHandle($hProc)
                }
            }

            "CreateDump" {
                if ($TargetPid -le 4) {
                    throw "Cannot generate memory dump for System process (PID $TargetPid)."
                }
                $p = [System.Diagnostics.Process]::GetProcessById($TargetPid)
                $pName = if ($ExpectedName) { $ExpectedName } else { $p.ProcessName }
                if ($pName.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $pName = $pName.Substring(0, $pName.Length - 4)
                }

                # Ensure remote C:\temp directory exists
                $tempDir = "C:\temp"
                if (-not [System.IO.Directory]::Exists($tempDir)) {
                    [void][System.IO.Directory]::CreateDirectory($tempDir)
                }

                # Pre-flight disk space check on C:\
                $di = [System.IO.DriveInfo]::new("C:\")
                $freeBytes = $di.AvailableFreeSpace
                $wsBytes = [long]$p.WorkingSet64
                $neededBytes = if ($DumpType -eq "Full") { $wsBytes + 524288000L } else { 104857600L }
                if ($freeBytes -lt $neededBytes) {
                    throw "Insufficient disk space on C:\ (Available: $([Math]::Round($freeBytes/1MB,1)) MB, Required: $([Math]::Round($neededBytes/1MB,1)) MB)."
                }

                $ts = (Get-Date).ToString("yyyyMMdd_HHmmss")
                $dumpFileName = "PSRPM_Dump_${pName}_PID${TargetPid}_${DumpType}_${ts}.dmp"
                $dumpFilePath = [System.IO.Path]::Combine($tempDir, $dumpFileName)

                # Open process with PROCESS_QUERY_INFORMATION (0x0400) | PROCESS_VM_READ (0x0010)
                $hProc = [PSRPM.NativeActionsV2]::OpenProcess(0x0410, 0, $TargetPid)
                if ($hProc -eq [IntPtr]::Zero) {
                    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    throw "Failed to open process (PID $TargetPid) for memory dump (Win32 error: $err)."
                }

                try {
                    # MiniDumpNormal = 0x00000000; MiniDumpWithFullMemory = 0x00000002
                    $dumpTypeFlags = if ($DumpType -eq "Full") { 2 } else { 0 }
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    $fs = [System.IO.File]::Create($dumpFilePath)
                    try {
                        $hFile = $fs.SafeFileHandle.DangerousGetHandle()
                        $ok = [PSRPM.NativeActionsV2]::MiniDumpWriteDump($hProc, [uint32]$TargetPid, $hFile, $dumpTypeFlags, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
                        if ($ok -eq 0) {
                            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                            throw "MiniDumpWriteDump failed (Win32 error: $err)."
                        }
                    } finally {
                        $fs.Close()
                    }
                    $sw.Stop()

                    $fi = [System.IO.FileInfo]::new($dumpFilePath)
                    $fileSizeMB = [Math]::Round($fi.Length / 1MB, 2)
                    $res.Success = $true
                    $res.Message = "Created $DumpType Dump for '$pName' (PID: $TargetPid) at '$dumpFilePath' ($fileSizeMB MB in $($sw.ElapsedMilliseconds) ms)."
                    $res.DumpPath = $dumpFilePath
                    $res.FileSizeBytes = $fi.Length
                    $res.ElapsedMs = $sw.ElapsedMilliseconds
                } finally {
                    [void][PSRPM.NativeActionsV2]::CloseHandle($hProc)
                }
            }

            "SetPriority" {
                $p = [System.Diagnostics.Process]::GetProcessById($TargetPid)
                $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$Priority
                $res.Success = $true
                $res.Message = "Set priority of '$ExpectedName' (PID: $TargetPid) to $Priority."
            }

            "ControlService" {
                # ExpectedName holds the service operation: Start, Stop, or Restart
                $op = $ExpectedName
                if ($op -eq "Start") {
                    Start-Service -Name $ServiceName -ErrorAction Stop
                } elseif ($op -eq "Stop") {
                    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                } elseif ($op -eq "Restart") {
                    Restart-Service -Name $ServiceName -Force -ErrorAction Stop
                }
                $script:LastSvcRefresh = [DateTime]::MinValue
                $res.Success = $true
                $res.Message = "Service '$ServiceName' action '$op' completed successfully."
            }

            default {
                throw "Unknown action '$Action'."
            }
        }
    } catch {
        $res.Success = $false
        $res.Message = $_.Exception.Message
    }

    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
    $jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    return $jss.Serialize($res)
}
