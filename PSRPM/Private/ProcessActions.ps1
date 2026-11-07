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
        [string]$Priority = "Normal"
    )

    if (-not ('PSRPM.NativeActions' -as [type])) {
        $dynAsm = [AppDomain]::CurrentDomain.DefineDynamicAssembly(
            [System.Reflection.AssemblyName]::new("PSRPMNativeActionsAsm"),
            [System.Reflection.Emit.AssemblyBuilderAccess]::Run
        )
        $dynMod = $dynAsm.DefineDynamicModule("PSRPMNativeActionsMod")
        $tb = $dynMod.DefineType("PSRPM.NativeActions", [System.Reflection.TypeAttributes]"Public,Abstract,Sealed")

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

        &$addPInvoke "OpenProcess"      "kernel32.dll" ([IntPtr]) @([uint32], [int], [int])
        &$addPInvoke "CloseHandle"      "kernel32.dll" ([int])    @([IntPtr])
        &$addPInvoke "NtSuspendProcess" "ntdll.dll"    ([int])    @([IntPtr])
        &$addPInvoke "NtResumeProcess"  "ntdll.dll"    ([int])    @([IntPtr])

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
                    $hSusp = [PSRPM.NativeActions]::OpenProcess(0x0800, 0, $pIdVal) # PROCESS_SUSPEND_RESUME
                    if ($hSusp -ne [IntPtr]::Zero) {
                        try { [void][PSRPM.NativeActions]::NtSuspendProcess($hSusp) } finally { [void][PSRPM.NativeActions]::CloseHandle($hSusp) }
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
                $hProc = [PSRPM.NativeActions]::OpenProcess(0x0800, 0, $TargetPid) # PROCESS_SUSPEND_RESUME
                if ($hProc -eq [IntPtr]::Zero) {
                    throw "Access denied opening PID $TargetPid for PROCESS_SUSPEND_RESUME (0x0800)."
                }
                try {
                    $ntStatus = [PSRPM.NativeActions]::NtSuspendProcess($hProc)
                    if ($ntStatus -ne 0) {
                        throw "NtSuspendProcess failed with NTSTATUS 0x$($ntStatus.ToString('X8'))."
                    }
                } finally {
                    [void][PSRPM.NativeActions]::CloseHandle($hProc)
                }
                if ($script:LastDynState -and $script:ActivePidToKey -and $script:ActivePidToKey.ContainsKey($TargetPid)) {
                    $script:LastDynState.Remove($script:ActivePidToKey[$TargetPid])
                }
                $res.Success = $true
                $res.Message = "Suspended process '$ExpectedName' (PID: $TargetPid)."
            }

            "ResumeProcess" {
                $hProc = [PSRPM.NativeActions]::OpenProcess(0x0800, 0, $TargetPid) # PROCESS_SUSPEND_RESUME
                if ($hProc -eq [IntPtr]::Zero) {
                    throw "Access denied opening PID $TargetPid for PROCESS_SUSPEND_RESUME (0x0800)."
                }
                try {
                    $ntStatus = [PSRPM.NativeActions]::NtResumeProcess($hProc)
                    if ($ntStatus -ne 0) {
                        throw "NtResumeProcess failed with NTSTATUS 0x$($ntStatus.ToString('X8'))."
                    }
                } finally {
                    [void][PSRPM.NativeActions]::CloseHandle($hProc)
                }
                if ($script:LastDynState -and $script:ActivePidToKey -and $script:ActivePidToKey.ContainsKey($TargetPid)) {
                    $script:LastDynState.Remove($script:ActivePidToKey[$TargetPid])
                }
                $res.Success = $true
                $res.Message = "Resumed process '$ExpectedName' (PID: $TargetPid)."
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
