#!/bin/bash
# Install Sirepo + pykern into /opt/sirepo-venv inside the QEMU guest.
# Inlined into cloud-init's write_files by scripts/bootstrap-qemu.ps1 and
# run on first boot.
#
# Usage: install-sirepo.sh [--force] [--patches <dir>] <sirepo-src-dir> <pykern-src-dir>
#
# Source dirs must contain a checked-out clone of radiasoft/sirepo and
# radiasoft/pykern respectively (cloud-init does this into /opt/{sirepo,pykern}).
#
# --patches <dir> optionally copies Sirepo_Win-side overlay files into the
# sirepo source tree after the editable install. Currently used for the
# windows_native job driver stub (job_driver_windows_native.py ->
# sirepo/job_driver/windows_native.py).

set -euo pipefail

# Stage marker -- sirepo-control.service's /status reads this and the UI shows
# it as "Installing: <stage>" so users see progress past "cloud-init started".
STAGE_FILE=/var/lib/sirepo/install-stage
stage() {
    mkdir -p /var/lib/sirepo
    echo "$1" > "$STAGE_FILE"
}

FORCE=0
PATCHES_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE=1
            shift
            ;;
        --patches)
            PATCHES_DIR="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -ne 2 ]]; then
    echo "usage: $0 [--force] [--patches <dir>] <sirepo-src-dir> <pykern-src-dir>" >&2
    exit 2
fi

SIREPO_SRC="$1"
PYKERN_SRC="$2"

for d in "$SIREPO_SRC" "$PYKERN_SRC"; do
    if [[ ! -d "$d" ]]; then
        echo "Missing source dir: $d" >&2
        exit 1
    fi
done

stage apt-install
echo "--- apt install runtime packages ---"
# Stripped to runtime-only: sirepo/pykern's deps all ship as manylinux x86_64
# wheels, so we don't need build-essential or any -dev headers. Without
# compilation we also don't need nodejs/npm here (vue UI is disabled via
# SIREPO_FEATURE_CONFIG_VUE_SIM_TYPES=). davfs2 + git are installed in
# cloud-init's runcmd already; this list only adds what's left.
# Saves ~30-40s on first boot and ~250 MB of overlay growth.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv \
    ca-certificates

VENV=/opt/sirepo-venv
if (( FORCE )) && [[ -d "$VENV" ]]; then
    echo "--- wiping existing venv (--force) ---"
    rm -rf "$VENV"
fi

if [[ ! -d "$VENV" ]]; then
    echo "--- creating venv at $VENV ---"
    python3 -m venv "$VENV"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"

stage pip-upgrade
echo "--- upgrade pip + install pykern (editable) ---"
pip install --upgrade pip wheel setuptools

stage pip-install-pykern
pip install -e "$PYKERN_SRC"

stage pip-install-sirepo
echo "--- install sirepo (editable; pulls remaining deps) ---"
pip install -e "$SIREPO_SRC"

if [[ -n "$PATCHES_DIR" ]]; then
    stage patches
    if [[ ! -d "$PATCHES_DIR" ]]; then
        echo "--patches dir not found: $PATCHES_DIR" >&2
        exit 1
    fi
    echo "--- applying Sirepo_Win overlay patches from $PATCHES_DIR ---"
    # Convention: a file named job_driver_<name>.py lands at sirepo/job_driver/<name>.py.
    for p in "$PATCHES_DIR"/job_driver_*.py; do
        [[ -e "$p" ]] || continue
        base="$(basename "$p")"
        target_name="${base#job_driver_}"
        target="$SIREPO_SRC/sirepo/job_driver/$target_name"
        cp -v "$p" "$target"
    done
fi

stage smoke-test
echo "--- smoke test ---"
which sirepo
python -c 'import sirepo, pykern; print("OK: sirepo + pykern importable")'
sirepo --help 2>&1 | head -3 || true
