<#
.SYNOPSIS
    Simulates variable CPU and memory workloads across multiple worker processes for testing PSRPM.

.DESCRIPTION
    Spins up worker processes (default: 12) that allocate varying amounts of committed memory
    (40 MB to 220 MB) and execute staggered, oscillating CPU burst cycles.
    This creates an ideal live environment to verify:
      - Realtime CPU sort re-ordering (processes spiking, rising to the top, and settling)
      - Flat View vs Tree View sorting
      - Memory / Working Set visualization and sorting
      - Search filtering (type 'PSRPMSim' in PSRPM search box)
      - Lifecycle detection (green spawn flashes, red exit flashes)

.PARAMETER Start
    Starts the simulator processes (default action).

.PARAMETER Stop
    Terminates all running simulator worker processes and cleans up state files.

.PARAMETER Status
    Displays the current execution status and resource metrics of active simulator workers.

.PARAMETER Count
    Number of worker processes to spawn (default: 12).

.PARAMETER DurationMinutes
    Safety auto-exit timeout in minutes (default: 30). Workers self-terminate after this duration
    to prevent orphaned background tasks.

.EXAMPLE
    .\Simulate-Workload.ps1
    # Starts 12 simulator workers

.EXAMPLE
    .\Simulate-Workload.ps1 -Stop
    # Terminates all simulator workers cleanly

.EXAMPLE
    .\Simulate-Workload.ps1 -Status
    # Checks live metrics of all running workers
#>

[CmdletBinding(DefaultParameterSetName = "Start")]
param(
    [Parameter(ParameterSetName = "Start")]
    [switch]$Start,

    [Parameter(ParameterSetName = "Stop")]
    [switch]$Stop,

    [Parameter(ParameterSetName = "Status")]
    [switch]$Status,

    [Parameter(ParameterSetName = "Start")]
    [ValidateRange(1, 64)]
    [int]$Count = 12,

    [Parameter(ParameterSetName = "Start")]
    [ValidateRange(1, 1440)]
    [int]$DurationMinutes = 30
)

$pidFile = Join-Path $env:TEMP "psrpm_workload_simulator_pids.json"

# ------------------------------------------------------------------------------
# Action: STOP
# ------------------------------------------------------------------------------
if ($Stop) {
    Write-Host "`nStopping PSRPM Workload Simulator processes..." -ForegroundColor Cyan
    $stoppedCount = 0

    if (Test-Path -LiteralPath $pidFile) {
        try {
            $jsonContent = Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue
            if ($jsonContent) {
                $parsed = ConvertFrom-Json -InputObject $jsonContent -ErrorAction SilentlyContinue
                $trackedList = @($parsed)
                foreach ($item in $trackedList) {
                    $tPid = [int]$item.PID
                    try {
                        $p = Get-Process -Id $tPid -ErrorAction SilentlyContinue
                        if ($p -and -not $p.HasExited) {
                            $p | Stop-Process -Force -ErrorAction SilentlyContinue
                            $stoppedCount++
                        }
                    } catch {}
                }
            }
        } catch {}
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }

    # Safety-net sweep: clean up any orphaned powershell processes tagged with PSRPMSim
    try {
        $simProcs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains("PSRPMSim_Worker_") }
        if ($simProcs) {
            foreach ($sp in $simProcs) {
                try {
                    Stop-Process -Id $sp.ProcessId -Force -ErrorAction SilentlyContinue
                    $stoppedCount++
                } catch {}
            }
        }
    } catch {}

    if ($stoppedCount -gt 0) {
        Write-Host "  [OK] Successfully terminated $stoppedCount simulator worker processes.`n" -ForegroundColor Green
    } else {
        Write-Host "  [INFO] No active simulator worker processes found.`n" -ForegroundColor Gray
    }
    return
}

# ------------------------------------------------------------------------------
# Action: STATUS
# ------------------------------------------------------------------------------
if ($Status) {
    Write-Host "`nPSRPM Workload Simulator Status:" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $pidFile)) {
        Write-Host "  No active simulator session found. Start one with: .\Simulate-Workload.ps1`n" -ForegroundColor Yellow
        return
    }

    $jsonContent = Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue
    $parsed = if ($jsonContent) { ConvertFrom-Json -InputObject $jsonContent -ErrorAction SilentlyContinue } else { $null }
    $trackedList = @($parsed)
    if ($trackedList.Count -eq 0) {
        Write-Host "  No tracked simulator workers found.`n" -ForegroundColor Yellow
        return
    }

    $aliveWorkers = @()
    foreach ($item in $trackedList) {
        $tPid = [int]$item.PID
        $p = Get-Process -Id $tPid -ErrorAction SilentlyContinue
        if ($p -and -not $p.HasExited) {
            $wsMb = [Math]::Round($p.WorkingSet64 / 1MB, 1)
            $aliveWorkers += [PSCustomObject]@{
                PID         = $tPid
                Tag         = $item.Tag
                AllocTarget = "$($item.AllocMB) MB"
                WorkingSet  = "$wsMb MB"
                StartTime   = $p.StartTime.ToString("HH:mm:ss")
            }
        }
    }

    if ($aliveWorkers.Count -gt 0) {
        $aliveWorkers | Format-Table -AutoSize
        Write-Host "  Active workers: $($aliveWorkers.Count) / $($trackedList.Count)" -ForegroundColor Green
        Write-Host "  To stop all workers run: .\Simulate-Workload.ps1 -Stop`n" -ForegroundColor Gray
    } else {
        Write-Host "  All previous simulator workers have exited.`n" -ForegroundColor Gray
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
    return
}

