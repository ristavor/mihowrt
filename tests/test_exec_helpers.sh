#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = process.cwd();
const source = fs.readFileSync(path.join(rootDir, 'rootfs/www/luci-static/resources/mihowrt/exec.js'), 'utf8');
const match = source.match(/function errorDetail[\s\S]*?\n}\n\nreturn baseclass\.extend/);

if (!match)
	throw new Error('errorDetail() not found');

const fnSource = match[0].replace(/\n\nreturn baseclass\.extend$/, '');
const context = {};

vm.createContext(context);
vm.runInContext(`
function _(value) { return value; }
${fnSource}
globalThis.errorDetail = errorDetail;
`, context);

if (context.errorDetail({ stderr: 'boom' }) !== 'boom')
	throw new Error('errorDetail() should prefer stderr');
if (context.errorDetail({ stdout: 'trace' }) !== 'trace')
	throw new Error('errorDetail() should fall back to stdout');
if (context.errorDetail({ stderr: ' ', stdout: '' }) !== 'unknown error')
	throw new Error('errorDetail() should emit unknown error fallback');
EOF

pass "exec helper"
