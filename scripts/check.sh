#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
LOG_FILE="${LOG_FILE:-check.log}"
CHECK_EXT_DEPS=0
FAILURE_CONTEXT="unexpected failure"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Checks base/-hwe package exclusivity by installation tests.

Options:
  --ext-deps  Also test external dependency install (debvm, genimage, sbuild-qemu, libvirt-daemon-driver-qemu) during checks
  -h, --help  Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ext-deps)
      CHECK_EXT_DEPS=1
      shift
      ;;
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

is_installed() {
  local package_name="$1"
  local status=""

  status="$(dpkg-query -W -f='${db:Status-Status}' "$package_name" 2>/dev/null || true)"
  [ "$status" = "installed" ]
}

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: check.sh must run as root (required for apt install/remove)." >&2
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

log_installed_virt_packages() {
  local context="$1"
  local installed_virt_packages=()

  mapfile -t installed_virt_packages < <(
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${source:Package}\n' 2>/dev/null \
      | awk '$2 == "installed" && ($3 == "qemu" || $3 == "qemu-hwe" || $3 == "edk2" || $3 == "edk2-hwe" || $3 == "libvirt" || $3 == "libvirt-hwe") {print $1}' \
      | sort
  )

  step "  >>> Installed packages ($context):"
  if [ "${#installed_virt_packages[@]}" -eq 0 ]; then
    step "  (none)"
    return
  fi

  for pkg in "${installed_virt_packages[@]}"; do
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

check_exclusive_state() {
  local base_pkg="$1"
  local hwe_pkg="$2"
  local expected_set="$3"
  local context="$4"

  local pkg=""
  local installed_pkg=""

  step "Checking exclusivity ($context): expected set=$expected_set, pair=${base_pkg}<->${hwe_pkg}"

  if [ "$expected_set" = "base" ]; then
    if ! is_installed "$base_pkg"; then
      echo "ERROR [$context]: expected $base_pkg to be installed"
      return 1
    fi

    for pkg in "${PACKAGES[@]}"; do
      if is_installed "${pkg}-hwe"; then
        installed_pkg="${pkg}-hwe"
        echo "ERROR [$context]: unexpected -hwe package installed: $installed_pkg"
        return 1
      fi
    done
  elif [ "$expected_set" = "hwe" ]; then
    if ! is_installed "$hwe_pkg"; then
      echo "ERROR [$context]: expected $hwe_pkg to be installed"
      return 1
    fi

    for pkg in "${PACKAGES[@]}"; do
      if is_installed "$pkg"; then
        installed_pkg="$pkg"
        echo "ERROR [$context]: unexpected base package installed: $installed_pkg"
        return 1
      fi
    done
  else
    echo "ERROR [$context]: unknown expected set '$expected_set'"
    return 1
  fi

  step "Exclusivity check passed ($context)"
  log_installed_virt_packages "$context"

  return 0
}

install_package() {
  local package_name="$1"

  run_cmd "Installing package: $package_name" \
    apt-get install -y -o Dpkg::Options::=--force-confnew "$package_name"
}

check_external_deps_stage() {
  local expected_set="$3"
  local context="$4"

  if ! run_cmd "Installing package: debvm ($context)" \
    apt-get install -y -o Dpkg::Options::=--force-confnew debvm; then
    echo "ERROR [$context]: failed to install debvm"
    return 1
  fi
  log_installed_virt_packages "$context after debvm install"

  step "Validating genimage suggests installed one qemu-utils variant ($context)"
  if ! run_cmd "Installing package: genimage with suggests ($context)" \
    apt-get install -y --install-suggests -o Dpkg::Options::=--force-confnew genimage; then
    echo "ERROR [$context]: failed to install genimage"
    return 1
  fi
  if [ "$expected_set" = "base" ]; then
    if ! is_installed "qemu-utils" || is_installed "qemu-utils-hwe"; then
      echo "ERROR [$context]: expected qemu-utils installed and qemu-utils-hwe not installed after genimage installation"
      return 1
    fi
  elif [ "$expected_set" = "hwe" ]; then
    if ! is_installed "qemu-utils-hwe" || is_installed "qemu-utils"; then
      echo "ERROR [$context]: expected qemu-utils-hwe installed and qemu-utils not installed after genimage installation"
      return 1
    fi
  else
    echo "ERROR [$context]: unknown expected set '$expected_set'"
    return 1
  fi
  log_installed_virt_packages "$context after genimage install"

  step "Validating sbuild-qemu selected correct qemu-system-x86 variant ($context)"
  if ! run_cmd "Installing package: sbuild-qemu ($context)" \
    apt-get install -y -o Dpkg::Options::=--force-confnew sbuild-qemu; then
    echo "ERROR [$context]: failed to install sbuild-qemu"
    return 1
  fi
  if [ "$expected_set" = "base" ]; then
    if ! is_installed "qemu-system-x86" || is_installed "qemu-system-x86-hwe"; then
      echo "ERROR [$context]: expected qemu-system-x86 installed and qemu-system-x86-hwe not installed"
      return 1
    fi
  elif [ "$expected_set" = "hwe" ]; then
    if ! is_installed "qemu-system-x86-hwe" || is_installed "qemu-system-x86"; then
      echo "ERROR [$context]: expected qemu-system-x86-hwe installed and qemu-system-x86 not installed"
      return 1
    fi
  else
    echo "ERROR [$context]: unknown expected set '$expected_set'"
    return 1
  fi
  log_installed_qemu_packages "$context after sbuild-qemu install"

  step "Validating libvirt-daemon-driver-qemu selected correct qemu-system-x86 variant ($context)"
  if ! run_cmd "Installing package: libvirt-daemon-driver-qemu ($context)" \
    apt-get install -y -o Dpkg::Options::=--force-confnew libvirt-daemon-driver-qemu; then
    echo "ERROR [$context]: failed to install libvirt-daemon-driver-qemu"
    return 1
  fi
  if [ "$expected_set" = "base" ]; then
    if ! is_installed "qemu-system-x86" || is_installed "qemu-system-x86-hwe"; then
      echo "ERROR [$context]: expected qemu-system-x86 installed and qemu-system-x86-hwe not installed after libvirt-daemon-driver-qemu installation"
      return 1
    fi
  elif [ "$expected_set" = "hwe" ]; then
    if ! is_installed "qemu-system-x86-hwe" || is_installed "qemu-system-x86"; then
      echo "ERROR [$context]: expected qemu-system-x86-hwe installed and qemu-system-x86 not installed after libvirt-daemon-driver-qemu installation"
      return 1
    fi
  else
    echo "ERROR [$context]: unknown expected set '$expected_set'"
    return 1
  fi
  log_installed_virt_packages "$context after libvirt-daemon-driver-qemu install"

  return 0
}

remove_pair() {
  local base_pkg="$1"
  local hwe_pkg="$2"

  run_cmd_allow_fail "Removing pair (best-effort): $base_pkg $hwe_pkg" \
    apt-get remove -y "$base_pkg" "$hwe_pkg"
}

remove_all_test_packages() {
  local all_pkgs=()
  local base_pkg=""

  for base_pkg in "${PACKAGES[@]}"; do
    all_pkgs+=("$base_pkg" "${base_pkg}-hwe")
  done

  run_cmd_allow_fail "Removing all test packages (best-effort)" \
    apt-get remove -y "${all_pkgs[@]}"
}

remove_external_dep_packages() {
  run_cmd_allow_fail "Removing external deps (best-effort): debvm genimage sbuild-qemu libvirt-daemon-driver-qemu" \
    apt-get remove -y debvm genimage sbuild-qemu libvirt-daemon-driver-qemu
}

checked_pairs=0

run_cmd "Refreshing apt metadata" apt-get -o APT::Sandbox::User=root -y update

for base_pkg in "${PACKAGES[@]}"; do
  hwe_pkg="${base_pkg}-hwe"
  checked_pairs=$((checked_pairs + 1))

  echo
  echo "=== Checking pair: $base_pkg <-> $hwe_pkg ==="

  remove_external_dep_packages
  remove_all_test_packages

  if ! install_package "$base_pkg"; then
    exit_with_failure "failed to install $base_pkg" "failure snapshot after base install failure"
  fi

  if ! check_exclusive_state "$base_pkg" "$hwe_pkg" "base" "after base(+ext-deps) install"; then
    exit_with_failure "base exclusivity check failed for $base_pkg/$hwe_pkg" "failure snapshot after base exclusivity check"
  fi

  if [ "$CHECK_EXT_DEPS" -eq 1 ]; then
    if ! check_external_deps_stage "$base_pkg" "$hwe_pkg" "base" "base variant check"; then
      exit_with_failure "base external dependency check failed for $base_pkg/$hwe_pkg" "failure snapshot after base external deps check"
    fi
  fi

  remove_external_dep_packages
  remove_all_test_packages

  if ! install_package "$hwe_pkg"; then
    exit_with_failure "failed to install $hwe_pkg" "failure snapshot after hwe install failure"
  fi

  if ! check_exclusive_state "$base_pkg" "$hwe_pkg" "hwe" "after hwe(+ext-deps) install"; then
    exit_with_failure "hwe exclusivity check failed for $base_pkg/$hwe_pkg" "failure snapshot after hwe exclusivity check"
  fi

  if [ "$CHECK_EXT_DEPS" -eq 1 ]; then
    if ! check_external_deps_stage "$base_pkg" "$hwe_pkg" "hwe" "hwe variant check"; then
      exit_with_failure "hwe external dependency check failed for $base_pkg/$hwe_pkg" "failure snapshot after hwe external deps check"
    fi
  fi

  echo "OK: $base_pkg/$hwe_pkg installation switch behaves correctly"
done

echo "Checked package pairs: $checked_pairs"

echo "Detailed command output saved to: $LOG_FILE"

echo "Validation passed. No base/-hwe package mix detected during install checks."
