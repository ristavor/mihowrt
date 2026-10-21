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
#tabmenu > .tabs { max-width: 100%; }
.mw-page { display: flex; flex-direction: column; gap: 16px; }
.mw-page > h2, .mw-page > .cbi-section { margin: 0; }
.mw-page h3 { margin-top: 0; }
.mw-status { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; margin: 0; }
.mw-row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 12px; }
.mw-row:first-child, .mw-grid .mw-row { margin-top: 0; }
.mw-grid { display: grid; grid-template-columns: minmax(0, max-content) minmax(0, 1fr); gap: 8px 16px; align-items: center; }
.mw-grid > * { min-width: 0; overflow-wrap: anywhere; }
.mw-grid select { max-width: 100%; }
.mw-check > div { padding: 4px 0; }
.mw-mark { display: inline-block; min-width: 1.6em; }
.mw-announce { white-space: pre-wrap; overflow-wrap: anywhere; }
.mw-yaml { width: 100%; min-height: 24em; }
.mw-log { max-height: 30em; overflow: auto; white-space: pre-wrap; }
.mw-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
@media (max-width: 600px) { .mw-grid { grid-template-columns: minmax(0, 1fr); gap: 4px 0; } .mw-grid > label, .mw-grid > .mw-muted { margin-top: 8px; } }
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

// Dates follow the LuCI language, not the browser's.
function formatDate(epoch) {
	const n = Number(epoch);
	if (!Number.isFinite(n) || n <= 0)
		return '';
	try {
		return new Date(n * 1000).toLocaleString(document.documentElement.lang || undefined, { dateStyle: 'medium', timeStyle: 'short' });
	}
	catch (e) {
		return new Date(n * 1000).toLocaleString();
	}
}

// Traffic line for a subscription. Missing total means unlimited; missing
// usage means unknown.
function trafficSummary(sub) {
	const hasUsage = sub?.upload != null || sub?.download != null;
	const used = (Number(sub?.upload) || 0) + (Number(sub?.download) || 0);
	const total = (sub?.total != null && Number(sub.total) > 0) ? formatBytes(sub.total) : _('Unlimited');

	return hasUsage ? '%s / %s'.format(formatBytes(used), total) : total;
}

// cls: an optional theme class (e.g. 'cbi-button' for stand-alone links).
function safeLink(url, label, cls) {
	return /^https?:\/\//i.test(String(url || ''))
		? E('a', { href: String(url), target: '_blank', rel: 'noopener noreferrer', class: cls || null }, text(label))
		: null;
}

// Plain messages for subscription download errors ("... failed: http_404").
function subscriptionError(message) {
	const m = /Subscription download failed: (\S+)/.exec(String(message || ''));
	if (!m)
		return message;
	const code = m[1];
	const http = /^http_(\d+)$/.exec(code);
	if (http && http[1] === '404')
		return _('The subscription link was not found (HTTP 404). Check the link with your provider.');
	if (http && (http[1] === '401' || http[1] === '403'))
		return _('The provider refused access (HTTP %s). The subscription may have expired or the link is wrong.').format(http[1]);
	if (http)
		return _('The provider server answered with an error (HTTP %s). Try again later.').format(http[1] || '?');
	if (code === 'too_large')
		return _('The subscription is too large.');
	if (code === 'invalid_url')
		return _('Enter the subscription link that starts with https://');
	return _('The router cannot reach the subscription server. Check the internet connection and the link.');
}

// Show/hide a block with a theme button (no <details>: some themes hide
// its marker). onOpen runs on every opening.
function toggle(showLabel, hideLabel, content, onOpen) {
	const button = E('button', { class: 'cbi-button', type: 'button', 'aria-expanded': 'false' }, text(showLabel));
	content.hidden = true;
	button.addEventListener('click', () => {
		content.hidden = !content.hidden;
		button.textContent = content.hidden ? showLabel : hideLabel;
		button.setAttribute('aria-expanded', content.hidden ? 'false' : 'true');
		if (!content.hidden && onOpen)
			onOpen();
	});
	return E('div', {}, [ E('div', { class: 'mw-row' }, [ button ]), content ]);
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
	subscriptionError,
	toggle,
	busy,
	notify,
	style
});
