# Requires -Version 5.1
# Automated Verification & Benchmark Suite for PSRPM
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot "PSRPM\PSRPM.psd1"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " PSRPM Automated Architecture, Telemetry & UI Verification Suite" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------
# TEST 1: Fileless Compliance Audit (Zero Add-Type -TypeDefinition)
# ------------------------------------------------------------------
Write-Host "`n[TEST 1] Auditing codebase for 100% fileless EDR compliance..." -ForegroundColor Yellow
$psFiles = Get-ChildItem -Path (Join-Path $repoRoot "PSRPM") -Recurse -Filter "*.ps*"
foreach ($f in $psFiles) {
    $content = Get-Content -Path $f.FullName -Raw
    if ($content -match 'Add-Type\s+-(TypeDefinition|MemberDefinition)') {
        throw "EDR Violation in $($f.Name): Found Add-Type -TypeDefinition/MemberDefinition (spawns csc.exe)."
    }
}
Write-Host "  [PASS] Zero csc.exe / Add-Type -TypeDefinition calls across $($psFiles.Count) module files." -ForegroundColor Green

# ------------------------------------------------------------------
# TEST 2: Module Manifest & Exported Commands
# ------------------------------------------------------------------
Write-Host "`n[TEST 2] Importing PSRPM Module & Verifying Exports..." -ForegroundColor Yellow
Import-Module $manifestPath -Force
$cmds = Get-Command -Module PSRPM
if (($cmds.Name -notcontains "Start-PSRPM") -or ($cmds.Name -notcontains "Start-RemoteProcessManager")) {
    throw "Missing expected exported functions in PSRPM module."
}
Write-Host "  [PASS] Exported functions verified: $($cmds.Name -join ', ')" -ForegroundColor Green

# Dot-source private components for direct unit testing
$privDir = Join-Path $repoRoot "PSRPM\Private"
. (Join-Path $privDir "ViewModelClasses.ps1")
. (Join-Path $privDir "DataCollector.ps1")
. (Join-Path $privDir "DeepInspector.ps1")
. (Join-Path $privDir "ProcessActions.ps1")

Add-Type -AssemblyName System.Web.Extensions
$jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
$jss.MaxJsonLength = 10485760

