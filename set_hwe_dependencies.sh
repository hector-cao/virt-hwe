#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-./extracted}"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--root-dir DIR] [--dry-run]

For all -hwe package control files under <root-dir>, update dependency fields
to reference -hwe package counterparts for known QEMU package names.

Updated fields:
  Pre-Depends, Depends, Recommends, Suggests, Enhances

Options:
  --root-dir DIR  Root extraction directory (default: ./extracted)
  --dry-run       Show what would change, without writing files
  -h, --help      Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root-dir)
      ROOT_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

if [ ! -d "$ROOT_DIR" ]; then
  echo "Error: root directory not found: $ROOT_DIR" >&2
  exit 1
fi

python3 - "$ROOT_DIR" "$DRY_RUN" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
dry_run = sys.argv[2] == "1"

packages = [
    "qemu-block-extra",
    "qemu-block-supplemental",
    "qemu-guest-agent",
    "qemu-system",
    "qemu-system-arm",
    "qemu-system-common",
    "qemu-system-data",
    "qemu-system-gui",
    "qemu-system-mips",
    "qemu-system-misc",
    "qemu-system-modules-opengl",
    "qemu-system-modules-spice",
    "qemu-system-ppc",
    "qemu-system-riscv",
    "qemu-system-s390x",
    "qemu-system-sparc",
    "qemu-system-x86",
    "qemu-system-x86-xen",
    "qemu-system-xen",
    "qemu-user",
    "qemu-user-binfmt",
    "qemu-utils",
]

token_char_class = r"[a-z0-9+.-]"
replacement_patterns = [
    (re.compile(rf"(?<!{token_char_class}){re.escape(pkg)}(?!{token_char_class})"), f"{pkg}-hwe")
    for pkg in packages
]

field_pattern = re.compile(
    r"(?m)^(Pre-Depends|Depends|Recommends|Suggests|Enhances):([^\n]*(?:\n[ \t].*)*)"
)

scanned = 0
updated = 0

for control_file in sorted(root.glob("*-hwe/*/control/control")):
    scanned += 1
    original = control_file.read_text(encoding="utf-8")

    def rewrite_field(match: re.Match[str]) -> str:
        field_name = match.group(1)
        block_value = match.group(2)

        lines = block_value.splitlines()
        if lines:
            lines[0] = lines[0].lstrip()
        normalized = " ".join(line.strip() for line in lines)

        rewritten = normalized
        for pattern, replacement in replacement_patterns:
            rewritten = pattern.sub(replacement, rewritten)

        if rewritten == normalized:
            return match.group(0)

        return f"{field_name}: {rewritten}"

    rewritten_text = field_pattern.sub(rewrite_field, original)

    if rewritten_text == original:
        continue

    updated += 1
    if dry_run:
        print(f"Would update: {control_file}")
    else:
        control_file.write_text(rewritten_text, encoding="utf-8")
        print(f"Updated: {control_file}")

print(f"Scanned control files: {scanned}")
print(f"Updated control files: {updated}")
PY
