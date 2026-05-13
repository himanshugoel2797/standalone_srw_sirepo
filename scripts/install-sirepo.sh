#!/bin/bash
# Install Sirepo + pykern into /opt/sirepo-venv inside a Linux env.
# Backend-agnostic: invoked the same way by the WSL2 and QEMU bootstrap paths.
#
# Usage: install-sirepo.sh [--force] <sirepo-src-dir> <pykern-src-dir>
#
# Source dirs must contain a checked-out clone of radiasoft/sirepo and
# radiasoft/pykern respectively. They can be anywhere readable -- /mnt/c/... for
# the WSL2 path, /opt/... for the QEMU path.

set -euo pipefail

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
    shift
fi

if [[ $# -ne 2 ]]; then
    echo "usage: $0 [--force] <sirepo-src-dir> <pykern-src-dir>" >&2
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

echo "--- apt update + install base packages ---"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv python3-dev \
    git build-essential pkg-config \
    libffi-dev libssl-dev libxml2-dev libxslt1-dev \
    libjpeg-dev libpng-dev libfreetype-dev libtiff-dev libwebp-dev \
    zlib1g-dev libldap2-dev libsasl2-dev libldap-common \
    nodejs npm \
    curl ca-certificates

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

echo "--- upgrade pip + install pykern (editable) ---"
pip install --upgrade pip wheel setuptools
pip install -e "$PYKERN_SRC"

echo "--- install sirepo (editable; pulls remaining deps) ---"
pip install -e "$SIREPO_SRC"

echo "--- smoke test ---"
which sirepo
python -c 'import sirepo, pykern; print("OK: sirepo + pykern importable")'
sirepo --help 2>&1 | head -3 || true
