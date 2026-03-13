#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
LOG_FILE="${LOG_FILE:-check-default.log}"
FAILURE_CONTEXT="unexpected failure"

PACKAGES=(
  ubuntu-virt
  qemu-block-extra
  qemu-block-supplemental
  qemu-guest-agent
  qemu-system
  qemu-system-arm
  qemu-system-common
  qemu-system-data
  qemu-system-gui
  qemu-system-mips
  qemu-system-misc
  qemu-system-modules-opengl
  qemu-system-modules-spice
  qemu-system-ppc
  qemu-system-riscv
  qemu-system-s390x
  qemu-system-sparc
  qemu-system-x86
  qemu-system-x86-xen
  qemu-system-xen
  qemu-user
  qemu-user-binfmt
  qemu-utils
  libvirt-clients
  libvirt-clients-qemu
  libvirt-daemon
  libvirt-daemon-common
  libvirt-daemon-log
  libvirt-daemon-lock
  libvirt-daemon-driver-qemu
  libvirt-daemon-driver-lxc
  libvirt-daemon-driver-vbox
  libvirt-daemon-driver-xen
  libvirt-daemon-driver-storage
  libvirt-daemon-driver-storage-disk
  libvirt-daemon-driver-storage-gluster
  libvirt-daemon-driver-storage-iscsi
  libvirt-daemon-driver-storage-iscsi-direct
  libvirt-daemon-driver-storage-logical
  libvirt-daemon-driver-storage-mpath
  libvirt-daemon-driver-storage-rbd
  libvirt-daemon-driver-storage-scsi
  libvirt-daemon-driver-storage-zfs
  libvirt-daemon-driver-network
  libvirt-daemon-driver-nwfilter
  libvirt-daemon-driver-interface
  libvirt-daemon-driver-nodedev
  libvirt-daemon-driver-secret
  libvirt-daemon-plugin-lockd
  libvirt-daemon-plugin-sanlock
  libvirt-daemon-system
  libvirt-daemon-config-network
  libvirt-daemon-config-nwfilter
  libvirt0
  libvirt-common
  libvirt-l10n
  libvirt-doc
  libvirt-dev
  libnss-libvirt
  libvirt-ssh-proxy
  libvirt-wireshark
  libvirt-login-shell
  libvirt-sanlock
  libvirt-daemon-system-systemd
  libvirt-daemon-system-sysv
  ovmf
  ovmf-generic
  ovmf-legacy
  ovmf-amdsev
  ovmf-inteltdx
  qemu-efi-aarch64
  qemu-efi-riscv64
  efi-shell-x64
  efi-shell-aa64
  efi-shell-riscv64
  seabios
)

usage() {
  cat <<EOF
Usage: $(basename "$0")

Removes qemu base/-hwe package set, installs default external packages
(genimage, sbuild-qemu, libvirt-daemon-driver-qemu, debvm), and validates
that only base qemu variants are installed (no -hwe package present).

Options:
  -h, --help  Show this help

Environment variables:
  LOG_FILE    Log file path (default: check-default.log)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: check-default.sh must run as root (required for apt install/remove)." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Error: apt-get is required." >&2
  exit 1
fi

: > "$LOG_FILE"

step() {
  echo "[STEP] $*"
}

run_cmd() {
  local description="$1"
  shift

  step "$description"
  "$@" >>"$LOG_FILE" 2>&1
}

run_cmd_allow_fail() {
  local description="$1"
  shift

  step "$description"
  "$@" >>"$LOG_FILE" 2>&1 || true
}

is_installed() {
  local package_name="$1"
  local status=""

  status="$(dpkg-query -W -f='${db:Status-Status}' "$package_name" 2>/dev/null || true)"
  [ "$status" = "installed" ]
}

log_installed_virt_packages() {
  local context="$1"
  local installed_qemu_packages=()

  mapfile -t installed_qemu_packages < <(
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${source:Package}\n' 2>/dev/null \
      | awk '$2 == "installed" && (
               $3 == "qemu"       || $3 == "qemu-hwe"    ||
               $3 == "edk2"       || $3 == "edk2-hwe"    ||
               $3 == "seabios"    || $3 == "seabios-hwe" ||
               $3 == "libvirt"    || $3 == "libvirt-hwe"
             ) {print $1}' \
      | sort
  )

  step "  >>> Installed virt packages ($context):"
  if [ "${#installed_qemu_packages[@]}" -eq 0 ]; then
    step "  (none)"
    return
  fi

  local pkg=""
  for pkg in "${installed_qemu_packages[@]}"; do
    step "  - $pkg"
  done
}

exit_with_failure() {
  local message="$1"
  local context="$2"

  echo "ERROR: $message"
  FAILURE_CONTEXT="$context"
  exit 1
}

on_exit() {
  local status=$?
  set +e

  if [ "$status" -ne 0 ]; then
    log_installed_virt_packages "failure snapshot (${FAILURE_CONTEXT})"
  fi

  trap - EXIT
  exit "$status"
}

trap on_exit EXIT

remove_all_virt_packages() {
  local all_pkgs=()
  local base_pkg=""

  for base_pkg in "${PACKAGES[@]}"; do
    all_pkgs+=("$base_pkg" "${base_pkg}-hwe")
  done

  run_cmd_allow_fail "Removing all virt base/-hwe packages (best-effort)" \
    apt-get remove -y "${all_pkgs[@]}"
}

verify_only_base_variants() {
  local base_pkg=""
  local installed_any_virt=0

  for base_pkg in "${PACKAGES[@]}"; do
    if is_installed "${base_pkg}-hwe"; then
      echo "ERROR [default-check]: unexpected -hwe package installed: ${base_pkg}-hwe"
      return 1
    fi

    if is_installed "$base_pkg"; then
      installed_any_virt=1
    fi
  done

  if [ "$installed_any_virt" -eq 0 ]; then
    echo "ERROR [default-check]: no base virt package installed after dependency installs"
    return 1
  fi

  return 0
}

run_cmd "Refreshing apt metadata" apt-get -o APT::Sandbox::User=root -y update

remove_all_virt_packages

if ! run_cmd "Installing debvm" apt-get install -y -o Dpkg::Options::=--force-confnew debvm; then
  exit_with_failure "failed to install debvm" "after debvm install"
fi

if ! run_cmd "Installing genimage (with suggests)" apt-get install -y --install-suggests -o Dpkg::Options::=--force-confnew genimage; then
  exit_with_failure "failed to install genimage" "after genimage install"
fi

if ! run_cmd "Installing sbuild-qemu" apt-get install -y -o Dpkg::Options::=--force-confnew sbuild-qemu; then
  exit_with_failure "failed to install sbuild-qemu" "after sbuild-qemu install"
fi

if ! run_cmd "Installing libvirt-daemon-driver-qemu" apt-get install -y -o Dpkg::Options::=--force-confnew libvirt-daemon-driver-qemu; then
  exit_with_failure "failed to install libvirt-daemon-driver-qemu" "after libvirt-daemon-driver-qemu install"
fi

if ! verify_only_base_variants; then
  exit_with_failure "base variant verification failed" "after final base variant verification"
fi

log_installed_virt_packages "after default dependency installs"

echo "Detailed command output saved to: $LOG_FILE"
echo "Validation passed. Only base qemu variants are installed."
