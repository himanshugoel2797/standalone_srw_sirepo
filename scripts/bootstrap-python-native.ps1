#requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap a portable native-Windows Python 3.12 under <project>\python-native\.

.DESCRIPTION
  Lays down a self-contained CPython runtime for the native-Windows SRW worker.
  The worker runs on the Windows host (not inside WSL2 or QEMU) and receives
  compute jobs from a custom Sirepo job driver living in the Linux env. Native
  Python is faster than emulated Python under TCG by 10-50x and gives a clean
  path to MSVC-built srwlpy + future CUDA / MS-MPI.

  Pipeline (all under <project>\, no admin, no Windows features):
    1. Download python.org Windows embeddable amd64 zip (~10 MB).
    2. Verify MD5 against the pinned hash from the python.org release page.
    3. Extract to <project>\python-native\.
    4. Patch python312._pth to re-enable site.py (the embeddable zip ships with
       it disabled). Without this, pip-installed packages aren't importable.
    5. Bootstrap pip via get-pip.py.
    6. pip install srwpy + numpy + fastapi + uvicorn for the worker.
    7. Smoke test: import srwpy, run a one-liner SRW init.

  No system installs. No registry writes. No PATH changes. Idempotent.

.PARAMETER PythonVersion
  CPython release tag (e.g. '3.12.7'). Default 3.12.7. Must have a published
  embeddable amd64 zip on python.org and matching srwpy wheel on PyPI.

.PARAMETER ExpectedMd5
  MD5 of the embeddable zip (python.org publishes MD5, not SHA256). Default
  matches PythonVersion=3.12.7.

.PARAMETER Force
  Wipe python-native\ and re-bootstrap.

.PARAMETER NoSrwpy
  Skip the srwpy install. Useful for testing the bootstrap without the slow
  SRW dependency download.
#>
[CmdletBinding()]
param(
    [string]$PythonVersion = '3.12.7',
    [string]$ExpectedMd5   = '4c0a5a44d4ca1d0bc76fe08ea8b76adc',
    [switch]$Force,
    [switch]$NoSrwpy
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Paths (all project-local) ---
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$PyDir       = Join-Path $ProjectRoot 'python-native'
$CacheDir    = Join-Path $ProjectRoot '.cache'
$Marker      = Join-Path $PyDir '.python-native-ok'

$ZipName = "python-$PythonVersion-embed-amd64.zip"
$ZipUrl  = "https://www.python.org/ftp/python/$PythonVersion/$ZipName"
$ZipPath = Join-Path $CacheDir $ZipName

$PyExe   = Join-Path $PyDir 'python.exe'

Write-Host "=== Sirepo_Win native-Python bootstrap ==="
Write-Host "project root: $ProjectRoot"
Write-Host "python dir:   $PyDir"
Write-Host "version:      $PythonVersion"
Write-Host ""

# --- Idempotency ---
if ((Test-Path $Marker) -and -not $Force) {
    Write-Host "Already bootstrapped:"
    Get-Content $Marker | ForEach-Object { Write-Host "  $_" }
    Write-Host "Pass -Force to wipe and re-bootstrap."
    exit 0
}

if ((Test-Path $PyDir) -and -not $Force) {
    throw "$PyDir exists but no marker. Partial install? Re-run with -Force."
}

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

# --- 1. Download embeddable zip ---
if (-not (Test-Path $ZipPath)) {
    Write-Host "Downloading $ZipUrl"
    $oldPP = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing }
    finally { $ProgressPreference = $oldPP }
} else {
    Write-Host "Cached: $ZipPath"
}

# --- 2. Verify MD5 ---
$actual = (Get-FileHash $ZipPath -Algorithm MD5).Hash.ToLower()
if ($actual -ne $ExpectedMd5.ToLower()) {
    Remove-Item $ZipPath -Force
    throw "MD5 mismatch (expected $ExpectedMd5, got $actual). Cached file removed; re-run to retry."
}
Write-Host "MD5 verified: $actual"

# --- 3. Extract ---
if (Test-Path $PyDir) {
    Write-Host "Removing previous $PyDir..."
    Remove-Item -Recurse -Force $PyDir
}
New-Item -ItemType Directory -Force -Path $PyDir | Out-Null
Write-Host "Extracting to $PyDir..."
Expand-Archive -Path $ZipPath -DestinationPath $PyDir -Force

if (-not (Test-Path $PyExe)) { throw "python.exe missing after extract" }

# --- 4. Patch ._pth to re-enable site.py ---
$pthFiles = @(Get-ChildItem $PyDir -Filter 'python*._pth')
if ($pthFiles.Count -eq 0) { throw "no python*._pth file found in $PyDir" }
$pthFile = $pthFiles[0].FullName
Write-Host "Patching $pthFile to enable site-packages..."
$pthContent = Get-Content -Raw $pthFile
# Embeddable zip ships with "#import site" commented out. Uncomment it so
# Lib/site-packages is on sys.path and pip-installed packages can be imported.
$pthContent = $pthContent -replace '(?m)^#\s*import site\s*$', 'import site'
Set-Content -Path $pthFile -Value $pthContent -Encoding ASCII -NoNewline

# --- 5. Bootstrap pip ---
$getPip = Join-Path $CacheDir 'get-pip.py'
if (-not (Test-Path $getPip)) {
    Write-Host "Downloading get-pip.py..."
    $oldPP = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $getPip -UseBasicParsing }
    finally { $ProgressPreference = $oldPP }
}

Write-Host "Bootstrapping pip..."
& $PyExe $getPip --no-warn-script-location
if ($LASTEXITCODE -ne 0) { throw "get-pip.py failed (exit $LASTEXITCODE)" }

# --- 6. Install worker deps ---
#   wsgidav + a2wsgi serve the Windows source tree to the QEMU VM as WebDAV
#   (mounted via davfs2 inside cloud-init). Same process as the FastAPI /run
#   worker -- the WSGI app gets mounted under /dav.
$pkgs = @('pip', 'wheel', 'setuptools', 'numpy', 'fastapi', 'uvicorn[standard]', 'wsgidav', 'a2wsgi')
if (-not $NoSrwpy) { $pkgs += 'srwpy' }

Write-Host "pip install $($pkgs -join ' ')..."
& $PyExe -m pip install --upgrade --no-warn-script-location @pkgs
if ($LASTEXITCODE -ne 0) { throw "pip install failed (exit $LASTEXITCODE)" }

# --- 7. Smoke test ---
Write-Host "Smoke test..."
$smokeTest = if ($NoSrwpy) {
    "import numpy, fastapi, uvicorn; print('OK: numpy', numpy.__version__, '| fastapi', fastapi.__version__)"
} else {
    "import srwpy, numpy; print('OK: srwpy', getattr(srwpy, '__version__', '?'), '| numpy', numpy.__version__)"
}
& $PyExe -c $smokeTest
if ($LASTEXITCODE -ne 0) { throw "Smoke test failed (exit $LASTEXITCODE)" }

# --- 8. Marker ---
$installedPip = (& $PyExe -m pip --version) -join ' '
@"
date:        $(Get-Date -Format o)
python:      $PythonVersion (embeddable amd64, MD5 $actual)
pip:         $installedPip
srwpy:       $(if ($NoSrwpy) { 'NOT INSTALLED (-NoSrwpy)' } else { 'installed' })
location:    $PyDir
"@ | Set-Content -Path $Marker -Encoding UTF8

Write-Host ""
Write-Host "Done. Native Python ready at: $PyExe"
Write-Host "Run worker with:  $PyExe <project>\worker\worker.py"
