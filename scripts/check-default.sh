#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
LOG_FILE="${LOG_FILE:-check-default.log}"
FAILURE_CONTEXT="unexpected failure"

PACKAGES=(
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

log_installed_qemu_packages() {
  local context="$1"
  local installed_qemu_packages=()

  mapfile -t installed_qemu_packages < <(
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${source:Package}\n' 2>/dev/null \
      | awk '$2 == "installed" && ($3 == "qemu" || $3 == "qemu-hwe") {print $1}' \
      | sort
  )

  step "  >>> Installed qemu/qemu-hwe packages ($context):"
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
    log_installed_qemu_packages "failure snapshot (${FAILURE_CONTEXT})"
  fi

  trap - EXIT
  exit "$status"
}

trap on_exit EXIT

remove_all_qemu_packages() {
  local all_pkgs=()
  local base_pkg=""

  for base_pkg in "${PACKAGES[@]}"; do
    all_pkgs+=("$base_pkg" "${base_pkg}-hwe")
  done

  run_cmd_allow_fail "Removing all qemu base/-hwe packages (best-effort)" \
    apt-get remove -y "${all_pkgs[@]}"
}

verify_only_base_variants() {
  local base_pkg=""
  local installed_any_qemu=0

  for base_pkg in "${PACKAGES[@]}"; do
    if is_installed "${base_pkg}-hwe"; then
      echo "ERROR [default-check]: unexpected -hwe package installed: ${base_pkg}-hwe"
      return 1
    fi

    if is_installed "$base_pkg"; then
      installed_any_qemu=1
    fi
  done

  if [ "$installed_any_qemu" -eq 0 ]; then
    echo "ERROR [default-check]: no base qemu package installed after dependency installs"
    return 1
  fi

  return 0
}

run_cmd "Refreshing apt metadata" apt-get -o APT::Sandbox::User=root -y update

remove_all_qemu_packages

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

log_installed_qemu_packages "after default dependency installs"

echo "Detailed command output saved to: $LOG_FILE"
echo "Validation passed. Only base qemu variants are installed."
