#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://git.launchpad.net/ubuntu/+source/virt-top"
REPO_BRANCH="ubuntu/devel"
KEEP_WORKDIR=0
WORKDIR=""
APT_UPDATED=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--keep-workdir] [--workdir DIR]

Clone ${REPO_URL} (${REPO_BRANCH}), build with dpkg-buildpackage,
and verify the generated virt-top package Depends includes libvirt0.

Options:
  --keep-workdir   Do not delete temporary working directory
  --workdir DIR    Use DIR as working directory (must not already exist)
  -h, --help       Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep-workdir)
      KEEP_WORKDIR=1
      shift
      ;;
    --workdir)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --workdir requires a directory path" >&2
        exit 2
      fi
      WORKDIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $cmd" >&2
    exit 2
  fi
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ERROR: This script must run as root to install dependencies with apt-get." >&2
    exit 2
  fi
}

apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    echo "[1/6] Updating apt metadata"
    apt-get update
    APT_UPDATED=1
  fi
}

install_git_if_missing() {
  if command -v git >/dev/null 2>&1; then
    return
  fi

  apt_update_once
  echo "[2/6] Installing git"
  apt-get install -y git
}

require_root
require_cmd apt-get
install_git_if_missing
require_cmd dpkg-buildpackage
require_cmd dpkg-deb
require_cmd grep

cleanup() {
  if [ "$KEEP_WORKDIR" -eq 0 ] && [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

if [ -z "$WORKDIR" ]; then
  WORKDIR="$(mktemp -d -t check-shdeps-XXXXXX)"
else
  if [ -e "$WORKDIR" ]; then
    echo "ERROR: --workdir path already exists: $WORKDIR" >&2
    exit 2
  fi
  mkdir -p "$WORKDIR"
fi

SRC_DIR="$WORKDIR/virt-top"

echo "[3/6] Cloning ${REPO_URL} branch ${REPO_BRANCH}"
git clone --branch "$REPO_BRANCH" --single-branch "$REPO_URL" "$SRC_DIR"

echo "[4/6] Installing build dependencies"
apt_update_once
if ! apt-get build-dep -y "$SRC_DIR"; then
  echo "ERROR: Failed to install build dependencies for virt-top." >&2
  echo "Hint: ensure source repositories (deb-src) are enabled in apt sources." >&2
  exit 1
fi

pushd "$SRC_DIR" >/dev/null

echo "[5/6] Building package with dpkg-buildpackage"
# -b builds binary packages only; -us -uc skips signing for local checks.
dpkg-buildpackage -b -us -uc

popd >/dev/null

echo "[6/6] Locating built virt-top .deb"
VIRT_TOP_DEB=""
shopt -s nullglob
for deb in "$WORKDIR"/*.deb; do
  if [ "$(dpkg-deb -f "$deb" Package 2>/dev/null || true)" = "virt-top" ]; then
    VIRT_TOP_DEB="$deb"
    break
  fi
done
shopt -u nullglob

if [ -z "$VIRT_TOP_DEB" ]; then
  echo "ERROR: Could not find built virt-top .deb in $WORKDIR" >&2
  exit 1
fi

echo "Found package: $VIRT_TOP_DEB"

echo "Checking Depends for libvirt0"
DEPENDS="$(dpkg-deb -f "$VIRT_TOP_DEB" Depends 2>/dev/null || true)"
if [ -z "$DEPENDS" ]; then
  echo "ERROR: Depends field is empty or unreadable in $VIRT_TOP_DEB" >&2
  exit 1
fi

echo "Depends: $DEPENDS"

if echo "$DEPENDS" | grep -Eq '(^|,)[[:space:]]*libvirt0([[:space:]]*\(|[[:space:]]*\||[[:space:]]*$)'; then
  echo "PASS: virt-top Depends includes libvirt0"
  exit 0
fi

echo "FAIL: virt-top Depends does not include libvirt0" >&2
exit 1
