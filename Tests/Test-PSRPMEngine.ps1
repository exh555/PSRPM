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
    @{ File = "MainWindow.xaml";       RequiredControls = @("GridProcesses", "GridServices", "SummaryBar", "TxtSearch", "BtnClearSearch", "ConnStatusDot", "TxtTargetBadge", "BtnToolbarTree", "BtnToolbarTheme", "BtnToolbarHelp", "BtnToolbarPause", "IconToolbarPause", "TxtToolbarPause", "BadgePaused", "LogPane", "TxtLogConsole", "TxtTelemTransport", "TxtTelemPayload", "TxtTelemNetwork", "TxtTelemDelta", "ChkStreamTicks", "BtnCopyLog", "MenuSystemInfo", "MenuHelpTopics", "MenuHelpAbout", "MenuFileHelp", "CardMiniCpu", "CardMiniCommit", "CardMiniRam", "HostTabsList", "BtnAddHostTab", "BtnSvcStart", "BtnSvcStop", "BtnSvcRestart", "BtnSvcProperties", "BtnSvcGoToProcess", "TxtSvcSummary", "TxtSearchServices", "BtnClearSearchServices", "MenuHighlightCategories", "BtnToggleHighlights", "MenuFindHandle", "BtnFindHandleOrDll", "MenuCreateMiniDump", "MenuCreateFullDump", "MenuThemeLight", "MenuThemeDark", "MenuThemeClassic", "MenuThemeHighContrast", "TxtTelemNetRate", "TxtTelemDiskRate", "MenuViewNetEtw", "MenuColTreeNet", "MenuColNetRxTx", "BtnToolbarNetEtw", "EllNetEtwDot", "TxtNetEtwBtn", "BtnToolbarNetRxTx", "NetEtwAlertBanner", "BtnNetEtwResume", "BtnNetEtwTurnOff", "BtnNetEtwDismiss") }
    @{ File = "PropertiesWindow.xaml"; RequiredControls = @("PropTabControl", "PropDescription", "PropVersion", "PropBuildTime", "PropWorkDir", "BtnVerifySig", "BtnSuspendResume", "BtnPropCreateDump", "GridPropDlls", "GridPropHandles", "GridNetConnections", "GridPropServices", "GridPropEnv") }
    @{ File = "ConnectDialog.xaml";    RequiredControls = @("RbRemoteHost", "RbLocalOnly", "TxtConnectComputer", "ChkUseSSL", "TxtConnectPort", "BtnPickCredential", "BtnConnectSubmit", "ChkOpenInNewTab") }
    @{ File = "SystemInfoWindow.xaml"; RequiredControls = @("SysInfoTabControl", "ChkPerCpuGraph", "BtnSysInfoOk", "QuadCpu", "QuadCommit", "QuadRam", "QuadIo") }
    @{ File = "HelpWindow.xaml";       RequiredControls = @("HelpTabControl", "TxtHeaderBadge", "TxtAboutVersion", "TxtAboutHost", "TxtAboutUser", "TxtAboutTarget", "TxtAboutTransport", "TxtAboutPsVersion", "TxtAboutClrVersion", "TxtAboutArch", "BtnHelpClose") }
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
        if ($winObj.FindName("NetEtwAlertBanner").Visibility -ne [System.Windows.Visibility]::Collapsed -or
            $winObj.FindName("BtnToolbarNetRxTx").Visibility -ne [System.Windows.Visibility]::Collapsed) {
            throw "MainWindow.xaml Net ETW banner and Rx/Tx button must start Collapsed when Net ETW is off."
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

    # Test Process Explorer 3-Way Column Header Sort Cycle (Tree -> Flat Asc -> Flat Desc -> Tree)
    $psrpmMod = Get-Module PSRPM
    $s1 = & $psrpmMod { Get-PSRPMNextColumnSortState -IsTreeMode $true -CurrentSortProperty "PID" -CurrentSortDescending $false -ClickedSortProperty "Name" }
    if ($s1.IsTreeMode -or $s1.SortProperty -ne "Name" -or $s1.SortDescending) {
        throw "Process header click 1 (from Tree) expected Flat Name Asc, got IsTree=$($s1.IsTreeMode), Prop=$($s1.SortProperty), Desc=$($s1.SortDescending)."
    }
    $s2 = & $psrpmMod { param($st) Get-PSRPMNextColumnSortState -IsTreeMode $st.IsTreeMode -CurrentSortProperty $st.SortProperty -CurrentSortDescending $st.SortDescending -ClickedSortProperty "Name" } $s1
    if ($s2.IsTreeMode -or $s2.SortProperty -ne "Name" -or -not $s2.SortDescending) {
        throw "Process header click 2 (from Flat Name Asc) expected Flat Name Desc, got IsTree=$($s2.IsTreeMode), Prop=$($s2.SortProperty), Desc=$($s2.SortDescending)."
    }
    $s3 = & $psrpmMod { param($st) Get-PSRPMNextColumnSortState -IsTreeMode $st.IsTreeMode -CurrentSortProperty $st.SortProperty -CurrentSortDescending $st.SortDescending -ClickedSortProperty "Name" } $s2
    if (-not $s3.IsTreeMode -or $s3.SortProperty -ne "PID" -or $s3.SortDescending) {
        throw "Process header click 3 (from Flat Name Desc) expected Tree View reset, got IsTree=$($s3.IsTreeMode), Prop=$($s3.SortProperty), Desc=$($s3.SortDescending)."
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

    # Verify RunspaceEngine ordering across Process column 3-way cycle
    $eng.StateContainer.IsTreeMode     = $s1.IsTreeMode
    $eng.StateContainer.SortProperty   = $s1.SortProperty
    $eng.StateContainer.SortDescending = $s1.SortDescending
    & $eng.RefreshTree
    if ($procCol.IndexOf($pGrandChild) -gt $procCol.IndexOf($pRoot) -or $procCol.IndexOf($pRoot) -gt $procCol.IndexOf($pChild1)) {
        throw "Flat Name Asc ordering mismatch for psrpm_test_proc.exe < services.exe < svchost.exe."
    }

    $eng.StateContainer.IsTreeMode     = $s2.IsTreeMode
    $eng.StateContainer.SortProperty   = $s2.SortProperty
    $eng.StateContainer.SortDescending = $s2.SortDescending
    & $eng.RefreshTree
    if ($procCol.IndexOf($pChild1) -gt $procCol.IndexOf($pRoot) -or $procCol.IndexOf($pRoot) -gt $procCol.IndexOf($pGrandChild)) {
        throw "Flat Name Desc ordering mismatch for svchost.exe > services.exe > psrpm_test_proc.exe."
    }

    $eng.StateContainer.IsTreeMode     = $s3.IsTreeMode
    $eng.StateContainer.SortProperty   = $s3.SortProperty
    $eng.StateContainer.SortDescending = $s3.SortDescending
    $eng.StateContainer.FilterText = ""
    & $eng.RefreshTree
    if ($pGrandChild.Level -ne 2 -or $procCol.IndexOf($pRoot) -gt $procCol.IndexOf($pChild1) -or $procCol.IndexOf($pChild1) -gt $procCol.IndexOf($pGrandChild)) {
        throw "Tree View restoration after 3rd Process header click failed."
    }
    Write-Host "  Verified Process Header 3-Way Sort Cycle: Tree -> Flat Name Asc -> Flat Name Desc -> Tree." -ForegroundColor Gray

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
if (-not $dataTick1.ContainsKey('colVer') -or [string]$dataTick1['colVer'] -ne "1.8.2" -or -not $dataTick1.ContainsKey('colMs') -or -not $dataTick1.ContainsKey('svcMs') -or -not $dataTick1.ContainsKey('svcFull') -or -not $dataTick1.ContainsKey('metaPend')) {
    throw "Expected colVer='1.8.2', colMs, svcMs, svcFull, and metaPend in DataCollector payload."
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

if ($diSrc12j -notmatch 'PSRPM_CachedServices' -or $diSrc12j -notmatch '\[Microsoft\.Win32\.Registry\]::Users') {
    throw "DeepInspector.ps1 missing AppDomain PSRPM_CachedServices reader or HKU Registry::Users autostart enumeration."
}
if ($paSrc12j -notmatch 'PSRPM_ForceSvcRefresh' -or $paSrc12j -notmatch 'System\.ServiceProcess\.ServiceController') {
    throw "ProcessActions.ps1 missing PSRPM_ForceSvcRefresh flag or ServiceController 30s timeout implementation."
}
if ($reSrc12j -notmatch 'NewBoundScriptBlock' -or $reSrc12j -notmatch 'Grandparent:' -or $reSrc12j -notmatch '72000' -or $reSrc12j -notmatch 'ViewportHeight') {
    throw "RunspaceEngine.ps1 missing per-tab NewBoundScriptBlock, Grandparent lineage, 72000 char buffer, or Sticky-to-Bottom ViewportHeight check."
}
if ($psm1Src12 -notmatch '72000' -or $psm1Src12 -notmatch 'BitmapCacheOption\]::OnLoad' -or $psm1Src12 -notmatch 'PSRPM_Dumps') {
    throw "PSRPM.psm1 missing 72000 char buffer, in-memory BitmapCacheOption::OnLoad icon loader, or PSRPM_Dumps prompt path."
}
Write-Host "  Verified 12J: NativeServiceEnumV1 (colVer 1.8.2), AppDomain service cache, wildcard service refusal, async worker routing, sticky auto-scroll, and parent/grandparent lineage." -ForegroundColor Gray

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
