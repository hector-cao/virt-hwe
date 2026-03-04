#!/usr/bin/env bash
set -euo pipefail

LOCAL_PPA_DIR="${LOCAL_PPA_DIR:-/workspace/local-ppa}"
LOCAL_PPA_LIST="/etc/apt/sources.list.d/local-ppa.list"

publish_local_ppa() {
	local ppa_dir="$1"
	local built_debs=()

	mapfile -t built_debs < <(find /workspace -maxdepth 1 -type f -name '*.deb' | sort)

	if [ "${#built_debs[@]}" -eq 0 ]; then
		echo "No .deb files found in /workspace. Skipping local PPA publish."
		return 0
	fi

	mkdir -p "$ppa_dir"
	chmod 755 /workspace || true
	chmod 755 "$ppa_dir"
	rm -f "$ppa_dir"/*.deb "$ppa_dir"/Packages "$ppa_dir"/Packages.gz
	cp -f "${built_debs[@]}" "$ppa_dir"/

	(
		cd "$ppa_dir"
		dpkg-scanpackages . /dev/null > Packages
		gzip -9c Packages > Packages.gz
	)

	find "$ppa_dir" -maxdepth 1 -type f -name '*.deb' -exec chmod 644 {} +
	chmod 644 "$ppa_dir"/Packages "$ppa_dir"/Packages.gz

	echo "deb [trusted=yes] file:${ppa_dir} ./" > "$LOCAL_PPA_LIST"
	apt-get -o APT::Sandbox::User=root update

	echo "Local PPA published at $ppa_dir"
	echo "Install packages with: apt-get install -y <package-name>"
}

if [ "$#" -gt 0 ] && [ "$1" != "build" ]; then
	exec "$@"
fi

publish_local_ppa "$LOCAL_PPA_DIR"
