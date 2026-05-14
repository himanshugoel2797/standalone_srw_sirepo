#requires -Version 5.1
<#
.SYNOPSIS
  One-shot orchestrator for Sirepo_Win.

.DESCRIPTION
  Wraps the three bootstrap stages + worker + QEMU launch into a single
  command:

    1. Bootstrap python-native (embeddable Python + srwpy for the worker).
    2. Start the worker (FastAPI on 127.0.0.1:8311; serves /run and /dav).
    3. Hand off to bootstrap-qemu.ps1 (MSYS2 + portable QEMU + jammy image +
       cloud-init seed ISO -> launch). cloud-init clones sirepo+pykern inside
       the VM and runs install-sirepo.sh on first boot.

  Every stage is idempotent: re-running this script after a successful run
  skips the cached steps and is back in QEMU in seconds.

  Press Ctrl-C to stop. The worker is killed on exit.

.PARAMETER Memory
  Guest memory in GB. Default 4.

.PARAMETER Cpus
  Guest vCPU count. Default 2.

.PARAMETER HostPort
  Windows host port that maps to the VM's port 8000. Default 8000.

.PARAMETER WorkerPort
  TCP port for the native worker on the Windows host. Default 8311.

.PARAMETER Force
  Wipe the QEMU overlay + re-generate the cloud-init seed. Keeps MSYS2,
  python-native, and the Ubuntu base image.
#>
[CmdletBinding()]
param(
    [int]   $Memory     = 4,
    [int]   $Cpus       = 2,
    [int]   $HostPort   = 8000,
    [int]   $WorkerPort = 8311,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = $PSScriptRoot
$PyNativeBootstrap = Join-Path $ProjectRoot 'scripts\bootstrap-python-native.ps1'
$QemuBootstrap     = Join-Path $ProjectRoot 'scripts\bootstrap-qemu.ps1'
$WorkerPy          = Join-Path $ProjectRoot 'worker\worker.py'
$PyExe             = Join-Path $ProjectRoot 'python-native\python.exe'
$PyMarker          = Join-Path $ProjectRoot 'python-native\.python-native-ok'
$WorkerLog         = Join-Path $ProjectRoot '.cache\worker.log'

Write-Host "=== Sirepo_Win setup ==="
Write-Host "project root: $ProjectRoot"
Write-Host ""

# --- 1. python-native (embeddable Python + srwpy + worker deps) ---
if ((Test-Path $PyMarker) -and -not $Force) {
    Write-Host "python-native already bootstrapped."
} else {
    Write-Host "--- Bootstrapping python-native ---"
    & $PyNativeBootstrap
    if ($LASTEXITCODE -ne 0) { throw "bootstrap-python-native.ps1 failed (exit $LASTEXITCODE)" }
}

# --- 2. Worker: start if not already running ---
function Test-WorkerHealthy {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$WorkerPort/health" `
                               -UseBasicParsing -TimeoutSec 2
        return $r.StatusCode -eq 200
    } catch { return $false }
}

New-Item -ItemType Directory -Force -Path (Split-Path $WorkerLog) | Out-Null

$workerProc = $null
if (Test-WorkerHealthy) {
    Write-Host "Worker already running on 127.0.0.1:$WorkerPort."
} else {
    Write-Host "--- Starting worker (logs -> $WorkerLog) ---"
    # Start detached so Ctrl-C in this PowerShell doesn't take us out before
    # we get to the cleanup at the bottom.
    # Windows PowerShell 5.1's ProcessStartInfo (.NET Framework) doesn't have
    # ArgumentList -- use Arguments as a single quoted string.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $PyExe
    $psi.Arguments              = "`"$WorkerPy`" --port $WorkerPort"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.WorkingDirectory       = $ProjectRoot
    $workerProc = [System.Diagnostics.Process]::Start($psi)
    # Tee both streams to the log file. The Begin*Read calls return
    # immediately; the handler runs on a thread-pool worker.
    $sw = [System.IO.StreamWriter]::new($WorkerLog, $false)
    $sw.AutoFlush = $true
    $onData = {
        param($s, $e)
        if ($null -ne $e.Data) { $Event.MessageData.WriteLine($e.Data) }
    }
    Register-ObjectEvent -InputObject $workerProc -EventName OutputDataReceived `
        -Action $onData -MessageData $sw | Out-Null
    Register-ObjectEvent -InputObject $workerProc -EventName ErrorDataReceived `
        -Action $onData -MessageData $sw | Out-Null
    $workerProc.BeginOutputReadLine()
    $workerProc.BeginErrorReadLine()

    Write-Host "Waiting for worker /health..."
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-WorkerHealthy) { break }
        if ($workerProc.HasExited) {
            Write-Host ""
            Write-Host "Worker exited early. Tail of ${WorkerLog}:" -ForegroundColor Red
            if (Test-Path $WorkerLog) { Get-Content $WorkerLog -Tail 30 | Write-Host }
            throw "Worker failed to start."
        }
    }
    if (-not (Test-WorkerHealthy)) {
        throw "Worker did not become healthy within 30s."
    }
    Write-Host "Worker pid=$($workerProc.Id) ready."
}

# --- 3. QEMU bootstrap + launch (runs in foreground) ---
Write-Host ""
$qemuArgs = @{
    Memory     = $Memory
    Cpus       = $Cpus
    HostPort   = $HostPort
    WorkerPort = $WorkerPort
}
if ($Force) { $qemuArgs.Force = $true }

try {
    & $QemuBootstrap @qemuArgs
} finally {
    if ($workerProc -and -not $workerProc.HasExited) {
        Write-Host ""
        Write-Host "Stopping worker (pid=$($workerProc.Id))..."
        try { $workerProc.Kill() } catch {}
    }
}
