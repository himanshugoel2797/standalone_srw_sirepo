#requires -Version 5.1
<#
.SYNOPSIS
  Clone Sirepo + pykern and pip-install into the MSYS-subsystem python (3.12).

.DESCRIPTION
  Sirepo runs on MSYS python (Cygwin-based, has fork/killpg/SIGKILL). Most of
  its pip deps don't have wheels for cygwin so they build from source --
  gcc/base-devel installed in step 02 makes this possible. Build is slow first
  time (~10-20 min) but the result is cached under msys64\home\<user>\.local\.

  Strategy: install Sirepo's runtime deps as a single resolved set rather than
  one-by-one, so pip handles the constraint solver. SQLAlchemy<2 is honored
  here too (despite Sirepo eventually needing a constraint relax for SA 2).

.PARAMETER SirepoRef
  Sirepo git ref to checkout (default master).

.PARAMETER PykernRef
  pykern git ref to checkout (default master).

.PARAMETER Force
  Re-clone and re-install.

.PARAMETER SkipHeavyDeps
  Skip numpy/scipy/matplotlib install. Useful for an initial spike to see whether
  `sirepo service http` actually needs them at startup before paying the
  compile-from-source cost.
#>
[CmdletBinding()]
param(
    [string]$SirepoRef = 'master',
    [string]$PykernRef = 'master',
    [switch]$Force,
    [switch]$SkipHeavyDeps
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot   = Split-Path -Parent $PSScriptRoot
$Msys64Dir     = Join-Path $ProjectRoot 'msys64'
$BashExe       = Join-Path $Msys64Dir 'usr\bin\bash.exe'
$Stage2Marker  = Join-Path $Msys64Dir '.sirepo-win-msys-base-ok'
$Stage3Marker  = Join-Path $Msys64Dir '.sirepo-win-sirepo-ok'
$SirepoDir     = Join-Path $ProjectRoot 'sirepo'
$PykernDir     = Join-Path $ProjectRoot 'pykern'

if (-not (Test-Path $Stage2Marker)) {
    throw "Step 02 not complete. Run scripts\02-install-msys-base.ps1 first."
}

if ((Test-Path $Stage3Marker) -and -not $Force) {
    Write-Host "Sirepo already installed:"
    Get-Content $Stage3Marker | ForEach-Object { Write-Host "  $_" }
    Write-Host "Pass -Force to re-run."
    exit 0
}

if ($Force) {
    foreach ($d in @($SirepoDir, $PykernDir)) {
        if (Test-Path $d) {
            Write-Host "Removing $d"
            Remove-Item -Recurse -Force $d
        }
    }
}

function Invoke-MsysBash {
    param([string]$Command, [string]$Label = '')
    if ($Label) { Write-Host "--- $Label ---" }
    & $BashExe -lc $Command
    if ($LASTEXITCODE -ne 0) {
        throw "bash command failed (exit $LASTEXITCODE): $Command"
    }
}

function Sync-Repo {
    param([string]$Url, [string]$Dest, [string]$Ref)
    if (-not (Test-Path $Dest)) {
        Write-Host "Cloning $Url -> $Dest"
        & git clone --depth 50 $Url $Dest
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $Url" }
    } else {
        Write-Host "$Dest exists; fetching..."
        Push-Location $Dest
        try {
            & git fetch --depth 50 origin
            if ($LASTEXITCODE -ne 0) { throw "git fetch failed in $Dest" }
        } finally { Pop-Location }
    }
    Push-Location $Dest
    try {
        & git checkout $Ref 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "git checkout $Ref failed in $Dest" }
    } finally { Pop-Location }
}

Sync-Repo -Url 'https://github.com/radiasoft/pykern.git' -Dest $PykernDir -Ref $PykernRef
Sync-Repo -Url 'https://github.com/radiasoft/sirepo.git' -Dest $SirepoDir -Ref $SirepoRef

# Host -> MSYS path conversion (cygpath is most reliable)
$pykernMsys = (& $BashExe -lc "cygpath -u '$PykernDir'").Trim()
$sirepoMsys = (& $BashExe -lc "cygpath -u '$SirepoDir'").Trim()

# --user installs go to /home/<user>/.local under msys64/home -- portable.
# --break-system-packages because pacman-managed python marks itself
# externally-managed (PEP 668); inside our isolated MSYS that's exactly what we
# want.
$pipPrefix = 'python -m pip install --user --break-system-packages --no-warn-script-location'

# 1. Bootstrap wheel so source builds work cleanly.
Invoke-MsysBash -Label 'pip install wheel' -Command "$pipPrefix wheel"

