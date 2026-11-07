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
        SortProperty        = "PID"
        SortDescending      = $false
        FilterText          = ""
        CategoryFilter      = ""
        ForceFullSync       = $true
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

        $collectorSb = [scriptblock]::Create($collectorCode)
        $inspectorSb = [scriptblock]::Create($inspectorCode)
        $actionSb    = [scriptblock]::Create($actionCode)

        # Multi-Host Session Dictionary (TabId -> @{ Session, IsLocal, Target, Badge, CollectorSb })
        $sessions = @{}
        $initBadge = if ($isLocalMode) { "LOCAL" } else { "WINRM" }
        $sessions[$initTabId] = @{
            Session     = $session
            IsLocal     = $isLocalMode
            Target      = $stateContainer.TargetDisplayName
            Badge       = $initBadge
            CollectorSb = $collectorSb
        }
        $activeTabId = $initTabId

        while (-not $stateContainer.IsStopping) {
            # 1. Drain High-Priority User Commands Immediately
            $cmd = $null
            while ($stateContainer.CommandQueue.TryDequeue([ref]$cmd)) {
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

                            $jsonRes = if ($useLocal) {
                                & $inspectorSb $targetPid $verifySig $inspectMode
                            } else {
                                Invoke-Command -Session $useSess -ScriptBlock $inspectorSb -ArgumentList @($targetPid, $verifySig, $inspectMode) -ErrorAction Stop
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

                        "ProcessAction" {
                            $actName  = [string]$cmd.Action
                            $tPid     = [int]$cmd.TargetPid
                            $expName  = [string]$cmd.ExpectedName
                            $svcName  = [string]$cmd.ServiceName
                            $prio     = [string]$cmd.Priority
                            $useLocal = if ($activeSessObj) { [bool]$activeSessObj.IsLocal } else { $isLocalMode }
                            $useSess  = if ($activeSessObj) { $activeSessObj.Session } else { $session }

                            $jsonRes = if ($useLocal) {
                                & $actionSb $actName $tPid $expName $svcName $prio
                            } else {
                                Invoke-Command -Session $useSess -ScriptBlock $actionSb -ArgumentList @($actName, $tPid, $expName, $svcName, $prio) -ErrorAction Stop
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
                                $so = New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 15000 -CancelTimeout 5000 -NoMachineProfile
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
                                Session     = $newSess
                                IsLocal     = $newLocal
                                Target      = $targetName
                                Badge       = $badge
                                CollectorSb = [scriptblock]::Create($collectorCode)
                            }

                            $activeTabId = $newTabId
                            $stateContainer.ActiveTabId       = $newTabId
                            $stateContainer.TargetDisplayName = $targetName
                            $stateContainer.TransportBadge    = $badge
                            $stateContainer.ConnectionState   = if ($newLocal) { "LocalMode" } else { "Connected" }
                            $stateContainer.ForceFullSync     = $true

                            $swCmd.Stop()
                            $stateContainer.ResultQueue.Enqueue(@{
                                RequestId   = $cmd.RequestId
                                CommandType = "AddTabSession"
                                Success     = $true
                                TabId       = $newTabId
                                Target      = $targetName
                                Transport   = $badge
                                IsLocal     = $newLocal
                                ElapsedMs   = $swCmd.ElapsedMilliseconds
                            })
                        }

                        "SelectTabSession" {
                            $selTabId = [string]$cmd.TabId
                            if ($sessions.ContainsKey($selTabId)) {
                                $activeTabId = $selTabId
                                $curr = $sessions[$selTabId]
                                $stateContainer.ActiveTabId       = $selTabId
                                $stateContainer.TargetDisplayName = $curr.Target
                                $stateContainer.TransportBadge    = $curr.Badge
                                $stateContainer.ConnectionState   = if ($curr.IsLocal) { "LocalMode" } else { "Connected" }
                                $stateContainer.ForceFullSync     = [bool]$cmd.ForceFullSync
                            }
                            $swCmd.Stop()
                            $stateContainer.ResultQueue.Enqueue(@{
                                RequestId   = $cmd.RequestId
                                CommandType = "SelectTabSession"
                                Success     = $true
                                TabId       = $selTabId
                            })
                        }

                        "CloseTabSession" {
                            $closeTabId = [string]$cmd.TabId
                            if ($sessions.ContainsKey($closeTabId)) {
                                $sessToClose = $sessions[$closeTabId]
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
                                    $stateContainer.ConnectionState   = if ($curr.IsLocal) { "LocalMode" } else { "Connected" }
                                    $stateContainer.ForceFullSync     = $true
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
                                $so = New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 15000 -CancelTimeout 5000 -NoMachineProfile
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
                                Session     = $newSess
                                IsLocal     = $newLocal
                                Target      = $targetName
                                Badge       = $badge
                                CollectorSb = [scriptblock]::Create($collectorCode)
                            }

                            $stateContainer.ClearHostMaps = $true
                            $stateContainer.ForceFullSync = $true
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

            # 2. Periodic Telemetry Snapshot Poll on Active Host Session (0 KB/s standby for inactive tabs)
            if (-not $stateContainer.IsPaused -and $sessions.ContainsKey($activeTabId) -and ($null -eq $stateContainer.Payload -or $stateContainer.ForceFullSync)) {
                $swPoll = [System.Diagnostics.Stopwatch]::StartNew()
                $activeSessObj = $sessions[$activeTabId]
                try {
                    $forceFull = [bool]$stateContainer.ForceFullSync
                    $stateContainer.ForceFullSync = $false

                    $rawResult = if ($activeSessObj.IsLocal) {
                        & $activeSessObj.CollectorSb $forceFull
                    } else {
                        $sRef = $activeSessObj.Session
                        if (-not $sRef -or $sRef.State -ne 'Opened') {
                            throw "WinRM session is not open (State: $(if ($sRef) { $sRef.State } else { 'Null' }))."
                        }
                        Invoke-Command -Session $sRef -ScriptBlock $collectorSb -ArgumentList @($forceFull) -ErrorAction Stop
                    }

                    $swPoll.Stop()
                    if ($rawResult) {
                        $stateContainer.PollLatencyMs   = [int]$swPoll.ElapsedMilliseconds
                        $stateContainer.PayloadBytes    = [int]([string]$rawResult).Length
                        $stateContainer.PayloadTabId    = $activeTabId
                        $stateContainer.Payload         = [string]$rawResult
                        $stateContainer.ConnectionState = if ($activeSessObj.IsLocal) { "LocalMode" } else { "Connected" }
                        $stateContainer.LastErr         = $null
                    }
                } catch {
                    $swPoll.Stop()
                    $stateContainer.ConnectionState = "Disconnected"
                    $stateContainer.LastErr         = $_.Exception.Message
                }
            }

            $waitMs = [int]$stateContainer.IntervalMs
            if ($waitMs -lt 250) { $waitMs = 250 }
            [void]$stateContainer.WakeEvent.WaitOne($waitMs)
        }

        foreach ($sItem in $sessions.Values) {
            if ($sItem.Session) {
                Remove-PSSession -Session $sItem.Session -ErrorAction SilentlyContinue
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
    $processMap     = [System.Collections.Generic.Dictionary[int, Object]]::new()
    $servicesMap    = [System.Collections.Generic.Dictionary[string, Object]]::new()
    $pidServicesMap = [System.Collections.Generic.Dictionary[int, System.Collections.Generic.List[string]]]::new()
    $iconCache      = @{}
    $callbacks      = @{}
    $jss            = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $jss.MaxJsonLength = 10485760

    # Helper: Extract 16x16 Associated Process Icon (Cached per Unique Path)
    $resolveProcessIcon = {
        param([string]$exePath)
        if ([string]::IsNullOrWhiteSpace($exePath) -or $exePath -eq "N/A") { return $null }
        $key = $exePath.ToLowerInvariant()
        if ($iconCache.ContainsKey($key)) { return $iconCache[$key] }

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

        $savedSelected = if ($grid) { $grid.SelectedItem } else { $null }

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

        if ($grid -and $savedSelected -and $targetSet.Contains($savedSelected) -and $grid.SelectedItem -ne $savedSelected) {
            $grid.SelectedItem = $savedSelected
        }
    }.GetNewClosure()

    # Core View Builder (Tree-Grid & Flat List + Ancestor-Preserving Filter + Sibling Sort)
    $gridProcesses = $Window.FindName("GridProcesses")
    $txtMatchCount = $Window.FindName("TxtMatchCount")

    $updateViewCollections = {
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

        foreach ($kvp in $processMap.GetEnumerator()) {
            $vm = $kvp.Value
            $vm.Children.Clear()

            $isMatch = $true
            if ($catFilter.Length -gt 0 -and $vm.Category -ne $catFilter) {
                $isMatch = $false
            }
            if ($isMatch -and $filterTxt.Length -gt 0) {
                $isMatch = ($vm.Name -like "*$filterTxt*") -or
                           ($vm.PIDDisplay -like "*$filterTxt*") -or
                           ($vm.Description -like "*$filterTxt*") -or
                           ($vm.CompanyName -like "*$filterTxt*") -or
                           ($vm.User -like "*$filterTxt*") -or
                           ($vm.CommandLine -like "*$filterTxt*") -or
                           ($vm.HostedServices -like "*$filterTxt*")
            }
            if ($isMatch) {
                [void]$directMatches.Add($vm.PID)
            }
        }

        if ($hasFilter -and $isTreeMode) {
            foreach ($matchPid in $directMatches) {
                $curr = $processMap[$matchPid]
                $guard = 0
                while ($curr -and $curr.ParentPID -gt 0 -and $processMap.ContainsKey($curr.ParentPID) -and $curr.ParentPID -ne $curr.PID -and $guard -lt 20) {
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
                [void]$processMap[$pPid].Children.Add($vm)
            } else {
                $roots.Add($vm)
            }
        }

        # Helper to sort any node list by current SortProperty
        $sortNodes = {
            param($list)
            if ($list.Count -le 1) { return $list }
            return @($list | Sort-Object -Property @{ Expression = $sortProp; Descending = $sortDesc }, @{ Expression = "PID"; Descending = $false })
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
    $txtTelemTransport = $Window.FindName("TxtTelemTransport")
    $txtTelemPayload   = $Window.FindName("TxtTelemPayload")
    $txtTelemNetwork   = $Window.FindName("TxtTelemNetwork")
    $txtTelemDelta     = $Window.FindName("TxtTelemDelta")

    $telemStats = @{
        TotalWireBytes = 0L
        TotalRawBytes  = 0L
        TotalTicks     = 0L
        TotalRttMs     = 0L
    }

    $tickHandler = {
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
                        $LogConsole.AppendText("[$tsErr] [ERROR] Command callback error: $($_.Exception.Message)`r`n")
                    }
                    $stateContainer.LastErr = "Command callback error: $($_.Exception.Message)"
                }
            }
        }

        # 2. Check Target Switch / Reset Request
        if ($stateContainer.ClearHostMaps) {
            $stateContainer.ClearHostMaps = $false
            $processMap.Clear()
            $servicesMap.Clear()
            $pidServicesMap.Clear()
            $ProcessCollection.Clear()
            if ($ServicesCollection) { $ServicesCollection.Clear() }
            if ($SummaryViewModel -and $SummaryViewModel.CoreGraphs) { $SummaryViewModel.CoreGraphs.Clear() }
            $telemStats.TotalWireBytes = 0L
            $telemStats.TotalRawBytes  = 0L
            $telemStats.TotalTicks     = 0L
            $telemStats.TotalRttMs     = 0L
        }

        # 3. Update Connection Status Indicators
        $cState = $stateContainer.ConnectionState
        if ($connDot) {
            if ($stateContainer.IsPaused) {
                $connDot.Fill = "#F59E0B"
            } elseif ($cState -in @("Connected", "LocalMode")) {
                $connDot.Fill = "#16A34A"
            } else {
                $connDot.Fill = "#DC2626"
            }
        }
        if ($txtTarget)    { $txtTarget.Text    = [string]$stateContainer.TargetDisplayName }
        if ($txtTransport) { $txtTransport.Text = [string]$stateContainer.TransportBadge }
        if ($txtLatency)   { $txtLatency.Text   = "$($stateContainer.PollLatencyMs) ms" }

        # 4. Consume Differential Telemetry Payload
        $payloadStr = $stateContainer.Payload
        if (-not $payloadStr) { return }
        $stateContainer.Payload = $null

        if ($stateContainer.PayloadTabId -and $stateContainer.ActiveTabId -and $stateContainer.PayloadTabId -ne $stateContainer.ActiveTabId) {
            return
        }

        try {
            $wireBytes = [int]$stateContainer.PayloadBytes
            $wasGzip   = $payloadStr.StartsWith("GZIP:")
            if ($wasGzip) {
                $b64 = $payloadStr.Substring(5)
                $compBytes = [Convert]::FromBase64String($b64)
                $msIn = [System.IO.MemoryStream]::new($compBytes, $false)
                $gsIn = [System.IO.Compression.GZipStream]::new($msIn, [System.IO.Compression.CompressionMode]::Decompress)
                $sr   = [System.IO.StreamReader]::new($gsIn, [System.Text.Encoding]::UTF8)
                $payloadStr = $sr.ReadToEnd()
                $sr.Close()
                $gsIn.Close()
                $msIn.Close()
            }
            $rawBytes = [int]$payloadStr.Length

            $data = $jss.DeserializeObject($payloadStr)
            if (-not $data) { return }

            $seq = [int]$data['seq']
            $isDark = [bool]$stateContainer.IsDarkTheme
            $structureChanged = $false

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
                    }
                }
            }

            # C. Process Services Update (if sent on this tick)
            $svcArr = $data['svc']
            if ($svcArr) {
                $pidServicesMap.Clear()
                foreach ($s in $svcArr) {
                    $sName = [string]$s['n']
                    $sDisp = [string]$s['d']
                    $sPid  = [int]$s['p']
                    $sSt   = [string]$s['st']
                    $sSm   = [string]$s['sm']
                    $sUsr  = [string]$s['u']

                    if ($sPid -gt 0) {
                        if (-not $pidServicesMap.ContainsKey($sPid)) {
                            $pidServicesMap[$sPid] = [System.Collections.Generic.List[string]]::new()
                        }
                        $pidServicesMap[$sPid].Add($sName)
                    }

                    if ($ServicesCollection) {
                        if ($servicesMap.ContainsKey($sName)) {
                            $servicesMap[$sName].UpdateService($sName, $sDisp, $sPid, $sSt, $sSm, $sUsr)
                        } else {
                            $sVm = [ServiceItemViewModel]::new()
                            $sVm.UpdateService($sName, $sDisp, $sPid, $sSt, $sSm, $sUsr)
                            $servicesMap[$sName] = $sVm
                            $ServicesCollection.Add($sVm)
                        }
                    }
                }
            }

            # D. Ingest Static Metadata for Newly Spawned Processes
            $metaArr = $data['meta']
            $spawnedLogNames = [System.Collections.Generic.List[string]]::new()
            if ($metaArr -and $metaArr.Count -gt 0) {
                foreach ($m in $metaArr) {
                    try {
                        $pidVal = [int]$m['id']
                        $vm = $null
                        $isBrandNew = $false
                        if ($processMap.ContainsKey($pidVal)) {
                            $vm = $processMap[$pidVal]
                        } else {
                            $vm = [ProcessItemViewModel]::new()
                            $processMap[$pidVal] = $vm
                            $isBrandNew = $true
                            $structureChanged = $true
                        }

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
                            $spawnedLogNames.Add("$($vm.Name) (PID $pidVal, PPID $($vm.ParentPID), User: $($vm.User))")
                        }
                    } catch {}
                }
            }

            # E. Ingest Differential Dynamic Tuples: [pid, cpu, wsBytes, privBytes, threads, handles, statusFlags]
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
                    }
                }
            }

            # F. Update System Summary Bar, Network Telemetry Badges & Audit Stream
            $telemStats.TotalWireBytes += $wireBytes
            $telemStats.TotalRawBytes  += $rawBytes
            $telemStats.TotalTicks++
            $telemStats.TotalRttMs     += $stateContainer.PollLatencyMs

            $wireKB       = [Math]::Round($wireBytes / 1024.0, 2)
            $rawKB        = [Math]::Round($rawBytes / 1024.0, 2)
            $gzipSavedPct = if ($rawBytes -gt 0 -and $rawBytes -gt $wireBytes) { [Math]::Round((1.0 - ($wireBytes / [double]$rawBytes)) * 100.0, 0) } else { 0 }
            $avgRtt       = [Math]::Round($telemStats.TotalRttMs / [double]$telemStats.TotalTicks, 1)
            $intervalSec  = [Math]::Max(0.25, $stateContainer.IntervalMs / 1000.0)
            $bwKBs        = [Math]::Round($wireKB / $intervalSec, 2)
            $totRxKB      = [Math]::Round($telemStats.TotalWireBytes / 1024.0, 1)
            $totRawKB     = [Math]::Round($telemStats.TotalRawBytes / 1024.0, 1)

            $dynCount  = if ($dynArr)  { $dynArr.Count }  else { 0 }
            $metaCount = if ($metaArr) { $metaArr.Count } else { 0 }
            $deadCount = if ($deadArr) { $deadArr.Count } else { 0 }

            if ($txtTelemTransport) {
                $txtTelemTransport.Text = "$($stateContainer.TransportBadge) [$($stateContainer.TargetDisplayName)] | RTT: $($stateContainer.PollLatencyMs)ms (Avg: ${avgRtt}ms)"
            }
            if ($txtTelemPayload) {
                $encLabel = if ($wasGzip) { "${gzipSavedPct}% GZIP" } else { "Uncompressed" }
                $txtTelemPayload.Text = "Wire: ${wireKB} KB -> Raw: ${rawKB} KB ($encLabel)"
            }
            if ($txtTelemNetwork) {
                $txtTelemNetwork.Text = "BW: ${bwKBs} KB/s | Total RX: ${totRxKB} KB (Raw: ${totRawKB} KB)"
            }
            if ($txtTelemDelta) {
                $txtTelemDelta.Text = "Seq #$seq | Dyn: $dynCount | +Meta: $metaCount | -Exit: $deadCount"
            }

            if ($data['hw']) {
                $SummaryViewModel.UpdateHardwareInfo($data['hw'])
            }

            $sysArr = $data['sys']
            if ($sysArr -and $sysArr.Count -ge 8) {
                $SummaryViewModel.UpdateSummary(
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
                    $SummaryViewModel.UpdateExtendedTelemetry($sysArr, $data['cores'])
                }

                if ($statusText) {
                    $statusText.Text = "CPU Usage: $($SummaryViewModel.CpuSummaryFormatted) | Commit Charge: $($SummaryViewModel.CommitSummaryFormatted) | Processes: $($SummaryViewModel.ProcessCount) | Physical Usage: $($SummaryViewModel.RamPctFormatted) | Wire: ${wireKB} KB ($($stateContainer.PollLatencyMs) ms)"
                }
            }

            # Append Rich Telemetry & Process Lifecycle Events to Audit Console
            if ($LogConsole) {
                $ts = (Get-Date).ToString("HH:mm:ss.fff")
                $sbLog = [System.Text.StringBuilder]::new()

                if ($seq -eq 1) {
                    $svcCount = if ($svcArr) { $svcArr.Count } else { 0 }
                    [void]$sbLog.AppendLine("[$ts] [SYNC #1] Full Snapshot from '$($stateContainer.TargetDisplayName)' ($($stateContainer.TransportBadge)) | RTT: $($stateContainer.PollLatencyMs)ms | Wire: ${wireKB} KB -> Raw: ${rawKB} KB (GZIP ${gzipSavedPct}% saved) | Procs: $metaCount, Services: $svcCount")
                } elseif ($stateContainer.VerboseTelemetryLog) {
                    $svcTag = if ($svcArr) { ", SvcSync: $($svcArr.Count)" } else { "" }
                    [void]$sbLog.AppendLine("[$ts] [TELEM]   Seq #$($seq.ToString().PadLeft(4)) | RTT: $($stateContainer.PollLatencyMs.ToString().PadLeft(3))ms (Avg: ${avgRtt}ms) | Wire: $($wireKB.ToString('F2').PadLeft(5)) KB -> Raw: $($rawKB.ToString('F2').PadLeft(5)) KB (GZIP ${gzipSavedPct}%) | BW: $($bwKBs.ToString('F2')) KB/s (RX: ${totRxKB} KB) | Dyn: $dynCount, +Meta: $metaCount, -Exit: $deadCount$svcTag")
                }

                foreach ($spName in $spawnedLogNames) {
                    [void]$sbLog.AppendLine("[$ts] [PROC+]   Spawned: $spName")
                }
                foreach ($exName in $exitedLogNames) {
                    [void]$sbLog.AppendLine("[$ts] [PROC-]   Exited:  $exName")
                }

                if ($sbLog.Length -gt 0) {
                    if ($LogConsole.Text.Length -gt 24000) {
                        $LogConsole.Text = $LogConsole.Text.Substring($LogConsole.Text.Length - 16000)
                    }
                    $LogConsole.AppendText($sbLog.ToString())
                    $LogConsole.ScrollToEnd()
                }
            }

            # G. Update Tree / Flat View Order
            $needsOrderPass = $structureChanged -or (-not $stateContainer.IsTreeMode -and $stateContainer.SortProperty -in @("CPU", "MemoryBytes", "PrivateBytes", "Threads", "Handles")) -or ($stateContainer.IsTreeMode -and $stateContainer.SortProperty -in @("CPU", "MemoryBytes", "PrivateBytes", "Threads", "Handles"))
            if ($needsOrderPass -or $ProcessCollection.Count -eq 0) {
                & $updateViewCollections
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

    return @{
        Runspace       = $rs
        PowerShell     = $ps
        Handle         = $asyncHandle
        Timer          = $timer
        StateContainer = $stateContainer
        ProcessMap     = $processMap
        ServicesMap    = $servicesMap
        PidServicesMap = $pidServicesMap
        RefreshTree    = $updateViewCollections
        SendCommand    = $enqueueCommand
    }
}
