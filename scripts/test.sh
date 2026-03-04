#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mapfile -t check_scripts < <(
  find "$SCRIPT_DIR" -maxdepth 1 -type f -name 'check*.sh' \
    ! -name 'test.sh' \
    -printf '%f\n' \
    | sort
)

if [ "${#check_scripts[@]}" -eq 0 ]; then
  echo "No check scripts found in $SCRIPT_DIR"
  exit 1
fi

echo "Running check scripts in order:"
for script_name in "${check_scripts[@]}"; do
  echo "  - $script_name"
done

for script_name in "${check_scripts[@]}"; do
  echo
  echo "=== Running $script_name ==="
  bash "$SCRIPT_DIR/$script_name"
done

echo
echo "All check scripts completed successfully."