# 2. Install Sirepo's pip-resolved deps as a single batch. Pulling them all in
#    one `pip install` lets pip's resolver settle the version pins together
#    (notably SQLAlchemy<2 -> needs greenlet, etc.). Pure-Python deps come down
#    as wheels; compiled ones (greenlet, yarl, multidict, frozenlist, msgpack,
#    propcache) build from source using msys/gcc -- a few minutes total.
$deps = @(
    "'SQLAlchemy<2'",
    'aenum',
    'aiofiles',
    'aiohttp',
    'asyncssh',
    'chronver',
    'dnspython',
    'ldap3',
    'msgpack',
    'numconv',
    'pyIsEmail',
    'pytz',
    'pytest-asyncio',
    "'tornado>=6.5.2'",
    'user-agents',
    'websockets',
    'Authlib',
    'stripe'
)
# DEFERRED -- need native libs that MSYS subsystem doesn't ship as devel pkgs.
# We install these only on demand once we know which `sirepo` code paths import
# them at boot vs lazily. Setting -InstallHeavy attempts them; they will likely
# fail without extra pacman libjpeg/libpng/openblas devel pkgs that don't exist
# in MSYS subsystem (mingw64 has them but mingw64 python is the wrong ABI).
#   Pillow  -> needs libjpeg, libpng dev headers
#   numpy   -> needs BLAS/LAPACK
#   scipy   -> needs numpy + Fortran
#   matplotlib -> needs Pillow + freetype dev headers
if (-not $SkipHeavyDeps) {
    $deps += @('Pillow', 'numpy', 'matplotlib')
    Write-Host "(WILL ATTEMPT heavy deps -- Pillow/numpy/matplotlib; likely fails without devel libs)"
} else {
    Write-Host "(SKIPPING heavy deps -- Pillow/numpy/matplotlib deferred until we know sirepo boot path needs them)"
}
$depsArg = $deps -join ' '
Invoke-MsysBash -Label 'pip install runtime deps' -Command "$pipPrefix $depsArg"

# 3. pykern + sirepo editable installs.
#    --no-deps because we already installed the resolved set above and want to
#    avoid pip changing things underneath us.
Invoke-MsysBash -Label 'pip install -e pykern' -Command "$pipPrefix --no-deps -e '$pykernMsys'"
Invoke-MsysBash -Label 'pip install -e sirepo' -Command "$pipPrefix --no-deps -e '$sirepoMsys'"

# 4. Smoke test
Write-Host ""
Write-Host "=== Smoke test: import sirepo entrypoints ==="
$smoke = @'
import sys, importlib
print(f"python: {sys.version.split()[0]} {sys.platform} ({sys.executable})")
fail = []
for m in ["pykern", "sirepo",
         "tornado", "sqlalchemy", "aiohttp", "asyncssh",
         "cryptography", "msgpack", "chronver", "stripe",
         "authlib", "user_agents", "pyisemail", "numconv",
         "ldap3", "dns"]:
    try:
        importlib.import_module(m)
        print(f"  ok  {m}")
    except Exception as e:
        print(f"  ERR {m}: {type(e).__name__}: {e}")
        fail.append(m)
import sqlalchemy
print(f"  sqlalchemy version: {sqlalchemy.__version__}")
sys.exit(1 if fail else 0)
'@
$smokeHost = Join-Path $env:TEMP "sirepo-smoke-03-$([guid]::NewGuid().ToString('N')).py"
try {
    Set-Content -Path $smokeHost -Value $smoke -Encoding UTF8 -NoNewline
    $smokeMsys = (& $BashExe -lc "cygpath -u '$smokeHost'").Trim()
    Invoke-MsysBash -Label 'smoke test' -Command "python '$smokeMsys'"
} finally {
    Remove-Item $smokeHost -ErrorAction SilentlyContinue
}

function Get-RepoShortSha {
    param([string]$Dir)
    Push-Location $Dir
    try { (& git rev-parse --short HEAD).Trim() } finally { Pop-Location }
}
$pykernSha = Get-RepoShortSha $PykernDir
$sirepoSha = Get-RepoShortSha $SirepoDir

@"
date:       $(Get-Date -Format o)
python:     msys/python 3.12.13 (cygwin/posix)
sirepo:     $SirepoRef ($sirepoSha)
pykern:     $PykernRef ($pykernSha)
heavy-deps: $(if ($SkipHeavyDeps) { 'SKIPPED (numpy/matplotlib not installed)' } else { 'installed (numpy, matplotlib; scipy still missing)' })
"@ | Set-Content -Path $Stage3Marker -Encoding UTF8

Write-Host ""
Write-Host "Done. Sirepo + pykern installed in MSYS python user-site."
Write-Host "Next: try 'sirepo service http' or run scripts\04-try-sirepo.ps1 (TBD)"