function Expand-GzipPayload([string]$raw) {
    if (-not $raw.StartsWith("GZIP:")) { return $raw }
    $bytes = [Convert]::FromBase64String($raw.Substring(5))
    $ms = [System.IO.MemoryStream]::new($bytes, $false)
    $gs = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $sr = [System.IO.StreamReader]::new($gs, [System.Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd()
    $sr.Close(); $gs.Close(); $ms.Close()
    return $txt
}

# ------------------------------------------------------------------
# TEST 3: Native Telemetry Collector (Tick 1 Full Sync + Tick 2 Delta)
# ------------------------------------------------------------------
Write-Host "`n[TEST 3] Benchmarking Native NtQuerySystemInformation(5) Collector..." -ForegroundColor Yellow

$sw1 = [System.Diagnostics.Stopwatch]::StartNew()
$rawTick1 = & $script:PSRPMCollectorScriptBlock $true
$sw1.Stop()

$jsonTick1 = Expand-GzipPayload $rawTick1
$dataTick1 = $jss.DeserializeObject($jsonTick1)

$tick1WireKB = [Math]::Round($rawTick1.Length / 1024.0, 2)
Write-Host "  Tick 1 (Initial Full Sync): $($sw1.ElapsedMilliseconds) ms | Wire Payload: $tick1WireKB KB | Processes: $($dataTick1['meta'].Count) | Services: $($dataTick1['svc'].Count)" -ForegroundColor Gray

if ($dataTick1['meta'].Count -lt 1) {
    throw "Expected at least 1 process on Tick 1, got $($dataTick1['meta'].Count)."
}

# Verify current $PID exists in metadata and has accurate PPID, Path, User, and Arch
$selfMeta = $dataTick1['meta'] | Where-Object { $_['id'] -eq $PID } | Select-Object -First 1
if (-not $selfMeta) {
    throw "Current PowerShell process (PID $PID) not found in Tick 1 metadata."
}
Write-Host "  Verified Self Process (PID $PID): Name='$($selfMeta['n'])', PPID=$($selfMeta['p']), Arch='$($selfMeta['arch'])', Cat='$($selfMeta['cat'])', Co='$($selfMeta['comp'])'" -ForegroundColor Gray

Start-Sleep -Milliseconds 250

$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
$rawTick2 = & $script:PSRPMCollectorScriptBlock $false
$sw2.Stop()

$jsonTick2 = Expand-GzipPayload $rawTick2
$dataTick2 = $jss.DeserializeObject($jsonTick2)
$tick2WireKB = [Math]::Round($rawTick2.Length / 1024.0, 2)

Write-Host "  Tick 2 (Differential Sync): $($sw2.ElapsedMilliseconds) ms | Wire Payload: $tick2WireKB KB | New Meta: $($dataTick2['meta'].Count) | Changed Dyn: $($dataTick2['dyn'].Count)" -ForegroundColor Gray
if ($dataTick1['sys'].Count -lt 27 -or -not $dataTick1['hw'] -or $null -ne $dataTick2['hw']) {
    throw "Expected 27 sys metrics and one-time hw metadata on Tick 1 (got sys=$($dataTick1['sys'].Count), hw1=$($null -ne $dataTick1['hw']), hw2=$($null -ne $dataTick2['hw']))."
}
Write-Host "  Verified System Info Telemetry: $($dataTick1['sys'].Count) kernel/hardware counters, $($dataTick1['cores'].Count) CPU core series, OS='$($dataTick1['hw']['os'])', CPU='$($dataTick1['hw']['cpu'])'" -ForegroundColor Gray
Write-Host "  [PASS] Differential telemetry engine verified (Steady-State Latency: $($sw2.ElapsedMilliseconds) ms, Wire Size: $tick2WireKB KB)." -ForegroundColor Green

# ------------------------------------------------------------------
# TEST 4: Deep Process Inspector (PEB, Mitigations, Threads, Sockets)
# ------------------------------------------------------------------
Write-Host "`n[TEST 4] Testing On-Demand Deep Process Inspector (Lazy Tab Modes) against PID $PID..." -ForegroundColor Yellow
$swCore = [System.Diagnostics.Stopwatch]::StartNew()
$coreJson = & $script:PSRPMDeepInspectorScriptBlock $PID $false "Core"
$swCore.Stop()
$coreData = $jss.DeserializeObject($coreJson)

if (-not $coreData['CurrentDirectory'] -or $coreData['CurrentDirectory'] -eq "N/A") {
    throw "DeepInspector (Core) failed to read remote PEB CurrentDirectory."
}
if ($coreData['Environment'].Count -lt 3) {
    throw "DeepInspector (Core) failed to read remote PEB Environment block."
}
if ($coreData['Modules'].Count -ne 0 -or $coreData['Handles'].Count -ne 0) {
    throw "DeepInspector (Core) should skip Modules and Handles for zero-overhead dialog startup."
}

$swMod = [System.Diagnostics.Stopwatch]::StartNew()
$modJson = & $script:PSRPMDeepInspectorScriptBlock $PID $false "Modules"
$swMod.Stop()
$modData = $jss.DeserializeObject($modJson)
if ($modData['Modules'].Count -lt 5) {
    throw "DeepInspector (Modules) failed to enumerate loaded DLLs/Modules (got $($modData['Modules'].Count))."
}

$swHnd = [System.Diagnostics.Stopwatch]::StartNew()
$hndJson = & $script:PSRPMDeepInspectorScriptBlock $PID $false "Handles"
$swHnd.Stop()
$hndData = $jss.DeserializeObject($hndJson)
if ($hndData['Handles'].Count -lt 3) {
    throw "DeepInspector (Handles) failed to enumerate open Handles (got $($hndData['Handles'].Count))."
}

$modVm = [InspectorModuleItem]::new($modData['Modules'][0])
$hndVm = [InspectorHandleItem]::new($hndData['Handles'][0])
if ([string]::IsNullOrWhiteSpace($modVm.Name) -or [string]::IsNullOrWhiteSpace($hndVm.Name)) {
    throw "InspectorModuleItem / InspectorHandleItem CLR ViewModel binding failed."
}

$swPerf = [System.Diagnostics.Stopwatch]::StartNew()
$perfJson = & $script:PSRPMDeepInspectorScriptBlock $PID $false "Performance"
$swPerf.Stop()
$perfData = $jss.DeserializeObject($perfJson)
if (-not $perfData['Performance'] -or -not $perfData['Performance']['Cycles']) {
    throw "DeepInspector (Performance) failed to query CPU Cycles."
}
if ($perfData['Modules'].Count -ne 0 -or $perfData['Handles'].Count -ne 0 -or $perfData['Environment'].Count -ne 0) {
    throw "DeepInspector (Performance) should skip Modules, Handles, and Environment for ultra-fast live polling."
}

Write-Host "  Core Inspector Latency (Dialog Open) : $($swCore.ElapsedMilliseconds) ms" -ForegroundColor Gray
Write-Host "  Live Perf Latency (1s Timer Poll)    : $($swPerf.ElapsedMilliseconds) ms (Cycles: $($perfData['Performance']['Cycles']))" -ForegroundColor Gray
Write-Host "  Lazy DLLs Tab Latency (On-Demand)    : $($swMod.ElapsedMilliseconds) ms ($($modData['Modules'].Count) modules, e.g. $($modVm.Name))" -ForegroundColor Gray
Write-Host "  Lazy Handles Tab Latency (On-Demand) : $($swHnd.ElapsedMilliseconds) ms ($($hndData['Handles'].Count) named handles, e.g. $($hndVm.Type): $($hndVm.Name))" -ForegroundColor Gray
Write-Host "  PEB CurrentDirectory                 : $($coreData['CurrentDirectory'])" -ForegroundColor Gray
Write-Host "  PEB Environment Vars                 : $($coreData['Environment'].Count) variables extracted" -ForegroundColor Gray
Write-Host "  CPU Cycles                           : $($coreData['Performance']['Cycles'])" -ForegroundColor Gray
Write-Host "  [PASS] Deep Process Inspector & Lazy Tab Modes verified." -ForegroundColor Green

# ------------------------------------------------------------------
# TEST 5: Process Actions (Priority Change on Current Process)
# ------------------------------------------------------------------
Write-Host "`n[TEST 5] Testing ProcessActions (SetPriority)..." -ForegroundColor Yellow
$actJson = & $script:PSRPMActionScriptBlock "SetPriority" $PID "powershell" "" "Normal"
$actRes = $jss.DeserializeObject($actJson)
if (-not $actRes['Success']) {
    throw "SetPriority action failed: $($actRes['Message'])"
}
Write-Host "  [PASS] ProcessActions verified: $($actRes['Message'])" -ForegroundColor Green

# TEST 5B: Process Memory Dump Generation (CreateDump - Minidump)
Write-Host "  Testing ProcessActions (CreateDump Mini)..." -ForegroundColor Gray
$dumpJson = & $script:PSRPMActionScriptBlock "CreateDump" $PID "powershell" "" "Normal" "" "Mini"
$dumpRes = $jss.DeserializeObject($dumpJson)
if (-not $dumpRes['Success'] -or -not (Test-Path $dumpRes['DumpPath'])) {
    throw "CreateDump action failed: $($dumpRes['Message'])"
}
$dumpBytes = [System.IO.File]::ReadAllBytes($dumpRes['DumpPath'])
$isMdmp = ($dumpBytes.Length -ge 4 -and $dumpBytes[0] -eq 0x4D -and $dumpBytes[1] -eq 0x44 -and $dumpBytes[2] -eq 0x4D -and $dumpBytes[3] -eq 0x50) # 'MDMP'
Remove-Item -Path $dumpRes['DumpPath'] -Force -ErrorAction SilentlyContinue
if (-not $isMdmp) {
    throw "Generated dump file is missing MDMP signature."
}
Write-Host "  [PASS] CreateDump verified: Valid MDMP minidump created and verified at $($dumpRes['DumpPath'])" -ForegroundColor Green

# TEST 5C: ProcessActions (CloseHandle via DuplicateHandle)
Write-Host "  Testing ProcessActions (CloseHandle)..." -ForegroundColor Gray
$tempLockFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "psrpm_test_lock.tmp")
$fsLock = [System.IO.File]::Open($tempLockFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
$hLockVal = "0x{0:X}" -f $fsLock.SafeFileHandle.DangerousGetHandle().ToInt64()
$closeJson = & $script:PSRPMActionScriptBlock "CloseHandle" $PID "powershell" "" "Normal" $hLockVal ""
$closeRes = $jss.DeserializeObject($closeJson)
if (-not $closeRes['Success']) {
    throw "CloseHandle action failed: $($closeRes['Message'])"
}
$fileUnlocked = $false
try {
    [System.IO.File]::Delete($tempLockFile)
    $fileUnlocked = $true
} catch {
    $fileUnlocked = $false
}
if (-not $fileUnlocked) {
    throw "CloseHandle succeeded but target file remained locked."
}
Write-Host "  [PASS] CloseHandle verified: Atomic handle invalidation released locked file." -ForegroundColor Green

# ------------------------------------------------------------------
# TEST 6: ViewModel Classes & WPF XAML Integrity Verification
# ------------------------------------------------------------------
Write-Host "`n[TEST 6] Verifying WPF XAML Templates & ViewModel Data Binding..." -ForegroundColor Yellow
$uiDir = Join-Path $repoRoot "PSRPM\UI"
$xamlFiles = @(
    @{ File = "MainWindow.xaml";       RequiredControls = @("GridProcesses", "GridServices", "SummaryBar", "TxtSearch", "BtnClearSearch", "ConnStatusDot", "TxtTargetBadge", "BtnToolbarTree", "BtnToolbarTheme", "BtnToolbarHelp", "BtnToolbarPause", "IconToolbarPause", "TxtToolbarPause", "BadgePaused", "LogPane", "TxtLogConsole", "TxtTelemTransport", "TxtTelemPayload", "TxtTelemNetwork", "TxtTelemDelta", "ChkStreamTicks", "BtnCopyLog", "MenuSystemInfo", "MenuHelpTopics", "MenuHelpAbout", "MenuFileHelp", "CardMiniCpu", "CardMiniCommit", "CardMiniRam", "HostTabsList", "BtnAddHostTab", "BtnSvcStart", "BtnSvcStop", "BtnSvcRestart", "BtnSvcProperties", "BtnSvcGoToProcess", "TxtSvcSummary", "TxtSearchServices", "BtnClearSearchServices", "MenuHighlightCategories", "BtnToggleHighlights", "MenuFindHandle", "BtnFindHandleOrDll", "MenuCreateMiniDump", "MenuCreateFullDump", "MenuThemeLight", "MenuThemeDark", "MenuThemeClassic", "MenuThemeHighContrast", "TxtTelemNetRate", "TxtTelemDiskRate") }
    @{ File = "PropertiesWindow.xaml"; RequiredControls = @("PropTabControl", "PropDescription", "PropVersion", "PropBuildTime", "PropWorkDir", "BtnVerifySig", "BtnSuspendResume", "BtnPropCreateDump", "GridPropDlls", "GridPropHandles", "GridNetConnections", "GridPropServices", "GridPropEnv") }
    @{ File = "ConnectDialog.xaml";    RequiredControls = @("RbRemoteHost", "RbLocalOnly", "TxtConnectComputer", "ChkUseSSL", "TxtConnectPort", "BtnPickCredential", "BtnConnectSubmit", "ChkOpenInNewTab") }
    @{ File = "SystemInfoWindow.xaml"; RequiredControls = @("SysInfoTabControl", "ChkPerCpuGraph", "BtnSysInfoOk", "QuadCpu", "QuadCommit", "QuadRam", "QuadIo") }
    @{ File = "HelpWindow.xaml";       RequiredControls = @("HelpTabControl", "TxtAboutVersion", "TxtAboutHost", "TxtAboutUser", "TxtAboutTarget", "TxtAboutTransport", "TxtAboutPsVersion", "TxtAboutClrVersion", "TxtAboutArch", "BtnHelpClose") }
    @{ File = "ServiceDetailWindow.xaml"; RequiredControls = @("TxtDlgDisplayName", "TxtDlgServiceName", "TxtDlgPid", "BadgeDlgStatus", "TxtDlgStatus", "SvcTabControl", "TxtDlgDescription", "TxtDlgPath", "TxtDlgStartup", "TxtDlgAccount", "TxtDlgDepSummary", "GridDlgPrereqs", "GridDlgDependents", "BtnDlgStart", "BtnDlgStop", "BtnDlgRestart", "BtnDlgClose") }
    @{ File = "FindHandleWindow.xaml"; RequiredControls = @("TxtSearchHandle", "BtnSearchHandle", "TxtHandleStatus", "GridHandleResults", "CtxCloseHandle", "CtxGoToProcess", "CtxCopyPath", "BtnCloseHandle", "BtnGoToProcess", "BtnCopyPath", "BtnCloseDlg") }
)

foreach ($xf in $xamlFiles) {
    $fullPath = Join-Path $uiDir $xf.File
    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    $ms = [System.IO.MemoryStream]::new($bytes)
    $winObj = [System.Windows.Markup.XamlReader]::Load($ms)
    $ms.Close()

    foreach ($ctrlName in $xf.RequiredControls) {
        $ctrl = $winObj.FindName($ctrlName)
        if ($null -eq $ctrl) {
            throw "XAML Verification Failed: Control '$ctrlName' not found in $($xf.File)."
        }
    }
    Write-Host "  Verified $($xf.File): All $($xf.RequiredControls.Count) required named controls resolved cleanly." -ForegroundColor Gray
}

# Verify ViewModel instantiation and methods
$vmTest = [ProcessItemViewModel]::new()
$vmTest.SetStaticMetadata($selfMeta, $false)
$vmTest.UpdateDynamic(1.25, 65536000, 45056000, 14, 420, 0)
$vmTest.UpdateTreeState(2, $true, $true, "M 7.5,0 L 7.5,22 M 23.5,0 L 23.5,11.5 L 31,11.5", 1.0)
$vmTest.SetTheme($true)
$vmTest.SetTheme($false)

# Verify Process Explorer-style Command Line ToolTip
if ([string]::IsNullOrWhiteSpace($vmTest.CommandLineToolTip) -or -not $vmTest.CommandLineToolTip.Contains("Command line:")) {
    throw "ProcessItemViewModel failed to build Process Explorer-style CommandLineToolTip."
}

# Verify Selective Category Highlighting & Lifecycle Flash Invariance
$vmTest.SetCategoryHighlights($true)
if ($vmTest.RowBackground -ne "#FFFFFF" -and -not $vmTest.RowBackground.StartsWith("#")) {
    throw "RowBackground failed to initialize with category highlighting enabled."
}
$vmTest.SetCategoryHighlights($false)
if ($vmTest.RowBackground -ne "#FFFFFF") {
    throw "RowBackground expected neutral #FFFFFF when category highlights are disabled."
}
# Critical requirement: Lifecycle flashes (Lime/Crimson) remain active when category highlights are off
$vmTest.LifecycleState = 1 # New Process
$vmTest.RefreshRowColors()
if ($vmTest.RowBackground -ne "#86EFAC") {
    throw "Lifecycle New process flash (Lime Green #86EFAC) was suppressed when category highlights were disabled."
}
$vmTest.LifecycleState = 2 # Exiting Process
$vmTest.RefreshRowColors()
if ($vmTest.RowBackground -ne "#FCA5A5") {
    throw "Lifecycle Exiting process flash (Crimson Red #FCA5A5) was suppressed when category highlights were disabled."
}
$vmTest.LifecycleState = 0
$vmTest.RefreshRowColors()
Write-Host "  Verified Selective Highlighting: Lifecycle flashes (Lime/Crimson) strictly preserved when category colors disabled." -ForegroundColor Gray

$sumTest = [SystemSummaryViewModel]::new()
$sumTest.IsSysInfoOpen = $true
$sumTest.UpdateHardwareInfo($dataTick1['hw'])
$sumTest.UpdateSummary(12.4, 8589934592, 17179869184, 185, 2400, 75000, 10737418240, 21474836480)
$sumTest.UpdateExtendedTelemetry($dataTick2['sys'], $dataTick2['cores'])
$sumTest.SetPerCpuMode($true)
$sumTest.SetPerCpuMode($false)
if ($sumTest.CoreGraphs.Count -lt 1 -or [string]::IsNullOrWhiteSpace($sumTest.CommitLimitK)) {
    throw "SystemSummaryViewModel extended System Information telemetry failed to populate."
}

# Verify HostTabItemViewModel
$tabVm = [HostTabItemViewModel]::new("tab_1", "Localhost", "Localhost", "LOCAL", $true, $sumTest)
$tabVm.UpdateVisualState($true, $false, $false, "LocalMode", $false, 45)
if (-not $tabVm.IsActive -or $tabVm.StatusDotFill -ne "#16A34A" -or $tabVm.TitleFontWeight -ne "Bold") {
    throw "HostTabItemViewModel active state verification failed."
}
$tabVm.UpdateVisualState($false, $true, $true, "Standby", $false, 0)
if ($tabVm.IsActive -or $tabVm.CloseVisibility -ne "Visible" -or $tabVm.StatusDotFill -ne "#64748B") {
    throw "HostTabItemViewModel standby state verification failed."
}
$tabVm.UpdateVisualState($true, $false, $false, "LocalMode", $true, 45)
if ($tabVm.StatusDotFill -ne "#F59E0B" -or $tabVm.LatencyText -ne "Paused") {
    throw "HostTabItemViewModel paused state verification failed."
}
Write-Host "  Verified HostTabItemViewModel: Active/Standby visual styling, isolated state maps and theme switching." -ForegroundColor Gray

# Verify ServiceItemViewModel
$svcVmTest = [ServiceItemViewModel]::new()
$svcVmTest.UpdateService("Spooler", "Print Spooler", 1234, "Running", "Auto", "LocalSystem", "RPCSS, HTTP", "Fax", "Spools print jobs", "C:\Windows\System32\spoolsv.exe")
if ($svcVmTest.Name -ne "Spooler" -or $svcVmTest.Status -ne "Running" -or -not $svcVmTest.CanStop -or -not $svcVmTest.CanRestart -or $svcVmTest.CanStart -or $svcVmTest.DependenciesFormatted -ne "RPCSS, HTTP" -or $svcVmTest.DependentServicesFormatted -ne "Fax" -or $svcVmTest.BinaryPath -ne "C:\Windows\System32\spoolsv.exe") {
    throw "ServiceItemViewModel verification failed for running service with dependencies."
}
$svcVmTest.UpdateService("Spooler", "Print Spooler", 0, "Stopped", "Auto", "LocalSystem", "", "", "Spools print jobs", "C:\Windows\System32\spoolsv.exe")
if ($svcVmTest.Status -ne "Stopped" -or $svcVmTest.CanStop -or $svcVmTest.CanRestart -or -not $svcVmTest.CanStart -or $svcVmTest.DependenciesFormatted -ne "None") {
    throw "ServiceItemViewModel verification failed for stopped service."
}
Write-Host "  Verified ServiceItemViewModel: Lifecycle status, dependencies formatting and action controls." -ForegroundColor Gray

Write-Host "  [PASS] All XAML templates and ViewModel classes verified." -ForegroundColor Green

# ------------------------------------------------------------------
# TEST 7: End-to-End RunspaceEngine, Dispatcher Sync & Tree Builder
# ------------------------------------------------------------------
Write-Host "`n[TEST 7] Testing End-to-End RunspaceEngine & Tree-Grid Reconciliation..." -ForegroundColor Yellow
. (Join-Path $privDir "RunspaceEngine.ps1")

$mainBytes = [System.IO.File]::ReadAllBytes((Join-Path $uiDir "MainWindow.xaml"))
$msMain = [System.IO.MemoryStream]::new($mainBytes)
$testWin = [System.Windows.Markup.XamlReader]::Load($msMain)
$msMain.Close()

$procCol = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$svcCol  = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$sumVm   = [SystemSummaryViewModel]::new()

$testWin.FindName("GridProcesses").ItemsSource = $procCol
$testWin.FindName("GridServices").ItemsSource  = $svcCol
$testWin.FindName("SummaryBar").DataContext    = $sumVm

$eng = Start-PSRPMEngine `
    -PSSession $null `
    -Window $testWin `
    -ProcessCollection $procCol `
    -ServicesCollection $svcCol `
    -SummaryViewModel $sumVm `
    -CollectorScript $script:PSRPMCollectorScriptBlock `
    -InspectorScript $script:PSRPMDeepInspectorScriptBlock `
    -ActionScript $script:PSRPMActionScriptBlock `
    -IntervalMs 300 `
    -IsLocal $true `
    -TargetName "TEST-HOST"

try {
    # Wait up to 3 seconds while pumping the WPF Dispatcher queue
    $deadline = [DateTime]::UtcNow.AddSeconds(3.5)
    while ([DateTime]::UtcNow -lt $deadline -and $procCol.Count -eq 0) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{}
        )
        Start-Sleep -Milliseconds 50
    }

    if ($procCol.Count -lt 1) {
        throw "RunspaceEngine did not populate ProcessCollection within timeout."
    }

    Write-Host "  Tree-Grid populated with $($procCol.Count) live process nodes (ProcessMap: $($eng.ProcessMap.Count), Latency: $($eng.StateContainer.PollLatencyMs) ms)." -ForegroundColor Gray

    # Inject synthetic multi-level parent/child/grandchild hierarchy to verify tree traversal, guide geometry & sorting
    $pRoot = [ProcessItemViewModel]::new()
    $pRoot.SetStaticMetadata(@{ id = 90001; ct = 100; n = "services.exe"; p = 4; u = "SYSTEM"; arch = "x64"; path = "C:\Windows\System32\services.exe"; cmd = "services.exe"; desc = "Services"; comp = "Microsoft"; start = "2026-11-07"; sid = 0; prio = 9; cat = "Service" }, $false)
    $pChild1 = [ProcessItemViewModel]::new()
    $pChild1.SetStaticMetadata(@{ id = 90002; ct = 200; n = "svchost.exe"; p = 90001; u = "SYSTEM"; arch = "x64"; path = "C:\Windows\System32\svchost.exe"; cmd = "svchost.exe -k netsvcs"; desc = "Host Process"; comp = "Microsoft"; start = "2026-11-07"; sid = 0; prio = 8; cat = "Service" }, $false)
    $pGrandChild = [ProcessItemViewModel]::new()
    $pGrandChild.SetStaticMetadata(@{ id = 90003; ct = 300; n = "psrpm_test_proc.exe"; p = 90002; u = "LocalUser"; arch = "x64"; path = "psrpm_test_proc.exe"; cmd = "psrpm_test_proc.exe"; desc = "TestProc"; comp = "Microsoft"; start = "2026-11-07"; sid = 1; prio = 8; cat = "Packaged" }, $false)

    $eng.ProcessMap[90001] = $pRoot
    $eng.ProcessMap[90002] = $pChild1
    $eng.ProcessMap[90003] = $pGrandChild

    & $eng.RefreshTree
    if ($pGrandChild.Level -ne 2 -or [string]::IsNullOrWhiteSpace($pGrandChild.TreeGuideGeometry)) {
        throw "Tree builder failed to compute Level=2 and SVG guide geometry for grandchild node (Level=$($pGrandChild.Level), Geom='$($pGrandChild.TreeGuideGeometry)')."
    }
    Write-Host "  Verified 3-Tier Tree Hierarchy: Root(L$($pRoot.Level)) -> Child(L$($pChild1.Level)) -> GrandChild(L$($pGrandChild.Level), Geom='$($pGrandChild.TreeGuideGeometry)')" -ForegroundColor Gray

    # Test Ancestor-Preserving Search Filter (searching 'psrpm_test_proc' should keep 90001, 90002, 90003 in Tree Mode)
    $eng.StateContainer.FilterText = "psrpm_test_proc"
    & $eng.RefreshTree
    if ($procCol.Count -ne 3) {
        throw "Ancestor-preserving filter expected 3 nodes (root + parent + match), got $($procCol.Count)."
    }
    Write-Host "  Verified Ancestor-Preserving Filter: Matched leaf + 2 ancestors ($($procCol.Count) rows visible, ancestor opacity=$($pRoot.RowOpacity))." -ForegroundColor Gray

    # Test Flat Mode & Reset Filter
    $eng.StateContainer.IsTreeMode = $false
    & $eng.RefreshTree
    if ($procCol.Count -ne 1) {
        throw "Flat mode filter expected 1 direct match, got $($procCol.Count)."
    }
    $eng.StateContainer.IsTreeMode = $true
    $eng.StateContainer.FilterText = ""
    & $eng.RefreshTree

    # Test SendCommand Async Command Bus (InspectPid Modules with .GetNewClosure() UI callback)
    $cbState  = @{ Fired = $false; Count = 0; Err = "" }
    $localJss = $jss
    $cmdInspect = @{
        CommandType     = "InspectPid"
        TargetPid       = $PID
        VerifySignature = $false
        InspectMode     = "Modules"
    }
    & $eng.SendCommand $cmdInspect ({
        param($res)
        if ($res.Success -and $res.PayloadJson) {
            try {
                $d = $localJss.DeserializeObject($res.PayloadJson)
                $modList = [System.Collections.Generic.List[Object]]::new()
                if ($d['Modules']) {
                    foreach ($mItem in $d['Modules']) {
                        $modList.Add([PSCustomObject]@{
                            Name        = [string]$mItem['Name']
                            Description = [string]$mItem['Description']
                            CompanyName = [string]$mItem['CompanyName']
                            Version     = [string]$mItem['Version']
                            Size        = [string]$mItem['Size']
                            BaseAddress = [string]$mItem['BaseAddress']
                            Path        = [string]$mItem['Path']
                        })
                    }
                }
                $cbState.Count = $modList.Count
                $cbState.Fired = $true
            } catch {
                $cbState.Err = $_.Exception.Message
                $cbState.Fired = $true
            }
        }
    }.GetNewClosure())
    $cbDeadline = [DateTime]::UtcNow.AddSeconds(3.0)
    while ([DateTime]::UtcNow -lt $cbDeadline -and -not $cbState.Fired) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{}
        )
        Start-Sleep -Milliseconds 50
    }
    if (-not $cbState.Fired -or $cbState.Count -lt 5) {
        throw "SendCommand async InspectPid (Modules) callback failed (Fired=$($cbState.Fired), Count=$($cbState.Count), Err=$($cbState.Err))."
    }
    Write-Host "  Verified Async Command Bus (SendCommand -> InspectPid[Modules] -> UI Closure Callback populated $($cbState.Count) DLL rows)." -ForegroundColor Gray

    # Test FindHandles command on Async Command Bus
    $findState = @{ Fired = $false; Matches = 0; PayloadJson = ""; Err = "" }
    $localFindState = $findState
    & $eng.SendCommand @{
        CommandType = "FindHandles"
        Query       = "kernel32"
    } ({
        param($res)
        if ($res.Success -and $res.PayloadJson) {
            $parsed = $jss.DeserializeObject($res.PayloadJson)
            $localFindState.Matches = $parsed.Count
            $localFindState.PayloadJson = $res.PayloadJson
            $localFindState.Fired = $true
        } else {
            $localFindState.Err = $res.Error
            $localFindState.Fired = $true
        }
    }.GetNewClosure())

    $findDeadline = [DateTime]::UtcNow.AddSeconds(3.0)
    while ([DateTime]::UtcNow -lt $findDeadline -and -not $findState.Fired) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{}
        )
        Start-Sleep -Milliseconds 50
    }
    if (-not $findState.Fired -or $findState.Matches -lt 1) {
        throw "SendCommand async FindHandles command bus callback failed (Fired=$($findState.Fired), Matches=$($findState.Matches), Err=$($findState.Err))."
    }
    Write-Host "  Verified Async Command Bus (SendCommand -> FindHandles['kernel32'] -> UI Callback returned $($findState.Matches) matches)." -ForegroundColor Gray

    # Verify FindHandleWindow GridHandleResults Data Binding & Visible Text Rendering
    $fBytes = [System.IO.File]::ReadAllBytes((Join-Path $uiDir "FindHandleWindow.xaml"))
    $msF = [System.IO.MemoryStream]::new($fBytes)
    $findWinTest = [System.Windows.Markup.XamlReader]::Load($msF)
    $msF.Close()
    $dgFindTest = $findWinTest.FindName("GridHandleResults")
    $parsedMatches = $jss.DeserializeObject($findState.PayloadJson)
    $testFindCol = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    foreach ($m in $parsedMatches) {
        $testFindCol.Add([PSCustomObject]@{
            ProcessName = [string]$m['ProcessName']
            PID         = [int]$m['PID']
            Type        = [string]$m['Type']
            Handle      = [string]$m['Handle']
            Name        = [string]$m['Name']
        })
    }
    $dgFindTest.ItemsSource = $testFindCol
    $findWinTest.Show()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $dgFindTest.UpdateLayout()
    $rowTest = $dgFindTest.ItemContainerGenerator.ContainerFromIndex(0)
    if ($rowTest) {
        $cell0 = $dgFindTest.Columns[0].GetCellContent($rowTest)
        if (-not $cell0 -or [string]::IsNullOrEmpty($cell0.Text)) {
            $findWinTest.Close()
            throw "FindHandleWindow DataGrid text binding failed: Cell text in column 0 (ProcessName) is empty."
        }
        $findWinTest.Close()
        Write-Host "  Verified FindHandleWindow DataGrid binding: ProcessName text '$($cell0.Text)' rendered with non-empty text." -ForegroundColor Gray
    } else {
        $findWinTest.Close()
        throw "FindHandleWindow DataGrid failed to generate row container."
    }

    # Test Multi-Host Tab Session Command Bus
    $testTabsCol = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    $localTestTabs = $testTabsCol
    $tabCb = @{ Fired = $false; Success = $false; TabId = "" }
    $cmdAddTab = @{
        CommandType  = "AddTabSession"
        TabId        = "tab_test_2"
        ComputerName = "localhost"
        IsLocal      = $true
        Credential   = $null
        Port         = 0
        UseSSL       = $false
    }
    $fnCreateTestTabVm = { param($id, $target, $transport, $isLoc) [HostTabItemViewModel]::new($id, $target, $target, $transport, [bool]$isLoc, $null) }
    & $eng.SendCommand $cmdAddTab ({
        param($res)
        $tabCb.Fired   = $true
        $tabCb.Success = [bool]$res.Success
        $tabCb.TabId   = [string]$res.TabId
        if ($res.Success) {
            $tVm = & $fnCreateTestTabVm $res.TabId $res.Target $res.Transport $res.IsLocal
            $localTestTabs.Add($tVm)
        }
    }.GetNewClosure())

    $tabDeadline = [DateTime]::UtcNow.AddSeconds(3.0)
    while ([DateTime]::UtcNow -lt $tabDeadline -and -not $tabCb.Fired) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{}
        )
        Start-Sleep -Milliseconds 50
    }
    if (-not $tabCb.Fired -or -not $tabCb.Success -or $testTabsCol.Count -ne 1) {
        throw "SendCommand AddTabSession failed or did not update tabs collection."
    }
    Write-Host "  Verified AddTabSession multi-session bus command (Created Tab '$($tabCb.TabId)', TabsCollection Count=$($testTabsCol.Count))." -ForegroundColor Gray

    # Select Tab
    $selCb = @{ Fired = $false; Success = $false }
    & $eng.SendCommand @{ CommandType = "SelectTabSession"; TabId = "tab_test_2"; ForceFullSync = $true } ({
        param($res)
        $selCb.Fired = $true
        $selCb.Success = [bool]$res.Success
    }.GetNewClosure())

    $selDeadline = [DateTime]::UtcNow.AddSeconds(3.0)
    while ([DateTime]::UtcNow -lt $selDeadline -and -not $selCb.Fired) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{}
        )
        Start-Sleep -Milliseconds 50
    }
    if (-not $selCb.Fired -or -not $selCb.Success) {
        throw "SendCommand SelectTabSession failed."
    }
    Write-Host "  Verified SelectTabSession multi-session bus command." -ForegroundColor Gray

    # Close Tab
    $closeCb = @{ Fired = $false; Success = $false }
    & $eng.SendCommand @{ CommandType = "CloseTabSession"; TabId = "tab_test_2" } ({
        param($res)
        $closeCb.Fired = $true
        $closeCb.Success = [bool]$res.Success
    }.GetNewClosure())

    $closeDeadline = [DateTime]::UtcNow.AddSeconds(3.0)
    while ([DateTime]::UtcNow -lt $closeDeadline -and -not $closeCb.Fired) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{}
        )
        Start-Sleep -Milliseconds 50
    }
    if (-not $closeCb.Fired -or -not $closeCb.Success) {
        throw "SendCommand CloseTabSession failed."
    }
    Write-Host "  Verified CloseTabSession multi-session bus command." -ForegroundColor Gray

    Write-Host "  [PASS] End-to-End RunspaceEngine, Tree-Grid reconciliation & ancestor filter verified." -ForegroundColor Green
} finally {
    $eng.Timer.Stop()
    $eng.StateContainer.IsStopping = $true
    [void]$eng.StateContainer.WakeEvent.Set()
    Start-Sleep -Milliseconds 80
    $eng.PowerShell.Dispose()
    $eng.Runspace.Close()
    $eng.Runspace.Dispose()
}

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host " ALL 7 PSRPM VERIFICATION SUITES PASSED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
[System.Environment]::Exit(0)
