#requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap an embedded QEMU Linux VM hosting Sirepo. Fully portable --
  requires NO admin elevation. Uses WHPX (Windows Hypervisor Platform) for
  near-native speed when available, falls back to TCG software emulation.

.DESCRIPTION
  Pipeline (all under <project>\, no admin, no Windows features):
    1. Download the prebuilt QEMU portable bundle from GitHub Releases
       (x86_64-only; UI stripped; non-x86 firmware excluded -- ~120 MB
       compressed vs. ~700 MB MSYS2 install). Verify SHA256, extract to
       <project>\qemu\. Built by .github/workflows/build-qemu-bundle.yml.
       Override with -QemuBundleUrl / -QemuBundleSha256 or env vars
       SIREPO_WIN_QEMU_URL / SIREPO_WIN_QEMU_SHA256 for testing.
    2. Download Ubuntu 22.04 (jammy) cloud qcow2 image, verify SHA256.
       Jammy chosen over noble (24.04) because noble's 6.8 kernel panics on
       IO-APIC timer init under QEMU TCG. Override $UbuntuUrl to pick a
       different release.
    3. Create a writable overlay qcow2 so the base image stays pristine.
    4. Generate a NoCloud cloud-init seed ISO inlining install-sirepo.sh,
       the windows_native job-driver patch, the sirepo.service unit, and a
       mount-host-runs.sh helper. cloud-init's runcmd: apt install davfs2
       + git, mount the worker's WebDAV /dav share at /mnt/host-runs (narrow
       data pipe -- just SRW job dirs), git clone sirepo+pykern to /opt/,
       run install-sirepo.sh --patches.
    5. Before launching QEMU: verify the worker (which serves /run + /dav)
       is running on 127.0.0.1:$WorkerPort. Fail fast if not.
    6. Launch QEMU with user-mode networking + hostfwd of $HostPort:8000.
       Tries WHPX first (Windows Hypervisor Platform, ~1.5x native), falls
       back to TCG software emulation (10-50x slower for SRW FP work, but
       Sirepo itself is just I/O/HTTP -- compute is on the Windows side).

  Cloud-init installs and starts Sirepo on first boot. Total bundle on disk
  (qemu/ + Ubuntu jammy image + overlay + python-native): ~1 GB.

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
    # Prebuilt portable QEMU bundle. Defaults read SIREPO_WIN_QEMU_URL /
    # SIREPO_WIN_QEMU_SHA256 (set by setup.ps1 or for local-bundle testing).
    # The "real" prod URL lives in setup.ps1 as a constant; this script
    # accepts overrides without caring where the URL points.
    [string]$QemuBundleUrl    = ($env:SIREPO_WIN_QEMU_URL),
    [string]$QemuBundleSha256 = ($env:SIREPO_WIN_QEMU_SHA256),
    [int]   $Memory        = 4,
    [int]   $Cpus          = 2,
    [int]   $HostPort      = 8000,
    [int]   $WorkerPort    = 8311,
    [int]   $ControlPort   = 8312,
    [string]$SirepoRef     = 'master',
    [string]$PykernRef     = 'master',
    [switch]$Force,
    [switch]$NoStart,
    # Launch QEMU as a detached background process (Start-Process -PassThru)
    # so the caller can keep running (e.g. setup.ps1's WinForms control UI).
    # In this mode the script returns the QEMU process; the caller owns cleanup.
    [switch]$Detached
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Paths (all project-local) ---
$ProjectRoot   = Split-Path -Parent $PSScriptRoot
$QemuDir       = Join-Path $ProjectRoot 'qemu'
$VmDir         = Join-Path $ProjectRoot 'qemu-vm'
$CacheDir      = Join-Path $ProjectRoot '.cache'

$QemuReadyMarker = Join-Path $QemuDir '.qemu-ready'
$VmReadyMarker   = Join-Path $VmDir '.vm-ready'

$QemuExe        = Join-Path $QemuDir 'bin\qemu-system-x86_64.exe'
$QemuImgExe     = Join-Path $QemuDir 'bin\qemu-img.exe'
$QemuShareDir   = Join-Path $QemuDir 'share\qemu'

$BaseImage      = Join-Path $CacheDir 'ubuntu-22.04-jammy-amd64.qcow2'
$OverlayImage   = Join-Path $VmDir 'overlay.qcow2'
$SeedIso        = Join-Path $VmDir 'seed.iso'

$InstallShHost  = Join-Path $PSScriptRoot 'install-sirepo.sh'
$PatchesHost    = Join-Path $ProjectRoot 'sirepo_patches'
$RunsHost       = Join-Path $ProjectRoot 'state\runs'

