# Requires -Version 5.1
<#
.SYNOPSIS
    Standalone benchmark and verification test for PSRPM GZIP telemetry performance on client and remote target.
.DESCRIPTION
    Measures the exact network, CPU, and latency impact of PSRPM's GZIP + Base64 wire encoding
    on both the collector (remote target / isolated runspace) and the host client (decompression + JSON parse).

    Runs three phases:
      1. End-to-End Pipeline (GZIP ON): Real DataCollector.ps1 (Tick 1 full sync + N steady-state delta ticks).
      2. End-to-End Pipeline (GZIP OFF): In-memory raw JSON variant of DataCollector.ps1 for baseline comparison.
      3. Pure GZIP Microbenchmark: Isolates GZIP+Base64 compression cost on the target and decompression cost
         on the client across Full Sync, Steady-State Delta, and Minimal Idle payloads.
.PARAMETER ComputerName
    Optional remote target hostname to benchmark over a real WinRM PSSession.
    If omitted, runs the collector in an isolated background Runspace locally.
.PARAMETER Credential
    Optional PSCredential for the remote WinRM PSSession.
.PARAMETER UseSSL
    Use HTTPS/SSL for the WinRM PSSession.
.PARAMETER Ticks
    Number of steady-state differential ticks per phase (default: 10).
.PARAMETER IntervalMs
    Delay in milliseconds between steady-state ticks (default: 500).
.PARAMETER MicroIterations
    Base iterations for the pure compress/decompress microbenchmark (default: 2000;
    payloads under 8 KB automatically run at 5x this count for high-precision CPU measurement).
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-GzipPerformance.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-GzipPerformance.ps1 -ComputerName SRV-PROD-01 -Ticks 15 -IntervalMs 1000
#>
[CmdletBinding()]
param(
    [string]$ComputerName = "",
    [pscredential]$Credential = $null,
    [switch]$UseSSL,
    [int]$Ticks = 10,
    [int]$IntervalMs = 500,
    [int]$MicroIterations = 2000
)

$ErrorActionPreference = 'Stop'

if ($Ticks -lt 1) { $Ticks = 1 }
if ($IntervalMs -lt 50) { $IntervalMs = 50 }
if ($MicroIterations -lt 10) { $MicroIterations = 10 }

$repoRoot = Split-Path -Parent $PSScriptRoot
$collectorPath = Join-Path $repoRoot "PSRPM\Private\DataCollector.ps1"
if (-not (Test-Path -Path $collectorPath)) {
    throw "Could not find DataCollector.ps1 at '$collectorPath'."
}

Add-Type -AssemblyName System.Web.Extensions
$jss = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
$jss.MaxJsonLength = 10485760

function Expand-GzipPayload {
    param([string]$Payload)
    if (-not $Payload.StartsWith("GZIP:")) { return $Payload }
    $compBytes = [Convert]::FromBase64String($Payload.Substring(5))
    $ms = [System.IO.MemoryStream]::new($compBytes, $false)
    $gs = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $sr = [System.IO.StreamReader]::new($gs, [System.Text.Encoding]::UTF8)
    try {
        return $sr.ReadToEnd()
    } finally {
        $sr.Close()
        $gs.Close()
        $ms.Close()
    }
}

function Compress-GzipPayload {
    param([string]$JsonText)
    $rawBytes = [System.Text.Encoding]::UTF8.GetBytes($JsonText)
    $ms = [System.IO.MemoryStream]::new()
    $gs = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
    try {
        $gs.Write($rawBytes, 0, $rawBytes.Length)
        $gs.Close()
        return "GZIP:" + [Convert]::ToBase64String($ms.ToArray())
    } finally {
        $ms.Dispose()
    }
}

