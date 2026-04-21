#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const rootDir = process.cwd();
const source = fs.readFileSync(path.join(rootDir, 'rootfs/www/luci-static/resources/view/mihowrt/policy.js'), 'utf8');
const normalizeMatch = source.match(/function normalizeBlock[\s\S]*?\n}\n\nfunction currentNormalizedListValue/);
const bindMatch = source.match(/function bindTextFileOption[\s\S]*?\n}\n\nreturn view.extend/);

if (!normalizeMatch)
	throw new Error('normalizeBlock() not found');
if (!bindMatch)
	throw new Error('bindTextFileOption() not found');

const normalizeFnSource = normalizeMatch[0].replace(/\n\nfunction currentNormalizedListValue$/, '');
const bindFnSource = bindMatch[0].replace(/\n\nreturn view.extend$/, '');
const context = {
	fs: {
		writeCalls: [],
		write(path, value) {
			this.writeCalls.push({ path, value });
			return Promise.resolve();
		}
	}
};

vm.createContext(context);
vm.runInContext(`let dstValueCache = null; let srcValueCache = null;\n${normalizeFnSource}\n${bindFnSource}\nglobalThis.bindTextFileOption = bindTextFileOption;\nglobalThis.getDstCache = () => dstValueCache;\nglobalThis.setDstCache = value => { dstValueCache = value; };\nglobalThis.setSrcCache = value => { srcValueCache = value; };`, context);

(async () => {
	const option = {};
	context.setDstCache('1.1.1.1\n');
	context.bindTextFileOption(option, 'dst', '/opt/clash/lst/always_proxy_dst.txt', 'desc');
	await option.write('settings', '1.1.1.1');
	if (context.fs.writeCalls.length !== 0)
		throw new Error('bindTextFileOption.write should skip no-op writes');

	await option.write('settings', '2.2.2.2');
	if (context.fs.writeCalls.length !== 1)
		throw new Error('bindTextFileOption.write should persist changed content once');
	if (context.fs.writeCalls[0].value !== '2.2.2.2\n')
		throw new Error('bindTextFileOption.write should normalize changed content');
	if (context.getDstCache() !== '2.2.2.2\n')
		throw new Error('bindTextFileOption.write should update cache after changed content');

	context.fs.writeCalls.length = 0;
	context.setSrcCache('');
	const removeOption = {};
	context.bindTextFileOption(removeOption, 'src', '/opt/clash/lst/always_proxy_src.txt', 'desc');
	await removeOption.remove();
	if (context.fs.writeCalls.length !== 0)
		throw new Error('bindTextFileOption.remove should skip no-op empty writes');
})().catch(err => {
	throw err;
});
EOF

pass "policy view helpers"
