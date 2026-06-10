#!/usr/bin/env bash
set -euo pipefail
# Simple installer: copy to /usr/src, register with DKMS, build & install.
# Optional: setup/sign module for Secure Boot.
# Usage: run from repo root: sudo ./scripts/install-dkms.sh [--secure-boot] [--mok-key PATH] [--mok-cert PATH]

VER=1.0
MODULE=hid-rakk-dasig-x
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
DEST="/usr/src/${MODULE}-${VER}"
SECURE_BOOT=0
MOK_KEY="/root/.secureboot/MOK.priv"
MOK_CERT="/root/.secureboot/MOK.der"
DKMS_CERT="/var/lib/dkms/mok.pub"

as_root() {
	if [[ "${EUID}" -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

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
			if [[ $# -lt 2 ]]; then
				echo "ERROR: --mok-key requires a path argument"
				exit 1
			fi
			MOK_KEY="$2"
			shift 2
			;;
		--mok-cert)
			if [[ $# -lt 2 ]]; then
				echo "ERROR: --mok-cert requires a path argument"
				exit 1
			fi
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

secure_boot_enabled() {
	mokutil --sb-state 2>/dev/null | grep -qi "enabled"
}

ensure_dkms_key_enrolled() {
	if ! secure_boot_enabled; then
		return
	fi

	if ! command -v mokutil >/dev/null 2>&1; then
		echo "WARNING: Secure Boot is enabled but mokutil is not installed."
		echo "Install mokutil and enroll ${DKMS_CERT} to allow DKMS modules to load."
		return
	fi

	if [[ ! -f "${DKMS_CERT}" ]]; then
		echo "WARNING: Secure Boot is enabled but ${DKMS_CERT} was not found."
		echo "DKMS may not be able to load modules until a signing key is enrolled."
		return
	fi

	if mokutil --test-key "${DKMS_CERT}" >/dev/null 2>&1; then
		echo "DKMS MOK certificate is already enrolled."
		return
	fi

	echo "Secure Boot is enabled and current DKMS key is not enrolled: ${DKMS_CERT}"
	echo "Importing DKMS key with mokutil (you will set a one-time password)..."
	as_root mokutil --import "${DKMS_CERT}"
	echo "IMPORTANT: Reboot and complete MOK enrollment in firmware UI."
	echo "After reboot, run: sudo modprobe hid-rakk-dasig-x"
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
		as_root mkdir -p "$(dirname "$key")"
		as_root openssl req -new -x509 -newkey rsa:2048 \
			-keyout "$key" -out "$cert" -outform DER \
			-nodes -days 36500 -subj "/CN=hid-rakk-dasig-x MOK/"
		as_root chmod 600 "$key"
	fi

	if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
		if ! mokutil --test-key "$cert" >/dev/null 2>&1; then
			echo "Secure Boot is enabled and MOK cert is not enrolled."
			echo "Importing cert with mokutil (you will set a one-time password)..."
			as_root mokutil --import "$cert"
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
		as_root "$sign_tool" sha256 "$key" "$cert" "$module_path"
		as_root depmod -a "$kernel"
		any_signed=1
	done

	if [[ "$any_signed" -eq 0 ]]; then
		echo "WARNING: No installed ${MODULE}.ko files found to sign."
	else
		echo "Secure Boot signing complete."
	fi
}

echo "Installing ${MODULE} (version ${VER}) to DKMS..."

if [[ ! -f "${SRC_DIR}/dkms.conf" ]]; then
	echo "ERROR: dkms.conf not found at ${SRC_DIR}/dkms.conf"
	echo "Run this script from an unpacked project tree that contains dkms.conf."
	exit 1
fi

if secure_boot_enabled && [[ "$SECURE_BOOT" -eq 0 ]]; then
	echo "WARNING: Secure Boot appears enabled. Unsigned modules will fail to load."
	echo "Re-run with: sudo ./scripts/install-dkms.sh --secure-boot"
fi

as_root rm -rf "${DEST}"
as_root cp -r "${SRC_DIR}" "${DEST}"

# Remove previous DKMS instance only if present.
if as_root dkms status -m "${MODULE}" -v "${VER}" | grep -q "${MODULE}/${VER}"; then
	as_root dkms remove -m "${MODULE}" -v "${VER}" --all
fi

as_root dkms add -m ${MODULE} -v ${VER}
as_root dkms build -m ${MODULE} -v ${VER}
as_root dkms install -m ${MODULE} -v ${VER}

echo "Running dkms autoinstall to ensure all kernels are covered..."
as_root dkms autoinstall

ensure_dkms_key_enrolled

if [[ "$SECURE_BOOT" -eq 1 ]]; then
	echo "Secure Boot mode enabled: setting up MOK and signing installed modules..."
	sign_modules_for_secure_boot "$MOK_KEY" "$MOK_CERT"
fi

echo "Done. To manually bind a device use the new_id method (example IDs):"
echo "  sudo sh -c 'echo 248a fb01 > /sys/bus/hid/drivers/rakk-dasig-x/new_id'"

echo "If you want a udev rule to bind on plug, see udev/99-hid-rakk.rules in the repo."
