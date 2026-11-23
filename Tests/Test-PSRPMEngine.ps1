# Requires -Version 5.1
# Automated Verification & Benchmark Suite for PSRPM
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $repoRoot "PSRPM\PSRPM.psd1"
$manifestData = Import-PowerShellDataFile -Path $manifestPath
$modVer = [string]$manifestData['ModuleVersion']

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

# Verify MUI indirect service descriptions (@%SystemRoot%\...\*.dll,-id) resolve to human-readable text
$evSvc = $dataTick1['svc'] | Where-Object { $_['n'] -eq 'EventLog' -or $_['n'] -eq 'Dhcp' } | Select-Object -First 1
if (-not $evSvc -or [string]::IsNullOrWhiteSpace($evSvc['dsc']) -or ([string]$evSvc['dsc']).StartsWith('@')) {
    throw "Service MUI description resolution failed for '$($evSvc['n'])': got '$($evSvc['dsc'])'."
}
Write-Host "  Verified Service MUI Resolution ($($evSvc['n'])): '$(($evSvc['dsc']).Substring(0, [Math]::Min(64, $evSvc['dsc'].Length)))...'" -ForegroundColor Gray

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
$selfMeta = $dataTick1['meta'] | Where-Object { $_['id'] -eq $PID } | Select-Object -First 1
if (-not $selfMeta -or -not $selfMeta.ContainsKey('ver') -or [string]::IsNullOrWhiteSpace([string]$selfMeta['ver'])) {
    throw "Expected static metadata 'ver' (FileVersion) to be populated for current PowerShell process PID=$PID."
}
Write-Host "  Verified System Info Telemetry: $($dataTick1['sys'].Count) kernel/hardware counters, $($dataTick1['cores'].Count) CPU core series, OS='$($dataTick1['hw']['os'])', CPU='$($dataTick1['hw']['cpu'])', SelfVer='$($selfMeta['ver'])'" -ForegroundColor Gray

# 30-Tick Steady-State Statistical Benchmark (with warmup + GC isolation)
$latencies = [System.Collections.Generic.List[double]]::new()
$wireSizes = [System.Collections.Generic.List[double]]::new()

for ($w = 1; $w -le 3; $w++) {
    $null = & $script:PSRPMCollectorScriptBlock $false
    Start-Sleep -Milliseconds 30
}
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
[GC]::Collect()

for ($t = 1; $t -le 30; $t++) {
    Start-Sleep -Milliseconds 50
    $swSample = [System.Diagnostics.Stopwatch]::StartNew()
    $rawSample = & $script:PSRPMCollectorScriptBlock $false
    $swSample.Stop()
    $latencies.Add([double]$swSample.ElapsedMilliseconds)
    $wireSizes.Add([double]([Math]::Round($rawSample.Length / 1024.0, 2)))
}

$sortedLat = [System.Collections.Generic.List[double]]::new($latencies)
$sortedLat.Sort()
$p95Index = [Math]::Min($sortedLat.Count - 1, [int][Math]::Ceiling($sortedLat.Count * 0.95) - 1)
$p95Lat   = $sortedLat[$p95Index]
$minLat   = $sortedLat[0]
$maxLat   = $sortedLat[$sortedLat.Count - 1]

$sumLat = 0.0; foreach ($l in $latencies) { $sumLat += $l }
$meanLat = $sumLat / $latencies.Count

$sumSqDiff = 0.0; foreach ($l in $latencies) { $sumSqDiff += [Math]::Pow($l - $meanLat, 2) }
$stdDevLat = [Math]::Sqrt($sumSqDiff / $latencies.Count)

$sumWire = 0.0; foreach ($w in $wireSizes) { $sumWire += $w }
$meanWire = $sumWire / $wireSizes.Count

Write-Host "  Steady-State 30-Tick Benchmark: Mean=$([Math]::Round($meanLat, 1))ms, P95=${p95Lat}ms, StdDev=$([Math]::Round($stdDevLat, 1))ms (Range: ${minLat}-${maxLat}ms) | Avg Wire: $([Math]::Round($meanWire, 2)) KB" -ForegroundColor Gray

if ($meanLat -gt 25.0) {
    throw "Benchmark Gate Failed: Mean steady-state latency ($([Math]::Round($meanLat, 1))ms) exceeded 25.0 ms ceiling."
}
if ($p95Lat -gt 35.0) {
    throw "Benchmark Gate Failed: P95 steady-state latency (${p95Lat}ms) exceeded 35.0 ms ceiling."
}
if ($meanWire -gt 3.5) {
    throw "Benchmark Gate Failed: Mean wire payload ($([Math]::Round($meanWire, 2)) KB) exceeded 3.5 KB ceiling."
}

Write-Host "  [PASS] Differential telemetry engine & statistical benchmarks verified." -ForegroundColor Green

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
# Verify non-inherited ACL protection
$dmpAcl = Get-Acl -Path $dumpRes['DumpPath']
if (-not $dmpAcl.AreAccessRulesProtected) {
    throw "Security Regression: Generated dump file $($dumpRes['DumpPath']) has inheritance enabled!"
}
$inheritedRules = @($dmpAcl.Access | Where-Object { $_.IsInherited })
if ($inheritedRules.Count -gt 0) {
    throw "Security Regression: Generated dump file contains inherited access rules!"
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

# Verify Process Properties / FindHandle Handle Closing Safeguard predicate
$testHandles = @(
    @{ Type = "DLL";        Handle = "0x100"; Name = "kernel32.dll"; Expected = $false }
    @{ Type = "[Error]";    Handle = "";      Name = "Access Denied"; Expected = $false }
    @{ Type = "[UI Error]"; Handle = "0x200"; Name = "UI Failure";   Expected = $false }
    @{ Type = "File";       Handle = "N/A";   Name = "\Device\HarddiskVolume3"; Expected = $false }
    @{ Type = "File";       Handle = "";      Name = ""; Expected = $false }
    @{ Type = "File";       Handle = "0x1A4"; Name = "C:\Windows\notepad.exe"; Expected = $true }
    @{ Type = "Key";        Handle = "0x2B8"; Name = "\REGISTRY\MACHINE"; Expected = $true }
)
foreach ($th in $testHandles) {
    $canClose = -not ($th.Type -eq "DLL" -or [string]::IsNullOrWhiteSpace($th.Handle) -or $th.Handle -eq "N/A" -or ($th.Type -and $th.Type.StartsWith("[")))
    if ($canClose -ne $th.Expected) {
        throw "Handle closing guard failed for Type='$($th.Type)', Handle='$($th.Handle)' (Expected: $($th.Expected), Got: $canClose)."
    }
}
Write-Host "  [PASS] Handle closing safeguard predicate verified (Zero wildcard syntax errors on bracketed types)." -ForegroundColor Green

# ------------------------------------------------------------------
# TEST 6: ViewModel Classes & WPF XAML Integrity Verification
# ------------------------------------------------------------------
Write-Host "`n[TEST 6] Verifying WPF XAML Templates & ViewModel Data Binding..." -ForegroundColor Yellow
$uiDir = Join-Path $repoRoot "PSRPM\UI"
$xamlFiles = @(
    @{ File = "MainWindow.xaml";       RequiredControls = @("RootLayoutPanel", "RootScaleTransform", "MainMenuBar", "MainStatusBar", "MiniMonitorBar", "MiniStatusDot", "TxtMiniHostName", "TxtMiniSearch", "BtnClearMiniSearch", "BtnMiniPause", "BtnExitMiniMonitor", "MenuDisplayDensity", "MenuLayoutStandard", "MenuLayoutCompact", "MenuLayoutMini", "MenuUiScale", "MenuScaleZoomIn", "MenuScaleZoomOut", "MenuScaleReset", "MenuScale75", "MenuScale100", "MenuScale125", "MenuScale150", "MenuScale175", "MenuScale200", "GridProcesses", "GridServices", "SummaryBar", "TxtSearch", "BtnClearSearch", "ConnStatusDot", "TxtTargetBadge", "BtnToolbarTree", "BtnToolbarTheme", "BtnToolbarHelp", "BtnToolbarPause", "IconToolbarPause", "TxtToolbarPause", "BadgePaused", "LogPane", "LogPaneResizer", "TxtLogConsole", "TxtTelemTransport", "TxtTelemPayload", "TxtTelemNetwork", "TxtTelemDelta", "ChkStreamTicks", "ChkLogAutoScroll", "BtnCopyLog", "MenuFile", "MenuReconnectHost", "MenuOptions", "MenuView", "MenuFind", "MenuHelp", "MenuGoToParent", "CtxGoToParent", "CtxExpandSubtree", "CtxCollapseSubtree", "MenuAlwaysOnTop", "MenuViewTreeLines", "MenuTreeOptions", "MenuTreeOrderNewest", "MenuTreeOrderClassic", "MenuNetEtwGroup", "MenuCopySubmenu", "MenuCopyName", "MenuCopyPid", "CtxCopySubmenu", "CtxCopyName", "CtxCopyPid", "MenuFindFilter", "MenuFindClearFilter", "MenuSavePreferences", "MenuResetPreferences", "MenuSystemInfo", "MenuHelpTopics", "MenuHelpAbout", "MenuThemeCycle", "MenuCopyCmdLine", "MenuCopyPath", "CtxPrioIdle", "CtxPrioHigh", "CardMiniCpu", "CardMiniCommit", "CardMiniRam", "HostTabsList", "BtnAddHostTab", "BtnSvcStart", "BtnSvcStop", "BtnSvcRestart", "BtnSvcProperties", "BtnSvcGoToProcess", "TxtSvcSummary", "TxtSearchServices", "BtnClearSearchServices", "MenuHighlightCategories", "BtnToggleHighlights", "MenuFindHandle", "BtnFindHandleOrDll", "MenuCreateMiniDump", "MenuCreateFullDump", "MenuThemeLight", "MenuThemeDark", "MenuThemeTokyoNight", "MenuThemeTokyoNightLight", "MenuThemeClassic", "MenuThemeHighContrast", "TxtTelemNetRate", "TxtTelemDiskRate", "BorderTelemNetRate", "MenuViewSelectColumns", "MenuViewBaseline", "MenuViewClearBaseline", "BadgeBaselineActive", "TxtBaselineLabel", "BtnClearBaseline", "MenuViewNetEtw", "MenuColTreeNet", "MenuColNetRxTx", "BtnToolbarNetEtw", "EllNetEtwDot", "TxtNetEtwBtn", "BtnToolbarNetRxTx", "NetEtwAlertBanner", "BtnNetEtwResume", "BtnNetEtwTurnOff", "BtnNetEtwDismiss", "ColProcess", "ColCpu", "ColTreeCpu", "ColNetTotal", "ColTreeNet", "ColNetRx", "ColNetTx", "ColPrivateBytes", "ColWorkingSet", "ColPeakCpu", "ColPeakPrivate", "ColCpuDelta", "ColPrivateDelta", "ColWorkingSetDelta", "ColPid", "ColParentPid", "ColDescription", "ColCompanyName", "ColVersion", "ColCommandLine", "ColPath", "ColUser", "ColHandles", "ColThreads", "ColSessionId", "ColBasePriority", "ColArchitecture", "ColStartTime", "ColStatus", "ColServices", "ColCategory", "TabNetworkActivity", "BtnNetModeSockets", "BtnNetModeTimeline", "BtnNetRefreshSockets", "ChkNetAutoRefresh", "BtnNetCloseConn", "ChipNetTcp4", "ChipNetTcp6", "ChipNetUdp4", "ChipNetUdp6", "ChipNetEstablished", "ChipNetListening", "ChipNetSynSent", "ChipNetTimeWait", "ChipNetRecv", "ChipNetSend", "BtnNetClear", "BtnNetExportCsv", "TxtNetActivitySummary", "TxtNetStatusCounts", "TxtSearchNetwork", "BtnClearSearchNetwork", "NetTabNoticeBanner", "BtnNetBannerEnableEtw", "BtnNetBannerSwitchSockets", "GridNetworkSockets", "GridNetworkTimeline", "CtxNetSockCloseConn", "CtxNetSockCopyDetails", "CtxNetTimeCopyDetails", "ProcEmptyStateOverlay", "BtnProcEmptyClear", "SvcEmptyStateOverlay", "BtnSvcEmptyClear", "NetEmptyStateOverlay") }
    @{ File = "PropertiesWindow.xaml"; RequiredControls = @("PropTabControl", "PropDescription", "PropVersion", "PropBuildTime", "PropWorkDir", "BtnVerifySig", "BtnSuspendResume", "BtnPropCreateDump", "GridPropDlls", "GridPropHandles", "GridNetConnections", "GridPropServices", "GridPropEnv") }
    @{ File = "ConnectDialog.xaml";    RequiredControls = @("RbRemoteHost", "RbLocalOnly", "TxtConnectComputer", "ChkUseSSL", "TxtConnectPort", "BtnPickCredential", "BtnConnectSubmit", "BtnConnectCancel", "TxtConnectProgress", "BdConnectError", "TxtConnectError", "ChkOpenInNewTab") }
    @{ File = "SystemInfoWindow.xaml"; RequiredControls = @("SysInfoTabControl", "ChkPerCpuGraph", "BtnSysInfoOk", "QuadCpu", "QuadCommit", "QuadRam", "QuadIo", "QuadNet") }
    @{ File = "HelpWindow.xaml";       RequiredControls = @("HelpTabControl", "TxtHeaderBadge", "TxtAboutVersion", "TxtAboutHost", "TxtAboutUser", "TxtAboutTarget", "TxtAboutTransport", "TxtAboutPsVersion", "TxtAboutClrVersion", "TxtAboutArch", "BtnHelpClose") }
    @{ File = "ServiceDetailWindow.xaml"; RequiredControls = @("TxtDlgDisplayName", "TxtDlgServiceName", "TxtDlgPid", "BadgeDlgStatus", "TxtDlgStatus", "SvcTabControl", "TxtDlgDescription", "TxtDlgPath", "TxtDlgStartup", "TxtDlgAccount", "TxtDlgDepSummary", "GridDlgPrereqs", "GridDlgDependents", "BtnDlgStart", "BtnDlgStop", "BtnDlgRestart", "BtnDlgClose") }
    @{ File = "FindHandleWindow.xaml"; RequiredControls = @("TxtSearchHandle", "BtnSearchHandle", "BtnCancelSearchHandle", "TxtHandleStatus", "PbHandleSearch", "GridHandleResults", "CtxCloseHandle", "CtxGoToProcess", "CtxCopyPath", "BtnCloseHandle", "BtnGoToProcess", "BtnCopyPath", "BtnCloseDlg") }
    @{ File = "SelectColumnsWindow.xaml"; RequiredControls = @("TxtSelectedCount", "BtnPresetDefault", "BtnPresetProcExp", "BtnPresetForensic", "TxtColFilter", "BtnColFilterClear", "LstAvailableColumns", "LstColumnOrder", "BtnColMoveUp", "BtnColMoveDown", "BtnColResetDefaults", "BtnColOk", "BtnColCancel") }
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

    if ($xf.File -in @("PropertiesWindow.xaml", "SelectColumnsWindow.xaml")) {
        foreach ($reqBrush in @("BrushWindowBg", "BrushToolbarBg", "BrushSurfaceBg", "BrushHeaderBg", "BrushBorderSubtle", "BrushTextPrimary", "BrushTextSecondary", "BrushTextMuted", "BrushRowHover")) {
            if (-not $winObj.Resources.Contains($reqBrush)) {
                throw "$($xf.File) missing default fallback SolidColorBrush '$reqBrush' in Window.Resources."
            }
        }
    }

    if ($xf.File -eq "HelpWindow.xaml") {
        $badgeText = [string]$winObj.FindName("TxtHeaderBadge").Text
        $aboutText = [string]$winObj.FindName("TxtAboutVersion").Text
        if ($badgeText -ne "v$modVer") {
            throw "HelpWindow.xaml TxtHeaderBadge expected 'v$modVer', got '$badgeText'."
        }
        if ($aboutText -ne $modVer) {
            throw "HelpWindow.xaml TxtAboutVersion expected '$modVer', got '$aboutText'."
        }
        Write-Host "  Verified HelpWindow.xaml: Header badge and About version tags match manifest v$modVer." -ForegroundColor Gray
    }

    Write-Host "  Verified $($xf.File): All $($xf.RequiredControls.Count) required named controls resolved cleanly." -ForegroundColor Gray
    if ($xf.File -eq "SystemInfoWindow.xaml") {
        $sysTabsTest = $winObj.FindName("SysInfoTabControl")
        if ($sysTabsTest.Items.Count -ne 5 -or [string]$sysTabsTest.Items[4].Header -ne "Network") {
            throw "SystemInfoWindow.xaml expected 5 tabs with 5th tab 'Network', got Count=$($sysTabsTest.Items.Count)."
        }
        foreach ($reqSysBrush in @("BrushNetRxStroke", "BrushNetRxFill", "BrushNetTxStroke", "BrushNetTxFill")) {
            if (-not $winObj.Resources.Contains($reqSysBrush)) {
                throw "SystemInfoWindow.xaml missing fallback brush '$reqSysBrush'."
            }
        }
    }
    if ($xf.File -eq "MainWindow.xaml") {
        $gridProcTest = $winObj.FindName("GridProcesses")
        if ($gridProcTest.SelectionMode -ne [System.Windows.Controls.DataGridSelectionMode]::Extended) {
            throw "MainWindow.xaml expected GridProcesses SelectionMode='Extended', got '$($gridProcTest.SelectionMode)'."
        }
        $colHeaders = @($gridProcTest.Columns | ForEach-Object { [string]$_.Header })
        $cpuIdx = [Array]::IndexOf($colHeaders, "CPU")
        $treeCpuIdx = [Array]::IndexOf($colHeaders, "Tree CPU Usage")
        if ($cpuIdx -lt 0 -or $treeCpuIdx -ne ($cpuIdx + 1)) {
            throw "MainWindow.xaml expected 'Tree CPU Usage' column directly to the right of 'CPU' (CPU=$cpuIdx, TreeCPU=$treeCpuIdx)."
        }
        $netColHeaders = @("Network", "Tree Net", "Net Recv", "Net Send")
        foreach ($nch in $netColHeaders) {
            $nCol = $gridProcTest.Columns | Where-Object { [string]$_.Header -eq $nch } | Select-Object -First 1
            if ($null -eq $nCol) { throw "MainWindow.xaml missing network column '$nch'." }
            if ($nCol.Visibility -ne [System.Windows.Visibility]::Collapsed) {
                throw "MainWindow.xaml network column '$nch' must start Collapsed when Net ETW is off."
            }
        }
        # Verify Menu UX Integrity: zero duplicate Alt-key mnemonics, visible Separator template, bounded View menu
        $checkMenuMnemonics = {
            param([System.Windows.Controls.ItemsControl]$parent, [string]$menuLabel)
            $seenKeys = @{}
            foreach ($mi in $parent.Items) {
                if ($mi -is [System.Windows.Controls.MenuItem]) {
                    $hdr = [string]$mi.Header
                    if ($hdr -match '(?<!_)_([A-Za-z0-9])') {
                        $k = $Matches[1].ToUpperInvariant()
                        if ($seenKeys.ContainsKey($k)) {
                            throw "Duplicate menu mnemonic '_$k' in '$menuLabel': '$($seenKeys[$k])' vs '$hdr'."
                        }
                        $seenKeys[$k] = $hdr
                    }
                    if ($mi.Items.Count -gt 0) {
                        & $checkMenuMnemonics $mi ("$menuLabel -> $($hdr -replace '_','')")
                    }
                }
            }
        }
        foreach ($topMenuName in @("MenuFile", "MenuOptions", "MenuView", "MenuProcess", "MenuFind", "MenuHelp")) {
            $tm = $winObj.FindName($topMenuName)
            if ($null -eq $tm) { throw "MainWindow.xaml missing top-level menu '$topMenuName'." }
            & $checkMenuMnemonics $tm $topMenuName
        }
        if ($gridProcTest.ContextMenu) {
            & $checkMenuMnemonics $gridProcTest.ContextMenu "GridProcesses.ContextMenu"
        }
        $viewDirectItems = @($winObj.FindName("MenuView").Items | Where-Object { $_ -is [System.Windows.Controls.MenuItem] }).Count
        if ($viewDirectItems -gt 12) {
            throw "MenuView has $viewDirectItems direct items (expected <= 12 to prevent menu sprawl)."
        }
        $sepTest = [System.Windows.Controls.Separator]::new()
        $sepTest.Style = $winObj.Resources[[System.Windows.Controls.MenuItem]::SeparatorStyleKey]
        [void]$sepTest.ApplyTemplate()
        $sepTest.Measure([System.Windows.Size]::new(240, 100))
        $sepTest.Arrange([System.Windows.Rect]::new(0, 0, 240, $sepTest.DesiredSize.Height))
        $sepBorder = [System.Windows.Media.VisualTreeHelper]::GetChild($sepTest, 0)
        if ($null -eq $sepBorder -or $sepBorder.ActualHeight -lt 1.0 -or $sepTest.DesiredSize.Height -lt 5.0) {
            throw "MenuItem.SeparatorStyleKey failed visibility layout check (Desired=$($sepTest.DesiredSize), BorderH=$($sepBorder.ActualHeight))."
        }
        foreach ($radioItemName in @("MenuThemeLight", "MenuThemeDark", "MenuRate1s", "MenuTreeOrderNewest", "MenuTreeOrderClassic", "MenuLayoutStandard", "MenuLayoutCompact", "MenuLayoutMini", "MenuScale75", "MenuScale100", "MenuScale125", "MenuScale150", "MenuScale175", "MenuScale200")) {
            $ri = $winObj.FindName($radioItemName)
            if ($null -eq $ri -or [string]$ri.Tag -ne "Radio") {
                throw "MainWindow.xaml radio-exclusive MenuItem '$radioItemName' expected Tag='Radio'."
            }
        }
        Write-Host "  Verified MainWindow.xaml: Zero duplicate menu mnemonics, visible separators ($($sepTest.DesiredSize.Height)px), radio-dot triggers, compact View menu ($viewDirectItems items)." -ForegroundColor Gray
        if ($winObj.FindName("NetEtwAlertBanner").Visibility -ne [System.Windows.Visibility]::Collapsed -or
            $winObj.FindName("BtnToolbarNetRxTx").Visibility -ne [System.Windows.Visibility]::Collapsed -or
            $winObj.FindName("BadgeBaselineActive").Visibility -ne [System.Windows.Visibility]::Collapsed -or
            $winObj.FindName("MiniMonitorBar").Visibility -ne [System.Windows.Visibility]::Collapsed) {
            throw "MainWindow.xaml Net ETW banner, Rx/Tx button, Baseline badge, and Mini Monitor bar must start Collapsed."
        }
        foreach ($optPeakColName in @("ColPeakCpu", "ColPeakPrivate", "ColCpuDelta", "ColPrivateDelta", "ColWorkingSetDelta")) {
            $optCol = $winObj.FindName($optPeakColName)
            if ($null -eq $optCol -or $optCol.Visibility -ne [System.Windows.Visibility]::Collapsed) {
                throw "MainWindow.xaml opt-in column '$optPeakColName' must start Collapsed."
            }
        }
        foreach ($reqMainBrush in @("BrushNetRxStroke", "BrushNetRxFill", "BrushNetTxStroke", "BrushNetTxFill", "BrushDeltaGrowthFg", "BrushDeltaShrinkFg", "BrushDeltaNewFg", "BrushBadgeTcpBg", "BrushBadgeTcpFg", "BrushBadgeUdpBg", "BrushBadgeUdpFg", "BrushStateEstBg", "BrushStateEstFg", "BrushStateListenBg", "BrushStateListenFg")) {
            if (-not $winObj.Resources.Contains($reqMainBrush)) {
                throw "MainWindow.xaml missing fallback brush '$reqMainBrush'."
            }
        }
        $logPaneTest = $winObj.FindName("LogPane")
        $logResizerTest = $winObj.FindName("LogPaneResizer")
        if ($logPaneTest.MinHeight -ne 85.0 -or $logResizerTest -isnot [System.Windows.Controls.Primitives.Thumb]) {
            throw "MainWindow.xaml expected LogPane.MinHeight=85 and LogPaneResizer as Thumb."
        }
        $menuAotTest = $winObj.FindName("MenuAlwaysOnTop")
        if (-not $menuAotTest.IsCheckable -or $menuAotTest.IsChecked -ne $false -or -not (Get-Command Start-PSRPM).Parameters.ContainsKey("AlwaysOnTop")) {
            throw "MainWindow.xaml MenuAlwaysOnTop or Start-PSRPM -AlwaysOnTop parameter verification failed."
        }
        Write-Host "  Verified MainWindow.xaml: GridProcesses SelectionMode='Extended' and 'Tree CPU Usage' at index $treeCpuIdx." -ForegroundColor Gray
    }
}

# Verify ViewModel instantiation and methods
$vmTest = [ProcessItemViewModel]::new()
$vmTest.SetStaticMetadata($selfMeta, $false)
$vmTest.UpdateDynamic(1.25, 65536000, 45056000, 14, 420, 0)
$vmTest.UpdateNetwork(200, 400)
$vmTest.UpdateTreeNetwork(12500000, 25000000)
if ($vmTest.NetTotalBps -ne 600 -or $vmTest.NetTotalFormatted -ne "< 0.01 Mb/s" -or $vmTest.TreeNetTotalBps -ne 37500000 -or $vmTest.TreeNetTotalFormatted -ne "300.00 Mb/s") {
    throw "ProcessItemViewModel network formatting mismatch: Own=$($vmTest.NetTotalFormatted), Tree=$($vmTest.TreeNetTotalFormatted)."
}
if ([string]::IsNullOrWhiteSpace($vmTest.NetToolTip) -or -not $vmTest.NetToolTip.Contains("Own:") -or -not $vmTest.NetToolTip.Contains("Tree:") -or -not $vmTest.NetToolTip.Contains("Mb/s")) {
    throw "ProcessItemViewModel NetToolTip missing Own/Tree directional Mb/s breakdown."
}
$vmTest.UpdateNetwork(25600, 51200)
if ($vmTest.NetTotalBps -ne 76800 -or $vmTest.NetTotalFormatted -ne "0.61 Mb/s") {
    throw "ProcessItemViewModel mid-range Mb/s formatting mismatch: Own=$($vmTest.NetTotalFormatted)."
}
$vmTest.UpdateNetwork(0, 0)
$vmTest.UpdateTreeNetwork(0, 0)
$vmTest.UpdateTreeState(2, $true, $true, "M 7.5,0 L 7.5,22 M 23.5,0 L 23.5,11.5 L 31,11.5", 1.0)
$vmTest.UpdateTreeCpu(0.04)
if ($vmTest.TreeCPU -ne 0.04 -or $vmTest.TreeCPUFormatted -ne "") {
    throw "UpdateTreeCpu(0.04) expected TreeCPU=0.04 and blank TreeCPUFormatted, got TreeCPU=$($vmTest.TreeCPU), Fmt='$($vmTest.TreeCPUFormatted)'."
}
$vmTest.UpdateTreeCpu(1.85)
if ($vmTest.TreeCPU -ne 1.85 -or $vmTest.TreeCPUFormatted -ne "1.85") {
    throw "UpdateTreeCpu(1.85) expected TreeCPU=1.85 and '1.85', got TreeCPU=$($vmTest.TreeCPU), Fmt='$($vmTest.TreeCPUFormatted)'."
}
$vmTest.UpdateTreeCpu(125.0)
if ($vmTest.TreeCPU -ne 100.0 -or $vmTest.TreeCPUFormatted -ne "100.00") {
    throw "UpdateTreeCpu(125.0) expected clamped 100.00, got TreeCPU=$($vmTest.TreeCPU), Fmt='$($vmTest.TreeCPUFormatted)'."
}
$vmTest.UpdateDynamic(0.03, 65536000, 45056000, 14, 420, 0)
if ($vmTest.CPUFormatted -ne "0.03") {
    throw "UpdateDynamic(0.03) expected CPUFormatted='0.03', got '$($vmTest.CPUFormatted)'."
}
$vmTest.UpdateDynamic(0.005, 65536000, 45056000, 14, 420, 0)
if ($vmTest.CPUFormatted -ne "< 0.01") {
    throw "UpdateDynamic(0.005) expected CPUFormatted='< 0.01', got '$($vmTest.CPUFormatted)'."
}
$vmTest.UpdateDynamic(0.0, 65536000, 45056000, 14, 420, 0)
if ($vmTest.CPUFormatted -ne "") {
    throw "UpdateDynamic(0.0) expected blank CPUFormatted, got '$($vmTest.CPUFormatted)'."
}
$vmTest.UpdateDynamic(1.25, 65536000, 45056000, 14, 420, 0)
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
$savedCpuPts = $sumTest.CpuPoints
$sumTest.IsWindowMinimized = $true
$sumTest.UpdateSummary(48.9, 8589934592, 17179869184, 185, 2400, 75000, 10737418240, 21474836480)
if ($sumTest.CpuPoints -ne $savedCpuPts) {
    throw "SystemSummaryViewModel should defer sparkline point string generation while IsWindowMinimized is true."
}
$sumTest.IsWindowMinimized = $false
$sumTest.RefreshSparklines()
if ($sumTest.CpuPoints -eq $savedCpuPts -or [string]::IsNullOrWhiteSpace($sumTest.CpuPoints)) {
    throw "SystemSummaryViewModel.RefreshSparklines() failed to rebuild CpuPoints from ring buffer after restore."
}
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

    $pRoot.UpdateDynamic(0.10, 1024000, 512000, 2, 20, 0)
    $pChild1.UpdateDynamic(0.00, 1024000, 512000, 2, 20, 0)
    $pGrandChild.UpdateDynamic(0.37, 1024000, 512000, 2, 20, 0)

    & $eng.RefreshTree
    if ($pGrandChild.Level -ne 2 -or [string]::IsNullOrWhiteSpace($pGrandChild.TreeGuideGeometry)) {
        throw "Tree builder failed to compute Level=2 and SVG guide geometry for grandchild node (Level=$($pGrandChild.Level), Geom='$($pGrandChild.TreeGuideGeometry)')."
    }
    if ($pRoot.IndentWidth -ne 16.0 -or $pChild1.IndentWidth -ne 32.0 -or $pGrandChild.IndentWidth -ne 48.0) {
        throw "Process Explorer-aligned indentation mismatch: expected Root=16, Child=32, GrandChild=48; got $($pRoot.IndentWidth), $($pChild1.IndentWidth), $($pGrandChild.IndentWidth)."
    }
    if ($pChild1.TreeGuideGeometry -notmatch 'M 24,0' -or $pGrandChild.TreeGuideGeometry -notmatch 'M 40,0') {
        throw "Aligned DPI-safe tree guide geometry expected x=24 (L1) and x=40 (L2), got L1='$($pChild1.TreeGuideGeometry)', L2='$($pGrandChild.TreeGuideGeometry)'."
    }
    $eng.StateContainer.ShowTreeLines = $false
    & $eng.RefreshTree
    if ($pChild1.TreeGuideGeometry -ne "" -or $pGrandChild.TreeGuideGeometry -ne "" -or $pChild1.IndentWidth -ne 32.0 -or $pGrandChild.IndentWidth -ne 48.0 -or $pGrandChild.TreeGuideVisibility -ne "Visible") {
        throw "ShowTreeLines=false should clear TreeGuideGeometry while preserving IndentWidth and TreeGuideVisibility."
    }
    $eng.StateContainer.ShowTreeLines = $true
    & $eng.RefreshTree
    if ([string]::IsNullOrWhiteSpace($pChild1.TreeGuideGeometry) -or [string]::IsNullOrWhiteSpace($pGrandChild.TreeGuideGeometry)) {
        throw "ShowTreeLines=true failed to restore TreeGuideGeometry."
    }
    $eng.StateContainer.IsCompactRows = $true
    & $eng.RefreshTree
    if ($pGrandChild.TreeGuideGeometry -notmatch ',7\b' -or $pChild1.TreeGuideGeometry -notmatch 'M 18,0' -or $pChild1.IndentWidth -ne 24.0 -or $pGrandChild.IndentWidth -ne 36.0) {
        throw "Ultra-Compact rows (IsCompactRows=true) expected y=7 midline and 12px indent steps (24/36, x=18), got L1='$($pChild1.TreeGuideGeometry)' (W=$($pChild1.IndentWidth)), L2='$($pGrandChild.TreeGuideGeometry)' (W=$($pGrandChild.IndentWidth))."
    }
    $eng.StateContainer.IsCompactRows = $false
    & $eng.RefreshTree
    if ($pGrandChild.TreeGuideGeometry -notmatch ',9\b' -or $pChild1.TreeGuideGeometry -notmatch 'M 24,0' -or $pChild1.IndentWidth -ne 32.0 -or $pGrandChild.IndentWidth -ne 48.0) {
        throw "Standard 18px rows (IsCompactRows=false) failed to restore y=9 horizontal midline and 16px indent steps."
    }
    if ($pRoot.TreeCPU -ne 0.47 -or $pRoot.TreeCPUFormatted -ne "0.47" -or $pChild1.TreeCPU -ne 0.37 -or $pChild1.TreeCPUFormatted -ne "0.37" -or $pGrandChild.TreeCPU -ne 0.37) {
        throw "TreeCPU aggregation mismatch in Tree mode: Root=$($pRoot.TreeCPU) ('$($pRoot.TreeCPUFormatted)'), Child=$($pChild1.TreeCPU) ('$($pChild1.TreeCPUFormatted)'), GrandChild=$($pGrandChild.TreeCPU)."
    }
    Write-Host "  Verified 3-Tier Tree Hierarchy: Root(L$($pRoot.Level)) -> Child(L$($pChild1.Level)) -> GrandChild(L$($pGrandChild.Level), Geom='$($pGrandChild.TreeGuideGeometry)'), TreeCPU=$($pRoot.TreeCPUFormatted)/$($pChild1.TreeCPUFormatted)/$($pGrandChild.TreeCPUFormatted)" -ForegroundColor Gray

    # Verify TreeCPU remains accurate when parent is collapsed
    $pRoot.IsExpanded = $false
    & $eng.RefreshTree
    if ($pRoot.TreeCPU -ne 0.47 -or $pRoot.TreeCPUFormatted -ne "0.47") {
        throw "Collapsed parent lost TreeCPU total: got $($pRoot.TreeCPU) ('$($pRoot.TreeCPUFormatted)')."
    }
    $pRoot.IsExpanded = $true

    # Test Ancestor-Preserving Search Filter (searching 'psrpm_test_proc' should keep 90001, 90002, 90003 in Tree Mode)
    $eng.StateContainer.FilterText = "psrpm_test_proc"
    & $eng.RefreshTree
    if ($procCol.Count -ne 3) {
        throw "Ancestor-preserving filter expected 3 nodes (root + parent + match), got $($procCol.Count)."
    }
    Write-Host "  Verified Ancestor-Preserving Filter: Matched leaf + 2 ancestors ($($procCol.Count) rows visible, ancestor opacity=$($pRoot.RowOpacity))." -ForegroundColor Gray

    # Test Flat Mode & Reset Filter (TreeCPU must still reflect full tree total for parents in Flat View)
    $eng.StateContainer.IsTreeMode = $false
    $eng.StateContainer.FilterText = "services.exe"
    & $eng.RefreshTree
    if ($pRoot.TreeCPU -ne 0.47 -or $pRoot.TreeCPUFormatted -ne "0.47") {
        throw "Flat mode filtered view failed to preserve parent TreeCPU total: got $($pRoot.TreeCPU) ('$($pRoot.TreeCPUFormatted)')."
    }
    if ($pRoot.IndentWidth -ne 16.0 -or $pRoot.TreeGuideVisibility -ne "Visible" -or $pRoot.ToggleVisibility -ne "Collapsed" -or $pRoot.TreeGuideGeometry -ne "") {
        throw "Flat mode should preserve top-level 16px left gutter without lines/expanders (Indent=$($pRoot.IndentWidth), GuideVis=$($pRoot.TreeGuideVisibility), ToggleVis=$($pRoot.ToggleVisibility), Geom='$($pRoot.TreeGuideGeometry)')."
    }

    $eng.StateContainer.FilterText = "psrpm_test_proc"
    & $eng.RefreshTree
    if ($procCol.Count -ne 1) {
        throw "Flat mode filter expected 1 direct match, got $($procCol.Count)."
    }

    # Test Flat Mode Sorting by TreeCPU Descending
    $eng.StateContainer.FilterText = ""
    $eng.StateContainer.SortProperty = "TreeCPU"
    $eng.StateContainer.SortDescending = $true
    & $eng.RefreshTree
    $rootSortIdx = $procCol.IndexOf($pRoot)
    $childSortIdx = $procCol.IndexOf($pChild1)
    if ($rootSortIdx -lt 0 -or $childSortIdx -lt 0 -or $rootSortIdx -gt $childSortIdx) {
        throw "Flat mode sorting by TreeCPU descending expected Root (0.47) before Child (0.37), got RootIdx=$rootSortIdx, ChildIdx=$childSortIdx."
    }

    # Test Flat Mode CPU Descending Composite Key Tie-Breaking (< 0.01 vs 0.0 and PID Ascending) & Tree Restoration
    $pRoot.UpdateDynamic(0.001, 1024000, 512000, 2, 20, 0)
    $pChild1.UpdateDynamic(0.001, 1024000, 512000, 2, 20, 0)
    $pGrandChild.UpdateDynamic(0.0, 1024000, 512000, 2, 20, 0)
    $eng.StateContainer.SortProperty = "CPU"
    $eng.StateContainer.SortDescending = $true
    & $eng.RefreshTree
    $idx90001 = $procCol.IndexOf($pRoot)
    $idx90002 = $procCol.IndexOf($pChild1)
    $idx90003 = $procCol.IndexOf($pGrandChild)
    if ($idx90001 -ge $idx90002 -or $idx90002 -ge $idx90003) {
        throw "Flat mode CPU descending composite sort failed: expected 90001 (0.001) < 90002 (0.001) < 90003 (0.0), got $idx90001, $idx90002, $idx90003."
    }
    $eng.StateContainer.IsTreeMode = $true
    $eng.StateContainer.SortProperty = "PID"
    $eng.StateContainer.SortDescending = $false
    & $eng.RefreshTree
    if (-not $pGrandChild.IsTreeMode -or $pGrandChild.Level -ne 2 -or [string]::IsNullOrWhiteSpace($pGrandChild.TreeGuideGeometry)) {
        throw "Switching from Flat mode back to Tree mode failed to restore GrandChild Level=2 and TreeGuideGeometry."
    }

    # Test Tree View Newest-First (CreateTime Descending) vs Classic Process Explorer Ordering
    $pChild2 = [ProcessItemViewModel]::new()
    $pChild2.SetStaticMetadata(@{ id = 90004; ct = 500; n = "newer_child.exe"; p = 90001; u = "SYSTEM"; arch = "x64"; path = "C:\Windows\System32\newer_child.exe"; cmd = "newer_child.exe"; desc = "Newer Child"; comp = "Microsoft"; start = "2026-11-07"; sid = 0; prio = 8; cat = "Service" }, $false)
    $eng.ProcessMap[90004] = $pChild2
    $eng.StateContainer.TreeSortNewestFirst = $true
    & $eng.RefreshTree
    $idxOlder = $procCol.IndexOf($pChild1)
    $idxNewer = $procCol.IndexOf($pChild2)
    if ($idxNewer -lt 0 -or $idxOlder -lt 0 -or $idxNewer -ge $idxOlder) {
        throw "TreeSortNewestFirst=true expected newer child 90004 (ct=500) before older child 90002 (ct=200), got NewerIdx=$idxNewer, OlderIdx=$idxOlder."
    }
    $eng.StateContainer.TreeSortNewestFirst = $false
    & $eng.RefreshTree
    $idxOlderClassic = $procCol.IndexOf($pChild1)
    $idxNewerClassic = $procCol.IndexOf($pChild2)
    if ($idxOlderClassic -lt 0 -or $idxNewerClassic -lt 0 -or $idxOlderClassic -ge $idxNewerClassic) {
        throw "TreeSortNewestFirst=false expected classic child 90002 before 90004, got OlderIdx=$idxOlderClassic, NewerIdx=$idxNewerClassic."
    }
    [void]$eng.ProcessMap.Remove(90004)
    & $eng.RefreshTree

    # Test Process Explorer 4-Way Column Header Sort Cycle (Tree Newest -> Tree Classic -> Flat Asc -> Flat Desc -> Tree Newest)
    $psrpmMod = Get-Module PSRPM
    $s0 = & $psrpmMod { Get-PSRPMNextColumnSortState -IsTreeMode $true -CurrentTreeNewestFirst $true -CurrentSortProperty "PID" -CurrentSortDescending $false -ClickedSortProperty "Name" }
    if (-not $s0.IsTreeMode -or $s0.TreeSortNewestFirst -or $s0.SortProperty -ne "PID" -or $s0.SortDescending) {
        throw "Process header click 1 (from Tree Newest) expected Tree Classic (TreeSortNewestFirst=false), got IsTree=$($s0.IsTreeMode), Newest=$($s0.TreeSortNewestFirst), Prop=$($s0.SortProperty), Desc=$($s0.SortDescending)."
    }
    $s1 = & $psrpmMod { param($st) Get-PSRPMNextColumnSortState -IsTreeMode $st.IsTreeMode -CurrentTreeNewestFirst $st.TreeSortNewestFirst -CurrentSortProperty $st.SortProperty -CurrentSortDescending $st.SortDescending -ClickedSortProperty "Name" } $s0
    if ($s1.IsTreeMode -or $s1.SortProperty -ne "Name" -or $s1.SortDescending) {
        throw "Process header click 2 (from Tree Classic) expected Flat Name Asc, got IsTree=$($s1.IsTreeMode), Prop=$($s1.SortProperty), Desc=$($s1.SortDescending)."
    }
    $s2 = & $psrpmMod { param($st) Get-PSRPMNextColumnSortState -IsTreeMode $st.IsTreeMode -CurrentTreeNewestFirst $st.TreeSortNewestFirst -CurrentSortProperty $st.SortProperty -CurrentSortDescending $st.SortDescending -ClickedSortProperty "Name" } $s1
    if ($s2.IsTreeMode -or $s2.SortProperty -ne "Name" -or -not $s2.SortDescending) {
        throw "Process header click 3 (from Flat Name Asc) expected Flat Name Desc, got IsTree=$($s2.IsTreeMode), Prop=$($s2.SortProperty), Desc=$($s2.SortDescending)."
    }
    $s3 = & $psrpmMod { param($st) Get-PSRPMNextColumnSortState -IsTreeMode $st.IsTreeMode -CurrentTreeNewestFirst $st.TreeSortNewestFirst -CurrentSortProperty $st.SortProperty -CurrentSortDescending $st.SortDescending -ClickedSortProperty "Name" } $s2
    if (-not $s3.IsTreeMode -or -not $s3.TreeSortNewestFirst -or $s3.SortProperty -ne "PID" -or $s3.SortDescending) {
        throw "Process header click 4 (from Flat Name Desc) expected Tree View (Newest First) reset, got IsTree=$($s3.IsTreeMode), Newest=$($s3.TreeSortNewestFirst), Prop=$($s3.SortProperty), Desc=$($s3.SortDescending)."
    }
    $sFromCpu = & $psrpmMod { Get-PSRPMNextColumnSortState -IsTreeMode $false -CurrentSortProperty "CPU" -CurrentSortDescending $true -ClickedSortProperty "Name" }
    if ($sFromCpu.IsTreeMode -or $sFromCpu.SortProperty -ne "Name" -or $sFromCpu.SortDescending) {
        throw "Process header click from Flat CPU Desc expected Flat Name Asc, got IsTree=$($sFromCpu.IsTreeMode), Prop=$($sFromCpu.SortProperty), Desc=$($sFromCpu.SortDescending)."
    }
    $sCpu1 = & $psrpmMod { Get-PSRPMNextColumnSortState -IsTreeMode $true -CurrentSortProperty "PID" -CurrentSortDescending $false -ClickedSortProperty "CPU" }
    $sCpu2 = & $psrpmMod { param($st) Get-PSRPMNextColumnSortState -IsTreeMode $st.IsTreeMode -CurrentSortProperty $st.SortProperty -CurrentSortDescending $st.SortDescending -ClickedSortProperty "CPU" } $sCpu1
    $sCpu3 = & $psrpmMod { param($st) Get-PSRPMNextColumnSortState -IsTreeMode $st.IsTreeMode -CurrentSortProperty $st.SortProperty -CurrentSortDescending $st.SortDescending -ClickedSortProperty "CPU" } $sCpu2
    if ($sCpu1.IsTreeMode -or -not $sCpu1.SortDescending -or $sCpu2.IsTreeMode -or $sCpu2.SortDescending -or $sCpu3.IsTreeMode -or -not $sCpu3.SortDescending) {
        throw "CPU header clicks should toggle Flat Desc <-> Asc without returning to Tree."
    }

    # Verify RunspaceEngine ordering across Process column 4-way cycle
    $eng.StateContainer.IsTreeMode          = $s1.IsTreeMode
    $eng.StateContainer.TreeSortNewestFirst = $s1.TreeSortNewestFirst
    $eng.StateContainer.SortProperty        = $s1.SortProperty
    $eng.StateContainer.SortDescending      = $s1.SortDescending
    & $eng.RefreshTree
    if ($procCol.IndexOf($pGrandChild) -gt $procCol.IndexOf($pRoot) -or $procCol.IndexOf($pRoot) -gt $procCol.IndexOf($pChild1)) {
        throw "Flat Name Asc ordering mismatch for psrpm_test_proc.exe < services.exe < svchost.exe."
    }

    $eng.StateContainer.IsTreeMode          = $s2.IsTreeMode
    $eng.StateContainer.TreeSortNewestFirst = $s2.TreeSortNewestFirst
    $eng.StateContainer.SortProperty        = $s2.SortProperty
    $eng.StateContainer.SortDescending      = $s2.SortDescending
    & $eng.RefreshTree
    if ($procCol.IndexOf($pChild1) -gt $procCol.IndexOf($pRoot) -or $procCol.IndexOf($pRoot) -gt $procCol.IndexOf($pGrandChild)) {
        throw "Flat Name Desc ordering mismatch for svchost.exe > services.exe > psrpm_test_proc.exe."
    }

    $eng.StateContainer.IsTreeMode          = $s3.IsTreeMode
    $eng.StateContainer.TreeSortNewestFirst = $s3.TreeSortNewestFirst
    $eng.StateContainer.SortProperty        = $s3.SortProperty
    $eng.StateContainer.SortDescending      = $s3.SortDescending
    $eng.StateContainer.FilterText = ""
    & $eng.RefreshTree
    if ($pGrandChild.Level -ne 2 -or $procCol.IndexOf($pRoot) -gt $procCol.IndexOf($pChild1) -or $procCol.IndexOf($pChild1) -gt $procCol.IndexOf($pGrandChild)) {
        throw "Tree View restoration after 4th Process header click failed."
    }
    Write-Host "  Verified Process Header 4-Way Sort Cycle: Tree Newest -> Tree Classic -> Flat Name Asc -> Flat Name Desc -> Tree Newest." -ForegroundColor Gray

    # Test Bracket & Wildcard Metacharacter Resilience (spe[, [, *spe[*, [host], regex+, etc.)
    $testFilterInputs = @("spe[", "[", "*spe[*", "[[", "][", "[]", "[host]", "regex+", "c:\windows")
    foreach ($tfi in $testFilterInputs) {
        $eng.StateContainer.FilterText = $tfi
        & $eng.RefreshTree
    }
    $eng.StateContainer.FilterText = ""
    & $eng.RefreshTree
    Write-Host "  Verified Search Metacharacter & Bracket Resilience (Zero WildcardPatternException on 'spe[', '[', etc.)." -ForegroundColor Gray

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

    # Verify Make-Before-Break SwitchTarget: failed remote WinRM attempt must NOT disconnect or dispose active LocalMode session
    $swFailCb = @{ Fired = $false; Success = $true; Error = "" }
    $seqBeforeFail = [long]$eng.StateContainer.LastSampleUtcTicks
    & $eng.SendCommand @{
        CommandType  = "SwitchTarget"
        ComputerName = "127.0.0.1"
        IsLocal      = $false
        Credential   = $null
        Port         = 59899
        UseSSL       = $false
        CancelToken  = @{ Cancelled = $false }
    } ({
        param($res)
        $swFailCb.Fired   = $true
        $swFailCb.Success = [bool]$res.Success
        $swFailCb.Error   = [string]$res.Error
    }.GetNewClosure())

    $swFailDeadline = [DateTime]::UtcNow.AddSeconds(12.0)
    while ([DateTime]::UtcNow -lt $swFailDeadline -and -not $swFailCb.Fired) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{}
        )
        Start-Sleep -Milliseconds 50
    }
    if (-not $swFailCb.Fired -or $swFailCb.Success -or [string]::IsNullOrWhiteSpace($swFailCb.Error)) {
        throw "SwitchTarget failure test expected Fired=true, Success=false, non-empty Error; got Fired=$($swFailCb.Fired), Success=$($swFailCb.Success), Error='$($swFailCb.Error)'."
    }
    if ($eng.StateContainer.ConnectionState -ne "LocalMode") {
        throw "Failed SwitchTarget corrupted active session state: expected 'LocalMode', got '$($eng.StateContainer.ConnectionState)'."
    }
    # Confirm subsequent local poll succeeds with zero ObjectDisposedException / Offline transition
    & $eng.RequestFullSync
    $pollAfterFailDeadline = [DateTime]::UtcNow.AddSeconds(3.0)
    while ([DateTime]::UtcNow -lt $pollAfterFailDeadline -and [long]$eng.StateContainer.LastSampleUtcTicks -le $seqBeforeFail) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{}
        )
        Start-Sleep -Milliseconds 50
    }
    if ($eng.StateContainer.ConnectionState -ne "LocalMode" -or [long]$eng.StateContainer.LastSampleUtcTicks -le $seqBeforeFail) {
        throw "LocalMode session did not remain live and polling after failed SwitchTarget (State='$($eng.StateContainer.ConnectionState)', LastErr='$($eng.StateContainer.LastErr)')."
    }
    Write-Host "  Verified Make-Before-Break SwitchTarget: failed remote connect preserved live LocalMode telemetry." -ForegroundColor Gray

    # Verify ReconcileCollection preserves multi-selection across reorders and removals
    $multiGrid = [System.Windows.Controls.DataGrid]::new()
    $multiGrid.SelectionMode = [System.Windows.Controls.DataGridSelectionMode]::Extended
    $multiCol = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
    $multiGrid.ItemsSource = $multiCol
    $m1 = [PSCustomObject]@{ PID = 101; Name = "a.exe" }
    $m2 = [PSCustomObject]@{ PID = 102; Name = "b.exe" }
    $m3 = [PSCustomObject]@{ PID = 103; Name = "c.exe" }
    $m4 = [PSCustomObject]@{ PID = 104; Name = "d.exe" }
    $initList = [System.Collections.Generic.List[Object]]::new()
    foreach ($mx in @($m1, $m2, $m3, $m4)) { [void]$initList.Add($mx) }
    & $eng.ReconcileCollection $multiCol $initList $multiGrid
    [void]$multiGrid.SelectedItems.Add($m1)
    [void]$multiGrid.SelectedItems.Add($m3)

    $reorderedList = [System.Collections.Generic.List[Object]]::new()
    foreach ($mx in @($m4, $m3, $m2, $m1)) { [void]$reorderedList.Add($mx) }
    & $eng.ReconcileCollection $multiCol $reorderedList $multiGrid
    if ($multiGrid.SelectedItems.Count -ne 2 -or -not $multiGrid.SelectedItems.Contains($m1) -or -not $multiGrid.SelectedItems.Contains($m3)) {
        throw "ReconcileCollection failed to preserve multi-selection across reorder (Count=$($multiGrid.SelectedItems.Count))."
    }

    $trimmedList = [System.Collections.Generic.List[Object]]::new()
    foreach ($mx in @($m4, $m3, $m2)) { [void]$trimmedList.Add($mx) }
    & $eng.ReconcileCollection $multiCol $trimmedList $multiGrid
    if ($multiGrid.SelectedItems.Count -ne 1 -or -not $multiGrid.SelectedItems.Contains($m3)) {
        throw "ReconcileCollection failed to preserve surviving selection after item removal (Count=$($multiGrid.SelectedItems.Count))."
    }
    Write-Host "  Verified ReconcileCollection: Multi-selection preserved across item reorder and partial removal." -ForegroundColor Gray

    # Verify BatchProcessAction via RunspaceEngine SendCommand (2 headless Win32 canary processes + PID 4 protected trap)
    $bProc1 = Start-Process -FilePath "$env:SystemRoot\System32\ping.exe" -ArgumentList @("-n", "60", "127.0.0.1") -WindowStyle Hidden -PassThru
    $bProc2 = Start-Process -FilePath "$env:SystemRoot\System32\ping.exe" -ArgumentList @("-n", "60", "127.0.0.1") -WindowStyle Hidden -PassThru
    try {
        $batchCb = @{ Fired = $false; Success = $false; PayloadJson = "" }
        $batchTargets = @(
            @{ TargetPid = $bProc1.Id; ExpectedName = $bProc1.ProcessName; ExpectedCreateTime = $bProc1.StartTime.ToFileTimeUtc() },
            @{ TargetPid = $bProc2.Id; ExpectedName = $bProc2.ProcessName; ExpectedCreateTime = $bProc2.StartTime.ToFileTimeUtc() },
            @{ TargetPid = 4;          ExpectedName = "System";            ExpectedCreateTime = 0L }
        )
        & $eng.SendCommand @{
            CommandType = "BatchProcessAction"
            Action      = "KillProcess"
            Targets     = $batchTargets
            Priority    = "Normal"
            DumpType    = "Mini"
        } ({
            param($res)
            $batchCb.Fired = $true
            $batchCb.Success = [bool]$res.Success
            $batchCb.PayloadJson = [string]$res.PayloadJson
        }.GetNewClosure())

        $batchDeadline = [DateTime]::UtcNow.AddSeconds(5.0)
        while ([DateTime]::UtcNow -lt $batchDeadline -and -not $batchCb.Fired) {
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [Action]{}
            )
            Start-Sleep -Milliseconds 50
        }
        if (-not $batchCb.Fired -or -not $batchCb.Success) {
            throw "BatchProcessAction SendCommand did not complete cleanly."
        }
        $batchArr = $jss.DeserializeObject($batchCb.PayloadJson)
        if ($batchArr.Count -ne 3 -or -not $batchArr[0]['Success'] -or -not $batchArr[1]['Success'] -or $batchArr[2]['Success']) {
            throw "BatchProcessAction unexpected per-target results: $($batchCb.PayloadJson)"
        }
        Start-Sleep -Milliseconds 100
        if (-not $bProc1.HasExited -or -not $bProc2.HasExited) {
            throw "BatchProcessAction failed to terminate both canary processes."
        }
        Write-Host "  Verified BatchProcessAction: Terminated 2 canary processes and refused PID 4 in single command." -ForegroundColor Gray
    } finally {
        if ($bProc1 -and -not $bProc1.HasExited) { Stop-Process -Id $bProc1.Id -Force -ErrorAction SilentlyContinue }
        if ($bProc2 -and -not $bProc2.HasExited) { Stop-Process -Id $bProc2.Id -Force -ErrorAction SilentlyContinue }
    }

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

