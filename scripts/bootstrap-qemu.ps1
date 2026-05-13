#requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap an embedded QEMU/TCG Linux VM hosting Sirepo. Truly portable
  backend alternative to bootstrap-wsl.ps1 -- requires NO admin elevation.

.DESCRIPTION
  Pipeline (all under <project>\, no admin, no Windows features):
    1. Bootstrap MSYS2 into <project>\msys64 via scripts\bootstrap-msys2.ps1.
       MSYS2 is needed only as a portable package fetcher: `pacman -S
       mingw-w64-x86_64-qemu` gives us real QEMU binaries + all their
       transitive DLL deps without touching system paths or registry.
       (Stefan Weil's standalone QEMU installer is the canonical Windows
       binary distribution, but its NSIS requires-admin manifest makes it
       unusable for a no-admin install. MSYS2's package archive is the
       portable alternative.)
    2. pacman-install mingw-w64-x86_64-qemu. ~500 MB of QEMU+deps land in
       msys64\mingw64\.
    3. Download Ubuntu 22.04 (jammy) cloud qcow2 image, verify SHA256.
       Jammy chosen over noble (24.04) because noble's 6.8 kernel panics on
       IO-APIC timer init under QEMU TCG. Override $UbuntuUrl to pick a
       different release.
    4. Sync sirepo + pykern source on the Windows side (via git). The VM
       sees these through the WebDAV mount, not via a clone-inside-VM.
    5. Create a writable overlay qcow2 so the base image stays pristine.
    6. Generate a NoCloud cloud-init seed ISO embedding the systemd unit,
       davfs2 secrets, and a mount-host-src.sh helper. cloud-init's runcmd
       installs davfs2, mounts the WebDAV share, then runs install-sirepo.sh
       straight out of the mounted Windows source.
    7. Before launching QEMU: verify the worker (which serves /run + /dav)
       is running on 127.0.0.1:$WorkerPort. Fail fast if not.
    8. Launch QEMU with user-mode networking + hostfwd of $HostPort:8000.

  Cloud-init installs and starts Sirepo on first boot. Total bundle for the
  QEMU backend (msys64 + QEMU + Ubuntu jammy image + overlay + python-native):
  ~1.5 GB.

.PARAMETER UbuntuUrl
  HTTPS URL of Ubuntu cloud qcow2.

.PARAMETER Sha256SumsUrl
  URL of SHA256SUMS file alongside the qcow2.

.PARAMETER Memory
  Guest memory in GB. Default 4.

.PARAMETER Cpus
  Guest vCPU count. Default 2.

.PARAMETER HostPort
  Windows host port that maps to the VM's port 8000. Default 8000.

.PARAMETER Force
  Wipe overlay disk + re-generate seed ISO. Keeps MSYS2 and Ubuntu image.

.PARAMETER NoStart
  Set up everything but don't launch QEMU at the end.
