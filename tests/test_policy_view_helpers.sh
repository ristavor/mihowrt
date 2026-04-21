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
const syncMatch = source.match(/function syncListCaches[\s\S]*?\n}\n\nfunction hasListValueChanges/);
const bindMatch = source.match(/function bindTextFileOption[\s\S]*?\n}\n\nreturn view.extend/);

if (!normalizeMatch)
	throw new Error('normalizeBlock() not found');
if (!syncMatch)
	throw new Error('syncListCaches() not found');
if (!bindMatch)
	throw new Error('bindTextFileOption() not found');

const normalizeFnSource = normalizeMatch[0].replace(/\n\nfunction currentNormalizedListValue$/, '');
const syncFnSource = syncMatch[0].replace(/\n\nfunction hasListValueChanges$/, '');
const bindFnSource = bindMatch[0].replace(/\n\nreturn view.extend$/, '');
	const context = {
		writeError: null,
		fs: {
			writeCalls: [],
			write(path, value) {
				if (context.writeError)
					return Promise.reject(new Error(context.writeError));
				this.writeCalls.push({ path, value });
				return Promise.resolve();
			}
	}
};

vm.createContext(context);
vm.runInContext(`let dstValueCache = null; let srcValueCache = null;\n${normalizeFnSource}\n${syncFnSource}\n${bindFnSource}\nglobalThis.bindTextFileOption = bindTextFileOption;\nglobalThis.syncListCaches = syncListCaches;\nglobalThis.getDstCache = () => dstValueCache;\nglobalThis.getSrcCache = () => srcValueCache;\nglobalThis.setDstCache = value => { dstValueCache = value; };\nglobalThis.setSrcCache = value => { srcValueCache = value; };`, context);

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

		context.writeError = 'disk full';
		let writeFailed = false;
		try {
			await option.write('settings', '4.4.4.4');
		}
		catch (e) {
			writeFailed = e.message === 'disk full';
		}
		if (!writeFailed)
			throw new Error('bindTextFileOption.write should reject when fs.write fails');
		if (context.getDstCache() !== '2.2.2.2\n')
			throw new Error('bindTextFileOption.write should keep cache unchanged on write failure');
		context.writeError = null;

		context.fs.writeCalls.length = 0;
		context.setSrcCache('');
		const removeOption = {};
		context.bindTextFileOption(removeOption, 'src', '/opt/clash/lst/always_proxy_src.txt', 'desc');
		await removeOption.remove();
		if (context.fs.writeCalls.length !== 0)
			throw new Error('bindTextFileOption.remove should skip no-op empty writes');

		context.setSrcCache('erase-me\n');
		context.writeError = 'permission denied';
		let removeFailed = false;
		try {
			await removeOption.remove();
		}
		catch (e) {
			removeFailed = e.message === 'permission denied';
		}
		if (!removeFailed)
			throw new Error('bindTextFileOption.remove should reject when fs.write fails');
		if (context.getSrcCache() !== 'erase-me\n')
			throw new Error('bindTextFileOption.remove should keep cache unchanged on write failure');
		context.writeError = null;

		context.setDstCache('stale\n');
		context.setSrcCache('old\n');
	context.syncListCaches(' 3.3.3.3\r\n', '');
	if (context.getDstCache() !== '3.3.3.3\n')
		throw new Error('syncListCaches should refresh destination cache from latest file contents');
	if (context.getSrcCache() !== '')
		throw new Error('syncListCaches should refresh source cache from latest file contents');
	})().catch(err => {
		throw err;
	});
EOF

pass "policy view helpers"
