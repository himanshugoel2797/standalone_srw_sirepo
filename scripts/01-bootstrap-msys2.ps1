#requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap a portable MSYS2 install under <project>\msys64\.

.DESCRIPTION
  Downloads the MSYS2 base archive, verifies SHA256, extracts into the project
  tree, runs first-time pacman init, and does the initial -Syu sync. Idempotent;
  re-running is a no-op once .sirepo-win-bootstrap-ok exists. Use -Force to wipe
  and redo.

  No system installs. No registry writes. No system PATH changes. Deleting the
  project directory removes every trace.

.PARAMETER Version
  MSYS2 release tag (date form, e.g. '2024-11-16'). Find current options at
  https://github.com/msys2/msys2-installer/releases.

.PARAMETER ExpectedSha256
  Optional pinned SHA256 for the archive. If empty, the script attempts to
  download <archive>.sha256 from the release page and verify against that.
  For reproducible bundles, prefer pinning.

.PARAMETER SkipUpdate
  Skip the two `pacman -Syu` passes after extraction. Useful when mirrors are
  flaky or you want to install pinned packages from .cache first. Run
  `pacman -Syu` yourself later.

.PARAMETER Force
  Wipe an existing msys64\ directory and re-bootstrap.

.EXAMPLE
  .\scripts\01-bootstrap-msys2.ps1

.EXAMPLE
  .\scripts\01-bootstrap-msys2.ps1 -Version 2025-02-21 -ExpectedSha256 abc123...
