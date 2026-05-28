#!/bin/sh
set -euo pipefail
# Simple installer: copy to /usr/src, register with DKMS, build & install
# Usage: run from repo root: sudo ./scripts/install-dkms.sh

VER=1.0
MODULE=hid-rakk-dasig-x
SRC_DIR=$(pwd)
DEST="/usr/src/${MODULE}-${VER}"

echo "Installing ${MODULE} (version ${VER}) to DKMS..."

sudo rm -rf "${DEST}"
sudo cp -r "${SRC_DIR}" "${DEST}"

# remove any previous DKMS instances (ignore errors)
sudo dkms remove -m ${MODULE} -v ${VER} --all || true

sudo dkms add -m ${MODULE} -v ${VER}
sudo dkms build -m ${MODULE} -v ${VER}
sudo dkms install -m ${MODULE} -v ${VER}

echo "Running dkms autoinstall to ensure all kernels are covered..."
sudo dkms autoinstall

echo "Done. To manually bind a device use the new_id method (example IDs):"
echo "  sudo sh -c 'echo 248a fb01 > /sys/bus/hid/drivers/hid_rakk_dasig_x/new_id'"

echo "If you want a udev rule to bind on plug, see udev/99-hid-rakk.rules in the repo."
