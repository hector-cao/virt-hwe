#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR=""
LOCAL_PPA_DIR="${LOCAL_PPA_DIR:-$SCRIPT_DIR/local-ppa}"
LOCAL_PPA_LIST="${LOCAL_PPA_LIST:-/etc/apt/sources.list.d/local-ppa.list}"
SKIP_APT_UPDATE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [SOURCE_DIR] [--source-dir DIR] [--ppa-dir DIR] [--ppa-list FILE] [--skip-apt-update]

Updates a local file-based PPA using .deb files from a source folder.

Arguments:
  SOURCE_DIR            Directory containing .deb files

Options:
  --source-dir DIR      Directory containing .deb files (same as positional SOURCE_DIR)
  --ppa-dir DIR         Local PPA publish directory (default: ./local-ppa)
  --ppa-list FILE       apt source list file (default: /etc/apt/sources.list.d/local-ppa.list)
  --skip-apt-update     Do not write apt source or run apt-get update
  -h, --help            Show this help

Environment variables:
  LOCAL_PPA_DIR, LOCAL_PPA_LIST
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-dir)
      SOURCE_DIR="$2"
      shift 2
      ;;
    --ppa-dir)
      LOCAL_PPA_DIR="$2"
      shift 2
      ;;
    --ppa-list)
      LOCAL_PPA_LIST="$2"
      shift 2
      ;;
    --skip-apt-update)
      SKIP_APT_UPDATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ -n "$SOURCE_DIR" ]; then
        echo "Error: multiple source directories provided." >&2
        usage >&2
        exit 1
      fi
      SOURCE_DIR="$1"
      shift
      ;;
  esac
done

if [ -z "$SOURCE_DIR" ]; then
  echo "Error: SOURCE_DIR is required." >&2
  usage >&2
  exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: source dir not found: $SOURCE_DIR" >&2
  exit 1
fi

if ! command -v dpkg-scanpackages >/dev/null 2>&1; then
  echo "Error: dpkg-scanpackages is required." >&2
  exit 1
fi

if ! command -v gzip >/dev/null 2>&1; then
  echo "Error: gzip is required." >&2
  exit 1
fi

mapfile -t built_debs < <(find "$SOURCE_DIR" -maxdepth 1 -type f -name '*.deb' | sort)

if [ "${#built_debs[@]}" -eq 0 ]; then
  echo "Error: no .deb files found in $SOURCE_DIR" >&2
  exit 1
fi

mkdir -p "$LOCAL_PPA_DIR"
chmod 755 "$LOCAL_PPA_DIR" || true
rm -f "$LOCAL_PPA_DIR"/*.deb "$LOCAL_PPA_DIR"/Packages "$LOCAL_PPA_DIR"/Packages.gz
cp -f "${built_debs[@]}" "$LOCAL_PPA_DIR"/

(
  cd "$LOCAL_PPA_DIR"
  dpkg-scanpackages . /dev/null > Packages
  gzip -9c Packages > Packages.gz
)

find "$LOCAL_PPA_DIR" -maxdepth 1 -type f -name '*.deb' -exec chmod 644 {} +
chmod 644 "$LOCAL_PPA_DIR"/Packages "$LOCAL_PPA_DIR"/Packages.gz

echo "Local PPA files updated at: $LOCAL_PPA_DIR"
echo "Indexed packages: ${#built_debs[@]}"

if [ "$SKIP_APT_UPDATE" -eq 1 ]; then
  echo "Skipped apt source update (--skip-apt-update)."
  exit 0
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "Warning: apt-get not found. Skipping apt source update."
  exit 0
fi

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Error: root privileges required to write $LOCAL_PPA_LIST and run apt-get update." >&2
    echo "Run as root or use --skip-apt-update." >&2
    exit 1
  fi
  echo "deb [trusted=yes] file:${LOCAL_PPA_DIR} ./" | sudo tee "$LOCAL_PPA_LIST" >/dev/null
  sudo apt-get -o APT::Sandbox::User=root update
else
  echo "deb [trusted=yes] file:${LOCAL_PPA_DIR} ./" > "$LOCAL_PPA_LIST"
  apt-get -o APT::Sandbox::User=root update
fi

echo "apt source list updated: $LOCAL_PPA_LIST"
echo "Install packages with: apt-get install -y <package-name>"
