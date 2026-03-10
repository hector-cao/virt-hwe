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

if ! command -v apt-cache >/dev/null 2>&1; then
  echo "ERROR: apt-cache is required." >&2
  exit 2
fi

had_error=0
checked=0

for base_pkg in "${PACKAGES[@]}"; do
  hwe_pkg="${base_pkg}-hwe"

  echo "=== ${hwe_pkg} ==="

  if [ "$base_pkg" == "ubuntu-virt" ]; then
    # Skip ubuntu-virt and ubuntu-virt-hwe
    continue
  fi

  if ! depends_output="$(apt-cache depends "$hwe_pkg" 2>/dev/null)"; then
    echo "ERROR: apt-cache depends failed for package: ${hwe_pkg}"
    had_error=1
    continue
  fi

  if [ -z "$depends_output" ]; then
    echo "ERROR: empty apt-cache depends output for package: ${hwe_pkg}"
    had_error=1
    continue
  fi

  if ! showpkg_output="$(apt-cache showpkg "$hwe_pkg" 2>/dev/null)"; then
    echo "ERROR: apt-cache showpkg failed for package: ${hwe_pkg}"
    had_error=1
    continue
  fi

  if [ -z "$showpkg_output" ]; then
    echo "ERROR: empty apt-cache showpkg output for package: ${hwe_pkg}"
    had_error=1
    continue
  fi

  provides_lines="$(echo "$showpkg_output" | awk '
    /^Provides:[[:space:]]*$/ { in_provides=1; next }
    in_provides && /^[[:alpha:]][[:alpha:] ]*:[[:space:]]*$/ { in_provides=0 }
    in_provides { print }
  ')"

  if [ -z "$provides_lines" ]; then
    echo "ERROR: no Provides section found in apt-cache showpkg output for package: ${hwe_pkg}"
    had_error=1
    continue
  fi

  # Show dependency-related lines for visibility.
  echo "$depends_output" | awk '/^[[:space:]]*[| ]*(Depends|Replaces):/ { print }'
  echo "$provides_lines"

  if [ "$hwe_pkg" != "ubuntu-virt-hwe" ]; then
    if ! echo "$depends_output" | grep -Eq '^[[:space:]]*[| ]*Depends:[[:space:]]*ubuntu-virt-hwe([[:space:]]|$)'; then
      echo "ERROR: ${hwe_pkg} does not depend on ubuntu-virt-hwe"
      had_error=1
    fi
  fi

  if ! echo "$depends_output" | grep -Eq "^[[:space:]]*[| ]*Replaces:[[:space:]]*${base_pkg}([[:space:]]|$)"; then
    echo "ERROR: ${hwe_pkg} does not replace ${base_pkg}"
    had_error=1
  fi

  if ! echo "$provides_lines" | grep -Eq "(^|[[:space:]])${base_pkg}([[:space:]]|$|\()"; then
    echo "ERROR: ${hwe_pkg} does not provide ${base_pkg}"
    had_error=1
  fi

  checked=$((checked + 1))
  echo

done

if [ "$had_error" -ne 0 ]; then
  echo "Checked packages: ${checked}"
  echo "HWE dependency/replaces/provides validation FAILED."
  exit 1
fi

echo "Checked packages: ${checked}"
echo "HWE dependency/replaces/provides validation passed."
