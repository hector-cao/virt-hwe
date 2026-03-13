#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
LOG_FILE="${LOG_FILE:-check-idempotence.log}"
FAILURE_CONTEXT="unexpected failure"

# Sources used to identify "virt" packages to track.
VIRT_SOURCES="edk2|edk2-hwe|seabios|seabios-hwe|libvirt|libvirt-hwe|qemu|qemu-hwe"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

is_installed() {
  local status
  status="$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)"
  [ "$status" = "installed" ]
}

get_installed_virt_packages() {
  dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${source:Package}\n' 2>/dev/null \
    | awk -v sources="$VIRT_SOURCES" '
        BEGIN { n = split(sources, s, "|"); for (i=1;i<=n;i++) src[s[i]]=1 }
        $2 == "installed" && ($3 in src) { print $1 }
      ' \
    | sort
}

step() { echo "[STEP] $*"; }

run_cmd() {
  local description="$1"; shift
  step "$description"
  "$@" >>"$LOG_FILE" 2>&1
}

exit_with_failure() {
  echo "ERROR: $1"
  FAILURE_CONTEXT="$2"
  exit 1
}

on_exit() {
  local status=$?
  set +e
  if [ "$status" -ne 0 ]; then
    echo
    echo "=== Installed virt packages at failure (${FAILURE_CONTEXT}) ==="
    get_installed_virt_packages | sed 's/^/  - /'
  fi
  trap - EXIT
  exit "$status"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Error: $(basename "$0") must run as root." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Error: apt-get is required." >&2
  exit 1
fi

: > "$LOG_FILE"

run_cmd "Refreshing apt metadata" \
  apt-get -o APT::Sandbox::User=root -y update

# ---------------------------------------------------------------------------
# Step 1: install image-factory
# ---------------------------------------------------------------------------

run_cmd "Installing image-factory" \
  apt-get install -y -o Dpkg::Options::=--force-confnew image-factory

# ---------------------------------------------------------------------------
# Step 2: collect installed virt packages
# ---------------------------------------------------------------------------

step "Collecting installed virt packages after image-factory install"
mapfile -t BASELINE_PKGS < <(get_installed_virt_packages)

if [ "${#BASELINE_PKGS[@]}" -eq 0 ]; then
  exit_with_failure \
    "no virt packages are installed after image-factory install" \
    "post-image-factory package collection"
fi

echo "Collected virt packages (${#BASELINE_PKGS[@]}):"
for pkg in "${BASELINE_PKGS[@]}"; do
  echo "  - $pkg"
done

# ---------------------------------------------------------------------------
# Step 3: install qemu-utils-hwe
# ---------------------------------------------------------------------------

run_cmd "Installing qemu-utils-hwe" \
  apt-get install -y -o Dpkg::Options::=--force-confnew qemu-utils-hwe

# ---------------------------------------------------------------------------
# Step 4: verify baseline packages switched to -hwe counterparts
# ---------------------------------------------------------------------------

step "Verifying collected baseline packages switched to -hwe counterparts"
had_error=0

for pkg in "${BASELINE_PKGS[@]}"; do
  [[ "$pkg" == *-hwe ]] && continue

  hwe_pkg="${pkg}-hwe"
  if ! is_installed "$hwe_pkg"; then
    echo "ERROR: expected $hwe_pkg to be installed"
    had_error=1
    continue
  fi

  if is_installed "$pkg"; then
    echo "ERROR: base package is still installed: $pkg"
    had_error=1
    continue
  fi

  echo "OK: $pkg -> $hwe_pkg"
done

if ! is_installed "qemu-utils-hwe"; then
  echo "ERROR: expected qemu-utils-hwe to be installed"
  had_error=1
fi

if is_installed "qemu-utils"; then
  echo "ERROR: qemu-utils is still installed alongside qemu-utils-hwe"
  had_error=1
fi

if [ "$had_error" -ne 0 ]; then
  exit_with_failure \
    "some baseline virt packages did not switch to -hwe counterparts" \
    "post-install package verification"
fi

echo
echo "Baseline package switch verification passed."
echo "Detailed command output saved to: $LOG_FILE"
