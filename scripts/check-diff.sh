#!/usr/bin/env bash
set -euo pipefail

# Static package list copied from scripts/check.sh.
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
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v apt >/dev/null 2>&1; then
  echo "ERROR: apt is required (for apt download)."
  exit 2
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "ERROR: dpkg-deb is required (for .deb extraction)."
  exit 2
fi

TMP_DIR="$(mktemp -d -t check-diff.XXXXXX)"
DOWNLOAD_DIR="$TMP_DIR/downloads"
EXTRACT_DIR="$TMP_DIR/extracted"
CONTROL_DIR="$TMP_DIR/control"
LIST_DIR="$TMP_DIR/lists"

mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_DIR" "$CONTROL_DIR" "$LIST_DIR"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

download_deb() {
  local package_name="$1"
  local package_download_dir="$DOWNLOAD_DIR/$package_name"
  local deb_path=""

  mkdir -p "$package_download_dir"
  rm -f "$package_download_dir"/*.deb

  (
    cd "$package_download_dir"
    apt -o APT::Sandbox::User=root download "$package_name" >/dev/null
  )

  deb_path="$(find "$package_download_dir" -maxdepth 1 -type f -name '*.deb' | head -n 1)"
  if [ -z "$deb_path" ]; then
    return 1
  fi

  echo "$deb_path"
}

extract_deb() {
  local package_name="$1"
  local deb_path="$2"
  local package_extract_dir="$EXTRACT_DIR/$package_name"
  local package_control_dir="$CONTROL_DIR/$package_name"

  rm -rf "$package_extract_dir" "$package_control_dir"
  mkdir -p "$package_extract_dir" "$package_control_dir"

  dpkg-deb -x "$deb_path" "$package_extract_dir"
  dpkg-deb -e "$deb_path" "$package_control_dir"
}

build_file_list() {
  local package_name="$1"
  local package_extract_dir="$EXTRACT_DIR/$package_name"
  local list_path="$2"

  if [ ! -d "$package_extract_dir" ]; then
    return 1
  fi

  (
    cd "$package_extract_dir"
    find . -mindepth 1 ! -type d -printf '%P\n' | sort -u > "$list_path"
  )
}

had_diff=0
had_error=0
checked_pairs=0

for base_pkg in "${PACKAGES[@]}"; do
  hwe_pkg="${base_pkg}-hwe"
  echo "Checking pair: $base_pkg <-> $hwe_pkg"

  base_deb=""
  hwe_deb=""
  if ! base_deb="$(download_deb "$base_pkg")"; then
    echo "ERROR: failed to download base package: $base_pkg"
    had_error=1
    continue
  fi

  if ! hwe_deb="$(download_deb "$hwe_pkg")"; then
    echo "ERROR: failed to download hwe package: $hwe_pkg"
    had_error=1
    continue
  fi

  if ! extract_deb "$base_pkg" "$base_deb"; then
    echo "ERROR: failed to extract base package: $base_pkg"
    had_error=1
    continue
  fi

  if ! extract_deb "$hwe_pkg" "$hwe_deb"; then
    echo "ERROR: failed to extract hwe package: $hwe_pkg"
    had_error=1
    continue
  fi

  base_files="$LIST_DIR/${base_pkg}.files"
  hwe_files="$LIST_DIR/${hwe_pkg}.files"
  only_base="$LIST_DIR/${base_pkg}.only_base.files"
  only_hwe="$LIST_DIR/${base_pkg}.only_hwe.files"

  if ! build_file_list "$base_pkg" "$base_files"; then
    echo "ERROR: failed to build file list for base package: $base_pkg"
    had_error=1
    continue
  fi

  if ! build_file_list "$hwe_pkg" "$hwe_files"; then
    echo "ERROR: failed to build file list for hwe package: $hwe_pkg"
    had_error=1
    continue
  fi

  comm -23 "$base_files" "$hwe_files" > "$only_base"
  comm -13 "$base_files" "$hwe_files" > "$only_hwe"

  if [ -s "$only_base" ] || [ -s "$only_hwe" ]; then
    had_diff=1
    echo "DIFF: $base_pkg <-> $hwe_pkg"

    echo "  Only in $base_pkg ($(wc -l < "$only_base"))"
    cat "$only_base"

    echo "  Only in $hwe_pkg ($(wc -l < "$only_hwe"))"
    cat "$only_hwe"
    echo
  fi

  checked_pairs=$((checked_pairs + 1))
done

if [ "$had_error" -ne 0 ]; then
  echo "Completed with errors while scanning package pairs."
  exit 2
fi

if [ "$had_diff" -ne 0 ]; then
  echo "Compared architecture pairs: $checked_pairs"
  echo "Differences found between base and -hwe package file lists."
  exit 1
fi

echo "Compared architecture pairs: $checked_pairs"
echo "All compared base/-hwe package file lists match."
