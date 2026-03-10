#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
LOG_FILE="${LOG_FILE:-check-default.log}"
FAILURE_CONTEXT="unexpected failure"
DOWNLOAD_ROOT="${DOWNLOAD_ROOT:-}"
CREATED_DOWNLOAD_ROOT=0

usage() {
  cat <<USAGE_EOF
Usage: $(basename "$0")

Downloads default external packages (genimage, sbuild-qemu,
libvirt-daemon-driver-qemu, debvm) with apt download and extracts each .deb
into a temporary directory (or DOWNLOAD_ROOT, if provided).

Options:
  -h, --help  Show this help

Environment variables:
  LOG_FILE       Log file path (default: check-default.log)
  DOWNLOAD_ROOT  Directory where downloaded/extracted package content is stored
                 (default: auto-created temporary directory)
USAGE_EOF
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
  echo "Error: check-default.sh must run as root (required for apt metadata refresh)." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Error: apt-get is required." >&2
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  echo "Error: apt is required (for apt download)." >&2
  exit 1
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "Error: dpkg-deb is required (for .deb extraction)." >&2
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

run_cmd_in_dir() {
  local description="$1"
  local work_dir="$2"
  shift 2

  step "$description"
  (
    cd "$work_dir"
    "$@"
  ) >>"$LOG_FILE" 2>&1
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

  trap - EXIT
  exit "$status"
}

trap on_exit EXIT

setup_download_root() {
  if [ -z "$DOWNLOAD_ROOT" ]; then
    DOWNLOAD_ROOT="$(mktemp -d -t check-default-debs.XXXXXX)"
    CREATED_DOWNLOAD_ROOT=1
  else
    mkdir -p "$DOWNLOAD_ROOT"
  fi

  step "Using download root: $DOWNLOAD_ROOT"
}

download_and_extract_package() {
  local package_name="$1"
  local package_download_dir="$DOWNLOAD_ROOT/$package_name"
  local package_extract_dir="$DOWNLOAD_ROOT/extracted/$package_name"
  local package_control_dir="$DOWNLOAD_ROOT/control/$package_name"
  local package_deb=""

  mkdir -p "$package_download_dir"
  mkdir -p "$package_extract_dir"
  mkdir -p "$package_control_dir"

  rm -f "$package_download_dir"/*.deb
  rm -rf "$package_extract_dir"/* "$package_control_dir"/*

  if ! run_cmd_in_dir "Downloading ${package_name} via apt download" "$package_download_dir" \
    apt -o APT::Sandbox::User=root download "$package_name"; then
    exit_with_failure "failed to download ${package_name}" "after ${package_name} download"
  fi

  package_deb="$(find "$package_download_dir" -maxdepth 1 -type f -name '*.deb' | head -n 1)"
  if [ -z "$package_deb" ]; then
    exit_with_failure "downloaded .deb not found for ${package_name}" "after ${package_name} download"
  fi

  if ! run_cmd "Extracting ${package_name} payload to ${package_extract_dir}" \
    dpkg-deb -x "$package_deb" "$package_extract_dir"; then
    exit_with_failure "failed to extract ${package_name} payload" "after ${package_name} payload extract"
  fi

  if ! run_cmd "Extracting ${package_name} control data to ${package_control_dir}" \
    dpkg-deb -e "$package_deb" "$package_control_dir"; then
    exit_with_failure "failed to extract ${package_name} control data" "after ${package_name} control extract"
  fi
}

run_cmd "Refreshing apt metadata" apt-get -o APT::Sandbox::User=root -y update

setup_download_root

download_and_extract_package debvm
download_and_extract_package genimage
download_and_extract_package sbuild-qemu
download_and_extract_package libvirt-daemon-driver-qemu

echo "Detailed command output saved to: $LOG_FILE"
echo "Downloaded .debs and extracted content under: $DOWNLOAD_ROOT"
