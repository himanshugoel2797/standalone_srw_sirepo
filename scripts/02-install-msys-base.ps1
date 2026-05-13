#requires -Version 5.1
<#
.SYNOPSIS
  Install the MSYS-subsystem python and supporting toolchain for Sirepo.

.DESCRIPTION
  Sirepo uses POSIX features (os.fork, os.killpg, signal.SIGKILL) so it MUST run
  on MSYS-subsystem python -- NOT mingw64 python (which is native Windows ABI
  and lacks those). See memory/project_msys_vs_mingw64.md.

  This step installs the MSYS python interpreter + pip + the small subset of
  Sirepo deps that have MSYS prebuilts + the gcc toolchain needed to pip-build
  the rest from source in step 03.

  No system effects: everything goes under <project>\msys64\.

.PARAMETER Force
  Re-run pacman even if marker file says we're done.
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Msys64Dir   = Join-Path $ProjectRoot 'msys64'
$BootstrapMarker = Join-Path $Msys64Dir '.sirepo-win-bootstrap-ok'
$BashExe     = Join-Path $Msys64Dir 'usr\bin\bash.exe'
$StageMarker = Join-Path $Msys64Dir '.sirepo-win-msys-base-ok'

if (-not (Test-Path $BootstrapMarker)) {
    throw "MSYS2 not bootstrapped. Run scripts\01-bootstrap-msys2.ps1 first."
}

if ((Test-Path $StageMarker) -and -not $Force) {
    Write-Host "MSYS base already installed:"
    Get-Content $StageMarker | ForEach-Object { Write-Host "  $_" }
    Write-Host "Pass -Force to re-run."
    exit 0
}

# MSYS-subsystem packages. Two groups:
#   - The cygwin/POSIX python interpreter and its tooling.
#   - The prebuilt Sirepo deps available in MSYS subsystem (avoids building
#     OpenSSL/libffi/etc. dependents from source).
$MsysPackages = @(
    # Python interpreter + packaging tooling
    'python',
    'python-pip',
    'python-setuptools',
    # 'wheel' is installed via pip later -- no MSYS-subsystem pacman package exists
    # Toolchain for building remaining wheels in step 03
    'base-devel',           # make, patch, etc.
    'gcc',
    'git',
    'libcrypt-devel',       # needed by some build_ext steps
    'libffi-devel',
    'openssl-devel',
    'zlib-devel',
    # Prebuilt Sirepo deps that exist in MSYS subsystem
    'python-cryptography',  # avoids needing to build against openssl
    'python-cffi',
    'python-attrs',
    'python-requests',
    'python-six'
)

Write-Host "=== Installing $($MsysPackages.Count) MSYS packages ==="

$pkgList = $MsysPackages -join ' '
$flags = if ($Force) { '-S --noconfirm --noprogressbar --overwrite "*"' } else { '-S --needed --noconfirm --noprogressbar' }
& $BashExe -lc "pacman $flags $pkgList"
if ($LASTEXITCODE -ne 0) { throw "pacman install failed (exit $LASTEXITCODE)" }

# Probe what we got
Write-Host ""
Write-Host "=== Probe MSYS python POSIX support ==="
$probeMsys = (& $BashExe -lc "cygpath -u '$ProjectRoot\.cache\probe.py'").Trim()
& $BashExe -lc "python '$probeMsys'"
if ($LASTEXITCODE -ne 0) { throw "MSYS python probe failed (exit $LASTEXITCODE)" }

# Stage marker
@"
date:        $(Get-Date -Format o)
python:      $(& $BashExe -lc 'python --version 2>&1' | Out-String).Trim()
pip:         $(& $BashExe -lc 'python -m pip --version 2>&1' | Out-String).Trim()
packages:    $($MsysPackages.Count) installed
package-list: $($MsysPackages -join ', ')
"@ | Set-Content -Path $StageMarker -Encoding UTF8

Write-Host ""
Write-Host "Done. MSYS python + toolchain ready."
Write-Host "Next: scripts\03-install-sirepo.ps1"
