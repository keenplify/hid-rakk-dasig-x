#!/usr/bin/env bash
set -euo pipefail
# Simple installer: copy to /usr/src, register with DKMS, build & install.
# Optional: setup/sign module for Secure Boot.
# Usage: run from repo root: sudo ./scripts/install-dkms.sh [--secure-boot] [--mok-key PATH] [--mok-cert PATH]

VER=1.0
MODULE=hid-rakk-dasig-x
SRC_DIR=$(pwd)
DEST="/usr/src/${MODULE}-${VER}"
SECURE_BOOT=0
MOK_KEY="/root/.secureboot/MOK.priv"
MOK_CERT="/root/.secureboot/MOK.der"

usage() {
	cat <<EOF
Usage: sudo ./scripts/install-dkms.sh [options]

Options:
  --secure-boot       Generate/enroll MOK key if needed and sign installed module(s)
  --mok-key PATH      Path to MOK private key (default: ${MOK_KEY})
  --mok-cert PATH     Path to MOK public cert in DER format (default: ${MOK_CERT})
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--secure-boot)
			SECURE_BOOT=1
			shift
			;;
		--mok-key)
			MOK_KEY="$2"
			shift 2
			;;
		--mok-cert)
			MOK_CERT="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1"
			usage
			exit 1
			;;
	esac
done

find_sign_tool() {
	local kernel="$1"
	local tool="/lib/modules/${kernel}/build/scripts/sign-file"
	if [[ -x "$tool" ]]; then
		echo "$tool"
		return
	fi

	if command -v kmodsign >/dev/null 2>&1; then
		command -v kmodsign
		return
	fi

	echo ""
}

sign_modules_for_secure_boot() {
	local key="$1"
	local cert="$2"
	local any_signed=0

	if ! command -v mokutil >/dev/null 2>&1; then
		echo "ERROR: mokutil not found. Install 'mokutil' first."
		exit 1
	fi

	if ! command -v openssl >/dev/null 2>&1; then
		echo "ERROR: openssl not found. Install 'openssl' first."
		exit 1
	fi

	if [[ ! -f "$key" || ! -f "$cert" ]]; then
		echo "MOK key/cert not found, generating new key pair..."
		sudo mkdir -p "$(dirname "$key")"
		sudo openssl req -new -x509 -newkey rsa:2048 \
			-keyout "$key" -out "$cert" -outform DER \
			-nodes -days 36500 -subj "/CN=hid-rakk-dasig-x MOK/"
		sudo chmod 600 "$key"
	fi

	if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
		if ! mokutil --test-key "$cert" >/dev/null 2>&1; then
			echo "Secure Boot is enabled and MOK cert is not enrolled."
			echo "Importing cert with mokutil (you will set a one-time password)..."
			sudo mokutil --import "$cert"
			echo "IMPORTANT: Reboot and complete MOK enrollment in firmware UI, then run this script again."
		fi
	else
		echo "Secure Boot is not enabled; skipping MOK enrollment checks."
	fi

	for module_path in /lib/modules/*/updates/dkms/${MODULE}.ko /lib/modules/*/kernel/drivers/hid/${MODULE}.ko; do
		[[ -f "$module_path" ]] || continue

		local kernel
		kernel=$(echo "$module_path" | cut -d'/' -f4)
		local sign_tool
		sign_tool=$(find_sign_tool "$kernel")

		if [[ -z "$sign_tool" ]]; then
			echo "WARNING: Could not find sign-file/kmodsign for kernel ${kernel}; skipping ${module_path}"
			continue
		fi

		echo "Signing ${module_path} using ${sign_tool}"
		sudo "$sign_tool" sha256 "$key" "$cert" "$module_path"
		sudo depmod -a "$kernel"
		any_signed=1
	done

	if [[ "$any_signed" -eq 0 ]]; then
		echo "WARNING: No installed ${MODULE}.ko files found to sign."
	else
		echo "Secure Boot signing complete."
	fi
}

echo "Installing ${MODULE} (version ${VER}) to DKMS..."

sudo rm -rf "${DEST}"
sudo cp -r "${SRC_DIR}" "${DEST}"

# Remove previous DKMS instance only if present.
if sudo dkms status -m "${MODULE}" -v "${VER}" | grep -q "${MODULE}/${VER}"; then
	sudo dkms remove -m "${MODULE}" -v "${VER}" --all
fi

sudo dkms add -m ${MODULE} -v ${VER}
sudo dkms build -m ${MODULE} -v ${VER}
sudo dkms install -m ${MODULE} -v ${VER}

echo "Running dkms autoinstall to ensure all kernels are covered..."
sudo dkms autoinstall

if [[ "$SECURE_BOOT" -eq 1 ]]; then
	echo "Secure Boot mode enabled: setting up MOK and signing installed modules..."
	sign_modules_for_secure_boot "$MOK_KEY" "$MOK_CERT"
fi

echo "Done. To manually bind a device use the new_id method (example IDs):"
echo "  sudo sh -c 'echo 248a fb01 > /sys/bus/hid/drivers/hid_rakk_dasig_x/new_id'"

echo "If you want a udev rule to bind on plug, see udev/99-hid-rakk.rules in the repo."