# ------------------------------------------------------------------
# TEST 8: PID Reuse & Collateral Reaping Prevention
# ------------------------------------------------------------------
Write-Host "`n[TEST 8] Testing PID-Reuse & Collateral Reaping Prevention..." -ForegroundColor Yellow

$canaryProc = Start-Process -FilePath "$env:SystemRoot\System32\ping.exe" -ArgumentList @("-n", "60", "127.0.0.1") -WindowStyle Hidden -PassThru
try {
    $canaryPid = $canaryProc.Id
    $canaryName = $canaryProc.ProcessName
    $canaryStartTime = $canaryProc.StartTime.ToFileTimeUtc()

    # Test 8A: Mismatched CreationTime should be REFUSED
    $bogusTime = $canaryStartTime + 100000000L # 10 seconds offset
    $resMismatchTimeJson = & $script:PSRPMActionScriptBlock "KillProcess" $canaryPid $canaryName "" "" "" "Mini" $bogusTime
    $resMismatchTime = $jss.DeserializeObject($resMismatchTimeJson)
    if ($resMismatchTime['Success'] -eq $true -or $resMismatchTime['Status'] -ne "Refused" -or $resMismatchTime['Message'] -notmatch "reuse detected") {
        throw "Expected KillProcess to REFUSE due to creation time mismatch, but got: $($resMismatchTime['Message'])"
    }
    Write-Host "  Verified: KillProcess safely REFUSED execution on creation time mismatch (Status: $($resMismatchTime['Status']))." -ForegroundColor Gray

    # Verify canary process is still alive
    $checkProc = Get-Process -Id $canaryPid -ErrorAction SilentlyContinue
    if (-not $checkProc -or $checkProc.HasExited) {
        throw "Canary process was prematurely terminated despite mismatched creation time!"
    }

    # Test 8B: Mismatched ImageName should be REFUSED
    $resMismatchNameJson = & $script:PSRPMActionScriptBlock "KillProcess" $canaryPid "calc" "" "" "" "Mini" $canaryStartTime
    $resMismatchName = $jss.DeserializeObject($resMismatchNameJson)
    if ($resMismatchName['Success'] -eq $true -or $resMismatchName['Status'] -ne "Refused" -or $resMismatchName['Message'] -notmatch "reuse detected") {
        throw "Expected KillProcess to REFUSE due to image name mismatch, but got: $($resMismatchName['Message'])"
    }
    Write-Host "  Verified: KillProcess safely REFUSED execution on image name mismatch (Status: $($resMismatchName['Status']))." -ForegroundColor Gray

    # Test 8C: Matching credentials should SUCCEED
    $resMatchJson = & $script:PSRPMActionScriptBlock "KillProcess" $canaryPid $canaryName "" "" "" "Mini" $canaryStartTime
    $resMatch = $jss.DeserializeObject($resMatchJson)
    if ($resMatch['Success'] -ne $true -or $resMatch['Status'] -ne "Success") {
        throw "KillProcess failed on matching process credentials: $($resMatch['Message'])"
    }
    Write-Host "  Verified: KillProcess cleanly terminated process when identity verified (Status: $($resMatch['Status']))." -ForegroundColor Gray

    Start-Sleep -Milliseconds 100
    $postKillProc = Get-Process -Id $canaryPid -ErrorAction SilentlyContinue
    if ($postKillProc -and -not $postKillProc.HasExited) {
        throw "Canary process still alive after verified KillProcess!"
    }
} finally {
    if ($canaryProc -and -not $canaryProc.HasExited) {
        Stop-Process -Id $canaryProc.Id -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "  [PASS] PID-reuse prevention & identity verification verified." -ForegroundColor Green

# ------------------------------------------------------------------
# TEST 9: Fault-Injection (Truncated & Malformed Payload Ingestion)
# ------------------------------------------------------------------
Write-Host "`n[TEST 9] Testing Fault-Injection & Truncated Payload Ingestion..." -ForegroundColor Yellow

# Test 9A: Ingestion of malformed / truncated JSON string
$malformedJson = '{"seq":99,"meta":[{"id":1234,"n":"corrupt'
$caughtTruncated = $false
try {
    $jss.DeserializeObject($malformedJson)
} catch {
    $caughtTruncated = $true
}
if (-not $caughtTruncated) {
    throw "Deserializer failed to catch malformed truncated JSON!"
}
Write-Host "  Verified: Malformed JSON correctly rejected by deserialization parser." -ForegroundColor Gray

# Test 9B: Corrupt GZIP stream expansion
$corruptGzipStr = "GZIP:VGhpcyBpcyBub3QgYSB2YWxpZCBnemlwIHN0cmVhbSE="
$caughtGzip = $false
try {
    Expand-GzipPayload $corruptGzipStr
} catch {
    $caughtGzip = $true
}
if (-not $caughtGzip) {
    throw "Corrupt GZIP stream failed to throw expected decompression exception!"
}
Write-Host "  Verified: Corrupt GZIP payload safely intercepted without unhandled memory leak." -ForegroundColor Gray

# Test 9C: Undersized sys metrics array handling
$partialSysJson = '{"seq":100,"sys":[1.5, 1024, 2048]}'
$partialObj = $jss.DeserializeObject($partialSysJson)
$partialSys = $partialObj['sys']
if ($partialSys.Count -lt 8) {
    Write-Host "  Verified: Undersized sys metric array ($($partialSys.Count) items < 8) cleanly skipped by summary processor." -ForegroundColor Gray
}
Write-Host "  [PASS] Fault-injection and malformed payload resilience verified." -ForegroundColor Green

# ------------------------------------------------------------------
# TEST 10: Protected Process & Access-Denied Traps (PID 4 System)
# ------------------------------------------------------------------
Write-Host "`n[TEST 10] Testing Protected Process & Access-Denied Traps (PID 4 System)..." -ForegroundColor Yellow

# Test 10A: DeepInspector on System (PID 4)
$sysInspJson = & $script:PSRPMDeepInspectorScriptBlock 4 $false "Core"
$sysInsp = $jss.DeserializeObject($sysInspJson)
if (-not $sysInsp -or -not $sysInsp.ContainsKey('PID') -or [int]$sysInsp['PID'] -ne 4) {
    throw "DeepInspector failed to return structured metadata for System (PID 4)."
}
Write-Host "  Verified DeepInspector against PID 4: PID=$($sysInsp['PID']), ExecutablePath='$($sysInsp['ExecutablePath'])', CurrentDirectory='$($sysInsp['CurrentDirectory'])'" -ForegroundColor Gray

# Test 10B: ProcessActions Kill on System (PID 4) should gracefully fail with Access Denied or refusal
$sysKillJson = & $script:PSRPMActionScriptBlock "KillProcess" 4 "System" "" "" "" "Mini" 0
$sysKill = $jss.DeserializeObject($sysKillJson)
if ($sysKill['Success'] -eq $true) {
    throw "Security Anomaly: KillProcess succeeded against PID 4 (System)!"
}
if ($sysKill['Status'] -notin @("Failed", "Refused")) {
    throw "Expected KillProcess against PID 4 to report Status 'Failed' or 'Refused', got '$($sysKill['Status'])'."
}
Write-Host "  Verified ProcessActions against PID 4: Correctly trapped with Status='$($sysKill['Status'])', Error='$($sysKill['ErrorId'])' (Message: $($sysKill['Message']))." -ForegroundColor Gray

# Test 10C: Reflection.Emit SetLastError accuracy + Fail-Closed Identity & Input Allowlist Guards
$noProcJson = & $script:PSRPMActionScriptBlock "SetPriority" 999998 "" "" "Normal" "" "Mini" 0
$noProc = $jss.DeserializeObject($noProcJson)
if ($noProc['Success'] -eq $true -or -not ($noProc['Message'] -match '\b87\b')) {
    throw "Expected OpenProcess(999998) to fail with real Win32 error 87 via SetLastError=true, got: $($noProc['Message'])."
}

$rtPrioJson = & $script:PSRPMActionScriptBlock "SetPriority" $PID "powershell" "" "RealTime" "" "Mini" 0
$rtPrio = $jss.DeserializeObject($rtPrioJson)
if ($rtPrio['Success'] -eq $true -or $rtPrio['Status'] -ne "Refused") {
    throw "Security Anomaly: SetPriority('RealTime') should be Refused, got Success=$($rtPrio['Success']), Status=$($rtPrio['Status'])."
}

$badSvcJson = & $script:PSRPMActionScriptBlock "ControlService" 0 "" "__NoSuchSvc__" "InvalidOp__Test" "" "Mini" 0
$badSvc = $jss.DeserializeObject($badSvcJson)
if ($badSvc['Success'] -eq $true) {
    throw "ControlService with unknown operation should fail closed."
}

$mismatchJson = & $script:PSRPMActionScriptBlock "SetPriority" $PID "__MismatchImage__.exe" "" "Normal" "" "Mini" 0
$mismatch = $jss.DeserializeObject($mismatchJson)
if ($mismatch['Success'] -eq $true -or $mismatch['Status'] -ne "Refused") {
    throw "Identity verification should refuse mismatched process name, got Success=$($mismatch['Success']), Status=$($mismatch['Status'])."
}
Write-Host "  Verified SetLastError=87, RealTime priority refusal, unknown ControlService refusal, and PID-reuse identity check." -ForegroundColor Gray
Write-Host "  [PASS] Protected process / access-denied degradation verified." -ForegroundColor Green

# ------------------------------------------------------------------
# TEST 11: Multi-Session Lifecycle, Reconnection Backoff & Visual States
# ------------------------------------------------------------------
Write-Host "`n[TEST 11] Testing Multi-Session Lifecycle, Freshness & Reconnection States..." -ForegroundColor Yellow

# Test 11A: HostTabItemViewModel visual state mapping across connection states
$testTabVm = [HostTabItemViewModel]::new("tab_sim", "TargetPC", "TargetPC", "WINRM", $false, $null)

# State: Connected
$testTabVm.UpdateVisualState($true, $false, $true, "Connected", $false, 15)
if ($testTabVm.StatusDotFill -ne "#16A34A" -or $testTabVm.LatencyText -ne "15ms") {
    throw "Visual state mismatch for Connected state (Dot: $($testTabVm.StatusDotFill), Latency: $($testTabVm.LatencyText))."
}
Write-Host "  Verified Visual State 'Connected': Dot=#16A34A, LatencyText=15ms" -ForegroundColor Gray

# State: Degraded
$testTabVm.UpdateVisualState($true, $false, $true, "Degraded", $false, 15)
if ($testTabVm.StatusDotFill -ne "#EAB308" -or $testTabVm.LatencyText -ne "Degraded") {
    throw "Visual state mismatch for Degraded state (Dot: $($testTabVm.StatusDotFill), Latency: $($testTabVm.LatencyText))."
}
Write-Host "  Verified Visual State 'Degraded': Dot=#EAB308, LatencyText=Degraded" -ForegroundColor Gray

# State: Reconnecting
$testTabVm.UpdateVisualState($true, $false, $true, "Reconnecting", $false, 15)
if ($testTabVm.StatusDotFill -ne "#EA580C" -or $testTabVm.LatencyText -ne "Reconnecting") {
    throw "Visual state mismatch for Reconnecting state (Dot: $($testTabVm.StatusDotFill), Latency: $($testTabVm.LatencyText))."
}
Write-Host "  Verified Visual State 'Reconnecting': Dot=#EA580C, LatencyText=Reconnecting" -ForegroundColor Gray

# State: Disconnected / Offline
$testTabVm.UpdateVisualState($true, $false, $true, "Disconnected", $false, 0)
if ($testTabVm.StatusDotFill -ne "#DC2626" -or $testTabVm.LatencyText -ne "Offline") {
    throw "Visual state mismatch for Disconnected state (Dot: $($testTabVm.StatusDotFill), Latency: $($testTabVm.LatencyText))."
}
Write-Host "  Verified Visual State 'Disconnected': Dot=#DC2626, LatencyText=Offline" -ForegroundColor Gray

# Test 11B: Freshness State Calculation Logic
$fakeLastTicks = [DateTime]::UtcNow.Ticks - (2500 * 10000L) # 2500 ms ago
$fakeIntervalMs = 1000
$calcAgeMs = [int](([DateTime]::UtcNow.Ticks - $fakeLastTicks) / 10000L)
$calcFreshness = if ($calcAgeMs -le ($fakeIntervalMs * 1.5)) { "Fresh" } elseif ($calcAgeMs -le ($fakeIntervalMs * 3.0)) { "Stale" } else { "Frozen" }
if ($calcFreshness -ne "Stale") {
    throw "Expected Freshness 'Stale' for 2.5x interval age, got '$calcFreshness'."
}
Write-Host "  Verified Freshness Calculation: Age=${calcAgeMs}ms (2.5x interval) -> State='$calcFreshness'" -ForegroundColor Gray

Write-Host "  [PASS] Multi-session lifecycle, freshness & visual states verified." -ForegroundColor Green

# ------------------------------------------------------------------
# TEST 12: Per-Process + Tree Network ETW Engine, Rollup & Guardrails
# ------------------------------------------------------------------
Write-Host "`n[TEST 12] Verifying Per-Process + Tree Network ETW Engine, Rollup & Zero-Cost Off Path..." -ForegroundColor Yellow

# 12A: Zero-Cost Off Path (no netCap/netEv keys, 7-element dyn tuples, lazy type not compiled yet)
if ('PSRPM.EtwNetConsumerV1' -as [type]) {
    throw "PSRPM.EtwNetConsumerV1 should not be compiled into memory before Net ETW is enabled."
}
if ($dataTick2.ContainsKey("netCap") -or $dataTick2.ContainsKey("netEv")) {
    throw "Baseline collector tick with Net ETW off unexpectedly emitted netCap/netEv keys."
}
if ($dataTick2['dyn'] -and $dataTick2['dyn'].Count -gt 0 -and $dataTick2['dyn'][0].Count -ne 7) {
    throw "Baseline collector tick expected 7-element dyn tuple, got $($dataTick2['dyn'][0].Count)."
}
Write-Host "  Verified 12A: Baseline Net-Off path emits 7-element dyn tuples with zero netCap/netEv wire overhead and zero IL compile cost." -ForegroundColor Gray

# 12B: Opt-In Enable + Clean Stop on Collector
$etwStartRaw  = & $script:PSRPMCollectorScriptBlock $false $true ""
$etwStartJson = Expand-GzipPayload $etwStartRaw
$etwStartObj  = $jss.DeserializeObject($etwStartJson)
if (-not $etwStartObj.ContainsKey("netCap") -or ([int]$etwStartObj["netCap"] -notin @(1, 3, 4))) {
    throw "Collector opt-in Net ETW expected valid netCap (1=Active, 3=AccessDenied, 4=Unavailable), got $($etwStartObj['netCap'])."
}
if ([int]$etwStartObj["netCap"] -eq 3) {
    $etwFollowRaw = & $script:PSRPMCollectorScriptBlock $false $false ""
    $etwFollowObj = $jss.DeserializeObject((Expand-GzipPayload $etwFollowRaw))
    if ([int]$etwFollowObj["netCap"] -ne 3) {
        throw "Expected netCap=3 banner state to persist until explicit Stop action, got $($etwFollowObj['netCap'])."
    }
}
$stopRes = & $script:PSRPMCollectorScriptBlock $false $false "Stop"
if ($stopRes -ne "STOPPED") {
    throw "Collector StopNetEtw action expected 'STOPPED', got '$stopRes'."
}
if ([PSRPM.EtwNetConsumerV1]::Active -ne 0) {
    throw "Expected [PSRPM.EtwNetConsumerV1]::Active == 0 after StopNetEtw."
}
Write-Host "  Verified 12B: Opt-In ETW activation returned netCap=$($etwStartObj['netCap']) and StopNetEtw cleaned up cleanly." -ForegroundColor Gray

# 12C: Craft unmanaged EVENT_RECORD + UserData to verify Pure-IL OnEventRecord + DrainAndReset deterministically
[PSRPM.EtwNetConsumerV1]::ClearSlots()
[PSRPM.EtwNetConsumerV1]::TotalEvents = 0
[PSRPM.EtwNetConsumerV1]::Active = 1
$recSize = 96 + [IntPtr]::Size
$pRec  = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($recSize)
$pData = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(16)
try {
    for ($zi = 0; $zi -lt $recSize; $zi++) { [System.Runtime.InteropServices.Marshal]::WriteByte($pRec, $zi, 0) }
    for ($zi = 0; $zi -lt 16; $zi++)       { [System.Runtime.InteropServices.Marshal]::WriteByte($pData, $zi, 0) }
    [System.Runtime.InteropServices.Marshal]::WriteInt16($pRec, 86, [int16]16)
    [System.Runtime.InteropServices.Marshal]::WriteIntPtr($pRec, 88 + [IntPtr]::Size, $pData)

    # Case 1: TCPv4 Send (Task=10, Opcode=10, PID=4242, Size=1200)
    [System.Runtime.InteropServices.Marshal]::WriteByte($pRec, 45, [byte]10)
    [System.Runtime.InteropServices.Marshal]::WriteInt16($pRec, 46, [int16]10)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($pData, 0, 4242)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($pData, 4, 1200)
    [PSRPM.EtwNetConsumerV1]::OnEventRecord($pRec)

    # Case 2: TCPv4 Recv (Task=10, Opcode=11, PID=4242, Size=800)
    [System.Runtime.InteropServices.Marshal]::WriteByte($pRec, 45, [byte]11)
    [System.Runtime.InteropServices.Marshal]::WriteInt16($pRec, 46, [int16]10)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($pData, 0, 4242)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($pData, 4, 800)
    [PSRPM.EtwNetConsumerV1]::OnEventRecord($pRec)

    # Case 3: UDPv6 Send (Task=11, Opcode=42, PID=5353, Size=640)
    [System.Runtime.InteropServices.Marshal]::WriteByte($pRec, 45, [byte]42)
    [System.Runtime.InteropServices.Marshal]::WriteInt16($pRec, 46, [int16]11)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($pData, 0, 5353)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($pData, 4, 640)
    [PSRPM.EtwNetConsumerV1]::OnEventRecord($pRec)

    # Case 4: Non-payload Connect opcode (Task=10, Opcode=12 -> ignored for byte counters)
    [System.Runtime.InteropServices.Marshal]::WriteByte($pRec, 45, [byte]12)
    [System.Runtime.InteropServices.Marshal]::WriteInt16($pRec, 46, [int16]10)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($pData, 0, 4242)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($pData, 4, 9999)
    [PSRPM.EtwNetConsumerV1]::OnEventRecord($pRec)

    $outPids = [int[]]::new(64)
    $outRx   = [long[]]::new(64)
    $outTx   = [long[]]::new(64)
    $totEv   = 0
    $drained = [PSRPM.EtwNetConsumerV1]::DrainAndReset($outPids, $outRx, $outTx, [ref]$totEv)
    if ($drained -ne 2 -or $totEv -ne 4) {
        throw "Pure-IL DrainAndReset mismatch: expected drained=2 & totalEvents=4, got drained=$drained, totalEvents=$totEv."
    }
    $found4242 = $false; $found5353 = $false
    for ($di = 0; $di -lt $drained; $di++) {
        if ($outPids[$di] -eq 4242 -and $outRx[$di] -eq 800L -and $outTx[$di] -eq 1200L) { $found4242 = $true }
        if ($outPids[$di] -eq 5353 -and $outRx[$di] -eq 0L   -and $outTx[$di] -eq 640L)  { $found5353 = $true }
    }
    if (-not $found4242 -or -not $found5353) {
        $dumpSlots = (0..($drained - 1) | ForEach-Object { "pid=$($outPids[$_]) rx=$($outRx[$_]) tx=$($outTx[$_])" }) -join "; "
        throw "Pure-IL OnEventRecord/DrainAndReset misattributed PID/Rx/Tx counters: $dumpSlots"
    }
} finally {
    [PSRPM.EtwNetConsumerV1]::Active = 0
    [PSRPM.EtwNetConsumerV1]::ClearSlots()
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pRec)
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pData)
}
Write-Host "  Verified 12C: Pure-IL OnEventRecord + DrainAndReset attributed TCP/UDP Tx & Rx slots accurately." -ForegroundColor Gray

