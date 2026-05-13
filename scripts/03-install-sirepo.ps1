#requires -Version 5.1
<#
.SYNOPSIS
  Install Sirepo + pykern inside the WSL distro (Ubuntu 24.04 LTS).

.DESCRIPTION
  Clones sirepo + pykern to <project>\sirepo and <project>\pykern (so the
  source stays visible/editable from the Windows side), and pip-installs them
  into a venv at /opt/sirepo-venv inside the WSL distro. Ubuntu's apt has
  every native dep prebuilt (no compile-from-source surprises like the
  MSYS path).

  Idempotent: re-running picks up where things were. -Force wipes the venv
  and reinstalls.

.PARAMETER DistroName
  WSL distro to install into. Must already be bootstrapped via step 02.

.PARAMETER SirepoRef
  Sirepo git ref to check out (default master).

.PARAMETER PykernRef
  pykern git ref to check out (default master).

.PARAMETER Force
  Wipe the venv and re-install. Source clones are kept (just `git pull`'d).
#>
[CmdletBinding()]
param(
    [string]$DistroName = 'sirepo-win',
    [string]$SirepoRef  = 'master',
    [string]$PykernRef  = 'master',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:WSL_UTF8 = '1'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$WslMarker   = Join-Path $ProjectRoot "wsl\.wsl-bootstrap-$DistroName-ok"
$Stage3Marker= Join-Path $ProjectRoot "wsl\.wsl-sirepo-$DistroName-ok"
$SirepoDir   = Join-Path $ProjectRoot 'sirepo'
$PykernDir   = Join-Path $ProjectRoot 'pykern'

if (-not (Test-Path $WslMarker)) {
    throw "WSL distro '$DistroName' not bootstrapped. Run scripts\02-bootstrap-wsl.ps1 first."
}

if ((Test-Path $Stage3Marker) -and -not $Force) {
    Write-Host "Sirepo already installed in '$DistroName':"
    Get-Content $Stage3Marker | ForEach-Object { Write-Host "  $_" }
    Write-Host "Pass -Force to wipe the venv and re-install."
    exit 0
}

# --- 1. Clone source on the Windows side (visible from /mnt/c inside distro) ---
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

# --- 2. Translate Windows paths to WSL paths ---
# C:\Users\hgoel\Documents\Sirepo_Win\sirepo -> /mnt/c/Users/hgoel/Documents/Sirepo_Win/sirepo
function Convert-WindowsPathToWsl {
    param([string]$Path)
    $abs = (Get-Item $Path).FullName
    $drive = $abs.Substring(0,1).ToLower()
    $rest = ($abs.Substring(2) -replace '\\','/')
    return "/mnt/$drive$rest"
}
$sirepoWsl = Convert-WindowsPathToWsl $SirepoDir
$pykernWsl = Convert-WindowsPathToWsl $PykernDir

Write-Host ""
Write-Host "Sirepo source (Windows): $SirepoDir"
Write-Host "Sirepo source (WSL):     $sirepoWsl"
Write-Host "pykern source (Windows): $PykernDir"
Write-Host "pykern source (WSL):     $pykernWsl"

# --- 3. Install apt deps + create venv + pip install inside the distro ---
# Build the bash script with single-quoted here-string (no PS interpolation),
# then inject the three values we need with -replace.
$installTmpl = @'
#!/bin/bash
set -euo pipefail

echo '--- apt update + install base packages ---'
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv python3-dev \
    git build-essential pkg-config \
    libffi-dev libssl-dev libxml2-dev libxslt1-dev \
    libjpeg-dev libpng-dev libfreetype-dev libtiff-dev libwebp-dev \
    zlib1g-dev libldap2-dev libsasl2-dev libldap-common \
    nodejs npm \
    curl ca-certificates

VENV=/opt/sirepo-venv
if [[ '@@FORCE@@' == 'True' && -d "$VENV" ]]; then
    echo '--- wiping existing venv (-Force) ---'
    rm -rf "$VENV"
fi

if [[ ! -d "$VENV" ]]; then
    echo '--- creating venv at /opt/sirepo-venv ---'
    python3 -m venv "$VENV"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"

echo '--- upgrade pip + install pykern (editable) ---'
pip install --upgrade pip wheel setuptools
pip install -e '@@PYKERN@@'

echo '--- install sirepo (editable; pulls its remaining deps) ---'
pip install -e '@@SIREPO@@'

echo '--- smoke test ---'
which sirepo
python -c 'import sirepo, pykern; print("sirepo:", sirepo.__file__); print("pykern:", pykern.__file__)'
sirepo --help 2>&1 | head -5 || true
'@

$installScript = $installTmpl `
    -replace '@@FORCE@@',  ([string]$Force.IsPresent) `
    -replace '@@PYKERN@@', $pykernWsl `
    -replace '@@SIREPO@@', $sirepoWsl

$tmpHost = Join-Path $env:TEMP "sirepo-install-$([guid]::NewGuid().ToString('N')).sh"
try {
    # bash needs LF line endings even if the file is on NTFS
    [System.IO.File]::WriteAllText($tmpHost, ($installScript -replace "`r",''), [System.Text.UTF8Encoding]::new($false))
    $tmpWsl = Convert-WindowsPathToWsl $tmpHost
    Write-Host ""
    Write-Host "=== running install script inside '$DistroName' (this takes 2-5 min) ==="
    & wsl.exe -d $DistroName --user root -- bash "$tmpWsl"
    if ($LASTEXITCODE -ne 0) {
        throw "Install script failed inside distro (exit $LASTEXITCODE)"
    }
} finally {
    Remove-Item $tmpHost -ErrorAction SilentlyContinue
}

# --- 4. Stage marker ---
function Get-RepoShortSha {
    param([string]$Dir)
    Push-Location $Dir
    try { (& git rev-parse --short HEAD).Trim() } finally { Pop-Location }
}
$sirepoSha = Get-RepoShortSha $SirepoDir
$pykernSha = Get-RepoShortSha $PykernDir

@"
date:       $(Get-Date -Format o)
distro:     $DistroName
venv:       /opt/sirepo-venv (inside distro)
sirepo:     $SirepoRef ($sirepoSha)  at  $SirepoDir
pykern:     $PykernRef ($pykernSha)  at  $PykernDir
"@ | Set-Content -Path $Stage3Marker -Encoding UTF8

Write-Host ""
Write-Host "Done. Sirepo installed in '$DistroName' at /opt/sirepo-venv."
Write-Host "Run it with:"
Write-Host "  wsl -d $DistroName -- /opt/sirepo-venv/bin/sirepo service http"
