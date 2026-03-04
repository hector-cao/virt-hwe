#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0")

Checks whether virtual package virt or virt-hwe is present on the system,
either by direct package installation or by an installed package that Provides
virt/virt-hwe.

Exit codes:
  0  Found at least one provider for virt/virt-hwe
  1  No provider found
  2  Tooling/usage error
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
      exit 2
      ;;
  esac
done

if ! command -v dpkg-query >/dev/null 2>&1; then
  echo "Error: dpkg-query is required." >&2
  exit 2
fi

result="$(python3 <<'PY'
import subprocess
import sys

cmd = ["dpkg-query", "-W", "-f=${binary:Package}\t${db:Status-Status}\t${Provides}\n"]
proc = subprocess.run(cmd, text=True, capture_output=True)
if proc.returncode != 0:
    print("Error: failed to query dpkg database.", file=sys.stderr)
    sys.exit(2)

found = []
seen = set()

for line in proc.stdout.splitlines():
    parts = line.split("\t", 2)
    if len(parts) != 3:
        continue

    package, status, provides = parts
    if status != "installed":
        continue

    if package in {"virt", "virt-hwe"}:
        key = (package, package)
        if key not in seen:
            seen.add(key)
            found.append(key)

    if not provides:
        continue

    for item in provides.split(","):
        token = item.strip().split(" ", 1)[0]
        if token in {"virt", "virt-hwe"}:
            key = (package, token)
            if key not in seen:
                seen.add(key)
                found.append(key)

if not found:
    print("NONE")
    sys.exit(1)

for pkg, provided in sorted(found):
    print(f"{pkg}\t{provided}")
PY
)" || {
  status=$?
  if [ "$status" -eq 1 ]; then
    echo "No installed package provides virt or virt-hwe."
    exit 1
  fi
  exit "$status"
}

echo "Found installed virt/virt-hwe provider(s):"
while IFS=$'\t' read -r pkg provided; do
  [ -n "$pkg" ] || continue
  echo "  - $pkg (provides: $provided)"
done <<< "$result"

exit 0
