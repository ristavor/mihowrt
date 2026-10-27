#!/bin/ash

# Read names directly: no package-manager process or per-package queries.
pkg_installed_names() {
	if [ -f /lib/apk/db/installed ]; then
		awk '/^P:/ { print substr($0, 3) }' /lib/apk/db/installed
	elif [ -f /usr/lib/opkg/status ]; then
		awk '/^Package: / { print substr($0, 10) }' /usr/lib/opkg/status
	fi
}
