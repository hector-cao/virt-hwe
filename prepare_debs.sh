#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULL_SCRIPT="$SCRIPT_DIR/pull_launchpad_qemu_debs.sh"
PULL_LIBVIRT_SCRIPT="$SCRIPT_DIR/pull_launchpad_libvirt_debs.sh"
SET_LIBVIRT_BASE_FIELDS_SCRIPT="$SCRIPT_DIR/set_libvirt_base_variant_fields.sh"
SET_LIBVIRT_HWE_FIELDS_SCRIPT="$SCRIPT_DIR/set_libvirt_hwe_variant_fields.sh"
GENERATE_HWE_SCRIPT="$SCRIPT_DIR/generate_hwe_11_2_controls.sh"
PACK_HWE_SCRIPT="$SCRIPT_DIR/pack_hwe_11_2.sh"
EXTRACTED_DIR="$SCRIPT_DIR/extracted"
HWE_11_2_DIR="$SCRIPT_DIR/hwe-11.2"
LIBVIRT_VERSION="12.0.0-1ubuntu3"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Prepare all debs needed by create_container.sh:
  1) pull missing source .deb files
  2) pack base + -hwe .deb files from extracted controls
  3) regenerate hwe-11.2 controls
  4) pack hwe-11.2 .deb files

Options:
  -h, --help     Show this help
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

if [ ! -f "$PULL_SCRIPT" ]; then
  echo "Error: $PULL_SCRIPT not found." >&2
  exit 1
fi

if [ ! -f "$GENERATE_HWE_SCRIPT" ]; then
  echo "Error: $GENERATE_HWE_SCRIPT not found." >&2
  exit 1
fi

if [ ! -f "$PACK_HWE_SCRIPT" ]; then
  echo "Error: $PACK_HWE_SCRIPT not found." >&2
  exit 1
fi

if [ ! -d "$EXTRACTED_DIR" ]; then
  echo "Error: $EXTRACTED_DIR not found." >&2
  exit 1
fi

mkdir -p "$HWE_11_2_DIR"

chmod +x "$PULL_SCRIPT"
chmod +x "$GENERATE_HWE_SCRIPT"
chmod +x "$PACK_HWE_SCRIPT"

if [ -f "$PULL_LIBVIRT_SCRIPT" ]; then
  chmod +x "$PULL_LIBVIRT_SCRIPT"
fi

if [ -f "$SET_LIBVIRT_BASE_FIELDS_SCRIPT" ]; then
  chmod +x "$SET_LIBVIRT_BASE_FIELDS_SCRIPT"
fi

if [ -f "$SET_LIBVIRT_HWE_FIELDS_SCRIPT" ]; then
  chmod +x "$SET_LIBVIRT_HWE_FIELDS_SCRIPT"
fi

echo "Pulling missing .deb files with: $(basename "$PULL_SCRIPT")"
"$PULL_SCRIPT" --output-dir "$SCRIPT_DIR"

echo "Packing base+hwe .deb files with: $(basename "$PULL_SCRIPT") --pack --extract-dir '$EXTRACTED_DIR'"
"$PULL_SCRIPT" --pack --output-dir "$SCRIPT_DIR" --extract-dir "$EXTRACTED_DIR"

if [ ! -f "$PULL_LIBVIRT_SCRIPT" ]; then
  echo "Error: $PULL_LIBVIRT_SCRIPT not found." >&2
  exit 1
fi

if [ ! -f "$SET_LIBVIRT_BASE_FIELDS_SCRIPT" ]; then
  echo "Error: $SET_LIBVIRT_BASE_FIELDS_SCRIPT not found." >&2
  exit 1
fi

if [ ! -f "$SET_LIBVIRT_HWE_FIELDS_SCRIPT" ]; then
  echo "Error: $SET_LIBVIRT_HWE_FIELDS_SCRIPT not found." >&2
  exit 1
fi

echo "Pulling+unpacking libvirt controls with: $(basename "$PULL_LIBVIRT_SCRIPT") --version '$LIBVIRT_VERSION' --unpack"
"$PULL_LIBVIRT_SCRIPT" --version "$LIBVIRT_VERSION" --output-dir "$SCRIPT_DIR" --extract-dir "$EXTRACTED_DIR" --unpack

echo "Applying base libvirt variant fields with: $(basename "$SET_LIBVIRT_BASE_FIELDS_SCRIPT")"
"$SET_LIBVIRT_BASE_FIELDS_SCRIPT" --root-dir "$EXTRACTED_DIR"

echo "Applying hwe libvirt variant fields with: $(basename "$SET_LIBVIRT_HWE_FIELDS_SCRIPT")"
"$SET_LIBVIRT_HWE_FIELDS_SCRIPT" --root-dir "$EXTRACTED_DIR"

echo "Packing libvirt base+hwe .deb files with: $(basename "$PULL_LIBVIRT_SCRIPT") --version '$LIBVIRT_VERSION' --pack --extract-dir '$EXTRACTED_DIR'"
"$PULL_LIBVIRT_SCRIPT" --version "$LIBVIRT_VERSION" --pack --output-dir "$SCRIPT_DIR" --extract-dir "$EXTRACTED_DIR"

echo "Generating -hwe control folders with: $(basename "$GENERATE_HWE_SCRIPT") --clean-dst"
"$GENERATE_HWE_SCRIPT" --clean-dst

echo "Packing -hwe .deb files with: $(basename "$PACK_HWE_SCRIPT") --output-dir '$HWE_11_2_DIR'"
"$PACK_HWE_SCRIPT" --output-dir "$HWE_11_2_DIR"

echo "Deb preparation finished."
