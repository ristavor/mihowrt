'use strict';
'require baseclass';
'require fs';
'require ui';
'require request';
'require rpc';

// Single bridge between the views and /usr/bin/mihowrt. Read calls go through
// mihowrt-read so the LuCI read ACL can never run a mutating command.
const READ = '/usr/bin/mihowrt-read';
const WRITE = '/usr/bin/mihowrt';
const INIT = '/etc/init.d/mihowrt';

const CSS = `
#tabmenu > .tabs { max-width: 100%; }
.mw-page { display: flex; flex-direction: column; gap: 16px; }
.mw-page [hidden] { display: none; }
.mw-page > h2 { margin-bottom: 0; }
.mw-page > .cbi-section { margin: 0; }
.mw-page h3 { margin-top: 0; }
.mw-status { display: flex; flex-direction: column; align-items: flex-start; gap: 4px; margin: 0; }
.mw-row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 12px; }
.mw-row:first-child, .mw-grid .mw-row { margin-top: 0; }
.mw-grid { display: grid; grid-template-columns: minmax(0, max-content) minmax(0, 1fr); gap: 8px 16px; align-items: center; }
.mw-grid > * { min-width: 0; overflow-wrap: anywhere; }
.mw-grid select { max-width: 100%; }
.mw-check > div { padding: 4px 0; }
.mw-mark { display: inline-block; min-width: 1.6em; }
.mw-announce { white-space: pre-wrap; overflow-wrap: anywhere; }
.mw-announce + .mw-grid { margin-top: 12px; }
.mw-toggle > .mw-row + * { margin-top: 12px; }
.mw-toggle + .mw-toggle { margin-top: 12px; }
.mw-job:empty { position: absolute; }
.mw-picker > select { flex: 1 1 12em; min-width: 0; max-width: 100%; }
.mw-picker + .cbi-value-description { margin-top: 4px; }
.mw-groups .mw-row > select { flex: 1 1 12em; min-width: 0; max-width: 28em; }
.mw-groups .mw-ping { flex: 0 0 auto; min-width: 5.5em; white-space: nowrap; }
.mw-yaml { width: 100%; min-height: 24em; }
.mw-log { max-height: 30em; overflow: auto; white-space: pre-wrap; }
.mw-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
@media (max-width: 600px) { .mw-grid { grid-template-columns: minmax(0, 1fr); gap: 4px 0; } .mw-grid > label, .mw-grid > .mw-muted { margin-top: 8px; } .mw-actions { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 10em), 1fr)); } .mw-groups .mw-ping { flex-basis: 100%; } .mw-groups .mw-ping:empty { display: none; } }
`;

function errorText(res) {
	const output = res?.stderr || res?.stdout;
	const message = String(output || res?.message || (typeof res === 'string' ? res : '')).replace(/^Error: /gm, '').trim();
	// Backend output is not a LuCI transport error, even if it mentions one.
	if (output || res?.name === 'CommandError' || res?.name === 'JobError')
		return message || _('Unknown error');
	if (res?.name === 'TimeoutError' || (res?.name === 'Error' && message === 'XHR request timed out'))
		return _('The router did not answer in time. The operation may still be running; check again in a minute.');
	// An expired session reaches us as SessionError, or as rpc error -32002.
	if (res?.name === 'PermissionError' || res?.name === 'SessionError' || (res?.name === 'Error' && message === 'Access denied')
		|| (res?.name === 'RPCError' && /failed with (?:ubus code 6:|HTTP error 403:|error -32002:)/.test(message)))
		return _('Access denied. Log in to LuCI again.');
	return message || _('Unknown error');
}

async function run(bin, args) {
	let res;
	try {
		res = await fs.exec(bin, args);
	}
	catch (e) {
		throw new Error(errorText(e));
	}
	if (res.code !== 0)
		throw Object.assign(new Error(errorText(res)), { name: 'CommandError' });
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
	return Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, '0')).join('');
}

const JOB_LABELS = {
	'connect': _('Connect'),
	'core-update': _('Update Mihomo core'),
	'update-subscription': _('Update subscription'),
	'update-lists': _('Update remote lists'),
	'apply-lists': _('Save & Apply'),
	'save-config': _('Check and apply'),
	'restore-config': _('Restore the previous YAML'),
	'service': _('Start / Stop / Restart')
};

const ACCESS_DENIED = _('Access denied. Log in to LuCI again.');
let waitingJobs = 0;
let jobButtonLocks = 0;
const jobButtons = new Map();