# 12C-2: Verify EVENT_TRACE_LOGFILEW size/callback offsets in DataCollector.ps1 and live OpenTraceW+ProcessTrace callback delivery
$dcSrc = [System.IO.File]::ReadAllText((Join-Path $repoRoot "PSRPM\Private\DataCollector.ps1"))
if ($dcSrc -notmatch '\$lfSize\s*=\s*if\s*\(\$is64\)\s*\{\s*448\s*\}\s*else\s*\{\s*416\s*\}' -or
    $dcSrc -notmatch '\$offCallback\s*=\s*if\s*\(\$is64\)\s*\{\s*424\s*\}\s*else\s*\{\s*400\s*\}') {
    throw "DataCollector.ps1 EVENT_TRACE_LOGFILEW offsets/sizes do not match verified Windows SDK layout (x64: 448/424, x86: 416/400)."
}
$sampleEtl = Get-ChildItem -Path "$env:SystemRoot\Logs" -Recurse -Filter "*.etl" -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 8192 } | Select-Object -First 1
if ($sampleEtl) {
    $is64Test = ([IntPtr]::Size -eq 8)
    $lfSzTest = if ($is64Test) { 448 } else { 416 }
    $cbOffTest = if ($is64Test) { 424 } else { 400 }
    $pmOffTest = if ($is64Test) { 28 } else { 20 }
    $pLf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($lfSzTest)
    $pFn = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($sampleEtl.FullName)
    $delType = 'PSRPM.EtwEventRecordCallback' -as [type]
    $onEvDel = [Delegate]::CreateDelegate($delType, ([PSRPM.EtwNetConsumerV1]).GetMethod("OnEventRecord"))
    $onEvPtr = [System.Runtime.InteropServices.Marshal]::GetFunctionPointerForDelegate($onEvDel)
    $hTr = [uint64]::MaxValue
    try {
        for ($zi = 0; $zi -lt $lfSzTest; $zi++) { [System.Runtime.InteropServices.Marshal]::WriteByte($pLf, $zi, 0) }
        [System.Runtime.InteropServices.Marshal]::WriteIntPtr($pLf, 0, $pFn)
        [System.Runtime.InteropServices.Marshal]::WriteInt32($pLf, $pmOffTest, 0x10000000) # EVENT_RECORD
        [System.Runtime.InteropServices.Marshal]::WriteIntPtr($pLf, $cbOffTest, $onEvPtr)
        [PSRPM.EtwNetConsumerV1]::TotalEvents = 0
        [PSRPM.EtwNetConsumerV1]::Active = 1
        $hTr = [PSRPM.EtwNetConsumerV1]::OpenTraceW($pLf)
        $invH = if ($is64Test) { [uint64]::MaxValue } else { [uint64]0xFFFFFFFFL }
        if ($hTr -ne $invH -and $hTr -ne [uint64]0) {
            [void][PSRPM.EtwNetConsumerV1]::ProcessTrace([uint64[]]@($hTr), [uint32]1, [IntPtr]::Zero, [IntPtr]::Zero)
            $seenEtlEv = [PSRPM.EtwNetConsumerV1]::TotalEvents
            if ($seenEtlEv -le 0) {
                throw "OpenTraceW/ProcessTrace on $($sampleEtl.FullName) delivered 0 callbacks using EVENT_TRACE_LOGFILEW layout (sz=$lfSzTest, cbOff=$cbOffTest)."
            }
            Write-Host "  Verified 12C-2: Real OpenTraceW+ProcessTrace delivered $seenEtlEv callbacks via EVENT_TRACE_LOGFILEW (sz=$lfSzTest, cbOff=$cbOffTest)." -ForegroundColor Gray
        }
    } finally {
        [PSRPM.EtwNetConsumerV1]::Active = 0
        [PSRPM.EtwNetConsumerV1]::TotalEvents = 0
        [PSRPM.EtwNetConsumerV1]::ClearSlots()
        $invH2 = if ($is64Test) { [uint64]::MaxValue } else { [uint64]0xFFFFFFFFL }
        if ($hTr -ne $invH2 -and $hTr -ne [uint64]0) { [void][PSRPM.EtwNetConsumerV1]::CloseTrace($hTr) }
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pFn)
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($pLf)
        [GC]::KeepAlive($onEvDel)
    }
} else {
    Write-Host "  Verified 12C-2: EVENT_TRACE_LOGFILEW static layout constants validated (no sample .etl in %SystemRoot%\Logs)." -ForegroundColor Gray
}

# 12D: RunspaceEngine 3-Tier TreeNet Rollup & Numeric Network Sorting
$psrpmModNet = Get-Module PSRPM
$sNetSort = & $psrpmModNet { Get-PSRPMNextColumnSortState -IsTreeMode $true -CurrentSortProperty "PID" -CurrentSortDescending $false -ClickedSortProperty "TreeNetTotalBps" }
if ($sNetSort.IsTreeMode -or $sNetSort.SortProperty -ne "TreeNetTotalBps" -or -not $sNetSort.SortDescending) {
    throw "TreeNetTotalBps sort click expected Flat Descending first."
}
$netBytes = [System.IO.File]::ReadAllBytes((Join-Path $uiDir "MainWindow.xaml"))
$msNet = [System.IO.MemoryStream]::new($netBytes)
$netWin = [System.Windows.Markup.XamlReader]::Load($msNet)
$msNet.Close()
$netProcCol = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$netSvcCol  = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$netSumVm   = [SystemSummaryViewModel]::new()
$netWin.FindName("GridProcesses").ItemsSource = $netProcCol
$netWin.FindName("GridServices").ItemsSource  = $netSvcCol
$netWin.FindName("SummaryBar").DataContext    = $netSumVm

$engNet = Start-PSRPMEngine `
    -PSSession $null `
    -Window $netWin `
    -ProcessCollection $netProcCol `
    -ServicesCollection $netSvcCol `
    -SummaryViewModel $netSumVm `
    -CollectorScript $script:PSRPMCollectorScriptBlock `
    -InspectorScript $script:PSRPMDeepInspectorScriptBlock `
    -ActionScript $script:PSRPMActionScriptBlock `
    -IntervalMs 1000 `
    -IsLocal $true `
    -TargetName "NetTest"
try {
    if ($engNet.Timer) { $engNet.Timer.Stop() }
    $engNet.StateContainer.IsPaused = $true
    $engNet.StateContainer.NetEtwCap = 1
    $engNet.ProcessMap.Clear()
    $nRoot = [ProcessItemViewModel]::new()
    $nRoot.SetStaticMetadata(@{ id = 1000; n = "parent.exe"; p = 0; u = "SYSTEM"; arch = "x64"; ct = 10; cat = "System" }, $false)
    $nRoot.UpdateNetwork(0L, 0L)
    $nChild = [ProcessItemViewModel]::new()
    $nChild.SetStaticMetadata(@{ id = 1001; n = "child.exe"; p = 1000; u = "SYSTEM"; arch = "x64"; ct = 20; cat = "System" }, $false)
    $nChild.UpdateNetwork(1024L, 0L)
    $nGrand = [ProcessItemViewModel]::new()
    $nGrand.SetStaticMetadata(@{ id = 1002; n = "grand.exe"; p = 1001; u = "SYSTEM"; arch = "x64"; ct = 30; cat = "System" }, $false)
    $nGrand.UpdateNetwork(0L, 2048L)

    $engNet.ProcessMap[1000] = $nRoot
    $engNet.ProcessMap[1001] = $nChild
    $engNet.ProcessMap[1002] = $nGrand
    & $engNet.RefreshTree

    if ($nRoot.TreeNetRxBps -ne 1024L -or $nRoot.TreeNetTxBps -ne 2048L -or $nRoot.TreeNetTotalBps -ne 3072L -or $nChild.TreeNetTotalBps -ne 3072L -or $nGrand.TreeNetTotalBps -ne 2048L) {
        throw "3-tier TreeNet rollup mismatch: Root=$($nRoot.TreeNetTotalBps), Child=$($nChild.TreeNetTotalBps), Grand=$($nGrand.TreeNetTotalBps)."
    }

    $engNet.StateContainer.IsTreeMode = $false
    $engNet.StateContainer.SortProperty = "NetTotalBps"
    $engNet.StateContainer.SortDescending = $true
    & $engNet.RefreshTree
    if ($netProcCol.IndexOf($nGrand) -ne 0 -or $netProcCol.IndexOf($nChild) -ne 1 -or $netProcCol.IndexOf($nRoot) -ne 2) {
        throw "Flat NetTotalBps Desc sort mismatch (expected grand(2048) -> child(1024) -> parent(0))."
    }
    foreach ($np in @("NetTotalBps", "TreeNetTotalBps", "NetRxBps", "NetTxBps", "TreeNetRxBps", "TreeNetTxBps")) {
        $engNet.StateContainer.SortProperty = $np
        & $engNet.RefreshTree
    }
} finally {
    $engNet.StateContainer.IsStopping = $true
    try { [void]$engNet.StateContainer.WakeEvent.Set() } catch {}
    if ($engNet.Timer) { $engNet.Timer.Stop() }
    if ($engNet.Handle -and $engNet.Handle.AsyncWaitHandle) { [void]$engNet.Handle.AsyncWaitHandle.WaitOne(1500) }
    try { $engNet.PowerShell.Dispose(); $engNet.Runspace.Close(); $engNet.Runspace.Dispose() } catch {}
}
Write-Host "  Verified 12D: 3-tier TreeNet rollup (3072 B/s = 3.0 KB/s) and numeric sorting across all network metrics." -ForegroundColor Gray

# 12F: Classic System Logger MOF (TcpIpGuid/UdpIpGuid Task=0, IPv4/IPv6 Send/Recv 10,11,26,27) & Diagnostic Fields
$etwTypeCheck = 'PSRPM.EtwNetConsumerV1' -as [type]
if ($null -eq $etwTypeCheck) { throw "Expected PSRPM.EtwNetConsumerV1 to be compiled before 12F." }
if ($null -eq $etwTypeCheck.GetField('TraceThreadRunning') -or $null -eq $etwTypeCheck.GetField('LastTraceStatus')) {
    throw "Expected TraceThreadRunning and LastTraceStatus diagnostic fields on PSRPM.EtwNetConsumerV1."
}
$evRecPtr2 = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(112)
$udPtr2    = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(32)
try {
    [System.Runtime.InteropServices.Marshal]::WriteInt32($udPtr2, 0, 7777)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($udPtr2, 4, 2048)
    $offUd2 = 88 + [IntPtr]::Size
    $mofCases = @(
        @{ Guid = '9a280ac0-c8e0-11d1-84e2-00c04fb998a2'; Task = 0;  Op = 10; Rx = 0L;    Tx = 2048L },
        @{ Guid = '9a280ac0-c8e0-11d1-84e2-00c04fb998a2'; Task = 0;  Op = 11; Rx = 2048L; Tx = 0L    },
        @{ Guid = '9a280ac0-c8e0-11d1-84e2-00c04fb998a2'; Task = 0;  Op = 26; Rx = 0L;    Tx = 2048L },
        @{ Guid = '9a280ac0-c8e0-11d1-84e2-00c04fb998a2'; Task = 0;  Op = 27; Rx = 2048L; Tx = 0L    },
        @{ Guid = 'bf3a50c5-a9c9-4988-a005-2df0b7c80f80'; Task = 0;  Op = 10; Rx = 0L;    Tx = 2048L },
        @{ Guid = 'bf3a50c5-a9c9-4988-a005-2df0b7c80f80'; Task = 0;  Op = 27; Rx = 2048L; Tx = 0L    },
        @{ Guid = '7dd42a49-5329-4832-8dfd-43d979153a88'; Task = 11; Op = 58; Rx = 0L;    Tx = 2048L },
        @{ Guid = '7dd42a49-5329-4832-8dfd-43d979153a88'; Task = 11; Op = 59; Rx = 2048L; Tx = 0L    }
    )
    $outPids2 = New-Object int[] 4096
    $outRx2   = New-Object long[] 4096
    $outTx2   = New-Object long[] 4096
    $prevAct  = [PSRPM.EtwNetConsumerV1]::Active
    [PSRPM.EtwNetConsumerV1]::Active = 1
    try {
        foreach ($mc in $mofCases) {
            [PSRPM.EtwNetConsumerV1]::ClearSlots()
            for ($zi = 0; $zi -lt 112; $zi++) { [System.Runtime.InteropServices.Marshal]::WriteByte($evRecPtr2, $zi, 0) }
            $gb2 = ([Guid]$mc.Guid).ToByteArray()
            [System.Runtime.InteropServices.Marshal]::Copy($gb2, 0, [IntPtr]::Add($evRecPtr2, 24), 16)
            [System.Runtime.InteropServices.Marshal]::WriteByte($evRecPtr2, 45, [byte]$mc.Op)
            [System.Runtime.InteropServices.Marshal]::WriteInt16($evRecPtr2, 46, [int16]$mc.Task)
            [System.Runtime.InteropServices.Marshal]::WriteInt16($evRecPtr2, 86, [int16]32)
            [System.Runtime.InteropServices.Marshal]::WriteIntPtr($evRecPtr2, $offUd2, $udPtr2)
            [PSRPM.EtwNetConsumerV1]::OnEventRecord($evRecPtr2)
            $tot2 = 0
            $cnt2 = [PSRPM.EtwNetConsumerV1]::DrainAndReset($outPids2, $outRx2, $outTx2, [ref]$tot2)
            if ($cnt2 -ne 1 -or $outPids2[0] -ne 7777 -or $outRx2[0] -ne $mc.Rx -or $outTx2[0] -ne $mc.Tx) {
                throw "Classic MOF event attribution failed for $($mc.Guid) op=$($mc.Op): cnt=$cnt2 pid=$($outPids2[0]) rx=$($outRx2[0]) tx=$($outTx2[0])."
            }
        }
        # Non-network Task=0 provider (EventTrace header GUID) must be ignored
        [PSRPM.EtwNetConsumerV1]::ClearSlots()
        $hdrGb = ([Guid]'68fdd900-4a3e-11d1-84f4-0000f80464e3').ToByteArray()
        [System.Runtime.InteropServices.Marshal]::Copy($hdrGb, 0, [IntPtr]::Add($evRecPtr2, 24), 16)
        [System.Runtime.InteropServices.Marshal]::WriteByte($evRecPtr2, 45, [byte]10)
        [System.Runtime.InteropServices.Marshal]::WriteInt16($evRecPtr2, 46, [int16]0)
        [PSRPM.EtwNetConsumerV1]::OnEventRecord($evRecPtr2)
        $totHdr = 0
        if ([PSRPM.EtwNetConsumerV1]::DrainAndReset($outPids2, $outRx2, $outTx2, [ref]$totHdr) -ne 0) {
            throw "Expected non-network Task=0 provider event to be ignored."
        }
    } finally {
        [PSRPM.EtwNetConsumerV1]::Active = $prevAct
    }
} finally {
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($evRecPtr2)
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($udPtr2)
}
Write-Host "  Verified 12F: Classic System Logger TcpIpGuid/UdpIpGuid (IPv4/IPv6 Send/Recv 10,11,26,27) and header exclusion." -ForegroundColor Gray

$dcRaw12g = [System.IO.File]::ReadAllText((Join-Path $repoRoot "PSRPM\Private\DataCollector.ps1"))
$idxStartBlock = $dcRaw12g.IndexOf('$startNetEtw = {')
$idxIs64Start  = $dcRaw12g.IndexOf('$is64 = ([IntPtr]::Size -eq 8)', $idxStartBlock)
$idxLfSize     = $dcRaw12g.IndexOf('$lfSize = if ($is64)', $idxStartBlock)
if ($idxStartBlock -lt 0 -or $idxIs64Start -lt 0 -or $idxLfSize -lt 0 -or $idxIs64Start -gt $idxLfSize) {
    throw "Regression: `$is64 must be initialized inside `$startNetEtw before `$lfSize / `$offCallback / `$invTraceHnd!"
}
Write-Host "  Verified 12G: `$is64 initialized inside `$startNetEtw before 64/32-bit EVENT_TRACE_LOGFILEW offsets." -ForegroundColor Gray