#>
[CmdletBinding()]
param(
    # Ubuntu 22.04 (jammy, kernel 5.15) is the well-trodden TCG combo. Noble
    # (24.04, kernel 6.8) panics on IO-APIC timer init under TCG -- working
    # around that needs -kernel/-initrd/-append "noapic" + tracking the
    # cloud-images unpacked artifacts separately. Not worth the fragility for
    # a backend whose job is to be a portable demo target. Override these
    # params if you have a TCG fix and want noble back.
    [string]$UbuntuUrl     = 'https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img',
    [string]$Sha256SumsUrl = 'https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS',
    [int]   $Memory        = 4,
    [int]   $Cpus          = 2,
    [int]   $HostPort      = 8000,
    [int]   $WorkerPort    = 8311,
    [string]$SirepoRef     = 'master',
    [string]$PykernRef     = 'master',
    [switch]$Force,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Paths (all project-local) ---
$ProjectRoot   = Split-Path -Parent $PSScriptRoot
$Msys64Dir     = Join-Path $ProjectRoot 'msys64'
$VmDir         = Join-Path $ProjectRoot 'qemu-vm'
$CacheDir      = Join-Path $ProjectRoot '.cache'
$MsysBootstrap = Join-Path $PSScriptRoot 'bootstrap-msys2.ps1'

$BootstrapMarker  = Join-Path $Msys64Dir '.sirepo-win-bootstrap-ok'
$QemuPacmanMarker = Join-Path $Msys64Dir '.qemu-installed-ok'
$VmReadyMarker    = Join-Path $VmDir '.vm-ready'

$QemuExe        = Join-Path $Msys64Dir 'mingw64\bin\qemu-system-x86_64.exe'
$QemuImgExe     = Join-Path $Msys64Dir 'mingw64\bin\qemu-img.exe'
$QemuShareDir   = Join-Path $Msys64Dir 'mingw64\share\qemu'

$BaseImage      = Join-Path $CacheDir 'ubuntu-22.04-jammy-amd64.qcow2'
$OverlayImage   = Join-Path $VmDir 'overlay.qcow2'
$SeedIso        = Join-Path $VmDir 'seed.iso'

$SirepoDir      = Join-Path $ProjectRoot 'sirepo'
$PykernDir      = Join-Path $ProjectRoot 'pykern'

# Slirp NATs guest -> 10.0.2.2 to host's 127.0.0.1 by default. The VM mounts
# http://10.0.2.2:$WorkerPort/dav/ via davfs2 to see the Windows project tree.
$WebdavGuestUrl = "http://10.0.2.2:$WorkerPort/dav/"

Write-Host "=== Sirepo_Win embedded-VM (QEMU/TCG) bootstrap ==="
Write-Host "project root: $ProjectRoot"
Write-Host "msys64 dir:   $Msys64Dir  (portable QEMU lives here)"
Write-Host "vm dir:       $VmDir"
Write-Host ""

New-Item -ItemType Directory -Force -Path $VmDir, $CacheDir | Out-Null

function Sync-Repo {
    # Clone-or-update a git repo at Dest, checked out at Ref. Duplicated from
    # install-sirepo.ps1 -- both backends need the source on the Windows side.
    # TODO: factor into common.psm1 if a third caller appears.
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

# --- 1. Bootstrap MSYS2 (portable, no admin) ---
if (-not (Test-Path $BootstrapMarker)) {
    Write-Host "--- MSYS2 not present; running bootstrap-msys2.ps1 ---"
    if (-not (Test-Path $MsysBootstrap)) {
        throw "Missing $MsysBootstrap"
    }
    & $MsysBootstrap
    if ($LASTEXITCODE -ne 0 -and -not (Test-Path $BootstrapMarker)) {
        throw "bootstrap-msys2.ps1 failed."
    }
} else {
    Write-Host "MSYS2 already bootstrapped at $Msys64Dir"
}

$BashExe = Join-Path $Msys64Dir 'usr\bin\bash.exe'
if (-not (Test-Path $BashExe)) { throw "MSYS2 bash missing at $BashExe" }

# --- 2. pacman -S mingw-w64-x86_64-qemu (portable QEMU + DLL deps) ---
if ((Test-Path $QemuPacmanMarker) -and (Test-Path $QemuExe) -and -not $Force) {
    Write-Host "QEMU already pacman-installed in msys64/mingw64/."
} else {
    Write-Host "--- Installing mingw-w64-x86_64-qemu via pacman (this pulls ~500 MB of deps) ---"
    & $BashExe -lc 'pacman -S --needed --noconfirm --noprogressbar mingw-w64-x86_64-qemu'
    if ($LASTEXITCODE -ne 0) { throw "pacman install of qemu failed (exit $LASTEXITCODE)" }
    if (-not (Test-Path $QemuExe)) { throw "qemu-system-x86_64.exe missing at $QemuExe after pacman install" }
    $qemuPkgVersion = (& $BashExe -lc 'pacman -Q mingw-w64-x86_64-qemu' | Out-String).Trim()
    @"
date: $(Get-Date -Format o)
qemu: $qemuPkgVersion
"@ | Set-Content $QemuPacmanMarker -Encoding UTF8
}

Write-Host "Using: $QemuExe"

# --- 3. Download Ubuntu cloud qcow2 + verify SHA256 ---
Write-Host ""
Write-Host "--- Ubuntu cloud image ($UbuntuUrl) ---"

function Get-Sha256FromSums {
    param([string]$Url, [string]$Filename)
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing
    $text = if ($resp.Content -is [byte[]]) {
        [System.Text.Encoding]::UTF8.GetString($resp.Content)
    } else { [string]$resp.Content }
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^([0-9a-f]{64})\s+\*?(.+)$' -and $Matches[2].Trim() -eq $Filename) {
            return $Matches[1].ToLower()
        }
    }
    throw "No SHA256 entry for '$Filename' in $Url"
}

