#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
IMAGE_NAME="${IMAGE_NAME:-ubuntu-devel-run}"
CONTAINER_NAME="${CONTAINER_NAME:-ubuntu-devel-qemu}"
PULL_SCRIPT="$SCRIPT_DIR/pull_launchpad_qemu_debs.sh"
GENERATE_HWE_SCRIPT="$SCRIPT_DIR/generate_hwe_11_2_controls.sh"
PACK_HWE_SCRIPT="$SCRIPT_DIR/pack_hwe_11_2.sh"
ENTRYPOINT_SCRIPT="$SCRIPTS_DIR/entrypoint.sh"
HWE_11_2_DIR="$SCRIPT_DIR/hwe-11.2"
DEB_ARCH_REGEX="${DEB_ARCH_REGEX:-amd64|all}"
HOST_LOGS_DIR="${HOST_LOGS_DIR:-$PWD/logs}"
STAGING_DIR="${STAGING_DIR:-}"
AUTO_STAGING_DIR=0

cleanup() {
  if [ "$AUTO_STAGING_DIR" -eq 1 ] && [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    sudo rm -rf "$STAGING_DIR"
  fi
}

trap cleanup EXIT

if [ ! -d "$SCRIPTS_DIR" ]; then
  echo "Error: $SCRIPTS_DIR not found."
  exit 1
fi

if [ ! -f "$ENTRYPOINT_SCRIPT" ]; then
  echo "Error: $ENTRYPOINT_SCRIPT not found."
  exit 1
fi

if [ ! -f "$PULL_SCRIPT" ]; then
  echo "Error: $PULL_SCRIPT not found."
  exit 1
fi

if [ ! -f "$GENERATE_HWE_SCRIPT" ]; then
  echo "Error: $GENERATE_HWE_SCRIPT not found."
  exit 1
fi

if [ ! -f "$PACK_HWE_SCRIPT" ]; then
  echo "Error: $PACK_HWE_SCRIPT not found."
  exit 1
fi

if [ ! -d "$HWE_11_2_DIR" ]; then
  echo "Creating missing directory: $HWE_11_2_DIR"
  mkdir -p "$HWE_11_2_DIR"
fi

find "$SCRIPTS_DIR" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} +
chmod +x "$PULL_SCRIPT"
chmod +x "$GENERATE_HWE_SCRIPT"
chmod +x "$PACK_HWE_SCRIPT"

echo "Pulling missing .deb files with: $(basename "$PULL_SCRIPT") --arch '$DEB_ARCH_REGEX'"
"$PULL_SCRIPT" --arch "$DEB_ARCH_REGEX" --output-dir "$SCRIPT_DIR"

echo "Generating -hwe control folders with: $(basename "$GENERATE_HWE_SCRIPT") --clean-dst"
"$GENERATE_HWE_SCRIPT" --clean-dst

echo "Packing -hwe .deb files with: $(basename "$PULL_SCRIPT") --pack --arch '$DEB_ARCH_REGEX' --extract-dir '$HWE_11_2_DIR'"
"$PULL_SCRIPT" --pack --arch "$DEB_ARCH_REGEX" --output-dir "$SCRIPT_DIR" --extract-dir "$HWE_11_2_DIR"

echo "Packing -hwe .deb files with: $(basename "$PACK_HWE_SCRIPT") --arch '$DEB_ARCH_REGEX' --output-dir '$HWE_11_2_DIR'"
"$PACK_HWE_SCRIPT" --arch "$DEB_ARCH_REGEX" --output-dir "$HWE_11_2_DIR"

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
mkdir -p "$STAGING_DIR/scripts"
mkdir -p "$HOST_LOGS_DIR"

cp -a "$SCRIPTS_DIR/." "$STAGING_DIR/scripts/"
cp -a "$HWE_11_2_DIR" "$STAGING_DIR/hwe-11.2"
find "$STAGING_DIR/scripts" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} +

if [ ! -f "$STAGING_DIR/scripts/entrypoint.sh" ]; then
  echo "Error: failed to stage entrypoint.sh in $STAGING_DIR/scripts"
  exit 1
fi

if [ ! -d "$STAGING_DIR/hwe-11.2" ]; then
  echo "Error: failed to stage hwe-11.2 in $STAGING_DIR"
  exit 1
fi

if [ ! -d "$HOST_LOGS_DIR" ]; then
  echo "Error: failed to create host logs directory: $HOST_LOGS_DIR"
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
echo "Host logs directory mounted to /workspace/logs: $HOST_LOGS_DIR"

if [ -t 0 ] && [ -t 1 ]; then
  if [ "$#" -gt 0 ]; then
    docker run -it \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/scripts/entrypoint.sh \
      -v "$STAGING_DIR:/workspace" \
      -v "$HOST_LOGS_DIR:/workspace/logs" \
      "$IMAGE_NAME" \
      "$@"
  else
    docker run -it \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/scripts/entrypoint.sh \
      -v "$STAGING_DIR:/workspace" \
      -v "$HOST_LOGS_DIR:/workspace/logs" \
      "$IMAGE_NAME"
  fi
else
  if [ "$#" -gt 0 ]; then
    docker run \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/scripts/entrypoint.sh \
      -v "$STAGING_DIR:/workspace" \
      -v "$HOST_LOGS_DIR:/workspace/logs" \
      "$IMAGE_NAME" \
      "$@"
  else
    docker run \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/scripts/entrypoint.sh \
      -v "$STAGING_DIR:/workspace" \
      -v "$HOST_LOGS_DIR:/workspace/logs" \
      "$IMAGE_NAME"
  fi
fi
