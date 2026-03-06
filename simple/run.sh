#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[1/5] Adding PPA: ppa:hectorcao/testppa1"
add-apt-repository -y ppa:hectorcao/testppa1

echo "[2/5] Installing test-package-p1-hwe and test-package-p2-hwe"
apt-get update
apt-get install -y --no-install-recommends test-package-p1-hwe test-package-p2-hwe

echo "[3/5] Running apt upgrade"
apt-get upgrade -y

echo "[4/5] Preparing release upgrader config"
if [ -f /etc/update-manager/release-upgrades ]; then
    sed -i 's/^Prompt=.*/Prompt=normal/' /etc/update-manager/release-upgrades
fi

echo "[5/5] Running do-release-upgrade to Questing"
do-release-upgrade -f DistUpgradeViewNonInteractive -m server -d
