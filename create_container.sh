#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-ubuntu-devel-run}"
CONTAINER_NAME="${CONTAINER_NAME:-ubuntu-devel-qemu}"

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is required to clone repositories."
  echo "Install it and re-run (e.g. sudo apt-get install -y git)."
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/run.sh" ]; then
  echo "Error: $SCRIPT_DIR/run.sh not found."
  exit 1
fi

chmod +x "$SCRIPT_DIR/run.sh"

ensure_repo() {
  local repo_url="$1"
  local branch="$2"
  local destination="$3"

  if [ -d "$destination" ]; then
    echo "Skipping clone/fetch for $(basename "$destination") (folder already exists)."
    return 0
  fi

  echo "Cloning $(basename "$destination") (branch '$branch')..."
  git clone --branch "$branch" --single-branch "$repo_url" "$destination"
}

ensure_repo "https://git.launchpad.net/~hectorcao/ubuntu/+source/qemu" "hwe-experiment" "$SCRIPT_DIR/qemu"
ensure_repo "https://git.launchpad.net/~hectorcao/ubuntu/+source/qemu" "hwe-experiment-hwe" "$SCRIPT_DIR/qemu-hwe"

if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  echo "Image '$IMAGE_NAME' not found. Building it from Dockerfile..."
  docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "Container '$CONTAINER_NAME' already exists. Removing it..."
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

echo "Starting container '$CONTAINER_NAME' with mounted folders..."

if [ -t 0 ] && [ -t 1 ]; then
  if [ "$#" -gt 0 ]; then
    docker run -it \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/run.sh \
      -v "$SCRIPT_DIR/run.sh:/workspace/run.sh:ro" \
        -v "$SCRIPT_DIR/qemu:/workspace/qemu" \
        -v "$SCRIPT_DIR/qemu-hwe:/workspace/qemu-hwe" \
      --mount type=tmpfs,destination=/workspace/qemu/.git \
      --mount type=tmpfs,destination=/workspace/qemu-hwe/.git \
      "$IMAGE_NAME" \
      "$@"
  else
    docker run -it \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/run.sh \
      -v "$SCRIPT_DIR/run.sh:/workspace/run.sh:ro" \
      -v "$SCRIPT_DIR/qemu:/workspace/qemu" \
      -v "$SCRIPT_DIR/qemu-hwe:/workspace/qemu-hwe" \
      --mount type=tmpfs,destination=/workspace/qemu/.git \
      --mount type=tmpfs,destination=/workspace/qemu-hwe/.git \
      "$IMAGE_NAME"
  fi
else
  if [ "$#" -gt 0 ]; then
    docker run \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/run.sh \
      -v "$SCRIPT_DIR/run.sh:/workspace/run.sh:ro" \
        -v "$SCRIPT_DIR/qemu:/workspace/qemu" \
        -v "$SCRIPT_DIR/qemu-hwe:/workspace/qemu-hwe" \
      --mount type=tmpfs,destination=/workspace/qemu/.git \
      --mount type=tmpfs,destination=/workspace/qemu-hwe/.git \
      "$IMAGE_NAME" \
      "$@"
  else
    docker run \
      --name "$CONTAINER_NAME" \
      --entrypoint /workspace/run.sh \
      -v "$SCRIPT_DIR/run.sh:/workspace/run.sh:ro" \
      -v "$SCRIPT_DIR/qemu:/workspace/qemu" \
      -v "$SCRIPT_DIR/qemu-hwe:/workspace/qemu-hwe" \
      --mount type=tmpfs,destination=/workspace/qemu/.git \
      --mount type=tmpfs,destination=/workspace/qemu-hwe/.git \
      "$IMAGE_NAME"
  fi
fi
