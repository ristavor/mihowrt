#!/bin/ash

migrate_legacy_uci_settings() {
	local pkg_config="${PKG_CONFIG:-mihowrt}"
	local policy_mode="" changed=0 legacy_enabled_present=0

	have_command uci || return 0

	if uci -q get "$pkg_config.settings.enabled" >/dev/null 2>&1; then
		legacy_enabled_present=1
	fi

	policy_mode="$(uci -q get "$pkg_config.settings.policy_mode" 2>/dev/null || true)"
	case "$policy_mode" in
	direct-first | proxy-first)
		;;
	*)
		uci -q set "$pkg_config.settings=settings" || {
			err "Failed to prepare MihoWRT UCI settings section"
			return 1
		}
		uci -q set "$pkg_config.settings.policy_mode=direct-first" || {
			err "Failed to migrate MihoWRT policy_mode to direct-first"
			return 1
		}
		changed=1
		;;
	esac

	if [ "$legacy_enabled_present" = "1" ]; then
		uci -q delete "$pkg_config.settings.enabled" || {
			err "Failed to remove legacy MihoWRT enabled option"
			return 1
		}
		changed=1
	fi

	[ "$changed" = "1" ] || return 0
	uci -q commit "$pkg_config" || {
		err "Failed to commit migrated MihoWRT UCI settings"
		return 1
	}
	log "Migrated legacy MihoWRT UCI settings"
}