# ------------------------------------------------------------------------------
# Action: START
# ------------------------------------------------------------------------------

# Check if workers are already active
if (Test-Path -LiteralPath $pidFile) {
    $existingRaw = Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue
    $existingParsed = if ($existingRaw) { ConvertFrom-Json -InputObject $existingRaw -ErrorAction SilentlyContinue } else { $null }
    $existing = @($existingParsed)
    $aliveCount = 0
    foreach ($e in $existing) {
        $p = Get-Process -Id ([int]$e.PID) -ErrorAction SilentlyContinue
        if ($p -and -not $p.HasExited) { $aliveCount++ }
    }
    if ($aliveCount -gt 0) {
        Write-Host "`nA simulator workload is already running ($aliveCount active processes)." -ForegroundColor Yellow
        Write-Host "  Check status : .\Simulate-Workload.ps1 -Status" -ForegroundColor Gray
        Write-Host "  Stop session : .\Simulate-Workload.ps1 -Stop`n" -ForegroundColor Gray
        return
    }
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Starting PSRPM Workload Simulator ($Count processes, ${DurationMinutes}m auto-exit)" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

$maxSec = $DurationMinutes * 60
$workerInfoList = [System.Collections.Generic.List[Object]]::new()

for ($i = 1; $i -le $Count; $i++) {
    $tag = ("PSRPMSim_Worker_{0:D2}" -f $i)

    # Staggered memory allocation: 40 MB to 220 MB
    $allocMb = 40 + ($i * 15)

    # Staggered CPU burst and idle periods: creates asynchronous oscillating spikes
    $burstMs = 1200 + ($i * 120)
    $idleMs  = 1500 + (($Count - $i) * 350)

    # Worker script launched via -Command with tag clearly in command line
    $workerCmd = "& { # $tag`n`$ErrorActionPreference = 'SilentlyContinue'; `$allocMb = $allocMb; `$burstMs = $burstMs; `$idleMs = $idleMs; `$maxSec = $maxSec; `$bytes = [byte[]]::new(`$allocMb * 1024 * 1024); for (`$b = 0; `$b -lt `$bytes.Length; `$b += 4096) { `$bytes[`$b] = 1 }; `$totalSw = [System.Diagnostics.Stopwatch]::StartNew(); while (`$totalSw.Elapsed.TotalSeconds -lt `$maxSec) { `$burstSw = [System.Diagnostics.Stopwatch]::StartNew(); while (`$burstSw.ElapsedMilliseconds -lt `$burstMs) { `$null = [Math]::Sqrt(`$burstSw.ElapsedTicks) * [Math]::Sin(`$burstSw.ElapsedTicks) }; Start-Sleep -Milliseconds `$idleMs } }"

    $p = Start-Process powershell.exe -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden",
        "-Command", $workerCmd
    ) -PassThru

    if ($p) {
        $workerInfoList.Add([PSCustomObject]@{
            PID         = $p.Id
            Tag         = $tag
            AllocMB     = $allocMb
            BurstMs     = $burstMs
            IdleMs      = $idleMs
            StartedUtc  = [DateTime]::UtcNow.ToString("o")
        })
    }
}

# Save PID state file
@($workerInfoList) | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $pidFile -Encoding UTF8

Write-Host "`n  Successfully spawned $($workerInfoList.Count) simulator processes:`n" -ForegroundColor Green

$summaryTable = @()
foreach ($w in $workerInfoList) {
    $summaryTable += [PSCustomObject]@{
        PID        = $w.PID
        Tag        = $w.Tag
        Memory     = "$($w.AllocMB) MB"
        Cycle      = "$([Math]::Round($w.BurstMs / 1000.0, 1))s burst / $([Math]::Round($w.IdleMs / 1000.0, 1))s idle"
    }
}
$summaryTable | Format-Table -AutoSize

Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host " HOW TO TEST IN PSRPM:" -ForegroundColor Yellow
Write-Host " 1. Run PSRPM (in a separate terminal or tab):" -ForegroundColor White
Write-Host "      Start-PSRPM -LocalOnly" -ForegroundColor Cyan
Write-Host " 2. Type 'PSRPMSim' in the top-right search box (Ctrl+F) to isolate them." -ForegroundColor White
Write-Host " 3. Click the 'CPU' column header to sort descending:" -ForegroundColor White
Write-Host "    - Watch active workers dynamically rise to the top as they burst." -ForegroundColor Gray
Write-Host "    - Watch them settle back down as their burst finishes." -ForegroundColor Gray
Write-Host " 4. Click the 'Private Bytes' column to see sorted memory allocation." -ForegroundColor White
Write-Host " 5. When done testing, stop all workers by running:" -ForegroundColor White
Write-Host "      .\Simulate-Workload.ps1 -Stop" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------------`n" -ForegroundColor DarkGray