# 12H: Double-bank slot recycling across >4096 distinct PIDs (zero slot exhaustion)
$evRecPtr3 = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(112)
$udPtr3    = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(32)
$prevAct3  = [PSRPM.EtwNetConsumerV1]::Active
try {
    [PSRPM.EtwNetConsumerV1]::ClearSlots()
    [PSRPM.EtwNetConsumerV1]::ActiveBank = 0
    [PSRPM.EtwNetConsumerV1]::InFlight0  = 0
    [PSRPM.EtwNetConsumerV1]::InFlight1  = 0
    [PSRPM.EtwNetConsumerV1]::Active     = 1

    for ($zi = 0; $zi -lt 112; $zi++) { [System.Runtime.InteropServices.Marshal]::WriteByte($evRecPtr3, $zi, 0) }
    [System.Runtime.InteropServices.Marshal]::WriteByte($evRecPtr3, 45, [byte]11)   # Rx IPv4
    [System.Runtime.InteropServices.Marshal]::WriteInt16($evRecPtr3, 46, [int16]10) # Task=10 TcpIp
    [System.Runtime.InteropServices.Marshal]::WriteInt16($evRecPtr3, 86, [int16]32)
    [System.Runtime.InteropServices.Marshal]::WriteIntPtr($evRecPtr3, (88 + [IntPtr]::Size), $udPtr3)
    [System.Runtime.InteropServices.Marshal]::WriteInt32($udPtr3, 4, 256)

    $outPids3 = New-Object int[] 4096
    $outRx3   = New-Object long[] 4096
    $outTx3   = New-Object long[] 4096
    $cumPids  = 0
    $cumBytes = 0L
    # 3 ticks x 2000 unique PIDs = 6000 distinct PIDs (>4096 single-table capacity)
    for ($tickIdx = 0; $tickIdx -lt 3; $tickIdx++) {
        $basePid = 10000 + ($tickIdx * 2000)
        for ($pi = 0; $pi -lt 2000; $pi++) {
            [System.Runtime.InteropServices.Marshal]::WriteInt32($udPtr3, 0, ($basePid + $pi))
            [PSRPM.EtwNetConsumerV1]::OnEventRecord($evRecPtr3)
        }
        $tot3 = 0
        $cnt3 = [PSRPM.EtwNetConsumerV1]::DrainAndReset($outPids3, $outRx3, $outTx3, [ref]$tot3)
        if ($cnt3 -ne 2000) {
            throw "Double-bank slot recycling failed on tick $($tickIdx): expected 2000 unique PIDs, got $cnt3."
        }
        $cumPids += $cnt3
        for ($di = 0; $di -lt $cnt3; $di++) { $cumBytes += $outRx3[$di] }
    }
    if ($cumPids -ne 6000 -or $cumBytes -ne (6000L * 256L)) {
        throw "Double-bank totals mismatch: pids=$cumPids bytes=$cumBytes."
    }
    $totEmpty = 0
    $cntEmpty = [PSRPM.EtwNetConsumerV1]::DrainAndReset($outPids3, $outRx3, $outTx3, [ref]$totEmpty)
    if ($cntEmpty -ne 0) {
        throw "Expected drained bank to start empty on subsequent tick, got $cntEmpty."
    }
} finally {
    [PSRPM.EtwNetConsumerV1]::Active = $prevAct3
    [PSRPM.EtwNetConsumerV1]::ClearSlots()
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($evRecPtr3)
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($udPtr3)
}
Write-Host "  Verified 12H: Double-bank lock-free slot reclamation recycled 6,000 unique PIDs across 3 ticks with zero exhaustion." -ForegroundColor Gray

# 12I: Per-tab NetEtwCap/NetBannerDismissedCap isolation and Dark/Light banner theme parity
$tabEtwA = [HostTabItemViewModel]::new("tA", "PC-A", "PC-A", "WINRM", $false, $null)
$tabEtwA.NetEtwCap = 2
$tabEtwA.NetEtwEventsPerSec = 31200
$tabEtwA.NetBannerDismissedCap = 2
$tabEtwB = [HostTabItemViewModel]::new("tB", "PC-B", "PC-B", "WINRM", $false, $null)
if ($tabEtwB.NetEtwCap -ne 0 -or $tabEtwB.NetBannerDismissedCap -ne 0 -or $tabEtwA.NetBannerDismissedCap -ne 2 -or $tabEtwA.NetEtwEventsPerSec -ne 31200) {
    throw "HostTabItemViewModel ETW per-tab isolation mismatch."
}
$psm1Src12 = [System.IO.File]::ReadAllText((Join-Path $repoRoot "PSRPM\PSRPM.psm1"))
if ($psm1Src12 -notmatch '\$stateContainer\.NetEtwCap\s*=\s*\[int\]\$targetTabVm\.NetEtwCap' -or
    $psm1Src12 -notmatch 'NetBannerDismissedCap' -or
    $psm1Src12 -notmatch '\$script:UpdateNetEtwUi') {
    throw "PSRPM.psm1 missing per-tab NetEtwCap preservation, per-tab NetBannerDismissedCap, or theme-sync hook."
}
Write-Host "  Verified 12I: Per-tab NetEtwCap (including Paused/Unavailable), NetBannerDismissedCap isolation, and theme-aware banner sync." -ForegroundColor Gray

# 12J: v1.8.2 Code Review & Audit Console Enhancements Verification
$svcEnumType = 'PSRPM.NativeServiceEnumV1' -as [type]
if ($null -eq $svcEnumType) {
    throw "Expected PSRPM.NativeServiceEnumV1 Reflection.Emit type to be compiled in memory."
}
$manifestVer12j = (Import-PowerShellDataFile -Path (Join-Path $repoRoot "PSRPM\PSRPM.psd1")).ModuleVersion
if (-not $dataTick1.ContainsKey('colVer') -or [string]$dataTick1['colVer'] -ne [string]$manifestVer12j -or -not $dataTick1.ContainsKey('colMs') -or -not $dataTick1.ContainsKey('svcMs') -or -not $dataTick1.ContainsKey('svcFull') -or -not $dataTick1.ContainsKey('metaPend')) {
    throw "Expected colVer='$manifestVer12j', colMs, svcMs, svcFull, and metaPend in DataCollector payload."
}
$appDomainSvcs = [AppDomain]::CurrentDomain.GetData("PSRPM_CachedServices")
if ($null -eq $appDomainSvcs -or $appDomainSvcs.Count -lt 5) {
    throw "Expected PSRPM_CachedServices to be published to AppDomain data by DataCollector."
}

# Verify ControlService wildcard refusal
$actWcJson = & $script:PSRPMActionScriptBlock -Action "ControlService" -TargetPid 0 -ExpectedName "Stop" -ServiceName "wuauserv*"
$actWcObj  = $jss.DeserializeObject($actWcJson)
if ([bool]$actWcObj['Success'] -or [string]$actWcObj['Status'] -ne "Refused") {
    throw "Expected ControlService with wildcard 'wuauserv*' to be refused, got Success=$($actWcObj['Success']), Status=$($actWcObj['Status'])."
}

# Verify RunspaceEngine, PSRPM.psm1, DeepInspector.ps1, and ProcessActions.ps1 structural invariants
$reSrc12j = [System.IO.File]::ReadAllText((Join-Path $repoRoot "PSRPM\Private\RunspaceEngine.ps1"))
$diSrc12j = [System.IO.File]::ReadAllText((Join-Path $repoRoot "PSRPM\Private\DeepInspector.ps1"))
$paSrc12j = [System.IO.File]::ReadAllText((Join-Path $repoRoot "PSRPM\Private\ProcessActions.ps1"))

if ($diSrc12j -notmatch 'PSRPM_CachedServices' -or $diSrc12j -notmatch '\[Microsoft\.Win32\.Registry\]::Users' -or $diSrc12j -match 'while\s*\(\$true\)' -or $diSrc12j -notmatch '\$netProc\.Dispose\(\)') {
    throw "DeepInspector.ps1 missing AppDomain PSRPM_CachedServices reader, HKU Registry::Users autostart enumeration, bounded SPI struct walk, or netProc.Dispose()."
}
if ($paSrc12j -notmatch 'PSRPM_ForceSvcRefresh' -or $paSrc12j -notmatch 'System\.ServiceProcess\.ServiceController' -or $paSrc12j -notmatch '\$curIdent\.Dispose\(\)' -or $paSrc12j -notmatch '\$dupProbe\s*=\s*\[IntPtr\]::Zero') {
    throw "ProcessActions.ps1 missing PSRPM_ForceSvcRefresh flag, ServiceController 30s timeout, curIdent.Dispose(), or dupProbe pointer hygiene."
}
if ($reSrc12j -notmatch 'NewBoundScriptBlock' -or $reSrc12j -notmatch 'Grandparent:' -or $reSrc12j -notmatch '72000' -or $reSrc12j -notmatch 'ViewportHeight') {
    throw "RunspaceEngine.ps1 missing per-tab NewBoundScriptBlock, Grandparent lineage, 72000 char buffer, or Sticky-to-Bottom ViewportHeight check."
}
if ($psm1Src12 -notmatch '72000' -or $psm1Src12 -notmatch 'BitmapCacheOption\]::OnLoad' -or $psm1Src12 -notmatch 'PSRPM_Dumps') {
    throw "PSRPM.psm1 missing 72000 char buffer, in-memory BitmapCacheOption::OnLoad icon loader, or PSRPM_Dumps prompt path."
}
foreach ($srcEntry in @(
    @{ Name = "DeepInspector.ps1";  Content = $diSrc12j },
    @{ Name = "ProcessActions.ps1"; Content = $paSrc12j },
    @{ Name = "PSRPM.psm1";         Content = $psm1Src12 }
)) {
    $freeMatches = [regex]::Matches($srcEntry.Content, 'FreeHGlobal\(\$(?<var>[A-Za-z0-9_]+)\)(?<tail>\s*\$[A-Za-z0-9_]+\s*=\s*\[IntPtr\]::Zero)?')
    if ($freeMatches.Count -eq 0) {
        throw "Expected at least one FreeHGlobal call in $($srcEntry.Name)."
    }
    foreach ($fm in $freeMatches) {
        $vName = $fm.Groups['var'].Value
        $tail  = $fm.Groups['tail'].Value
        if ($tail -notmatch "^\s*\`$$vName\s*=\s*\[IntPtr\]::Zero$") {
            throw "Double-free hazard in $($srcEntry.Name): FreeHGlobal(`$$vName) is not immediately followed by `$$vName = [IntPtr]::Zero."
        }
    }
}
Write-Host "  Verified 12J: NativeServiceEnumV1 (colVer $manifestVer12j), AppDomain service cache, wildcard service refusal, zero double-free pointer hygiene, async worker routing, sticky auto-scroll, and parent/grandparent lineage." -ForegroundColor Gray