# Slirp NATs guest -> 10.0.2.2 to host's 127.0.0.1 by default. The VM mounts
# http://10.0.2.2:$WorkerPort/dav/ via davfs2 at /mnt/host-runs. The WebDAV
# share is NARROW: only the SRW job run-dir tree (state/runs). Sirepo source
# is cloned inside the VM at /opt/{sirepo,pykern} -- no symlink/WebDAV-import
# gymnastics, just normal ext4. The windows_native job driver writes a job's
# run.py + inputs into /mnt/host-runs/<jid>/, then HTTP POSTs the worker's
# /run endpoint pointing at that path; the worker reads it back from
# $RunsHost on the Windows side and executes natively.
$WebdavGuestUrl = "http://10.0.2.2:$WorkerPort/dav/"

Write-Host "=== Sirepo_Win embedded-VM (QEMU) bootstrap ==="
Write-Host "project root: $ProjectRoot"
Write-Host "qemu dir:     $QemuDir  (portable QEMU bundle extracted here)"
Write-Host "vm dir:       $VmDir"
Write-Host ""

New-Item -ItemType Directory -Force -Path $VmDir, $CacheDir, $RunsHost | Out-Null

# --- 1. Fetch + extract the prebuilt portable QEMU bundle ---
# Built by .github/workflows/build-qemu-bundle.yml on a Windows runner that
# pacman-installs MSYS2's mingw-w64-x86_64-qemu, stages just the bits we use
# (qemu-system-x86_64.exe, qemu-img.exe, runtime DLLs, x86 firmware), and
# publishes a zip to GitHub Releases. ~120 MB compressed vs. ~700 MB MSYS2.
if ((Test-Path $QemuReadyMarker) -and (Test-Path $QemuExe) -and -not $Force) {
    $ready = Get-Content $QemuReadyMarker -Raw
    Write-Host "QEMU bundle already extracted at $QemuDir"
    Write-Host ($ready.Trim() -split "`n" | ForEach-Object { "  $_" }) -Separator "`n"
} else {
    if (-not $QemuBundleUrl) {
        throw @"
No QEMU bundle URL configured. Either:
  - run .github/workflows/build-qemu-bundle.yml once and set
    SIREPO_WIN_QEMU_URL + SIREPO_WIN_QEMU_SHA256 to the release asset, or
  - pass -QemuBundleUrl / -QemuBundleSha256 to this script.
Bundle layout expected: zip with bin/qemu-system-x86_64.exe at top level.
"@
    }

    if (Test-Path $QemuDir) { Remove-Item -Recurse -Force $QemuDir }
    New-Item -ItemType Directory -Force -Path $QemuDir | Out-Null

    $bundleZip = Join-Path $CacheDir 'qemu-portable.zip'
    Write-Host "--- Downloading QEMU bundle ($QemuBundleUrl) ---"
    $oldPP = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        if ($QemuBundleUrl.StartsWith('file:///', [StringComparison]::OrdinalIgnoreCase)) {
            # Local-file URL for testing. Convert to a normal path and copy.
            $localPath = [Uri]::new($QemuBundleUrl).LocalPath
            Copy-Item -Path $localPath -Destination $bundleZip -Force
        } else {
            Invoke-WebRequest -Uri $QemuBundleUrl -OutFile $bundleZip -UseBasicParsing
        }
    } finally { $ProgressPreference = $oldPP }

    if ($QemuBundleSha256) {
        $actual = (Get-FileHash $bundleZip -Algorithm SHA256).Hash.ToLower()
        $expected = $QemuBundleSha256.Trim().ToLower()
        if ($actual -ne $expected) {
            Remove-Item $bundleZip -Force
            throw "QEMU bundle SHA256 mismatch (expected $expected, got $actual). Cached file removed; re-run."
        }
        Write-Host "Bundle verified: $actual"
    } else {
        Write-Host "WARNING: no SHA256 provided; skipping integrity check." -ForegroundColor Yellow
    }

    Write-Host "--- Extracting bundle to $QemuDir ---"
    Expand-Archive -Path $bundleZip -DestinationPath $QemuDir -Force
    if (-not (Test-Path $QemuExe)) {
        throw "After extract, qemu-system-x86_64.exe missing at $QemuExe -- bundle layout wrong?"
    }

    $verFile = Join-Path $QemuDir 'VERSION.txt'
    $verLine = if (Test-Path $verFile) { (Get-Content -Raw $verFile).Trim() } else { '(unknown)' }
    @"
date: $(Get-Date -Format o)
url:  $QemuBundleUrl
sha:  $QemuBundleSha256
qemu: $verLine
"@ | Set-Content $QemuReadyMarker -Encoding UTF8
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

