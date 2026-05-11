#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

js_syntax_files=(
	"$ROOT_DIR/rootfs/www/luci-static/resources/view/mihowrt/config.js"
	"$ROOT_DIR/rootfs/www/luci-static/resources/view/mihowrt/policy.js"
	"$ROOT_DIR/rootfs/www/luci-static/resources/view/mihowrt/diagnostics.js"
	"$ROOT_DIR/rootfs/www/luci-static/resources/mihowrt/backend.js"
	"$ROOT_DIR/rootfs/www/luci-static/resources/mihowrt/ace.js"
	"$ROOT_DIR/rootfs/www/luci-static/resources/mihowrt/exec.js"
	"$ROOT_DIR/rootfs/www/luci-static/resources/mihowrt/ui.js"
)

check_js_syntax() {
	node - "$@" <<'NODE'
const fs = require('fs');

for (const file of process.argv.slice(2)) {
	try {
		new Function(fs.readFileSync(file, 'utf8'));
	} catch (err) {
		err.message = `${file}: ${err.message}`;
		throw err;
	}
}
NODE
}

run_all_tests() {
	printf '==> shell syntax\n'
	sh -n \
		"$ROOT_DIR/install.sh" \
		"$ROOT_DIR/rootfs/usr/bin/mihowrt" \
		"$ROOT_DIR"/rootfs/usr/lib/mihowrt/*.sh \
		"$ROOT_DIR/rootfs/etc/init.d/mihowrt" \
		"$ROOT_DIR/rootfs/etc/init.d/mihowrt-recover"
	printf 'ok - shell syntax\n'

	printf '==> js syntax\n'
	if command -v node >/dev/null 2>&1; then
		check_js_syntax "${js_syntax_files[@]}"
		printf 'ok - js syntax\n'
	else
		printf 'skip - js syntax (node missing)\n'
	fi

	printf '==> shell tests\n'
	for test_script in "$ROOT_DIR"/tests/test_*.sh; do
		bash "$test_script"
	done

	printf 'all tests passed\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	run_all_tests "$@"
fi
