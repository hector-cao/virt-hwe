#!/usr/bin/env bash
set -euo pipefail

LOCAL_PPA_DIR="${LOCAL_PPA_DIR:-/workspace/local-ppa}"
LOCAL_PPA_LIST="/etc/apt/sources.list.d/local-ppa.list"

build_repo() {
	local repo_path="$1"

	if [ ! -d "$repo_path" ]; then
		echo "Skipping $repo_path (directory not found)."
		return 0
	fi

	if [ ! -d "$repo_path/debian" ]; then
		echo "Skipping $repo_path (no debian/ directory)."
		return 0
	fi

	echo "Building Debian packages in $repo_path"
	cd "$repo_path"
	dpkg-buildpackage -us -uc -b
}

publish_local_ppa() {
	local ppa_dir="$1"
	local built_debs=()

	mapfile -t built_debs < <(find /workspace -maxdepth 1 -type f -name '*.deb' | sort)

	if [ "${#built_debs[@]}" -eq 0 ]; then
		echo "No .deb files found in /workspace. Skipping local PPA publish."
		return 0
	fi

	mkdir -p "$ppa_dir"
	rm -f "$ppa_dir"/*.deb "$ppa_dir"/Packages "$ppa_dir"/Packages.gz
	cp -f "${built_debs[@]}" "$ppa_dir"/

	(
		cd "$ppa_dir"
		dpkg-scanpackages . /dev/null > Packages
		gzip -9c Packages > Packages.gz
	)

	echo "deb [trusted=yes] file:${ppa_dir} ./" > "$LOCAL_PPA_LIST"
	apt-get update

	echo "Local PPA published at $ppa_dir"
	echo "Install packages with: apt-get install -y <package-name>"
}

if [ "$#" -gt 0 ] && [ "$1" != "build" ]; then
	exec "$@"
fi

build_repo "/workspace/qemu"
build_repo "/workspace/qemu-hwe"
publish_local_ppa "$LOCAL_PPA_DIR"
