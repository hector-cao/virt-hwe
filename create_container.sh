#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-ubuntu-devel-run}"
CONTAINER_NAME="${CONTAINER_NAME:-ubuntu-devel-qemu}"
PULL_SCRIPT="$SCRIPT_DIR/pull_launchpad_qemu_debs.sh"
CHECK_SCRIPT="$SCRIPT_DIR/check.sh"
CHECK_UPGRADE_SCRIPT="$SCRIPT_DIR/check-upgrade.sh"
PPA_UPDATE_SCRIPT="$SCRIPT_DIR/update_local_ppa_from_dir.sh"
HWE_11_2_DIR="$SCRIPT_DIR/hwe-11.2"
DEB_ARCH_REGEX="${DEB_ARCH_REGEX:-amd64|all}"
STAGING_DIR="${STAGING_DIR:-}"
AUTO_STAGING_DIR=0

cleanup() {
  if [ "$AUTO_STAGING_DIR" -eq 1 ] && [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    sudo rm -rf "$STAGING_DIR"
  fi
}

trap cleanup EXIT

if [ ! -f "$SCRIPT_DIR/run.sh" ]; then
  echo "Error: $SCRIPT_DIR/run.sh not found."
  exit 1
fi

if [ ! -f "$PULL_SCRIPT" ]; then
  echo "Error: $PULL_SCRIPT not found."
  exit 1
fi

if [ ! -f "$CHECK_SCRIPT" ]; then
  echo "Error: $CHECK_SCRIPT not found."
  exit 1
fi

if [ ! -f "$CHECK_UPGRADE_SCRIPT" ]; then
  echo "Error: $CHECK_UPGRADE_SCRIPT not found."
  exit 1
fi

if [ ! -f "$PPA_UPDATE_SCRIPT" ]; then
  echo "Error: $PPA_UPDATE_SCRIPT not found."
  exit 1
fi

if [ ! -d "$HWE_11_2_DIR" ]; then
  echo "Error: $HWE_11_2_DIR not found."
  exit 1
fi

chmod +x "$SCRIPT_DIR/run.sh"
chmod +x "$PULL_SCRIPT"
chmod +x "$CHECK_SCRIPT"
chmod +x "$CHECK_UPGRADE_SCRIPT"
chmod +x "$PPA_UPDATE_SCRIPT"

echo "Pulling missing .deb files with: $(basename "$PULL_SCRIPT") --arch '$DEB_ARCH_REGEX'"
"$PULL_SCRIPT" --arch "$DEB_ARCH_REGEX" --output-dir "$SCRIPT_DIR"

echo "Packing .deb files with: $(basename "$PULL_SCRIPT") --pack --arch '$DEB_ARCH_REGEX'"
"$PULL_SCRIPT" --pack --arch "$DEB_ARCH_REGEX" --output-dir "$SCRIPT_DIR"

if [ "$STAGING_DIR" = "/" ]; then
  echo "Error: STAGING_DIR cannot be /."
  exit 1
fi

if [ -z "$STAGING_DIR" ]; then
  STAGING_DIR="$(mktemp -d "/tmp/${CONTAINER_NAME}-workspace.XXXXXX")"
  AUTO_STAGING_DIR=1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

cp -f "$SCRIPT_DIR/run.sh" "$STAGING_DIR/run.sh"
cp -f "$CHECK_SCRIPT" "$STAGING_DIR/check.sh"
cp -f "$CHECK_UPGRADE_SCRIPT" "$STAGING_DIR/check-upgrade.sh"
cp -f "$PPA_UPDATE_SCRIPT" "$STAGING_DIR/update_local_ppa_from_dir.sh"
cp -a "$HWE_11_2_DIR" "$STAGING_DIR/hwe-11.2"
chmod +x "$STAGING_DIR/run.sh"
chmod +x "$STAGING_DIR/check.sh"
chmod +x "$STAGING_DIR/check-upgrade.sh"
chmod +x "$STAGING_DIR/update_local_ppa_from_dir.sh"

if [ ! -f "$STAGING_DIR/check.sh" ]; then
  echo "Error: failed to stage check.sh in $STAGING_DIR"
  exit 1
fi

if [ ! -f "$STAGING_DIR/check-upgrade.sh" ]; then
  echo "Error: failed to stage check-upgrade.sh in $STAGING_DIR"
  exit 1
fi

if [ ! -f "$STAGING_DIR/update_local_ppa_from_dir.sh" ]; then
  echo "Error: failed to stage update_local_ppa_from_dir.sh in $STAGING_DIR"
  exit 1
fi

if [ ! -d "$STAGING_DIR/hwe-11.2" ]; then
  echo "Error: failed to stage hwe-11.2 in $STAGING_DIR"
  exit 1
fi

mapfile -t built_debs < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.deb' | sort)
if [ "${#built_debs[@]}" -eq 0 ]; then
  echo "Warning: no .deb files found in $SCRIPT_DIR after packing."
else
  cp -f "${built_debs[@]}" "$STAGING_DIR/"
  echo "Staged .deb files: ${#built_debs[@]}"
fi

if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "Image '$IMAGE_NAME' not found. Building it from Dockerfile..."
  docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "Container '$CONTAINER_NAME' already exists. Removing it..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

echo "Starting container '$CONTAINER_NAME' with /workspace mounted from $STAGING_DIR..."

if [ -t 0 ] && [ -t 1 ]; then
  if [ "$#" -gt 0 ]; then
    docker run -it \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/run.sh \
      -v "$STAGING_DIR:/workspace" \
      "$IMAGE_NAME" \
      "$@"
  else
    docker run -it \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/run.sh \
      -v "$STAGING_DIR:/workspace" \
      "$IMAGE_NAME"
  fi
else
  if [ "$#" -gt 0 ]; then
    docker run \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/run.sh \
      -v "$STAGING_DIR:/workspace" \
      "$IMAGE_NAME" \
      "$@"
  else
    docker run \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/run.sh \
      -v "$STAGING_DIR:/workspace" \
      "$IMAGE_NAME"
  fi
fi
