#requires -Version 5.1
<#
.SYNOPSIS
  Install Sirepo's MSYS2/MinGW64 Python dependencies via pacman.

.DESCRIPTION
  Runs `pacman -S --needed --noconfirm` for the subset of Sirepo's deps that have
  prebuilt mingw-w64-x86_64 packages. Remaining deps (pykern, chronver, stripe,
  authlib, user-agents, pyIsEmail, numconv) are installed in a later step via
  pip from inside MSYS2.

  All work happens inside <project>\msys64\ -- no system effects. The marker file
  written by 01-bootstrap-msys2.ps1 must exist before this script runs.

.PARAMETER Force
  Force pacman to reinstall even if the package version is already current.
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Msys64Dir   = Join-Path $ProjectRoot 'msys64'
$Marker      = Join-Path $Msys64Dir '.sirepo-win-bootstrap-ok'
$BashExe     = Join-Path $Msys64Dir 'usr\bin\bash.exe'
$StageMarker = Join-Path $Msys64Dir '.sirepo-win-pacman-deps-ok'

if (-not (Test-Path $Marker)) {
    throw "MSYS2 not bootstrapped. Run scripts\01-bootstrap-msys2.ps1 first."
}
if (-not (Test-Path $BashExe)) {
    throw "Missing $BashExe -- MSYS2 install looks broken."
}

if ((Test-Path $StageMarker) -and -not $Force) {
    Write-Host "pacman deps already installed:"
    Get-Content $StageMarker | ForEach-Object { Write-Host "  $_" }
    Write-Host "Pass -Force to re-run."
    exit 0
}

# Subset of Sirepo's runtime deps that have mingw-w64-x86_64 prebuilt packages.
# Verified present in the MSYS2 mingw64 repo. Anything not here goes through pip
# in the next step.
$PacmanPackages = @(
    # Toolchain we always want
    'mingw-w64-x86_64-python',
    'mingw-w64-x86_64-python-pip',
    'mingw-w64-x86_64-python-setuptools',
    'mingw-w64-x86_64-python-wheel',
    'mingw-w64-x86_64-git',
    # Sirepo's deps (alphabetical)
    'mingw-w64-x86_64-python-aenum',
    'mingw-w64-x86_64-python-aiofiles',
    'mingw-w64-x86_64-python-aiohttp',
    'mingw-w64-x86_64-python-asyncssh',
    'mingw-w64-x86_64-python-cryptography',
    'mingw-w64-x86_64-python-dnspython',
    'mingw-w64-x86_64-python-ldap3',
    'mingw-w64-x86_64-python-matplotlib',
    'mingw-w64-x86_64-python-msgpack',
    'mingw-w64-x86_64-python-numpy',
    'mingw-w64-x86_64-python-pillow',
    'mingw-w64-x86_64-python-pytest-asyncio',
    'mingw-w64-x86_64-python-pytz',
    'mingw-w64-x86_64-python-requests',
    'mingw-w64-x86_64-python-scipy',
    'mingw-w64-x86_64-python-sqlalchemy',
    'mingw-w64-x86_64-python-tornado',
    'mingw-w64-x86_64-python-websockets'
)

Write-Host "=== Installing $($PacmanPackages.Count) packages via pacman ==="

# pacman handles batching well; one invocation is faster and produces a single
# dependency resolution.
$pkgList = $PacmanPackages -join ' '
$pacmanArgs = if ($Force) { '-S --noconfirm --noprogressbar --overwrite "*"' } else { '-S --needed --noconfirm --noprogressbar' }

$cmd = "pacman $pacmanArgs $pkgList"
Write-Host "running: $cmd"
& $BashExe -lc $cmd
if ($LASTEXITCODE -ne 0) {
    throw "pacman install failed (exit $LASTEXITCODE). Re-run after investigating."
}

# Smoke test: import the things most likely to fail (compiled bits)
Write-Host ""
Write-Host "=== Smoke test: import core scientific stack in MinGW64 Python ==="
$smokeScript = @'
import sys
print(f"python: {sys.version.split()[0]} ({sys.executable})")
# NB: import names differ from PyPI names for some packages.
# dnspython -> dns, Pillow -> PIL, etc.
mods = ["numpy", "scipy", "matplotlib", "PIL", "tornado",
        "sqlalchemy", "aiohttp", "aiofiles", "asyncssh",
        "cryptography", "msgpack", "requests", "ldap3", "dns"]
fail = []
for m in mods:
    try:
        __import__(m)
        print(f"  ok  {m}")
    except Exception as e:
        print(f"  ERR {m}: {e}")
        fail.append(m)
if fail:
    sys.exit(1)
'@

# Use a temp file rather than a long -c invocation to avoid quoting hell.
$smokePathHost = Join-Path $env:TEMP "sirepo-win-smoke-$([guid]::NewGuid().ToString('N')).py"
try {
    Set-Content -Path $smokePathHost -Value $smokeScript -Encoding UTF8 -NoNewline
    # Convert C:\Users\... -> /c/Users/... for MSYS2 bash
    $smokeMsys = ($smokePathHost -replace '\\','/') -replace '^([A-Za-z]):/','/$1/' -replace '^/([A-Za-z])/','/$1/'
    # ^ ASCII drive letter to /<lower>/ in cygpath style. cygpath is more robust:
    $smokeMsys = & $BashExe -lc "cygpath -u '$smokePathHost'"
    & $BashExe -lc "MSYSTEM=MINGW64 source /etc/profile && python '$smokeMsys'"
    if ($LASTEXITCODE -ne 0) { throw "smoke test failed (exit $LASTEXITCODE)" }
} finally {
    Remove-Item $smokePathHost -ErrorAction SilentlyContinue
}

# Stage marker
@"
installed:    $($PacmanPackages.Count) mingw64 packages
date:         $(Get-Date -Format o)
package-list: $($PacmanPackages -join ', ')
"@ | Set-Content -Path $StageMarker -Encoding UTF8

Write-Host ""
Write-Host "Done. MSYS2 + Sirepo's mingw64-available deps installed."
Write-Host "Remaining (pip in step 03): pykern, chronver, stripe, authlib, user-agents, pyIsEmail, numconv"