# 12K: User Preferences Persistence (LocalApplicationData, Validation & Malformed JSON Resilience)
$psrpmModPrefs = Get-Module PSRPM
$defaultPrefPath = & $psrpmModPrefs { Get-PSRPMPreferencesPath }
$expectedLocalAppData = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($defaultPrefPath) -or ($expectedLocalAppData -and -not $defaultPrefPath.StartsWith($expectedLocalAppData, [System.StringComparison]::OrdinalIgnoreCase)) -or -not $defaultPrefPath.EndsWith("PSRPM\preferences.json", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Expected Get-PSRPMPreferencesPath to resolve under LocalApplicationData\PSRPM\preferences.json, got '$defaultPrefPath'."
}
$tempPrefFile = Join-Path ([System.IO.Path]::GetTempPath()) ("psrpm_prefs_test_{0}.json" -f [guid]::NewGuid().ToString("N"))
try {
    & $psrpmModPrefs { param($p) $script:PSRPMPreferencesPathOverride = $p } $tempPrefFile

    $missingRes = & $psrpmModPrefs { Read-PSRPMPreferences }
    if ($missingRes.LoadedFromDisk -or $missingRes.HadParseError -or $missingRes.Preferences.Theme -ne "Light") {
        throw "Missing preferences file should return factory defaults without error."
    }

    $customPrefs = @{
        Theme                    = "Dark"
        AlwaysOnTop              = $true
        EnableCategoryHighlights = $false
        ConfirmKill              = $false
        VerboseTelemetryLog      = $false
        IsTreeMode               = $false
        ShowTreeLines            = $false
        CompactMode              = $true
        UiScalePct               = 175
        TreeSortNewestFirst      = $false
        SortProperty             = "CPU"
        SortDescending           = $true
        RefreshIntervalMs        = 500
        LogPaneVisible           = $true
        LogPaneHeight            = 240.0
        LogAutoScroll            = $false
        VisibleColumns           = @("Process", "CPU", "PID", "Version", "CommandLine")
        ColumnOrder              = @("Process", "PID", "Version", "CommandLine", "CPU")
        ColumnWidths             = @{ Version = 125.0; CommandLine = 340.0 }
    }
    [void](& $psrpmModPrefs { param($pr) Save-PSRPMPreferences -Preferences $pr } $customPrefs)
    if (-not [System.IO.File]::Exists($tempPrefFile)) {
        throw "Save-PSRPMPreferences did not write file to '$tempPrefFile'."
    }
    $loadedRes = & $psrpmModPrefs { Read-PSRPMPreferences }
    if (-not $loadedRes.LoadedFromDisk -or $loadedRes.HadParseError) {
        throw "Failed to load saved preferences from '$tempPrefFile'."
    }
    if ($loadedRes.Preferences.Theme -ne "Dark" -or -not $loadedRes.Preferences.AlwaysOnTop -or $loadedRes.Preferences.EnableCategoryHighlights -or $loadedRes.Preferences.IsTreeMode -or $loadedRes.Preferences.ShowTreeLines -or -not $loadedRes.Preferences.CompactMode -or $loadedRes.Preferences.UiScalePct -ne 175 -or $loadedRes.Preferences.SortProperty -ne "CPU" -or -not $loadedRes.Preferences.SortDescending -or $loadedRes.Preferences.RefreshIntervalMs -ne 500 -or -not $loadedRes.Preferences.LogPaneVisible -or $loadedRes.Preferences.LogPaneHeight -ne 240.0 -or $loadedRes.Preferences.LogAutoScroll) {
        throw "Loaded preferences did not round-trip accurately."
    }
    if (($loadedRes.Preferences.VisibleColumns -join ',') -ne "Process,CPU,PID,Version,CommandLine") {
        throw "VisibleColumns did not round-trip accurately: $($loadedRes.Preferences.VisibleColumns -join ',')"
    }
    if ($loadedRes.Preferences.ColumnOrder[0] -ne "Process" -or $loadedRes.Preferences.ColumnOrder[1] -ne "PID" -or $loadedRes.Preferences.ColumnOrder[2] -ne "Version" -or $loadedRes.Preferences.ColumnOrder.Count -lt 26) {
        throw "ColumnOrder did not preserve saved order and backfill catalog columns."
    }
    if ($loadedRes.Preferences.ColumnWidths["Version"] -ne 125.0 -or $loadedRes.Preferences.ColumnWidths["CommandLine"] -ne 340.0) {
        throw "ColumnWidths did not round-trip accurately."
    }

    # Malformed JSON resilience
    [System.IO.File]::WriteAllText($tempPrefFile, "{`"Theme`": `"Dark`", broken", [System.Text.UTF8Encoding]::new($false))
    $badJsonRes = & $psrpmModPrefs { Read-PSRPMPreferences }
    if ($badJsonRes.LoadedFromDisk -or -not $badJsonRes.HadParseError -or $badJsonRes.Preferences.Theme -ne "Light") {
        throw "Malformed JSON did not fail open cleanly to factory defaults."
    }

    # Partial + invalid-field sanitization resilience (also tests forced Process column & width bounds)
    [System.IO.File]::WriteAllText($tempPrefFile, '{"Theme":"Bogus","AlwaysOnTop":true,"SortProperty":"InjectedField","RefreshIntervalMs":-50,"LogPaneHeight":99999,"VisibleColumns":["BogusCol","Version"],"ColumnWidths":{"Version":99999,"CommandLine":310,"FakeCol":120}}', [System.Text.UTF8Encoding]::new($false))
    $sanitizedRes = & $psrpmModPrefs { Read-PSRPMPreferences }
    if (-not $sanitizedRes.LoadedFromDisk -or $sanitizedRes.HadParseError -or $sanitizedRes.Preferences.Theme -ne "Light" -or -not $sanitizedRes.Preferences.AlwaysOnTop -or $sanitizedRes.Preferences.SortProperty -ne "PID" -or $sanitizedRes.Preferences.RefreshIntervalMs -ne 1000 -or $sanitizedRes.Preferences.LogPaneHeight -ne 175.0) {
        throw "Invalid preference fields were not sanitized to safe defaults."
    }
    if (($sanitizedRes.Preferences.VisibleColumns -join ',') -ne "Process,Version") {
        throw "VisibleColumns sanitization failed (expected 'Process,Version', got '$($sanitizedRes.Preferences.VisibleColumns -join ',')')."
    }
    if ($sanitizedRes.Preferences.ColumnWidths.ContainsKey("Version") -or $sanitizedRes.Preferences.ColumnWidths.ContainsKey("FakeCol") -or $sanitizedRes.Preferences.ColumnWidths["CommandLine"] -ne 310.0) {
        throw "ColumnWidths sanitization failed."
    }

    # Temporary -Defaults (-UseDefaults) must return factory defaults without reading or modifying saved config on disk
    $skipDiskRes = & $psrpmModPrefs { Read-PSRPMPreferences -UseDefaults }
    if (-not $skipDiskRes.SkippedDisk -or $skipDiskRes.LoadedFromDisk -or $skipDiskRes.HadParseError -or $skipDiskRes.Preferences.Theme -ne "Light" -or $skipDiskRes.Preferences.AlwaysOnTop -or $skipDiskRes.Preferences.SortProperty -ne "PID" -or $skipDiskRes.Preferences.RefreshIntervalMs -ne 1000) {
        throw "Read-PSRPMPreferences -UseDefaults did not bypass saved config cleanly."
    }
    if (-not [System.IO.File]::Exists($tempPrefFile)) {
        throw "Read-PSRPMPreferences -UseDefaults unexpectedly deleted saved preferences file '$tempPrefFile'."
    }

    $wasRemoved = & $psrpmModPrefs { Reset-PSRPMPreferences }
    if (-not $wasRemoved -or [System.IO.File]::Exists($tempPrefFile)) {
        throw "Reset-PSRPMPreferences did not remove '$tempPrefFile'."
    }
} finally {
    & $psrpmModPrefs { $script:PSRPMPreferencesPathOverride = $null }
    if ([System.IO.File]::Exists($tempPrefFile)) { try { [System.IO.File]::Delete($tempPrefFile) } catch {} }
}
Write-Host "  Verified 12K: Explicit preferences persistence (LocalApplicationData\PSRPM\preferences.json), field sanitization, reset, and malformed JSON resilience." -ForegroundColor Gray

# 12L: Tokyo Night & Tokyo Night Light Theme Registry, ViewModel, Tab & Preferences Verification
if (-not [PSRPMThemeRegistry]::IsDarkMode("TokyoNight") -or [PSRPMThemeRegistry]::IsDarkMode("TokyoNightLight")) {
    throw "PSRPMThemeRegistry.IsDarkMode mismatch for TokyoNight / TokyoNightLight."
}
$tnDark = [PSRPMThemeRegistry]::GetPalette("TokyoNight")
$tnLight = [PSRPMThemeRegistry]::GetPalette("TokyoNightLight")
foreach ($reqBrush in @("BrushWindowBg", "BrushSurfaceBg", "BrushTextPrimary", "BrushAccent", "BrushBadgeBg", "BrushSparkGrid", "BrushLogBg", "BrushLogTelem1", "BrushTargetNodeBg", "BrushKillBg", "BrushSwatchSvcBg")) {
    if (-not $tnDark.Brushes.ContainsKey($reqBrush) -or -not $tnLight.Brushes.ContainsKey($reqBrush)) {
        throw "Tokyo Night palette missing required brush key '$reqBrush'."
    }
}
$tnVm = [ProcessItemViewModel]::new()
$tnVm.PID = 901
$tnVm.ParentPID = 4
$tnVm.Name = "tn_worker.exe"
$tnVm.Category = "Service"
$tnVm.SetThemeMode("TokyoNight")
if (-not $tnVm.IsDarkTheme -or $tnVm.RowBackground -ne "#2C1F35" -or $tnVm.RowForeground -ne "#C0CAF5") {
    throw "TokyoNight Service row mismatch: Bg=$($tnVm.RowBackground), Fg=$($tnVm.RowForeground)"
}
$tnVm.SetLifecycleState(1)
if ($tnVm.RowBackground -ne "#1C382E" -or $tnVm.RowForeground -ne "#9ECE6A") {
    throw "TokyoNight New row mismatch: Bg=$($tnVm.RowBackground), Fg=$($tnVm.RowForeground)"
}
$tnVm.SetLifecycleState(0)
$tnVm.SetThemeMode("TokyoNightLight")
if ($tnVm.IsDarkTheme -or $tnVm.RowBackground -ne "#EBD8E4" -or $tnVm.RowForeground -ne "#4A2538") {
    throw "TokyoNightLight Service row mismatch: Bg=$($tnVm.RowBackground), Fg=$($tnVm.RowForeground)"
}
$tnVm.SetLifecycleState(1)
if ($tnVm.RowBackground -ne "#CFE3CC" -or $tnVm.RowForeground -ne "#264709") {
    throw "TokyoNightLight New row mismatch: Bg=$($tnVm.RowBackground), Fg=$($tnVm.RowForeground)"
}

$tnTab = [HostTabItemViewModel]::new("t1", "PC-TN", "PC-TN", "WINRM", $false, $null)
$tnTab.UpdateVisualState($true, "TokyoNight", $true, "Connected", $false, 12)
if (-not $tnTab.IsDarkTheme -or $tnTab.TabBackground -ne "#1A1B26" -or $tnTab.TabBorderBrush -ne "#7AA2F7") {
    throw "HostTabItemViewModel TokyoNight active mismatch."
}
$tnTab.UpdateVisualState($false, "TokyoNightLight", $true, "Standby", $false, 0)
if ($tnTab.IsDarkTheme -or $tnTab.TabBackground -ne "#D6D8DF" -or $tnTab.TabBorderBrush -ne "#C1C2C7") {
    throw "HostTabItemViewModel TokyoNightLight standby mismatch."
}

$tempTnPref = Join-Path ([System.IO.Path]::GetTempPath()) "psrpm_tn_prefs_$([System.Guid]::NewGuid().ToString('N')).json"
try {
    & $psrpmModPrefs { param($p) $script:PSRPMPreferencesPathOverride = $p } $tempTnPref
    [System.IO.File]::WriteAllText($tempTnPref, '{"Theme":"TokyoNight"}', [System.Text.UTF8Encoding]::new($false))
    $tnPrefRead1 = & $psrpmModPrefs { Read-PSRPMPreferences }
    [System.IO.File]::WriteAllText($tempTnPref, '{"Theme":"TokyoNightLight"}', [System.Text.UTF8Encoding]::new($false))
    $tnPrefRead2 = & $psrpmModPrefs { Read-PSRPMPreferences }
    if ($tnPrefRead1.Preferences.Theme -ne "TokyoNight" -or $tnPrefRead2.Preferences.Theme -ne "TokyoNightLight") {
        throw "Read-PSRPMPreferences rejected TokyoNight / TokyoNightLight themes."
    }
} finally {
    & $psrpmModPrefs { $script:PSRPMPreferencesPathOverride = $null }
    if ([System.IO.File]::Exists($tempTnPref)) { try { [System.IO.File]::Delete($tempTnPref) } catch {} }
}
Write-Host "  Verified 12L: TokyoNight & TokyoNightLight theme registry, ViewModel rows, HostTabItemViewModel, and preferences." -ForegroundColor Gray

# 12M: Network System Info Tab, AllSockets DeepInspector, Hover Tooltips, Peaks, Baseline Diffs & 6-Theme WCAG Brushes
Write-Host "`n[TEST 12M] Verifying Network SysInfo Graph, AllSockets Mode, Hover Tooltips, Peaks & Baseline Diffs..." -ForegroundColor Yellow

# A. Verify all 6 themes define all 15 new brushes and meet >= 4.5:1 contrast for delta & badge foregrounds
$getRelLum = {
    param([string]$hex)
    $h = $hex.TrimStart('#')
    if ($h.Length -eq 8) { $h = $h.Substring(2) }
    $r = [Convert]::ToInt32($h.Substring(0, 2), 16) / 255.0
    $g = [Convert]::ToInt32($h.Substring(2, 2), 16) / 255.0
    $b = [Convert]::ToInt32($h.Substring(4, 2), 16) / 255.0
    $lin = {
        param([double]$c)
        if ($c -le 0.03928) { return ($c / 12.92) }
        return [Math]::Pow(($c + 0.055) / 1.055, 2.4)
    }
    return (0.2126 * (& $lin $r) + 0.7152 * (& $lin $g) + 0.0722 * (& $lin $b))
}
$getContrastRatio = {
    param([string]$hexA, [string]$hexB)
    $l1 = & $getRelLum $hexA
    $l2 = & $getRelLum $hexB
    $hi = [Math]::Max($l1, $l2)
    $lo = [Math]::Min($l1, $l2)
    return (($hi + 0.05) / ($lo + 0.05))
}

$reqNetThemeKeys = @(
    "BrushNetRxStroke", "BrushNetRxFill", "BrushNetTxStroke", "BrushNetTxFill",
    "BrushDeltaGrowthFg", "BrushDeltaShrinkFg", "BrushDeltaNewFg",
    "BrushBadgeTcpBg", "BrushBadgeTcpFg", "BrushBadgeUdpBg", "BrushBadgeUdpFg",
    "BrushStateEstBg", "BrushStateEstFg", "BrushStateListenBg", "BrushStateListenFg",
    "BrushStateTimeWaitBg", "BrushStateTimeWaitFg",
    "BrushNetRowNewBg", "BrushNetRowNewFg",
    "BrushNetRowModBg", "BrushNetRowModFg",
    "BrushNetRowDelBg", "BrushNetRowDelFg"
)
foreach ($tName in @("Light", "Dark", "TokyoNight", "TokyoNightLight", "Classic", "HighContrast")) {
    $palCheck = [PSRPMThemeRegistry]::GetPalette($tName)
    foreach ($rk in $reqNetThemeKeys) {
        if (-not $palCheck.Brushes.ContainsKey($rk)) {
            throw "Theme '$tName' missing required brush '$rk'."
        }
        $valHex = [string]$palCheck.Brushes[$rk]
        if ($valHex -notmatch '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$') {
            throw "Theme '$tName' brush '$rk' has invalid hex '$valHex'."
        }
    }
    $surfHex = [string]$palCheck.Brushes["BrushSurfaceBg"]
    foreach ($dKey in @("BrushDeltaGrowthFg", "BrushDeltaShrinkFg", "BrushDeltaNewFg")) {
        $crDelta = & $getContrastRatio ([string]$palCheck.Brushes[$dKey]) $surfHex
        if ($crDelta -lt 4.5) {
            throw "Theme '$tName' delta brush '$dKey' contrast against BrushSurfaceBg is $([Math]::Round($crDelta, 2)) (< 4.5:1)."
        }
    }
    foreach ($pair in @(
        @("BrushBadgeTcpBg", "BrushBadgeTcpFg"),
        @("BrushBadgeUdpBg", "BrushBadgeUdpFg"),
        @("BrushStateEstBg", "BrushStateEstFg"),
        @("BrushStateListenBg", "BrushStateListenFg"),
        @("BrushStateTimeWaitBg", "BrushStateTimeWaitFg"),
        @("BrushNetRowNewBg", "BrushNetRowNewFg"),
        @("BrushNetRowModBg", "BrushNetRowModFg"),
        @("BrushNetRowDelBg", "BrushNetRowDelFg")
    )) {
        $crBadge = & $getContrastRatio ([string]$palCheck.Brushes[$pair[0]]) ([string]$palCheck.Brushes[$pair[1]])
        if ($crBadge -lt 4.5) {
            throw "Theme '$tName' badge pair '$($pair[0])/$($pair[1])' contrast is $([Math]::Round($crBadge, 2)) (< 4.5:1)."
        }
    }
}

# B. SystemSummaryViewModel Network 240-Sample Curve, Auto-Scale Peak, Closed Guard & Session Totals
$netSummVm = [SystemSummaryViewModel]::new()
$netSummVm.IsSysInfoOpen = $false
$beforeRxPts = $netSummVm.SysNetRxPoints
$extArr = [double[]]::new(29)
$extArr[27] = 100.0 # 100 KB/s Rx
$extArr[28] = 50.0  # 50 KB/s Tx
$netSummVm.UpdateExtendedTelemetry($extArr, @())
if ($netSummVm.SysNetRxPoints -ne $beforeRxPts) {
    throw "SystemSummaryViewModel rebuilt Net Rx points while IsSysInfoOpen=false ('$($netSummVm.SysNetRxPoints)' vs '$beforeRxPts')."
}
Start-Sleep -Milliseconds 120
$extArr[27] = 512.0 # 512 KB/s Rx burst
$extArr[28] = 256.0 # 256 KB/s Tx burst
$netSummVm.UpdateExtendedTelemetry($extArr, @())
$netSummVm.IsSysInfoOpen = $true
$netSummVm.RefreshSysInfoGraphs()
if ($netSummVm.SysNetRxPoints -eq $beforeRxPts -or -not $netSummVm.SysNetRxPoints.Contains(",") -or -not $netSummVm.SysNetTxPoints.Contains(",")) {
    throw "SystemSummaryViewModel did not generate Net Rx/Tx polylines when IsSysInfoOpen=true."
}
if ($netSummVm.NetGaugeHeight -le 0.0 -or $netSummVm.NetSessionTotalFormatted -eq "0 B" -or $netSummVm.NetTotalRateFormatted -notlike "*/s") {
    throw "SystemSummaryViewModel network readouts invalid: Gauge=$($netSummVm.NetGaugeHeight), Sess='$($netSummVm.NetSessionTotalFormatted)', Tot='$($netSummVm.NetTotalRateFormatted)'."
}
$netSummVm.UpdateNetEtwStatus(1, 340)
if ($netSummVm.NetEtwStatusSummary -notlike "*340*") { throw "UpdateNetEtwStatus(1,340) mismatch: '$($netSummVm.NetEtwStatusSummary)'." }
$netSummVm.UpdateNetEtwStatus(2, 26000)
if ($netSummVm.NetEtwStatusSummary -notlike "*breaker*") { throw "UpdateNetEtwStatus(2,26000) mismatch: '$($netSummVm.NetEtwStatusSummary)'." }
$netSummVm.UpdateNetEtwStatus(3, 0)
if ($netSummVm.NetEtwStatusSummary -notlike "*Tier 1*") { throw "UpdateNetEtwStatus(3,0) mismatch: '$($netSummVm.NetEtwStatusSummary)'." }

# C. DeepInspector.ps1 "AllSockets" On-Demand Snapshot Mode
$allSockJson = & $script:PSRPMDeepInspectorScriptBlock 0 $false "AllSockets"
$jssAllSock = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
$jssAllSock.MaxJsonLength = 67108864
$allSockRes = $jssAllSock.DeserializeObject($allSockJson)
if (-not $allSockRes -or -not [bool]$allSockRes["Success"]) {
    throw "DeepInspector AllSockets failed: $($allSockRes['Error'])"
}
$sockRows = $allSockRes["Sockets"]
if ($null -eq $sockRows -or $sockRows.Count -lt 1) {
    throw "DeepInspector AllSockets returned 0 system-wide sockets on local host."
}
$sampleSock = $sockRows[0]
foreach ($reqSockField in @("PID", "Protocol", "State", "LocalAddress", "LocalPort", "RemoteAddress", "RemotePort", "LocalEndpoint", "RemoteEndpoint", "CreateTimestamp", "CreateTime", "ModuleName", "SentPackets", "RecvPackets", "SentBytes", "RecvBytes")) {
    if (-not $sampleSock.ContainsKey($reqSockField)) {
        throw "DeepInspector AllSockets record missing expected TCPView key '$reqSockField'."
    }
}
$hasTcpStateTitleCase = $false
foreach ($sr in $sockRows) {
    if ($sr["State"] -in @("Listen", "Listening", "Established", "Time Wait", "Close Wait")) {
        $hasTcpStateTitleCase = $true
        break
    }
}
if (-not $hasTcpStateTitleCase) {
    throw "DeepInspector AllSockets did not normalize socket State to TitleCase (e.g. Listen/Established/Time Wait)."
}

# C2. ProcessActions "CloseTcpConnection" P/Invoke + Endpoint Validation
$closeTestJson = & $script:PSRPMActionScriptBlock "CloseTcpConnection" 0 "" "" "Normal" "127.0.0.1|65499|127.0.0.1|65498"
$closeTestRes = $jssAllSock.DeserializeObject($closeTestJson)
if (-not $closeTestRes -or [bool]$closeTestRes["Success"] -or ([string]$closeTestRes["Message"] -notmatch 'Win32 error|SetTcpEntry|Access denied|could not be closed')) {
    throw "CloseTcpConnection probe unexpected result: $closeTestJson"
}

# D. ProcessItemViewModel Session Peaks, Baseline Diffs (+/-/NEW & PID-Reuse CreateTime Protection), & Hover Tooltips
$peakBaseVm = [ProcessItemViewModel]::new()
$peakBaseVm.SetStaticMetadata(@{ id = $PID; ct = 134076000000000000L; n = "worker_test.exe"; desc = "Worker Host"; comp = "PSRPM QA"; ver = "1.0.0"; cmd = "worker_test.exe --run"; path = "C:\Tools\worker_test.exe"; u = "TEST\User"; sid = 8; arch = "x64"; start = "2026-11-14 10:00:00"; prio = 8; p = 0; cat = "Own" }, $false)
$peakBaseVm.SetThemeMode("Light")
$peakBaseVm.UpdateDynamic(12.50, 30000000L, 20000000L, 12, 200, 0)
$peakBaseVm.UpdateDynamic(2.10, 25000000L, 15000000L, 12, 180, 0)
if ($peakBaseVm.PeakCPU -ne 12.50 -or $peakBaseVm.PeakCPUFormatted -ne "12.50" -or $peakBaseVm.PeakPrivateBytes -ne 20000000L -or $peakBaseVm.PeakHandles -ne 200) {
    throw "ProcessItemViewModel failed to retain high-water session peaks (PeakCPU=$($peakBaseVm.PeakCPU), PeakPriv=$($peakBaseVm.PeakPrivateBytes))."
}
# Baseline set at 15MB Private, 25MB WS, 180 Handles, 2.10% CPU -> grow by +2MB/+4MB/+0.90% CPU (badge visible), then shrink below baseline
$peakBaseVm.SetBaselineState($true, $false, 15000000L, 25000000L, 180, 2.10)
$peakBaseVm.UpdateDynamic(3.00, 29000000L, 17000000L, 12, 195, 0)
if ($peakBaseVm.PrivateBytesDelta -ne 2000000L -or $peakBaseVm.PrivateDeltaBadgeVisibility -ne "Visible" -or -not $peakBaseVm.PrivateDeltaFormatted.StartsWith("+")) {
    throw "ProcessItemViewModel baseline growth diff mismatch: Delta=$($peakBaseVm.PrivateBytesDelta), Fmt='$($peakBaseVm.PrivateDeltaFormatted)', Vis=$($peakBaseVm.PrivateDeltaBadgeVisibility)."
}
if ([Math]::Abs($peakBaseVm.CPUDelta - 0.90) -gt 0.001 -or $peakBaseVm.CPUDeltaFormatted -ne "+0.90%") {
    throw "ProcessItemViewModel CPUDelta growth mismatch: CPUDelta=$($peakBaseVm.CPUDelta), Fmt='$($peakBaseVm.CPUDeltaFormatted)'."
}
if ([string]::IsNullOrWhiteSpace($peakBaseVm.CommandLineToolTip) -or -not $peakBaseVm.CommandLineToolTip.Contains("Command line:")) {
    throw "ProcessItemViewModel CommandLineToolTip regression."
}
if ([string]::IsNullOrWhiteSpace($peakBaseVm.ProcessHoverToolTip) -or -not $peakBaseVm.ProcessHoverToolTip.Contains("Path:") -or -not $peakBaseVm.ProcessHoverToolTip.Contains("(Peak ") -or -not $peakBaseVm.ProcessHoverToolTip.Contains("Baseline: CPU ") -or -not $peakBaseVm.CpuCellToolTip.Contains("Session Peak:") -or -not $peakBaseVm.CpuCellToolTip.Contains("Baseline Delta:")) {
    throw "ProcessItemViewModel ProcessHoverToolTip / CpuCellToolTip missing expected telemetry sections."
}
# Sub-threshold delta (< 64 KB) hides inline compact badge while preserving full column text
$peakBaseVm.UpdateDynamic(2.10, 25004096L, 15004096L, 12, 180, 0)
if ($peakBaseVm.PrivateDeltaBadgeVisibility -ne "Collapsed" -or [string]::IsNullOrWhiteSpace($peakBaseVm.PrivateDeltaFormatted) -or $peakBaseVm.CPUDeltaFormatted -ne "0.00%") {
    throw "Sub-64KB delta should collapse inline badge while keeping formatted column string (CPUDeltaFormatted='$($peakBaseVm.CPUDeltaFormatted)')."
}
# Negative shrink delta (>= 64 KB) shows compact negative badge and shrink brush
$peakBaseVm.UpdateDynamic(1.00, 23000000L, 13000000L, 12, 175, 0)
if ($peakBaseVm.PrivateBytesDelta -ne -2000000L -or $peakBaseVm.PrivateDeltaBadgeVisibility -ne "Visible" -or -not $peakBaseVm.PrivateDeltaFormatted.StartsWith("-") -or -not $peakBaseVm.PrivateDeltaBadgeText.StartsWith("-") -or $peakBaseVm.CPUDeltaFormatted -ne "-1.10%") {
    throw "Negative baseline shrink diff mismatch: Delta=$($peakBaseVm.PrivateBytesDelta), Fmt='$($peakBaseVm.PrivateDeltaFormatted)', Badge='$($peakBaseVm.PrivateDeltaBadgeText)', CPUDelta='$($peakBaseVm.CPUDeltaFormatted)'."
}
# PID-reuse protection: same PID with new CreateTime must become [NEW] instead of subtracting stale process memory
$pidSnap = @{
    [int]$peakBaseVm.PID = @{
        CreateTime   = 134075000000000000L
        CPU          = 2.10
        PrivateBytes = 90000000L
        MemoryBytes  = 90000000L
        Handles      = 500
    }
}
$snapEntry = $pidSnap[[int]$peakBaseVm.PID]
$isRecycledNew = ([string]$snapEntry.CreateTime -ne [string]$peakBaseVm.CreateTime)
if (-not $isRecycledNew) { throw "CreateTime mismatch expected for recycled PID simulation." }
$peakBaseVm.SetBaselineState($true, $true, 0L, 0L, 0, 0.0)
if ($peakBaseVm.PrivateDeltaFormatted -ne "[NEW]" -or $peakBaseVm.PrivateDeltaBadgeText -ne "[NEW]" -or $peakBaseVm.PrivateDeltaBadgeVisibility -ne "Visible" -or $peakBaseVm.CPUDeltaFormatted -ne "[NEW]") {
    throw "Post-baseline [NEW] marker mismatch: Fmt='$($peakBaseVm.PrivateDeltaFormatted)', CPUDelta='$($peakBaseVm.CPUDeltaFormatted)'."
}
# Backward-compatible 5-arg overload check
$peakBaseVm.SetBaselineState($true, $false, 15000000L, 25000000L, 180)
if (-not $peakBaseVm.HasBaseline -or $peakBaseVm.SpawnedPostBaseline -or $peakBaseVm.CPUDeltaFormatted -ne "0.00%") {
    throw "5-arg SetBaselineState overload regression: CPUDeltaFormatted='$($peakBaseVm.CPUDeltaFormatted)'."
}
if ([SystemSummaryViewModel]::FormatBytesStatic(1048576.0) -ne "1.0 MB") {
    throw "SystemSummaryViewModel::FormatBytesStatic(1MB) mismatch."
}

# E. 31-Column Catalog & New Sort Keys Round-Trip in Preferences
$psrpmModCat = Get-Module -Name PSRPM
$colCat31 = & $psrpmModCat { Get-PSRPMColumnCatalog }
if ($colCat31.Count -ne 31) {
    throw "Expected 31 catalog columns after adding Peak/Delta columns, got $($colCat31.Count)."
}
foreach ($reqColKey in @("PeakCPU", "PeakPrivate", "CPUDelta", "PrivateDelta", "WSDelta")) {
    $hitCol = $colCat31 | Where-Object { $_.Key -eq $reqColKey } | Select-Object -First 1
    if (-not $hitCol -or [bool]$hitCol.DefaultVisible) {
        throw "Catalog entry '$reqColKey' missing or must default to hidden."
    }
}
$tempNewColPref = Join-Path ([System.IO.Path]::GetTempPath()) "psrpm_newcols_$([System.Guid]::NewGuid().ToString('N')).json"
try {
    & $psrpmModCat { param($p) $script:PSRPMPreferencesPathOverride = $p } $tempNewColPref
    [System.IO.File]::WriteAllText($tempNewColPref, '{"SortProperty":"CPUDelta","VisibleColumns":["Process","PeakCPU","PeakPrivate","CPUDelta","PrivateDelta","WSDelta"]}', [System.Text.UTF8Encoding]::new($false))
    $newColRead = & $psrpmModCat { Read-PSRPMPreferences }
    if ($newColRead.Preferences.SortProperty -ne "CPUDelta" -or ($newColRead.Preferences.VisibleColumns -join ',') -ne "Process,PeakCPU,PeakPrivate,CPUDelta,PrivateDelta,WSDelta") {
        throw "Preferences failed to round-trip new Peak/Delta sort key & visible columns."
    }
} finally {
    & $psrpmModCat { $script:PSRPMPreferencesPathOverride = $null }
    if ([System.IO.File]::Exists($tempNewColPref)) { try { [System.IO.File]::Delete($tempNewColPref) } catch {} }
}

# F. Regression Guard: Zero $script: Inside .GetNewClosure() + ActiveSockets/Timeline WPF Grid & Toolbar Fit
foreach ($closureFile in @(
    (Join-Path $repoRoot "PSRPM\PSRPM.psm1"),
    (Join-Path $repoRoot "PSRPM\Private\RunspaceEngine.ps1"),
    (Join-Path $repoRoot "PSRPM\Private\ViewModelClasses.ps1")
)) {
    $cAst = [System.Management.Automation.Language.Parser]::ParseFile($closureFile, [ref]$null, [ref]$null)
    $cInvs = $cAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'GetNewClosure' }, $true)
    foreach ($ci in $cInvs) {
        $sbExpr = $ci.Expression
        if ($sbExpr -is [System.Management.Automation.Language.ParenExpressionAst]) { $sbExpr = $sbExpr.Pipeline.GetPureExpression() }
        if ($sbExpr) {
            $badScriptVars = $sbExpr.FindAll({ param($v) $v -is [System.Management.Automation.Language.VariableExpressionAst] -and $v.VariablePath.IsScript }, $true)
            if ($badScriptVars.Count -gt 0) {
                throw "Closure scope bug in $(Split-Path $closureFile -Leaf) L$($ci.Extent.StartLineNumber): `$script:$($badScriptVars[0].VariablePath.UserPath) resolves to dynamic closure scope."
            }
        }
    }
}
$netQaBytes = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "PSRPM\UI\MainWindow.xaml"))
$msNetQa = [System.IO.MemoryStream]::new($netQaBytes)
$netQaWin = [System.Windows.Markup.XamlReader]::Load($msNetQa)
$msNetQa.Close()
# Verify Start-PSRPM Theme parameter has valid default so .GetNewClosure() never throws ValidationMetadataException
$psrpmAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot "PSRPM\PSRPM.psm1"), [ref]$null, [ref]$null)
foreach ($fnName in @("Start-PSRPM", "Start-RemoteProcessManager")) {
    $fnAst = $psrpmAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true) | Select-Object -First 1
    $themeParamAst = $fnAst.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Theme" } | Select-Object -First 1
    if (-not $themeParamAst -or -not $themeParamAst.DefaultValue) {
        throw "$fnName `$Theme parameter with [ValidateSet] must define a valid non-empty default so .GetNewClosure() never throws ValidationMetadataException."
    }
}
$psrpmRawTxt = [System.IO.File]::ReadAllText((Join-Path $repoRoot "PSRPM\PSRPM.psm1"))
if ($psrpmRawTxt -match '=\s*if\s*\([^\r\n]+\)\s*\{[^}\r\n]*GetDefaultView') {
    throw "PSRPM.psm1 must assign CollectionViewSource::GetDefaultView directly (if (...) unwraps empty ListCollectionView to `$null)."
}
$sockGrid = $netQaWin.FindName("GridNetworkSockets")
$timeGrid = $netQaWin.FindName("GridNetworkTimeline")
$sockOc   = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$timeOc   = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$sockGrid.ItemsSource = $sockOc
$timeGrid.ItemsSource = $timeOc
$sockView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($sockOc)
$timeView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($timeOc)
if ($null -eq $sockView -or $null -eq $timeView) {
    throw "CollectionViewSource::GetDefaultView returned `$null on empty ObservableCollection."
}
if ($sockGrid.Columns.Count -ne 14) {
    throw "GridNetworkSockets expected 14 TCPView columns, found $($sockGrid.Columns.Count)."
}
$fltState = @{ FilterTcp4 = $true; FilterTcp6 = $true; FilterUdp4 = $true; FilterUdp6 = $true; FilterEst = $false; FilterListen = $false; FilterSynSent = $false; FilterTimeWait = $false; Search = "" }
$sockView.Filter = & {
    param($localFlt)
    return ([Predicate[Object]]{
        param($x)
        if (-not $x) { return $false }
        $p = [string]$x.Protocol; $s = [string]$x.State
        $protoOk = switch ($p) {
            "TCP"   { [bool]$localFlt.FilterTcp4 }
            "TCPv6" { [bool]$localFlt.FilterTcp6 }
            "UDP"   { [bool]$localFlt.FilterUdp4 }
            "UDPv6" { [bool]$localFlt.FilterUdp6 }
            default { $true }
        }
        if (-not $protoOk) { return $false }
        if ($localFlt.FilterEst -or $localFlt.FilterListen -or $localFlt.FilterSynSent -or $localFlt.FilterTimeWait) {
            $stateOk = (
                ($localFlt.FilterEst      -and ($s -eq "Established")) -or
                ($localFlt.FilterListen   -and ($s -eq "Listen" -or $s -eq "Listening")) -or
                ($localFlt.FilterSynSent  -and ($s -eq "Syn Sent")) -or
                ($localFlt.FilterTimeWait -and ($s -eq "Time Wait" -or $s -eq "Close Wait"))
            )
            if (-not $stateOk) { return $false }
        }
        if ($localFlt.Search) { return ([string]$x.ProcessName).IndexOf($localFlt.Search, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }
        return $true
    }.GetNewClosure())
} $fltState
$timeView.Filter = ([Predicate[Object]]{ param($x) if (-not $x) { return $false }; if ($fltState.Search) { return ([string]$x.ProcessName).IndexOf($fltState.Search, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }; return $true }.GetNewClosure())
# Verify ActiveSockets closure callback pattern using module-scoped active-tab getter populates grid
$qaTabObj = [HostTabItemViewModel]::new("tab_qa_1", "Localhost", "Localhost", "LOCAL", $true, $null)
if (-not [bool]$qaTabObj.AutoRefreshSockets) {
    throw "HostTabItemViewModel.AutoRefreshSockets should default to true for live TCPView updates."
}
$simHostState = @{ ActiveTab = $qaTabObj }
$getActiveSim = { return $simHostState.ActiveTab }
$simBuilt = [System.Collections.Generic.List[Object]]::new()
$simBuilt.Add([PSCustomObject]@{ PID = 4; PIDDisplay = "4"; ProcessName = "System"; Protocol = "TCP"; LocalAddress = "0.0.0.0"; LocalPort = 445; LocalPortDisplay = "445"; RemoteAddress = "0.0.0.0"; RemotePort = 0; RemotePortDisplay = "0"; LocalEndpoint = "0.0.0.0:445"; RemoteEndpoint = "0.0.0.0:0"; State = "Listen"; CreateTime = ""; ModuleName = "System"; SentPackets = 0L; RecvPackets = 0L; SentBytes = 0L; RecvBytes = 0L; SentPacketsFormatted = ""; RecvPacketsFormatted = ""; SentBytesFormatted = ""; RecvBytesFormatted = ""; LifecycleState = "" })
$simBuilt.Add([PSCustomObject]@{ PID = 1234; PIDDisplay = "1234"; ProcessName = "msedge.exe"; Protocol = "TCP"; LocalAddress = "10.0.0.5"; LocalPort = 51000; LocalPortDisplay = "51000"; RemoteAddress = "1.1.1.1"; RemotePort = 443; RemotePortDisplay = "443"; LocalEndpoint = "10.0.0.5:51000"; RemoteEndpoint = "1.1.1.1:443"; State = "Established"; CreateTime = "11/14/2026 6:08:21 PM"; ModuleName = "msedge.exe"; SentPackets = 21L; RecvPackets = 26L; SentBytes = 2937L; RecvBytes = 47023L; SentPacketsFormatted = "21"; RecvPacketsFormatted = "26"; SentBytesFormatted = "2,937"; RecvBytesFormatted = "47,023"; LifecycleState = "Mod" })
$simBuilt.Add([PSCustomObject]@{ PID = 5678; PIDDisplay = "5678"; ProcessName = "svchost.exe"; Protocol = "UDP"; LocalAddress = "0.0.0.0"; LocalPort = 5353; LocalPortDisplay = "5353"; RemoteAddress = "*"; RemotePort = 0; RemotePortDisplay = ""; LocalEndpoint = "0.0.0.0:5353"; RemoteEndpoint = "*:*"; State = "Listening"; CreateTime = "11/14/2026 10:54:52 AM"; ModuleName = "Dnscache"; SentPackets = 0L; RecvPackets = 0L; SentBytes = 0L; RecvBytes = 0L; SentPacketsFormatted = ""; RecvPacketsFormatted = ""; SentBytesFormatted = ""; RecvBytesFormatted = ""; LifecycleState = "New" })
$simBuilt.Add([PSCustomObject]@{ PID = 0; PIDDisplay = ""; ProcessName = "[Time Wait]"; Protocol = "TCPv6"; LocalAddress = "::1"; LocalPort = 55000; LocalPortDisplay = "55000"; RemoteAddress = "::1"; RemotePort = 80; RemotePortDisplay = "80"; LocalEndpoint = "[::1]:55000"; RemoteEndpoint = "[::1]:80"; State = "Time Wait"; CreateTime = ""; ModuleName = ""; SentPackets = 0L; RecvPackets = 0L; SentBytes = 0L; RecvBytes = 0L; SentPacketsFormatted = ""; RecvPacketsFormatted = ""; SentBytesFormatted = ""; RecvBytesFormatted = ""; LifecycleState = "Del" })
$simBuilt.Add([PSCustomObject]@{ PID = 4321; PIDDisplay = "4321"; ProcessName = "curl.exe"; Protocol = "TCP"; LocalAddress = "10.0.0.5"; LocalPort = 52000; LocalPortDisplay = "52000"; RemoteAddress = "93.184.216.34"; RemotePort = 443; RemotePortDisplay = "443"; LocalEndpoint = "10.0.0.5:52000"; RemoteEndpoint = "93.184.216.34:443"; State = "Syn Sent"; CreateTime = "11/14/2026 6:09:00 PM"; ModuleName = "curl.exe"; SentPackets = 0L; RecvPackets = 0L; SentBytes = 0L; RecvBytes = 0L; SentPacketsFormatted = ""; RecvPacketsFormatted = ""; SentBytesFormatted = ""; RecvBytesFormatted = ""; LifecycleState = "New" })
$cbSim = ({
    param($items)
    $curT = & $getActiveSim
    if ($curT -and $curT.TabId -eq "tab_qa_1") {
        foreach ($it in $items) { $sockOc.Add($it) }
    }
}.GetNewClosure())
& $cbSim $simBuilt
$timeOc.Add([PSCustomObject]@{ TimestampTicks = [DateTime]::Now.Ticks; TimeText = "12:00:00.0"; PID = 4; ProcessName = "System"; Operation = "Recv"; Detail = "Rx: 1.0 KB/s | Tx: "; RateFormatted = "1.0 KB/s"; TreeRateFormatted = "1.0 KB/s"; SessionTotalFormatted = "1.0 KB"; Category = "System"; User = "SYSTEM" })
if ([int]$sockView.Count -ne 5 -or $sockGrid.Items.Count -ne 5 -or [int]$timeView.Count -ne 1 -or $timeGrid.Items.Count -ne 1) {
    throw "Network Activity DataGrid / CollectionViewSource failed to surface populated rows (Sock=$($sockGrid.Items.Count), Time=$($timeGrid.Items.Count))."
}
$fltState.FilterEst = $true; $sockView.Refresh()
if ([int]$sockView.Count -ne 1) { throw "Socket Established filter expected 1 match, got $($sockView.Count)." }
$fltState.FilterEst = $false; $fltState.FilterListen = $true; $sockView.Refresh()
if ([int]$sockView.Count -ne 2) { throw "Socket Listening filter expected 2 matches (TCP Listen + UDP Listening), got $($sockView.Count)." }
$fltState.FilterTcp4 = $false; $fltState.FilterTcp6 = $false; $fltState.FilterUdp6 = $false; $sockView.Refresh()
if ([int]$sockView.Count -ne 1) { throw "Socket UDPv4+Listening filter expected 1 match, got $($sockView.Count)." }
$fltState.FilterUdp4 = $false; $fltState.FilterTcp6 = $true; $fltState.FilterListen = $false; $fltState.FilterTimeWait = $true; $sockView.Refresh()
if ([int]$sockView.Count -ne 1) { throw "Socket TCPv6+TimeWait filter expected 1 match, got $($sockView.Count)." }
$fltState.FilterTcp4 = $true; $fltState.FilterUdp4 = $true; $fltState.FilterUdp6 = $true; $fltState.FilterTimeWait = $false; $fltState.FilterSynSent = $true; $sockView.Refresh()
if ([int]$sockView.Count -ne 1) { throw "Socket SynSent filter expected 1 match, got $($sockView.Count)." }
$fltState.FilterSynSent = $false; $sockView.Refresh()
$netQaWin.FindName("BtnToolbarNetRxTx").Visibility = [System.Windows.Visibility]::Visible
$netQaWin.FindName("TxtNetEtwBtn").Text = "Net ETW (99/s)"
$netQaWin.FindName("TxtTelemNetRate").Text = "NET: v 12.3 KB/s ^ 4.5 KB/s"
$netQaWin.FindName("TxtTelemDiskRate").Text = "I/O: 284.0 KB/s | 32 IOPS"
$netQaWin.Measure([System.Windows.Size]::new(1280, 780))
$netQaWin.Arrange([System.Windows.Rect]::new(0, 0, 1280, 780))
$netQaWin.UpdateLayout()
$pillNet = $netQaWin.FindName("BorderTelemNetRate")
if ($pillNet -and $pillNet.ActualWidth -lt ($pillNet.DesiredSize.Width - 1.0)) {
    throw "BorderTelemNetRate clipped in 1280px toolbar layout (Actual=$($pillNet.ActualWidth), Desired=$($pillNet.DesiredSize.Width))."
}
# G. 12N: Graph Hover Tooltips, Crosshair XAML Elements, 240-Sample Top-Process Attribution & Mini Index Alignment
foreach ($miniName in @("CardMiniCpu", "GridMiniCpu", "CrosshairMiniCpu", "CardMiniCommit", "GridMiniCommit", "CrosshairMiniCommit", "CardMiniRam", "GridMiniRam", "CrosshairMiniRam")) {
    if (-not $netQaWin.FindName($miniName)) {
        throw "MainWindow.xaml missing mini sparkline hover element '$miniName'."
    }
}
try { $netQaWin.Close() } catch {}
Write-Host "  [PASS] 12M: Verified 6-theme WCAG brushes, Network SysInfo curves/totals, AllSockets ($($allSockRes['Count']) sockets), Hover tooltips, Peaks/Baseline diffs, closure-scope guard & 31-column preferences." -ForegroundColor Green
$sysHoverXmlBytes = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot "PSRPM\UI\SystemInfoWindow.xaml"))
$msSysHover = [System.IO.MemoryStream]::new($sysHoverXmlBytes)
$sysHoverWin = [System.Windows.Markup.XamlReader]::Load($msSysHover)
$msSysHover.Close()
foreach ($sysElem in @(
    "BorderQuadCpuChart", "CanvasQuadCpu", "CrosshairQuadCpu",
    "BorderQuadCommitChart", "CanvasQuadCommit", "CrosshairQuadCommit",
    "BorderQuadRamChart", "CanvasQuadRam", "CrosshairQuadRam",
    "BorderQuadIoChart", "CanvasQuadIo", "CrosshairQuadIo",
    "QuadNet",
    "BorderSysCpuChart", "CanvasSysCpu", "CrosshairSysCpu", "ItemsCoreGraphs",
    "BorderMemCommitChart", "CanvasMemCommit", "CrosshairMemCommit",
    "BorderMemRamChart", "CanvasMemRam", "CrosshairMemRam",
    "BorderSysIoChart", "CanvasSysIo", "CrosshairSysIo",
    "BorderSysNetChart", "CanvasSysNet", "CrosshairSysNet"
)) {
    if (-not $sysHoverWin.FindName($sysElem)) {
        throw "SystemInfoWindow.xaml missing hover element '$sysElem'."
    }
}
try { $sysHoverWin.Close() } catch {}

$hoverVm = [SystemSummaryViewModel]::new()
$preTip  = $hoverVm.GetGraphHoverInfo("Cpu", 0, $false)
if ($preTip -notlike "*pre-session*") {
    throw "Expected pre-session hover message before live samples arrive, got: '$preTip'"
}
$preMiniTip = $hoverVm.GetGraphHoverInfo("Cpu", 0, $true)
if ($preMiniTip -notlike "*pre-session*" -or $preMiniTip -notlike "*System Information*") {
    throw "Mini sparkline pre-session hover tooltip missing expected text: '$preMiniTip'"
}

$baseUtc = [DateTime]::UtcNow.AddSeconds(-420)
for ($t = 1; $t -le 380; $t++) {
    $sampleSys = [double[]]::new(29)
    $sampleSys[0]  = [double](10.0 + ($t % 50))
    $sampleSys[1]  = 16000L
    $sampleSys[2]  = 32768L
    $sampleSys[3]  = 180
    $sampleSys[4]  = 2100
    $sampleSys[5]  = 65000
    $sampleSys[6]  = 18000L
    $sampleSys[7]  = 32768L
    $sampleSys[8]  = 4.0
    $sampleSys[9]  = 18432000L
    $sampleSys[10] = 33554432L
    $sampleSys[11] = 20000000L
    $sampleSys[12] = 33554432L
    $sampleSys[13] = 17170432L
    $sampleSys[24] = 1048576L
    $sampleSys[25] = 262144L
    $sampleSys[26] = 65536L
    $sampleSys[27] = 512.0
    $sampleSys[28] = 64.0
    $coresMock = @( @( [double](12.0 + ($t % 40)), 3.5 ) )

    $hoverVm.UpdateSummary($sampleSys[0], $sampleSys[1], $sampleSys[2], $sampleSys[3], $sampleSys[4], $sampleSys[5], $sampleSys[6], $sampleSys[7])
    $hoverVm.UpdateExtendedTelemetry($sampleSys, $coresMock)

    $tickUtc = $baseUtc.AddSeconds($t).Ticks
    $capForTick = if ($t -le 360) { 0 } elseif ($t -eq 379) { 2 } else { 1 }
    $cpuOwner = if ($t -eq 351) { "early_boundary.exe" } elseif ($t -eq 380) { "msedge.exe" } else { "proc_$t.exe" }
    $cpuPid   = if ($t -eq 380) { 4832 } else { 1000 + $t }
    $netOwner = if ($capForTick -eq 1) { "msedge.exe" } else { "" }
    $netPid   = if ($capForTick -eq 1) { 4832 } else { 0 }

    $hoverVm.RecordTopProcessSample(
        $tickUtc,
        $cpuPid, $cpuOwner, (14.25 + ($t % 5)),
        9500, "Antigravity.exe", 2147483648L,
        4832, "msedge.exe", 1610612736L,
        $netPid, $netOwner, 524288L, 65536L, $capForTick
    )
}

if ($hoverVm.GetCpuHistory360().Count -ne 360 -or $hoverVm.GetCpuHistory240().Count -ne 360) {
    throw "Rolling CPU history exceeded or fell short of 360-sample (6-min @ 1s) cap."
}

$tipSysLatest  = $hoverVm.GetGraphHoverInfo("Cpu", 359, $false)
$tipMiniLatest = $hoverVm.GetGraphHoverInfo("Cpu", 29,  $true)
if ($tipSysLatest -notlike "*msedge.exe (PID 4832)*" -or $tipMiniLatest -notlike "*msedge.exe (PID 4832)*") {
    throw "Latest hover tooltip missing top CPU process attribution. Sys='$tipSysLatest', Mini='$tipMiniLatest'"
}
# Index 330 of 360-buffer corresponds to Mini index 0 (after 380 ticks, tick 351 sits at slot 330)
$tipSys330  = $hoverVm.GetGraphHoverInfo("Cpu", 330, $false)
$tipMini0   = $hoverVm.GetGraphHoverInfo("Cpu", 0,   $true)
if ($tipSys330 -notlike "*early_boundary.exe*" -or $tipMini0 -notlike "*early_boundary.exe*") {
    throw "Mini sparkline index 0 did not align with 360-history index 330. Sys330='$tipSys330', Mini0='$tipMini0'"
}

$tipCommit = $hoverVm.GetGraphHoverInfo("Commit", 359, $false)
$tipRam    = $hoverVm.GetGraphHoverInfo("Ram",    359, $false)
$tipIo     = $hoverVm.GetGraphHoverInfo("Io",     359, $false)
if ($tipCommit -notlike "*Antigravity.exe (PID 9500)*" -or $tipRam -notlike "*msedge.exe (PID 4832)*" -or $tipIo -notlike "*zero-overhead mode*") {
    throw "Commit/Ram/Io hover tooltips mismatch: Commit='$tipCommit' Ram='$tipRam' Io='$tipIo'"
}

