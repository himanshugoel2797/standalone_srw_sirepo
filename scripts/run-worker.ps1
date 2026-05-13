#requires -Version 5.1
<#
.SYNOPSIS
  Start the native-Windows SRW worker.

.DESCRIPTION
  The worker runs on the Windows host, outside whichever Linux backend hosts
  Sirepo. Sirepo's windows_native job driver POSTs compute jobs here so srwpy
  runs at native speed (not the 10-50x TCG slowdown under QEMU, and not over
  the slow /mnt/c bridge under WSL2).

  Binds 127.0.0.1 by default. The Linux guest reaches the worker via the host
  side of its NIC (WSL2: $(ip route show default | awk '/default/{print \$3}')
  -- QEMU/slirp: 10.0.2.2). The driver discovers the URL at runtime.

.PARAMETER Port
  TCP port to listen on. Default 8311.

.PARAMETER Host
  Bind address. Default 127.0.0.1. Pass 0.0.0.0 only when you understand the
  exposure (e.g. a QEMU hostfwd is forwarding the guest port back at us).
#>
[CmdletBinding()]
param(
    [int]$Port = 8311,
    [string]$BindHost = '127.0.0.1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$PyExe       = Join-Path $ProjectRoot 'python-native\python.exe'
$WorkerPy    = Join-Path $ProjectRoot 'worker\worker.py'
$PyMarker    = Join-Path $ProjectRoot 'python-native\.python-native-ok'

if (-not (Test-Path $PyMarker)) {
    throw "Native python not bootstrapped. Run scripts\bootstrap-python-native.ps1 first."
}
if (-not (Test-Path $WorkerPy)) {
    throw "Missing $WorkerPy"
}

Write-Host "Starting native worker on http://${BindHost}:${Port}"
Write-Host "  python: $PyExe"
Write-Host "  worker: $WorkerPy"
Write-Host "  Ctrl-C to stop."
Write-Host ""

& $PyExe $WorkerPy --host $BindHost --port $Port
