# Sirepo_Win

Portable Windows installer for [Sirepo](https://github.com/radiasoft/sirepo)
(SRW only). No admin needed. Everything stays under this directory — delete
the folder to uninstall.

## Quick start

In PowerShell (or double-click `setup.bat`):

```powershell
.\setup.bat
```

or

```powershell
.\setup.ps1
```

First run takes ~5-10 min (downloads the portable QEMU bundle ~110 MB,
Ubuntu 22.04 cloud image ~600 MB, Python embeddable + srwpy ~80 MB, then
boots a VM and installs Sirepo on first boot). Subsequent runs reuse the
cached pieces and are back in QEMU in seconds.

Once cloud-init finishes, open <http://localhost:8000> in your browser.

Press Ctrl-C in the terminal to stop. The worker is killed on exit; the
qcow2 overlay keeps state across restarts.

## Faster boot (optional, one-time)

QEMU runs in software-emulation mode (TCG) by default. To get near-native
speed via [Windows Hypervisor Platform](https://learn.microsoft.com/en-us/virtualization/api/) (WHPX):

1. Open **Settings** → **Apps** → **Optional features** → **More Windows features**.
2. Tick **Windows Hypervisor Platform**.
3. Reboot.

`setup.ps1` auto-detects WHPX availability and prefers it over TCG.

WSL2/Docker Desktop/Hyper-V users already have WHPX enabled.

## What it builds

```text
Sirepo_Win/
├── qemu/           portable QEMU bundle (~290 MB extracted; downloaded as ~110 MB zip from GH Releases)
├── python-native/  Python 3.12 embeddable + srwpy + worker deps (~100 MB)
├── qemu-vm/        cloud-init seed.iso + writable overlay.qcow2
├── .cache/         downloads (Ubuntu image, bundle zip, etc.)
├── state/runs/     SRW job inputs/outputs (shared with the guest via WebDAV)
└── (qemu/python-native/qemu-vm/.cache/state are all gitignored)
```

Total disk: ~2 GB after first install.

## Architecture

```text
[Windows host]                          [QEMU guest (Ubuntu 22.04 LTS)]
 ┌───────────────────────┐               ┌────────────────────────────────┐
 │ Browser :8000  ◄──────┼──slirp:hostfwd┼──► Sirepo HTTP :8000           │
 │                       │               │      └── job_supervisor        │
 │ Worker :8311          │               │           └── windows_native   │
 │   ├── /run   POST     │◄──HTTP────────┼──            driver (POSTs     │
 │   │   (runs srwpy     │  10.0.2.2     │               jobs to worker)  │
 │   │    natively)      │               │                                │
 │   └── /dav   WebDAV   │◄──davfs2──────┼──► /mnt/host-runs              │
 │       (state/runs/)   │               │   (job dir transfer only)      │
 └───────────────────────┘               └────────────────────────────────┘
```

- **Why a VM?** Sirepo's supervisor + job machinery is Linux-only (relies on
  POSIX `fork`, pyenv prefixes, etc.). MSYS2's cygwin-style POSIX layer was
  rejected by Sirepo's numeric deps (`psutil`, `numpy` refusing to run on
  cygwin). A Linux pocket avoids patching Sirepo at all.

- **Why a native Windows worker?** Sirepo's web tier is just I/O/HTTP, but
  SRW itself is heavy FP work. Under TCG (no hardware-virt), running SRW
  inside the VM is 10-50× slower than native. The `windows_native` job
  driver routes SRW jobs to the host-side worker so srwpy runs at full
  native speed regardless of the guest's accelerator.

- **Why WebDAV?** The guest needs a way to hand the worker the per-job
  `run.py` + inputs and read results back. 9p/virtfs is disabled in MSYS2's
  QEMU build; slirp `-smb` needs Samba on the host (Windows lacks it).
  WebDAV via `wsgidav` + `davfs2` works with zero host-side prerequisites
  and is mounted narrowly at `/mnt/host-runs` — not a source-tree mount.

- **Why is Sirepo cloned inside the VM?** Because `pip install -e` over
  WebDAV plus `npm install` on a davfs2 mount both fall apart (no symlinks,
  slow writes). Sources live on the guest's local ext4 (`/opt/sirepo`,
  `/opt/pykern`). The patch file in `sirepo_patches/` is inlined into
  cloud-init's `write_files` and copied into the source tree post-install.

- **Where does the QEMU bundle come from?**
  [.github/workflows/build-qemu-bundle.yml](.github/workflows/build-qemu-bundle.yml)
  runs on a Windows GitHub Actions runner: it pacman-installs MSYS2's
  `mingw-w64-x86_64-qemu`, stages just the bits we use (`qemu-system-x86_64.exe`,
  `qemu-img.exe`, runtime DLLs, x86 firmware), zips them, and attaches the
  result to a GitHub Release. `bootstrap-qemu.ps1` downloads + SHA-verifies
  the asset. Re-run the workflow whenever MSYS2 ships a newer QEMU.

## Component scripts (no need to run manually)

| Script                                        | What it does                                                |
|-----------------------------------------------|-------------------------------------------------------------|
| `setup.ps1`                                   | Orchestrates everything (this is the only one to run)       |
| `scripts/bootstrap-python-native.ps1`         | Python 3.12 embeddable + srwpy + worker deps                |
| `scripts/bootstrap-qemu.ps1`                  | Download QEMU bundle, fetch jammy, build seed ISO, launch   |
| `scripts/install-sirepo.sh`                   | Runs inside the VM via cloud-init                           |
| `scripts/run-worker.ps1`                      | Manual worker launcher (for debugging)                      |
| `worker/worker.py`                            | FastAPI: `/health`, `/run`, `/dav`                          |
| `sirepo_patches/job_driver_windows_native.py` | The Sirepo-side driver stub                                 |

## Troubleshooting

**Boot stalls on `Cloud-init: Final Stage`.** Cloud-init is doing the first-
boot `apt install` + `pip install` (~3 min on WHPX, ~10-15 on TCG). The
progress goes to the QEMU stdout window.

**`Worker not running` on launch.** Something else is on port 8311. Stop it
or pass `-WorkerPort <free port>` to `setup.ps1`.

**`HTTP 000` / connection reset on <http://localhost:8000>.** Cloud-init
hasn't finished yet, or Sirepo crashed inside the VM. Check the QEMU console
output; `sirepo.service` logs go to systemd journal inside the guest.

**`No QEMU bundle URL configured`.** Either the GH Releases asset doesn't
exist yet (run the `build-qemu-bundle` workflow), or the default URL in
`setup.ps1` points to the wrong repo. Override with `-QemuBundleUrl` and
`-QemuBundleSha256` or set `SIREPO_WIN_QEMU_URL` / `SIREPO_WIN_QEMU_SHA256`.

**Need to start over.** `Remove-Item -Recurse -Force qemu-vm,.cache,state`
(or just delete those folders) and re-run `.\setup.ps1`. To re-download
QEMU/Python too, also delete `qemu` and `python-native`.

## License

Sirepo and pykern are Apache 2.0 (RadiaSoft LLC). Sirepo_Win-side code in
this repo is the same. The `sirepo_patches/` files include the RadiaSoft
copyright header where they overlay Sirepo source.
