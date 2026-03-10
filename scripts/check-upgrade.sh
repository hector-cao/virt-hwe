#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
LOG_FILE="${LOG_FILE:-check-upgrade.log}"
UPGRADE_SOURCE_DIR="${UPGRADE_SOURCE_DIR:-/workspace/hwe-11.2}"
WORKSPACE_ROOT_DIR="${WORKSPACE_ROOT_DIR:-/workspace}"
PPA_UPDATE_SCRIPT="${PPA_UPDATE_SCRIPT:-/workspace/scripts/update_local_ppa_from_dir.sh}"
UPGRADE_VERSION="${UPGRADE_VERSION:-11.2.1+ds-0ubuntu1}"
UPGRADE_ANCHOR_PACKAGE="${UPGRADE_ANCHOR_PACKAGE:-qemu-system-x86-hwe}"
SWITCH_BACK_PACKAGE="${SWITCH_BACK_PACKAGE:-}"
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

Checks -hwe upgrade flow:
  1) install one -hwe package (default: qemu-system-x86-hwe)
  2) update local PPA from hwe-11.2
  3) run apt upgrade
  4) verify only -hwe qemu packages are installed and all are at new version
  5) switch back to base by installing a random base package and verify no -hwe package remains

Options:
  -h, --help  Show this help

Environment variables:
  LOG_FILE                 Log file path (default: check-upgrade.log)
  UPGRADE_SOURCE_DIR       Folder with upgraded -hwe debs (default: /workspace/hwe-11.2)
  WORKSPACE_ROOT_DIR       Workspace root where debs are staged/scanned (default: /workspace)
  PPA_UPDATE_SCRIPT        PPA update helper script (default: /workspace/scripts/update_local_ppa_from_dir.sh)
  UPGRADE_VERSION          Target version without epoch (default: 11.2.1+ds-0ubuntu1)
  UPGRADE_ANCHOR_PACKAGE   Initial -hwe package to install (default: qemu-system-x86-hwe)
  SWITCH_BACK_PACKAGE      Base package to install for switch-back stage (default: random from list)
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
  echo "Error: check-upgrade.sh must run as root (required for apt install/remove/upgrade)." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Error: apt-get is required." >&2
  exit 1
fi

if [ ! -d "$UPGRADE_SOURCE_DIR" ]; then
  echo "Error: UPGRADE_SOURCE_DIR not found: $UPGRADE_SOURCE_DIR" >&2
  exit 1
fi

if [ ! -d "$WORKSPACE_ROOT_DIR" ]; then
  echo "Error: WORKSPACE_ROOT_DIR not found: $WORKSPACE_ROOT_DIR" >&2
  exit 1
fi

if [ ! -f "$PPA_UPDATE_SCRIPT" ]; then
  echo "Error: PPA_UPDATE_SCRIPT not found: $PPA_UPDATE_SCRIPT" >&2
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
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${source:Package}\t${Version}\n' 2>/dev/null \
      | awk '$2 == "installed" && ($3 == "qemu" || $3 == "qemu-hwe") {print $1"\t"$4}' \
      | sort
  )

  step "  >>> Installed qemu/qemu-hwe packages ($context):"
  if [ "${#installed_qemu_packages[@]}" -eq 0 ]; then
    step "  (none)"
    return
  fi

  local row=""
  local pkg=""
  local ver=""
  for row in "${installed_qemu_packages[@]}"; do
    IFS=$'\t' read -r pkg ver <<< "$row"
    step "  - $pkg $ver"
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

remove_all_test_packages() {
  local all_pkgs=()
  local base_pkg=""

  for base_pkg in "${PACKAGES[@]}"; do
    all_pkgs+=("$base_pkg" "${base_pkg}-hwe")
  done

  run_cmd_allow_fail "Removing all qemu test packages (best-effort)" \
    apt-get remove -y "${all_pkgs[@]}"
}

check_only_hwe_installed() {
  local pkg=""
  local installed_qemu_packages=()

  for pkg in "${PACKAGES[@]}"; do
    if is_installed "$pkg"; then
      echo "ERROR [upgrade-check]: unexpected base package installed after upgrade: $pkg"
      return 1
    fi
  done

  mapfile -t installed_qemu_packages < <(
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${source:Package}\n' 2>/dev/null \
      | awk '$2 == "installed" && ($3 == "qemu" || $3 == "qemu-hwe") {print $1}' \
      | sort
  )

  if [ "${#installed_qemu_packages[@]}" -eq 0 ]; then
    echo "ERROR [upgrade-check]: no qemu/qemu-hwe packages installed after upgrade"
    return 1
  fi

  for pkg in "${installed_qemu_packages[@]}"; do
    if [[ "$pkg" != *-hwe ]]; then
      echo "ERROR [upgrade-check]: expected only -hwe packages, found: $pkg"
      return 1
    fi
  done

  return 0
}

check_hwe_versions() {
  local expected_with_epoch="1:${UPGRADE_VERSION}"
  local installed_qemu_packages=()
  local row=""
  local pkg=""
  local version=""

  mapfile -t installed_qemu_packages < <(
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${source:Package}\t${Version}\n' 2>/dev/null \
      | awk '$2 == "installed" && ($3 == "qemu" || $3 == "qemu-hwe") {print $1"\t"$4}' \
      | sort
  )

  for row in "${installed_qemu_packages[@]}"; do
    IFS=$'\t' read -r pkg version <<< "$row"
    if [ "$version" != "$expected_with_epoch" ] && [ "$version" != "$UPGRADE_VERSION" ]; then
      echo "ERROR [upgrade-check]: package $pkg has version $version, expected $expected_with_epoch"
      return 1
    fi
  done

  return 0
}