function New-TargetContext {
    param(
        [string]$CollectorCode,
        [string]$RemoteHost,
        [pscredential]$Cred,
        [switch]$Ssl
    )

    if ($RemoteHost) {
        $so = New-PSSessionOption -OpenTimeout 8000 -OperationTimeout 15000 -NoMachineProfile
        $sessParams = @{
            ComputerName  = $RemoteHost
            SessionOption = $so
            ErrorAction   = 'Stop'
        }
        if ($Cred) { $sessParams['Credential'] = $Cred }
        if ($Ssl)  { $sessParams['UseSSL']     = $true }

        $sess = New-PSSession @sessParams
        Invoke-Command -Session $sess -ScriptBlock {
            param($code)
            $script:PSRPMBenchCollector = [scriptblock]::Create($code)
        } -ArgumentList @($CollectorCode) -ErrorAction Stop

        $hostInfo = Invoke-Command -Session $sess -ScriptBlock {
            @{
                ComputerName = $env:COMPUTERNAME
                ProcName     = (Get-Process -Id $PID).ProcessName + ".exe"
                Pid          = $PID
            }
        } -ErrorAction Stop

        return [PSCustomObject]@{
            IsRemote    = $true
            Session     = $sess
            Runspace    = $null
            PowerShell  = $null
            TargetName  = [string]$hostInfo.ComputerName
            ProcessInfo = "$($hostInfo.ProcName) (PID $($hostInfo.Pid))"
        }
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $rs  = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript('param($code); $script:PSRPMBenchCollector = [scriptblock]::Create($code)').AddArgument($CollectorCode).Invoke()
    $ps.Commands.Clear()

    return [PSCustomObject]@{
        IsRemote    = $false
        Session     = $null
        Runspace    = $rs
        PowerShell  = $ps
        TargetName  = [string]$env:COMPUTERNAME
        ProcessInfo = "$((Get-Process -Id $PID).ProcessName).exe (PID $PID, Isolated Runspace)"
    }
}

function Close-TargetContext {
    param([PSCustomObject]$Ctx)
    if (-not $Ctx) { return }
    if ($Ctx.IsRemote) {
        if ($Ctx.Session) {
            try { Remove-PSSession -Session $Ctx.Session -ErrorAction SilentlyContinue } catch {}
        }
    } else {
        if ($Ctx.PowerShell) {
            try {
                $Ctx.PowerShell.Commands.Clear()
                [void]$Ctx.PowerShell.AddScript(@'
                    if ($script:SysBufPtr -and $script:SysBufPtr -ne [IntPtr]::Zero) {
                        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($script:SysBufPtr)
                        $script:SysBufPtr = [IntPtr]::Zero
                    }
                    if ($script:ScratchBufPtr -and $script:ScratchBufPtr -ne [IntPtr]::Zero) {
                        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($script:ScratchBufPtr)
                        $script:ScratchBufPtr = [IntPtr]::Zero
                    }
'@).Invoke()
            } catch {}
            try { $Ctx.PowerShell.Dispose() } catch {}
        }
        if ($Ctx.Runspace) {
            try { $Ctx.Runspace.Close(); $Ctx.Runspace.Dispose() } catch {}
        }
    }
}

function Invoke-TargetTick {
    param(
        [PSCustomObject]$Ctx,
        [bool]$ForceFull
    )
    if ($Ctx.IsRemote) {
        $res = Invoke-Command -Session $Ctx.Session -ScriptBlock {
            param($full)
            & $script:PSRPMBenchCollector $full
        } -ArgumentList @($ForceFull) -ErrorAction Stop
        return [string]$res
    } else {
        $Ctx.PowerShell.Commands.Clear()
        $res = $Ctx.PowerShell.AddScript('param($full); & $script:PSRPMBenchCollector $full').AddArgument($ForceFull).Invoke()
        if ($Ctx.PowerShell.HadErrors) {
            $errMsg = ($Ctx.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join "; "
            throw "Runspace collector error: $errMsg"
        }
        return [string]($res | Select-Object -First 1)
    }
}

function Get-TargetCpuMs {
    param([PSCustomObject]$Ctx)
    if ($Ctx.IsRemote) {
        return [double](Invoke-Command -Session $Ctx.Session -ScriptBlock {
            [System.Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime.TotalMilliseconds
        } -ErrorAction Stop)
    } else {
        return [double]([System.Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime.TotalMilliseconds)
    }
}

function Invoke-CollectorPhase {
    param(
        [string]$Label,
        [string]$CollectorCode,
        [bool]$ExpectGzip,
        [string]$RemoteHost,
        [pscredential]$Cred,
        [switch]$Ssl,
        [int]$SteadyTicks,
        [int]$TickDelayMs,
        [System.Web.Script.Serialization.JavaScriptSerializer]$Serializer
    )

    $swFreq = [double][System.Diagnostics.Stopwatch]::Frequency
    $ctx = $null
    $records = [System.Collections.Generic.List[PSCustomObject]]::new()
    $tick1Json = ""
    $sampleDeltaJson = ""

    try {
        $ctx = New-TargetContext -CollectorCode $CollectorCode -RemoteHost $RemoteHost -Cred $Cred -Ssl:$Ssl

        # Warm JIT / Type emission check & Tick 1 Full Sync
        $cpuStartAll = Get-TargetCpuMs -Ctx $ctx
        $swRtt1 = [System.Diagnostics.Stopwatch]::StartNew()
        $wire1 = Invoke-TargetTick -Ctx $ctx -ForceFull $true
        $swRtt1.Stop()
        $cpuAfterTick1 = Get-TargetCpuMs -Ctx $ctx

        if ($ExpectGzip -and -not $wire1.StartsWith("GZIP:")) {
            throw "[$Label] Expected 'GZIP:' prefix on Tick 1, got '$($wire1.Substring(0, [Math]::Min(16, $wire1.Length)))'."
        }
        if (-not $ExpectGzip -and $wire1.StartsWith("GZIP:")) {
            throw "[$Label] Expected raw JSON on Tick 1, but got 'GZIP:' prefix."
        }

        $swDec1 = [System.Diagnostics.Stopwatch]::StartNew()
        $json1 = if ($ExpectGzip) { Expand-GzipPayload -Payload $wire1 } else { $wire1 }
        $swDec1.Stop()

        $swParse1 = [System.Diagnostics.Stopwatch]::StartNew()
        $data1 = $Serializer.DeserializeObject($json1)
        $swParse1.Stop()

        if (-not $data1 -or $data1['meta'].Count -lt 1 -or $data1['svc'].Count -lt 1) {
            throw "[$Label] Tick 1 parsed payload missing expected processes or services."
        }

        $tick1Json = $json1
        $wireBytes1 = [System.Text.Encoding]::UTF8.GetByteCount($wire1)
        $rawBytes1  = [System.Text.Encoding]::UTF8.GetByteCount($json1)
        $saved1     = if ($rawBytes1 -gt 0) { (1.0 - ($wireBytes1 / [double]$rawBytes1)) * 100.0 } else { 0.0 }

        $tick1Obj = [PSCustomObject]@{
            Tick           = 1
            Seq            = [int]$data1['seq']
            WireBytes      = $wireBytes1
            RawBytes       = $rawBytes1
            SavedPct       = [Math]::Round($saved1, 1)
            RttMs          = [Math]::Round(($swRtt1.ElapsedTicks / $swFreq) * 1000.0, 2)
            DecompressMs   = if ($ExpectGzip) { [Math]::Round(($swDec1.ElapsedTicks / $swFreq) * 1000.0, 3) } else { 0.0 }
            JsonParseMs    = [Math]::Round(($swParse1.ElapsedTicks / $swFreq) * 1000.0, 3)
            TargetCpuMs    = [Math]::Round([Math]::Max(0.0, $cpuAfterTick1 - $cpuStartAll), 2)
            DynCount       = [int]$data1['dyn'].Count
            MetaCount      = [int]$data1['meta'].Count
        }

        # Steady-state ticks
        $cpuSteadyStart = Get-TargetCpuMs -Ctx $ctx
        for ($i = 1; $i -le $SteadyTicks; $i++) {
            Start-Sleep -Milliseconds $TickDelayMs

            $swRtt = [System.Diagnostics.Stopwatch]::StartNew()
            $wire = Invoke-TargetTick -Ctx $ctx -ForceFull $false
            $swRtt.Stop()

            if ($ExpectGzip -and -not $wire.StartsWith("GZIP:")) {
                throw "[$Label] Expected 'GZIP:' prefix on steady tick $i."
            }
            if (-not $ExpectGzip -and $wire.StartsWith("GZIP:")) {
                throw "[$Label] Expected raw JSON on steady tick $i."
            }

            $swDec = [System.Diagnostics.Stopwatch]::StartNew()
            $json = if ($ExpectGzip) { Expand-GzipPayload -Payload $wire } else { $wire }
            $swDec.Stop()

            $swParse = [System.Diagnostics.Stopwatch]::StartNew()
            $data = $Serializer.DeserializeObject($json)
            $swParse.Stop()

            if (-not $data -or -not $data.ContainsKey('seq')) {
                throw "[$Label] Steady tick $i failed JSON deserialization."
            }
            if (-not $sampleDeltaJson -or $json.Length -gt $sampleDeltaJson.Length -and $null -eq $data['svc']) {
                $sampleDeltaJson = $json
            }

            $wireBytes = [System.Text.Encoding]::UTF8.GetByteCount($wire)
            $rawBytes  = [System.Text.Encoding]::UTF8.GetByteCount($json)
            $savedPct  = if ($rawBytes -gt 0) { (1.0 - ($wireBytes / [double]$rawBytes)) * 100.0 } else { 0.0 }

            $records.Add([PSCustomObject]@{
                Tick         = $i + 1
                Seq          = [int]$data['seq']
                WireBytes    = $wireBytes
                RawBytes     = $rawBytes
                SavedPct     = $savedPct
                RttMs        = ($swRtt.ElapsedTicks / $swFreq) * 1000.0
                DecompressMs = if ($ExpectGzip) { ($swDec.ElapsedTicks / $swFreq) * 1000.0 } else { 0.0 }
                JsonParseMs  = ($swParse.ElapsedTicks / $swFreq) * 1000.0
                DynCount     = [int]$data['dyn'].Count
            })
        }
        $cpuSteadyEnd = Get-TargetCpuMs -Ctx $ctx
        $steadyCpuTotalMs = [Math]::Max(0.0, $cpuSteadyEnd - $cpuSteadyStart)

        $avgWire   = ($records | Measure-Object -Property WireBytes -Average).Average
        $avgRaw    = ($records | Measure-Object -Property RawBytes -Average).Average
        $avgRtt    = ($records | Measure-Object -Property RttMs -Average).Average
        $avgDec    = ($records | Measure-Object -Property DecompressMs -Average).Average
        $avgParse  = ($records | Measure-Object -Property JsonParseMs -Average).Average
        $avgSaved  = if ($avgRaw -gt 0) { (1.0 - ($avgWire / $avgRaw)) * 100.0 } else { 0.0 }
        $expandedCount = @($records | Where-Object { $_.WireBytes -gt $_.RawBytes }).Count
        $intervalSec = [Math]::Max(0.05, $TickDelayMs / 1000.0)

        return [PSCustomObject]@{
            Label             = $Label
            TargetName        = $ctx.TargetName
            ProcessInfo       = $ctx.ProcessInfo
            IsRemote          = $ctx.IsRemote
            Tick1             = $tick1Obj
            SteadyCount       = $records.Count
            AvgWireBytes      = [Math]::Round($avgWire, 0)
            AvgRawBytes       = [Math]::Round($avgRaw, 0)
            AvgWireKB         = [Math]::Round($avgWire / 1024.0, 2)
            AvgRawKB          = [Math]::Round($avgRaw / 1024.0, 2)
            BandwidthKBs      = [Math]::Round(($avgWire / 1024.0) / $intervalSec, 2)
            AvgSavedPct       = [Math]::Round($avgSaved, 1)
            AvgRttMs          = [Math]::Round($avgRtt, 2)
            SteadyCpuTotalMs  = [Math]::Round($steadyCpuTotalMs, 2)
            SteadyCpuPerTickMs = [Math]::Round($steadyCpuTotalMs / [Math]::Max(1, $records.Count), 3)
            AvgDecompressMs   = [Math]::Round($avgDec, 3)
            AvgJsonParseMs    = [Math]::Round($avgParse, 3)
            AvgClientTotalMs  = [Math]::Round($avgDec + $avgParse, 3)
            ExpandedTicks     = $expandedCount
            Tick1Json         = $tick1Json
            SampleDeltaJson   = $sampleDeltaJson
        }
    } finally {
        Close-TargetContext -Ctx $ctx
    }
}

# ------------------------------------------------------------------
# 1. Prepare Collector ScriptBlocks (Unmodified GZIP ON vs Raw OFF)
# ------------------------------------------------------------------
. $collectorPath
$gzipCollectorCode = $script:PSRPMCollectorScriptBlock.ToString()

$gzipTailPattern = '(?s)\$rawBytes\s*=\s*\[System\.Text\.Encoding\]::UTF8\.GetBytes\(\$sb\.ToString\(\)\).*?return\s+"GZIP:"\s*\+\s*\[Convert\]::ToBase64String\(\$ms\.ToArray\(\)\)\s*$'
if ($gzipCollectorCode -notmatch $gzipTailPattern) {
    throw "DataCollector.ps1 tail format changed; unable to construct GZIP-OFF baseline scriptblock."
}
$rawCollectorCode = [regex]::Replace(
    $gzipCollectorCode,
    $gzipTailPattern,
    "return `$sb.ToString()"
)

$transportLabel = if ($ComputerName) { "WinRM PSSession -> $ComputerName" } else { "Local Isolated Runspace (loopback simulation)" }

Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host " PSRPM GZIP Performance Benchmark (Client & Remote Target)" -ForegroundColor Cyan
Write-Host "========================================================================" -ForegroundColor Cyan
Write-Host " Client Host    : $env:COMPUTERNAME (PowerShell $($PSVersionTable.PSVersion))" -ForegroundColor Gray
Write-Host " Transport Mode : $transportLabel" -ForegroundColor Gray
Write-Host " Steady Ticks   : $Ticks ticks @ ${IntervalMs}ms interval | Microbench: $MicroIterations iters" -ForegroundColor Gray

# ------------------------------------------------------------------
# 1B. Warmup (Avoid Cold JIT / Reflection.Emit Skewing Phase 1 vs Phase 2)
# ------------------------------------------------------------------
$warmupJson = '{"ver":1,"seq":0,"sys":[0],"cores":[],"hw":null,"dead":[],"meta":[],"svc":null,"svcDead":[],"dyn":[]}'
$null = $jss.DeserializeObject($warmupJson)
$null = Expand-GzipPayload -Payload (Compress-GzipPayload -JsonText $warmupJson)
$warmCtx = $null
try {
    $warmCtx = New-TargetContext -CollectorCode $gzipCollectorCode -RemoteHost $ComputerName -Cred $Credential -Ssl:$UseSSL
    $null = Invoke-TargetTick -Ctx $warmCtx -ForceFull $true
} finally {
    Close-TargetContext -Ctx $warmCtx
}

# ------------------------------------------------------------------
# 2. Run End-to-End Phases
# ------------------------------------------------------------------
Write-Host "`n[Phase 1/3] Running End-to-End Collector with GZIP ON..." -ForegroundColor Yellow
$resGzip = Invoke-CollectorPhase -Label "GZIP ON" -CollectorCode $gzipCollectorCode -ExpectGzip $true `
    -RemoteHost $ComputerName -Cred $Credential -Ssl:$UseSSL -SteadyTicks $Ticks -TickDelayMs $IntervalMs -Serializer $jss

Write-Host "  Target: $($resGzip.TargetName) [$($resGzip.ProcessInfo)]" -ForegroundColor Gray
Write-Host "  Tick 1: Wire=$([Math]::Round($resGzip.Tick1.WireBytes/1024.0, 2)) KB vs Raw=$([Math]::Round($resGzip.Tick1.RawBytes/1024.0, 2)) KB ($($resGzip.Tick1.SavedPct)% saved) | RTT=$($resGzip.Tick1.RttMs) ms" -ForegroundColor Gray
Write-Host "  Steady: Avg Wire=$($resGzip.AvgWireKB) KB vs Raw=$($resGzip.AvgRawKB) KB ($($resGzip.AvgSavedPct)% saved) | Avg RTT=$($resGzip.AvgRttMs) ms | Expanded ticks=$($resGzip.ExpandedTicks)/$($resGzip.SteadyCount)" -ForegroundColor Gray

Write-Host "`n[Phase 2/3] Running End-to-End Collector with GZIP OFF (Raw JSON)..." -ForegroundColor Yellow
$resRaw = Invoke-CollectorPhase -Label "GZIP OFF" -CollectorCode $rawCollectorCode -ExpectGzip $false `
    -RemoteHost $ComputerName -Cred $Credential -Ssl:$UseSSL -SteadyTicks $Ticks -TickDelayMs $IntervalMs -Serializer $jss

Write-Host "  Tick 1: Wire=$([Math]::Round($resRaw.Tick1.WireBytes/1024.0, 2)) KB (Raw) | RTT=$($resRaw.Tick1.RttMs) ms" -ForegroundColor Gray
Write-Host "  Steady: Avg Wire=$($resRaw.AvgWireKB) KB (Raw) | Avg RTT=$($resRaw.AvgRttMs) ms" -ForegroundColor Gray

# ------------------------------------------------------------------
# 3. Pure GZIP Microbenchmark (Remote Compress vs Client Decompress)
# ------------------------------------------------------------------
Write-Host "`n[Phase 3/3] Benchmarking Pure GZIP Compress (Target) vs Decompress (Client)..." -ForegroundColor Yellow

$sampleFullJson  = $resGzip.Tick1Json
$sampleDeltaJson = if ($resGzip.SampleDeltaJson) { $resGzip.SampleDeltaJson } else {
    '{"ver":1,"colVer":"1.6.3","seq":10,"full":0,"sys":[4.2,9120,16384,180,2210,75200,11400,24576],"cores":[[0,5.1,1.2],[1,3.3,0.9]],"hw":null,"dead":[],"meta":[],"svc":null,"svcDead":[],"dyn":[[4,0.12,356352,184320,162,3290,0],[5748,0.45,14827520,4915200,6,184,0]]}'
}
$sampleIdleJson = '{"ver":1,"colVer":"1.6.3","seq":99,"full":0,"sys":[1.1,8100,16384,170,2000,70000,10200,24576],"cores":[[0,1.0,0.4]],"hw":null,"dead":[],"meta":[],"svc":null,"svcDead":[],"dyn":[]}'

# Verify exact round-trip fidelity before timing
$rtWire = Compress-GzipPayload -JsonText $sampleFullJson
$rtBack = Expand-GzipPayload -Payload $rtWire
if ($rtBack -ne $sampleFullJson) {
    throw "GZIP round-trip fidelity check failed! Decompressed text differed from original JSON."
}

$targetBenchScript = {
    param([string]$JsonPayload, [int]$Iters)
    $proc = [System.Diagnostics.Process]::GetCurrentProcess()
    # Warmup
    for ($w = 0; $w -lt 10; $w++) {
        $b = [System.Text.Encoding]::UTF8.GetBytes($JsonPayload)
        $m = [System.IO.MemoryStream]::new()
        $g = [System.IO.Compression.GZipStream]::new($m, [System.IO.Compression.CompressionMode]::Compress)
        $g.Write($b, 0, $b.Length)
        $g.Close()
        $null = "GZIP:" + [Convert]::ToBase64String($m.ToArray())
        $m.Dispose()
    }
    $cpuStart = $proc.TotalProcessorTime.TotalMilliseconds
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $outStr = ""
    for ($i = 0; $i -lt $Iters; $i++) {
        $b = [System.Text.Encoding]::UTF8.GetBytes($JsonPayload)
        $m = [System.IO.MemoryStream]::new()
        $g = [System.IO.Compression.GZipStream]::new($m, [System.IO.Compression.CompressionMode]::Compress)
        $g.Write($b, 0, $b.Length)
        $g.Close()
        $outStr = "GZIP:" + [Convert]::ToBase64String($m.ToArray())
        $m.Dispose()
    }
    $sw.Stop()
    $cpuEnd = $proc.TotalProcessorTime.TotalMilliseconds
    $msTotal = ($sw.ElapsedTicks / [double][System.Diagnostics.Stopwatch]::Frequency) * 1000.0
    $cpuTotal = [Math]::Max(0.0, $cpuEnd - $cpuStart)
    return @{
        TotalMs     = $msTotal
        PerOpMs     = $msTotal / [double]$Iters
        CpuTotalMs  = $cpuTotal
        CpuPerOpMs  = $cpuTotal / [double]$Iters
        Cores       = [Environment]::ProcessorCount
        WireStr     = $outStr
        WireBytes   = [System.Text.Encoding]::UTF8.GetByteCount($outStr)
        RawBytes    = [System.Text.Encoding]::UTF8.GetByteCount($JsonPayload)
    }
}

$clientDecompressBench = {
    param([string]$WirePayload, [int]$Iters)
    $proc = [System.Diagnostics.Process]::GetCurrentProcess()
    # Warmup
    for ($w = 0; $w -lt 10; $w++) {
        $null = Expand-GzipPayload -Payload $WirePayload
    }
    $cpuStart = $proc.TotalProcessorTime.TotalMilliseconds
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $outJson = ""
    for ($i = 0; $i -lt $Iters; $i++) {
        $outJson = Expand-GzipPayload -Payload $WirePayload
    }
    $sw.Stop()
    $cpuEnd = $proc.TotalProcessorTime.TotalMilliseconds
    $msTotal = ($sw.ElapsedTicks / [double][System.Diagnostics.Stopwatch]::Frequency) * 1000.0
    $cpuTotal = [Math]::Max(0.0, $cpuEnd - $cpuStart)
    return @{
        TotalMs    = $msTotal
        PerOpMs    = $msTotal / [double]$Iters
        CpuTotalMs = $cpuTotal
        CpuPerOpMs = $cpuTotal / [double]$Iters
        Cores      = [Environment]::ProcessorCount
        OutLen     = $outJson.Length
    }
}

$microCases = @(
    @{ Name = "Full Sync (Tick 1)";   Json = $sampleFullJson }
    @{ Name = "Steady Delta Tick";    Json = $sampleDeltaJson }
    @{ Name = "Minimal Idle Tick";    Json = $sampleIdleJson }
)

$microResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$microSess = $null
try {
    if ($ComputerName) {
        $so = New-PSSessionOption -OpenTimeout 8000 -OperationTimeout 15000 -NoMachineProfile
        $sp = @{ ComputerName = $ComputerName; SessionOption = $so; ErrorAction = 'Stop' }
        if ($Credential) { $sp['Credential'] = $Credential }
        if ($UseSSL)     { $sp['UseSSL']     = $true }
        $microSess = New-PSSession @sp
    }

    foreach ($mc in $microCases) {
        $caseIters = if ($mc.Json.Length -lt 8192) { $MicroIterations * 5 } else { $MicroIterations }
        $tRes = if ($microSess) {
            Invoke-Command -Session $microSess -ScriptBlock $targetBenchScript -ArgumentList @($mc.Json, $caseIters)
        } else {
            & $targetBenchScript $mc.Json $caseIters
        }
        $cRes = & $clientDecompressBench $tRes.WireStr $caseIters

        $rawB  = [int]$tRes.RawBytes
        $wireB = [int]$tRes.WireBytes
        $pct   = if ($rawB -gt 0) { [Math]::Round((1.0 - ($wireB / [double]$rawB)) * 100.0, 1) } else { 0.0 }
        $tCores = [Math]::Max(1, [int]$tRes.Cores)
        $cCores = [Math]::Max(1, [int]$cRes.Cores)

        $tHostCpuPct = (($tRes.CpuPerOpMs / 1000.0) / $tCores) * 100.0
        $cHostCpuPct = (($cRes.CpuPerOpMs / 1000.0) / $cCores) * 100.0

        $microResults.Add([PSCustomObject]@{
            PayloadType        = $mc.Name
            Iters              = $caseIters
            RawBytes           = $rawB
            WireBytes          = $wireB
            SavedPct           = $pct
            TargetWallMs       = [Math]::Round($tRes.PerOpMs, 4)
            TargetCpuMs        = [Math]::Round($tRes.CpuPerOpMs, 4)
            Target1sHostCpuPct = "$([Math]::Round($tHostCpuPct, 4))%"
            ClientWallMs       = [Math]::Round($cRes.PerOpMs, 4)
            ClientCpuMs        = [Math]::Round($cRes.CpuPerOpMs, 4)
            Client1sHostCpuPct = "$([Math]::Round($cHostCpuPct, 4))%"
        })
    }
} finally {
    if ($microSess) {
        try { Remove-PSSession -Session $microSess -ErrorAction SilentlyContinue } catch {}
    }
}

# ------------------------------------------------------------------
# 4. Assertions
# ------------------------------------------------------------------
$tick1Saved = $resGzip.Tick1.SavedPct
if ($tick1Saved -lt 50.0) {
    throw "Expected GZIP to save at least 50% on Tick 1 full sync, observed $tick1Saved%."
}

# ------------------------------------------------------------------
# 5. Formatted Performance Summary Report
# ------------------------------------------------------------------
Write-Host "`n========================================================================" -ForegroundColor Green
Write-Host " RESULTS: END-TO-END COLLECTOR & CLIENT (GZIP ON vs GZIP OFF)" -ForegroundColor Green
Write-Host "========================================================================" -ForegroundColor Green

$e2eTable = @(
    [PSCustomObject]@{
        Phase        = "Tick 1 (Full)"
        Mode         = "GZIP ON"
        WireKB       = [Math]::Round($resGzip.Tick1.WireBytes / 1024.0, 2)
        RawKB        = [Math]::Round($resGzip.Tick1.RawBytes / 1024.0, 2)
        SavedPct     = "$($resGzip.Tick1.SavedPct)%"
        RttMs        = $resGzip.Tick1.RttMs
        TargetCpuMs  = $resGzip.Tick1.TargetCpuMs
        ClientDecMs  = $resGzip.Tick1.DecompressMs
        ClientJsonMs = $resGzip.Tick1.JsonParseMs
        ClientTotMs  = [Math]::Round($resGzip.Tick1.DecompressMs + $resGzip.Tick1.JsonParseMs, 3)
    }
    [PSCustomObject]@{
        Phase        = "Tick 1 (Full)"
        Mode         = "GZIP OFF"
        WireKB       = [Math]::Round($resRaw.Tick1.WireBytes / 1024.0, 2)
        RawKB        = [Math]::Round($resRaw.Tick1.RawBytes / 1024.0, 2)
        SavedPct     = "0%"
        RttMs        = $resRaw.Tick1.RttMs
        TargetCpuMs  = $resRaw.Tick1.TargetCpuMs
        ClientDecMs  = 0.0
        ClientJsonMs = $resRaw.Tick1.JsonParseMs
        ClientTotMs  = $resRaw.Tick1.JsonParseMs
    }
    [PSCustomObject]@{
        Phase        = "Steady Avg ($Ticks)"
        Mode         = "GZIP ON"
        WireKB       = $resGzip.AvgWireKB
        RawKB        = $resGzip.AvgRawKB
        SavedPct     = "$($resGzip.AvgSavedPct)%"
        RttMs        = $resGzip.AvgRttMs
        TargetCpuMs  = $resGzip.SteadyCpuPerTickMs
        ClientDecMs  = $resGzip.AvgDecompressMs
        ClientJsonMs = $resGzip.AvgJsonParseMs
        ClientTotMs  = $resGzip.AvgClientTotalMs
    }
    [PSCustomObject]@{
        Phase        = "Steady Avg ($Ticks)"
        Mode         = "GZIP OFF"
        WireKB       = $resRaw.AvgWireKB
        RawKB        = $resRaw.AvgRawKB
        SavedPct     = "0%"
        RttMs        = $resRaw.AvgRttMs
        TargetCpuMs  = $resRaw.SteadyCpuPerTickMs
        ClientDecMs  = 0.0
        ClientJsonMs = $resRaw.AvgJsonParseMs
        ClientTotMs  = $resRaw.AvgJsonParseMs
    }
)
$e2eTable | Format-Table -AutoSize

Write-Host "========================================================================" -ForegroundColor Green
Write-Host " RESULTS: ISOLATED GZIP MICROBENCHMARK (Base=$MicroIterations, Small=5x)" -ForegroundColor Green
Write-Host "========================================================================" -ForegroundColor Green
$microResults | Format-Table -AutoSize

$bwSavedPct = $resGzip.AvgSavedPct
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  - Tick 1 Wire Reduction    : $($resGzip.Tick1.SavedPct)% ($([Math]::Round($resGzip.Tick1.RawBytes/1024.0, 2)) KB -> $([Math]::Round($resGzip.Tick1.WireBytes/1024.0, 2)) KB)" -ForegroundColor Gray
Write-Host "  - Steady-State Wire Avg    : $($resGzip.AvgWireKB) KB/tick ($($resGzip.BandwidthKBs) KB/s @ ${IntervalMs}ms), $bwSavedPct% saved vs raw ($($resGzip.AvgRawKB) KB/tick)" -ForegroundColor Gray
Write-Host "  - Target Compress (CPU)    : $($microResults[0].TargetCpuMs) ms (Full) | $($microResults[1].TargetCpuMs) ms (Delta, $($microResults[1].Target1sHostCpuPct) host CPU @ 1s)" -ForegroundColor Gray
Write-Host "  - Client Decompress (CPU)  : $($microResults[0].ClientCpuMs) ms (Full) | $($microResults[1].ClientCpuMs) ms (Delta, $($microResults[1].Client1sHostCpuPct) host CPU @ 1s)" -ForegroundColor Gray
if ($resGzip.ExpandedTicks -gt 0 -or $microResults[2].SavedPct -lt 0) {
    Write-Host "  - Small-Payload Crossover  : Minimal idle payloads expanded ($($microResults[2].RawBytes) B -> $($microResults[2].WireBytes) B, $($microResults[2].SavedPct)%) due to 'GZIP:' + Base64 overhead." -ForegroundColor Yellow
}
Write-Host "`n[PASS] Standalone GZIP performance benchmark completed successfully." -ForegroundColor Green
