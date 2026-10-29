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
@media (max-width: 600px) { .mw-grid { grid-template-columns: minmax(0, 1fr); gap: 4px 0; } .mw-grid > label, .mw-grid > .mw-muted { margin-top: 8px; } .mw-actions { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 10em), 1fr)); align-items: stretch; } .mw-actions > .cbi-button { margin: 0; } .mw-groups .mw-ping { flex-basis: 100%; } .mw-groups .mw-ping:empty { display: none; } }
`;

const JOB_LABELS = {
	'connect': _('Connecting the subscription'),
	'core-update': _('Mihomo core update'),
	'dashboard-install': _('Install Mihomo dashboard'),
	'dashboard-remove': _('Remove Mihomo dashboard'),
	'auto-update': _('Automatic update'),
	'update-subscription': _('Subscription update'),
	'update-lists': _('Remote list update'),
	'apply-lists': _('Applying lists and settings'),
	'save-config': _('Checking and applying the YAML'),
	'restore-config': _('Restoring the previous YAML'),
	'service': _('Starting, stopping or restarting MihoWRT')
};

const ACCESS_DENIED = _('Access denied. Log in to LuCI again, or ask for write access.');

function jobLabel(op) {
	return JOB_LABELS[op] || op;
}

// Plain words for backend errors the user can act on; other text is kept.
// Mapped text never matches again, so mapping twice is harmless.
function backendErrorText(message) {
	const raw = String(message ?? '');
	const lastLine = raw.trim().split('\n').pop() || '';
	const inner = value => backendErrorText(value).replace(/\.$/, '');
	let m;

	if ((m = /^Failed to apply the new subscription settings: ([\s\S]*?); restoring the previous config failed: ([\s\S]*); the previous config is saved in (\S+)$/.exec(raw)))
		return _('The new subscription settings could not be applied: %s. Returning to the previous configuration also failed: %s. The previous configuration is saved in %s.').format(inner(m[1]), inner(m[2]), m[3]);
	if ((m = /^Failed to apply the new subscription settings: ([\s\S]*); the previous config is restored$/.exec(raw)))
		return _('The new subscription settings could not be applied: %s. The previous configuration is back in use.').format(inner(m[1]));
	if ((m = /^Failed to apply routing rules: ([\s\S]*)$/.exec(raw)))
		return _('Mihomo started, but the routing rules could not be applied: %s').format(backendErrorText(m[1]));
	if ((m = /^Failed to update (\d+) of (\d+) remote lists: ([\s\S]*)$/.exec(raw)))
		return N_(Number(m[2]), 'Could not update %d of %d remote list: %s', 'Could not update %d of %d remote lists: %s').format(m[1], m[2], backendErrorText(m[3]));
	if (raw !== lastLine && lastLine !== 'Mihomo rejected the configuration')
		return backendErrorText(lastLine);
	if ((m = /^Another operation is running: ([\w-]+)$/.exec(raw)))
		return _('Another operation is running: "%s". Wait until it finishes.').format(jobLabel(m[1]));
	if ((m = /^Unsupported (\S+) form: use a block mapping$/.exec(raw)))
		return _('The "%s" section of the YAML must be a block mapping (one key per line), not {…}, […] or a single value.').format(m[1]);
	if ((m = /^Mihomo core updated, but the service restart failed: (.*)$/.exec(raw)))
		return _('The Mihomo core was updated, but MihoWRT could not restart: %s. Press Start on Overview.').format(inner(m[1]));
	if (lastLine === 'Mihomo core updated, but the service restart failed')
		return _('The Mihomo core was updated, but MihoWRT could not restart. Press Start on Overview.');
	if (/Mihomo rejected the configuration$/.test(raw)) {
		const headline = _('Mihomo rejected the configuration.');
		const messages = [ ...raw.matchAll(/level=(?:error|fatal) msg="((?:[^"\\]|\\.)*)"/g) ]
			.map(m => {
				const text = m[1].replace(/\\"/g, '"').replace(/\/tmp\/[^\s"'<>]+/g, '…');
				let sub;
				if ((sub = /yaml:(?:\s+unmarshal errors:)?\s+line (\d+): (.*)/s.exec(text)))
					return _('YAML error on line %s: %s').format(sub[1], sub[2]);
				if ((sub = /^proxy group\[\d+\]: (.*?): '(.*?)' not found$/.exec(text)))
					return _('Group "%s" refers to a server "%s" that does not exist.').format(sub[1], sub[2]);
				return text;
			});
		return messages.length ? headline + ' ' + messages.join('\n') : headline;
	}
	if (/^Core update: (?:cannot reach GitHub|download failed|no downloadable asset|no asset for)/.test(raw))
		return _('Could not download the Mihomo core from GitHub. Check the router\'s internet connection. If GitHub is blocked, install the core manually (README, "If GitHub is unavailable").');
	if ((m = /^Core update: not enough flash: need (\d+) MiB, free (\d+) MiB/.exec(raw)))
		return _('Not enough free flash for the Mihomo core: %s MiB needed, %s MiB free.').format(m[1], m[2]);
	if (/^Core update: not enough flash/.test(raw))
		return _('Not enough free flash for the Mihomo core. The current core is kept.');
	if (/^Core update: unsupported architecture/.test(raw))
		return _('This router\'s CPU is not supported by the Mihomo core.');
	if (/^Core update: new binary does not run on this router/.test(raw))
		return _('The downloaded core does not run on this router. The current core is kept.');
	if (/^Core update: new core rejects the current config/.test(raw))
		return _('The new core does not accept your current configuration; the core was not updated.');
	if (/^Core update: (?:sha256 mismatch|downloaded size does not match release)/.test(raw))
		return _('The downloaded core file is damaged. Try again.');
	if (raw === 'Another core update is running')
		return _('The core is already being updated.');
	if (raw === 'The YAML is empty: nothing was changed.')
		return _('The YAML is empty: nothing was changed.');
	if (raw === 'There is no previous configuration.')
		return _('There is no previous configuration.');
	if ((m = /^List (\S+) is larger than 1 MiB\.$/.exec(raw))) {
		const titles = {
			dst: _('Addresses via proxy'),
			src: _('Devices via proxy'),
			direct: _('Addresses always direct'),
			direct_src: _('Devices always direct')
		};
		return _('The "%s" list is larger than 1 MiB.').format(titles[m[1]] || m[1]);
	}
	if (/^Runtime is busy \(process \d+\)$/.test(raw))
		return _('The router is busy with another task. Try again in a minute.');
	if (raw === 'Mihomo hot reload failed')
		return _('Mihomo could not apply the new configuration; the previous one is kept.');
	if (raw === 'MihoWRT could not start. See the system log.')
		return _('MihoWRT could not start. See the log on the Diagnostics page.');
	if (raw === 'Invalid MihoWRT settings')
		return _('MihoWRT settings are damaged. Save the Traffic page again or reinstall the package.');
	if ((m = /^Mihomo config not found: (\S+)$/.exec(raw)))
		return _('Mihomo configuration file not found: %s').format(m[1]);
	if ((m = /^Failed to apply nftables policy \(see (\S+)\)$/.exec(raw)))
		return _('Failed to apply nftables policy: see %s').format(m[1]);
	if (raw === 'Could not download the dashboard. Check that GitHub is reachable from the router.')
		return _('Could not download the dashboard. Check that GitHub is reachable from the router.');
	if (raw === 'Start MihoWRT before installing the dashboard.')
		return _('Start MihoWRT before installing the dashboard.');
	if (/^Interrupted:/.test(raw))
		return _('The operation was interrupted (for example, by a router reboot). You can run it again.');
	if (/not a Clash\/Mihomo config/.test(raw))
		return _('The link does not give a Clash/Mihomo config (it looks like V2Ray links, base64, sing-box JSON or a web page). Take the Clash/Mihomo link from your provider\'s account.');
	if (/^Subscription returned an empty config/.test(raw))
		return _('The subscription returned an empty configuration.');
	if (/must start with http/.test(raw))
		return _('Enter the subscription link that starts with https://');
	if (/Remote lists exceed 8 MiB in total/.test(raw))
		return _('The remote lists are larger than 8 MiB in total. Remove some list links or use smaller lists.');

	// Subscription download errors ("... failed: http_404").
	if (!(m = /Subscription download failed: (\S+)/.exec(raw)))
		return raw;
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

// Only Mihomo's error messages, without timestamps and temp paths.
function coreError(raw) {
	const msgs = [ ...String(raw).matchAll(/level=(?:error|fatal) msg="((?:[^"\\]|\\.)*)"/g) ].map((m) => m[1].replace(/\\"/g, '"'));
	return msgs.length ? msgs.join('\n')
		: String(raw).split('\n').filter((l) => l && !/level=(info|debug|warning)/.test(l) && !/test failed$/.test(l)).join('\n');
}

function jobErrorText(op, message) {
	const mapped = backendErrorText(message);
	return ['save-config', 'restore-config', 'connect', 'update-subscription', 'auto-update'].includes(op)
		&& /(?:^|\n)Mihomo rejected the configuration$/.test(String(message).trim())
		? mapped + ' ' + _('Nothing was changed, the previous configuration is still running.') : mapped;
}

function errorText(res) {
	const output = res?.stderr || res?.stdout;
	const message = String(output || res?.message || (typeof res === 'string' ? res : '')).replace(/^Error: /gm, '').trim();
	// Backend output is not a LuCI transport error, even if it mentions one.
	if (output || res?.name === 'CommandError' || res?.name === 'JobError')
		return backendErrorText(message) || _('Unknown error');
	if (res?.name === 'TimeoutError' || (res?.name === 'Error' && message === 'XHR request timed out'))
		return _('The router did not answer in time. The operation may still be running; check again in a minute.');
	// An expired session reaches us as SessionError, or as rpc error -32002.
	if (res?.name === 'PermissionError' || res?.name === 'SessionError' || (res?.name === 'Error' && message === 'Access denied')
		|| (res?.name === 'RPCError' && /failed with (?:ubus code 6:|HTTP error 403:|error -32002:)/.test(message)))
		return ACCESS_DENIED;
	return backendErrorText(message) || _('Unknown error');
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

// Every poll forks the backend on the router: poll gently.
async function waitJob(api, id, op) {
	let failures = 0;
	for (;;) {
		await new Promise(resolve => setTimeout(resolve, 2000));
		let status;
		try {
			status = await api.read('job-status', id);
			failures = 0;
		}
		catch (e) {
			if (++failures < 5)
				continue;
			throw new Error(errorText(e) === ACCESS_DENIED ? ACCESS_DENIED
				: _('Lost connection to the router while waiting for the result.'));
		}
		if (status.state === 'ok')
			return status.result;
		if (status.state === 'error')
			throw Object.assign(new Error(jobErrorText(op, status.error)), { name: 'JobError' });
	}
}

function modeLabel(mode) {
	return mode === 'proxy-first' ? _('All traffic via proxy except exclusions')
		: mode === 'direct-first' ? _('Only selected traffic via proxy')
		: _('unknown');
}

// Provider links as theme buttons (some themes leave a.cbi-button unstyled).
function linkButton(url, label) {
	if (!/^https?:\/\//i.test(String(url || '')))
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

function safeLink(url, label) {
	return /^https?:\/\//i.test(String(url || ''))
		? E('a', { href: String(url), target: '_blank', rel: 'noopener noreferrer' }, text(label))
		: null;
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

function confirm(title, body, okLabel, { danger = false } = {}) {
	return new Promise(resolve => {
		let settled = false;
		const finish = value => {
			if (settled)
				return;
			settled = true;
			ui.hideModal();
			resolve(value);
		};
		const cancel = E('button', { class: 'cbi-button', type: 'button' }, text(_('Cancel')));
		const ok = E('button', { class: 'cbi-button ' + (danger ? 'cbi-button-negative' : 'cbi-button-action'), type: 'button' }, text(okLabel));
		cancel.addEventListener('click', () => finish(false));
		ok.addEventListener('click', () => finish(true));
		ui.showModal(title, [
			E('p', text(body)),
			E('div', { class: 'mw-row right', style: 'justify-content: flex-end;' }, [ cancel, ' ', ok ])
		]);
	});
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
	jobLabel,
	// C16: the LuCI ACL gives this user read access only.
	readOnly: () => L.hasViewPermission?.() === false,
	job: async function(op, ...args) {
		for (const el of document.querySelectorAll?.('.mw-job') || [])
			el.replaceChildren ? el.replaceChildren() : (el.innerHTML = '');
		waitingJobs++;
		this.jobRunning = true;
		lockJobButtons();
		for (const el of document.querySelectorAll?.('.mw-job') || []) {
			const alert = E('div', { class: 'alert-message notice' }, [
				_('"%s" is running…').format(this.jobLabel(op)), ' ',
				E('span', { class: 'mw-muted' }, text(_('You can close the page — the operation continues on the router.')))
			]);
			el.replaceChildren ? el.replaceChildren(alert) : el.appendChild?.(alert);
		}
		try {
			const started = await this.write('job-start', op, ...args);
			let result;
			try {
				result = await waitJob(this, started.id, op);
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
			for (const el of document.querySelectorAll?.('.mw-job') || [])
				el.replaceChildren ? el.replaceChildren() : (el.innerHTML = '');
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
		// A reload would lose what the user typed meanwhile.
		let edited = false, alert;
		document.addEventListener?.('input', () => { edited = true; }, { once: true });
		const keepEdits = message => {
			alert.textContent = message;
			this.jobRunning = waitingJobs > 0;
			unlockJobButtons();
		};
		const failed = (status, error) => _('"%s" failed: %s').format(this.jobLabel(status.op), jobErrorText(status.op, error));
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
			alert = E('div', { class: 'alert-message notice' }, [
				_('"%s" is running…').format(this.jobLabel(status.op)), ' ',
				E('span', { class: 'mw-muted' }, text(_('You can close the page — the operation continues on the router.')))
			]);
			notice.appendChild(alert);
			try {
				await waitJob(this, status.id, status.op);
			}
			catch (e) {
				// A terminal job error still requires fresh page data. A lost
				// connection does not: keep its recovery message visible.
				if (e.name !== 'JobError') {
					alert.textContent = errorText(e);
					return;
				}
				markJobSeen(status.id);
				const message = failed(status, e.message || _('The operation failed.'));
				if (edited)
					keepEdits(message);
				else
					this.reloadWithNotice(message, 'error');
				return;
			}
			markJobSeen(status.id);
			if (edited)
				keepEdits(_('"%s" finished. Reload the page to see the result; your unsaved edits are still here.').format(this.jobLabel(status.op)));
			else
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
			throw new Error(_('The upload failed. Check your LuCI permissions and try again.'));
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
	modeLabel,
	linkButton,
	infoGrid,
	actionNotice,
	confirm,
	errorText,
	coreError,
	text,
	formatBytes,
	formatDate,
	trafficSummary,
	safeLink,
	toggle,
	busy,
	notify,
	style
});
