#requires -Version 5.1
<#
.SYNOPSIS
  Install Sirepo + pykern inside the WSL distro by running install-sirepo.sh.

.DESCRIPTION
  Backend-specific glue. For WSL2:
    1. Clone sirepo + pykern source into <project>\sirepo and <project>\pykern
       so they stay visible/editable from the Windows side.
    2. Invoke scripts\install-sirepo.sh inside the distro, pointing it at the
       /mnt/c/.../sirepo and /mnt/c/.../pykern source paths.

  The QEMU backend uses the same install-sirepo.sh but invokes it via
  cloud-init during first boot, with sources cloned inside the VM.

.PARAMETER DistroName
  WSL distro to install into. Must already be bootstrapped via bootstrap-wsl.ps1.

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

$ProjectRoot   = Split-Path -Parent $PSScriptRoot
$WslMarker     = Join-Path $ProjectRoot "wsl\.wsl-bootstrap-$DistroName-ok"
$Stage3Marker  = Join-Path $ProjectRoot "wsl\.wsl-sirepo-$DistroName-ok"
$SirepoDir     = Join-Path $ProjectRoot 'sirepo'
$PykernDir     = Join-Path $ProjectRoot 'pykern'
$InstallShHost = Join-Path $PSScriptRoot 'install-sirepo.sh'

if (-not (Test-Path $WslMarker)) {
    throw "WSL distro '$DistroName' not bootstrapped. Run scripts\bootstrap-wsl.ps1 first."
}
if (-not (Test-Path $InstallShHost)) {
    throw "Missing $InstallShHost"
}

if ((Test-Path $Stage3Marker) -and -not $Force) {
    Write-Host "Sirepo already installed in '$DistroName':"
    Get-Content $Stage3Marker | ForEach-Object { Write-Host "  $_" }
    Write-Host "Pass -Force to wipe the venv and re-install."
    exit 0
}

# --- 1. Clone source on the Windows side ---
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

# --- 2. Path translation Windows -> WSL (/mnt/c/...) ---
function Convert-WindowsPathToWsl {
    param([string]$Path)
    $abs   = (Get-Item $Path).FullName
    $drive = $abs.Substring(0,1).ToLower()
    $rest  = ($abs.Substring(2) -replace '\\','/')
    return "/mnt/$drive$rest"
}

$sirepoWsl    = Convert-WindowsPathToWsl $SirepoDir
$pykernWsl    = Convert-WindowsPathToWsl $PykernDir
$installShWsl = Convert-WindowsPathToWsl $InstallShHost

Write-Host ""
Write-Host "Source paths (visible inside distro):"
Write-Host "  install-sirepo.sh -> $installShWsl"
Write-Host "  sirepo            -> $sirepoWsl"
Write-Host "  pykern            -> $pykernWsl"

# --- 3. Ensure install-sirepo.sh has LF endings (bash chokes on CRLF shebangs) ---
$shContent = Get-Content -Raw $InstallShHost
if ($shContent -match "`r`n") {
    Write-Host "Normalizing install-sirepo.sh to LF endings..."
    [System.IO.File]::WriteAllText($InstallShHost, ($shContent -replace "`r",''),
        [System.Text.UTF8Encoding]::new($false))
}

# --- 4. Run install-sirepo.sh inside the distro ---
Write-Host ""
Write-Host "=== Running install-sirepo.sh inside '$DistroName' (2-5 min) ==="
$forceArg = if ($Force) { '--force' } else { '' }
$bashCmd  = "bash $installShWsl $forceArg '$sirepoWsl' '$pykernWsl'"
& wsl.exe -d $DistroName --user root -- bash -c $bashCmd
if ($LASTEXITCODE -ne 0) {
    throw "install-sirepo.sh failed inside distro (exit $LASTEXITCODE)"
}

# --- 5. Marker ---
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
Write-Host "Run with:"
Write-Host "  wsl -d $DistroName -- bash $(Convert-WindowsPathToWsl (Join-Path $PSScriptRoot 'run-sirepo.sh'))"
