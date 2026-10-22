#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs'), path = require('path'), assert = require('assert');
const root = process.argv[2];
const api = fs.readFileSync(path.join(root, 'rootfs/www/luci-static/resources/mihowrt/api.js'), 'utf8');
const css = api.match(/const CSS = `([\s\S]*?)`;/)[1].replace(/\.mw-sr\s*\{[^}]*\}/g, '');
assert(!/(?:font(?:-[\w-]+)?|opacity|color|background(?:-[\w-]+)?|border(?:-[\w-]+)?|outline(?:-[\w-]+)?)\s*:/.test(css), 'MihoWRT CSS must leave visual styles to the theme');
console.log('ok - layout-only MihoWRT CSS');
// Material gives the LuCI page tabs negative margins; cap their width so the
// MihoWRT menu cannot extend beyond a 390px viewport (398px before this cap).
assert(/#tabmenu\s*>\s*\.tabs\s*\{[^}]*max-width:\s*100%/.test(css), 'page tabs must fit the viewport despite theme negative margins');
console.log('ok - bounded page tab layout');
assert(/\.mw-page\s+\[hidden\]\s*\{\s*display:\s*none;?\s*\}/.test(css), 'hidden toggle content must override grid and theme display rules');
console.log('ok - hidden toggle content layout');
// Spacing and alignment keep blocks consistent with stock LuCI pages in every theme.
assert(/\.mw-toggle\s*>\s*\.mw-row\s*\+\s*\*\s*\{[^}]*margin-top:\s*12px/.test(css), 'opened toggle content keeps a gap under its button');
assert(/\.mw-groups\s+\.mw-row\s*>\s*select\s*\{[^}]*flex:\s*1 1 12em[^}]*max-width:\s*28em/.test(css), 'group selects share one width so Test buttons align');
assert(/\.mw-page\s*>\s*h2\s*\{\s*margin-bottom:\s*0;?\s*\}/.test(css) && !/\.mw-page\s*>\s*h2[^{]*\{[^}]*margin:\s*0/.test(css), 'page title keeps the theme top margin');
assert(/\.mw-announce\s*\+\s*\.mw-grid\s*\{[^}]*margin-top:\s*12px/.test(css), 'announce text is separated from the subscription grid');
assert(/\.mw-status\s*\{[^}]*flex-direction:\s*column/.test(css), 'status facts are stacked');
assert(/\.mw-actions\s*>\s*\.cbi-button\s*\{[^}]*flex:\s*1 1 auto/.test(css), 'phone action buttons share the row');
const overview = fs.readFileSync(path.join(root, 'rootfs/www/luci-static/resources/view/mihowrt/overview.js'), 'utf8');
assert(/class: 'mw-toggle'/.test(api), 'toggle wrapper marked for spacing');
assert(/function linkButton/.test(api) && /api\.linkButton\(sub\./.test(overview) && !/safeLink\(sub\./.test(overview), 'provider links are theme buttons, not unstyled links');
assert(/cells\.push\(E\('span'\), E\('span', \{ class: 'mw-muted' \}/.test(overview), 'LoadBalance note on its own grid row');
assert(/\.mw-job:empty\s*\{[^}]*position:\s*absolute/.test(css) && /class: 'mw-job'/.test(api), 'empty job notice takes no flex gap');
assert(/\.mw-field\s*\{[^}]*display:\s*flex/.test(css) && /\.mw-field\s*>\s*select\s*\{[^}]*min-width:\s*0/.test(css), 'picker selects stay with their label');
console.log('ok - layout review spacing and alignment');
NODE
