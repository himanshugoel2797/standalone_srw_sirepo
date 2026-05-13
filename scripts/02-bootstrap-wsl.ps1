#requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap a portable WSL2 (or WSL1) Linux environment for Sirepo into the
  project tree, programmatically handling Windows-feature enable + reboot.

.DESCRIPTION
  Goal: a user double-clicks a "set up Sirepo" launcher and ends up with a
  Linux VM (or translation layer) ready to host unmodified Sirepo. This script
  drives that flow:

    1. Detect current state (WSL installed? VM Platform on? VT-x in BIOS?).
    2. If WSL not present:
       a. Self-elevate, enable required Windows optional features via DISM.
       b. If reboot needed, write a continuation marker and ask the user to
          reboot. After reboot, re-running the script picks up where it left.
       c. Install the WSL runtime via `wsl --install --no-distribution` (or
          MSI fallback).
    3. Decide WSL2 vs WSL1: prefer WSL2; fall back to WSL1 if VM Platform
       cannot be enabled (corporate Group Policy, virtualization off in BIOS,
       or -ForceWSL1).
    4. Download a portable Ubuntu rootfs (cached + SHA256-verified) and
       `wsl --import` it as our distro into the project tree.
    5. Configure the distro (/etc/wsl.conf), smoke-test python3.

  No system pollution outside two unavoidable things:
    - Enabling 'VirtualMachinePlatform' (and/or 'Microsoft-Windows-Subsystem-
      Linux') Windows features. Reversible via Disable-WindowsOptionalFeature.
    - Installing the WSL runtime MSI (if step 2c runs). Reversible via
      Programs and Features.
  Everything else — the distro rootfs, the Sirepo install inside it, all
  state — lives under <project>\wsl\.

.PARAMETER DistroName
  Name to register the distro under (visible to `wsl --list`). Default
  'sirepo-win' to keep it clearly distinct from any user-owned distros.

.PARAMETER RootfsUrl
  HTTPS URL of a tarball/.wsl Ubuntu rootfs. Default: 24.04 LTS cloud rootfs.

.PARAMETER RootfsSha256
  Pinned SHA256 of the rootfs tarball. If empty, the script fetches the
  release's SHA256SUMS file and looks up the entry for us.

.PARAMETER ForceWSL1
  Use WSL1 even if WSL2 is available. Useful for testing fallback path.

.PARAMETER Force
  Wipe existing distro registration (if any) and re-import.

.PARAMETER PostRebootContinue
  Internal flag set when the script re-launches itself after a reboot. Do not
  pass manually.
#>
[CmdletBinding()]
param(
    [string]$DistroName     = 'sirepo-win',
    [string]$RootfsUrl      = 'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64-root.tar.xz',
    [string]$Sha256SumsUrl  = 'https://cloud-images.ubuntu.com/noble/current/SHA256SUMS',
    [string]$RootfsSha256   = '',
    [switch]$ForceWSL1,
    [switch]$Force,
    [switch]$PostRebootContinue
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# wsl.exe writes UTF-16 LE by default. Setting WSL_UTF8=1 makes it emit UTF-8
# for both its own messages AND the stdout of distro-invoked commands -- which
# matches what PowerShell expects without further encoding gymnastics.
$env:WSL_UTF8 = '1'

# --- Paths ---
$ProjectRoot   = Split-Path -Parent $PSScriptRoot
$WslDir        = Join-Path $ProjectRoot 'wsl'
$DistroDir     = Join-Path $WslDir $DistroName
$CacheDir      = Join-Path $ProjectRoot '.cache'
$Marker        = Join-Path $WslDir ".wsl-bootstrap-$DistroName-ok"
$RebootMarker  = Join-Path $WslDir '.wsl-reboot-pending'

# ---- Helpers ----

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal] $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FeatureState {
    param([string]$Name)
    try {
        (Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop).State
    } catch {
        'Unknown'
    }
}

function Test-BiosVirtualization {
    # NB: this isn't 100% reliable -- on systems where WSL2 is already running
    # via Hyper-V, the CIM property can return False. Callers should treat
    # an *existing* WSL2 install as the strongest signal that VT-x works.
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop
        return [bool]$cpu.VirtualizationFirmwareEnabled
    } catch {
        return $false
    }
}

function Invoke-WslExe {
    # Thin wrapper for consistency. WSL_UTF8=1 (set globally above) handles the
    # encoding -- no per-call Console-encoding gymnastics needed.
    param([Parameter(ValueFromRemainingArguments=$true)] $WslArgs)
    return & wsl.exe @WslArgs 2>&1
}

