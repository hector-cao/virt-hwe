#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULL_SCRIPT="$SCRIPT_DIR/pull_launchpad_qemu_debs.sh"
EXTRACT_DIR="${EXTRACT_DIR:-$SCRIPT_DIR/hwe-11.2}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/hwe-11.2}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR}"
SOURCE_VERSION="${SOURCE_VERSION:-10.2.1+ds-1ubuntu1}"
ARCH_REGEX="${ARCH_REGEX:-amd64|all}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--extract-dir DIR] [--output-dir DIR] [--source-version VER] [--arch REGEX]

Pack -hwe packages from hwe-11.2 control trees and emit deb files named with
that copied control Version (e.g. 11.2.1+ds-0ubuntu1).

Options:
  --extract-dir DIR    Control root to pack from (default: ./hwe-11.2)
  --output-dir DIR     Destination directory for packed .deb files (default: ./hwe-11.2)
  --work-dir DIR       Working directory containing source debs for packing
                       (default: workspace root)
  --source-version VER Source .deb version used to read data.tar/debian-binary
                       (default: 10.2.1+ds-1ubuntu1)
  --arch REGEX         Architecture filter regex (default: amd64|all)
  -h, --help           Show this help

Environment variables:
  EXTRACT_DIR, OUTPUT_DIR, WORK_DIR, SOURCE_VERSION, ARCH_REGEX
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
    --arch)
      ARCH_REGEX="$2"
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

echo "Packing from $EXTRACT_DIR using source version $SOURCE_VERSION (work dir: $WORK_DIR)"
VERSION="$SOURCE_VERSION" "$PULL_SCRIPT" --pack --arch "$ARCH_REGEX" --output-dir "$WORK_DIR" --extract-dir "$EXTRACT_DIR"

echo "Renaming and moving packed -hwe debs to $OUTPUT_DIR"
python3 - "$EXTRACT_DIR" "$WORK_DIR" "$OUTPUT_DIR" "$SOURCE_VERSION" <<'PY'
import pathlib
import re
import sys

extract_dir = pathlib.Path(sys.argv[1])
work_dir = pathlib.Path(sys.argv[2])
output_dir = pathlib.Path(sys.argv[3])
source_version = sys.argv[4]

updated = 0
output_dir.mkdir(parents=True, exist_ok=True)

for control_file in sorted(extract_dir.glob("*-hwe/*/control/control")):
    text = control_file.read_text(encoding="utf-8")

    pkg_match = re.search(r"(?m)^Package:\s*(\S+)\s*$", text)
    ver_match = re.search(r"(?m)^Version:\s*(\S+)\s*$", text)
    if not pkg_match or not ver_match:
        continue

    package = pkg_match.group(1)
    full_version = ver_match.group(1)
    deb_version = full_version.split(":", 1)[1] if ":" in full_version else full_version

    arch = control_file.parts[-3]
    src = work_dir / f"{package}_{source_version}_{arch}.deb"
    dst = output_dir / f"{package}_{deb_version}_{arch}.deb"

    if src.exists() and src != dst:
        if dst.exists():
            dst.unlink()
        src.rename(dst)
        updated += 1
        print(f"Renamed: {src.name} -> {dst.name}")

print(f"Renamed files: {updated}")
PY

echo "Done. Packed files are in: $OUTPUT_DIR"