$qcowFilename = Split-Path -Leaf $UbuntuUrl
$baseQcowCache = Join-Path $CacheDir $qcowFilename
if (-not (Test-Path $baseQcowCache) -or $Force) {
    Write-Host "Downloading $UbuntuUrl"
    $oldPP = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $UbuntuUrl -OutFile $baseQcowCache -UseBasicParsing }
    finally { $ProgressPreference = $oldPP }
} else {
    Write-Host "Cached: $baseQcowCache"
}
$expectedSha = Get-Sha256FromSums -Url $Sha256SumsUrl -Filename $qcowFilename
$actual = (Get-FileHash $baseQcowCache -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expectedSha) {
    Remove-Item $baseQcowCache -Force
    throw "Ubuntu qcow2 SHA256 mismatch (expected $expectedSha, got $actual). Cached file removed; re-run."
}
Write-Host "Ubuntu image verified: $actual"

if (-not (Test-Path $BaseImage) -or $Force) {
    Copy-Item -Path $baseQcowCache -Destination $BaseImage -Force
}

# --- 4. Create writable overlay qcow2 ---
if ((Test-Path $OverlayImage) -and -not $Force) {
    Write-Host "Overlay exists: $OverlayImage"
} else {
    if (Test-Path $OverlayImage) { Remove-Item $OverlayImage -Force }
    Write-Host "Creating overlay (backing file = base image)..."
    & $QemuImgExe create -f qcow2 -F qcow2 -b $BaseImage $OverlayImage 20G | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "qemu-img create failed" }
}

# --- 5. Ensure sirepo + pykern source on Windows side ---
# The VM mounts the project tree over WebDAV (see step 6) and pip installs
# Sirepo from /mnt/host-src/sirepo. Source has to exist before the VM tries
# to read it.
Write-Host ""
Write-Host "--- Syncing sirepo + pykern source on Windows side ---"
Sync-Repo -Url 'https://github.com/radiasoft/pykern.git' -Dest $PykernDir -Ref $PykernRef
Sync-Repo -Url 'https://github.com/radiasoft/sirepo.git' -Dest $SirepoDir -Ref $SirepoRef

# --- 6. Build cloud-init seed ISO via IMAPI2 COM (Windows built-in) ---
# user-data tells the VM to:
#   1. apt install davfs2 + cifs-utils (cifs as fallback)
#   2. configure davfs2 to do anonymous Basic auth, no locks, no caching
#   3. mount $WebdavGuestUrl at /mnt/host-src
#   4. run install-sirepo.sh out of the mounted source tree (editable install)
# install-sirepo.sh is no longer embedded -- it comes through the mount.
Write-Host ""
Write-Host "--- Generating cloud-init seed ISO ---"

$userData = @"
#cloud-config
hostname: sirepo-qemu
manage_etc_hosts: true

ssh_pwauth: true
users:
  - name: sirepo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: sirepo

write_files:
  - path: /etc/systemd/system/sirepo.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Sirepo (SRW)
      After=network-online.target host-src.mount
      Wants=network-online.target host-src.mount

      [Service]
      Type=simple
      Environment=SIREPO_FEATURE_CONFIG_TRUST_SH_ENV=1
      Environment=SIREPO_FEATURE_CONFIG_SIM_TYPES=srw
      Environment=PATH=/opt/sirepo-venv/bin:/usr/local/bin:/usr/bin:/bin
      WorkingDirectory=/var/sirepo
      ExecStartPre=/bin/mkdir -p /var/sirepo
      ExecStart=/opt/sirepo-venv/bin/sirepo service http
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
  - path: /usr/local/sbin/mount-host-src.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      mkdir -p /mnt/host-src
      # Configure davfs2: anonymous Basic auth, no client-side cache, no
      # locks (wsgidav supports locks but we don't need them and they slow
      # down editable installs).
      echo '$WebdavGuestUrl guest guest' > /etc/davfs2/secrets
      chmod 600 /etc/davfs2/secrets
      sed -i 's|^# *ask_auth .*|ask_auth 0|' /etc/davfs2/davfs2.conf
      sed -i 's|^# *use_locks .*|use_locks 0|' /etc/davfs2/davfs2.conf
      sed -i 's|^# *gui_optimize .*|gui_optimize 0|' /etc/davfs2/davfs2.conf
      # Retry briefly in case the worker isn't yet up when cloud-init runs.
      for i in 1 2 3 4 5; do
          if mount -t davfs -o rw,_netdev $WebdavGuestUrl /mnt/host-src; then
              echo "host-src mounted"; exit 0
          fi
          echo "mount attempt `$i failed; sleeping"
          sleep 5
      done
      echo "ERROR: could not mount $WebdavGuestUrl after 5 tries" >&2
      exit 1

