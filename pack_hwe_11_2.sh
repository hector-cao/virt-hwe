#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULL_SCRIPT="$SCRIPT_DIR/pull_launchpad_qemu_debs.sh"
EXTRACT_DIR="${EXTRACT_DIR:-$SCRIPT_DIR/hwe-11.2}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/hwe-11.2}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR}"
SOURCE_VERSION="${SOURCE_VERSION:-10.2.1+ds-1ubuntu1}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--extract-dir DIR] [--output-dir DIR] [--source-version VER]

Pack -hwe packages from hwe-11.2 control trees and emit deb files named with
that copied control Version (e.g. 11.2.1+ds-0ubuntu1).

Options:
  --extract-dir DIR    Control root to pack from (default: ./hwe-11.2)
  --output-dir DIR     Destination directory for packed .deb files (default: ./hwe-11.2)
  --work-dir DIR       Working directory containing source debs for packing
                       (default: workspace root)
  --source-version VER Source .deb version used to read data.tar/debian-binary
                       (default: 10.2.1+ds-1ubuntu1)
  -h, --help           Show this help

Environment variables:
  EXTRACT_DIR, OUTPUT_DIR, WORK_DIR, SOURCE_VERSION
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --extract-dir)
      EXTRACT_DIR="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    --source-version)
      SOURCE_VERSION="$2"
      shift 2
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

if [ ! -f "$PULL_SCRIPT" ]; then
  echo "Error: missing pull script: $PULL_SCRIPT" >&2
  exit 1
fi

if [ ! -d "$EXTRACT_DIR" ]; then
  echo "Error: extract dir not found: $EXTRACT_DIR" >&2
  exit 1
fi

if [ ! -d "$WORK_DIR" ]; then
  echo "Error: work dir not found: $WORK_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Packing from $EXTRACT_DIR using source version $SOURCE_VERSION (source deb dir: $WORK_DIR, output dir: $OUTPUT_DIR)"
SOURCE_DEB_DIR="$WORK_DIR" VERSION="$SOURCE_VERSION" "$PULL_SCRIPT" --pack --output-dir "$OUTPUT_DIR" --extract-dir "$EXTRACT_DIR"

echo "Done. Packed files are in: $OUTPUT_DIR"