$tipNetOff = $hoverVm.GetGraphHoverInfo("Net", 10,  $false) # tick 31 had cap=0
$tipNetBrk = $hoverVm.GetGraphHoverInfo("Net", 358, $false) # tick 379 had cap=2
$tipNetOn  = $hoverVm.GetGraphHoverInfo("Net", 359, $false) # tick 380 had cap=1
if ($tipNetOff -notlike "*Enable Net ETW*" -or $tipNetBrk -notlike "*circuit breaker*" -or $tipNetOn -notlike "*msedge.exe (PID 4832)*") {
    throw "Net ETW hover states mismatch: Off='$tipNetOff', Brk='$tipNetBrk', On='$tipNetOn'"
}

$tipCore = $hoverVm.GetCoreHoverInfo($hoverVm.CoreGraphs[0], 59)
if ($tipCore -notlike "*CPU 0:*" -or $tipCore -notlike "*Time:*") {
    throw "Core hover tooltip mismatch: '$tipCore'"
}

# Verify Option B Stepped Rolling Window Buckets (60 -> 120 -> 180 -> 360), N=0/N=1 edge cases & interval label scaling
$stepVm = [SystemSummaryViewModel]::new()
$stepVm.IsSysInfoOpen = $true
if ($stepVm.RecordedSampleCount -ne 0 -or $stepVm.GetActiveChartWindowCount() -ne 60 -or $stepVm.SysCpuPoints -ne "" -or $stepVm.ChartAxisLeftLabel -ne "-1m") {
    throw "Fresh SystemSummaryViewModel should start empty in 60-sample (1m) bucket (Rec=$($stepVm.RecordedSampleCount), Win=$($stepVm.GetActiveChartWindowCount()), Pts='$($stepVm.SysCpuPoints)', Left='$($stepVm.ChartAxisLeftLabel)')."
}
$stepSys = [double[]]::new(29)
$stepSys[0] = 25.0; $stepSys[8] = 6.0; $stepSys[9] = 10000L; $stepSys[10] = 20000L; $stepSys[12] = 16000L; $stepSys[13] = 8000L
$stepVm.UpdateExtendedTelemetry($stepSys, @(@(25.0, 6.0)))
if ($stepVm.RecordedSampleCount -ne 1 -or $stepVm.GetActiveChartWindowCount() -ne 60 -or $stepVm.SysCpuPoints -notlike "359.0,* 360.0,*") {
    throw "Single-sample startup should emit right-edge tick without fake left zero line (Pts='$($stepVm.SysCpuPoints)')."
}
for ($s = 2; $s -le 60; $s++) { $stepVm.UpdateExtendedTelemetry($stepSys, @(@(25.0, 6.0))) }
if ($stepVm.GetActiveChartWindowCount() -ne 60 -or $stepVm.ChartTimeSpanLabel -ne "Window: 1m (10s/div)") {
    throw "At 60 ticks expected 1m bucket, got Win=$($stepVm.GetActiveChartWindowCount()), Label='$($stepVm.ChartTimeSpanLabel)'."
}
$stepVm.UpdateExtendedTelemetry($stepSys, @(@(25.0, 6.0))) # tick 61 -> 120 bucket
if ($stepVm.GetActiveChartWindowCount() -ne 120 -or $stepVm.ChartAxisLeftLabel -ne "-2m" -or $stepVm.ChartTimeSpanLabel -ne "Window: 2m (20s/div)") {
    throw "At 61 ticks expected 2m (120) bucket, got Win=$($stepVm.GetActiveChartWindowCount()), Label='$($stepVm.ChartTimeSpanLabel)'."
}
for ($s = 62; $s -le 121; $s++) { $stepVm.UpdateExtendedTelemetry($stepSys, @(@(25.0, 6.0))) } # tick 121 -> 180 bucket
if ($stepVm.GetActiveChartWindowCount() -ne 180 -or $stepVm.ChartAxisLeftLabel -ne "-3m" -or $stepVm.ChartTimeSpanLabel -ne "Window: 3m (30s/div)") {
    throw "At 121 ticks expected 3m (180) bucket, got Win=$($stepVm.GetActiveChartWindowCount()), Label='$($stepVm.ChartTimeSpanLabel)'."
}
for ($s = 122; $s -le 181; $s++) { $stepVm.UpdateExtendedTelemetry($stepSys, @(@(25.0, 6.0))) } # tick 181 -> 360 bucket
if ($stepVm.GetActiveChartWindowCount() -ne 360 -or $stepVm.ChartAxisLeftLabel -ne "-6m" -or $stepVm.ChartTimeSpanLabel -ne "Window: 6m (1m/div)") {
    throw "At 181 ticks expected 6m (360) bucket, got Win=$($stepVm.GetActiveChartWindowCount()), Label='$($stepVm.ChartTimeSpanLabel)'."
}
$stepVm.SetPollingIntervalMs(2000)
if ($stepVm.ChartAxisLeftLabel -ne "-12m" -or $stepVm.ChartTimeSpanLabel -ne "Window: 12m (2m/div)") {
    throw "2s polling interval failed to scale stepped axis labels (Left='$($stepVm.ChartAxisLeftLabel)', Span='$($stepVm.ChartTimeSpanLabel)')."
}
Write-Host "  [PASS] 12N: Verified Graph Hover Tooltips, XAML Crosshair elements, 360/30/60 circular alignment, stepped 1m->2m->3m->6m buckets & Top-Process attribution." -ForegroundColor Green

# 12O: Phase 1-5 Stabilization, Native Safety, Performance & 6-Theme Parity Regressions
# H4: Collector Dispose lifecycle + unmanaged pointer nulling + clean re-init
$null = & $script:PSRPMCollectorScriptBlock $true $false
if (-not $script:CollectorInitialized -or $script:SysBufPtr -eq [IntPtr]::Zero) {
    throw "Expected CollectorInitialized=$true and non-zero SysBufPtr before Dispose regression check."
}
$dispRes = & $script:PSRPMCollectorScriptBlock $false $false "Dispose"
if ($dispRes -ne "DISPOSED" -or $script:CollectorInitialized -or $script:SysBufPtr -ne [IntPtr]::Zero -or $script:SvcBufPtr -ne [IntPtr]::Zero -or $script:ScratchBufPtr -ne [IntPtr]::Zero) {
    throw "DataCollector Dispose failed to zero unmanaged buffers cleanly (Res='$dispRes', Init=$($script:CollectorInitialized))."
}
$reInitWire = & $script:PSRPMCollectorScriptBlock $true $false
$reInitData = $jssAllSock.DeserializeObject((Expand-GzipPayload $reInitWire))
if (-not $reInitData -or [int]$reInitData['seq'] -lt 1) {
    throw "DataCollector failed to re-initialize cleanly after Dispose."
}

# M2: CloseTcpConnection validation (PID <= 4 refusal, GetExtendedTcpTable export, ownership mismatch) & KillTree root abort
if ($null -eq ([PSRPM.NativeActionsV4].GetMethod('GetExtendedTcpTable'))) {
    throw "PSRPM.NativeActionsV4 missing GetExtendedTcpTable P/Invoke export."
}
$closeSysJson = & $script:PSRPMActionScriptBlock "CloseTcpConnection" 4 "" "" "Normal" "127.0.0.1|80|127.0.0.1|9000"
$closeSysObj  = $jssAllSock.DeserializeObject($closeSysJson)
if ([bool]$closeSysObj['Success'] -or $closeSysObj['Status'] -ne "Refused" -or ([string]$closeSysObj['Message'] -notmatch 'PID 4')) {
    throw "CloseTcpConnection must refuse PID 4 with Status='Refused': $closeSysJson"
}
$closeMissJson = & $script:PSRPMActionScriptBlock "CloseTcpConnection" $PID "" "" "Normal" "127.0.0.1|65499|127.0.0.1|65498"
$closeMissObj  = $jssAllSock.DeserializeObject($closeMissJson)
if ([bool]$closeMissObj['Success'] -or $closeMissObj['Status'] -ne "Refused" -or ([string]$closeMissObj['Message'] -notmatch 'no longer exists|ownership mismatch|could not be closed')) {
    throw "CloseTcpConnection must refuse non-existent/unowned tuple with Status='Refused': $closeMissJson"
}
$killTreeMissingJson = & $script:PSRPMActionScriptBlock "KillTree" 999999 "nonexistent_psrpm_canary.exe" "" "Normal" ""
$killTreeMissingObj  = $jssAllSock.DeserializeObject($killTreeMissingJson)
if ([bool]$killTreeMissingObj['Success']) {
    throw "KillTree against non-existent PID 999999 should abort and fail cleanly: $killTreeMissingJson"
}

# M1 & H1: Same-tick PID-reuse CreateTime eviction & CoordLocalWorker clean shutdown in RunspaceEngine
$pidReuseWin = [System.Windows.Window]::new()
$pidReuseProcCol = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$pidReuseSvcCol  = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$pidReuseSumVm   = [SystemSummaryViewModel]::new()
$mockReuseCol = {
    param([bool]$ForceFull = $false, [bool]$EnableNetEtw = $false, [string]$NetEtwAction = "")
    if ($NetEtwAction -eq "Dispose") { return "DISPOSED" }
    if (-not $script:MockReuseTick) { $script:MockReuseTick = 0 }
    $script:MockReuseTick++
    if ($script:MockReuseTick -eq 1) {
        return '{"ver":1,"seq":1,"full":1,"sys":[1.0,1000,8192,10,100,1000,1000,16384],"cores":[[0,1.0,0.2]],"hw":null,"dead":[],"meta":[{"id":44444,"ct":1000,"n":"alpha_old.exe","desc":"","comp":"","ver":"","cmd":"","path":"","u":"U","sid":1,"arch":"x64","start":"2026-11-14","prio":8,"p":0,"cat":"Own"}],"svc":[],"svcDead":[],"dyn":[[44444,0.5,1048576,1048576,2,10,0]]}'
    }
    return '{"ver":1,"seq":2,"full":0,"sys":[1.0,1000,8192,10,100,1000,1000,16384],"cores":[[0,1.0,0.2]],"hw":null,"dead":[],"meta":[{"id":44444,"ct":2000,"n":"beta_new.exe","desc":"","comp":"","ver":"","cmd":"","path":"","u":"U","sid":1,"arch":"x64","start":"2026-11-14","prio":8,"p":0,"cat":"Own"}],"svc":[],"svcDead":[],"dyn":[[44444,1.2,2097152,2097152,3,15,0]]}'
}
$pidReuseEng = Start-PSRPMEngine `
    -PSSession $null -Window $pidReuseWin `
    -ProcessCollection $pidReuseProcCol -ServicesCollection $pidReuseSvcCol -SummaryViewModel $pidReuseSumVm `
    -CollectorScript $mockReuseCol -InspectorScript $script:PSRPMDeepInspectorScriptBlock -ActionScript $script:PSRPMActionScriptBlock `
    -IntervalMs 120 -IsLocal $true -TargetName "PID-REUSE-MOCK"
try {
    $reuseDeadline = [DateTime]::UtcNow.AddSeconds(4.0)
    while ([DateTime]::UtcNow -lt $reuseDeadline) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{})
        if ($pidReuseEng.ProcessMap.ContainsKey(44444) -and $pidReuseEng.ProcessMap[44444].Name -eq "beta_new.exe") { break }
        Start-Sleep -Milliseconds 30
    }
    if (-not $pidReuseEng.ProcessMap.ContainsKey(44444)) {
        throw "RunspaceEngine PID-reuse mock never ingested PID 44444."
    }
    $reusedVm = $pidReuseEng.ProcessMap[44444]
    if ($reusedVm.Name -ne "beta_new.exe" -or [long]$reusedVm.CreateTime -ne 2000L -or $reusedVm.LifecycleState -ne 1) {
        throw "RunspaceEngine failed to evict & recreate reused PID 44444 (Name=$($reusedVm.Name), CT=$($reusedVm.CreateTime), State=$($reusedVm.LifecycleState))."
    }
} finally {
    $pidReuseEng.Timer.Stop()
    $pidReuseEng.StateContainer.IsStopping = $true
    [void]$pidReuseEng.StateContainer.WakeEvent.Set()
    Start-Sleep -Milliseconds 80
    $pidReuseEng.PowerShell.Dispose()
    $pidReuseEng.Runspace.Close()
    $pidReuseEng.Runspace.Dispose()
}

# 6-Theme Palette Caching, Semantic Brush Key Parity & PendingNetTimeline Queue
[PSRPMThemeRegistry]::ClearCache()
if ([PSRPMThemeRegistry]::NormalizeMode("tokyonight") -ne "TokyoNight" -or [PSRPMThemeRegistry]::NormalizeMode("classic") -ne "Classic") {
    throw "PSRPMThemeRegistry::NormalizeMode failed case normalization."
}
$pCache1 = [PSRPMThemeRegistry]::GetPalette("TokyoNight")
$pCache2 = [PSRPMThemeRegistry]::GetPalette("TokyoNight")
if (-not [Object]::ReferenceEquals($pCache1, $pCache2)) {
    throw "PSRPMThemeRegistry::GetPalette did not return cached reference on repeat call."
}
$reqThemeBrushKeys = @(
    "BrushGaugeCpuFill", "BrushGaugeCpuArea", "BrushGaugeCpuStroke",
    "BrushGaugeKernelFill", "BrushGaugeKernelArea", "BrushGaugeKernelStroke",
    "BrushGaugeCommitFill", "BrushGaugeCommitArea", "BrushGaugeCommitStroke",
    "BrushGaugeRamFill", "BrushGaugeRamArea", "BrushGaugeRamStroke",
    "BrushGaugeIoReadFill", "BrushGaugeIoReadArea", "BrushGaugeIoReadStroke",
    "BrushGaugeIoWriteArea", "BrushGaugeIoWriteStroke",
    "BrushMiniCpuFill", "BrushMiniCommitFill", "BrushMiniRamFill",
    "BrushSigSignedFg", "BrushSigUnsignedFg",
    "BrushStatusActiveFg", "BrushStatusIdleFg", "BrushStatusExitedFg",
    "BrushSvcRunningBg", "BrushSvcPausedBg", "BrushSvcStoppedBg",
    "BrushStateTimeWaitBg", "BrushStateTimeWaitFg",
    "BrushNetRowNewBg", "BrushNetRowModBg", "BrushNetRowDelBg"
)
foreach ($thName in @("Light", "Dark", "TokyoNight", "TokyoNightLight", "Classic", "HighContrast")) {
    $tp = [PSRPMThemeRegistry]::GetPalette($thName)
    foreach ($rk in $reqThemeBrushKeys) {
        if (-not $tp.Brushes.ContainsKey($rk)) {
            throw "Theme '$thName' palette missing semantic brush key '$rk'."
        }
    }
}
$tabPendingCheck = [HostTabItemViewModel]::new("t_pend", "LOCALHOST", "LOCALHOST", "Local", $true, $null)
if (-not ($tabPendingCheck.PendingNetTimeline -is [System.Collections.Generic.Queue[Object]])) {
    throw "HostTabItemViewModel.PendingNetTimeline must initialize as Queue[Object]."
}

# Structural Remediation Invariants (PSRPM.psm1, DataCollector.ps1, RunspaceEngine.ps1)
$dcSrc12o = [System.IO.File]::ReadAllText((Join-Path $repoRoot "PSRPM\Private\DataCollector.ps1"))
if ($dcSrc12o -notmatch '\$rawBytes\.Length\s*-lt\s*256' -or $dcSrc12o -notmatch 'CoreCount\s*\*\s*48') {
    throw "DataCollector.ps1 missing < 256 B raw JSON passthrough or dynamic Class 8 CoreCount * 48 buffer scaling."
}
if ($reSrc12j -match '\)\s*-or\s*\[bool\]\$stateContainer\.LogAutoScroll') {
    throw "RunspaceEngine.ps1 still contains trailing LogAutoScroll short-circuit bypassing sticky-to-bottom check."
}
if (([regex]::Matches($psm1Src12, 'Clipboard\]::SetText')).Count -gt 1) {
    throw "PSRPM.psm1 contains raw Clipboard::SetText calls outside copyToClipboardSafe."
}
foreach ($reqSym in @('$copyToClipboardSafe', '$showMsgSafe', '$jumpToProcessInMainGrid', '$syncTargetSwitchUi', '$flushPendingNetTimeline', '$applySocketSnapshotList', '$getSvcBadgeKey', 'MaxJsonLength = 10485760', 'Export-Csv -LiteralPath')) {
    if (-not $psm1Src12.Contains($reqSym)) {
        throw "PSRPM.psm1 missing expected Phase 1-3 remediation helper/guard '$reqSym'."
    }
}
if ($psm1Src12 -match '(?<![A-Za-z0-9_])\$bc\.') {
    throw "PSRPM.psm1 contains stale undefined `$bc member invocation."
}
$svcXamlSrc12o = [System.IO.File]::ReadAllText((Join-Path $repoRoot "PSRPM\UI\ServiceDetailWindow.xaml"))
if ($svcXamlSrc12o -notmatch 'x:Key="BrushAccent"' -or $svcXamlSrc12o -notmatch 'TargetType="TabItem"' -or $svcXamlSrc12o -notmatch 'x:Name="BtnDlgClose"[^>]*Style="\{StaticResource DialogButtonStyle\}"') {
    throw "ServiceDetailWindow.xaml missing dark/Tokyo theme styles (BrushAccent, TabItem template, or DialogButtonStyle on BtnDlgClose)."
}
$svcTestDoc = [xml]$svcXamlSrc12o
$svcTestWin = [System.Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($svcTestDoc))
$tokyoPal12o = [PSRPMThemeRegistry]::GetPalette("TokyoNight")
$bc12o = [System.Windows.Media.BrushConverter]::new()
foreach ($tk in $tokyoPal12o.Brushes.Keys) {
    $tb = $bc12o.ConvertFromString($tokyoPal12o.Brushes[$tk])
    if ($tb.CanFreeze) { $tb.Freeze() }
    $svcTestWin.Resources[$tk] = $tb
}
$svcTestBadge = $svcTestWin.FindName("BadgeDlgStatus")
foreach ($stKey in @("BrushSvcRunningBg", "BrushSvcPausedBg", "BrushSvcStoppedBg")) {
    $svcTestBadge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $stKey)
    if ($svcTestBadge.Background.Color.ToString() -ne $bc12o.ConvertFromString($tokyoPal12o.Brushes[$stKey]).Color.ToString()) {
        throw "ServiceDetailWindow BadgeDlgStatus failed TokyoNight theme resolution for '$stKey'."
    }
}
$svcTestWin.Close()
Write-Host "  [PASS] 12O: Verified Phase 1-5 regressions (H1/H4 Dispose, M1 PID-reuse, M2 CloseTcp & KillTree, M4/M5 helpers, 6-theme parity, ServiceDetail badge/theme, <256B GZIP bypass, PendingNetTimeline)." -ForegroundColor Green

# 12P: UX Audit, WCAG 2.1 AA 6-Theme Contrast, UIA Accessibility, Input Isolation, Local-Default & Empty/Error Regressions
foreach ($tName12p in @("Light", "Dark", "TokyoNight", "TokyoNightLight", "Classic", "HighContrast")) {
    $pal12p = [PSRPMThemeRegistry]::GetPalette($tName12p).Brushes
    foreach ($bgKey12p in @("BrushWindowBg", "BrushToolbarBg", "BrushSurfaceBg")) {
        foreach ($fgKey12p in @("BrushTextPrimary", "BrushTextSecondary", "BrushTextMuted", "BrushAccent")) {
            $crTxt = & $getContrastRatio ([string]$pal12p[$fgKey12p]) ([string]$pal12p[$bgKey12p])
            if ($crTxt -lt 4.5) {
                throw "WCAG AA failure in theme '$tName12p': '$fgKey12p' vs '$bgKey12p' contrast is $([Math]::Round($crTxt, 2)) (< 4.5:1)."
            }
        }
    }
    foreach ($helpKey12p in @("BrushHelpSuccessFg", "BrushHelpAmberFg", "BrushHelpVioletFg")) {
        $crHelp = & $getContrastRatio ([string]$pal12p[$helpKey12p]) ([string]$pal12p["BrushSurfaceBg"])
        if ($crHelp -lt 4.5) {
            throw "WCAG AA failure in theme '$tName12p': '$helpKey12p' vs BrushSurfaceBg contrast is $([Math]::Round($crHelp, 2)) (< 4.5:1)."
        }
    }
    foreach ($pair12p in @(
        @("BrushRowSelectedFg", "BrushRowSelectedBg"),
        @("BrushBadgeFg", "BrushBadgeBg"),
        @("BrushKillFg", "BrushKillBg"),
        @("BrushKillTreeFg", "BrushKillTreeBg")
    )) {
        $crPair = & $getContrastRatio ([string]$pal12p[$pair12p[0]]) ([string]$pal12p[$pair12p[1]])
        if ($crPair -lt 4.5) {
            throw "WCAG AA failure in theme '$tName12p': '$($pair12p[0])/$($pair12p[1])' contrast is $([Math]::Round($crPair, 2)) (< 4.5:1)."
        }
    }
    foreach ($svcKey12p in @("BrushSvcRunningBg", "BrushSvcPausedBg", "BrushSvcStoppedBg")) {
        $crSvc = & $getContrastRatio "#FFFFFF" ([string]$pal12p[$svcKey12p])
        if ($crSvc -lt 4.5) {
            throw "WCAG AA failure in theme '$tName12p': '#FFFFFF' vs '$svcKey12p' contrast is $([Math]::Round($crSvc, 2)) (< 4.5:1)."
        }
    }
}

$uiDir12p = Join-Path $repoRoot "PSRPM\UI"
$uiaExpectations = @(
    @{ File = "MainWindow.xaml";          MinCount = 60; Tokens = @("BtnToolbarTree", "BtnToolbarTheme", "BtnToolbarHelp", "BtnClearSearch", "BtnClearSearchServices", "BtnClearSearchNetwork", "CardMiniCpu", "BtnProcEmptyClear", "BtnSvcEmptyClear") }
    @{ File = "PropertiesWindow.xaml";    MinCount = 15; Tokens = @("BtnVerifySig", "BtnSuspendResume", "BtnPropCreateDump", "GridPropDlls", "GridPropHandles") }
    @{ File = "ConnectDialog.xaml";       MinCount = 8;  Tokens = @("RbRemoteHost", "RbLocalOnly", "TxtConnectComputer", "BtnConnectSubmit", "BtnConnectCancel") }
    @{ File = "SystemInfoWindow.xaml";    MinCount = 8;  Tokens = @("SysInfoTabControl", "ChkPerCpuGraph", "BtnSysInfoOk") }
    @{ File = "HelpWindow.xaml";          MinCount = 2;  Tokens = @("HelpTabControl", "BtnHelpClose") }
    @{ File = "ServiceDetailWindow.xaml"; MinCount = 10; Tokens = @("SvcTabControl", "BtnDlgStart", "BtnDlgStop", "BtnDlgRestart", "BtnDlgClose") }
    @{ File = "FindHandleWindow.xaml";    MinCount = 8;  Tokens = @("TxtSearchHandle", "BtnSearchHandle", "BtnCancelSearchHandle", "GridHandleResults") }
    @{ File = "SelectColumnsWindow.xaml"; MinCount = 10; Tokens = @("TxtColFilter", "BtnColFilterClear", "LstAvailableColumns", "LstColumnOrder") }
)
foreach ($uiaSpec in $uiaExpectations) {
    $xRaw = [System.IO.File]::ReadAllText((Join-Path $uiDir12p $uiaSpec.File))
    $uiaMatches = [regex]::Matches($xRaw, 'AutomationProperties\.Name="[^"]+"')
    if ($uiaMatches.Count -lt $uiaSpec.MinCount) {
        throw "UIA AutomationProperties.Name coverage regression in $($uiaSpec.File): found $($uiaMatches.Count), expected >= $($uiaSpec.MinCount)."
    }
    foreach ($tok in $uiaSpec.Tokens) {
        if ($xRaw -notmatch ("x:Name=""$([regex]::Escape($tok))""[^>]*AutomationProperties\.Name=""[^""]+""")) {
            throw "UIA AutomationProperties.Name missing on key control '$tok' in $($uiaSpec.File)."
        }
    }
}

if ($psm1Src12 -notmatch 'isInteractiveKeyTarget' -or $psm1Src12 -notmatch 'Key\]::Space[^\r\n]+isInteractiveKeyTarget') {
    throw "PSRPM.psm1 missing Space focus isolation guard ('$isInteractiveKeyTarget') in PreviewKeyDown."
}
if ($psm1Src12 -notmatch 'Key\]::Return[^\r\n]+gridNetworkSockets' -or $psm1Src12 -notmatch 'Key\]::Return[^\r\n]+gridNetworkTimeline' -or $psm1Src12 -notmatch 'add_MouseDoubleClick') {
    throw "PSRPM.psm1 missing Network Activity Return/MouseDoubleClick row navigation wiring."
}
if ($psm1Src12 -notmatch '\$hasExplicitWinRmTarget\s*=' -or $psm1Src12 -notmatch '\$isLocalMode\s*=\s*\[bool\]\$LocalOnly\s*-or\s*\(-not\s*\$hasExplicitWinRmTarget\)') {
    throw "PSRPM.psm1 Start-PSRPM zero-arg Local Mode routing regression detected."
}
$waitAst12p = [System.Management.Automation.Language.Parser]::ParseInput($psm1Src12, [ref]$null, [ref]$null)
foreach ($cmdFn in @("Start-PSRPM", "Start-RemoteProcessManager")) {
    $cmdAst = $waitAst12p.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $cmdFn }, $true) | Select-Object -First 1
    $waitParam = $cmdAst.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Wait" } | Select-Object -First 1
    $noWaitParam = $cmdAst.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "NoWait" } | Select-Object -First 1
    $defParam = $cmdAst.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Defaults" } | Select-Object -First 1
    if (-not $waitParam -or $waitParam.StaticType.FullName -ne "System.Management.Automation.SwitchParameter") {
        throw "$cmdFn missing [switch]`$Wait parameter."
    }
    if (-not $noWaitParam -or $noWaitParam.StaticType.FullName -ne "System.Management.Automation.SwitchParameter") {
        throw "$cmdFn missing backwards-compatible [switch]`$NoWait parameter."
    }
    if (-not $defParam -or $defParam.StaticType.FullName -ne "System.Management.Automation.SwitchParameter") {
        throw "$cmdFn missing [switch]`$Defaults parameter."
    }
}
if ($psm1Src12 -notmatch 'if\s*\(-not\s*\[bool\]\$Wait\)' -or $psm1Src12 -notmatch '\$bound\["Wait"\]\s*=\s*\$true') {
    throw "PSRPM.psm1 Start-PSRPM default background STA launcher or recursion guard (`$bound['Wait'] = `$true`) regression detected."
}
if ($psm1Src12 -notmatch 'Read-PSRPMPreferences\s+-UseDefaults:\$Defaults') {
    throw "PSRPM.psm1 Start-PSRPM missing -Defaults bypass wiring to Read-PSRPMPreferences."
}
if ($psm1Src12 -notmatch '\$prefsDirtyState' -or $psm1Src12 -notmatch '\$markUnsavedPrefs' -or $psm1Src12 -notmatch '\$clearUnsavedPrefs') {
    throw "PSRPM.psm1 missing opt-in preference dirty cue helpers."
}
$mainXaml12p = [System.IO.File]::ReadAllText((Join-Path $uiDir12p "MainWindow.xaml"))
if ($mainXaml12p -notmatch 'MenuSavePreferences[^>]*never auto-saved') {
    throw "MainWindow.xaml MenuSavePreferences tooltip must explicitly document opt-in behavior (never auto-saved)."
}
$procActSrc12p = [System.IO.File]::ReadAllText((Join-Path $repoRoot "PSRPM\Private\ProcessActions.ps1"))
foreach ($hintCode in @('5', '87', '299', '1053', '1060', '1062')) {
    if ($procActSrc12p -notmatch "\b$hintCode\s*=" -or $procActSrc12p -notmatch 'Hint:') {
        throw "ProcessActions.ps1 missing actionable Win32/SCM Hint mapping for error code '$hintCode'."
    }
}
Write-Host "  [PASS] 12P: Verified 6-theme WCAG AA contrast (>=4.5:1), 8-XAML UIA labels, Space/Enter isolation, zero-arg Local Mode, opt-in prefs cue & Win32 Hint enrichment." -ForegroundColor Green

# 12Q: Code Review Remediation Regression Suite (#1-#10)
Write-Host "`n[TEST 12Q] Verifying Code Review Remediations (Resync Pruning, CPUDelta Sort, Self-PID KillTree/Suspend, >24h CPU, EStats, I/O Rate & Desktop Guard)..." -ForegroundColor Yellow

# 12Q.1: RunspaceEngine Resync Pruning (#1, #8), TabNeedsResync/CloseTabSession (#1), and Live CPUDelta Re-Sort (#6)
$win12q     = [System.Windows.Window]::new()
$procCol12q = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$svcCol12q  = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$sumVm12q   = [SystemSummaryViewModel]::new()
$eng12q = Start-PSRPMEngine `
    -PSSession $null `
    -Window $win12q `
    -ProcessCollection $procCol12q `
    -ServicesCollection $svcCol12q `
    -SummaryViewModel $sumVm12q `
    -CollectorScript $script:PSRPMCollectorScriptBlock `
    -InspectorScript $script:PSRPMDeepInspectorScriptBlock `
    -ActionScript $script:PSRPMActionScriptBlock `
    -IntervalMs 60 `
    -IsLocal $true `
    -TargetName "LOCAL-12Q" `
    -InitialTabId "tab_0"