# --- 5. Build cloud-init seed ISO via IMAPI2 COM (Windows built-in) ---
# Cloud-init writes install-sirepo.sh, the windows_native job-driver patch,
# the sirepo.service unit, and a small mount-host-runs.sh helper into the
# VM. Then runcmd: install davfs2 + git, git clone sirepo+pykern to /opt,
# mount the WebDAV runs share at /mnt/host-runs (added to fstab so it
# persists across reboots), invoke install-sirepo.sh with --patches.
# Sirepo lives ENTIRELY inside the VM on local ext4 -- no davfs2 symlink
# limitations on the source tree. /mnt/host-runs is a narrow data pipe for
# the windows_native job driver to hand SRW jobs off to the worker.
Write-Host ""
Write-Host "--- Generating cloud-init seed ISO ---"

# Inline install-sirepo.sh (~80 lines) and the job-driver patch (~60 lines)
# into the YAML write_files. Force LF endings + indent for cloud-init's
# multi-line content: | block.
$installShContent = (Get-Content -Raw $InstallShHost) -replace "`r",''
$indentedShContent = ($installShContent -split "`n" | ForEach-Object { '      ' + $_ }) -join "`n"

$patchHost = Join-Path $PatchesHost 'job_driver_windows_native.py'
if (-not (Test-Path $patchHost)) { throw "Missing patch $patchHost" }
$patchContent = (Get-Content -Raw $patchHost) -replace "`r",''
$indentedPatchContent = ($patchContent -split "`n" | ForEach-Object { '      ' + $_ }) -join "`n"

$controlSrvHost = Join-Path $PSScriptRoot 'control_server.py'
if (-not (Test-Path $controlSrvHost)) { throw "Missing $controlSrvHost" }
$controlSrvContent = (Get-Content -Raw $controlSrvHost) -replace "`r",''
$indentedControlSrvContent = ($controlSrvContent -split "`n" | ForEach-Object { '      ' + $_ }) -join "`n"

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
  - path: /usr/local/bin/install-sirepo.sh
    permissions: '0755'
    content: |
$indentedShContent
  - path: /tmp/patches/job_driver_windows_native.py
    permissions: '0644'
    content: |
$indentedPatchContent
  - path: /usr/local/lib/sirepo-control/server.py
    permissions: '0755'
    content: |
$indentedControlSrvContent
  - path: /etc/systemd/system/sirepo-control.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Sirepo_Win control endpoint
      # Doesn't strictly need sirepo.service running -- /status works either
      # way -- but if it's after sirepo.service we don't race the restart logic
      # in /update.
      After=network-online.target

      [Service]
      Type=simple
      Environment=SIREPO_CONTROL_PORT=$ControlPort
      ExecStart=/usr/bin/python3 /usr/local/lib/sirepo-control/server.py
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
  - path: /etc/systemd/system/sirepo.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Sirepo (SRW)
      After=network-online.target
      Wants=network-online.target
      RequiresMountsFor=/mnt/host-runs

      [Service]
      Type=simple
      Environment=SIREPO_FEATURE_CONFIG_TRUST_SH_ENV=1
      Environment=SIREPO_FEATURE_CONFIG_SIM_TYPES=srw
      # Disable the Vue dev server: it only matters for cortex (not SRW), and
      # vite requires Node 18+ -- Ubuntu 22.04 ships Node 12 and ships nothing
      # newer in the default repos. Empty value -> _start_vue_server is a no-op.
      Environment=SIREPO_FEATURE_CONFIG_VUE_SIM_TYPES=
      Environment=SIREPO_JOB_DRIVER_MODULES=local:windows_native
      Environment=SIREPO_JOB_DRIVER_WINDOWS_NATIVE_WORKER_URL=http://10.0.2.2:$WorkerPort
      Environment=PATH=/opt/sirepo-venv/bin:/usr/local/bin:/usr/bin:/bin
      # systemd creates /var/lib/sirepo + chmods/chowns it automatically. Using
      # StateDirectory avoids the chicken-and-egg where WorkingDirectory applies
      # to ExecStartPre too, so an ExecStartPre=mkdir would never get to run.
      StateDirectory=sirepo
      WorkingDirectory=/var/lib/sirepo
      ExecStart=/opt/sirepo-venv/bin/sirepo service http
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
  - path: /usr/local/sbin/mount-host-runs.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      mkdir -p /mnt/host-runs
      # Anonymous Basic auth (worker accepts any creds); no client-side cache
      # so writes from Sirepo are immediately visible to the worker.
      echo '$WebdavGuestUrl guest guest' > /etc/davfs2/secrets
      chmod 600 /etc/davfs2/secrets
      sed -i 's|^# *ask_auth .*|ask_auth 0|' /etc/davfs2/davfs2.conf
      sed -i 's|^# *use_locks .*|use_locks 0|' /etc/davfs2/davfs2.conf
      sed -i 's|^# *gui_optimize .*|gui_optimize 0|' /etc/davfs2/davfs2.conf
      # Add to fstab so systemd auto-mounts on subsequent boots. The mount unit
      # systemd auto-generates from fstab is what sirepo.service's
      # RequiresMountsFor=/mnt/host-runs hooks into.
      grep -q '/mnt/host-runs' /etc/fstab || echo '$WebdavGuestUrl /mnt/host-runs davfs rw,_netdev,user 0 0' >> /etc/fstab
      systemctl daemon-reload
      # Retry briefly in case the worker isn't yet up when cloud-init runs.
      for i in 1 2 3 4 5; do
          if mount /mnt/host-runs; then
              echo "host-runs mounted"; exit 0
          fi
          echo "mount attempt `$i failed; sleeping"
          sleep 5
      done
      echo "ERROR: could not mount /mnt/host-runs after 5 tries" >&2
      exit 1

