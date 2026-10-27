# Frozen diagnostics YAML scan from status.sh at f31cce69, before shared helpers.
		function report_port(value) {
			if (value ~ /^[0-9]+$/ && value + 0 > 0 && !seen[value + 0]++)
				printf "%.0f\n", value + 0
		}
		/^[[:space:]]*(#.*)?$/ { next }
		/^[^[:space:]]/ {
			auth_block = 0
			if ($0 !~ /^-[[:space:]]/) listeners_block = 0
		}
		/^([\042\047]?listeners[\042\047]?)[[:space:]]*:/ {
			value = $0
			sub(/^[^:]*:[[:space:]]*/, "", value)
			sub(/[[:space:]]+#.*$/, "", value)
			sub(/[[:space:]]+$/, "", value)
			listeners_block = (value == "")
			item_indent = -1
			listener = 0
			next
		}
		listeners_block {
			match($0, /^[[:space:]]*/)
			indent = RLENGTH
			line = substr($0, indent + 1)
			if (line ~ /^-[[:space:]]/ && (item_indent < 0 || indent == item_indent)) {
				item_indent = indent
				listener = ++listener_count
				sub(/^-[[:space:]]+/, "", line)
			} else if (!listener || indent != item_indent + 2) next
			if (line !~ /^([\042\047]?(type|port|users)[\042\047]?)[[:space:]]*:/) next
			key = line
			sub(/[[:space:]]*:.*$/, "", key)
			gsub(/[\042\047]/, "", key)
			value = line
			sub(/^[^:]*:[[:space:]]*/, "", value)
			sub(/[[:space:]]+#.*$/, "", value)
			sub(/[[:space:]]+$/, "", value)
			if (key == "users") {
				users_present[listener] = 1
				users_empty[listener] = (value ~ /^\[[[:space:]]*\]$/)
			} else {
				gsub(/^[[:space:]\042\047]+|[[:space:]\042\047]+$/, "", value)
				if (key == "type") listener_type[listener] = value
				else listener_port[listener] = value
			}
			next
		}
		/^([\042\047]?authentication[\042\047]?)[[:space:]]*:/ {
			value = $0
			sub(/^[^:]*:[[:space:]]*/, "", value)
			sub(/[[:space:]]+#.*$/, "", value)
			sub(/[[:space:]]+$/, "", value)
			if (value == "" || value == "null" || value == "~")
				auth_block = 1
			else if (value !~ /^\[[[:space:]]*\]$/)
				auth = 1
		}
		auth_block && /^[[:space:]]+-[[:space:]]/ { auth = 1 }
		/^(mixed-port|port|socks-port|redir-port)[[:space:]]*:/ {
			value = $0
			sub(/^[^:]*:[[:space:]]*/, "", value)
			sub(/[[:space:]]+#.*$/, "", value)
			gsub(/^[[:space:]\042\047]+|[[:space:]\042\047]+$/, "", value)
			top_ports[++port_count] = value
		}
		END {
			if (!auth)
				for (i = 1; i <= port_count; i++) report_port(top_ports[i])
			for (i = 1; i <= listener_count; i++)
				if (listener_type[i] ~ /^(socks|http|mixed)$/ &&
				    (users_empty[i] || (!users_present[i] && !auth)))
					report_port(listener_port[i])
		}