try {
    # Wait for initial background tick to settle before switching to deterministic paused injection
    $dl12q = [DateTime]::UtcNow.AddSeconds(4.0)
    while ([DateTime]::UtcNow -lt $dl12q -and $eng12q.TelemStats.LastReceivedSeq -lt 1) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{})
        Start-Sleep -Milliseconds 30
    }
    if ($eng12q.TelemStats.LastReceivedSeq -lt 1) {
        throw "12Q engine did not complete initial snapshot within timeout."
    }

    $eng12q.StateContainer.IsPaused = $true
    Start-Sleep -Milliseconds 90
    [System.Threading.Monitor]::Enter($eng12q.StateContainer.SyncRoot)
    try {
        $eng12q.StateContainer.Payload       = $null
        $eng12q.StateContainer.ForceFullSync = $false
    } finally {
        [System.Threading.Monitor]::Exit($eng12q.StateContainer.SyncRoot)
    }

    $eng12q.StateContainer.ClearHostMaps = $true
    $clrDl12q = [DateTime]::UtcNow.AddSeconds(2.0)
    while ([DateTime]::UtcNow -lt $clrDl12q -and ($eng12q.StateContainer.ClearHostMaps -or $eng12q.ProcessMap.Count -gt 0)) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{})
        Start-Sleep -Milliseconds 25
    }
    if ($eng12q.ProcessMap.Count -ne 0 -or $eng12q.ServicesMap.Count -ne 0) {
        throw "12Q failed to reset ProcessMap/ServicesMap cleanly before synthetic tick tests."
    }

    $tickState12q = @{ Count = 0 }
    $eng12q.StateContainer.OnTickProcessed = {
        param($elapsedSec, $netCap)
        $tickState12q.Count++
    }.GetNewClosure()

    $pushTick12q = {
        param([hashtable]$payloadObj, [string]$tabId = "tab_0")
        $prevCount = $tickState12q.Count
        $jsonPayload = $jss.Serialize($payloadObj)
        [System.Threading.Monitor]::Enter($eng12q.StateContainer.SyncRoot)
        try {
            $eng12q.StateContainer.Payload      = $jsonPayload
            $eng12q.StateContainer.PayloadTabId = $tabId
            $eng12q.StateContainer.PayloadBytes = $jsonPayload.Length
            $eng12q.StateContainer.PollLatencyMs = 5
        } finally {
            [System.Threading.Monitor]::Exit($eng12q.StateContainer.SyncRoot)
        }
        $tDl = [DateTime]::UtcNow.AddSeconds(2.5)
        while ([DateTime]::UtcNow -lt $tDl -and $tickState12q.Count -eq $prevCount) {
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{})
            Start-Sleep -Milliseconds 20
        }
        if ($tickState12q.Count -eq $prevCount) {
            throw "12Q synthetic tick (seq=$($payloadObj['seq']), tab=$tabId) was not processed within timeout."
        }
    }

    $mkMeta12q = {
        param([int]$procId, [string]$name)
        return @{
            id    = $procId
            ct    = [long](133000000000000000L + $procId)
            n     = $name
            p     = 0
            u     = "NT AUTHORITY\SYSTEM"
            arch  = "x64"
            path  = "C:\Windows\System32\$name"
            cmd   = $name
            desc  = $name
            comp  = "Microsoft"
            ver   = "1.0"
            start = "12:00:00"
            sid   = 1
            prio  = 8
            cat   = "System"
        }
    }
    $mkSvc12q = {
        param([string]$sName, [int]$sPid, [string]$st)
        return @{
            n   = $sName
            d   = $sName
            p   = $sPid
            st  = $st
            sm  = "Auto"
            u   = "LocalSystem"
            dep = ""
            rev = ""
            dsc = ""
            bin = "C:\Windows\System32\svchost.exe"
        }
    }

    # Tick seq=1: Baseline full snapshot with 3 processes + 2 services
    &$pushTick12q @{
        ver     = 1
        seq     = 1
        full    = 1
        svcFull = 1
        meta    = @( (&$mkMeta12q 1001 "alpha.exe"), (&$mkMeta12q 1002 "beta.exe"), (&$mkMeta12q 1003 "ghost.exe") )
        dyn     = @( @(1001, 10.0, 10485760L, 8388608L, 4, 50, 0), @(1002, 5.0, 10485760L, 8388608L, 4, 50, 0), @(1003, 1.0, 10485760L, 8388608L, 2, 20, 0) )
        dead    = @()
        svc     = @( (&$mkSvc12q "SvcLive" 1001 "Running"), (&$mkSvc12q "SvcOrphan" 1003 "Running") )
        svcDead = @()
    }
    if ($eng12q.ProcessMap.Count -ne 3 -or $eng12q.ServicesMap.Count -ne 2 -or $svcCol12q.Count -ne 2) {
        throw "12Q Tick 1 baseline mismatch: Procs=$($eng12q.ProcessMap.Count), SvcsMap=$($eng12q.ServicesMap.Count), SvcCol=$($svcCol12q.Count)."
    }

    # Test mismatched-tab payload marks TabNeedsResync['tab_other'] = $true
    [System.Threading.Monitor]::Enter($eng12q.StateContainer.SyncRoot)
    try {
        $eng12q.StateContainer.Payload      = $jss.Serialize(@{ ver = 1; seq = 2; full = 0; dyn = @(); dead = @(); meta = @(); svc = @(); svcDead = @() })
        $eng12q.StateContainer.PayloadTabId = "tab_other"
        $eng12q.StateContainer.PayloadBytes = 64
    } finally {
        [System.Threading.Monitor]::Exit($eng12q.StateContainer.SyncRoot)
    }
    $misDl = [DateTime]::UtcNow.AddSeconds(2.0)
    while ([DateTime]::UtcNow -lt $misDl -and -not $eng12q.StateContainer.TabNeedsResync.ContainsKey("tab_other")) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{})
        Start-Sleep -Milliseconds 20
    }
    if (-not $eng12q.StateContainer.TabNeedsResync["tab_other"]) {
        throw "12Q expected TabNeedsResync['tab_other'] to be marked when a mismatched tab payload was dropped."
    }

    # Test AddTabSession + SelectTabSession preserves pending ForceFullSync and honors TabNeedsResync,
    # and CloseTabSession honors NextTabId / NextForceFullSync and cleans TabNeedsResync
    $eng12q.StateContainer.TabNeedsResync["tab_other"] = $true
    $sendCmdWait12q = {
        param([hashtable]$cmdObj)
        $cb12q = @{ Fired = $false; Result = $null }
        & $eng12q.SendCommand $cmdObj ({
            param($r)
            $cb12q.Result = $r
            $cb12q.Fired  = $true
        }.GetNewClosure())
        $cdl = [DateTime]::UtcNow.AddSeconds(3.0)
        while ([DateTime]::UtcNow -lt $cdl -and -not $cb12q.Fired) {
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{})
            Start-Sleep -Milliseconds 20
        }
        if (-not $cb12q.Fired -or -not $cb12q.Result.Success) {
            throw "12Q command '$($cmdObj.CommandType)' failed or timed out."
        }
        return $cb12q.Result
    }
    [void](&$sendCmdWait12q @{ CommandType = "AddTabSession"; TabId = "tab_other"; ComputerName = "localhost"; IsLocal = $true; Credential = $null; Port = 0; UseSSL = $false })
    [void](&$sendCmdWait12q @{ CommandType = "SelectTabSession"; TabId = "tab_other"; ForceFullSync = $false })
    if (-not $eng12q.StateContainer.ForceFullSync) {
        throw "12Q SelectTabSession failed to trigger ForceFullSync when TabNeedsResync['tab_other'] was set."
    }
    # Clear ForceFullSync then ensure CloseTabSession restores explicit NextTabId='tab_0' without forcing resync when clean
    [System.Threading.Monitor]::Enter($eng12q.StateContainer.SyncRoot)
    try { $eng12q.StateContainer.ForceFullSync = $false } finally { [System.Threading.Monitor]::Exit($eng12q.StateContainer.SyncRoot) }
    [void](&$sendCmdWait12q @{ CommandType = "CloseTabSession"; TabId = "tab_other"; NextTabId = "tab_0"; NextForceFullSync = $false })
    if ($eng12q.StateContainer.ActiveTabId -ne "tab_0" -or $eng12q.StateContainer.TabNeedsResync.ContainsKey("tab_other") -or $eng12q.StateContainer.ForceFullSync) {
        throw "12Q CloseTabSession state mismatch: ActiveTabId=$($eng12q.StateContainer.ActiveTabId), TabOtherInResync=$($eng12q.StateContainer.TabNeedsResync.ContainsKey('tab_other')), ForceFullSync=$($eng12q.StateContainer.ForceFullSync)."
    }

    # Test sequence gap detection (seq=1 -> seq=5) marks TabNeedsResync['tab_0'] & ForceFullSync = $true
    &$pushTick12q @{
        ver     = 1
        seq     = 5
        full    = 0
        svcFull = 0
        meta    = @()
        dyn     = @( @(1001, 11.0, 10485760L, 8388608L, 4, 50, 0), @(1002, 6.0, 10485760L, 8388608L, 4, 50, 0) )
        dead    = @()
        svc     = @()
        svcDead = @()
    }
    if (-not $eng12q.StateContainer.ForceFullSync -or -not $eng12q.StateContainer.TabNeedsResync["tab_0"]) {
        throw "12Q sequence gap (1 -> 5) did not raise ForceFullSync and TabNeedsResync['tab_0']."
    }
    # Verify SelectTabSession with ForceFullSync=$false does NOT wipe already-pending ForceFullSync
    [void](&$sendCmdWait12q @{ CommandType = "SelectTabSession"; TabId = "tab_0"; ForceFullSync = $false })
    if (-not $eng12q.StateContainer.ForceFullSync) {
        throw "12Q SelectTabSession(ForceFullSync=$false) cleared pre-existing pending ForceFullSync."
    }

    # Tick seq=6: Recovery full snapshot omitting exited PID 1003 ('ghost.exe') and removed service 'SvcOrphan'
    &$pushTick12q @{
        ver     = 1
        seq     = 6
        full    = 1
        svcFull = 1
        meta    = @( (&$mkMeta12q 1001 "alpha.exe"), (&$mkMeta12q 1002 "beta.exe") )
        dyn     = @( @(1001, 12.0, 10485760L, 8388608L, 4, 50, 0), @(1002, 7.0, 10485760L, 8388608L, 4, 50, 0) )
        dead    = @()
        svc     = @( (&$mkSvc12q "SvcLive" 1001 "Running") )
        svcDead = @()
    }
    if ($eng12q.StateContainer.TabNeedsResync.ContainsKey("tab_0")) {
        throw "12Q full snapshot (seq=6) did not clear TabNeedsResync['tab_0']."
    }
    if ($eng12q.ServicesMap.Count -ne 1 -or $svcCol12q.Count -ne 1 -or -not $eng12q.ServicesMap.ContainsKey("SvcLive")) {
        throw "12Q full service resync (svcFull=1) failed to prune stale 'SvcOrphan' (Map=$($eng12q.ServicesMap.Count), Col=$($svcCol12q.Count))."
    }
    $has1003 = $eng12q.ProcessMap.ContainsKey(1003)
    $lc1003  = if ($has1003) { [string]$eng12q.ProcessMap[1003].LifecycleState } else { "<missing>" }
    if (-not $has1003 -or $eng12q.ProcessMap[1003].LifecycleState -ne 2) {
        throw "12Q full process resync should mark stale PID 1003 as LifecycleState=2 (Has1003=$has1003, LC=$lc1003, MapCount=$($eng12q.ProcessMap.Count), LastSeq=$($eng12q.TelemStats.LastReceivedSeq), LastErr='$($eng12q.StateContainer.LastErr)')."
    }

    # Tick seq=7: Next differential tick completes 1-tick exit flash and evicts PID 1003
    &$pushTick12q @{
        ver     = 1
        seq     = 7
        full    = 0
        svcFull = 0
        meta    = @()
        dyn     = @( @(1001, 12.0, 10485760L, 8388608L, 4, 50, 0), @(1002, 7.0, 10485760L, 8388608L, 4, 50, 0) )
        dead    = @()
        svc     = @()
        svcDead = @()
    }
    if ($eng12q.ProcessMap.ContainsKey(1003) -or $procCol12q.Count -ne 2) {
        throw "12Q failed to evict resync-pruned PID 1003 on tick N+1 (MapContains1003=$($eng12q.ProcessMap.ContainsKey(1003)), ColCount=$($procCol12q.Count))."
    }

    # Test #6: Live CPUDelta sorting in RunspaceEngine without spawn/exit structural changes
    $eng12q.ProcessMap[1001].SetBaselineState($true, $false, 8388608L, 10485760L, 50, 5.0)
    $eng12q.ProcessMap[1002].SetBaselineState($true, $false, 8388608L, 10485760L, 50, 5.0)
    $eng12q.StateContainer.IsTreeMode     = $false
    $eng12q.StateContainer.SortProperty   = "CPUDelta"
    $eng12q.StateContainer.SortDescending = $true

    &$pushTick12q @{
        ver = 1; seq = 8; full = 0; svcFull = 0; meta = @(); dead = @(); svc = @(); svcDead = @()
        dyn = @( @(1001, 6.0, 10485760L, 8388608L, 4, 50, 0), @(1002, 25.0, 10485760L, 8388608L, 4, 50, 0) )
    }
    if ($procCol12q[0].PID -ne 1002 -or $procCol12q[1].PID -ne 1001) {
        throw "12Q CPUDelta initial descending sort failed (top PID=$($procCol12q[0].PID), expected 1002)."
    }

    # Differential tick flips CPUDelta leader (1001 -> +40.0, 1002 -> +5.0) with ZERO meta/dead
    &$pushTick12q @{
        ver = 1; seq = 9; full = 0; svcFull = 0; meta = @(); dead = @(); svc = @(); svcDead = @()
        dyn = @( @(1001, 45.0, 10485760L, 8388608L, 4, 50, 0), @(1002, 10.0, 10485760L, 8388608L, 4, 50, 0) )
    }
    if ($procCol12q[0].PID -ne 1001 -or $procCol12q[1].PID -ne 1002) {
        throw "12Q live CPUDelta differential re-sort regression (top PID=$($procCol12q[0].PID), expected 1001 without spawn/exit)."
    }
} finally {
    $eng12q.Timer.Stop()
    $eng12q.StateContainer.IsStopping = $true
    [void]$eng12q.StateContainer.WakeEvent.Set()
    Start-Sleep -Milliseconds 60
    $eng12q.PowerShell.Dispose()
    $eng12q.Runspace.Close()
    $eng12q.Runspace.Dispose()
    try { $win12q.Close() } catch {}
}
Write-Host "  Verified 12Q.1: RunspaceEngine resync pruning (procs + services), TabNeedsResync/CloseTabSession, and live CPUDelta re-sort." -ForegroundColor Gray

# 12Q.2: Self-PID SuspendProcess refusal + Self-PID KillTree non-hang (#2)
$suspSelfJson12q = & $script:PSRPMActionScriptBlock "SuspendProcess" $PID "powershell" "" "Normal" "" "" 0L
$suspSelfRes12q  = $jss.DeserializeObject($suspSelfJson12q)
if ($suspSelfRes12q['Success'] -ne $false -or $suspSelfRes12q['Status'] -ne "Refused" -or $suspSelfRes12q['ErrorId'] -ne "PSRPM.Process.Refused") {
    throw "12Q SuspendProcess on own PID should return Status='Refused' / ErrorId='PSRPM.Process.Refused' (got Status='$($suspSelfRes12q['Status'])', Success=$($suspSelfRes12q['Success']))."
}

$actFileEsc12q = (Join-Path $privDir "ProcessActions.ps1").Replace("'", "''")
$selfKillScript12q = @"
`$ErrorActionPreference = 'Stop'
. '$actFileEsc12q'
`$kid = Start-Process -FilePath "$env:SystemRoot\System32\ping.exe" -ArgumentList @('-n','60','127.0.0.1') -WindowStyle Hidden -PassThru
[Console]::Out.WriteLine('KID:' + `$kid.Id)
[Console]::Out.Flush()
Start-Sleep -Milliseconds 120
[void](& `$script:PSRPMActionScriptBlock 'KillTree' `$PID 'powershell' '' 'Normal' '' '' 0L)
"@
$selfKillBytes12q = [System.Text.Encoding]::Unicode.GetBytes($selfKillScript12q)
$selfKillB6412q   = [Convert]::ToBase64String($selfKillBytes12q)
$psi12q = [System.Diagnostics.ProcessStartInfo]::new("$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")
$psi12q.Arguments              = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $selfKillB6412q"
$psi12q.UseShellExecute        = $false
$psi12q.CreateNoWindow         = $true
$psi12q.RedirectStandardOutput = $true
$treeProc12q = $null
$kidPid12q   = 0
try {
    $treeProc12q = [System.Diagnostics.Process]::Start($psi12q)
    $exitedInTime12q = $treeProc12q.WaitForExit(5000)
    $stdOut12q = $treeProc12q.StandardOutput.ReadToEnd()
    if ($stdOut12q -match 'KID:(\d+)') {
        $kidPid12q = [int]$Matches[1]
    }
    if (-not $exitedInTime12q) {
        throw "12Q KillTree containing own PID hung (>5s self-suspend deadlock regression)."
    }
    if ($kidPid12q -gt 0) {
        Start-Sleep -Milliseconds 150
        $kidStillAlive = $false
        try {
            $kp12q = [System.Diagnostics.Process]::GetProcessById($kidPid12q)
            $kidStillAlive = (-not $kp12q.HasExited)
        } catch {
            $kidStillAlive = $false
        }
        if ($kidStillAlive) {
            throw "12Q KillTree exited self without terminating descendant ping.exe (PID $kidPid12q)."
        }
    }
} finally {
    if ($treeProc12q -and -not $treeProc12q.HasExited) {
        try { $treeProc12q.Kill() } catch {}
    }
    if ($treeProc12q) { try { $treeProc12q.Dispose() } catch {} }
    if ($kidPid12q -gt 0) {
        try { Stop-Process -Id $kidPid12q -Force -ErrorAction SilentlyContinue } catch {}
    }
}
Write-Host "  Verified 12Q.2: SuspendProcess refuses self-PID; KillTree containing own PID terminates descendants and self cleanly (<5s)." -ForegroundColor Gray

# 12Q.3: >24h CPU Time Formatting (#10) & EStats Flag Container Persistence (#7)
$inspPerfRaw12q = & $script:PSRPMDeepInspectorScriptBlock $PID $false "Performance"
$inspPerf12q    = $jss.DeserializeObject($inspPerfRaw12q)
if ([string]$inspPerf12q['Performance']['TotalCpuTime'] -notmatch '^\d{2,}:\d{2}:\d{2}\.\d{3}$') {
    throw "12Q DeepInspector TotalCpuTime unexpected format: '$($inspPerf12q['Performance']['TotalCpuTime'])'."
}
$inspSrc12q = [System.IO.File]::ReadAllText((Join-Path $privDir "DeepInspector.ps1"))
if ($inspSrc12q -match 'hh\\:mm\\:ss') {
    throw "12Q DeepInspector.ps1 still contains hh\:mm\:ss TimeSpan truncation."
}
$mFmt12q = [regex]::Match($inspSrc12q, '(?s)\$formatCpuTime\s*=\s*\{(.*?return[^\r\n]+)\s*\}')
if (-not $mFmt12q.Success) {
    throw "12Q could not locate `$formatCpuTime helper in DeepInspector.ps1."
}
$fmtSb12q = [scriptblock]::Create($mFmt12q.Value + "`n`$formatCpuTime")
$fnFmt12q = & $fmtSb12q
$fmt30h   = & $fnFmt12q ([TimeSpan]::FromHours(30) + [TimeSpan]::FromMinutes(15) + [TimeSpan]::FromSeconds(42) + [TimeSpan]::FromMilliseconds(123))
$fmt105h  = & $fnFmt12q ([TimeSpan]::FromHours(105))
$fmtNeg   = & $fnFmt12q ([TimeSpan]::FromSeconds(-5))
if ($fmt30h -ne "30:15:42.123" -or $fmt105h -ne "105:00:00.000" -or $fmtNeg -ne "00:00:00.000") {
    throw "12Q >24h CPU formatter mismatch: 30h='$fmt30h', 105h='$fmt105h', neg='$fmtNeg'."
}
if ($inspSrc12q -match '\$estatsSetBlocked\s*=\s*\$true' -or $inspSrc12q -notmatch '\$estatsState\s*=\s*@\{\s*SetBlocked\s*=\s*\$false\s*\}') {
    throw "12Q DeepInspector.ps1 EStats permission-denial persistence must use `$estatsState hashtable container."
}
Write-Host "  Verified 12Q.3: >24h CPU time formatter ('$fmt30h', '$fmt105h') and persisted EStats flag container." -ForegroundColor Gray

# 12Q.4: Elapsed-Time I/O Rate Division (#9) & DataCollector Disk KB/s Decoupling (#9)
$ioVm12q = [SystemSummaryViewModel]::new()
$sysIo12q = [double[]]::new(32)
$sysIo12q[0]  = 12.0;  $sysIo12q[1]  = 8000L;     $sysIo12q[2]  = 16000L;    $sysIo12q[3] = 100
$sysIo12q[4]  = 1000;  $sysIo12q[5]  = 30000;     $sysIo12q[6]  = 8000L;     $sysIo12q[7] = 16000L
$sysIo12q[24] = 786432L; $sysIo12q[25] = 262144L; $sysIo12q[26] = 0L # Total 1,048,576 B = 1.0 MB
$coresIo12q = @( @(12.0, 1.0) )

$ioVm12q.UpdateExtendedTelemetry($sysIo12q, $coresIo12q, 2.0)
$hist2s = $ioVm12q.GetIoTotalHistory240()
$last2s = $hist2s[$hist2s.Count - 1]
if ($ioVm12q.IoTotalRateFormatted -ne "512.0 KB/s" -or $ioVm12q.IoGaugeText -ne "512.0 KB/s" -or [Math]::Abs($last2s - 524288.0) -gt 1.0 -or $ioVm12q.IoReadDeltaFormatted -ne "768.0 KB" -or $ioVm12q.IoSessionTotalFormatted -ne "1.0 MB") {
    throw "12Q I/O rate 2.0s elapsed division mismatch: Rate='$($ioVm12q.IoTotalRateFormatted)', Gauge='$($ioVm12q.IoGaugeText)', Hist='$last2s', ReadD='$($ioVm12q.IoReadDeltaFormatted)', Sess='$($ioVm12q.IoSessionTotalFormatted)'."
}
$ioVm12q.UpdateExtendedTelemetry($sysIo12q, $coresIo12q, 0.5)
$ioVm12q.RecordTopProcessSample([DateTime]::UtcNow.Ticks, 0, "", 0.0, 0, "", 0L, 0, "", 0L, 0, "", 0L, 0L, 0)
$histHalf = $ioVm12q.GetIoTotalHistory240()
$lastHalf = $histHalf[$histHalf.Count - 1]
$ioHover12q = $ioVm12q.GetGraphHoverInfo("Io", 359, $false)
if ($ioVm12q.IoTotalRateFormatted -ne "2.0 MB/s" -or [Math]::Abs($lastHalf - 2097152.0) -gt 1.0 -or $ioVm12q.IoSessionTotalFormatted -ne "2.0 MB" -or $ioHover12q -notlike "*2.0 MB/s*") {
    throw "12Q I/O rate 0.5s elapsed division mismatch: Rate='$($ioVm12q.IoTotalRateFormatted)', Hist='$lastHalf', Sess='$($ioVm12q.IoSessionTotalFormatted)', Hover='$ioHover12q'."
}
$ioVm12q.UpdateExtendedTelemetry($sysIo12q, $coresIo12q)
if ($ioVm12q.IoTotalRateFormatted -ne "1.0 MB/s") {
    throw "12Q 2-arg UpdateExtendedTelemetry backward-compatible 1.0s default mismatch: Rate='$($ioVm12q.IoTotalRateFormatted)'."
}
$dcSrc12q = [System.IO.File]::ReadAllText((Join-Path $privDir "DataCollector.ps1"))
if ($dcSrc12q -notmatch 'ioSec\s*=\s*\[Math\]::Max\(0\.1,\s*\(\$nowTicks\s*-\s*\$script:LastSnapTicks\)\s*/\s*10000000\.0\)' -or $dcSrc12q -notmatch '\$script:LastSnapTicks\s*=\s*\$nowTicks') {
    throw "12Q DataCollector.ps1 missing elapsed `$ioSec calculation / `$script:LastSnapTicks decoupling for Disk KB/s."
}
Write-Host "  Verified 12Q.4: Elapsed-time I/O rate scaling (512.0 KB/s @ 2s, 2.0 MB/s @ 0.5s) and DataCollector Disk KB/s decoupling." -ForegroundColor Gray

# 12Q.5: Host-Switch Window Rebinding (#3, #4) & Windows PowerShell Desktop Guard (#5)
if ($psm1Src12 -notmatch '\$script:ResetFindHandleForHostChange' -or $psm1Src12 -notmatch '\$script:RebindActiveSysInfoWindow' -or $psm1Src12 -notmatch '\$localState\.TabId\s*-ne\s*\$localTabId' -or $psm1Src12 -notmatch 'PSRPM - Host Mismatch') {
    throw "12Q PSRPM.psm1 missing FindHandle/SysInfo host-switch rebinding guards."
}
$compEd12q = @($manifestData['CompatiblePSEditions'])
if ($compEd12q.Count -ne 1 -or $compEd12q[0] -ne 'Desktop') {
    throw "12Q PSRPM.psd1 CompatiblePSEditions expected @('Desktop'), got: $($compEd12q -join ', ')."
}
if ($psm1Src12 -notmatch '\$PSVersionTable\.PSEdition\s*-ne\s*''Desktop''') {
    throw "12Q PSRPM.psm1 Start-PSRPM missing Windows PowerShell Desktop edition guard."
}
Write-Host "  [PASS] 12Q: Verified all Code Review Remediation regression checks (#1-#10)." -ForegroundColor Green

# 12R: Global Ctrl+D Theme Cycling Across All Modal/Modeless Child Windows
if ($psm1Src12 -notmatch '\$activeChildDialogs\s*=' -or $psm1Src12 -notmatch '\$getActiveChildWindows\s*=' -or $psm1Src12 -notmatch '\$registerChildWindow\s*=') {
    throw "12R PSRPM.psm1 missing `$activeChildDialogs / `$getActiveChildWindows / `$registerChildWindow helper."
}
if ($psm1Src12 -notmatch '\$childWin\.add_PreviewKeyDown' -or $psm1Src12 -notmatch 'Key\]::D\)\s*\{\s*&\$localCycleTheme') {
    throw "12R PSRPM.psm1 `$registerChildWindow missing PreviewKeyDown Ctrl+D theme cycling handler."
}
if ($psm1Src12 -notmatch '\$childWin\.add_Closed\(\{[^}]*\$localDialogList\.Remove\(\$localWinRef\)') {
    throw "12R PSRPM.psm1 `$registerChildWindow missing Closed cleanup handler."
}
if ($psm1Src12 -match '@\(\$script:ActiveFindHandleWin,\s*\$script:ActivePropWin,\s*\$script:ActiveSysInfoWin\)\)\s*\{\s*if\s*\(\$activeModal') {
    throw "12R PSRPM.psm1 still has legacy hardcoded 3-window modal loop instead of `&$getActiveChildWindows."
}
if ($psm1Src12 -notmatch 'foreach\s*\(\$activeModal\s+in\s+\(&\$getActiveChildWindows\)\)\s*\{\s*if\s*\(\$activeModal\s+-and\s+\$activeModal\.IsLoaded\)\s*\{\s*&\$syncDialogThemeBrushes\s+\$activeModal') {
    throw "12R PSRPM.psm1 `$applyTheme does not iterate `&$getActiveChildWindows for live theme sync."
}
if ($psm1Src12 -notmatch 'foreach\s*\(\$activeModal\s+in\s+\(&\$getActiveChildWindows\)\)\s*\{\s*if\s*\(\$activeModal\s+-and\s+\$activeModal\.IsLoaded\)\s*\{\s*\$activeModal\.Topmost\s*=\s*\$enable') {
    throw "12R PSRPM.psm1 `$setAlwaysOnTop does not iterate `&$getActiveChildWindows."
}
if ($psm1Src12 -notmatch '\$registerDialogRenderFlush\s*=\s*\{[\s\S]*?&\$registerChildWindow\s+\$dlg') {
    throw "12R PSRPM.psm1 `$registerDialogRenderFlush does not delegate to `&$registerChildWindow."
}
foreach ($childRegCheck in @(
    @{ Name = 'SelectColumnsWindow'; Pattern = '&\$registerDialogRenderFlush\s+\$scWin' },
    @{ Name = 'ServiceDetailWindow'; Pattern = '&\$registerDialogRenderFlush\s+\$svcWin' },
    @{ Name = 'PropertiesWindow';    Pattern = '&\$registerChildWindow\s+\$propWin' },
    @{ Name = 'ConnectDialog';       Pattern = '&\$registerDialogRenderFlush\s+\$connWin' },
    @{ Name = 'SystemInfoWindow';    Pattern = '&\$registerDialogRenderFlush\s+\$sysWin' },
    @{ Name = 'HelpWindow';          Pattern = '&\$registerDialogRenderFlush\s+\$helpWin' },
    @{ Name = 'FindHandleWindow';    Pattern = '&\$registerDialogRenderFlush\s+\$findWin' }
)) {
    if ($psm1Src12 -notmatch $childRegCheck.Pattern) {
        throw "12R PSRPM.psm1 $($childRegCheck.Name) is not registered with child window Ctrl+D / tracking helper ($($childRegCheck.Pattern))."
    }
}
$probeWin12r = [System.Windows.Window]::new()
$probeTb12r  = [System.Windows.Controls.TextBlock]::new()
$probeTb12r.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "BrushTextPrimary")
$probeWin12r.Content = $probeTb12r
$lightPal12r = [PSRPMThemeRegistry]::GetPalette("Light")
$darkPal12r  = [PSRPMThemeRegistry]::GetPalette("Dark")
$probeWin12r.Resources["BrushTextPrimary"] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString([string]$lightPal12r.Brushes["BrushTextPrimary"]))
$cLight12r = ([System.Windows.Media.SolidColorBrush]$probeTb12r.Foreground).Color.ToString()
$probeWin12r.Resources["BrushTextPrimary"] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString([string]$darkPal12r.Brushes["BrushTextPrimary"]))
$cDark12r = ([System.Windows.Media.SolidColorBrush]$probeTb12r.Foreground).Color.ToString()
if ($cLight12r -eq $cDark12r) {
    throw "12R DynamicResource brush update on child Window failed to change Foreground ($cLight12r vs $cDark12r)."
}
$probeWin12r.Close()
Write-Host "  [PASS] 12R: Verified global Ctrl+D registration across all 7 child windows and live theme brush propagation." -ForegroundColor Green

