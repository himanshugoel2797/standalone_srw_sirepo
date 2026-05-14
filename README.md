# Sirepo_Win

Portable Windows installer for [Sirepo](https://github.com/radiasoft/sirepo)
(SRW only). No admin needed. Everything stays under this directory — delete
the folder to uninstall.

## Quick start

In PowerShell (or double-click `setup.bat`):

```
.\setup.bat
```

or

```
.\setup.ps1
```

First run takes ~10-15 min (downloads MSYS2 + portable QEMU + Ubuntu 22.04
cloud image + Python embeddable + srwpy, then boots a VM and installs Sirepo
on first boot). Subsequent runs reuse the cached pieces and are back in QEMU
in seconds.

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

```
Sirepo_Win/
├── msys64/         portable MSYS2 -> portable QEMU 11.0.0 (~700 MB)
├── python-native/  Python 3.12 embeddable + srwpy + worker deps (~100 MB)
├── qemu-vm/        cloud-init seed.iso + writable overlay.qcow2
├── .cache/         downloads (Ubuntu image, MSYS2 base, etc.)
├── state/runs/     SRW job inputs/outputs (shared with the guest via WebDAV)
└── (msys64/python-native/qemu-vm/.cache/state are all gitignored)
```

Total disk: ~3 GB after first install.

## Architecture

```
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

## Component scripts (no need to run manually)

| Script                                | What it does                                  |
| ------------------------------------- | --------------------------------------------- |
| `setup.ps1`                           | Orchestrates everything (this is the only one to run) |
| `scripts/bootstrap-msys2.ps1`         | Portable MSYS2 install (no admin)             |
| `scripts/bootstrap-python-native.ps1` | Python 3.12 embeddable + srwpy + worker deps  |
| `scripts/bootstrap-qemu.ps1`          | pacman-install QEMU, download jammy, build seed ISO, launch |
| `scripts/install-sirepo.sh`           | Runs inside the VM via cloud-init             |
| `scripts/run-worker.ps1`              | Manual worker launcher (for debugging)        |
| `worker/worker.py`                    | FastAPI: `/health`, `/run`, `/dav`            |
| `sirepo_patches/job_driver_windows_native.py` | The Sirepo-side driver stub           |

## Troubleshooting

**Boot stalls on `Cloud-init: Final Stage`.** Cloud-init is doing the first-
boot `apt install` + `pip install` (~3 min on WHPX, ~10-15 on TCG). The
progress goes to the QEMU stdout window.

**`Worker not running` on launch.** Something else is on port 8311. Stop it
or pass `-WorkerPort <free port>` to `setup.ps1`.

**`HTTP 000` / connection reset on <http://localhost:8000>.** Cloud-init
hasn't finished yet, or Sirepo crashed inside the VM. Check the QEMU console
output; `sirepo.service` logs go to systemd journal inside the guest.

**Need to start over.** `Remove-Item -Recurse -Force qemu-vm,.cache,state`
(or just delete those folders) and re-run `.\setup.ps1`. To re-download
MSYS2/QEMU/Python too, also delete `msys64` and `python-native`.

## License

Sirepo and pykern are Apache 2.0 (RadiaSoft LLC). Sirepo_Win-side code in
this repo is the same. The `sirepo_patches/` files include the RadiaSoft
copyright header where they overlay Sirepo source.
