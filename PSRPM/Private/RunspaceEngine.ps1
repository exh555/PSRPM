# Requires -Version 5.1
# PSRPM Host Synchronization Engine & Single-Owner Runspace Coordinator
# Features:
# - Single-Owner PSSession Command Bus (ConcurrentQueue + AutoResetEvent <1ms wake)
# - Differential JSON Ingestion via JavaScriptSerializer
# - PID-Reuse-Safe Parent-Child Tree Builder with Pixel-Snapped Vector Guide Lines
# - Ancestor-Preserving Tree Filter & Sibling-Aware Column Sorting
# - Flicker-Free In-Place ObservableCollection Reconciliation (Zero .Clear() calls)

function Start-PSRPMEngine {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.Runspaces.PSSession]$PSSession,

        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$Window,

        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [System.Collections.ObjectModel.ObservableCollection[Object]]$ProcessCollection,

        [AllowEmptyCollection()]
        [Parameter(Mandatory = $false)]
        [System.Collections.ObjectModel.ObservableCollection[Object]]$ServicesCollection,

        [Parameter(Mandatory = $true)]
        [Object]$SummaryViewModel,

        [Parameter(Mandatory = $true)]
        [ScriptBlock]$CollectorScript,

        [Parameter(Mandatory = $true)]
        [ScriptBlock]$InspectorScript,

        [Parameter(Mandatory = $true)]
        [ScriptBlock]$ActionScript,

        [Parameter(Mandatory = $false)]
        [int]$IntervalMs = 1000,

        [Parameter(Mandatory = $false)]
        [bool]$IsLocal = $false,

        [Parameter(Mandatory = $false)]
        [string]$TargetName = "localhost",

        [Parameter(Mandatory = $false)]
        [string]$InitialTabId = "tab_0",

        [AllowNull()]
        [Parameter(Mandatory = $false)]
        [System.Windows.Controls.TextBox]$LogConsole
    )

    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue

    $stateContainer = [hashtable]::Synchronized(@{
        IntervalMs          = $IntervalMs
        IsPaused            = $false
        IsTreeMode          = $true
        IsDarkTheme         = $false
        EnableCategoryHighlights = $true
        SortProperty        = "PID"
        SortDescending      = $false
        FilterText          = ""
        CategoryFilter      = ""
        ForceFullSync       = $true
        FullSyncGen         = 1L
        ClearHostMaps       = $false
        ActiveTabId         = $InitialTabId
        PayloadTabId        = $InitialTabId
        Payload             = $null
        PollLatencyMs       = 0
        PayloadBytes        = 0
        ConnectionState     = if ($IsLocal) { "LocalMode" } else { "Connected" }
        TargetDisplayName   = $TargetName
        TransportBadge      = if ($IsLocal) { "LOCAL" } else { "WINRM" }
        LastErr             = $null
        VerboseTelemetryLog = $true
        IsStopping          = $false
        EnableNetEtw        = $false
        NetEtwCap           = 0
        NetEtwEventsPerSec  = 0
        ResetNetBreaker     = $false
        OnNetEtwStateChanged = $null
        LastSampleUtcTicks  = 0L
        TelemetryAgeMs      = 0
        FreshnessState      = "Fresh"
        CommandQueue        = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
        ResultQueue         = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
        WakeEvent           = [System.Threading.AutoResetEvent]::new($false)
    })

    # Create Coordinator Background Runspace
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $rs  = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.Open()

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    $collectorText = $CollectorScript.ToString()
    $inspectorText = $InspectorScript.ToString()
    $actionText    = $ActionScript.ToString()

    [void]$ps.AddScript({
        param(
            $session,
            $stateContainer,
            $collectorCode,
            $inspectorCode,
            $actionCode,
            $isLocalMode,
            $initTabId
        )

        $newLocalCollectorSb = {
            $m = New-Module -ScriptBlock {}
            $m.NewBoundScriptBlock([scriptblock]::Create($collectorCode))
        }
        $inspectorSb = [scriptblock]::Create($inspectorCode)
        $actionSb    = [scriptblock]::Create($actionCode)

        $asyncWorkerLoopText = {
            param($jobQueue, $doneQueue, $wakeEv, $state, $inspCode, $actCode, $coordWakeEv)
            $wInspSb = [scriptblock]::Create($inspCode)
            $wActSb  = [scriptblock]::Create($actCode)
            while (-not $state.IsStopping) {
                $job = $null
                while (-not $state.IsStopping -and $jobQueue.TryDequeue([ref]$job)) {
                    $swJob = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        $jType = [string]$job.CommandType
                        $payload = $null
                        if ($jType -eq "InspectPid") {
                            $payload = & $wInspSb ([int]$job.TargetPid) ([bool]$job.VerifySignature) ([string]$job.InspectMode)
                        } elseif ($jType -eq "FindHandles") {
                            $payload = & $wInspSb 0 $false "FindHandles" ([string]$job.Query)
                        } elseif ($jType -eq "ProcessAction") {
                            $payload = & $wActSb ([string]$job.Action) ([int]$job.TargetPid) ([string]$job.ExpectedName) ([string]$job.ServiceName) ([string]$job.Priority) ([string]$job.HandleId) ([string]$job.DumpType) ([long]$job.ExpectedCreateTime)
                        } elseif ($jType -eq "BatchProcessAction") {
                            $resItems = [System.Collections.Generic.List[string]]::new()
                            $pids  = $job.TargetPids
                            $names = $job.TargetNames
                            $times = $job.TargetTimes
                            for ($ti = 0; $ti -lt $pids.Count; $ti++) {
                                $oneJson = & $wActSb ([string]$job.Action) ([int]$pids[$ti]) ([string]$names[$ti]) "" ([string]$job.Priority) "" ([string]$job.DumpType) ([long]$times[$ti])
                                if (-not [string]::IsNullOrWhiteSpace($oneJson)) {
                                    [void]$resItems.Add([string]$oneJson)
                                }
                            }
                            $payload = "[" + ($resItems -join ",") + "]"
                        }
                        $swJob.Stop()
                        $job['Success']     = $true
                        $job['PayloadJson'] = [string]$payload
                        $job['ElapsedMs']   = $swJob.ElapsedMilliseconds
                        $doneQueue.Enqueue($job)
                    } catch {
                        $swJob.Stop()
                        $job['Success']   = $false
                        $job['Error']     = $_.Exception.Message
                        $job['ElapsedMs'] = $swJob.ElapsedMilliseconds
                        $doneQueue.Enqueue($job)
                    }
                    if ($coordWakeEv) {
                        try { [void]$coordWakeEv.Set() } catch {}
                    }
                }
                if (-not $state.IsStopping) {
                    [void]$wakeEv.WaitOne(200)
                }
            }
        }.ToString()

        $script:CoordLocalWorker = $null
        $ensureLocalWorker = {
            if ($null -eq $script:CoordLocalWorker) {
                $wIss   = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
                $wRs    = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($wIss)
                $wRs.Open()
                $wPs    = [System.Management.Automation.PowerShell]::Create()
                $wPs.Runspace = $wRs
                $wJobQ  = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
                $wDoneQ = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
                $wWake  = [System.Threading.AutoResetEvent]::new($false)
                $wState = [hashtable]::Synchronized(@{ IsStopping = $false })
                [void]$wPs.AddScript($asyncWorkerLoopText).AddArgument($wJobQ).AddArgument($wDoneQ).AddArgument($wWake).AddArgument($wState).AddArgument($inspectorCode).AddArgument($actionCode).AddArgument($stateContainer.WakeEvent)
                $wHnd = $wPs.BeginInvoke()
                $script:CoordLocalWorker = @{
                    Runspace  = $wRs
                    PowerShell = $wPs
                    Handle    = $wHnd
                    JobQueue  = $wJobQ
                    DoneQueue = $wDoneQ
                    WakeEvent = $wWake
                    State     = $wState
                }
            }
            return $script:CoordLocalWorker
        }

        $stopRemoteWorker = {
            param($sessObj)
            if (-not $sessObj -or $sessObj.IsLocal -or -not $sessObj.WorkerInitialized) { return }
            if ($sessObj.Session -and $sessObj.Session.State -eq 'Opened') {
                try {
                    Invoke-Command -Session $sessObj.Session -ScriptBlock {
                        if ($script:PSRPMAsyncWorker) {
                            try { $script:PSRPMAsyncWorker.State.IsStopping = $true } catch {}
                            try { [void]$script:PSRPMAsyncWorker.WakeEvent.Set() } catch {}
                            try { $script:PSRPMAsyncWorker.PowerShell.Dispose() } catch {}
                            try { $script:PSRPMAsyncWorker.Runspace.Close(); $script:PSRPMAsyncWorker.Runspace.Dispose() } catch {}
                            try { $script:PSRPMAsyncWorker.WakeEvent.Dispose() } catch {}
                            $script:PSRPMAsyncWorker = $null
                        }
                    } -ErrorAction SilentlyContinue
                } catch {}
            }
            $sessObj.WorkerInitialized = $false
        }

        $failSessionPendingJobs = {
            param($sessObj, [string]$reason)
            if (-not $sessObj -or -not $sessObj.PendingJobs -or $sessObj.PendingJobs.Count -eq 0) { return }
            $pKeys = @($sessObj.PendingJobs.Keys)
            foreach ($rk in $pKeys) {
                $pj = $sessObj.PendingJobs[$rk]
                [void]$sessObj.PendingJobs.Remove($rk)
                $pj['Success'] = $false
                $pj['Error']   = $reason
                $stateContainer.ResultQueue.Enqueue($pj)
            }
        }

        $submitAsyncJob = {
            param($sessObj, [hashtable]$jobDesc)
            $jobDesc['TabId'] = $activeTabId
            if ($sessObj) {
                $sessObj.PendingJobs[$jobDesc.RequestId] = $jobDesc
            }
            $useLoc = if ($sessObj) { [bool]$sessObj.IsLocal } else { $isLocalMode }
            if ($useLoc) {
                $lw = &$ensureLocalWorker
                $lw.JobQueue.Enqueue($jobDesc)
                [void]$lw.WakeEvent.Set()
            } else {
                $uSess = if ($sessObj) { $sessObj.Session } else { $session }
                if (-not $uSess -or $uSess.State -ne 'Opened') {
                    if ($sessObj) { [void]$sessObj.PendingJobs.Remove($jobDesc.RequestId) }
                    throw "WinRM session is not open for async job submission."
                }
                if ($sessObj -and -not $sessObj.WorkerInitialized) {
                    Invoke-Command -Session $uSess -ScriptBlock {
                        param($loopCode, $iCode, $aCode)
                        if (-not $script:PSRPMAsyncWorker) {
                            $wIss   = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
                            $wRs    = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($wIss)
                            $wRs.Open()
                            $wPs    = [System.Management.Automation.PowerShell]::Create()
                            $wPs.Runspace = $wRs
                            $wJobQ  = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
                            $wDoneQ = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
                            $wWake  = [System.Threading.AutoResetEvent]::new($false)
                            $wState = [hashtable]::Synchronized(@{ IsStopping = $false })
                            [void]$wPs.AddScript($loopCode).AddArgument($wJobQ).AddArgument($wDoneQ).AddArgument($wWake).AddArgument($wState).AddArgument($iCode).AddArgument($aCode).AddArgument($null)
                            $wHnd = $wPs.BeginInvoke()
                            $script:PSRPMAsyncWorker = @{
                                Runspace   = $wRs
                                PowerShell = $wPs
                                Handle     = $wHnd
                                JobQueue   = $wJobQ
                                DoneQueue  = $wDoneQ
                                WakeEvent  = $wWake
                                State      = $wState
                            }
                        }
                    } -ArgumentList @($asyncWorkerLoopText, $inspectorCode, $actionCode) -ErrorAction Stop
                    $sessObj.WorkerInitialized = $true
                }
                $enqOk = Invoke-Command -Session $uSess -ScriptBlock {
                    param($j)
                    if ($script:PSRPMAsyncWorker) {
                        $script:PSRPMAsyncWorker.JobQueue.Enqueue($j)
                        [void]$script:PSRPMAsyncWorker.WakeEvent.Set()
                        $true
                    } else {
                        $false
                    }
                } -ArgumentList @($jobDesc) -ErrorAction Stop
                if (-not $enqOk) {
                    if ($sessObj) { $sessObj.WorkerInitialized = $false }
                    throw "Target async worker was not initialized on remote host."
                }
            }
        }

        $harvestAsyncJobs = {
            if ($script:CoordLocalWorker) {
                $dJob = $null
                while ($script:CoordLocalWorker.DoneQueue.TryDequeue([ref]$dJob)) {
                    $jTab = [string]$dJob.TabId
                    $rId  = [string]$dJob.RequestId
                    if ($sessions.ContainsKey($jTab) -and $sessions[$jTab].PendingJobs.ContainsKey($rId)) {
                        [void]$sessions[$jTab].PendingJobs.Remove($rId)
                        $stateContainer.ResultQueue.Enqueue($dJob)
                    }
                }
            }
            foreach ($sItem in $sessions.Values) {
                if (-not $sItem.IsLocal -and $sItem.PendingJobs.Count -gt 0 -and $sItem.Session -and $sItem.Session.State -eq 'Opened') {
                    try {
                        $remDone = Invoke-Command -Session $sItem.Session -ScriptBlock {
                            $list = [System.Collections.Generic.List[hashtable]]::new()
                            if ($script:PSRPMAsyncWorker) {
                                $it = $null
                                while ($script:PSRPMAsyncWorker.DoneQueue.TryDequeue([ref]$it)) {
                                    $list.Add($it)
                                }
                            }
                            return ,$list
                        } -ErrorAction Stop
                        if ($remDone) {
                            foreach ($rd in $remDone) {
                                if ($null -ne $rd -and $rd.ContainsKey('RequestId')) {
                                    $rId = [string]$rd['RequestId']
                                    if ($sItem.PendingJobs.ContainsKey($rId)) {
                                        [void]$sItem.PendingJobs.Remove($rId)
                                        $stateContainer.ResultQueue.Enqueue($rd)
                                    }
                                }
                            }
                        }
                    } catch {}
                }
            }
        }

        # Multi-Host Session Dictionary (TabId -> @{ Session, IsLocal, Target, Badge, CollectorSb, ... })
        $sessions = @{}
        $initBadge = if ($isLocalMode) { "LOCAL" } else { "WINRM" }
        $initComp  = if ($isLocalMode) { "$env:COMPUTERNAME" } elseif ($session) { $session.ComputerName } else { $stateContainer.TargetDisplayName }
        $sessions[$initTabId] = @{
            Session              = $session
            IsLocal              = $isLocalMode
            Target               = $stateContainer.TargetDisplayName
            Badge                = $initBadge
            CollectorSb          = &$newLocalCollectorSb
            CollectorInitialized = $false
            InspectorInitialized = $false
            ActionInitialized    = $false
            WorkerInitialized    = $false
            PendingJobs          = @{}
            ConnectionConfig     = @{
                ComputerName = $initComp
                IsLocal      = $isLocalMode
                Credential   = $null
                Port         = 0
                UseSSL       = ($initBadge -eq "WINRM-SSL")
            }
            ConnState           = if ($isLocalMode) { "LocalMode" } else { "Connected" }
            ConsecutiveFailures = 0
            ReconnectAttempts   = 0
            NextReconnectTicks  = 0L
            BackoffSec          = 1
            NetEtwStarted       = $false
        }
        $activeTabId = $initTabId

        $lastPollUtcTicks = 0L
        $nextScheduledUtcTicks = [DateTime]::UtcNow.Ticks
        $prevPausedState = [bool]$stateContainer.IsPaused

        $stopSessionNetEtw = {
            param($sessObj)
            if (-not $sessObj -or -not $sessObj.NetEtwStarted) { return }
            try {
                if ($sessObj.IsLocal) {
                    if ($sessObj.CollectorSb) {
                        & $sessObj.CollectorSb $false $false "Stop" | Out-Null
                    }
                } elseif ($sessObj.Session -and $sessObj.Session.State -eq 'Opened' -and $sessObj.CollectorInitialized) {
                    Invoke-Command -Session $sessObj.Session -ScriptBlock {
                        if ($script:PSRPMCollectorInvoker) {
                            & $script:PSRPMCollectorInvoker $false $false "Stop" | Out-Null
                        }
                    } -ErrorAction SilentlyContinue
                }
            } catch {}
            $sessObj.NetEtwStarted = $false
        }

        $setFullSync = {
            param([bool]$val)
            [System.Threading.Monitor]::Enter($stateContainer.SyncRoot)
            try {
                $stateContainer.ForceFullSync = $val
                if ($val) {
                    $stateContainer.FullSyncGen = [long]$stateContainer.FullSyncGen + 1L
                }
            } finally {
                [System.Threading.Monitor]::Exit($stateContainer.SyncRoot)
            }
        }

        try {
        while (-not $stateContainer.IsStopping) {
            # 1. Drain High-Priority User Commands (Cooperative Quantum: at most 5 commands or 250 ms)
            $cmdBudgetSw = [System.Diagnostics.Stopwatch]::StartNew()
            $cmdCount = 0
            $cmd = $null
            while ($cmdCount -lt 5 -and $cmdBudgetSw.ElapsedMilliseconds -lt 250 -and $stateContainer.CommandQueue.TryDequeue([ref]$cmd)) {
                $cmdCount++
                if ($stateContainer.IsStopping) { break }
                $swCmd = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $activeSessObj = if ($sessions.ContainsKey($activeTabId)) { $sessions[$activeTabId] } else { $null }

                    switch ($cmd.CommandType) {
                        "InspectPid" {
                            $targetPid   = [int]$cmd.TargetPid
                            $verifySig   = [bool]$cmd.VerifySignature
                            $inspectMode = if ($cmd.InspectMode) { [string]$cmd.InspectMode } else { "Core" }
                            $useLocal    = if ($activeSessObj) { [bool]$activeSessObj.IsLocal } else { $isLocalMode }
                            $useSess     = if ($activeSessObj) { $activeSessObj.Session } else { $session }

                            if ($verifySig -or $inspectMode -in @("Modules", "Handles", "All")) {
                                &$submitAsyncJob $activeSessObj @{
                                    RequestId       = $cmd.RequestId
                                    CommandType     = "InspectPid"
                                    InspectMode     = $inspectMode
                                    TargetPid       = $targetPid
                                    VerifySignature = $verifySig
                                }
                            } else {
                                $jsonRes = if ($useLocal) {
                                    & $inspectorSb $targetPid $verifySig $inspectMode
                                } else {
                                    if ($activeSessObj -and -not $activeSessObj.InspectorInitialized) {
                                        Invoke-Command -Session $useSess -ScriptBlock {
                                            param($code)
                                            $script:PSRPMInspectorInvoker = [scriptblock]::Create($code)
                                        } -ArgumentList @($inspectorCode) -ErrorAction Stop
                                        $activeSessObj.InspectorInitialized = $true
                                    }
                                    $resInsp = Invoke-Command -Session $useSess -ScriptBlock {
                                        param($p, $v, $m)
                                        if ($script:PSRPMInspectorInvoker) {
                                            & $script:PSRPMInspectorInvoker $p $v $m
                                        } else {
                                            $null
                                        }
                                    } -ArgumentList @($targetPid, $verifySig, $inspectMode) -ErrorAction Stop

                                    if (-not $resInsp) {
                                        Invoke-Command -Session $useSess -ScriptBlock {
                                            param($code)
                                            $script:PSRPMInspectorInvoker = [scriptblock]::Create($code)
                                        } -ArgumentList @($inspectorCode) -ErrorAction Stop
                                        $activeSessObj.InspectorInitialized = $true
                                        $resInsp = Invoke-Command -Session $useSess -ScriptBlock {
                                            param($p, $v, $m)
                                            if ($script:PSRPMInspectorInvoker) {
                                                & $script:PSRPMInspectorInvoker $p $v $m
                                            } else {
                                                $null
                                            }
                                        } -ArgumentList @($targetPid, $verifySig, $inspectMode) -ErrorAction Stop
                                    }
                                    $resInsp
                                }
                                $swCmd.Stop()
                                $stateContainer.ResultQueue.Enqueue(@{
                                    RequestId   = $cmd.RequestId
                                    CommandType = "InspectPid"
                                    InspectMode = $inspectMode
                                    Success     = $true
                                    TargetPid   = $targetPid
                                    PayloadJson = [string]$jsonRes
                                    ElapsedMs   = $swCmd.ElapsedMilliseconds
                                })
                            }
                        }

                        "ProcessAction" {
                            $actName  = [string]$cmd.Action
                            $tPid     = [int]$cmd.TargetPid
                            $expName  = [string]$cmd.ExpectedName
                            $svcName  = [string]$cmd.ServiceName
                            $prio     = [string]$cmd.Priority
                            $hId       = if ($cmd.HandleId) { [string]$cmd.HandleId } else { "" }
                            $dType     = if ($cmd.DumpType) { [string]$cmd.DumpType } else { "Mini" }
                            $expCreate = if ($cmd.ExpectedCreateTime) { [long]$cmd.ExpectedCreateTime } else { 0L }
                            $useLocal  = if ($activeSessObj) { [bool]$activeSessObj.IsLocal } else { $isLocalMode }
                            $useSess   = if ($activeSessObj) { $activeSessObj.Session } else { $session }

                            if ($actName -in @("CreateDump", "ControlService")) {
                                &$submitAsyncJob $activeSessObj @{
                                    RequestId          = $cmd.RequestId
                                    CommandType        = "ProcessAction"
                                    Action             = $actName
                                    TargetPid          = $tPid
                                    ExpectedName       = $expName
                                    ServiceName        = $svcName
                                    Priority           = $prio
                                    HandleId           = $hId
                                    DumpType           = $dType
                                    ExpectedCreateTime = $expCreate
                                }
                            } else {
                                $jsonRes = if ($useLocal) {
                                    & $actionSb $actName $tPid $expName $svcName $prio $hId $dType $expCreate
                                } else {
                                    if ($activeSessObj -and -not $activeSessObj.ActionInitialized) {
                                        Invoke-Command -Session $useSess -ScriptBlock {
                                            param($code)
                                            $script:PSRPMActionInvoker = [scriptblock]::Create($code)
                                        } -ArgumentList @($actionCode) -ErrorAction Stop
                                        $activeSessObj.ActionInitialized = $true
                                    }
                                    Invoke-Command -Session $useSess -ScriptBlock {
                                        param($a, $p, $e, $s, $pr, $h, $dt, $ct)
                                        if ($script:PSRPMActionInvoker) {
                                            & $script:PSRPMActionInvoker $a $p $e $s $pr $h $dt $ct
                                        } else {
                                            $null
                                        }
                                    } -ArgumentList @($actName, $tPid, $expName, $svcName, $prio, $hId, $dType, $expCreate) -ErrorAction Stop
                                }
                                $swCmd.Stop()
                                $stateContainer.ResultQueue.Enqueue(@{
                                    RequestId   = $cmd.RequestId
                                    CommandType = "ProcessAction"
                                    Action      = $actName
                                    Success     = $true
                                    PayloadJson = [string]$jsonRes
                                    ElapsedMs   = $swCmd.ElapsedMilliseconds
                                })
                            }
                        }

                        "BatchProcessAction" {
                            $actName  = [string]$cmd.Action
                            $prio     = if ($cmd.Priority) { [string]$cmd.Priority } else { "Normal" }
                            $dType    = if ($cmd.DumpType) { [string]$cmd.DumpType } else { "Mini" }
                            $targets  = @($cmd.Targets)
                            $useLocal = if ($activeSessObj) { [bool]$activeSessObj.IsLocal } else { $isLocalMode }
                            $useSess  = if ($activeSessObj) { $activeSessObj.Session } else { $session }

                            $tPids  = [int[]]::new($targets.Count)
                            $tNames = [string[]]::new($targets.Count)
                            $tTimes = [long[]]::new($targets.Count)
                            for ($ti = 0; $ti -lt $targets.Count; $ti++) {
                                $tObj = $targets[$ti]
                                $tPids[$ti]  = [int]$tObj.TargetPid
                                $tNames[$ti] = [string]$tObj.ExpectedName
                                $tTimes[$ti] = if ($tObj.ExpectedCreateTime) { [long]$tObj.ExpectedCreateTime } else { 0L }
                            }

                            if ($targets.Count -gt 3 -or $actName -eq "CreateDump") {
                                &$submitAsyncJob $activeSessObj @{
                                    RequestId   = $cmd.RequestId
                                    CommandType = "BatchProcessAction"
                                    Action      = $actName
                                    Priority    = $prio
                                    DumpType    = $dType
                                    TargetPids  = $tPids
                                    TargetNames = $tNames
                                    TargetTimes = $tTimes
                                }
                            } else {
                                $jsonRes = if ($useLocal) {
                                    $resItems = [System.Collections.Generic.List[string]]::new()
                                    for ($ti = 0; $ti -lt $tPids.Count; $ti++) {
                                        $oneJson = & $actionSb $actName $tPids[$ti] $tNames[$ti] "" $prio "" $dType $tTimes[$ti]
                                        if (-not [string]::IsNullOrWhiteSpace($oneJson)) {
                                            [void]$resItems.Add([string]$oneJson)
                                        }
                                    }
                                    "[" + ($resItems -join ",") + "]"
                                } else {
                                    if ($activeSessObj -and -not $activeSessObj.ActionInitialized) {
                                        Invoke-Command -Session $useSess -ScriptBlock {
                                            param($code)
                                            $script:PSRPMActionInvoker = [scriptblock]::Create($code)
                                        } -ArgumentList @($actionCode) -ErrorAction Stop
                                        $activeSessObj.ActionInitialized = $true
                                    }
                                    Invoke-Command -Session $useSess -ScriptBlock {
                                        param($a, $pids, $names, $times, $pr, $dt)
                                        $resItems = [System.Collections.Generic.List[string]]::new()
                                        if ($script:PSRPMActionInvoker) {
                                            for ($ti = 0; $ti -lt $pids.Count; $ti++) {
                                                $oneJson = & $script:PSRPMActionInvoker $a ([int]$pids[$ti]) ([string]$names[$ti]) "" $pr "" $dt ([long]$times[$ti])
                                                if (-not [string]::IsNullOrWhiteSpace($oneJson)) {
                                                    [void]$resItems.Add([string]$oneJson)
                                                }
                                            }
                                        }
                                        "[" + ($resItems -join ",") + "]"
                                    } -ArgumentList @($actName, $tPids, $tNames, $tTimes, $prio, $dType) -ErrorAction Stop
                                }
                                $swCmd.Stop()
                                $stateContainer.ResultQueue.Enqueue(@{
                                    RequestId   = $cmd.RequestId
                                    CommandType = "BatchProcessAction"
                                    Action      = $actName
                                    Success     = $true
                                    PayloadJson = [string]$jsonRes
                                    ElapsedMs   = $swCmd.ElapsedMilliseconds
                                })
                            }
                        }

                        "FindHandles" {
                            $query = [string]$cmd.Query
                            &$submitAsyncJob $activeSessObj @{
                                RequestId   = $cmd.RequestId
                                CommandType = "FindHandles"
                                Query       = $query
                            }
                        }

                        "AddTabSession" {
                            $newTabId = [string]$cmd.TabId
                            $newComp  = [string]$cmd.ComputerName
                            $newLocal = [bool]$cmd.IsLocal
                            $newCred  = $cmd.Credential
                            $newPort  = [int]$cmd.Port
                            $newSsl   = [bool]$cmd.UseSSL

                            $newSess = $null
                            $badge = "LOCAL"
                            $targetName = if ($newLocal) { "$env:COMPUTERNAME" } else { $newComp }

                            if (-not $newLocal) {
                                $so = New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 30000 -CancelTimeout 5000 -NoMachineProfile
                                $sParams = @{
                                    ComputerName  = $newComp
                                    SessionOption = $so
                                    ErrorAction   = 'Stop'
                                }
                                if ($newCred) { $sParams['Credential'] = $newCred }
                                if ($newPort -gt 0) { $sParams['Port'] = $newPort }
                                if ($newSsl)  { $sParams['UseSSL'] = $true }

                                $newSess = New-PSSession @sParams
                                $badge = if ($newSsl) { "WINRM-SSL" } else { "WINRM" }
                            }

                            $sessions[$newTabId] = @{
                                Session              = $newSess
                                IsLocal              = $newLocal
                                Target               = $targetName
                                Badge                = $badge
                                CollectorSb          = &$newLocalCollectorSb
                                CollectorInitialized = $false
                                InspectorInitialized = $false
                                ActionInitialized    = $false
                                WorkerInitialized    = $false
                                PendingJobs          = @{}
                                ConnectionConfig     = @{
                                    ComputerName = $newComp
                                    IsLocal      = $newLocal
                                    Credential   = $newCred
                                    Port         = $newPort
                                    UseSSL       = $newSsl
                                }
                                ConnState           = if ($newLocal) { "LocalMode" } else { "Connected" }
                                ConsecutiveFailures = 0
                                ReconnectAttempts   = 0
                                NextReconnectTicks  = 0L
                                BackoffSec          = 1
                                NetEtwStarted       = $false
                            }

                            if ($sessions.ContainsKey($activeTabId) -and $activeTabId -ne $newTabId) {
                                &$stopSessionNetEtw $sessions[$activeTabId]
                            }
                            $activeTabId = $newTabId
                            $stateContainer.ActiveTabId       = $newTabId
                            $stateContainer.TargetDisplayName = $targetName
                            $stateContainer.TransportBadge    = $badge
                            $stateContainer.ConnectionState   = if ($newLocal) { "LocalMode" } else { "Connected" }
                            $stateContainer.EnableNetEtw      = $false
                            &$setFullSync $true

                            $swCmd.Stop()
                            $stateContainer.ResultQueue.Enqueue(@{
                                RequestId   = $cmd.RequestId
                                CommandType = "AddTabSession"
                                Success     = $true
                                TabId       = $newTabId
                                Target      = $targetName
                                Transport   = $badge
                                IsLocal     = $newLocal
                                ConnState   = $stateContainer.ConnectionState
                                ElapsedMs   = $swCmd.ElapsedMilliseconds
                            })
                        }

                        "SelectTabSession" {
                            $selTabId = [string]$cmd.TabId
                            if ($sessions.ContainsKey($selTabId)) {
                                if ($activeTabId -ne $selTabId -and $sessions.ContainsKey($activeTabId)) {
                                    &$stopSessionNetEtw $sessions[$activeTabId]
                                }
                                $activeTabId = $selTabId
                                $curr = $sessions[$selTabId]
                                $stateContainer.ActiveTabId       = $selTabId
                                $stateContainer.TargetDisplayName = $curr.Target
                                $stateContainer.TransportBadge    = $curr.Badge
                                $stateContainer.ConnectionState   = $curr.ConnState
                                if ($cmd.ContainsKey('EnableNetEtw')) {
                                    $stateContainer.EnableNetEtw = [bool]$cmd.EnableNetEtw
                                }
                                if ($cmd.ContainsKey('NetEtwCap')) {
                                    $stateContainer.NetEtwCap = [int]$cmd.NetEtwCap
                                }
                                if ($cmd.ContainsKey('NetEtwEventsPerSec')) {
                                    $stateContainer.NetEtwEventsPerSec = [int]$cmd.NetEtwEventsPerSec
                                }
                                &$setFullSync ([bool]$cmd.ForceFullSync)
                            }
                            $swCmd.Stop()
                            $stateContainer.ResultQueue.Enqueue(@{
                                RequestId   = $cmd.RequestId
                                CommandType = "SelectTabSession"
                                Success     = $true
                                TabId       = $selTabId
                            })
                        }

                        "SetNetEtw" {
                            $reqEnable = [bool]$cmd.Enable
                            $reqReset  = if ($cmd.ContainsKey('ResetBreaker')) { [bool]$cmd.ResetBreaker } else { $false }
                            $stateContainer.EnableNetEtw = $reqEnable
                            if ($reqReset) {
                                $stateContainer.ResetNetBreaker = $true
                                if ($stateContainer.NetEtwCap -eq 2) { $stateContainer.NetEtwCap = 0 }
                            }
                            if (-not $reqEnable) {
                                if ($sessions.ContainsKey($activeTabId)) {
                                    &$stopSessionNetEtw $sessions[$activeTabId]
                                }
                                $stateContainer.NetEtwCap = 0
                                $stateContainer.NetEtwEventsPerSec = 0
                                $stateContainer.ResetNetBreaker = $false
                            } else {
                                &$setFullSync $false
                                $nextScheduledUtcTicks = [DateTime]::UtcNow.Ticks
                            }
                            $swCmd.Stop()
                            $stateContainer.ResultQueue.Enqueue(@{
                                RequestId   = $cmd.RequestId
                                CommandType = "SetNetEtw"
                                Success     = $true
                                Enabled     = $reqEnable
                            })
                        }

                        "StopNetEtw" {
                            $stateContainer.EnableNetEtw = $false
                            foreach ($sItem in $sessions.Values) {
                                &$stopSessionNetEtw $sItem
                            }
                            $stateContainer.NetEtwCap = 0
                            $stateContainer.NetEtwEventsPerSec = 0
                            $swCmd.Stop()
                            $stateContainer.ResultQueue.Enqueue(@{
                                RequestId   = $cmd.RequestId
                                CommandType = "StopNetEtw"
                                Success     = $true
                            })
                        }

                        "CloseTabSession" {
                            $closeTabId = [string]$cmd.TabId
                            if ($sessions.ContainsKey($closeTabId)) {
                                $sessToClose = $sessions[$closeTabId]
                                &$failSessionPendingJobs $sessToClose "Tab session closed."
                                &$stopRemoteWorker $sessToClose
                                &$stopSessionNetEtw $sessToClose
                                if ($sessToClose.Session) {
                                    Remove-PSSession -Session $sessToClose.Session -ErrorAction SilentlyContinue
                                }
                                $sessions.Remove($closeTabId)
                            }

                            if ($activeTabId -eq $closeTabId) {
                                $remainKeys = @($sessions.Keys)
                                if ($remainKeys.Count -gt 0) {
                                    $activeTabId = $remainKeys[0]
                                    $curr = $sessions[$activeTabId]
                                    $stateContainer.ActiveTabId       = $activeTabId
                                    $stateContainer.TargetDisplayName = $curr.Target
                                    $stateContainer.TransportBadge    = $curr.Badge
                                    $stateContainer.ConnectionState   = $curr.ConnState
                                    &$setFullSync $true
                                }
                            }

                            $swCmd.Stop()
                            $stateContainer.ResultQueue.Enqueue(@{
                                RequestId   = $cmd.RequestId
                                CommandType = "CloseTabSession"
                                Success     = $true
                                TabId       = $closeTabId
                            })
                        }

                        "SwitchTarget" {
                            $newComp  = [string]$cmd.ComputerName
                            $newLocal = [bool]$cmd.IsLocal
                            $newCred  = $cmd.Credential
                            $newPort  = [int]$cmd.Port
                            $newSsl   = [bool]$cmd.UseSSL

                            if ($sessions.ContainsKey($activeTabId)) {
                                &$failSessionPendingJobs $sessions[$activeTabId] "Target switched."
                                &$stopRemoteWorker $sessions[$activeTabId]
                                &$stopSessionNetEtw $sessions[$activeTabId]
                            }
                            $oldSess = if ($sessions.ContainsKey($activeTabId)) { $sessions[$activeTabId].Session } else { $null }
                            if ($oldSess) {
                                Remove-PSSession -Session $oldSess -ErrorAction SilentlyContinue
                            }

                            $newSess = $null
                            $badge = "LOCAL"
                            $targetName = if ($newLocal) { "$env:COMPUTERNAME" } else { $newComp }

                            if ($newLocal) {
                                $stateContainer.ConnectionState   = "LocalMode"
                                $stateContainer.TargetDisplayName = "$env:COMPUTERNAME"
                                $stateContainer.TransportBadge    = "LOCAL"
                            } else {
                                $so = New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 30000 -CancelTimeout 5000 -NoMachineProfile
                                $sParams = @{
                                    ComputerName  = $newComp
                                    SessionOption = $so
                                    ErrorAction   = 'Stop'
                                }
                                if ($newCred) { $sParams['Credential'] = $newCred }
                                if ($newPort -gt 0) { $sParams['Port'] = $newPort }
                                if ($newSsl)  { $sParams['UseSSL'] = $true }

                                $newSess = New-PSSession @sParams
                                $badge = if ($newSsl) { "WINRM-SSL" } else { "WINRM" }
                                $stateContainer.ConnectionState   = "Connected"
                                $stateContainer.TargetDisplayName = $newComp
                                $stateContainer.TransportBadge    = $badge
                            }

                            $sessions[$activeTabId] = @{
                                Session              = $newSess
                                IsLocal              = $newLocal
                                Target               = $targetName
                                Badge                = $badge
                                CollectorSb          = &$newLocalCollectorSb
                                CollectorInitialized = $false
                                InspectorInitialized = $false
                                ActionInitialized    = $false
                                WorkerInitialized    = $false
                                PendingJobs          = @{}
                                ConnectionConfig     = @{
                                    ComputerName = $newComp
                                    IsLocal      = $newLocal
                                    Credential   = $newCred
                                    Port         = $newPort
                                    UseSSL       = $newSsl
                                }
                                ConnState           = if ($newLocal) { "LocalMode" } else { "Connected" }
                                ConsecutiveFailures = 0
                                ReconnectAttempts   = 0
                                NextReconnectTicks  = 0L
                                BackoffSec          = 1
                                NetEtwStarted       = $false
                            }
                            $stateContainer.EnableNetEtw = $false

                            $stateContainer.ClearHostMaps = $true
                            &$setFullSync $true
                            $swCmd.Stop()
                            $stateContainer.ResultQueue.Enqueue(@{
                                RequestId   = $cmd.RequestId
                                CommandType = "SwitchTarget"
                                Success     = $true
                                Message     = "Connected to $($stateContainer.TargetDisplayName) ($($stateContainer.TransportBadge)) in $($swCmd.ElapsedMilliseconds)ms."
                            })
                        }
                    }
                } catch {
                    $swCmd.Stop()
                    $stateContainer.ResultQueue.Enqueue(@{
                        RequestId   = $cmd.RequestId
                        CommandType = $cmd.CommandType
                        Success     = $false
                        Error       = $_.Exception.Message
                    })
                }
            }

            if ($stateContainer.IsStopping) { break }

            # 1b. Harvest Non-Blocking Async Worker Jobs
            &$harvestAsyncJobs

            # 2. Periodic Telemetry Snapshot Poll on Active Host Session (Wall-Clock Anchored & Reconnect Protected)
            $nowTicks = [DateTime]::UtcNow.Ticks
            $isDue = ($nowTicks -ge $nextScheduledUtcTicks) -or [bool]$stateContainer.ForceFullSync
            $canPollSession = $sessions.ContainsKey($activeTabId)
            $activeSessObj = if ($canPollSession) { $sessions[$activeTabId] } else { $null }

            $curPaused = [bool]$stateContainer.IsPaused
            if ($curPaused -and -not $prevPausedState -and $activeSessObj -and $activeSessObj.NetEtwStarted) {
                &$stopSessionNetEtw $activeSessObj
            }
            $prevPausedState = $curPaused

            $isReconnectingBackoff = $false
            if ($activeSessObj -and -not $activeSessObj.IsLocal -and $activeSessObj.ConnState -eq "Reconnecting" -and $nowTicks -lt $activeSessObj.NextReconnectTicks) {
                $isReconnectingBackoff = $true
            }

            if (-not $curPaused -and $activeSessObj -and -not $isReconnectingBackoff -and $isDue -and ($null -eq $stateContainer.Payload -or $stateContainer.ForceFullSync)) {
                $pollStartTicks = [DateTime]::UtcNow.Ticks
                $swPoll = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    [System.Threading.Monitor]::Enter($stateContainer.SyncRoot)
                    try {
                        $forceFull     = [bool]$stateContainer.ForceFullSync
                        $syncGenBefore = [long]$stateContainer.FullSyncGen
                    } finally {
                        [System.Threading.Monitor]::Exit($stateContainer.SyncRoot)
                    }

                    $effEnableNetEtw = [bool]$stateContainer.EnableNetEtw
                    $netEtwAction = if ($stateContainer.ResetNetBreaker) {
                        $stateContainer.ResetNetBreaker = $false
                        "ResetBreaker"
                    } else { "" }
                    if ($effEnableNetEtw) { $activeSessObj.NetEtwStarted = $true }

                    $rawResult = if ($activeSessObj.IsLocal) {
                        & $activeSessObj.CollectorSb $forceFull $effEnableNetEtw $netEtwAction
                    } else {
                        $sRef = $activeSessObj.Session
                        if (-not $sRef -or $sRef.State -ne 'Opened') {
                            throw "WinRM session state is $(if ($sRef) { $sRef.State } else { 'Null' })."
                        }
                        if (-not $activeSessObj.CollectorInitialized) {
                            Invoke-Command -Session $sRef -ScriptBlock {
                                param($code)
                                $script:PSRPMCollectorInvoker = [scriptblock]::Create($code)
                            } -ArgumentList @($collectorCode) -ErrorAction Stop
                            $activeSessObj.CollectorInitialized = $true
                        }

                        $resTick = Invoke-Command -Session $sRef -ScriptBlock {
                            param($f, $enNet, $netAct)
                            if ($script:PSRPMCollectorInvoker) {
                                & $script:PSRPMCollectorInvoker $f $enNet $netAct
                            } else {
                                $null
                            }
                        } -ArgumentList @($forceFull, $effEnableNetEtw, $netEtwAction) -ErrorAction Stop

                        if (-not $resTick) {
                            $activeSessObj.CollectorInitialized = $false
                            throw "Collector invoker uninitialized on target host."
                        }
                        $resTick
                    }

                    $swPoll.Stop()
                    if ($rawResult) {
                        $pollFinishTicks = [DateTime]::UtcNow.Ticks
                        $lastPollUtcTicks = $pollFinishTicks
                        $stateContainer.LastSampleUtcTicks = $pollFinishTicks
                        $currInterval = [Math]::Max(250, [int]$stateContainer.IntervalMs)
                        $nextScheduledUtcTicks = $pollStartTicks + ([long]$currInterval * 10000L)
                        if ($nextScheduledUtcTicks -le $pollFinishTicks) {
                            $nextScheduledUtcTicks = $pollFinishTicks + 100000L
                        }

                        $rawResultStr = [string]$rawResult
                        $calcWireBytes = if ($rawResultStr.StartsWith("GZIP:")) {
                            $b64Len = $rawResultStr.Length - 5
                            $pad = if ($rawResultStr.EndsWith("==")) { 2 } elseif ($rawResultStr.EndsWith("=")) { 1 } else { 0 }
                            [int](($b64Len * 3) / 4) - $pad
                        } else {
                            [System.Text.Encoding]::UTF8.GetByteCount($rawResultStr)
                        }

                        [System.Threading.Monitor]::Enter($stateContainer.SyncRoot)
                        try {
                            if ($forceFull -and ([long]$stateContainer.FullSyncGen -eq $syncGenBefore)) {
                                $stateContainer.ForceFullSync = $false
                            }
                            $stateContainer.PollLatencyMs = [int]$swPoll.ElapsedMilliseconds
                            $stateContainer.PayloadBytes  = $calcWireBytes
                            $stateContainer.PayloadTabId  = $activeTabId
                            $stateContainer.Payload       = $rawResultStr
                        } finally {
                            [System.Threading.Monitor]::Exit($stateContainer.SyncRoot)
                        }

                        $stateContainer.ConnectionState = if ($activeSessObj.IsLocal) { "LocalMode" } else { "Connected" }
                        $stateContainer.LastErr         = $null

                        $activeSessObj.ConnState           = if ($activeSessObj.IsLocal) { "LocalMode" } else { "Connected" }
                        $activeSessObj.ConsecutiveFailures = 0
                        $activeSessObj.ReconnectAttempts   = 0
                        $activeSessObj.BackoffSec          = 1
                    }
                } catch {
                    $swPoll.Stop()
                    $currIntervalErr = [Math]::Max(250, [int]$stateContainer.IntervalMs)
                    $nextScheduledUtcTicks = [DateTime]::UtcNow.Ticks + ([long]$currIntervalErr * 10000L)
                    $activeSessObj.ConsecutiveFailures++
                    $fails = $activeSessObj.ConsecutiveFailures
                    if ($forceFull) {
                        &$setFullSync $true
                    }

                    if ($activeSessObj.IsLocal) {
                        $stateContainer.ConnectionState = "Disconnected"
                        $stateContainer.LastErr         = $_.Exception.Message
                    } else {
                        if ($fails -lt 3 -and $activeSessObj.Session -and $activeSessObj.Session.State -eq 'Opened') {
                            $activeSessObj.ConnState = "Degraded"
                            $stateContainer.ConnectionState = "Degraded"
                            $stateContainer.LastErr = "Telemetry poll warning: $($_.Exception.Message)"
                        } else {
                            &$failSessionPendingJobs $activeSessObj "WinRM connection interrupted."
                            $activeSessObj.WorkerInitialized = $false
                            $activeSessObj.ConnState = "Reconnecting"
                            $activeSessObj.ReconnectAttempts++
                            $attempts = $activeSessObj.ReconnectAttempts

                            if ($attempts -gt 10) {
                                $activeSessObj.ConnState = "Disconnected"
                                $stateContainer.ConnectionState = "Disconnected"
                                $stateContainer.LastErr = "WinRM reconnection failed after $attempts attempts: $($_.Exception.Message)"
                            } else {
                                $stateContainer.ConnectionState = "Reconnecting"
                                # Bounded exponential backoff: 1s -> 2s -> 4s -> 8s -> 15s
                                $bSec = [Math]::Min(15, [int][Math]::Pow(2, [Math]::Min(4, $attempts - 1)))
                                $activeSessObj.BackoffSec = $bSec
                                $activeSessObj.NextReconnectTicks = [DateTime]::UtcNow.Ticks + ($bSec * 10000000L)
                                $stateContainer.LastErr = "WinRM link interrupted ($($_.Exception.Message)). Reconnecting in ${bSec}s (attempt $attempts/10)..."

                                # Stage 1: Connect-PSSession if session is disconnected
                                $recovered = $false
                                if ($activeSessObj.Session -and $activeSessObj.Session.State -eq 'Disconnected') {
                                    try {
                                        $activeSessObj.Session = Connect-PSSession -Session $activeSessObj.Session -ErrorAction Stop
                                        if ($activeSessObj.Session.State -eq 'Opened') { $recovered = $true }
                                    } catch {}
                                }

                                # Stage 2: Recreate New-PSSession if Stage 1 failed or session broken
                                if (-not $recovered -and $activeSessObj.ConnectionConfig -and $activeSessObj.ConnectionConfig.ComputerName) {
                                    try {
                                        if ($activeSessObj.Session) {
                                            Remove-PSSession -Session $activeSessObj.Session -ErrorAction SilentlyContinue
                                        }
                                        $cfg = $activeSessObj.ConnectionConfig
                                        $so = New-PSSessionOption -OpenTimeout 8000 -OperationTimeout 30000 -CancelTimeout 3000 -NoMachineProfile
                                        $sParams = @{
                                            ComputerName  = $cfg.ComputerName
                                            SessionOption = $so
                                            ErrorAction   = 'Stop'
                                        }
                                        if ($cfg.Credential) { $sParams['Credential'] = $cfg.Credential }
                                        if ($cfg.Port -gt 0) { $sParams['Port'] = $cfg.Port }
                                        if ($cfg.UseSSL)     { $sParams['UseSSL'] = $true }

                                        $activeSessObj.Session = New-PSSession @sParams
                                        if ($activeSessObj.Session.State -eq 'Opened') { $recovered = $true }
                                    } catch {
                                        $stateContainer.LastErr = "WinRM recreate failed: $($_.Exception.Message)"
                                    }
                                }

                                if ($recovered) {
                                    $activeSessObj.CollectorInitialized = $false
                                    $activeSessObj.InspectorInitialized = $false
                                    $activeSessObj.ActionInitialized    = $false
                                    $activeSessObj.WorkerInitialized    = $false
                                    $activeSessObj.ConnState            = "Connected"
                                    $activeSessObj.ConsecutiveFailures  = 0
                                    $activeSessObj.ReconnectAttempts    = 0
                                    $activeSessObj.BackoffSec           = 1
                                    $stateContainer.ConnectionState     = "Connected"
                                    &$setFullSync $true
                                    $stateContainer.LastErr             = $null
                                }
                            }
                        }
                    }
                }
            }

            # 3. Dynamic Drift-Compensated Sleep
            $curIntMs = [Math]::Max(250, [int]$stateContainer.IntervalMs)
            $remTicks = $nextScheduledUtcTicks - [DateTime]::UtcNow.Ticks
            $waitMs   = [int]($remTicks / 10000L)
            if ($waitMs -gt $curIntMs) { $waitMs = $curIntMs }
            if ($waitMs -lt 10)        { $waitMs = 10 }
            [void]$stateContainer.WakeEvent.WaitOne($waitMs)
        }
        } finally {
            if ($script:CoordLocalWorker) {
                try {
                    $script:CoordLocalWorker.State.IsStopping = $true
                    [void]$script:CoordLocalWorker.State.WakeEvent.Set()
                    $script:CoordLocalWorker.PowerShell.Dispose()
                    $script:CoordLocalWorker.Runspace.Close()
                    $script:CoordLocalWorker.Runspace.Dispose()
                } catch {}
            }
            foreach ($sItem in $sessions.Values) {
                &$failSessionPendingJobs $sItem "Engine stopped."
                &$stopRemoteWorker $sItem
                &$stopSessionNetEtw $sItem
                if ($sItem.Session) {
                    Remove-PSSession -Session $sItem.Session -ErrorAction SilentlyContinue
                }
            }
        }
    })

    [void]$ps.AddArgument($PSSession)
    [void]$ps.AddArgument($stateContainer)
    [void]$ps.AddArgument($collectorText)
    [void]$ps.AddArgument($inspectorText)
    [void]$ps.AddArgument($actionText)
    [void]$ps.AddArgument($IsLocal)
    [void]$ps.AddArgument($InitialTabId)

    $asyncHandle = $ps.BeginInvoke()

    # Host UI State Dictionaries & Caches
    $summaryVmHolder = @{ Value = $SummaryViewModel }
    $processMap      = [System.Collections.Generic.Dictionary[int, Object]]::new()
    $servicesMap     = [System.Collections.Generic.Dictionary[string, Object]]::new()
    $pidServicesMap  = [System.Collections.Generic.Dictionary[int, System.Collections.Generic.List[string]]]::new()
    $iconCache       = @{}
    $callbacks       = @{}
    $jss             = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $jss.MaxJsonLength = 10485760

    $requestFullSync = {
        [System.Threading.Monitor]::Enter($stateContainer.SyncRoot)
        try {
            $stateContainer.ForceFullSync = $true
            $stateContainer.FullSyncGen   = [long]$stateContainer.FullSyncGen + 1L
        } finally {
            [System.Threading.Monitor]::Exit($stateContainer.SyncRoot)
        }
        [void]$stateContainer.WakeEvent.Set()
    }.GetNewClosure()

    $appendLogSafe = {
        param([string]$text)
        if ($LogConsole -and -not [string]::IsNullOrEmpty($text)) {
            $isPinned = ($LogConsole.ViewportHeight -le 0) -or (($LogConsole.VerticalOffset + $LogConsole.ViewportHeight) -ge ($LogConsole.ExtentHeight - 4.0))
            if ($isPinned) {
                if ($LogConsole.Text.Length -gt 72000) {
                    $LogConsole.Text = $LogConsole.Text.Substring($LogConsole.Text.Length - 48000)
                }
                $LogConsole.AppendText($text)
                $LogConsole.ScrollToEnd()
            } else {
                if ($LogConsole.Text.Length -gt 192000) {
                    $savedOffset = $LogConsole.VerticalOffset
                    $LogConsole.Text = $LogConsole.Text.Substring($LogConsole.Text.Length - 144000)
                    $LogConsole.ScrollToVerticalOffset([Math]::Max(0.0, $savedOffset - 1200.0))
                }
                $LogConsole.AppendText($text)
            }
        }
    }.GetNewClosure()

    # Helper: Extract 16x16 Associated Process Icon (Cached per Unique Path)
    $resolveProcessIcon = {
        param([string]$exePath)
        if ([string]::IsNullOrWhiteSpace($exePath) -or $exePath -eq "N/A") { return $null }
        $key = $exePath.ToLowerInvariant()
        if ($iconCache.ContainsKey($key)) { return $iconCache[$key] }
        if ($iconCache.Count -ge 512) { $iconCache.Clear() }

        $bmpSrc = $null
        try {
            if ([System.IO.File]::Exists($exePath)) {
                $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
                if ($ico) {
                    $bmpSrc = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                        $ico.Handle,
                        [System.Windows.Int32Rect]::Empty,
                        [System.Windows.Media.Imaging.BitmapSizeOptions]::FromWidthAndHeight(16, 16)
                    )
                    $bmpSrc.Freeze()
                    $ico.Dispose()
                }
            }
        } catch {}
        $iconCache[$key] = $bmpSrc
        return $bmpSrc
    }.GetNewClosure()

    # Helper: Reconcile ObservableCollection In-Place Without .Clear()
    $reconcileCollection = {
        param(
            [System.Collections.ObjectModel.ObservableCollection[Object]]$collection,
            [System.Collections.Generic.List[Object]]$desiredList,
            [System.Windows.Controls.DataGrid]$grid
        )

        $savedPrimary = $null
        $savedMulti = $null
        $isMultiGrid = $false
        if ($grid) {
            $savedPrimary = $grid.SelectedItem
            if ($grid.SelectionMode -ne [System.Windows.Controls.DataGridSelectionMode]::Single -and $null -ne $grid.SelectedItems -and $grid.SelectedItems.Count -gt 0) {
                $isMultiGrid = $true
                $savedMulti = [System.Collections.Generic.List[Object]]::new($grid.SelectedItems.Count)
                foreach ($selObj in @($grid.SelectedItems)) {
                    if ($null -ne $selObj) { [void]$savedMulti.Add($selObj) }
                }
            }
        }

        $targetSet = [System.Collections.Generic.HashSet[Object]]::new()
        foreach ($item in $desiredList) { [void]$targetSet.Add($item) }

        # 1. Remove items no longer in desiredList (back-to-front)
        for ($i = $collection.Count - 1; $i -ge 0; $i--) {
            if (-not $targetSet.Contains($collection[$i])) {
                $collection.RemoveAt($i)
            }
        }

        # 2. Align order with desiredList via Move or Insert
        for ($i = 0; $i -lt $desiredList.Count; $i++) {
            $want = $desiredList[$i]
            if ($i -ge $collection.Count) {
                $collection.Add($want)
            } elseif (-not [Object]::ReferenceEquals($collection[$i], $want)) {
                $existingIdx = $collection.IndexOf($want)
                if ($existingIdx -gt $i) {
                    $collection.Move($existingIdx, $i)
                } else {
                    $collection.Insert($i, $want)
                }
            }
        }

        while ($collection.Count -gt $desiredList.Count) {
            $collection.RemoveAt($collection.Count - 1)
        }

        if ($grid) {
            if ($isMultiGrid -and $savedMulti -and $savedMulti.Count -gt 0) {
                $surviving = [System.Collections.Generic.List[Object]]::new()
                $survivingSet = [System.Collections.Generic.HashSet[Object]]::new()
                foreach ($s in $savedMulti) {
                    if ($targetSet.Contains($s) -and $survivingSet.Add($s)) {
                        [void]$surviving.Add($s)
                    }
                }

                $currSel = $grid.SelectedItems
                $needsRestore = ($currSel.Count -ne $surviving.Count)
                if (-not $needsRestore) {
                    foreach ($s in $surviving) {
                        if (-not $currSel.Contains($s)) {
                            $needsRestore = $true
                            break
                        }
                    }
                }

                if ($needsRestore) {
                    for ($si = $currSel.Count - 1; $si -ge 0; $si--) {
                        $curItem = $currSel[$si]
                        if (-not $survivingSet.Contains($curItem)) {
                            $currSel.RemoveAt($si)
                        }
                    }
                    foreach ($s in $surviving) {
                        if (-not $currSel.Contains($s)) {
                            [void]$currSel.Add($s)
                        }
                    }
                }
            } elseif ($savedPrimary -and $targetSet.Contains($savedPrimary) -and $grid.SelectedItem -ne $savedPrimary) {
                $grid.SelectedItem = $savedPrimary
            }
        }
    }.GetNewClosure()

    # Core View Builder (Tree-Grid & Flat List + Ancestor-Preserving Filter + Sibling Sort)
    $gridProcesses = $Window.FindName("GridProcesses")
    $txtMatchCount = $Window.FindName("TxtMatchCount")

    $treeCpuVisited = [System.Collections.Generic.HashSet[int]]::new()
    $recalculateTreeCpu = {
        $netTreeActive = ([int]$stateContainer.NetEtwCap -eq 1)
        foreach ($kvp in $processMap.GetEnumerator()) {
            $kvp.Value.PendingTreeCPU = $kvp.Value.CPU
            if ($netTreeActive) {
                $kvp.Value.PendingTreeNetRx = $kvp.Value.NetRxBps
                $kvp.Value.PendingTreeNetTx = $kvp.Value.NetTxBps
            }
        }

        foreach ($kvp in $processMap.GetEnumerator()) {
            $vm = $kvp.Value
            $ownCpu = $vm.CPU
            $ownRx  = if ($netTreeActive) { $vm.NetRxBps } else { 0L }
            $ownTx  = if ($netTreeActive) { $vm.NetTxBps } else { 0L }
            if ($ownCpu -le 0.0 -and $ownRx -le 0L -and $ownTx -le 0L) { continue }

            $treeCpuVisited.Clear()
            [void]$treeCpuVisited.Add($vm.PID)
            $curr = $vm
            $guard = 0
            while ($curr.ParentPID -gt 0 -and $curr.ParentPID -ne $curr.PID -and $processMap.ContainsKey($curr.ParentPID) -and $guard -lt 64) {
                $pPid = $curr.ParentPID
                if (-not $treeCpuVisited.Add($pPid)) { break }
                $parentVm = $processMap[$pPid]
                if ($parentVm.CreateTime -gt 0 -and $curr.CreateTime -gt 0 -and $parentVm.CreateTime -gt $curr.CreateTime) {
                    break
                }
                if ($ownCpu -gt 0.0) { $parentVm.PendingTreeCPU += $ownCpu }
                if ($netTreeActive) {
                    if ($ownRx -gt 0L) { $parentVm.PendingTreeNetRx += $ownRx }
                    if ($ownTx -gt 0L) { $parentVm.PendingTreeNetTx += $ownTx }
                }
                $curr = $parentVm
                $guard++
            }
        }

        foreach ($kvp in $processMap.GetEnumerator()) {
            $vm = $kvp.Value
            $vm.UpdateTreeCpu($vm.PendingTreeCPU)
            if ($netTreeActive) {
                $vm.UpdateTreeNetwork($vm.PendingTreeNetRx, $vm.PendingTreeNetTx)
            }
        }
    }.GetNewClosure()

    $updateViewCollections = {
        & $recalculateTreeCpu
        $isTreeMode = [bool]$stateContainer.IsTreeMode
        $sortProp   = [string]$stateContainer.SortProperty
        if (-not $sortProp) { $sortProp = "PID" }
        $sortDesc   = [bool]$stateContainer.SortDescending
        $filterTxt  = ([string]$stateContainer.FilterText).Trim()
        $catFilter  = ([string]$stateContainer.CategoryFilter).Trim()
        $hasFilter  = ($filterTxt.Length -gt 0) -or ($catFilter.Length -gt 0)

        # 1. Determine Filter Matches & Ancestor Chain
        $directMatches = [System.Collections.Generic.HashSet[int]]::new()
        $ancestorSet   = [System.Collections.Generic.HashSet[int]]::new()

        $wcPattern = $null
        if ($filterTxt.Length -gt 0) {
            # Escape bracket and backtick metacharacters to guard against WildcardPatternException on unclosed brackets while preserving * and ? wildcards
            $safePattern = "*" + $filterTxt.Replace('`', '``').Replace('[', '`[').Replace(']', '`]') + "*"
            try {
                $wc = [System.Management.Automation.WildcardPattern]::new($safePattern, [System.Management.Automation.WildcardOptions]::IgnoreCase)
                [void]$wc.IsMatch("")
                $wcPattern = $wc
            } catch {
                $wcPattern = $null
            }
        }

        foreach ($kvp in $processMap.GetEnumerator()) {
            $vm = $kvp.Value

            $isMatch = $true
            if ($catFilter.Length -gt 0 -and $vm.Category -ne $catFilter) {
                $isMatch = $false
            }
            if ($isMatch -and $filterTxt.Length -gt 0) {
                if ($wcPattern) {
                    $isMatch = $wcPattern.IsMatch([string]$vm.Name) -or
                               $wcPattern.IsMatch([string]$vm.PIDDisplay) -or
                               $wcPattern.IsMatch([string]$vm.Description) -or
                               $wcPattern.IsMatch([string]$vm.CompanyName) -or
                               $wcPattern.IsMatch([string]$vm.User) -or
                               $wcPattern.IsMatch([string]$vm.CommandLine) -or
                               $wcPattern.IsMatch([string]$vm.HostedServices)
                } else {
                    $isMatch = ([string]$vm.Name).IndexOf($filterTxt, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                               ([string]$vm.PIDDisplay).IndexOf($filterTxt, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                               ([string]$vm.Description).IndexOf($filterTxt, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                               ([string]$vm.CompanyName).IndexOf($filterTxt, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                               ([string]$vm.User).IndexOf($filterTxt, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                               ([string]$vm.CommandLine).IndexOf($filterTxt, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                               ([string]$vm.HostedServices).IndexOf($filterTxt, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                }
            }
            if ($isMatch) {
                [void]$directMatches.Add($vm.PID)
            }
        }

        if ($hasFilter -and $isTreeMode) {
            foreach ($matchPid in $directMatches) {
                $curr = $processMap[$matchPid]
                $guard = 0
                while ($curr -and $curr.ParentPID -gt 0 -and $processMap.ContainsKey($curr.ParentPID) -and $curr.ParentPID -ne $curr.PID -and $guard -lt 64) {
                    $parentVm = $processMap[$curr.ParentPID]
                    if ($parentVm.CreateTime -gt 0 -and $curr.CreateTime -gt 0 -and $parentVm.CreateTime -gt $curr.CreateTime) {
                        break
                    }
                    if (-not $directMatches.Contains($parentVm.PID)) {
                        [void]$ancestorSet.Add($parentVm.PID)
                    }
                    $curr = $parentVm
                    $guard++
                }
            }
        }

        if ($txtMatchCount) {
            $txtMatchCount.Text = if ($hasFilter) { "$($directMatches.Count)/$($processMap.Count)" } else { "$($processMap.Count)" }
        }

        # 2. Build Validated Parent-Child Hierarchy (CreationTime Checked)
        $roots = [System.Collections.Generic.List[Object]]::new()
        $childrenMap = [System.Collections.Generic.Dictionary[int, System.Collections.Generic.List[Object]]]::new()

        foreach ($kvp in $processMap.GetEnumerator()) {
            $vm = $kvp.Value
            $pidVal = $vm.PID
            if ($hasFilter) {
                if (-not $directMatches.Contains($pidVal) -and -not $ancestorSet.Contains($pidVal)) {
                    continue
                }
            }

            $pPid = $vm.ParentPID
            $validParent = $false
            if ($pPid -gt 0 -and $pPid -ne $pidVal -and $processMap.ContainsKey($pPid)) {
                $pVm = $processMap[$pPid]
                if (-not $hasFilter -or $directMatches.Contains($pPid) -or $ancestorSet.Contains($pPid)) {
                    if ($pVm.CreateTime -le 0 -or $vm.CreateTime -le 0 -or $pVm.CreateTime -le $vm.CreateTime) {
                        $validParent = $true
                    }
                }
            }

            if ($validParent) {
                if (-not $childrenMap.ContainsKey($pPid)) {
                    $childrenMap[$pPid] = [System.Collections.Generic.List[Object]]::new()
                }
                $childrenMap[$pPid].Add($vm)
            } else {
                $roots.Add($vm)
            }
        }

        # Reconcile vm.Children in-place only when membership changes (zero .Clear() calls)
        foreach ($kvp in $processMap.GetEnumerator()) {
            $pVm = $kvp.Value
            if (-not $childrenMap.ContainsKey($kvp.Key)) {
                for ($ci = $pVm.Children.Count - 1; $ci -ge 0; $ci--) {
                    $pVm.Children.RemoveAt($ci)
                }
            } else {
                $newKids = $childrenMap[$kvp.Key]
                $same = ($pVm.Children.Count -eq $newKids.Count)
                if ($same) {
                    for ($ci = 0; $ci -lt $newKids.Count; $ci++) {
                        if (-not [Object]::ReferenceEquals($pVm.Children[$ci], $newKids[$ci])) {
                            $same = $false
                            break
                        }
                    }
                }
                if (-not $same) {
                    for ($ci = $pVm.Children.Count - 1; $ci -ge 0; $ci--) {
                        $pVm.Children.RemoveAt($ci)
                    }
                    foreach ($nk in $newKids) {
                        [void]$pVm.Children.Add($nk)
                    }
                }
            }
        }

        # Fast Array.Sort helper (avoids PowerShell pipeline Sort-Object overhead)
        $isNumericSort = $sortProp -in @("PID", "CPU", "TreeCPU", "MemoryBytes", "PrivateBytes", "Threads", "Handles", "NetRxBps", "NetTxBps", "NetTotalBps", "TreeNetRxBps", "TreeNetTxBps", "TreeNetTotalBps")
        $sortNodes = {
            param($list)
            $cnt = $list.Count
            if ($cnt -le 1) { return $list }
            $arr = $list.ToArray()
            if ($isNumericSort) {
                $keys = [double[]]::new($cnt)
                switch ($sortProp) {
                    "CPU"             { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].CPU } }
                    "TreeCPU"         { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].TreeCPU } }
                    "NetTotalBps"     { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].NetTotalBps } }
                    "TreeNetTotalBps" { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].TreeNetTotalBps } }
                    "NetRxBps"        { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].NetRxBps } }
                    "NetTxBps"        { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].NetTxBps } }
                    "TreeNetRxBps"    { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].TreeNetRxBps } }
                    "TreeNetTxBps"    { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].TreeNetTxBps } }
                    "MemoryBytes"     { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].MemoryBytes } }
                    "PrivateBytes"    { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].PrivateBytes } }
                    "Threads"         { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].Threads } }
                    "Handles"         { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].Handles } }
                    default           { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [double]$arr[$idx].PID } }
                }
                [Array]::Sort([Array]$keys, [Array]$arr)
                if ($sortDesc) {
                    [Array]::Reverse([Array]$keys)
                    [Array]::Reverse([Array]$arr)
                }
                if ($sortProp -ne "PID") {
                    $idx = 0
                    while ($idx -lt ($cnt - 1)) {
                        $j = $idx + 1
                        while ($j -lt $cnt -and $keys[$j] -eq $keys[$idx]) { $j++ }
                        $runLen = $j - $idx
                        if ($runLen -gt 1) {
                            $subItems = [Object[]]::new($runLen)
                            $subPids  = [int[]]::new($runLen)
                            for ($s = 0; $s -lt $runLen; $s++) {
                                $subItems[$s] = $arr[$idx + $s]
                                $subPids[$s]  = [int]$subItems[$s].PID
                            }
                            [Array]::Sort([Array]$subPids, [Array]$subItems)
                            for ($s = 0; $s -lt $runLen; $s++) {
                                $arr[$idx + $s] = $subItems[$s]
                            }
                        }
                        $idx = $j
                    }
                }
            } else {
                $keys = [string[]]::new($cnt)
                switch ($sortProp) {
                    "Name"        { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [string]$arr[$idx].Name } }
                    "Description" { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [string]$arr[$idx].Description } }
                    "CompanyName" { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [string]$arr[$idx].CompanyName } }
                    "User"        { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [string]$arr[$idx].User } }
                    default       { for ($idx = 0; $idx -lt $cnt; $idx++) { $keys[$idx] = [string]$arr[$idx].$sortProp } }
                }
                [Array]::Sort([Array]$keys, [Array]$arr, [System.StringComparer]::OrdinalIgnoreCase)
                if ($sortDesc) {
                    [Array]::Reverse([Array]$keys)
                    [Array]::Reverse([Array]$arr)
                }
                $idx = 0
                while ($idx -lt ($cnt - 1)) {
                    $j = $idx + 1
                    while ($j -lt $cnt -and [string]::Equals($keys[$j], $keys[$idx], [System.StringComparison]::OrdinalIgnoreCase)) { $j++ }
                    $runLen = $j - $idx
                    if ($runLen -gt 1) {
                        $subItems = [Object[]]::new($runLen)
                        $subPids  = [int[]]::new($runLen)
                        for ($s = 0; $s -lt $runLen; $s++) {
                            $subItems[$s] = $arr[$idx + $s]
                            $subPids[$s]  = [int]$subItems[$s].PID
                        }
                        [Array]::Sort([Array]$subPids, [Array]$subItems)
                        for ($s = 0; $s -lt $runLen; $s++) {
                            $arr[$idx + $s] = $subItems[$s]
                        }
                    }
                    $idx = $j
                }
            }
            return $arr
        }

        $desiredList = [System.Collections.Generic.List[Object]]::new()

        if ($isTreeMode) {
            $sortedRoots = @(&$sortNodes $roots)
            $visited = [System.Collections.Generic.HashSet[int]]::new()

            $dfsTraverse = {
                param($node, [int]$depth, [bool[]]$ancestorHasNext)
                if ($null -eq $node -or -not $visited.Add($node.PID)) { return }

                $hasChildren = $childrenMap.ContainsKey($node.PID) -and ($childrenMap[$node.PID].Count -gt 0)

                # Build Pixel-Snapped Tree Guide SVG Path (Vertical, Tee, Corner)
                $geomStr = ""
                if ($depth -gt 0) {
                    $gSb = [System.Text.StringBuilder]::new(128)
                    for ($d = 0; $d -lt ($depth - 1); $d++) {
                        if ($ancestorHasNext[$d]) {
                            $x = ($d * 16) + 7.5
                            [void]$gSb.Append("M $x,0 L $x,22 ")
                        }
                    }
                    $px = (($depth - 1) * 16) + 7.5
                    $pxEnd = $px + 7.5
                    $isLast = -not $ancestorHasNext[$depth - 1]
                    if ($isLast) {
                        [void]$gSb.Append("M $px,0 L $px,11.5 L $pxEnd,11.5")
                    } else {
                        [void]$gSb.Append("M $px,0 L $px,22 M $px,11.5 L $pxEnd,11.5")
                    }
                    $geomStr = $gSb.ToString().Trim()
                }

                $opacity = if ($hasFilter -and $ancestorSet.Contains($node.PID) -and -not $directMatches.Contains($node.PID)) { 0.62 } else { 1.0 }
                $node.UpdateTreeState($depth, $true, $hasChildren, $geomStr, $opacity)
                $desiredList.Add($node)

                $shouldExpand = $node.IsExpanded -or ($hasFilter -and $ancestorSet.Contains($node.PID))
                if ($shouldExpand -and $hasChildren -and $depth -lt 20) {
                    $kids = @(&$sortNodes $childrenMap[$node.PID])
                    for ($k = 0; $k -lt $kids.Count; $k++) {
                        $hasNext = ($k -lt ($kids.Count - 1))
                        $nextAnc = [bool[]]::new($depth + 1)
                        for ($a = 0; $a -lt $depth; $a++) { $nextAnc[$a] = $ancestorHasNext[$a] }
                        $nextAnc[$depth] = $hasNext
                        & $dfsTraverse $kids[$k] ($depth + 1) $nextAnc
                    }
                }
            }

            for ($r = 0; $r -lt $sortedRoots.Count; $r++) {
                & $dfsTraverse $sortedRoots[$r] 0 ([bool[]]@())
            }
        } else {
            # Flat Mode: Global Sort
            $flatCandidates = [System.Collections.Generic.List[Object]]::new()
            foreach ($kvp in $processMap.GetEnumerator()) {
                if (-not $hasFilter -or $directMatches.Contains($kvp.Key)) {
                    $kvp.Value.UpdateTreeState(0, $false, $false, "", 1.0)
                    $flatCandidates.Add($kvp.Value)
                }
            }
            $sortedFlat = @(&$sortNodes $flatCandidates)
            foreach ($item in $sortedFlat) {
                $desiredList.Add($item)
            }
        }

        &$reconcileCollection $ProcessCollection $desiredList $gridProcesses
    }.GetNewClosure()

    # UI DispatcherTimer (150ms responsiveness for commands & telemetry)
    $timer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Normal, $Window.Dispatcher)
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)

    $connDot           = $Window.FindName("ConnStatusDot")
    $txtTarget         = $Window.FindName("TxtTargetBadge")
    $txtTransport      = $Window.FindName("TxtTransportBadge")
    $txtLatency        = $Window.FindName("TxtLatencyBadge")
    $statusText        = $Window.FindName("StatusText")
    $badgePaused       = $Window.FindName("BadgePaused")
    $txtTelemTransport = $Window.FindName("TxtTelemTransport")
    $txtTelemPayload   = $Window.FindName("TxtTelemPayload")
    $txtTelemNetwork   = $Window.FindName("TxtTelemNetwork")
    $txtTelemDelta     = $Window.FindName("TxtTelemDelta")

    $telemStats = @{
        TotalWireBytes   = 0L
        TotalRawBytes    = 0L
        TotalTicks       = 0L
        TotalRttMs       = 0L
        LastReceivedSeq  = 0
        RttSamples       = [System.Collections.Generic.Queue[int]]::new(240)
        LastTickUtcTicks = 0L
    }

    $createProcessVm = { [ProcessItemViewModel]::new() }
    $createServiceVm = { [ServiceItemViewModel]::new() }

    $tickHandler = {
        # 0. Telemetry Freshness & Age Tracking
        if ($stateContainer.LastSampleUtcTicks -gt 0L) {
            $ageMs = [int](([DateTime]::UtcNow.Ticks - [long]$stateContainer.LastSampleUtcTicks) / 10000L)
            $stateContainer.TelemetryAgeMs = $ageMs
            $targetInt = [Math]::Max(250, [int]$stateContainer.IntervalMs)
            if ($ageMs -le ($targetInt * 1.5)) {
                $stateContainer.FreshnessState = "Fresh"
            } elseif ($ageMs -le ($targetInt * 3.0)) {
                $stateContainer.FreshnessState = "Stale"
            } else {
                $stateContainer.FreshnessState = "Frozen"
            }
        }

        # 1. Drain Async Command Results
        $resItem = $null
        while ($stateContainer.ResultQueue.TryDequeue([ref]$resItem)) {
            $reqId = $resItem.RequestId
            if ($reqId -and $callbacks.ContainsKey($reqId)) {
                $cb = $callbacks[$reqId]
                $callbacks.Remove($reqId)
                try {
                    & $cb $resItem
                } catch {
                    if ($LogConsole) {
                        $tsErr = (Get-Date).ToString("HH:mm:ss.fff")
                        &$appendLogSafe "[$tsErr] [ERROR] Command callback error: $($_.Exception.Message)`r`n"
                    }
                    $stateContainer.LastErr = "Command callback error: $($_.Exception.Message)"
                }
            }
        }

        # 2. Check Target Switch / Reset Request (Zero .Clear() on live DataGrids)
        if ($stateContainer.ClearHostMaps) {
            $stateContainer.ClearHostMaps = $false
            $telemStats.LastReceivedSeq = 0
            $telemStats.RttSamples.Clear()
            $telemStats.LastTickUtcTicks = 0L
            $processMap.Clear()
            $servicesMap.Clear()
            $pidServicesMap.Clear()
            $emptyList = [System.Collections.Generic.List[Object]]::new()
            &$reconcileCollection $ProcessCollection $emptyList $gridProcesses
            if ($null -ne $ServicesCollection) {
                &$reconcileCollection $ServicesCollection $emptyList $null
            }
            $curSumVmReset = $summaryVmHolder.Value
            if ($curSumVmReset -and $curSumVmReset.CoreGraphs) {
                for ($gi = $curSumVmReset.CoreGraphs.Count - 1; $gi -ge 0; $gi--) {
                    $curSumVmReset.CoreGraphs.RemoveAt($gi)
                }
            }
            $telemStats.TotalWireBytes = 0L
            $telemStats.TotalRawBytes  = 0L
            $telemStats.TotalTicks     = 0L
            $telemStats.TotalRttMs     = 0L
        }

        # 3. Update Connection Status Indicators
        $cState = $stateContainer.ConnectionState
        $fState = $stateContainer.FreshnessState
        if ($connDot) {
            if ($stateContainer.IsPaused) {
                $connDot.Fill = "#F59E0B"
            } elseif ($cState -in @("Connected", "LocalMode")) {
                if ($fState -eq "Frozen") {
                    $connDot.Fill = "#EA580C"
                } elseif ($fState -eq "Stale") {
                    $connDot.Fill = "#EAB308"
                } else {
                    $connDot.Fill = "#16A34A"
                }
            } elseif ($cState -eq "Degraded") {
                $connDot.Fill = "#EAB308"
            } elseif ($cState -eq "Reconnecting") {
                $connDot.Fill = "#EA580C"
            } else {
                $connDot.Fill = "#DC2626"
            }
        }
        if ($txtTarget)    { $txtTarget.Text    = [string]$stateContainer.TargetDisplayName }
        if ($txtTransport) { $txtTransport.Text = [string]$stateContainer.TransportBadge }
        if ($txtLatency) {
            if ($stateContainer.IsPaused) {
                $txtLatency.Text = "Paused"
            } elseif ($cState -eq "Reconnecting") {
                $txtLatency.Text = "Reconnecting"
            } elseif ($cState -eq "Degraded") {
                $txtLatency.Text = "$($stateContainer.PollLatencyMs) ms (Degraded)"
            } elseif ($cState -eq "Disconnected") {
                $txtLatency.Text = "Offline"
            } else {
                $ageTag = if ($fState -ne "Fresh" -and $stateContainer.TelemetryAgeMs -gt 0) { " ($fState)" } else { "" }
                $txtLatency.Text = "$($stateContainer.PollLatencyMs) ms$ageTag"
            }
            $txtLatency.ToolTip = "Poll Latency: $($stateContainer.PollLatencyMs) ms | Age: $($stateContainer.TelemetryAgeMs) ms | State: $cState ($fState)"
        }
        if ($badgePaused)  { $badgePaused.Visibility = if ($stateContainer.IsPaused) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed } }

        # 4. Consume Differential Telemetry Payload (Synchronized Hand-Off)
        $payloadStr   = $null
        $payloadTabId = $null
        $wireBytes    = 0
        $pollRttMs    = 0
        [System.Threading.Monitor]::Enter($stateContainer.SyncRoot)
        try {
            $payloadStr = $stateContainer.Payload
            if ($payloadStr) {
                $stateContainer.Payload = $null
                $payloadTabId = $stateContainer.PayloadTabId
                $wireBytes    = [int]$stateContainer.PayloadBytes
                $pollRttMs    = [int]$stateContainer.PollLatencyMs
            }
        } finally {
            [System.Threading.Monitor]::Exit($stateContainer.SyncRoot)
        }
        if (-not $payloadStr) { return }

        if ($payloadTabId -and $stateContainer.ActiveTabId -and $payloadTabId -ne $stateContainer.ActiveTabId) {
            return
        }

        try {
            $wasGzip = $payloadStr.StartsWith("GZIP:")
            if ($wasGzip) {
                $b64 = $payloadStr.Substring(5)
                $compBytes = [Convert]::FromBase64String($b64)
                $wireBytes = $compBytes.Length
                $msIn = [System.IO.MemoryStream]::new($compBytes, $false)
                $gsIn = [System.IO.Compression.GZipStream]::new($msIn, [System.IO.Compression.CompressionMode]::Decompress)
                $sr   = [System.IO.StreamReader]::new($gsIn, [System.Text.Encoding]::UTF8)
                $payloadStr = $sr.ReadToEnd()
                $sr.Close()
                $gsIn.Close()
                $msIn.Close()
            }
            $rawBytes = [System.Text.Encoding]::UTF8.GetByteCount($payloadStr)

            $data = $jss.DeserializeObject($payloadStr)
            if (-not $data) { return }

            $wireVer    = if ($data.ContainsKey('ver'))  { [int]$data['ver'] }  else { 1 }
            $seq        = [int]$data['seq']
            $isFullSnap = ($data.ContainsKey('full') -and [int]$data['full'] -eq 1)

            $lastSeq = [int]$telemStats.LastReceivedSeq
            if ($lastSeq -gt 0 -and $seq -gt ($lastSeq + 1) -and -not $isFullSnap) {
                $gapCount = $seq - $lastSeq - 1
                if ($LogConsole) {
                    $tsGap = (Get-Date).ToString("HH:mm:ss.fff")
                    &$appendLogSafe "[$tsGap] [WARN] Telemetry sequence gap detected: expected #$($lastSeq + 1), received #$seq ($gapCount missed ticks). Triggering baseline resync.`r`n"
                }
                &$requestFullSync
            }
            $telemStats.LastReceivedSeq = $seq
            $isDark = [bool]$stateContainer.IsDarkTheme
            $enableCatHighlights = if ($stateContainer.ContainsKey('EnableCategoryHighlights')) { [bool]$stateContainer.EnableCategoryHighlights } else { $true }
            $structureChanged = $false

            # Opt-In Kernel Network ETW Status Transition
            $prevNetCap = [int]$stateContainer.NetEtwCap
            $prevNetEv  = [int]$stateContainer.NetEtwEventsPerSec
            $newNetCap  = if ($data.ContainsKey('netCap')) { [int]$data['netCap'] } else { 0 }
            $newNetEv   = if ($data.ContainsKey('netEv'))  { [int]$data['netEv'] }  else { 0 }
            $stateContainer.NetEtwCap = $newNetCap
            $stateContainer.NetEtwEventsPerSec = $newNetEv

            if ($prevNetCap -ne $newNetCap) {
                if ($newNetCap -ne 1) {
                    foreach ($kvp in $processMap.GetEnumerator()) {
                        $kvp.Value.UpdateNetwork(0L, 0L)
                        $kvp.Value.UpdateTreeNetwork(0L, 0L)
                    }
                    if ($newNetCap -in @(2, 3, 4)) {
                        $stateContainer.EnableNetEtw = $false
                    }
                    $structureChanged = $true
                }
                if ($LogConsole) {
                    $tsNet = (Get-Date).ToString("HH:mm:ss.fff")
                    if ($newNetCap -eq 1) {
                        &$appendLogSafe "[$tsNet] [NET-ETW] Enabled per-process kernel network monitoring (Microsoft-Windows-Kernel-Network).`r`n"
                    } elseif ($newNetCap -eq 2) {
                        &$appendLogSafe "[$tsNet] [NET-ETW] [WARN] Circuit breaker tripped ($newNetEv ev/s > 25,000/s threshold). Remote ETW session auto-paused.`r`n"
                    } elseif ($newNetCap -eq 3) {
                        &$appendLogSafe "[$tsNet] [NET-ETW] [INFO] Access denied starting ETW trace (Tier 1 fallback: system-wide NET rate active).`r`n"
                    } elseif ($newNetCap -eq 4) {
                        $errSuffix = if ($data.ContainsKey('netErr') -and -not [string]::IsNullOrWhiteSpace([string]$data['netErr'])) { " ($($data['netErr']))" } else { "" }
                        &$appendLogSafe "[$tsNet] [NET-ETW] [WARN] Kernel network ETW session unavailable on target host${errSuffix}.`r`n"
                    } elseif ($prevNetCap -eq 1) {
                        &$appendLogSafe "[$tsNet] [NET-ETW] Disabled per-process kernel network monitoring.`r`n"
                    }
                }
            }
            if (($prevNetCap -ne $newNetCap -or ($newNetCap -eq 1 -and $prevNetEv -ne $newNetEv)) -and $stateContainer.OnNetEtwStateChanged) {
                & $stateContainer.OnNetEtwStateChanged $newNetCap $newNetEv
            }

            # A. Clear Previous Tick's 1-Tick Lifecycle Flashes (New -> Normal, Exiting -> Remove)
            $exitingPidsToRemove = [System.Collections.Generic.List[int]]::new()
            foreach ($kvp in $processMap.GetEnumerator()) {
                if ($kvp.Value.LifecycleState -eq 1) {
                    $kvp.Value.SetLifecycleState(0)
                } elseif ($kvp.Value.LifecycleState -eq 2) {
                    $exitingPidsToRemove.Add($kvp.Key)
                }
            }
            foreach ($remPid in $exitingPidsToRemove) {
                [void]$processMap.Remove($remPid)
                $structureChanged = $true
            }

            # B. Process Newly Exited PIDs (Flash Red on Tick N, Remove on Tick N+1)
            $deadArr = $data['dead']
            $exitedLogNames = [System.Collections.Generic.List[string]]::new()
            if ($deadArr -and $deadArr.Count -gt 0) {
                foreach ($dPid in $deadArr) {
                    $deadPidInt = [int]$dPid
                    if ($processMap.ContainsKey($deadPidInt)) {
                        $deadVm = $processMap[$deadPidInt]
                        $exitedLogNames.Add("$($deadVm.Name) ($deadPidInt)")
                        $deadVm.SetLifecycleState(2)
                        $deadVm.UpdateDynamic(0.0, $deadVm.MemoryBytes, $deadVm.PrivateBytes, 0, 0, 0)
                        $deadVm.UpdateNetwork(0L, 0L)
                    }
                }
            }

            # C. Process Differential Services Update (Added/Changed + Removed)
            $svcArr     = $data['svc']
            $svcDeadArr = $data['svcDead']
            $svcChanged = ($svcArr -and $svcArr.Count -gt 0) -or ($svcDeadArr -and $svcDeadArr.Count -gt 0)
            if ($svcChanged) {
                if ($svcDeadArr -and $svcDeadArr.Count -gt 0) {
                    $deadSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($dn in $svcDeadArr) {
                        $dnStr = [string]$dn
                        [void]$deadSet.Add($dnStr)
                        if ($servicesMap.ContainsKey($dnStr)) {
                            [void]$servicesMap.Remove($dnStr)
                        }
                    }
                    if ($null -ne $ServicesCollection) {
                        for ($si = $ServicesCollection.Count - 1; $si -ge 0; $si--) {
                            if ($deadSet.Contains([string]$ServicesCollection[$si].Name)) {
                                $ServicesCollection.RemoveAt($si)
                            }
                        }
                    }
                }

                if ($svcArr -and $svcArr.Count -gt 0) {
                    foreach ($s in $svcArr) {
                        $sName = [string]$s['n']
                        $sDisp = [string]$s['d']
                        $sPid  = [int]$s['p']
                        $sSt   = [string]$s['st']
                        $sSm   = [string]$s['sm']
                        $sUsr  = [string]$s['u']
                        $sDep  = if ($s['dep']) { [string]$s['dep'] } else { "" }
                        $sRev  = if ($s['rev']) { [string]$s['rev'] } else { "" }
                        $sDesc = if ($s['dsc']) { [string]$s['dsc'] } else { "" }
                        $sBin  = if ($s['bin']) { [string]$s['bin'] } else { "" }

                        if ($servicesMap.ContainsKey($sName)) {
                            $servicesMap[$sName].UpdateService($sName, $sDisp, $sPid, $sSt, $sSm, $sUsr, $sDep, $sRev, $sDesc, $sBin)
                        } else {
                            $sVm = & $createServiceVm
                            $sVm.UpdateService($sName, $sDisp, $sPid, $sSt, $sSm, $sUsr, $sDep, $sRev, $sDesc, $sBin)
                            $servicesMap[$sName] = $sVm
                            if ($null -ne $ServicesCollection) {
                                $ServicesCollection.Add($sVm)
                            }
                        }
                    }
                }

                $pidServicesMap.Clear()
                foreach ($svcVmCur in $servicesMap.Values) {
                    if ($svcVmCur.PID -gt 0) {
                        if (-not $pidServicesMap.ContainsKey($svcVmCur.PID)) {
                            $pidServicesMap[$svcVmCur.PID] = [System.Collections.Generic.List[string]]::new()
                        }
                        $pidServicesMap[$svcVmCur.PID].Add($svcVmCur.Name)
                    }
                }

                foreach ($pKvp in $processMap.GetEnumerator()) {
                    $pVmItem = $pKvp.Value
                    $newHosted = if ($pidServicesMap.ContainsKey($pKvp.Key)) { ($pidServicesMap[$pKvp.Key] -join ", ") } else { "" }
                    if ($pVmItem.HostedServices -ne $newHosted) {
                        $pVmItem.HostedServices = $newHosted
                        $pVmItem.OnPropertyChanged('HostedServices')
                        if ($pVmItem.Name -eq "svchost.exe") {
                            $pVmItem.Description = if ($newHosted) { "Host Process for Windows Services ($newHosted)" } else { "Host Process for Windows Services" }
                            $pVmItem.OnPropertyChanged('Description')
                        }
                    }
                }

                if ($null -ne $ServicesCollection -and $Window) {
                    $txtSvcSum = $Window.FindName("TxtSvcSummary")
                    if ($txtSvcSum) {
                        $totCount = $ServicesCollection.Count
                        $runCount = 0
                        foreach ($svm in $ServicesCollection) {
                            if ($svm.Status -eq "Running") { $runCount++ }
                        }
                        $stopCount = $totCount - $runCount
                        $txtSvcBox = $Window.FindName("TxtSearchServices")
                        $sTerm = if ($txtSvcBox) { $txtSvcBox.Text.Trim() } else { "" }
                        if ([string]::IsNullOrWhiteSpace($sTerm)) {
                            $txtSvcSum.Text = "$totCount Services ($runCount Running, $stopCount Stopped)"
                        } else {
                            $cv = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ServicesCollection)
                            $visCount = 0
                            if ($cv) { foreach ($ci in $cv) { $visCount++ } }
                            $txtSvcSum.Text = "$visCount of $totCount Services ($runCount Running, $stopCount Stopped)"
                        }
                    }
                }
            }

            # D. Ingest Static Metadata for Newly Spawned Processes (and Deferred Metadata Resolution)
            $metaArr = $data['meta']
            $spawnedLogNames = [System.Collections.Generic.List[string]]::new()
            $newSpawnedVms   = [System.Collections.Generic.List[Object]]::new()
            if ($metaArr -and $metaArr.Count -gt 0) {
                foreach ($m in $metaArr) {
                    try {
                        $pidVal = [int]$m['id']
                        $vm = $null
                        $isBrandNew = $false
                        if ($processMap.ContainsKey($pidVal)) {
                            $vm = $processMap[$pidVal]
                        } else {
                            $vm = & $createProcessVm
                            $processMap[$pidVal] = $vm
                            $isBrandNew = $true
                            $structureChanged = $true
                        }

                        $vm.EnableCategoryHighlights = $enableCatHighlights
                        $vm.SetStaticMetadata($m, $isDark)
                        if ($pidServicesMap.ContainsKey($pidVal)) {
                            $hostedStr = ($pidServicesMap[$pidVal] -join ", ")
                            $vm.HostedServices = $hostedStr
                            if ($vm.Name -eq "svchost.exe" -and $hostedStr) {
                                $vm.Description = "Host Process for Windows Services ($hostedStr)"
                                $vm.OnPropertyChanged('Description')
                            }
                        }

                        # Extract 16x16 Icon Locally if Path Exists on Host
                        $icoBmp = &$resolveProcessIcon $vm.Path
                        if ($icoBmp) {
                            $vm.IconSource = $icoBmp
                            $vm.FallbackIconVisibility = "Collapsed"
                            $vm.OnPropertyChanged('IconSource')
                            $vm.OnPropertyChanged('FallbackIconVisibility')
                        }

                        # Flash Lime Green for 1 Tick if Spawned After Initial Load
                        if ($isBrandNew -and $seq -gt 1) {
                            $vm.SetLifecycleState(1)
                            $newSpawnedVms.Add($vm)
                        }
                    } catch {}
                }

                # Second Pass: Resolve Parent & Grandparent Lineage for Newly Spawned Processes
                foreach ($spVm in $newSpawnedVms) {
                    $ppid = [int]$spVm.ParentPID
                    $lineageTag = ""
                    if ($ppid -gt 0 -and $ppid -ne $spVm.PID -and $processMap.ContainsKey($ppid)) {
                        $parentVm = $processMap[$ppid]
                        if ($parentVm.CreateTime -le 0 -or $spVm.CreateTime -le 0 -or $parentVm.CreateTime -le $spVm.CreateTime) {
                            $lineageTag = " <- Parent: $($parentVm.Name) ($ppid)"
                            $gppid = [int]$parentVm.ParentPID
                            if ($gppid -gt 0 -and $gppid -ne $ppid -and $gppid -ne $spVm.PID -and $processMap.ContainsKey($gppid)) {
                                $grandParentVm = $processMap[$gppid]
                                if ($grandParentVm.CreateTime -le 0 -or $parentVm.CreateTime -le 0 -or $grandParentVm.CreateTime -le $parentVm.CreateTime) {
                                    $lineageTag += " <- Grandparent: $($grandParentVm.Name) ($gppid)"
                                }
                            }
                        }
                    }
                    $spawnedLogNames.Add("$($spVm.Name) (PID $($spVm.PID), PPID $ppid, User: $($spVm.User))$lineageTag")
                }
            }

            # E. Ingest Differential Dynamic Tuples: [pid, cpu, wsBytes, privBytes, threads, handles, statusFlags (, netRxBps, netTxBps)]
            $dynArr = $data['dyn']
            if ($dynArr -and $dynArr.Count -gt 0) {
                foreach ($tuple in $dynArr) {
                    $pidVal = [int]$tuple[0]
                    if ($processMap.ContainsKey($pidVal)) {
                        $vm = $processMap[$pidVal]
                        $vm.UpdateDynamic(
                            [double]$tuple[1],
                            [long]$tuple[2],
                            [long]$tuple[3],
                            [int]$tuple[4],
                            [int]$tuple[5],
                            [int]$tuple[6]
                        )
                        if ($tuple.Count -ge 9 -and $newNetCap -eq 1) {
                            $vm.UpdateNetwork([long]$tuple[7], [long]$tuple[8])
                        }
                    }
                }
            }

            # F. Update System Summary Bar, Network Telemetry Badges & Audit Stream
            $telemStats.TotalWireBytes += $wireBytes
            $telemStats.TotalRawBytes  += $rawBytes
            $telemStats.TotalTicks++
            $telemStats.TotalRttMs     += $pollRttMs

            if (-not $isFullSnap) {
                if ($telemStats.RttSamples.Count -ge 240) { [void]$telemStats.RttSamples.Dequeue() }
                $telemStats.RttSamples.Enqueue($pollRttMs)
            }
            $p50Rtt = $pollRttMs
            $p95Rtt = $pollRttMs
            if ($telemStats.RttSamples.Count -gt 0) {
                $sortedRtt = [int[]]$telemStats.RttSamples.ToArray()
                [Array]::Sort($sortedRtt)
                $p50Idx = [int][Math]::Floor(($sortedRtt.Length - 1) * 0.50)
                $p95Idx = [int][Math]::Floor(($sortedRtt.Length - 1) * 0.95)
                $p50Rtt = $sortedRtt[$p50Idx]
                $p95Rtt = $sortedRtt[$p95Idx]
            }

            $wireKB       = [Math]::Round($wireBytes / 1024.0, 2)
            $rawKB        = [Math]::Round($rawBytes / 1024.0, 2)
            $gzipSavedPct = if ($rawBytes -gt 0 -and $rawBytes -gt $wireBytes) { [Math]::Round((1.0 - ($wireBytes / [double]$rawBytes)) * 100.0, 0) } else { 0 }

            $nowTickUtc = [DateTime]::UtcNow.Ticks
            $elapsedSec = if ($telemStats.LastTickUtcTicks -gt 0L) {
                [Math]::Max(0.1, ($nowTickUtc - $telemStats.LastTickUtcTicks) / 10000000.0)
            } else {
                [Math]::Max(0.25, $stateContainer.IntervalMs / 1000.0)
            }
            $telemStats.LastTickUtcTicks = $nowTickUtc
            $bwKBs        = [Math]::Round($wireKB / $elapsedSec, 2)
            $totRxKB      = [Math]::Round($telemStats.TotalWireBytes / 1024.0, 1)
            $totRawKB     = [Math]::Round($telemStats.TotalRawBytes / 1024.0, 1)

            $dynCount  = if ($dynArr)  { $dynArr.Count }  else { 0 }
            $metaCount = if ($metaArr) { $metaArr.Count } else { 0 }
            $deadCount = if ($deadArr) { $deadArr.Count } else { 0 }

            if ($txtTelemTransport) {
                $txtTelemTransport.Text = "$($stateContainer.TransportBadge) | RTT: ${pollRttMs}ms (P50: ${p50Rtt}ms / P95: ${p95Rtt}ms)"
                $txtTelemTransport.ToolTip = "$($stateContainer.TransportBadge) [$($stateContainer.TargetDisplayName)] | RTT: ${pollRttMs}ms (Delta P50: ${p50Rtt}ms, P95: ${p95Rtt}ms)"
            }
            if ($txtTelemPayload) {
                $encLabel = if ($wasGzip) { "${gzipSavedPct}% GZIP" } else { "Uncompressed" }
                $txtTelemPayload.Text = "Wire: $($wireKB.ToString('F2')) KB ($encLabel)"
                $txtTelemPayload.ToolTip = "Differential Wire: $($wireKB.ToString('F2')) KB -> Raw: $($rawKB.ToString('F2')) KB ($encLabel)"
            }
            if ($txtTelemNetwork) {
                $txtTelemNetwork.Text = "BW: $($bwKBs.ToString('F2')) KB/s | RX: $($totRxKB.ToString('F1')) KB"
                $txtTelemNetwork.ToolTip = "Bandwidth: $($bwKBs.ToString('F2')) KB/s | Total Wire RX: $($totRxKB.ToString('F1')) KB (Raw: $($totRawKB.ToString('F1')) KB)"
            }
            if ($txtTelemDelta) {
                $txtTelemDelta.Text = "Seq #$seq | Dyn: $dynCount (+${metaCount}/-${deadCount})"
                $txtTelemDelta.ToolTip = "Sequence #$seq | Dynamic Updates: $dynCount | New Processes (+Meta): $metaCount | Exited (-Exit): $deadCount"
            }

            $curSummaryVm = $summaryVmHolder.Value
            if ($curSummaryVm -and $data['hw']) {
                $curSummaryVm.UpdateHardwareInfo($data['hw'])
            }

            $sysArr = $data['sys']
            if ($curSummaryVm -and $sysArr -and $sysArr.Count -ge 8) {
                $curSummaryVm.UpdateSummary(
                    [double]$sysArr[0],
                    [long]$sysArr[1],
                    [long]$sysArr[2],
                    [int]$sysArr[3],
                    [int]$sysArr[4],
                    [int]$sysArr[5],
                    [long]$sysArr[6],
                    [long]$sysArr[7]
                )

                if ($sysArr.Count -ge 27) {
                    $curSummaryVm.UpdateExtendedTelemetry($sysArr, $data['cores'])
                }

                if ($statusText) {
                    $netTag = if ($curSummaryVm.NetThroughputFormatted -and $curSummaryVm.NetThroughputFormatted -ne "NET: 0.0 KB/s") { " | $($curSummaryVm.NetThroughputFormatted)" } else { "" }
                    $etwTag = switch ($newNetCap) {
                        1 { " | Net ETW: $newNetEv/s" }
                        2 { " | Net ETW: AUTO-PAUSED" }
                        3 { " | Net ETW: NON-ADMIN" }
                        default { "" }
                    }
                    $telemMsg = "CPU: $($curSummaryVm.CpuSummaryFormatted) | Commit: $($curSummaryVm.CommitSummaryFormatted) | Procs: $($curSummaryVm.ProcessCount) | RAM: $($curSummaryVm.RamPctFormatted)$netTag$etwTag | Wire: $($wireKB.ToString('F2')) KB (${pollRttMs} ms)"
                    $stateContainer.LastStatusText = $telemMsg
                    if ($stateContainer.IsPaused) {
                        $statusText.Text = "[PAUSED] $telemMsg"
                    } else {
                        $statusText.Text = $telemMsg
                    }
                }
            }

            # Append Rich Telemetry & Process Lifecycle Events to Audit Console
            if ($LogConsole) {
                $ts = (Get-Date).ToString("HH:mm:ss.fff")
                $sbLog = [System.Text.StringBuilder]::new()
                $colMsVal    = if ($data.ContainsKey('colMs'))    { [int]$data['colMs'] }    else { 0 }
                $svcMsVal    = if ($data.ContainsKey('svcMs'))    { [int]$data['svcMs'] }    else { 0 }
                $svcFullVal  = if ($data.ContainsKey('svcFull'))  { [int]$data['svcFull'] }  else { 0 }
                $metaPendVal = if ($data.ContainsKey('metaPend')) { [int]$data['metaPend'] } else { 0 }
                $svcDeadCnt  = if ($svcDeadArr) { $svcDeadArr.Count } else { 0 }
                $svcUpdCnt   = if ($svcArr)     { $svcArr.Count }     else { 0 }

                if ($seq -eq 1 -or $isFullSnap) {
                    $svcCount = if ($svcArr) { $svcArr.Count } else { 0 }
                    $pendSyncTag = if ($metaPendVal -gt 0) { " (MetaPending: $metaPendVal)" } else { "" }
                    [void]$sbLog.AppendLine("[$ts] [SYNC #$seq] Full Snapshot from '$($stateContainer.TargetDisplayName)' ($($stateContainer.TransportBadge)) | RTT: ${pollRttMs}ms (Col: ${colMsVal}ms, SvcScan: ${svcMsVal}ms) | Wire: $($wireKB.ToString('F2')) KB -> Raw: $($rawKB.ToString('F2')) KB (GZIP ${gzipSavedPct}% saved) | Procs: $metaCount$pendSyncTag, Services: $svcCount")
                } elseif ($stateContainer.VerboseTelemetryLog) {
                    $svcSyncMode = if ($svcFullVal -eq 1) { "full" } else { "delta" }
                    $svcTag  = if ($svcUpdCnt -gt 0 -or $svcDeadCnt -gt 0 -or $svcMsVal -gt 0) { ", SvcSync ($svcSyncMode): +$svcUpdCnt/-$svcDeadCnt, SvcScan: ${svcMsVal}ms" } else { "" }
                    $pendTag = if ($metaPendVal -gt 0) { ", MetaPending: $metaPendVal" } else { "" }
                    [void]$sbLog.AppendLine("[$ts] [TELEM]   Seq #$($seq.ToString().PadLeft(4)) | RTT: $($pollRttMs.ToString().PadLeft(3))ms (Col: ${colMsVal}ms, P50: ${p50Rtt}ms, P95: ${p95Rtt}ms) | Wire: $($wireKB.ToString('F2').PadLeft(5)) KB -> Raw: $($rawKB.ToString('F2').PadLeft(5)) KB (GZIP ${gzipSavedPct}%) | BW: $($bwKBs.ToString('F2')) KB/s (RX: $($totRxKB.ToString('F1')) KB) | Dyn: $dynCount, +Meta: $metaCount, -Exit: $deadCount$svcTag$pendTag")
                }

                foreach ($spName in $spawnedLogNames) {
                    [void]$sbLog.AppendLine("[$ts] [PROC+]   Spawned: $spName")
                }
                foreach ($exName in $exitedLogNames) {
                    [void]$sbLog.AppendLine("[$ts] [PROC-]   Exited:  $exName")
                }

                if ($sbLog.Length -gt 0) {
                    $isPinned = ($LogConsole.ViewportHeight -le 0) -or (($LogConsole.VerticalOffset + $LogConsole.ViewportHeight) -ge ($LogConsole.ExtentHeight - 4.0))
                    if ($isPinned) {
                        if ($LogConsole.Text.Length -gt 72000) {
                            $LogConsole.Text = $LogConsole.Text.Substring($LogConsole.Text.Length - 48000)
                        }
                        $LogConsole.AppendText($sbLog.ToString())
                        $LogConsole.ScrollToEnd()
                    } else {
                        if ($LogConsole.Text.Length -gt 192000) {
                            $savedOffset = $LogConsole.VerticalOffset
                            $LogConsole.Text = $LogConsole.Text.Substring($LogConsole.Text.Length - 144000)
                            $LogConsole.ScrollToVerticalOffset([Math]::Max(0.0, $savedOffset - 1200.0))
                        }
                        $LogConsole.AppendText($sbLog.ToString())
                    }
                }
            }

            # G. Update Tree / Flat View Order (Realtime Dynamic Metric Re-sorting)
            $dynSortProps = @("CPU", "TreeCPU", "MemoryBytes", "PrivateBytes", "Threads", "Handles", "NetRxBps", "NetTxBps", "NetTotalBps", "TreeNetRxBps", "TreeNetTxBps", "TreeNetTotalBps")
            $needsOrderPass = $structureChanged -or ($stateContainer.SortProperty -in $dynSortProps)
            if ($needsOrderPass -or $ProcessCollection.Count -eq 0) {
                & $updateViewCollections
            } elseif (($dynArr -and $dynArr.Count -gt 0) -or ($deadArr -and $deadArr.Count -gt 0)) {
                & $recalculateTreeCpu
            }
        } catch {
            $stateContainer.LastErr = "UI Sync Error: $($_.Exception.Message)"
        }
    }.GetNewClosure()

    $timer.add_Tick($tickHandler)
    $timer.Start()

    $enqueueCommand = {
        param([hashtable]$cmdObj, [scriptblock]$onComplete)
        $reqId = [guid]::NewGuid().ToString("N")
        $cmdObj['RequestId'] = $reqId
        if ($onComplete) {
            $callbacks[$reqId] = $onComplete
        }
        $stateContainer.CommandQueue.Enqueue($cmdObj)
        [void]$stateContainer.WakeEvent.Set()
    }.GetNewClosure()

    $setSummaryViewModel = {
        param([Object]$vm)
        if ($vm) { $summaryVmHolder.Value = $vm }
    }.GetNewClosure()

    $reconcileServices = {
        param([System.Collections.Generic.List[Object]]$desiredServices)
        if ($null -ne $ServicesCollection) {
            &$reconcileCollection $ServicesCollection $desiredServices $null
        }
    }.GetNewClosure()

    return @{
        Runspace            = $rs
        PowerShell          = $ps
        Handle              = $asyncHandle
        Timer               = $timer
        StateContainer      = $stateContainer
        ProcessMap          = $processMap
        ServicesMap         = $servicesMap
        PidServicesMap      = $pidServicesMap
        TelemStats          = $telemStats
        RefreshTree         = $updateViewCollections
        SendCommand         = $enqueueCommand
        SetSummaryViewModel = $setSummaryViewModel
        ReconcileServices   = $reconcileServices
        ReconcileCollection = $reconcileCollection
        RequestFullSync     = $requestFullSync
    }
}
