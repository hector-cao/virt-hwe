#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

bash "$SCRIPT_DIR/setup.sh"
bash "$SCRIPT_DIR/test.sh"
