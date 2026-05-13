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
    3. Download Ubuntu 24.04 cloud qcow2 image, verify SHA256.
    4. Create a writable overlay qcow2 so the base image stays pristine.
    5. Generate a NoCloud cloud-init seed ISO via Windows' built-in IMAPI2
       COM API, embedding user-data + meta-data + a copy of
       install-sirepo.sh.
    6. Launch QEMU with user-mode networking + hostfwd of $HostPort:8000.

  Cloud-init installs and starts Sirepo on first boot. Total bundle for the
  QEMU backend (msys64 + QEMU + Ubuntu image + overlay): ~1.5 GB.

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
    [string]$UbuntuUrl     = 'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img',
    [string]$Sha256SumsUrl = 'https://cloud-images.ubuntu.com/noble/current/SHA256SUMS',
    [int]   $Memory        = 4,
    [int]   $Cpus          = 2,
    [int]   $HostPort      = 8000,
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
$InstallShHost = Join-Path $PSScriptRoot 'install-sirepo.sh'
$MsysBootstrap = Join-Path $PSScriptRoot 'bootstrap-msys2.ps1'

$BootstrapMarker  = Join-Path $Msys64Dir '.sirepo-win-bootstrap-ok'
$QemuPacmanMarker = Join-Path $Msys64Dir '.qemu-installed-ok'
$VmReadyMarker    = Join-Path $VmDir '.vm-ready'

$QemuExe        = Join-Path $Msys64Dir 'mingw64\bin\qemu-system-x86_64.exe'
$QemuImgExe     = Join-Path $Msys64Dir 'mingw64\bin\qemu-img.exe'
$QemuShareDir   = Join-Path $Msys64Dir 'mingw64\share\qemu'

$BaseImage      = Join-Path $CacheDir 'ubuntu-24.04-noble-amd64.qcow2'
$OverlayImage   = Join-Path $VmDir 'overlay.qcow2'
$SeedIso        = Join-Path $VmDir 'seed.iso'

Write-Host "=== Sirepo_Win embedded-VM (QEMU/TCG) bootstrap ==="
Write-Host "project root: $ProjectRoot"
Write-Host "msys64 dir:   $Msys64Dir  (portable QEMU lives here)"
Write-Host "vm dir:       $VmDir"
Write-Host ""

New-Item -ItemType Directory -Force -Path $VmDir, $CacheDir | Out-Null

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
Write-Host "--- Ubuntu 24.04 cloud image ---"

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
Write-Host ""
Write-Host "--- Generating cloud-init seed ISO ---"
$installShContent = (Get-Content -Raw $InstallShHost) -replace "`r",''
$indentedShContent = ($installShContent -split "`n" | ForEach-Object { '      ' + $_ }) -join "`n"

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
  - path: /etc/systemd/system/sirepo.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Sirepo (SRW)
      After=network-online.target
      Wants=network-online.target

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

runcmd:
  - git clone --depth 50 https://github.com/radiasoft/sirepo.git /opt/sirepo
  - git clone --depth 50 https://github.com/radiasoft/pykern.git /opt/pykern
  - bash /usr/local/bin/install-sirepo.sh /opt/sirepo /opt/pykern
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
    Write-Host "Skipping QEMU launch (-NoStart). Launch manually with:"
    Write-Host "  $QemuExe -m ${Memory}G -smp $Cpus -drive file=$OverlayImage,format=qcow2,if=virtio -drive file=$SeedIso,format=raw,media=cdrom -netdev user,id=net0,hostfwd=tcp::${HostPort}-:8000 -device virtio-net,netdev=net0 -nographic"
    exit 0
}

# --- 7. Launch QEMU ---
Write-Host ""
Write-Host "=== Launching QEMU (TCG, software emulation) ==="
Write-Host "First boot is SLOW under TCG: ~5-15 min to boot Ubuntu, +10-20 min for cloud-init to install Sirepo."
Write-Host "Subsequent boots: ~5 min."
Write-Host ""
Write-Host "Once cloud-init finishes, Sirepo will be at http://localhost:$HostPort"
Write-Host ""

$qemuArgs = @(
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
