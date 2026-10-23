#!/bin/ash

# Upgrade steps from 0.9.0 and newer. Every step is idempotent. Older
# versions: remove MihoWRT, then install (README).

migrate_settings() {
	# Traffic flags are saved with rmempty=false: write the defaults now, so the
	# first Save & Apply without edits changes no UCI option.
	[ -n "$(uci_get dns_hijack)" ] || uci_set dns_hijack 1
	[ -n "$(uci_get disable_quic)" ] || uci_set disable_quic 1
	[ -n "$(uci_get netbird_proxy)" ] || uci_set netbird_proxy 0
	[ -n "$(uci_get bypass_ntp)" ] || uci_set bypass_ntp 1
	[ -n "$(uci_get bypass_subscription_dns)" ] || uci_set bypass_subscription_dns 1
	[ -n "$(uci_get lists_interval)" ] || uci_set lists_interval 0
	uci_commit
}

migrate() {
	# Never follow or reuse the pre-flock symlink, even with a live old pid.
	rm -f "$PKG_STATE_DIR/runtime.lock"
	migrate_settings
	# Rebuilt by the next settings_load through the provider URL filter.
	rm -f "$PROFILE_FILE"
	rm -f "$CLASH_DIR/mihomo.sock"
	settings_ensure_generated
}