#>
[CmdletBinding()]
param(
    [string]$Version = '2024-11-16',
    [string]$ExpectedSha256 = '',
    [switch]$SkipUpdate,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Paths (all project-local) ---
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Msys64Dir   = Join-Path $ProjectRoot 'msys64'
$CacheDir    = Join-Path $ProjectRoot '.cache'
$MarkerFile  = Join-Path $Msys64Dir '.sirepo-win-bootstrap-ok'

$DateTag     = $Version -replace '-',''
$ArchiveName = "msys2-base-x86_64-$DateTag.tar.xz"
$BaseUrl     = "https://github.com/msys2/msys2-installer/releases/download/$Version"
$ArchiveUrl  = "$BaseUrl/$ArchiveName"
$ShaUrl      = "$ArchiveUrl.sha256"

$ArchivePath = Join-Path $CacheDir $ArchiveName
$ShaPath     = "$ArchivePath.sha256"

Write-Host "=== Sirepo_Win MSYS2 bootstrap ==="
Write-Host "project root: $ProjectRoot"
Write-Host "msys64 dir:   $Msys64Dir"
Write-Host "version:      $Version"
Write-Host ""

# --- Pick an extractor: prefer tar.exe with xz, fall back to a downloaded 7zr.exe ---
function Resolve-Extractor {
    # tar.exe ships on Win10 1803+ and Win11 (or via Git for Windows). Test it can
    # actually decompress xz before trusting it.
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        try {
            $help = & $tar.Source --help 2>&1
            if ($help -match '(?i)\bxz\b' -or $LASTEXITCODE -eq 0) {
                Write-Host "Extractor: tar.exe ($($tar.Source))"
                return [pscustomobject]@{ Type = 'tar'; Path = $tar.Source }
            }
        } catch { }
        Write-Warning "tar.exe present but xz support unclear; falling back to 7zr.exe."
    }

    # Fall back: portable 7zr.exe from 7-zip.org (~600 KB, Authenticode-signed).
    $toolsDir = Join-Path $CacheDir 'tools'
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
    $sevenZrPath = Join-Path $toolsDir '7zr.exe'

    if (-not (Test-Path $sevenZrPath)) {
        Write-Host "Downloading portable 7zr.exe from 7-zip.org..."
        $oldPP = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri 'https://www.7-zip.org/a/7zr.exe' `
                              -OutFile $sevenZrPath -UseBasicParsing
        } finally { $ProgressPreference = $oldPP }
    }

    # Verify Authenticode signature -- 7-Zip binaries are signed by Igor Pavlov.
    $sig = Get-AuthenticodeSignature $sevenZrPath
    if ($sig.Status -ne 'Valid') {
        Remove-Item $sevenZrPath -Force
        throw "7zr.exe failed signature check ($($sig.Status): $($sig.StatusMessage)). Removed; re-run to retry."
    }
    Write-Host "Extractor: 7zr.exe (signed by $($sig.SignerCertificate.Subject -replace 'CN=([^,]+).*','$1'))"
    return [pscustomobject]@{ Type = '7zr'; Path = $sevenZrPath }
}

function Expand-MSYS2Archive {
    param($Extractor, $ArchivePath, $DestRoot)

    if ($Extractor.Type -eq 'tar') {
        & $Extractor.Path -xJf $ArchivePath -C $DestRoot
        if ($LASTEXITCODE -ne 0) { throw "tar extraction failed (exit $LASTEXITCODE)" }
        return
    }

    # 7zr does two passes: .tar.xz -> .tar -> tree
    $tmpDir = Join-Path $CacheDir 'extract-tmp'
    if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir }
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    try {
        Write-Host "  7zr pass 1: xz -> tar"
        & $Extractor.Path x $ArchivePath "-o$tmpDir" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7zr xz extract failed (exit $LASTEXITCODE)" }
        $tarFile = Get-ChildItem $tmpDir -Filter '*.tar' | Select-Object -First 1
        if (-not $tarFile) { throw "7zr xz extract produced no .tar file" }

        Write-Host "  7zr pass 2: tar -> tree"
        & $Extractor.Path x $tarFile.FullName "-o$DestRoot" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7zr tar extract failed (exit $LASTEXITCODE)" }
    } finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
}

# --- Idempotency ---
if ((Test-Path $MarkerFile) -and -not $Force) {
    Write-Host "Already bootstrapped:"
    Get-Content $MarkerFile | ForEach-Object { Write-Host "  $_" }
    Write-Host "Pass -Force to wipe and re-bootstrap."
    exit 0
}

if ((Test-Path $Msys64Dir) -and -not $Force) {
    throw "Directory exists but no marker file: $Msys64Dir`nPartial install? Re-run with -Force to wipe and retry."
}

# --- Resolve an extractor (uses .cache\) ---
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$extractor = Resolve-Extractor

if (-not (Test-Path $ArchivePath)) {
    Write-Host "Downloading $ArchiveUrl"
    $oldPP = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # ~10x faster downloads in PS 5.1
    try   { Invoke-WebRequest -Uri $ArchiveUrl -OutFile $ArchivePath -UseBasicParsing }
    finally { $ProgressPreference = $oldPP }
} else {
    Write-Host "Archive already in cache: $ArchivePath"
}

# --- Verify SHA256 ---
$actual = (Get-FileHash $ArchivePath -Algorithm SHA256).Hash.ToLower()

if ($ExpectedSha256) {
    $expected = $ExpectedSha256.Trim().ToLower()
    Write-Host "Verifying against pinned SHA256..."
    if ($expected -ne $actual) {
        Remove-Item $ArchivePath -Force
        throw "SHA256 mismatch (expected $expected, got $actual). Archive removed."
    }
    Write-Host "  OK ($actual)"
} else {
    # Try to fetch the published checksum file
    $verified = $false
    if (-not (Test-Path $ShaPath)) {
        try {
            Write-Host "Fetching $ShaUrl"
            Invoke-WebRequest -Uri $ShaUrl -OutFile $ShaPath -UseBasicParsing
        } catch {
            Write-Warning "Could not fetch $ShaUrl ($($_.Exception.Message))."
            Write-Warning "Skipping integrity check. To pin, re-run with -ExpectedSha256 $actual"
        }
    }
    if (Test-Path $ShaPath) {
        $expected = ((Get-Content $ShaPath -Raw) -split '\s+')[0].Trim().ToLower()
        if ($expected -ne $actual) {
            Remove-Item $ArchivePath -Force
            throw "SHA256 mismatch (expected $expected, got $actual). Archive removed; re-run to retry."
        }
        Write-Host "  Verified against published .sha256: $actual"
        $verified = $true
    }
    if (-not $verified) {
        Write-Warning "Archive used WITHOUT integrity verification. SHA256 was: $actual"
    }
}

# --- Extract ---
if (Test-Path $Msys64Dir) {
    Write-Host "Removing previous $Msys64Dir..."
    Remove-Item -Recurse -Force $Msys64Dir
}

Write-Host "Extracting (~1 minute)..."
Expand-MSYS2Archive -Extractor $extractor -ArchivePath $ArchivePath -DestRoot $ProjectRoot

$BashExe = Join-Path $Msys64Dir 'usr\bin\bash.exe'
if (-not (Test-Path $BashExe)) {
    throw "Extraction missing $BashExe -- archive layout unexpected."
}

# --- First-run init ---
# First bash invocation triggers MSYS2's post-install: creates /etc/profile,
# /tmp, user entries in /etc/passwd, fstab defaults, etc.
Write-Host "Running MSYS2 first-time init..."
& $BashExe -lc 'true'
# First run sometimes exits non-zero while still completing setup -- don't gate on it.

if (-not $SkipUpdate) {
    # pacman pass 1: may update pacman/msys2-runtime itself and force a shell exit
    Write-Host "pacman -Syu (pass 1)..."
    & $BashExe -lc 'pacman -Syu --noconfirm --noprogressbar'
    # Don't fail on pass 1 -- it intentionally exits when core packages are replaced.

    # pacman pass 2: complete the rest
    Write-Host "pacman -Syu (pass 2)..."
    & $BashExe -lc 'pacman -Syu --noconfirm --noprogressbar'
    if ($LASTEXITCODE -ne 0) { throw "pacman -Syu (pass 2) failed (exit $LASTEXITCODE)" }
}

# --- Smoke test ---
Write-Host "Smoke test: pacman -V"
& $BashExe -lc 'pacman -V | head -1'
if ($LASTEXITCODE -ne 0) { throw "Smoke test failed -- MSYS2 install is broken." }

# --- Marker ---
@"
version:    $Version
archive:    $ArchiveName
sha256:     $actual
bootstrap:  $(Get-Date -Format o)
updated:    $(if ($SkipUpdate) { 'NO (-SkipUpdate)' } else { 'yes (pacman -Syu x2)' })
"@ | Set-Content -Path $MarkerFile -Encoding UTF8

Write-Host ""
Write-Host "Done. MSYS2 ready at: $Msys64Dir"
Write-Host ""
Write-Host "Open a MinGW64 shell with:"
Write-Host "  & '$Msys64Dir\msys2_shell.cmd' -mingw64 -here -no-start -defterm"
