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
NODE