// Shared by job(), busy() preparation, and jobs discovered at page load.
function lockJobButtons() {
	jobButtonLocks++;
	for (const button of document.querySelectorAll?.('[data-mw-job]') || []) {
		if (!jobButtons.has(button))
			jobButtons.set(button, button.disabled);
		button.disabled = true;
	}
}

function unlockJobButtons() {
	if (--jobButtonLocks > 0)
		return;
	for (const [ button, disabled ] of jobButtons)
		button.disabled = disabled;
	jobButtons.clear();
}

async function waitJob(api, id) {
	let failures = 0;
	for (;;) {
		await new Promise(resolve => setTimeout(resolve, 1000));
		let status;
		try {
			status = await api.read('job-status', id);
			failures = 0;
		}
		catch (e) {
			if (++failures < 10)
				continue;
			throw new Error(errorText(e) === ACCESS_DENIED ? ACCESS_DENIED
				: _('Lost connection to the router while waiting for the result.'));
		}
		if (status.state === 'ok')
			return status.result;
		if (status.state === 'error')
			throw Object.assign(new Error(status.error), { name: 'JobError' });
	}
}

function modeLabel(mode) {
	return mode === 'proxy-first'
		? _('All traffic via proxy except exclusions')
		: _('Only selected traffic via proxy');
}

// Provider links as theme buttons (some themes leave a.cbi-button unstyled).
function linkButton(url, label) {
	if (!safeLink(url, label))
		return null;
	const button = E('button', { class: 'cbi-button', type: 'button' }, text(label));
	button.addEventListener('click', () => window.open(String(url), '_blank', 'noopener,noreferrer'));
	return button;
}

function infoGrid(rows) {
	return E('div', { class: 'mw-grid' }, rows.flatMap(([ k, v ]) => [ E('span', { class: 'mw-muted' }, text(k)), E('span', text(v)) ]));
}