pick_random_base_package() {
  if [ -n "$SWITCH_BACK_PACKAGE" ]; then
    printf '%s\n' "$SWITCH_BACK_PACKAGE"
    return
  fi

  if command -v shuf >/dev/null 2>&1; then
    printf '%s\n' "${PACKAGES[@]}" | shuf -n1
    return
  fi

  local idx=0
  idx=$((RANDOM % ${#PACKAGES[@]}))
  printf '%s\n' "${PACKAGES[$idx]}"
}

check_no_hwe_installed() {
  local pkg=""

  for pkg in "${PACKAGES[@]}"; do
    if is_installed "${pkg}-hwe"; then
      echo "ERROR [switch-back]: unexpected -hwe package installed: ${pkg}-hwe"
      return 1
    fi
  done

  return 0
}

stage_hwe_debs_to_workspace_root() {
  local source_debs=()

  mapfile -t source_debs < <(find "$UPGRADE_SOURCE_DIR" -maxdepth 1 -type f -name '*.deb' | sort)

  if [ "${#source_debs[@]}" -eq 0 ]; then
    echo "ERROR [upgrade-check]: no .deb files found in $UPGRADE_SOURCE_DIR"
    return 1
  fi

  cp -f "${source_debs[@]}" "$WORKSPACE_ROOT_DIR/"
  step "Staged ${#source_debs[@]} deb files into $WORKSPACE_ROOT_DIR"
  return 0
}

is_known_base_package() {
  local needle="$1"
  local pkg=""

  for pkg in "${PACKAGES[@]}"; do
    if [ "$pkg" = "$needle" ]; then
      return 0
    fi
  done

  return 1
}

run_cmd "Refreshing apt metadata" apt-get -o APT::Sandbox::User=root -y update

if ! run_cmd "Copying upgraded -hwe debs to workspace root: $WORKSPACE_ROOT_DIR" \
  stage_hwe_debs_to_workspace_root; then
  exit_with_failure "failed to copy debs from $UPGRADE_SOURCE_DIR to $WORKSPACE_ROOT_DIR" "after workspace root staging"
fi

# remove_all_test_packages

# if ! run_cmd "Installing anchor -hwe package: $UPGRADE_ANCHOR_PACKAGE" \
#   apt-get install -y -o Dpkg::Options::=--force-confnew "$UPGRADE_ANCHOR_PACKAGE"; then
#   exit_with_failure "failed to install $UPGRADE_ANCHOR_PACKAGE" "after anchor install"
# fi

# if ! is_installed "$UPGRADE_ANCHOR_PACKAGE"; then
#   exit_with_failure "$UPGRADE_ANCHOR_PACKAGE is not installed" "after anchor install verification"
# fi

# if ! run_cmd "Updating local PPA from workspace root: $WORKSPACE_ROOT_DIR" \
#   bash "$PPA_UPDATE_SCRIPT" "$WORKSPACE_ROOT_DIR"; then
#   exit_with_failure "failed to update local PPA from $WORKSPACE_ROOT_DIR" "after PPA update"
# fi

# if ! run_cmd "Running apt upgrade" \
#   apt-get upgrade -y -o Dpkg::Options::=--force-confnew; then
#   exit_with_failure "apt upgrade failed" "after apt upgrade"
# fi

# if ! check_only_hwe_installed; then
#   exit_with_failure "non-hwe package detected after upgrade" "after installed package kind check"
# fi

# if ! check_hwe_versions; then
#   exit_with_failure "upgraded package version check failed" "after upgraded version check"
# fi

# log_installed_qemu_packages "after upgrade"

# SWITCH_BACK_PACKAGE="$(pick_random_base_package)"
# if ! is_known_base_package "$SWITCH_BACK_PACKAGE"; then
#   exit_with_failure "switch-back package '$SWITCH_BACK_PACKAGE' is not in known base package list" "before base switch-back install"
# fi

# step "Selected base package for switch-back check: $SWITCH_BACK_PACKAGE"

# if ! run_cmd "Installing random base package to switch back: $SWITCH_BACK_PACKAGE" \
#   apt-get install -y -o Dpkg::Options::=--force-confnew "$SWITCH_BACK_PACKAGE"; then
#   exit_with_failure "failed to install base package $SWITCH_BACK_PACKAGE" "after base switch-back install"
# fi

# if ! is_installed "$SWITCH_BACK_PACKAGE"; then
#   exit_with_failure "base package $SWITCH_BACK_PACKAGE is not installed" "after base switch-back install verification"
# fi

# if ! check_no_hwe_installed; then
#   exit_with_failure "-hwe package still installed after base switch-back" "after base switch-back exclusivity check"
# fi

# log_installed_qemu_packages "after base switch-back"

# echo "Detailed command output saved to: $LOG_FILE"
# echo "Upgrade validation passed. -hwe upgrade path is valid and base switch-back removes all -hwe packages."
