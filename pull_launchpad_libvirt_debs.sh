#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://launchpad.net/ubuntu/+archive/primary/+files}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"
VERSION="${VERSION:-12.0.0-1ubuntu3}"
EXTRACT_BASE_DIR="${EXTRACT_BASE_DIR:-}"

PACKAGES=(
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
  libvirt-daemon-system-systemd
  libvirt-daemon-system-sysv
  libvirt-login-shell
  libvirt-sanlock
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--output-dir DIR] [--extract-dir DIR] [--base-url URL] [--version VER] [--unpack] [--pack]

Downloads libvirt Debian binary packages from Launchpad's Primary archive files page,
filtering to a fixed list of libvirt package names.

Options:
  --output-dir DIR   Destination directory (default: current directory)
  --extract-dir DIR  Base extraction directory (default: OUTPUT_DIR/extracted)
  --base-url URL     Launchpad files URL prefix (default: $BASE_URL)
  --version VER      Package version filter (default: $VERSION)
  --unpack           Extract control.tar.zst and unpack its contents
  --pack             Rebuild .deb from modified control/ folders (also *-hwe)
  -h, --help         Show this help

Environment variables:
  OUTPUT_DIR, EXTRACT_BASE_DIR, BASE_URL, VERSION
EOF
}

UNPACK=0
PACK=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --base-url)
      BASE_URL="$2"
      shift 2
      ;;
    --extract-dir)
      EXTRACT_BASE_DIR="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --unpack)
      UNPACK=1
      shift
      ;;
    --pack)
      PACK=1
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

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 1
fi

if [ "$UNPACK" -eq 1 ] || [ "$PACK" -eq 1 ]; then
  if ! command -v ar >/dev/null 2>&1; then
    echo "Error: ar is required." >&2
    exit 1
  fi

  if ! command -v tar >/dev/null 2>&1; then
    echo "Error: tar is required." >&2
    exit 1
  fi

  if ! command -v zstd >/dev/null 2>&1; then
    echo "Error: zstd is required." >&2
    exit 1
  fi
fi

mkdir -p "$OUTPUT_DIR"

if [ "$UNPACK" -eq 1 ] || [ "$PACK" -eq 1 ]; then
  if [ -z "$EXTRACT_BASE_DIR" ]; then
    EXTRACT_BASE_DIR="$OUTPUT_DIR/extracted"
  fi

  mkdir -p "$EXTRACT_BASE_DIR"
fi

BASE_URL="${BASE_URL%/}"

KNOWN_ARCHES=(
  amd64
  all
)

downloaded=0
skipped=0
not_found=0
extracted=0
packed=0

extract_deb() {
  local deb_path="$1"
  local package_name="$2"
  local arch_name="$3"
  local target_dir="$EXTRACT_BASE_DIR/$package_name/$arch_name"
  local hwe_target_dir="$EXTRACT_BASE_DIR/${package_name}-hwe/$arch_name"
  local control_dir="$target_dir/control"
  local hwe_control_file="$hwe_target_dir/control/control"
  local members

  rm -rf "$target_dir"
  mkdir -p "$target_dir"

  members="$(ar t "$deb_path")"
  if printf '%s\n' "$members" | grep -Fxq "control.tar.zst"; then
    ar p "$deb_path" "control.tar.zst" > "$target_dir/control.tar.zst"
    mkdir -p "$control_dir"
    zstd -dc "$target_dir/control.tar.zst" | tar -x -f - -C "$control_dir"
    rm -f "$target_dir/control.tar.zst"
  else
    echo "Missing member in $(basename "$deb_path"): control.tar.zst"
  fi

  extracted=$((extracted + 1))

  rm -rf "$hwe_target_dir"
  mkdir -p "$hwe_target_dir"
  cp -a "$target_dir/." "$hwe_target_dir/"

  if [ -f "$hwe_control_file" ]; then
    sed -i -E "s/^Package:[[:space:]]+.*/Package: ${package_name}-hwe/" "$hwe_control_file"
  fi

  echo "Unpacked control contents: $control_dir"
  echo "Duplicated package folder: $hwe_target_dir"
}

resolve_source_deb() {
  local package_name="$1"
  local arch_name="$2"
  local candidate=""
  local candidate_deb=""

  for candidate in "$package_name" "${package_name%-hwe}"; do
    candidate_deb="$OUTPUT_DIR/${candidate}_${VERSION}_${arch_name}.deb"
    if [ -f "$candidate_deb" ]; then
      printf '%s\n' "$candidate_deb"
      return 0
    fi
  done

  return 1
}