runcmd:
  # IMPORTANT: install davfs2 FIRST so its conffiles (incl. /etc/davfs2/secrets)
  # land on disk before mount-host-src.sh overwrites them. Writing them via
  # cloud-init write_files (which runs before runcmd) trips a dpkg conffile
  # prompt that even DEBIAN_FRONTEND=noninteractive doesn't suppress, and the
  # package's --configure step exits non-zero.
  - apt-get update -qq
  - DEBIAN_FRONTEND=noninteractive apt-get install -y davfs2
  - /usr/local/sbin/mount-host-src.sh
  - bash /mnt/host-src/scripts/install-sirepo.sh --patches /mnt/host-src/sirepo_patches /mnt/host-src/sirepo /mnt/host-src/pykern
  - systemctl daemon-reload
  - systemctl enable --now sirepo.service
"@

$metaData = @"
instance-id: sirepo-qemu-01
local-hostname: sirepo-qemu
"@

# Force LF endings throughout (cloud-init/bash chokes on CRLF in YAML content)
$userData = $userData -replace "`r",''
$metaData = $metaData -replace "`r",''

# C# helper to copy IMAPI2's IStream to disk. PowerShell can't reliably marshal
# IStream's vtable-only methods, so we do the copy in C#. Drive the loop with
# BlockSize/TotalBlocks from the result (more reliable than IStream.Stat).
if (-not ('SirepoIsoCopy' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class SirepoIsoCopy {
    public static void Save(string path, object stream, int blockSize, int totalBlocks) {
        IStream i = stream as IStream;
        if (i == null) throw new InvalidCastException("ImageStream did not implement IStream");
        byte[] buf = new byte[blockSize];
        IntPtr nRead = Marshal.AllocHGlobal(sizeof(int));
        try {
            using (FileStream o = File.OpenWrite(path)) {
                while (totalBlocks-- > 0) {
                    i.Read(buf, blockSize, nRead);
                    int actual = Marshal.ReadInt32(nRead);
                    if (actual <= 0) break;
                    o.Write(buf, 0, actual);
                }
                o.Flush();
            }
        } finally {
            Marshal.FreeHGlobal(nRead);
        }
    }
}
'@
}

function New-CloudInitSeedIso {
    param([hashtable]$Files, [string]$VolumeLabel, [string]$OutPath)

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    # MediaType 12 = IMAPI_MEDIA_TYPE_DISK. Use the media-type variant: passing
    # $null to ChooseImageDefaults marshals to a null IUnknown, which throws.
    $fsi.ChooseImageDefaultsForMediaType(12)
    $fsi.VolumeName = $VolumeLabel
    $fsi.FileSystemsToCreate = 3   # ISO9660 | Joliet (cloud-init NoCloud needs only these)

    foreach ($entry in $Files.GetEnumerator()) {
        $bytes  = [System.Text.Encoding]::UTF8.GetBytes($entry.Value)
        $stream = New-Object -ComObject ADODB.Stream
        $stream.Type = 1                # adTypeBinary
        $stream.Open()
        $stream.Write($bytes)
        $stream.Position = 0
        $fsi.Root.AddFile($entry.Key, $stream) | Out-Null
        $stream.Close()
    }

    if (Test-Path $OutPath) { Remove-Item $OutPath -Force }
    $result = $fsi.CreateResultImage()
    [SirepoIsoCopy]::Save($OutPath, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)
}

New-CloudInitSeedIso `
    -Files @{ 'user-data' = $userData; 'meta-data' = $metaData } `
    -VolumeLabel 'CIDATA' `
    -OutPath $SeedIso

if (-not (Test-Path $SeedIso)) { throw "Seed ISO generation produced no file at $SeedIso" }
$seedSize = (Get-Item $SeedIso).Length
if ($seedSize -lt 1024) { throw "Seed ISO is suspiciously small ($seedSize bytes)" }

Write-Host "Seed ISO: $SeedIso ($([math]::Round((Get-Item $SeedIso).Length/1KB)) KB)"

# --- 6. Mark ready ---
@"
date:       $(Get-Date -Format o)
qemu:       $QemuExe
base image: $BaseImage
overlay:    $OverlayImage
seed iso:   $SeedIso
memory:     $($Memory)G
cpus:       $Cpus
host port:  $HostPort
"@ | Set-Content $VmReadyMarker -Encoding UTF8

Write-Host ""
Write-Host "VM artifacts ready."

if ($NoStart) {
    Write-Host "Skipping QEMU launch (-NoStart). Before launching, start the worker"
    Write-Host "(serves /run + /dav over WebDAV at port $WorkerPort):"
    Write-Host "  & '$ProjectRoot\python-native\python.exe' '$ProjectRoot\worker\worker.py' --port $WorkerPort"
    Write-Host "Then launch QEMU:"
    Write-Host "  $QemuExe -accel whpx -accel tcg,thread=multi,tb-size=512 -m ${Memory}G -smp $Cpus -drive file=$OverlayImage,format=qcow2,if=virtio -drive file=$SeedIso,format=raw,media=cdrom -netdev user,id=net0,hostfwd=tcp::${HostPort}-:8000 -device virtio-net,netdev=net0 -nographic"
    exit 0
}

# --- 7. Worker-running guard ---
# cloud-init mounts http://10.0.2.2:$WorkerPort/dav/ in the guest, NATed by
# slirp to the host's 127.0.0.1. If the worker isn't running, the mount-retry
# loop in cloud-init will eventually give up and Sirepo won't install. Bail
# early so the user knows.
Write-Host ""
Write-Host "--- Checking worker on 127.0.0.1:$WorkerPort ---"
try {
    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$WorkerPort/health" `
                              -UseBasicParsing -TimeoutSec 3
    $body = if ($resp.Content -is [byte[]]) {
        [System.Text.Encoding]::UTF8.GetString($resp.Content)
    } else { [string]$resp.Content }
    Write-Host "  worker OK: $($body.Substring(0, [Math]::Min(120, $body.Length)))..."
} catch {
    Write-Host ""
    Write-Host "ERROR: native worker is not responding on 127.0.0.1:$WorkerPort." -ForegroundColor Red
    Write-Host "The QEMU guest needs to mount http://10.0.2.2:$WorkerPort/dav/ via WebDAV"
    Write-Host "before cloud-init can install Sirepo. Start the worker first:"
    Write-Host ""
    Write-Host "  & '$ProjectRoot\python-native\python.exe' '$ProjectRoot\worker\worker.py' --port $WorkerPort"
    Write-Host ""
    Write-Host "(Or run scripts\bootstrap-python-native.ps1 if the python-native bundle is missing.)"
    throw "Worker not running."
}

