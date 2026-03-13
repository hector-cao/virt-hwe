#!/usr/bin/env bash
set -euo pipefail

LOCAL_PPA_DIR="${LOCAL_PPA_DIR:-/workspace/local-ppa}"
DEB_SOURCE_DIR="${DEB_SOURCE_DIR:-/workspace}"
LOCAL_PPA_LIST="/etc/apt/sources.list.d/local-ppa.list"

publish_local_ppa() {
	local ppa_dir="$1"
	local deb_source_dir="$2"
	local built_debs=()

	if [ ! -d "$deb_source_dir" ]; then
		echo "Deb source directory '$deb_source_dir' does not exist."
		return 1
	fi

	mapfile -t built_debs < <(find "$deb_source_dir" -maxdepth 1 -type f -name '*.deb' | sort)

	if [ "${#built_debs[@]}" -eq 0 ]; then
		echo "No .deb files found in $deb_source_dir. Skipping local PPA publish."
		return 0
	fi

	# clean up any existing debs in local PPA dir to avoid confusion with old packages
	rm -f "$ppa_dir"/* || true

	mkdir -p "$ppa_dir"
	chmod 755 "$deb_source_dir" || true
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

if [ "$#" -gt 0 ] && [ "$1" = "build" ]; then
	shift
	if [ "$#" -gt 0 ]; then
		DEB_SOURCE_DIR="$1"
	fi
fi

publish_local_ppa "$LOCAL_PPA_DIR" "$DEB_SOURCE_DIR"

#cp scripts/99-ubuntu-virt.conf /etc/apt/apt.conf.d/
cp scripts/apt_hook_ubuntu_virt.sh /usr/local/sbin/