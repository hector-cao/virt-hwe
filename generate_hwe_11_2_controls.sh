#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="${SRC_ROOT:-$SCRIPT_DIR/extracted}"
DST_ROOT="${DST_ROOT:-$SCRIPT_DIR/hwe-11.2}"
OLD_VERSION="${OLD_VERSION:-10.2.1+ds-1ubuntu1}"
NEW_VERSION="${NEW_VERSION:-11.2.1+ds-0ubuntu1}"
CLEAN_DST=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--src-root DIR] [--dst-root DIR] [--old-version VER] [--new-version VER] [--clean-dst]

Generate -hwe package control folders in destination from extracted folders.

Behavior:
  - Copies extracted/*-hwe/*/control -> <dst-root>/*-hwe/*/control
  - Rewrites Version and internal version references from old to new version

Options:
  --src-root DIR       Source extracted root (default: ./extracted)
  --dst-root DIR       Destination root (default: ./hwe-11.2)
  --old-version VER    Old version without epoch (default: 10.2.1+ds-1ubuntu1)
  --new-version VER    New version without epoch (default: 11.2.1+ds-0ubuntu1)
  --clean-dst          Remove destination root before generating
  -h, --help           Show this help

Environment variables:
  SRC_ROOT, DST_ROOT, OLD_VERSION, NEW_VERSION
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --src-root)
      SRC_ROOT="$2"
      shift 2
      ;;
    --dst-root)
      DST_ROOT="$2"
      shift 2
      ;;
    --old-version)
      OLD_VERSION="$2"
      shift 2
      ;;
    --new-version)
      NEW_VERSION="$2"
      shift 2
      ;;
    --clean-dst)
      CLEAN_DST=1
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

if [ ! -d "$SRC_ROOT" ]; then
  echo "Error: source root not found: $SRC_ROOT" >&2
  exit 1
fi

if [ "$CLEAN_DST" -eq 1 ]; then
  rm -rf "$DST_ROOT"
fi

mkdir -p "$DST_ROOT"

python3 - "$SRC_ROOT" "$DST_ROOT" "$OLD_VERSION" "$NEW_VERSION" <<'PY'
from pathlib import Path
import re
import shutil
import sys

src_root = Path(sys.argv[1])
dst_root = Path(sys.argv[2])
old_version = sys.argv[3]
new_version = sys.argv[4]

old_epoch = f"1:{old_version}"
new_epoch = f"1:{new_version}"
old_tilde = f"1:{old_version.split('-', 1)[0]}~"
new_tilde = f"1:{new_version.split('-', 1)[0]}~"

control_dirs = sorted(src_root.glob("*-hwe/*/control"))
if not control_dirs:
    print(f"No -hwe control folders found under: {src_root}")
    sys.exit(1)

copied = 0
for control_dir in control_dirs:
    rel = control_dir.relative_to(src_root)
    target = dst_root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(control_dir, target)
    copied += 1

updated = 0
for control_file in sorted(dst_root.glob("*-hwe/*/control/control")):
    original = control_file.read_text(encoding="utf-8")
    rewritten = original

    rewritten = re.sub(r"(?m)^Version:\s*.*$", f"Version: {new_epoch}", rewritten, count=1)
    rewritten = rewritten.replace(old_tilde, new_tilde)
    rewritten = rewritten.replace(old_epoch, new_epoch)
    rewritten = rewritten.replace(old_version, new_version)

    if rewritten != original:
        control_file.write_text(rewritten, encoding="utf-8")
        updated += 1

print(f"Copied control folders: {copied}")
print(f"Updated control files: {updated}")
print(f"Destination root: {dst_root}")
PY

echo "Done. Generated -hwe control folders in: $DST_ROOT"