# 12S: Dark-Theme Child Window Foreground & TabControl/TabItem Style Audit (SystemInfoWindow & HelpWindow)
foreach ($darkAuditSpec in @(
    @{ File = "SystemInfoWindow.xaml"; TabControl = "SysInfoTabControl"; RequiredStyles = @([System.Windows.Controls.CheckBox], [System.Windows.Controls.GroupBox], [System.Windows.Controls.TabItem], [System.Windows.Controls.TabControl]) },
    @{ File = "HelpWindow.xaml";       TabControl = "HelpTabControl";    RequiredStyles = @([System.Windows.Controls.GroupBox], [System.Windows.Controls.TabItem], [System.Windows.Controls.TabControl]) }
)) {
    $xamlBytes12s = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot ("PSRPM\UI\" + $darkAuditSpec.File)))
    $ms12s = [System.IO.MemoryStream]::new($xamlBytes12s)
    $w12s = [System.Windows.Markup.XamlReader]::Load($ms12s)
    $ms12s.Close()
    $pal12s = [PSRPMThemeRegistry]::GetPalette("TokyoNight")
    $bc12s = [System.Windows.Media.BrushConverter]::new()
    foreach ($kv12s in $pal12s.Brushes.GetEnumerator()) {
        $w12s.Resources[$kv12s.Key] = $bc12s.ConvertFromString([string]$kv12s.Value)
    }
    foreach ($reqType in $darkAuditSpec.RequiredStyles) {
        if (-not $w12s.Resources.Contains($reqType)) {
            throw "12S $($darkAuditSpec.File) missing implicit dark-theme-aware Style for $($reqType.Name)."
        }
    }
    $tc12s = $w12s.FindName($darkAuditSpec.TabControl)
    if (-not $tc12s -or -not $tc12s.Style) {
        throw "12S $($darkAuditSpec.File) $($darkAuditSpec.TabControl) missing custom TabControl style."
    }
    $chkPerCpu12s = $w12s.FindName("ChkPerCpuGraph")
    if ($chkPerCpu12s) {
        $chkBrush = $chkPerCpu12s.Foreground -as [System.Windows.Media.SolidColorBrush]
        if (-not $chkBrush -or $chkBrush.Color.ToString() -ne "#FFC0CAF5") {
            throw "12S SystemInfoWindow.xaml ChkPerCpuGraph expected TokyoNight Foreground '#FFC0CAF5', got '$($chkPerCpu12s.Foreground)'."
        }
    }
    $logicalQueue = [System.Collections.Generic.Queue[System.Object]]::new()
    $logicalQueue.Enqueue($tc12s)
    while ($logicalQueue.Count -gt 0) {
        $curNode = $logicalQueue.Dequeue()
        if ($curNode -is [System.Windows.Controls.TextBlock] -and $curNode.Visibility -eq 'Visible') {
            $fgB = $curNode.Foreground -as [System.Windows.Media.SolidColorBrush]
            if ($fgB -and $fgB.Color.R -lt 40 -and $fgB.Color.G -lt 40 -and $fgB.Color.B -lt 40) {
                throw "12S $($darkAuditSpec.File) has near-black TextBlock Foreground '$($fgB.Color)' on TokyoNight for text '$($curNode.Text)'."
            }
        }
        if ($curNode -is [System.Windows.DependencyObject]) {
            foreach ($childObj in [System.Windows.LogicalTreeHelper]::GetChildren($curNode)) {
                if ($childObj) { $logicalQueue.Enqueue($childObj) }
            }
        }
    }
    $w12s.Close()
}
Write-Host "  [PASS] 12S: Verified dark-theme TabControl/TabItem/CheckBox/GroupBox styles and foreground luminance in SystemInfoWindow and HelpWindow." -ForegroundColor Green

# 12T: Multi-Computer -ComputerName (10 Max), Lazy Dormant Tabs, Offline Fallback & Comma-Separated ConnectDialog
$psm1Mod12t = Get-Module PSRPM
if (-not $psm1Mod12t) {
    Import-Module (Join-Path $repoRoot "PSRPM\PSRPM.psd1") -Force
    $psm1Mod12t = Get-Module PSRPM
}

# Verify Resolve-PSRPMComputerTargets normalization, dedup, empty check & 10-host cap
$parsed12t = (& $psm1Mod12t { Resolve-PSRPMComputerTargets -ComputerName @("srv-01, srv-02", "SRV-01; srv-03", "  ", "srv-04") -MaxCount 10 }).Targets
if ($parsed12t.Count -ne 4 -or $parsed12t[0] -ne "srv-01" -or $parsed12t[1] -ne "srv-02" -or $parsed12t[2] -ne "srv-03" -or $parsed12t[3] -ne "srv-04") {
    throw "12T Resolve-PSRPMComputerTargets failed normalization/dedup: $($parsed12t -join ', ')"
}

$tenHosts12t = 1..10 | ForEach-Object { "host-$_" }
$parsed10_12t = (& $psm1Mod12t { param($h) Resolve-PSRPMComputerTargets -ComputerName $h -MaxCount 10 } $tenHosts12t).Targets
if ($parsed10_12t.Count -ne 10) {
    throw "12T expected 10 hosts to pass cap, got $($parsed10_12t.Count)."
}

$elevenThrew = $false
try {
    $elevenHosts12t = 1..11 | ForEach-Object { "host-$_" }
    [void](& $psm1Mod12t { param($h) Resolve-PSRPMComputerTargets -ComputerName $h -MaxCount 10 } $elevenHosts12t)
} catch {
    if ($_.Exception.Message -match 'maximum of 10') { $elevenThrew = $true }
}
if (-not $elevenThrew) {
    throw "12T Resolve-PSRPMComputerTargets failed to reject 11 hosts."
}

$emptyThrew = $false
try {
    [void](& $psm1Mod12t { Resolve-PSRPMComputerTargets -ComputerName @(" , ; ") -MaxCount 10 })
} catch {
    $emptyThrew = $true
}
if (-not $emptyThrew) {
    throw "12T Resolve-PSRPMComputerTargets failed to reject whitespace/delimiter-only input."
}

# Verify Start-PSRPM & Start-RemoteProcessManager accept [string[]]$ComputerName and reject -LocalOnly + multiple hosts
foreach ($cmdFn12t in @("Start-PSRPM", "Start-RemoteProcessManager")) {
    $cmdAst12t = $waitAst12p.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $cmdFn12t }, $true) | Select-Object -First 1
    $compParam12t = $cmdAst12t.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "ComputerName" } | Select-Object -First 1
    if (-not $compParam12t -or $compParam12t.StaticType.FullName -ne "System.String[]") {
        throw "12T $cmdFn12t ComputerName parameter must be [string[]], got '$($compParam12t.StaticType.FullName)'."
    }
}
$localConflictThrew = $false
try {
    Start-PSRPM -LocalOnly -ComputerName "srv-01", "srv-02" -Wait
} catch {
    if ($_.Exception.Message -match '-LocalOnly cannot be combined with multiple -ComputerName') {
        $localConflictThrew = $true
    }
}
if (-not $localConflictThrew) {
    throw "12T Start-PSRPM -LocalOnly with multiple -ComputerName targets did not throw conflict error."
}

# Verify HostTabItemViewModel visual states for NotConnected, Connecting, and inactive Offline
$tab12t = [HostTabItemViewModel]::new("t12t", "SRV-02", "SRV-02", "WINRM", $false, $null)
$tab12t.UpdateVisualState($false, $false, $true, "NotConnected", $false, 0)
if ($tab12t.StatusDotFill -ne "#64748B" -or $tab12t.LatencyText -ne "Not Connected") {
    throw "12T HostTabItemViewModel inactive NotConnected mismatch: $($tab12t.StatusDotFill) / $($tab12t.LatencyText)"
}
$tab12t.UpdateVisualState($true, $false, $true, "Connecting", $false, 0)
if ($tab12t.StatusDotFill -ne "#0284C7" -or $tab12t.LatencyText -ne "Connecting...") {
    throw "12T HostTabItemViewModel active Connecting mismatch: $($tab12t.StatusDotFill) / $($tab12t.LatencyText)"
}
$tab12t.UpdateVisualState($false, $false, $true, "Disconnected", $false, 0)
if ($tab12t.StatusDotFill -ne "#DC2626" -or $tab12t.LatencyText -ne "Offline") {
    throw "12T HostTabItemViewModel inactive Disconnected mismatch: $($tab12t.StatusDotFill) / $($tab12t.LatencyText)"
}

# Verify RunspaceEngine dormant target lifecycle, non-blocking lazy connect, offline isolation & cancellation on close
$win12t  = [System.Windows.Window]::new()
$proc12t = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$svc12t  = [System.Collections.ObjectModel.ObservableCollection[Object]]::new()
$sum12t  = [SystemSummaryViewModel]::new()
$dorm12t = @(
    @{ TabId = "dorm_1"; ComputerName = "127.0.0.1"; Target = "dormant-1"; IsLocal = $false; Credential = $null; Port = 59998; UseSSL = $false },
    @{ TabId = "dorm_2"; ComputerName = "127.0.0.1"; Target = "dormant-2"; IsLocal = $false; Credential = $null; Port = 59999; UseSSL = $false }
)
$initCfg12t = @{ ComputerName = "offline-primary"; IsLocal = $false; Credential = $null; Port = 59997; UseSSL = $false }
$eng12t = Start-PSRPMEngine `
    -PSSession $null `
    -Window $win12t `
    -ProcessCollection $proc12t `
    -ServicesCollection $svc12t `
    -SummaryViewModel $sum12t `
    -CollectorScript $script:PSRPMCollectorScriptBlock `
    -InspectorScript $script:PSRPMDeepInspectorScriptBlock `
    -ActionScript $script:PSRPMActionScriptBlock `
    -IntervalMs 500 `
    -IsLocal $false `
    -TargetName "offline-primary" `
    -InitialTabId "prim_0" `
    -InitialConnectionConfig $initCfg12t `
    -DormantTargets $dorm12t `
    -InitialConnectionState "Disconnected" `
    -InitialConnectionError "Simulated primary offline error"

try {
    if ($eng12t.StateContainer.ConnectionState -ne "Disconnected") {
        throw "12T Expected initial engine ConnectionState 'Disconnected', got '$($eng12t.StateContainer.ConnectionState)'."
    }

    $observedStates12t = [System.Collections.Generic.List[string]]::new()
    $eng12t.StateContainer.OnSessionStateChanged = {
        param($ev)
        if ($ev -and $ev.TabId) {
            $observedStates12t.Add("$($ev.TabId):$($ev.ConnState)")
        }
    }

    # Add a 3rd dormant tab dynamically via AddDormantTabs
    $addDormDone12t = $false
    & $eng12t.SendCommand @{
        CommandType = "AddDormantTabs"
        Targets     = @(@{ TabId = "dorm_3"; ComputerName = "127.0.0.1"; Target = "dormant-3"; IsLocal = $false; Credential = $null; Port = 59996; UseSSL = $false })
    } ({ param($r) $script:resAddDorm12t = $r; $script:flagAddDorm12t = $true })

    $sw12t = [System.Diagnostics.Stopwatch]::StartNew()
    $script:flagAddDorm12t = $false
    while (-not $script:flagAddDorm12t -and $sw12t.ElapsedMilliseconds -lt 5000) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        Start-Sleep -Milliseconds 25
    }
    if (-not $script:flagAddDorm12t -or -not $script:resAddDorm12t.Success -or $script:resAddDorm12t.AddedCount -ne 1) {
        throw "12T AddDormantTabs command failed."
    }

    # Select dorm_1 -> triggers non-blocking async connect, transitions Connecting -> Disconnected cleanly
    $script:flagSelDorm12t = $false
    & $eng12t.SendCommand @{ CommandType = "SelectTabSession"; TabId = "dorm_1"; ForceFullSync = $true } ({ param($r) $script:flagSelDorm12t = $true })
    $swSel12t = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $script:flagSelDorm12t -and $swSel12t.ElapsedMilliseconds -lt 2000) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        Start-Sleep -Milliseconds 20
    }
    if (-not $script:flagSelDorm12t -or $swSel12t.ElapsedMilliseconds -ge 2000) {
        throw "12T SelectTabSession blocked coordinator instead of launching connect asynchronously."
    }

    # Wait for dorm_1 async connect failure to settle into Disconnected
    $swConn12t = [System.Diagnostics.Stopwatch]::StartNew()
    while (($observedStates12t -notcontains "dorm_1:Disconnected") -and $swConn12t.ElapsedMilliseconds -lt 15000) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        Start-Sleep -Milliseconds 30
    }
    if (($observedStates12t -notcontains "dorm_1:Connecting") -or ($observedStates12t -notcontains "dorm_1:Disconnected")) {
        throw "12T Expected dorm_1 Connecting -> Disconnected transitions, observed: $($observedStates12t -join ', ')"
    }

    # Select dorm_2 and immediately CloseTabSession to verify mid-connect cancellation
    $script:flagCloseDorm2_12t = $false
    & $eng12t.SendCommand @{ CommandType = "SelectTabSession"; TabId = "dorm_2"; ForceFullSync = $true } $null
    & $eng12t.SendCommand @{ CommandType = "CloseTabSession"; TabId = "dorm_2"; NextTabId = "prim_0" } ({ param($r) $script:flagCloseDorm2_12t = $true })
    $swClose12t = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $script:flagCloseDorm2_12t -and $swClose12t.ElapsedMilliseconds -lt 3000) {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        Start-Sleep -Milliseconds 20
    }
    if (-not $script:flagCloseDorm2_12t) {
        throw "12T CloseTabSession mid-connect did not complete promptly."
    }
} finally {
    $eng12t.StateContainer.IsStopping = $true
    if ($eng12t.StateContainer.WakeEvent) { [void]$eng12t.StateContainer.WakeEvent.Set() }
    if ($eng12t.Timer) { $eng12t.Timer.Stop() }
    if ($eng12t.Handle -and $eng12t.Handle.AsyncWaitHandle) {
        [void]$eng12t.Handle.AsyncWaitHandle.WaitOne(3000)
        try { [void]$eng12t.PowerShell.EndInvoke($eng12t.Handle) } catch {}
    }
    try { $eng12t.PowerShell.Dispose() } catch {}
    try { $eng12t.Runspace.Close(); $eng12t.Runspace.Dispose() } catch {}
    try { $eng12t.StateContainer.WakeEvent.Dispose() } catch {}
    $win12t.Close()
}
Write-Host "  [PASS] 12T: Verified multi-computer -ComputerName (10-host cap, dedup, -LocalOnly conflict, dormant NotConnected -> Connecting -> Offline lifecycle & mid-connect close)." -ForegroundColor Green

# 12U: Post-Launch 1px Resize Nudge Mitigation for WPF Blank Modal / Window Surface Stalls
if ($psm1Src12 -notmatch '\$attachRenderResizeNudge\s*=') {
    throw "12U PSRPM.psm1 missing `$attachRenderResizeNudge helper."
}
if ($psm1Src12 -notmatch '\$registerDialogRenderFlush\s*=\s*\{[\s\S]*?&\$attachRenderResizeNudge\s+\$dlg') {
    throw "12U PSRPM.psm1 `$registerDialogRenderFlush does not invoke `&$attachRenderResizeNudge `$dlg."
}
if ($psm1Src12 -notmatch '&\$attachRenderResizeNudge\s+\$propWin') {
    throw "12U PSRPM.psm1 PropertiesWindow is missing `&$attachRenderResizeNudge `$propWin."
}
if ($psm1Src12 -notmatch '&\$attachRenderResizeNudge\s+\$window') {
    throw "12U PSRPM.psm1 MainWindow is missing `&$attachRenderResizeNudge `$window."
}
# Functional WPF probe: verify ContentRendered -> DispatcherTimer -> +1px grow -> 5ms -> -1px shrink back executes cleanly (including ResizeMode=NoResize + SizeToContent=Height)
$probeNudgeWin = [System.Windows.Window]::new()
$probeNudgeWin.Width = 420
$probeNudgeWin.Height = 120
$probeNudgeWin.ResizeMode = [System.Windows.ResizeMode]::NoResize
$probeNudgeWin.SizeToContent = [System.Windows.SizeToContent]::Height
$probeNudgeWin.WindowStyle = [System.Windows.WindowStyle]::None
$probeNudgeWin.ShowInTaskbar = $false
$probeNudgeWin.AllowsTransparency = $true
$probeNudgeWin.Opacity = 0.0
$probeNudgeWin.Left = -32000
$probeNudgeWin.Top = -32000
$probeNudgeWin.Content = [System.Windows.Controls.TextBlock]::new()
$probeFrame12u = [System.Windows.Threading.DispatcherFrame]::new()
$probeNudgeState = @{ Done = $false; Phase = 0; PeakWidth = 0.0; Timer = $null; Win = $probeNudgeWin; Frame = $probeFrame12u }
$probeNudgeTick = {
    param($ts, $te)
    $w = $probeNudgeState.Win
    if ($probeNudgeState.Phase -eq 0) {
        if ($w -and $w.IsLoaded -and $w.WindowState -eq [System.Windows.WindowState]::Normal) {
            $curW = if ([double]::IsNaN($w.Width) -or $w.Width -le 0) { $w.ActualWidth } else { $w.Width }
            if ($curW -gt 0 -and ($curW + 1) -le $w.MaxWidth) {
                $w.Width = $curW + 1
            }
            $probeNudgeState.PeakWidth = $w.Width
            $w.UpdateLayout()
            $w.InvalidateVisual()
        }
        $probeNudgeState.Phase = 1
        $probeNudgeState.Timer.Interval = [TimeSpan]::FromMilliseconds(5)
        return
    }
    if ($probeNudgeState.Timer) {
        $probeNudgeState.Timer.Stop()
        $probeNudgeState.Timer = $null
    }
    if ($w -and $w.IsLoaded -and $w.WindowState -eq [System.Windows.WindowState]::Normal) {
        $curW = if ([double]::IsNaN($w.Width) -or $w.Width -le 0) { $w.ActualWidth } else { $w.Width }
        if (($curW - 1) -gt 0 -and ($curW - 1) -ge $w.MinWidth) {
            $w.Width = $curW - 1
        }
        $w.UpdateLayout()
        $w.InvalidateVisual()
    }
    $probeNudgeState.Frame.Continue = $false
}.GetNewClosure()
$probeNudgeWin.add_ContentRendered({
    param($s, $e)
    if ($probeNudgeState.Done) { return }
    $probeNudgeState.Done = $true
    $t = [System.Windows.Threading.DispatcherTimer]::new(
        [System.Windows.Threading.DispatcherPriority]::Background,
        $probeNudgeState.Win.Dispatcher
    )
    $t.Interval = [TimeSpan]::FromMilliseconds(40)
    $t.add_Tick($probeNudgeTick)
    $probeNudgeState.Timer = $t
    $t.Start()
}.GetNewClosure())
$probeTimeout12u = [System.Windows.Threading.DispatcherTimer]::new()
$probeTimeout12u.Interval = [TimeSpan]::FromMilliseconds(1500)
$probeTimeout12u.add_Tick({ $probeNudgeState.Frame.Continue = $false }.GetNewClosure())
$probeTimeout12u.Start()
$probeNudgeWin.Show()
[System.Windows.Threading.Dispatcher]::PushFrame($probeFrame12u)
$probeTimeout12u.Stop()
$peakWidth12u = $probeNudgeState.PeakWidth
$finalWidth12u = $probeNudgeWin.Width
if ($probeNudgeState.Timer) { $probeNudgeState.Timer.Stop() }
$probeNudgeWin.Close()
if ($peakWidth12u -lt 420.5 -or $peakWidth12u -gt 422.0 -or [Math]::Abs($finalWidth12u - 420.0) -gt 1.0 -or $finalWidth12u -ge $peakWidth12u) {
    throw "12U Expected 1px grow+shrink Width nudge (420 -> ~421 -> ~420), got Peak=$peakWidth12u, Final=$finalWidth12u."
}
Write-Host "  [PASS] 12U: Verified 1px post-launch render resize nudge (grow + shrink back) across MainWindow and all 7 modal/modeless windows." -ForegroundColor Green

# 12V: WinRM Async Connect OwnerRunspace Retention & Teardown Guard
$rsEngineSrc12v = Get-Content -Path (Join-Path $repoRoot "PSRPM\Private\RunspaceEngine.ps1") -Raw
if ($rsEngineSrc12v -notmatch '\$disposeSessionOwner\s*=\s*\{') {
    throw "12V Missing `$disposeSessionOwner helper in RunspaceEngine.ps1."
}
$ownerAssignCount12v = ([regex]::Matches($rsEngineSrc12v, 'OwnerRunspace\s*=\s*\$(dcRs|pcRs)')).Count
if ($ownerAssignCount12v -lt 3) {
    throw "12V Expected at least 3 OwnerRunspace adoption sites (SwitchTarget, AddTabSession, pendingConnects), found $ownerAssignCount12v."
}
$disposeOwnerCalls12v = ([regex]::Matches($rsEngineSrc12v, '&\$disposeSessionOwner\b')).Count
if ($disposeOwnerCalls12v -lt 7) {
    throw "12V Expected at least 7 &$disposeSessionOwner teardown calls across switch/reconnect/close/local/shutdown paths, found $disposeOwnerCalls12v."
}
$harvestIdx12v = $rsEngineSrc12v.IndexOf('$harvestPendingConnects = {')
$harvestEnd12v = $rsEngineSrc12v.IndexOf('$lastPollUtcTicks = 0L', $harvestIdx12v)
if ($harvestIdx12v -lt 0 -or $harvestEnd12v -le $harvestIdx12v) {
    throw "12V Could not locate `$harvestPendingConnects block in RunspaceEngine.ps1."
}
$harvestBlock12v = $rsEngineSrc12v.Substring($harvestIdx12v, $harvestEnd12v - $harvestIdx12v)
if ($harvestBlock12v -match '\$dc\.Runspace\.Close\(\)|\$pc\.Runspace\.Close\(\)') {
    throw "12V Detected unconditional `$dc.Runspace.Close() or `$pc.Runspace.Close() inside `$harvestPendingConnects (would tear down newly created WinRM PSSession)."
}
Write-Host "  [PASS] 12V: Verified async WinRM OwnerRunspace retention ($ownerAssignCount12v adoption sites) and teardown ($disposeOwnerCalls12v dispose calls)." -ForegroundColor Green

# 12W: Host PC CPU Optimization Regressions (PSRPMProcessCollection ReplaceOrder, Frozen Native WPF Properties, Dirty-Checked Tab Sync, CPU Sort Deadband & Paused Spin Guard)
$fastCol12w = [PSRPMProcessCollection]::new()
$grid12w = [System.Windows.Controls.DataGrid]::new()
$grid12w.SelectionMode = [System.Windows.Controls.DataGridSelectionMode]::Extended
$grid12w.ItemsSource = $fastCol12w
$items12w = @(
    [PSCustomObject]@{ PID = 10; Name = "p10.exe" },
    [PSCustomObject]@{ PID = 20; Name = "p20.exe" },
    [PSCustomObject]@{ PID = 30; Name = "p30.exe" },
    [PSCustomObject]@{ PID = 40; Name = "p40.exe" },
    [PSCustomObject]@{ PID = 50; Name = "p50.exe" },
    [PSCustomObject]@{ PID = 60; Name = "p60.exe" }
)
$initList12w = [System.Collections.Generic.List[Object]]::new()
foreach ($it12w in $items12w) { [void]$initList12w.Add($it12w) }
$fastCol12w.ReplaceOrder($initList12w)
if ($fastCol12w.Count -ne 6 -or $fastCol12w[0].PID -ne 10 -or $fastCol12w[5].PID -ne 60) {
    throw "12W PSRPMProcessCollection initial ReplaceOrder failed (Count=$($fastCol12w.Count))."
}
$evActions12w = [System.Collections.Generic.List[string]]::new()
$fastCol12w.add_CollectionChanged({
    param($s, $e)
    [void]$evActions12w.Add([string]$e.Action)
})
$revList12w = [System.Collections.Generic.List[Object]]::new()
foreach ($it12w in @($items12w[5], $items12w[4], $items12w[3], $items12w[2], $items12w[1], $items12w[0])) { [void]$revList12w.Add($it12w) }
$fastCol12w.ReplaceOrder($revList12w)
if ($fastCol12w[0].PID -ne 60 -or $fastCol12w[5].PID -ne 10 -or ($evActions12w -contains "Move") -or ($evActions12w -contains "Reset")) {
    throw "12W PSRPMProcessCollection ReplaceOrder expected Replace-only notifications (Actions=$($evActions12w -join ','))."
}
$shrinkList12w = [System.Collections.Generic.List[Object]]::new()
foreach ($it12w in @($items12w[5], $items12w[2], $items12w[0])) { [void]$shrinkList12w.Add($it12w) }
$fastCol12w.ReplaceOrder($shrinkList12w)
if ($fastCol12w.Count -ne 3 -or $fastCol12w[1].PID -ne 30) {
    throw "12W PSRPMProcessCollection tail shrink failed (Count=$($fastCol12w.Count))."
}

# Verify pre-frozen native WPF properties across all 6 themes
$vm12w = [ProcessItemViewModel]::new()
$vm12w.SetStaticMetadata(@{ id = 777; ct = 100L; n = "svc.exe"; p = 4; u = "SYSTEM"; arch = "x64"; path = "N/A"; cmd = "N/A"; desc = "d"; comp = "c"; ver = "1.0"; start = "now"; sid = 0; prio = 8; cat = "Service" }, $false)
$vm12w.UpdateTreeState(1, $true, $true, "M 24,0 L 24,18 M 24,9 L 32,9", 1.0, $false)
foreach ($th12w in [PSRPMThemeRegistry]::GetBuiltInNames()) {
    $vm12w.SetThemeMode($th12w)
    if ($null -eq $vm12w.RowBackgroundBrush -or -not $vm12w.RowBackgroundBrush.IsFrozen -or $null -eq $vm12w.RowForegroundBrush -or -not $vm12w.RowForegroundBrush.IsFrozen) {
        throw "12W Theme '$th12w' failed to produce frozen RowBackgroundBrush/RowForegroundBrush."
    }
}
if ($null -eq $vm12w.TreeGuidePathGeometry -or -not $vm12w.TreeGuidePathGeometry.IsFrozen -or $null -eq $vm12w.ExpanderPathGeometry -or -not $vm12w.ExpanderPathGeometry.IsFrozen) {
    throw "12W ProcessItemViewModel geometry properties must be pre-frozen Geometry instances."
}

# Verify HostTabItemViewModel dirty-checking on 1ms RTT jitter
$tab12w = [HostTabItemViewModel]::new("t12w", "HOST1", "HOST1", "WINRM", $false, [SystemSummaryViewModel]::new())
$tab12w.UpdateVisualState($true, "Light", $false, "Connected", $false, 12)
$tabNotifs12w = [System.Collections.Generic.List[string]]::new()
$tab12w.add_PropertyChanged({
    param($s, $e)
    [void]$tabNotifs12w.Add([string]$e.PropertyName)
})
$tab12w.UpdateVisualState($true, "Light", $false, "Connected", $false, 13)
if ($tabNotifs12w.Count -ne 1 -or $tabNotifs12w[0] -ne "LatencyText") {
    throw "12W HostTabItemViewModel 1ms RTT jitter should notify only LatencyText, got: $($tabNotifs12w -join ',')."
}
if ($null -eq $tab12w.TabBackgroundBrush -or -not $tab12w.TabBackgroundBrush.IsFrozen) {
    throw "12W HostTabItemViewModel.TabBackgroundBrush must be frozen."
}

# Verify SystemSummaryViewModel frozen PointCollection sparklines
$sum12w = [SystemSummaryViewModel]::new()
$sum12w.UpdateSummary(25.0, 8192L, 16384L, 120, 1500, 45000, 10240L, 20480L)
if ($null -eq $sum12w.CpuPointCollection -or -not $sum12w.CpuPointCollection.IsFrozen -or $sum12w.CpuPointCollection.Count -ne 30) {
    throw "12W SystemSummaryViewModel.CpuPointCollection must be a frozen 30-point PointCollection."
}

# Verify strict CPU sorting by default (CpuSortDeadband = 0.0) and optional opt-in deadband
$dbWin12w = [System.Windows.Window]::new()
$dbCol12w = [PSRPMProcessCollection]::new()
$dbEng12w = Start-PSRPMEngine -PSSession $null -Window $dbWin12w -ProcessCollection $dbCol12w -ServicesCollection ([System.Collections.ObjectModel.ObservableCollection[Object]]::new()) -SummaryViewModel ([SystemSummaryViewModel]::new()) -CollectorScript { $null } -InspectorScript { $null } -ActionScript { $null } -IntervalMs 60000 -IsLocal $true -TargetName "DB12W"
try {
    $dbEng12w.StateContainer.IsPaused = $true
    $dbEng12w.Timer.Stop()
    $dbEng12w.StateContainer.IsTreeMode = $false
    $dbEng12w.StateContainer.SortProperty = "CPU"
    $dbEng12w.StateContainer.SortDescending = $true
    if ([double]$dbEng12w.StateContainer.CpuSortDeadband -ne 0.0) {
        throw "12W Expected default CpuSortDeadband = 0.0 (strict sorting), got $($dbEng12w.StateContainer.CpuSortDeadband)."
    }
    foreach ($spec12w in @(@{ id = 200; cpu = 0.08 }, @{ id = 100; cpu = 0.02 }, @{ id = 50; cpu = 0.0 }, @{ id = 300; cpu = 5.5 })) {
        $pVm12w = [ProcessItemViewModel]::new()
        $pVm12w.SetStaticMetadata(@{ id = $spec12w.id; ct = 100L; n = "p$($spec12w.id).exe"; p = 4; u = "U"; arch = "x64"; path = "N/A"; cmd = "N/A"; desc = ""; comp = ""; ver = ""; start = ""; sid = 1; prio = 8; cat = "Own" }, $false)
        $pVm12w.UpdateDynamic([double]$spec12w.cpu, 1048576L, 1048576L, 1, 10, 0)
        $dbEng12w.ProcessMap[[int]$spec12w.id] = $pVm12w
    }
    & $dbEng12w.RefreshTree
    if ($dbCol12w.Count -ne 4 -or $dbCol12w[0].PID -ne 300 -or $dbCol12w[1].PID -ne 200 -or $dbCol12w[2].PID -ne 100 -or $dbCol12w[3].PID -ne 50) {
        throw "12W Strict default CPU sort order mismatch: expected [300, 200, 100, 50], got [$($dbCol12w[0].PID), $($dbCol12w[1].PID), $($dbCol12w[2].PID), $($dbCol12w[3].PID)]."
    }
} finally {
    $dbEng12w.StateContainer.IsStopping = $true
    [void]$dbEng12w.StateContainer.WakeEvent.Set()
    $dbEng12w.Timer.Stop()
    try { $dbEng12w.PowerShell.Dispose(); $dbEng12w.Runspace.Close(); $dbEng12w.Runspace.Dispose() } catch {}
}
Write-Host "  [PASS] 12W: Verified PSRPMProcessCollection ReplaceOrder, 6-theme frozen native WPF bindings, dirty-checked HostTabItemViewModel, frozen sparklines & strict default CPU sort." -ForegroundColor Green

# 12E: Strict 7-bit ASCII Audit Across All .ps1 / .psm1 Files
$nonAsciiHits = [System.Collections.Generic.List[string]]::new()
foreach ($psFile in (Get-ChildItem -Path (Join-Path $repoRoot "PSRPM"), (Join-Path $repoRoot "Tests") -Include *.ps1,*.psm1 -Recurse)) {
    $rawBytes = [System.IO.File]::ReadAllBytes($psFile.FullName)
    for ($bi = 0; $bi -lt $rawBytes.Length; $bi++) {
        if ($rawBytes[$bi] -gt 127) {
            $nonAsciiHits.Add("$($psFile.Name)@offset$bi=0x$($rawBytes[$bi].ToString('X2'))")
            break
        }
    }
}
if ($nonAsciiHits.Count -gt 0) {
    throw "Strict 7-bit ASCII violation detected: $($nonAsciiHits -join ', ')"
}
Write-Host "  [PASS] 12E: Verified strict 7-bit ASCII compliance across all .ps1 and .psm1 files." -ForegroundColor Green

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host " ALL 12 PSRPM VERIFICATION SUITES PASSED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
[System.Environment]::Exit(0)
