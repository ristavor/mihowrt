#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "$0")/.." && pwd)"

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
	node -e "new Function(require('fs').readFileSync('$ROOT_DIR/rootfs/www/luci-static/resources/view/mihowrt/config.js','utf8')); new Function(require('fs').readFileSync('$ROOT_DIR/rootfs/www/luci-static/resources/view/mihowrt/policy.js','utf8')); new Function(require('fs').readFileSync('$ROOT_DIR/rootfs/www/luci-static/resources/view/mihowrt/diagnostics.js','utf8')); new Function(require('fs').readFileSync('$ROOT_DIR/rootfs/www/luci-static/resources/mihowrt/backend.js','utf8')); new Function(require('fs').readFileSync('$ROOT_DIR/rootfs/www/luci-static/resources/mihowrt/ace.js','utf8')); new Function(require('fs').readFileSync('$ROOT_DIR/rootfs/www/luci-static/resources/mihowrt/exec.js','utf8')); new Function(require('fs').readFileSync('$ROOT_DIR/rootfs/www/luci-static/resources/mihowrt/ui.js','utf8'));"
	printf 'ok - js syntax\n'
else
	printf 'skip - js syntax (node missing)\n'
fi

printf '==> shell tests\n'
for test_script in "$ROOT_DIR"/tests/test_*.sh; do
	bash "$test_script"
done

printf 'all tests passed\n'