pack_deb() {
  local package_name="$1"
  local arch_name="$2"
  local control_dir="$EXTRACT_BASE_DIR/$package_name/$arch_name/control"
  local source_deb=""
  local tmpdir=""
  local data_member=""
  local package_version="$VERSION"
  local out_deb=""

  if [ ! -d "$control_dir" ]; then
    return 0
  fi

  if ! source_deb="$(resolve_source_deb "$package_name" "$arch_name")"; then
    echo "Skipping pack for $package_name/$arch_name (source deb not found)"
    return 0
  fi

  if [ -f "$control_dir/control" ]; then
    package_version="$(awk -F': ' '$1 == "Version" {print $2; exit}' "$control_dir/control")"
    if [ -z "$package_version" ]; then
      package_version="$VERSION"
    fi
  fi

  out_deb="$OUTPUT_DIR/${package_name}_${package_version}_${arch_name}.deb"

  data_member="$(ar t "$source_deb" | grep -E '^data\.tar\.' | head -n1 || true)"
  if [ -z "$data_member" ]; then
    echo "Skipping pack for $package_name/$arch_name (missing data.tar.* in source deb)"
    return 0
  fi

  tmpdir="$(mktemp -d)"

  ar p "$source_deb" debian-binary > "$tmpdir/debian-binary"
  ar p "$source_deb" "$data_member" > "$tmpdir/$data_member"
  tar -C "$control_dir" -cf - . | zstd -q -o "$tmpdir/control.tar.zst"

  rm -f "$out_deb"
  (
    cd "$tmpdir"
    ar cr "$out_deb" debian-binary control.tar.zst "$data_member"
  )

  rm -rf "$tmpdir"

  packed=$((packed + 1))
  echo "Packed: $out_deb"
}

run_pack() {
  local package_dir=""
  local package_name=""
  local arch_name=""

  if [ ! -d "$EXTRACT_BASE_DIR" ]; then
    echo "No extraction directory found for --pack: $EXTRACT_BASE_DIR"
    return 0
  fi

  for package_dir in "$EXTRACT_BASE_DIR"/*; do
    [ -d "$package_dir" ] || continue
    package_name="$(basename "$package_dir")"

    for arch_name in "${KNOWN_ARCHES[@]}"; do
      pack_deb "$package_name" "$arch_name"
    done
  done
}

if [ "$PACK" -eq 0 ] || [ "$UNPACK" -eq 1 ]; then
  for package in "${PACKAGES[@]}"; do
    found_for_package=0

    for arch in "${KNOWN_ARCHES[@]}"; do
      deb="${package}_${VERSION}_${arch}.deb"
      url="${BASE_URL}/${deb}"
      dest="$OUTPUT_DIR/$deb"

      if [ -f "$dest" ]; then
        echo "Skipping existing: $deb"
        skipped=$((skipped + 1))
        found_for_package=1
        if [ "$UNPACK" -eq 1 ]; then
          extract_deb "$dest" "$package" "$arch"
        fi
        continue
      fi

      if ! curl -fsSLI "$url" >/dev/null 2>&1; then
        continue
      fi

      found_for_package=1

      echo "Downloading: $deb"
      curl -fL --retry 3 --retry-delay 1 -o "$dest" "$url"
      downloaded=$((downloaded + 1))
      if [ "$UNPACK" -eq 1 ]; then
        extract_deb "$dest" "$package" "$arch"
      fi
    done

    if [ "$found_for_package" -eq 0 ]; then
      echo "No file found for package/version: ${package} ${VERSION}"
      not_found=$((not_found + 1))
    fi
  done
else
  echo "--pack without --unpack: skipping download phase"
fi

if [ "$PACK" -eq 1 ]; then
  run_pack
fi

echo "Done. Downloaded: $downloaded, skipped existing: $skipped"
if [ "$UNPACK" -eq 1 ]; then
  echo "Extracted package files: $extracted"
  echo "Extraction base directory: $EXTRACT_BASE_DIR"
fi
if [ "$PACK" -eq 1 ]; then
  echo "Packed package files: $packed"
fi
echo "Packages not found for selected arch set: $not_found"
echo "Output directory: $OUTPUT_DIR"