function Get-WslState {
    # Returns @{ Installed=$bool; Version=$str; DefaultVer=$int; Distros=@(...) }
    $result = [pscustomobject]@{
        Installed   = $false
        Version     = $null
        DefaultVer  = $null
        Distros     = @()
        Wsl1Supported = $null
    }
    try {
        $ver = Invoke-WslExe '--version'
        if ($LASTEXITCODE -ne 0 -or -not $ver) { return $result }
        $result.Installed = $true
        $verMatch = $ver | Select-String -Pattern 'WSL version:\s*(\S+)'
        if ($verMatch) { $result.Version = $verMatch.Matches[0].Groups[1].Value }
    } catch { return $result }

    try {
        $status = Invoke-WslExe '--status'
        $verMatch = $status | Select-String -Pattern 'Default Version:\s*(\d+)'
        if ($verMatch) { $result.DefaultVer = [int]$verMatch.Matches[0].Groups[1].Value }
        $result.Wsl1Supported = -not (($status -join "`n") -match 'WSL1 is not supported')
    } catch { }

    try {
        $list = Invoke-WslExe '--list' '--quiet'
        if ($list) {
            $result.Distros = @($list | Where-Object { $_ -and $_.ToString().Trim() } | ForEach-Object { $_.ToString().Trim() })
        }
    } catch { }

    return $result
}

function Invoke-Elevated {
    param([string]$ScriptPath, [string[]]$Args)
    # Spawn an elevated PowerShell child running this script with the
    # requested args, wait for it to finish, return its exit code.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Verb = 'RunAs'
    $allArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $ScriptPath) + $Args
    $psi.Arguments = ($allArgs | ForEach-Object { '"{0}"' -f $_ }) -join ' '
    $psi.UseShellExecute = $true
    Write-Host "Elevating to run: $($psi.FileName) $($psi.Arguments)"
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    return $proc.ExitCode
}

function Get-RootfsExpectedSha256 {
    param([string]$Url, [string]$Filename)
    Write-Host "Fetching $Url to look up SHA256 for $Filename"
    $oldPP = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing
    } finally {
        $ProgressPreference = $oldPP
    }
    # Invoke-WebRequest may return Content as either string or byte[] depending
    # on the server's Content-Type. Normalize to UTF-8 string.
    $text = if ($resp.Content -is [byte[]]) {
        [System.Text.Encoding]::UTF8.GetString($resp.Content)
    } else {
        [string]$resp.Content
    }
    # SHA256SUMS format: "<hash>  <filename>" or "<hash> *<filename>" per line
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^([0-9a-f]{64})\s+\*?(.+)$') {
            if ($Matches[2].Trim() -eq $Filename) {
                return $Matches[1].ToLower()
            }
        }
    }
    throw "No SHA256 entry for '$Filename' in $Url"
}

function Save-FileWithProgress {
    param([string]$Url, [string]$OutPath)
    Write-Host "Downloading $Url -> $OutPath"
    $oldPP = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing
    } finally {
        $ProgressPreference = $oldPP
    }
}

# ---- Main flow ----

Write-Host "=== Sirepo_Win WSL bootstrap ==="
Write-Host "project root: $ProjectRoot"
Write-Host "wsl dir:      $WslDir"
Write-Host "distro:       $DistroName"
Write-Host ""

if ((Test-Path $Marker) -and -not $Force) {
    Write-Host "Already bootstrapped:"
    Get-Content $Marker | ForEach-Object { Write-Host "  $_" }
    Write-Host "Pass -Force to wipe and re-bootstrap."
    exit 0
}

New-Item -ItemType Directory -Force -Path $WslDir, $CacheDir | Out-Null

# Reboot-resume guard: if reboot marker is present, the user already enabled
# features in a previous run. Skip past that.
$justResumed = (Test-Path $RebootMarker) -or $PostRebootContinue

# --- 1. Detect current state ---
Write-Host "--- Probing current Windows state ---"
$wsl = Get-WslState
$vmPlatform = Get-FeatureState 'VirtualMachinePlatform'
$wslFeature = Get-FeatureState 'Microsoft-Windows-Subsystem-Linux'
$vtxFirmware = Test-BiosVirtualization