function actionNotice(action) {
	return action === 'unchanged' ? _('Subscription is up to date.')
		: action === 'hot_reloaded' ? _('Subscription updated and applied.') : _('Subscription updated.');
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
let toggleCount = 0;
function toggle(showLabel, hideLabel, content, onOpen) {
	const id = 'mw-toggle-' + (++toggleCount);
	const button = E('button', { class: 'cbi-button', type: 'button', 'aria-expanded': 'false', 'aria-controls': id }, text(showLabel));
	content.setAttribute('id', id);
	content.hidden = true;
	button.addEventListener('click', () => {
		content.hidden = !content.hidden;
		button.textContent = content.hidden ? showLabel : hideLabel;
		button.setAttribute('aria-expanded', content.hidden ? 'false' : 'true');
		if (!content.hidden && onOpen)
			onOpen();
	});
	return E('div', { class: 'mw-toggle' }, [ E('div', { class: 'mw-row' }, [ button ]), content ]);
}

// Disable a button while an async action runs; report failures.
async function busy(button, action) {
	const startsJob = button?.hasAttribute('data-mw-job');
	if (button?.disabled || (startsJob && this.jobRunning))
		return null;
	if (startsJob)
		lockJobButtons();
	if (button) {
		button.disabled = true;
		button.classList.add('spinning');
	}
	try {
		return await action();
	}
	catch (e) {
		notify(errorText(e), 'error');
		return null;
	}
	finally {
		if (button) {
			if (!startsJob)
				button.disabled = false;
			button.classList.remove('spinning');
		}
		if (startsJob)
			unlockJobButtons();
	}
}

// The LuCI banner has no role: announce it to screen readers.
function notify(message, level) {
	const node = ui.addNotification(null, E('p', text(message)), level || 'info');
	node?.setAttribute?.('role', level === 'error' ? 'alert' : 'status');
}

const NOTICE_KEY = 'mihowrt-notice';
// Last job whose result a page already showed (or waited for).
const SEEN_JOB_KEY = 'mihowrt-seen-job';
const JOB_ERROR_WINDOW = 600;

function markJobSeen(id) {
	try {
		sessionStorage.setItem(SEEN_JOB_KEY, String(id));
	}
	catch (e) {
		// No session storage: a later page may show the error once more.
	}
}

function jobSeen(id) {
	try {
		return sessionStorage.getItem(SEEN_JOB_KEY) === String(id);
	}
	catch (e) {
		// Without session storage the notice cannot be shown exactly once.
		return true;
	}
}

function showPendingNotice() {
	try {
		const raw = sessionStorage.getItem(NOTICE_KEY);
		sessionStorage.removeItem(NOTICE_KEY);
		const pending = raw ? JSON.parse(raw) : null;
		if (pending?.text)
			notify(pending.text, pending.type);
	}
	catch (e) {
		// No session storage or a damaged value: there is no notice to show.
	}
}

function style() {
	return E('style', text(CSS));
}

return baseclass.extend({
	read: (cmd, ...args) => json(READ, [ cmd, ...args ]),
	write: (cmd, ...args) => json(WRITE, [ cmd, ...args ]),
	service: (action) => run(INIT, [ action ]),
	jobRunning: false,
	jobLabel: (op) => JOB_LABELS[op] || op,
	job: async function(op, ...args) {
		waitingJobs++;
		this.jobRunning = true;
		lockJobButtons();
		try {
			const started = await this.write('job-start', op, ...args);
			let result;
			try {
				result = await waitJob(this, started.id);
			}
			catch (e) {
				if (e.name === 'JobError')
					markJobSeen(started.id);
				throw e;
			}
			markJobSeen(started.id);
			return result;
		}
		finally {
			this.jobRunning = --waitingJobs > 0;
			unlockJobButtons();
		}
	},
	// A notice shown right before location.reload() is lost: keep it for the next page load.
	reloadWithNotice: (message, level) => {
		try {
			sessionStorage.setItem(NOTICE_KEY, JSON.stringify({ text: String(message ?? ''), type: level || 'info' }));
		}
		catch (e) {
			notify(message, level);
		}
		location.reload();
	},
	jobNotice: function() {
		showPendingNotice();
		const notice = E('div', { class: 'mw-job', 'aria-live': 'polite' });
		const failed = (status, error) => _('"%s" failed: %s').format(this.jobLabel(status.op),
			[ 'connect', 'update-subscription' ].includes(status.op) ? subscriptionError(error) : error);
		this.read('job-status').then(async status => {
			// A job that failed while no page waited for it: show it once.
			if (status.state === 'error' && status.id && !jobSeen(status.id)
				&& Number(status.now ?? Date.now() / 1000) - Number(status.finished) <= JOB_ERROR_WINDOW) {
				markJobSeen(status.id);
				notify(failed(status, status.error || _('The operation failed.')), 'error');
				return;
			}
			if (status.state !== 'running')
				return;
			this.jobRunning = true;
			lockJobButtons();
			const alert = E('div', { class: 'alert-message notice' }, text(_('"%s" is running…').format(this.jobLabel(status.op))));
			notice.appendChild(alert);
			try {
				await waitJob(this, status.id);
			}
			catch (e) {
				// A terminal job error still requires fresh page data. A lost
				// connection does not: keep its recovery message visible.
				if (e.name !== 'JobError') {
					alert.textContent = errorText(e);
					return;
				}
				markJobSeen(status.id);
				this.reloadWithNotice(failed(status, e.message || _('The operation failed.')), 'error');
				return;
			}
			markJobSeen(status.id);
			location.reload();
		}).catch(e => {
			notice.appendChild(E('div', { class: 'alert-message notice' }, text(errorText(e))));
		});
		return notice;
	},
	upload: async (prefix, content) => {
		if (![ 'mihowrt-config', 'mihowrt-policy-list' ].includes(prefix))
			throw new Error(_('Invalid upload path.'));
		const path = '/tmp/%s.%s'.format(prefix, randomSuffix());
		const blob = new Blob([ content === '' ? '\n' : content ]); // cgi-upload refuses empty files; a blank line means an empty list/YAML to the backend
		const data = new FormData();
		data.append('sessionid', rpc.getSessionID());
		data.append('filename', path);
		data.append('filedata', blob);
		const response = await request.post(L.env.cgi_base + '/cgi-upload', data, { timeout: 0 });
		if (!response.ok || response.status !== 200)
			throw new Error(response.status === 403 ? ACCESS_DENIED : _('Unexpected response from the router.'));
		let reply;
		try {
			reply = response.json();
		}
		catch (e) {
			if (e.name === 'SyntaxError')
				throw new Error(_('Unexpected response from the router.'));
			throw e;
		}
		if (reply?.failure)
			throw new Error(reply.message);
		if (reply?.size !== blob.size)
			throw new Error(_('The upload was incomplete. Try again.'));
		return path;
	},
	readLarge: async (cmd, ...args) => {
		let reply;
		try {
			reply = await fs.exec_direct(READ, [ cmd, ...args ], 'json');
		}
		catch (e) {
			if (e.name === 'SyntaxError')
				throw new Error(_('Unexpected response from the router.'));
			throw e;
		}
		if (!reply || typeof reply !== 'object')
			throw new Error(_('Unexpected response from the router.'));
		return reply;
	},
	readFile: (path) => fs.read(path).catch(() => ''),
	modeLabel,
	linkButton,
	infoGrid,
	actionNotice,
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