# --- 8. Detect accelerator availability for user-visible messaging ---
# QEMU itself does the actual fallback via chained -accel flags; this is just
# so the user knows what to expect timing-wise. WHPX needs no admin to USE,
# but the underlying feature needs admin to ENABLE -- so we check rather than
# offering to enable it.
$whpxAvailable = $false
$vmcompute = Get-Service -Name vmcompute -ErrorAction SilentlyContinue
if ($vmcompute) {
    # vmcompute (Hyper-V Host Compute Service) being present is a strong
    # signal the WHPX feature is enabled (it's installed with the feature).
    $whpxAvailable = $true
}

Write-Host ""
Write-Host "=== Launching QEMU ==="
if ($whpxAvailable) {
    Write-Host "Accelerator: WHPX (Windows Hypervisor Platform) detected; will be tried first." -ForegroundColor Green
    Write-Host "Expected install time: ~5-10 min (near-native CPU speed)."
} else {
    Write-Host "Accelerator: WHPX not available; falling back to TCG (software emulation)." -ForegroundColor Yellow
    Write-Host "Expected install time: ~20-30 min. To make this faster, enable the Windows"
    Write-Host "Hypervisor Platform feature (admin/UAC needed once):"
    Write-Host "  Settings > Programs > Windows Features > Windows Hypervisor Platform"
}
Write-Host ""
Write-Host "Once cloud-init finishes, Sirepo will be at http://localhost:$HostPort"
Write-Host ""

$qemuArgs = @(
    # Try WHPX (Windows Hypervisor Platform) first -- runs guest code on the
    # CPU via Windows' user-mode hypervisor API, ~1.5x of native vs TCG's
    # 3-10x slower-than-native. Requires the "Windows Hypervisor Platform"
    # optional feature to be enabled (usually already on if user has Docker
    # Desktop, WSL2, or Hyper-V). If WHPX init fails, QEMU falls through to
    # the next -accel automatically. TCG flags: thread=multi exploits
    # multiple host cores for translation; tb-size=512 grows the translated-
    # block cache (saves re-translation overhead on long-running guests).
    '-accel', 'whpx',
    '-accel', 'tcg,thread=multi,tb-size=512',
    '-m', "${Memory}G",
    '-smp', "$Cpus",
    '-drive', "file=$OverlayImage,format=qcow2,if=virtio",
    '-drive', "file=$SeedIso,format=raw,media=cdrom",
    '-netdev', "user,id=net0,hostfwd=tcp::${HostPort}-:8000",
    '-device', 'virtio-net,netdev=net0',
    '-L', $QemuShareDir,
    '-nographic'
)

& $QemuExe @qemuArgs