runcmd:
  # IMPORTANT: install davfs2 FIRST so its conffiles land on disk before
  # mount-host-runs.sh writes /etc/davfs2/secrets. Writing it via write_files
  # (which runs before runcmd) trips a dpkg conffile prompt that
  # DEBIAN_FRONTEND=noninteractive doesn't suppress.
  - apt-get update -qq
  - DEBIAN_FRONTEND=noninteractive apt-get install -y davfs2 git
  - /usr/local/sbin/mount-host-runs.sh
  # Start sirepo-control.service early so the host-side UI's /status poll can
  # report "installing..." while the long-running steps below execute.
  - systemctl daemon-reload
  - mkdir -p /var/lib/sirepo
  - echo apt-deps > /var/lib/sirepo/install-stage
  - systemctl enable --now sirepo-control.service
  # Chain git clones + install + enable in a SINGLE bash -c with set -e so any
  # failure short-circuits and sirepo.service does NOT get enabled. Without
  # this, cloud-init treats each runcmd entry independently: a git failure
  # leaves /opt/sirepo missing, install-sirepo.sh bails, but
  # `systemctl enable --now sirepo.service` still runs -- and the service
  # then sits in a Restart=on-failure loop forever, with /status reporting
  # `sirepo_active: activating` and no way to tell anything is wrong.
  - |
    bash -c '
      set -euo pipefail
      stage() { echo "`$1" > /var/lib/sirepo/install-stage; }
      stage clone-pykern
      git clone --depth 50 https://github.com/radiasoft/pykern.git /opt/pykern
      stage clone-sirepo
      git clone --depth 50 https://github.com/radiasoft/sirepo.git /opt/sirepo
      stage install
      bash /usr/local/bin/install-sirepo.sh --patches /tmp/patches /opt/sirepo /opt/pykern
      stage starting
      systemctl enable --now sirepo.service
      stage done
    '
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
    # Skylake-Client-noTSX-IBRS is a well-tested WHPX-compatible CPU model.
    # We need AES-NI + AVX2 + SHA-NI for git's HTTPS crypto path (default
    # qemu64 only advertises SSE2, which causes libcurl/libgnutls to hit
    # SIGILL when CPUID detection picks the hand-rolled SIMD codepath).
    # `-cpu max` is the natural choice but advertises MPX and APX, which
    # WHPX can't emulate -- the guest crashes with "VP exit code 4" (memory
    # access fault) before cloud-init even runs. Skylake-Client is the
    # newest well-known model without MPX/APX.
    '-cpu', 'Skylake-Client-noTSX-IBRS',
    '-m', "${Memory}G",
    '-smp', "$Cpus",
    '-drive', "file=$OverlayImage,format=qcow2,if=virtio",
    '-drive', "file=$SeedIso,format=raw,media=cdrom",
    # Two hostfwd entries: 8000 -> sirepo HTTP, $ControlPort -> in-guest
    # control endpoint (the setup.ps1 WinForms UI talks to /update, /status,
    # /sbatch_creds).
    '-netdev', "user,id=net0,hostfwd=tcp::${HostPort}-:8000,hostfwd=tcp::${ControlPort}-:${ControlPort}",
    '-device', 'virtio-net,netdev=net0',
    '-L', $QemuShareDir,
    '-nographic'
)

if ($Detached) {
    # Background launch: redirect QEMU stdout/stderr to a log file so the
    # console output of the boot sequence is preserved without taking over
    # the terminal. Caller (setup.ps1) keeps the process handle and is
    # responsible for shutting it down.
    $qemuLog = Join-Path $CacheDir 'qemu.log'
    Write-Host "QEMU log: $qemuLog"
    $qemuProc = Start-Process -FilePath $QemuExe -ArgumentList $qemuArgs `
        -RedirectStandardOutput $qemuLog -RedirectStandardError "$qemuLog.err" `
        -WindowStyle Hidden -PassThru
    Write-Host "QEMU pid=$($qemuProc.Id) (detached)."
    return $qemuProc
}

& $QemuExe @qemuArgs
