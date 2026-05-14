#requires -Version 5.1
<#
.SYNOPSIS
  One-shot orchestrator + control UI for Sirepo_Win.

.DESCRIPTION
  Wraps the bootstrap stages, worker, and QEMU launch behind a small WinForms
  control window:

    1. Bootstrap python-native (embeddable Python + srwpy for the worker).
    2. Start the worker (FastAPI on 127.0.0.1:8311; serves /run and /dav).
    3. Run bootstrap-qemu.ps1 -Detached to download the portable QEMU bundle
       (if needed), build the cloud-init seed.iso, and launch QEMU in the
       background. cloud-init clones sirepo+pykern inside the guest and runs
       install-sirepo.sh on first boot.
    4. Poll for Sirepo at http://localhost:$HostPort and show a WinForms
       window with status, "Open in browser", "Update Sirepo", and "Quit".
       The in-guest control endpoint (sirepo-control.service, port
       $ControlPort) handles /update -> git pull + pip install -e + restart.

  Every stage is idempotent: re-running this script after a successful run
  skips the cached steps and is back in QEMU + UI in seconds.

  Closing the window (or clicking Quit) shuts down QEMU and the worker.

.PARAMETER Memory
  Guest memory in GB. Default 4.

.PARAMETER Cpus
  Guest vCPU count. Default 2.

.PARAMETER HostPort
  Windows host port that maps to the VM's port 8000. Default 8000.

.PARAMETER WorkerPort
  TCP port for the native worker on the Windows host. Default 8311.

