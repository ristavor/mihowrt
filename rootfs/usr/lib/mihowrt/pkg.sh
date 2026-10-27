#!/bin/ash

# Read names directly: no package-manager process or per-package queries.
pkg_installed_names() {
	if [ -f /lib/apk/db/installed ]; then
		awk '/^P:/ { print substr($0, 3) }' /lib/apk/db/installed
	elif [ -f /usr/lib/opkg/status ]; then
		# opkg keeps records like "Status: deinstall ok not-installed"; list only installed ones.
		awk '/^Package: / { name = substr($0, 10) } /^Status: .* installed$/ { print name }' /usr/lib/opkg/status
	fi
}