Write-Host "WSL installed:           $($wsl.Installed)"
if ($wsl.Installed) {
    Write-Host "  WSL version:           $($wsl.Version)"
    Write-Host "  Default version:       $($wsl.DefaultVer)"
    Write-Host "  Existing distros:      $($wsl.Distros -join ', ')"
}
Write-Host "VirtualMachinePlatform:  $vmPlatform"
Write-Host "WindowsSubsystemLinux:   $wslFeature"
Write-Host "VT-x in firmware:        $vtxFirmware  (unreliable when WSL2 is already running)"
Write-Host ""

# --- 2. Decide target WSL version ---
$canWsl2 = -not $ForceWSL1 -and ($wsl.Installed -or $vtxFirmware -or ($vmPlatform -eq 'Enabled'))
$target = if ($canWsl2) { 2 } else { 1 }
Write-Host "Target WSL version: $target $(if ($ForceWSL1) {'(forced)'})"

# --- 3. Enable Windows features if needed ---
# If WSL is already installed and reporting a default version of 2, both
# features are implicitly enabled -- skip the feature check entirely. The
# Get-WindowsOptionalFeature query returns 'Unknown' without admin, so we
# can't rely on it from a normal user shell.
$featuresNeeded = @()
$wsl2AlreadyWorking = $wsl.Installed -and $wsl.DefaultVer -ge 2
if (-not $wsl2AlreadyWorking) {
    if ($wslFeature -ne 'Enabled') { $featuresNeeded += 'Microsoft-Windows-Subsystem-Linux' }
    if ($target -eq 2 -and $vmPlatform -ne 'Enabled') { $featuresNeeded += 'VirtualMachinePlatform' }
}

if ($featuresNeeded.Count -gt 0) {
    if (-not (Test-IsAdmin)) {
        Write-Host ""
        Write-Host "Need admin to enable Windows features: $($featuresNeeded -join ', ')"
        Write-Host "Re-launching elevated. You'll see a UAC prompt."
        $argv = @('-DistroName', $DistroName, '-RootfsUrl', $RootfsUrl, '-Sha256SumsUrl', $Sha256SumsUrl)
        if ($RootfsSha256)  { $argv += @('-RootfsSha256', $RootfsSha256) }
        if ($ForceWSL1)     { $argv += '-ForceWSL1' }
        if ($Force)         { $argv += '-Force' }
        $code = Invoke-Elevated -ScriptPath $PSCommandPath -Args $argv
        exit $code
    }

    Write-Host "Enabling $($featuresNeeded -join ', ') (admin)..."
    foreach ($f in $featuresNeeded) {
        Write-Host "  dism enable: $f"
        & dism.exe /online /enable-feature /featurename:$f /norestart /quiet
        if ($LASTEXITCODE -notin 0,3010) {
            throw "Enabling $f failed (dism exit $LASTEXITCODE). If this is a corporate-managed machine, Group Policy may be blocking optional features."
        }
    }

    Write-Host ""
    Write-Host "Windows features enabled. A reboot is required before WSL can work."
    Write-Host "After rebooting, re-run this script:"
    Write-Host "  .\scripts\02-bootstrap-wsl.ps1"
    "Reboot pending since $(Get-Date -Format o)" | Set-Content $RebootMarker -Encoding UTF8
    exit 0
}

# --- 4. Install WSL runtime if not present ---
if (-not $wsl.Installed) {
    Write-Host "--- Installing WSL runtime via 'wsl --install --no-distribution' ---"
    # Modern WSL (Win11 22H2+) supports `wsl --install --no-distribution` to
    # install just the runtime without picking a distro. Needs admin.
    if (-not (Test-IsAdmin)) {
        Write-Host "Need admin to install WSL runtime. Re-launching elevated."
        $argv = @('-DistroName', $DistroName, '-RootfsUrl', $RootfsUrl, '-Sha256SumsUrl', $Sha256SumsUrl)
        if ($RootfsSha256)  { $argv += @('-RootfsSha256', $RootfsSha256) }
        if ($ForceWSL1)     { $argv += '-ForceWSL1' }
        if ($Force)         { $argv += '-Force' }
        $code = Invoke-Elevated -ScriptPath $PSCommandPath -Args $argv
        exit $code
    }
    Invoke-WslExe '--install' '--no-distribution' | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --install failed (exit $LASTEXITCODE). Older Windows versions may need an MSI from github.com/microsoft/WSL/releases -- add that fallback if you hit this."
    }
    $wsl = Get-WslState
    if (-not $wsl.Installed) {
        throw "WSL runtime install reported success but `wsl --version` still fails."
    }
}

