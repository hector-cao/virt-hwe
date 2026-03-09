#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[1/6] Populating local apt repo from /.deb files (if present)"
LOCAL_DEB_DIR="$PWD"

echo "[2/6] Adding PPA: ppa:hectorcao/testppa1"
add-apt-repository -y ppa:hectorcao/testppa1

echo "[3/6] Installing test-package-p2-hwe"
apt-get update
apt-get install -y --no-install-recommends test-package-p2-hwe

echo "[4/6] Running apt upgrade"
apt-get upgrade -y

echo "[5/6] Preparing release upgrader config"
if [ -f /etc/update-manager/release-upgrades ]; then
    sed -i 's/^Prompt=.*/Prompt=normal/' /etc/update-manager/release-upgrades
fi

echo "[6/6] Running do-release-upgrade to Questing"
do-release-upgrade -f DistUpgradeViewNonInteractive
