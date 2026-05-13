#!/bin/bash
# Launcher: sets env defaults Sirepo needs to run portably in our WSL distro.
set -euo pipefail

export SIREPO_FEATURE_CONFIG_TRUST_SH_ENV=1
export SIREPO_FEATURE_CONFIG_SIM_TYPES=srw
export PATH=/opt/sirepo-venv/bin:$PATH

# Run state under /var/sirepo (inside distro, fast ext4) -- avoid /mnt/c.
mkdir -p /var/sirepo
cd /var/sirepo

exec /opt/sirepo-venv/bin/sirepo service http