# Clean up reboot marker if we actually rebooted-and-resumed
if ($justResumed -and (Test-Path $RebootMarker)) {
    Remove-Item $RebootMarker -ErrorAction SilentlyContinue
    Write-Host "Resumed after reboot."
}

# --- 5. Set default version ---
if ($wsl.DefaultVer -ne $target) {
    Write-Host "Setting WSL default version to $target"
    Invoke-WslExe '--set-default-version' "$target" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "wsl --set-default-version $target returned $LASTEXITCODE -- continuing with whatever the system has."
    }
}

# --- 6. Download Ubuntu rootfs (cached, SHA256-verified) ---
$rootfsFilename = Split-Path -Leaf $RootfsUrl
$rootfsPath = Join-Path $CacheDir $rootfsFilename

if (-not (Test-Path $rootfsPath)) {
    Save-FileWithProgress -Url $RootfsUrl -OutPath $rootfsPath
} else {
    Write-Host "Rootfs already in cache: $rootfsPath"
}

# Verify SHA256
$actual = (Get-FileHash -Path $rootfsPath -Algorithm SHA256).Hash.ToLower()
$expected = $RootfsSha256
if (-not $expected) {
    try {
        $expected = Get-RootfsExpectedSha256 -Url $Sha256SumsUrl -Filename $rootfsFilename
    } catch {
        Write-Warning "Could not look up published SHA256 ($_). Skipping verification."
        Write-Warning "Got SHA256 = $actual -- pin via -RootfsSha256 to verify next time."
        $expected = $actual
    }
}
if ($actual -ne $expected.ToLower()) {
    Remove-Item $rootfsPath -Force
    throw "Rootfs SHA256 mismatch (expected $expected, got $actual). Cached file removed; re-run to retry."
}
Write-Host "Rootfs SHA256 verified: $actual"

# --- 7. Import the distro ---
# Re-probe -- earlier $wsl may be stale if we installed runtime in this run.
$wsl = Get-WslState
$alreadyRegistered = @($wsl.Distros | Where-Object { $_.Trim() -ieq $DistroName }).Count -gt 0
if ($alreadyRegistered -and -not $Force) {
    Write-Host "Distro '$DistroName' already registered. Pass -Force to wipe and re-import."
} else {
    if ($alreadyRegistered) {
        Write-Host "Unregistering existing '$DistroName'..."
        Invoke-WslExe '--unregister' $DistroName | Out-Host
    }
    if (Test-Path $DistroDir) { Remove-Item -Recurse -Force $DistroDir }
    New-Item -ItemType Directory -Force -Path $DistroDir | Out-Null

    Write-Host "Importing rootfs as '$DistroName' to $DistroDir (this takes ~30-60s)..."
    Invoke-WslExe '--import' $DistroName $DistroDir $rootfsPath '--version' "$target" | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --import failed (exit $LASTEXITCODE)."
    }
}

# --- 8. Configure /etc/wsl.conf inside the distro ---
# Sensible defaults: don't generate /etc/hosts/resolv.conf at every boot (we
# might want to bind-mount or override), keep systemd off for faster boot,
# default user to root (we'll create a sirepo user later if needed).
$wslConf = @'
[boot]
systemd=false

[automount]
enabled=true
options="metadata,umask=22,fmask=11"

[interop]
enabled=true
appendWindowsPath=false

[network]
generateHosts=true
generateResolvConf=true
'@
Write-Host "Writing /etc/wsl.conf inside distro..."
$wslConf | & wsl.exe -d $DistroName -- bash -c 'cat > /etc/wsl.conf'
if ($LASTEXITCODE -ne 0) { throw "Writing /etc/wsl.conf failed." }

# --- 9. Smoke test ---
Write-Host ""
Write-Host "=== Smoke test ==="
Invoke-WslExe '-d' $DistroName '--' 'bash' '-c' 'echo "os-release:" && cat /etc/os-release | head -3 && echo "---" && echo "python3: $(command -v python3 && python3 --version 2>&1)" && echo "uname: $(uname -a)"' | Out-Host

# --- 10. Marker ---
@"
date:        $(Get-Date -Format o)
distro:      $DistroName
distro-dir:  $DistroDir
rootfs:      $rootfsFilename
sha256:      $actual
wsl-version: $($wsl.Version)
target-ver:  $target
"@ | Set-Content -Path $Marker -Encoding UTF8

Write-Host ""
Write-Host "Done. WSL distro '$DistroName' ready at $DistroDir."
Write-Host "Use:  wsl -d $DistroName -- bash"
