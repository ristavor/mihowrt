'use strict';
'require baseclass';
'require fs';
'require ui';

// Single bridge between the views and /usr/bin/mihowrt. Read calls go through
// mihowrt-read so the LuCI read ACL can never run a mutating command.
const READ = '/usr/bin/mihowrt-read';
const WRITE = '/usr/bin/mihowrt';
const INIT = '/etc/init.d/mihowrt';

const CSS = `
.mw-page { display: flex; flex-direction: column; gap: 16px; }
.mw-page > h2, .mw-page > .cbi-section { margin: 0; }
.mw-page h3 { margin-top: 0; }
.mw-status { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; margin: 0; }
.mw-status strong { font-size: 1.25em; }
.mw-row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 12px; }
.mw-row:first-child, .mw-grid .mw-row { margin-top: 0; }
.mw-grid { display: grid; grid-template-columns: max-content 1fr; gap: 8px 16px; align-items: center; }
.mw-muted { opacity: .75; }
.mw-check { list-style: none; margin: 0; padding: 0; }
.mw-check li { padding: 6px 0; border-bottom: 1px solid rgba(127, 127, 127, .2); }
.mw-check .mw-mark { display: inline-block; min-width: 1.6em; font-weight: bold; }
.mw-announce { white-space: pre-wrap; }
.mw-yaml { width: 100%; min-height: 24em; font-family: monospace; font-size: 13px; }
.mw-log { max-height: 30em; overflow: auto; white-space: pre-wrap; font-size: 12px; }
.mw-groups select { min-width: 14em; }
`;

function errorText(res) {
	const text = String(res?.stderr || res?.stdout || '').replace(/^Error: /gm, '').trim();
	return text || _('Unknown error');
}

async function run(bin, args) {
	const res = await fs.exec(bin, args);
	if (res.code !== 0)
		throw new Error(errorText(res));
	return res.stdout || '';
}

async function json(bin, args) {
	const out = await run(bin, args);
	try {
		return JSON.parse(out || '{}');
	}
	catch (e) {
		throw new Error(_('Unexpected response from the router: %s').format(out.slice(0, 200)));
	}
}

function randomSuffix() {
	return Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

// Values from providers are untrusted: they always become text nodes.
function text(value) {
	return [ String(value ?? '') ];
}

function formatBytes(value) {
	let n = Number(value);
	const units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
	let i = 0;

	if (!Number.isFinite(n) || n < 0)
		return '';
	while (n >= 1024 && i < units.length - 1) {
		n /= 1024;
		i++;
	}
	return '%s %s'.format(i ? n.toFixed(1) : String(n), units[i]);
}

function formatDate(epoch) {
	const n = Number(epoch);
	return (Number.isFinite(n) && n > 0) ? new Date(n * 1000).toLocaleString() : '';
}

// Traffic line for a subscription. Missing total means unlimited; missing
// usage means unknown.
function trafficSummary(sub) {
	const hasUsage = sub?.upload != null || sub?.download != null;
	const used = (Number(sub?.upload) || 0) + (Number(sub?.download) || 0);
	const total = (sub?.total != null && Number(sub.total) > 0) ? formatBytes(sub.total) : _('Unlimited');

	return hasUsage ? '%s / %s'.format(formatBytes(used), total) : total;
}

function safeLink(url, label) {
	return /^https?:\/\//i.test(String(url || ''))
		? E('a', { href: String(url), target: '_blank', rel: 'noopener noreferrer' }, text(label))
		: null;
}

// Disable a button while an async action runs; report failures.
async function busy(button, action) {
	if (button) {
		button.disabled = true;
		button.classList.add('spinning');
	}
	try {
		return await action();
	}
	catch (e) {
		notify(e.message, 'error');
		return null;
	}
	finally {
		if (button) {
			button.disabled = false;
			button.classList.remove('spinning');
		}
	}
}

function notify(message, level) {
	ui.addNotification(null, E('p', text(message)), level || 'info');
}

function style() {
	return E('style', text(CSS));
}

return baseclass.extend({
	read: (cmd, ...args) => json(READ, [ cmd, ...args ]),
	write: (cmd, ...args) => json(WRITE, [ cmd, ...args ]),
	service: (action) => run(INIT, [ action ]),
	upload: async (prefix, content) => {
		const path = '/tmp/%s.%s'.format(prefix, randomSuffix());
		await fs.write(path, content);
		return path;
	},
	readFile: (path) => fs.read(path).catch(() => ''),
	errorText,
	text,
	formatBytes,
	formatDate,
	trafficSummary,
	safeLink,
	busy,
	notify,
	style
});