.PARAMETER ControlPort
  TCP port for the in-guest control endpoint (hostfwd'd). Default 8312.

.PARAMETER NoUi
  Skip the WinForms control window; run QEMU in the foreground instead
  (the pre-UI behavior). Useful for headless / CI scenarios.

.PARAMETER Force
  Wipe the QEMU overlay + re-generate the cloud-init seed. Keeps the QEMU
  bundle, python-native, and the Ubuntu base image.
#>
[CmdletBinding()]
param(
    [int]   $Memory      = 4,
    [int]   $Cpus        = 2,
    [int]   $HostPort    = 8000,
    [int]   $WorkerPort  = 8311,
    [int]   $ControlPort = 8312,
    # QEMU bundle: built by .github/workflows/build-qemu-bundle.yml and
    # uploaded to GitHub Releases. Override locally for testing with a
    # file:/// URL or pass -QemuBundleUrl / -QemuBundleSha256. Env vars
    # SIREPO_WIN_QEMU_URL / SIREPO_WIN_QEMU_SHA256 also work.
    [string]$QemuBundleUrl    = $(if ($env:SIREPO_WIN_QEMU_URL) { $env:SIREPO_WIN_QEMU_URL }
                                  else { 'https://github.com/himanshugoel2797/standalone_srw_sirepo/releases/download/qemu-portable-v11.0.0-r1/qemu-portable.zip' }),
    [string]$QemuBundleSha256 = $(if ($env:SIREPO_WIN_QEMU_SHA256) { $env:SIREPO_WIN_QEMU_SHA256 }
                                  else { '5d463141af73fad407703aedbb64d45a4fa376bc7786e42a67e09fe859fd48c2' }),
    [switch]$NoUi,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = $PSScriptRoot
$PyNativeBootstrap = Join-Path $ProjectRoot 'scripts\bootstrap-python-native.ps1'
$QemuBootstrap     = Join-Path $ProjectRoot 'scripts\bootstrap-qemu.ps1'
$WorkerPy          = Join-Path $ProjectRoot 'worker\worker.py'
$PyExe             = Join-Path $ProjectRoot 'python-native\python.exe'
$PyMarker          = Join-Path $ProjectRoot 'python-native\.python-native-ok'
$WorkerLog         = Join-Path $ProjectRoot '.cache\worker.log'

Write-Host "=== Sirepo_Win setup ==="
Write-Host "project root: $ProjectRoot"
Write-Host ""

# --- 1. python-native (embeddable Python + srwpy + worker deps) ---
if ((Test-Path $PyMarker) -and -not $Force) {
    Write-Host "python-native already bootstrapped."
} else {
    Write-Host "--- Bootstrapping python-native ---"
    & $PyNativeBootstrap
    if ($LASTEXITCODE -ne 0) { throw "bootstrap-python-native.ps1 failed (exit $LASTEXITCODE)" }
}

# --- 2. Worker: start if not already running ---
function Test-WorkerHealthy {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$WorkerPort/health" `
                               -UseBasicParsing -TimeoutSec 2
        return $r.StatusCode -eq 200
    } catch { return $false }
}

New-Item -ItemType Directory -Force -Path (Split-Path $WorkerLog) | Out-Null

$workerProc = $null
if (Test-WorkerHealthy) {
    Write-Host "Worker already running on 127.0.0.1:$WorkerPort."
} else {
    Write-Host "--- Starting worker (logs -> $WorkerLog) ---"
    # Start detached so Ctrl-C in this PowerShell doesn't take us out before
    # we get to the cleanup at the bottom.
    # Windows PowerShell 5.1's ProcessStartInfo (.NET Framework) doesn't have
    # ArgumentList -- use Arguments as a single quoted string.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $PyExe
    $psi.Arguments              = "`"$WorkerPy`" --port $WorkerPort"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.WorkingDirectory       = $ProjectRoot
    $workerProc = [System.Diagnostics.Process]::Start($psi)
    $sw = [System.IO.StreamWriter]::new($WorkerLog, $false)
    $sw.AutoFlush = $true
    $onData = {
        param($s, $e)
        if ($null -ne $e.Data) { $Event.MessageData.WriteLine($e.Data) }
    }
    Register-ObjectEvent -InputObject $workerProc -EventName OutputDataReceived `
        -Action $onData -MessageData $sw | Out-Null
    Register-ObjectEvent -InputObject $workerProc -EventName ErrorDataReceived `
        -Action $onData -MessageData $sw | Out-Null
    $workerProc.BeginOutputReadLine()
    $workerProc.BeginErrorReadLine()

    Write-Host "Waiting for worker /health..."
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-WorkerHealthy) { break }
        if ($workerProc.HasExited) {
            Write-Host ""
            Write-Host "Worker exited early. Tail of ${WorkerLog}:" -ForegroundColor Red
            if (Test-Path $WorkerLog) { Get-Content $WorkerLog -Tail 30 | Write-Host }
            throw "Worker failed to start."
        }
    }
    if (-not (Test-WorkerHealthy)) {
        throw "Worker did not become healthy within 30s."
    }
    Write-Host "Worker pid=$($workerProc.Id) ready."
}

# --- 3. QEMU bootstrap + launch ---
Write-Host ""
$qemuArgs = @{
    Memory      = $Memory
    Cpus        = $Cpus
    HostPort    = $HostPort
    WorkerPort  = $WorkerPort
    ControlPort = $ControlPort
}
if ($QemuBundleUrl)    { $qemuArgs.QemuBundleUrl    = $QemuBundleUrl }
if ($QemuBundleSha256) { $qemuArgs.QemuBundleSha256 = $QemuBundleSha256 }
if ($Force)            { $qemuArgs.Force            = $true }

# Headless mode: drop into bootstrap-qemu.ps1's foreground launch path, do
# the worker cleanup in finally. This is the pre-UI behavior; kept for CI /
# scripted use where popping a window doesn't make sense.
if ($NoUi) {
    try { & $QemuBootstrap @qemuArgs }
    finally {
        if ($workerProc -and -not $workerProc.HasExited) {
            Write-Host ""
            Write-Host "Stopping worker (pid=$($workerProc.Id))..."
            try { $workerProc.Kill() } catch {}
        }
    }
    return
}

# UI mode: launch QEMU detached, then open a small control window.
$qemuProc = & $QemuBootstrap @qemuArgs -Detached

# --- 4. Control UI (WinForms) ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$sirepoUrl  = "http://localhost:$HostPort"
$controlUrl = "http://127.0.0.1:$ControlPort"

$form        = New-Object System.Windows.Forms.Form
$form.Text   = 'Sirepo_Win'
$form.Size   = New-Object System.Drawing.Size(540, 480)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(420, 360)

# Layout: 1-column TableLayoutPanel. Rows: status / button / button / log / quit.
$tlp = New-Object System.Windows.Forms.TableLayoutPanel
$tlp.Dock        = 'Fill'
$tlp.ColumnCount = 1
$tlp.RowCount    = 5
[void]$tlp.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$tlp.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 60)))   # status
[void]$tlp.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 36)))   # open
[void]$tlp.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 36)))   # update
[void]$tlp.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))       # log
[void]$tlp.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 44)))   # quit
$tlp.Padding = New-Object System.Windows.Forms.Padding(10)
$form.Controls.Add($tlp)

$status      = New-Object System.Windows.Forms.Label
$status.Dock = 'Fill'
$status.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$status.Text = "Starting Sirepo...`r`nFirst boot can take 2-15 minutes."
$tlp.Controls.Add($status, 0, 0)

$btnOpen      = New-Object System.Windows.Forms.Button
$btnOpen.Text = "Open Sirepo in browser  ($sirepoUrl)"
$btnOpen.Dock = 'Fill'
$btnOpen.Enabled = $false   # enabled once Sirepo answers
$btnOpen.Add_Click({ Start-Process $sirepoUrl }.GetNewClosure())
$tlp.Controls.Add($btnOpen, 0, 1)

$btnUpdate         = New-Object System.Windows.Forms.Button
$btnUpdate.Text    = 'Update Sirepo (git pull + reinstall + restart)'
$btnUpdate.Dock    = 'Fill'
$btnUpdate.Enabled = $false   # enabled once /status is reachable
$tlp.Controls.Add($btnUpdate, 0, 2)

$log              = New-Object System.Windows.Forms.TextBox
$log.Multiline    = $true
$log.ReadOnly     = $true
$log.ScrollBars   = 'Vertical'
$log.Dock         = 'Fill'
$log.Font         = New-Object System.Drawing.Font('Consolas', 9)
$log.BackColor    = [System.Drawing.Color]::WhiteSmoke
$tlp.Controls.Add($log, 0, 3)

$btnQuit         = New-Object System.Windows.Forms.Button
$btnQuit.Text    = 'Quit (stop Sirepo + worker)'
$btnQuit.Dock    = 'Fill'
$btnQuit.BackColor = [System.Drawing.Color]::LightCoral
$btnQuit.Add_Click({ $form.Close() }.GetNewClosure())
$tlp.Controls.Add($btnQuit, 0, 4)

# Tiny helper to append a timestamped line to the log textbox.
$appendLog = {
    param($msg)
    $line = "{0} {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $msg
    $log.AppendText($line)
}.GetNewClosure()

& $appendLog "Worker pid=$($workerProc.Id) listening on :$WorkerPort"
& $appendLog "QEMU   pid=$($qemuProc.Id), Sirepo will be at $sirepoUrl"
& $appendLog "Control endpoint :$ControlPort (in-guest)"

# Status poller. Hits Sirepo's / and the control endpoint's /status every
# few seconds; flips button-enabled states based on what's reachable.
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$state          = @{ SirepoUp = $false; ControlUp = $false; SirepoRev = ''; PykernRev = '' }

$state.LastStage = ''
$stageLabel = @{
    'starting'             = 'Starting...'
    'apt-deps'             = 'Installing davfs2 + git...'
    'clone-pykern'         = 'Cloning pykern from GitHub...'
    'clone-sirepo'         = 'Cloning Sirepo from GitHub...'
    'apt-install'          = 'Installing apt runtime packages...'
    'pip-upgrade'          = 'Upgrading pip + setuptools...'
    'pip-install-pykern'   = 'Installing pykern (~50 wheels from PyPI)...'
    'pip-install-sirepo'   = 'Installing Sirepo (~50 wheels from PyPI)...'
    'patches'              = 'Applying Sirepo_Win patches...'
    'smoke-test'           = 'Smoke-testing the install...'
    'install'              = 'Installing (unspecified stage)...'
    'done'                 = 'Install complete, starting Sirepo...'
}

$timer.Add_Tick({
    # Sirepo HTTP probe (cheap; failure is the common case during boot).
    $sirepoUp = $false
    try {
        $r = Invoke-WebRequest -Uri $sirepoUrl -UseBasicParsing -TimeoutSec 2
        $sirepoUp = ($r.StatusCode -eq 200)
    } catch { }

    # Control endpoint /status (also gives us git revs + sirepo.service active
    # + install_stage so we can show real progress, not "cloud-init in progress").
    $controlUp = $false
    $rev = ''
    $stage = ''
    $svcActive = ''
    try {
        $r = Invoke-WebRequest -Uri "$controlUrl/status" -UseBasicParsing -TimeoutSec 2
        $controlUp = ($r.StatusCode -eq 200)
        if ($controlUp) {
            $body = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) }
                    else { [string]$r.Content }
            $j = $body | ConvertFrom-Json
            $rev = "sirepo@{0}, pykern@{1}, svc={2}" -f $j.sirepo_rev, $j.pykern_rev, $j.sirepo_active
            $stage = if ($j.PSObject.Properties.Name -contains 'install_stage') { [string]$j.install_stage } else { '' }
            $svcActive = [string]$j.sirepo_active
        }
    } catch { }

    # First-time transitions.
    if ($sirepoUp -and -not $state.SirepoUp) {
        & $appendLog "Sirepo HTTP 200 -- ready"
        $btnOpen.Enabled = $true
    }
    if ((-not $sirepoUp) -and $state.SirepoUp) {
        & $appendLog "Sirepo stopped responding"
        $btnOpen.Enabled = $false
    }
    if ($controlUp -and -not $state.ControlUp) {
        & $appendLog "Control endpoint reachable"
    }
    # Only enable Update once the install reports "done" -- the endpoint is
    # reachable earlier (it starts before install runs to report progress)
    # but /update would race the original install.
    $installDone = ($stage -eq 'done' -or $sirepoUp)
    $btnUpdate.Enabled = $controlUp -and $installDone

    # Log each new stage transition so the user sees a timeline.
    if ($stage -and $stage -ne $state.LastStage) {
        $msg = if ($stageLabel.ContainsKey($stage)) { $stageLabel[$stage] } else { "Stage: $stage" }
        & $appendLog "[$stage] $msg"
        $state.LastStage = $stage
    }

    $state.SirepoUp  = $sirepoUp
    $state.ControlUp = $controlUp

    $sirepoLine =
        if ($sirepoUp) {
            "Sirepo: running at $sirepoUrl"
        } elseif ($controlUp -and $stage) {
            $friendly = if ($stageLabel.ContainsKey($stage)) { $stageLabel[$stage] } else { $stage }
            "Sirepo: installing -- $friendly"
        } else {
            'Sirepo: waiting for VM boot (kernel + cloud-init network stage)'
        }
    $revLine =
        if ($sirepoUp -or $svcActive -eq 'active') { $rev }
        elseif ($controlUp) { "service: $svcActive" }
        else { '(control endpoint not yet reachable)' }
    $status.Text = "$sirepoLine`r`n$revLine"
}.GetNewClosure())
$timer.Start()

# Update Sirepo handler. POST /update is potentially long-running (pip install
# can take 30s-2min). Disable the button + show "updating..." while it runs.
# Calling the control endpoint synchronously from the UI thread blocks the
# message loop briefly; for a one-shot click that's fine.
$btnUpdate.Add_Click({
    $btnUpdate.Enabled = $false
    $btnUpdate.Text = 'Updating... (this can take 1-3 min)'
    & $appendLog "POST $controlUrl/update"
    try {
        $r = Invoke-WebRequest -Uri "$controlUrl/update" -Method Post `
                               -UseBasicParsing -TimeoutSec 600 `
                               -Body '{}' -ContentType 'application/json'
        $body = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) }
                else { [string]$r.Content }
        $j = $body | ConvertFrom-Json
        if ($j.ok) {
            & $appendLog 'Update OK; restarted sirepo.service'
        } else {
            & $appendLog 'Update FAILED:'
        }
        # Tail the multi-line log into the textbox (last ~40 lines).
        $tail = ($j.log -split "`n" | Select-Object -Last 40) -join "`r`n"
        $log.AppendText($tail + "`r`n")
    } catch {
        & $appendLog "Update threw: $($_.Exception.Message)"
    } finally {
        $btnUpdate.Text = 'Update Sirepo (git pull + reinstall + restart)'
        $btnUpdate.Enabled = $true
    }
}.GetNewClosure())

# FormClosing fires for both X-button and our Quit button. Kill QEMU + worker
# here so the user can't end up with orphans.
$form.Add_FormClosing({
    param($s, $e)
    $timer.Stop()
    if ($qemuProc -and -not $qemuProc.HasExited) {
        try { $qemuProc.Kill() } catch {}
    }
    if ($workerProc -and -not $workerProc.HasExited) {
        try { $workerProc.Kill() } catch {}
    }
}.GetNewClosure())

Write-Host ""
Write-Host "Control window open. Close it or click Quit to stop Sirepo."
[void]$form.ShowDialog()

# After the form closes, the FormClosing handler has already killed both
# procs. Wait briefly for the OS to reap them so the script's exit looks
# clean.
foreach ($p in @($qemuProc, $workerProc)) {
    if ($p -and -not $p.HasExited) {
        try { $p.WaitForExit(2000) | Out-Null } catch {}
    }
}
Write-Host "Sirepo_Win stopped."
