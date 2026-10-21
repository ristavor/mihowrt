#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs'), path = require('path'), assert = require('assert');
const root = process.argv[2];
const dir = path.join(root, 'rootfs/www/luci-static/resources');
const files = [path.join(dir, 'mihowrt/api.js'), ...fs.readdirSync(path.join(dir, 'view/mihowrt')).map(f => path.join(dir, 'view/mihowrt', f))];
const strings = new Set();
const literal = "'(?:[^'\\\\]|\\\\.)*'";
const decode = s => Function('return ' + s)();
for (const file of files) {
 const source = fs.readFileSync(file, 'utf8');
 for (const m of source.matchAll(new RegExp('(?<![\\w])_\\(\\s*(' + literal + ')', 'g'))) strings.add(decode(m[1]));
 for (const m of source.matchAll(new RegExp('N_\\([^,]+,\\s*(' + literal + '),\\s*(' + literal + ')', 'g'))) { strings.add(decode(m[1])); strings.add(decode(m[2])); }
}
const po = fs.readFileSync(path.join(root, 'po/ru/mihowrt.po'), 'utf8');
const catalog = new Set();
for (const m of po.matchAll(/^msgid(?:_plural)? (".*")(?:\n".*")*/gm)) {
 const value = m[0].replace(/^msgid(?:_plural)? /, '').split('\n').map(s => JSON.parse(s)).join('');
 if (value) catalog.add(value);
}
const missing = [...strings].filter(s => !catalog.has(s));
const obsolete = [...catalog].filter(s => !strings.has(s) && !['Overview'].includes(s));
assert.deepStrictEqual(missing, [], 'missing translations');
assert.deepStrictEqual(obsolete, [], 'obsolete translations');
assert(po.includes('Plural-Forms: nplurals=3;'), 'Russian plural header');
console.log('ok - exact JS translation catalog including plurals');
const api = fs.readFileSync(files[0], 'utf8');
const css = api.match(/const CSS = `([\s\S]*?)`;/)[1].replace(/\.mw-sr\s*\{[^}]*\}/g, '');
assert(!/(?:font(?:-[\w-]+)?|opacity|color|background(?:-[\w-]+)?|border(?:-[\w-]+)?|outline(?:-[\w-]+)?)\s*:/.test(css), 'MihoWRT CSS must leave visual styles to the theme');
console.log('ok - layout-only MihoWRT CSS');
// Material gives the LuCI page tabs negative margins; cap their width so the
// MihoWRT menu cannot extend beyond a 390px viewport (398px before this cap).
assert(/#tabmenu\s*>\s*\.tabs\s*\{[^}]*max-width:\s*100%/.test(css), 'page tabs must fit the viewport despite theme negative margins');
console.log('ok - bounded page tab layout');
NODE
