#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-./extracted}"
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--root-dir DIR] [--dry-run]

Updates extracted Debian control files to ensure:
  - base packages provide: virt
  - -hwe packages provide: virt-hwe

Options:
  --root-dir DIR  Root extraction directory (default: ./extracted)
  --dry-run       Show planned changes without writing files
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

field_pattern = re.compile(r"(?m)^(Provides):([^\n]*(?:\n[ \t].*)*)")


def split_items(value: str):
    parts = [p.strip() for p in value.split(",")]
    return [p for p in parts if p]


def merge_item(existing_value: str, new_item: str) -> str:
    items = split_items(existing_value)
    if new_item not in items:
        items.append(new_item)
    return ", ".join(items)


scanned = 0
updated = 0

for control_file in sorted(root.glob("*/ */control/control".replace(" ", ""))):
    scanned += 1
    package_name = control_file.parts[-4]
    provides_item = "virt-hwe" if package_name.endswith("-hwe") else "virt"

    original = control_file.read_text(encoding="utf-8")

    found_provides = [False]

    def rewrite_provides(match):
        found_provides[0] = True
        field_name = match.group(1)
        block_value = match.group(2)

        lines = block_value.splitlines()
        if lines:
            lines[0] = lines[0].lstrip()
        normalized = " ".join(line.strip() for line in lines)
        merged = merge_item(normalized, provides_item)
        return f"{field_name}: {merged}"

    rewritten = field_pattern.sub(rewrite_provides, original)

    if not found_provides[0]:
        insert_re = re.compile(r"(?m)^Section:[^\n]*$")
        match = insert_re.search(rewritten)
        if match:
            start = match.start()
            rewritten = rewritten[:start] + f"Provides: {provides_item}\n" + rewritten[start:]
        else:
            if not rewritten.endswith("\n"):
                rewritten += "\n"
            rewritten += f"Provides: {provides_item}\n"

    if rewritten != original:
        updated += 1
        if dry_run:
            print(f"Would update: {control_file} -> Provides: {provides_item}")
        else:
            control_file.write_text(rewritten, encoding="utf-8")
            print(f"Updated: {control_file} -> Provides: {provides_item}")

print(f"Scanned control files: {scanned}")
print(f"Updated control files: {updated}")
PY
