'use strict';
'require view';
'require ui';
'require mihowrt.api as api';

const text = api.text;

return view.extend({
	load: () => Promise.all([
		api.read('subscription-json').catch(() => ({})),
		api.read('status-json').catch(() => ({}))
	]),

	render: function([ sub, status = {} ]) {
		// type=text: some themes (openwrt-2020) style only text inputs.
		const url = E('input', { id: 'mw-url', type: 'text', inputmode: 'url', autocomplete: 'off', spellcheck: 'false',
			class: 'cbi-input-text', style: 'width: 100%',
			value: sub.url || '', placeholder: 'https://provider.example/sub/…' });
		const auto = E('input', { id: 'mw-auto', type: 'checkbox', checked: sub.auto_update !== false ? '' : null });
		const autoHint = E('div', { class: 'cbi-value-description' });
		// The header period also counts while auto-update is still off.
		const header = Number(sub.header_interval);
		const period = sub.effective_interval > 0 ? sub.effective_interval : (header >= 1 && header <= 8760 ? header : 0);
		const savedAuto = sub.auto_update !== false;
		const describeAuto = () => {
			autoHint.textContent = (!auto.checked ? _('Only when you press Update now.')
				: period > 0 ? _('Your provider decides how often (now every %d h).').format(period)
				: _('Your provider does not set an update period, so the subscription is updated only when you press Update now.'))
				+ (auto.checked !== savedAuto ? ' ' + _('Not saved yet: press Save or Update now.') : '');
		};
		describeAuto();
		const save = E('button', { class: 'cbi-button cbi-button-save' }, text(_('Save')));
		const update = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-action important' }, text(_('Update now')));
		const apply = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-apply' }, text(_('Check and apply')));
		// The YAML (up to 8 MiB) loads on the first opening of the editor.
		const editorBody = E('div', {});
		const editor = E('div', {}, [
			E('p', { class: 'mw-muted' }, text(_('MihoWRT manages ports, routing mark, TUN, the controller and the dashboard itself; those keys are overridden. Updating the subscription, including automatic updates, replaces this file.'))),
			editorBody
		]);
		let yaml = null, original = null, loading = null;

		const saveSettings = () => api.write('set-subscription', url.value.trim(), auto.checked ? '1' : '0');

		save.addEventListener('click', () => api.busy(save, async () => {
			await saveSettings();
			api.notify(_('Subscription settings saved.'));
		}));
		update.addEventListener('click', () => api.busy(update, async () => {
			if (yaml && yaml.value !== original && !confirm(_('Updating replaces your unsaved YAML edits. Continue?')))
				return;
			const link = url.value.trim();
			const changed = link !== (sub.url || '');
			let res;
			if (!changed)
				await saveSettings();
			// A new link is saved only after it downloads and passes the check.
			try {
				res = await api.job('update-subscription', ...(changed ? [ link ] : []));
			}
			catch (e) {
				throw new Error(api.subscriptionError(e.message) + (changed && sub.url ? ' ' + _('The previous link is kept.') : ''));
			}
			if (changed)
				await saveSettings();
			api.reloadWithNotice(api.actionNotice(res.action));
		}));
		apply.addEventListener('click', () => api.busy(apply, async () => {
			if (new Blob([yaml.value]).size > 8388608)
				throw new Error(_('The YAML is larger than 8 MiB.'));
			const path = await api.upload('mihowrt-config', yaml.value);
			const res = await api.job('save-config', path);
			api.reloadWithNotice(res.action === 'unchanged' ? _('Configuration is unchanged.')
				: res.action === 'hot_reloaded' ? _('Configuration checked and applied.') : _('Configuration checked and saved.'));
		}));

		const restore = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null,
			class: 'cbi-button cbi-button-reset' }, text(_('Restore the previous YAML')));
		restore.addEventListener('click', () => api.busy(restore, async () => {
			if (!confirm(_('Replace the current YAML with the previous one?')))
				return;
			const res = await api.job('restore-config');
			api.reloadWithNotice(res.action === 'unchanged' ? _('Configuration is unchanged.')
				: res.action === 'hot_reloaded' ? _('Configuration checked and applied.') : _('Configuration checked and saved.'));
		}));
		const restoreNote = E('div', { class: 'cbi-value-description' },
			text(_('Automatic updates replace it again with the subscription.')));
		restoreNote.hidden = !auto.checked;
		auto.addEventListener('change', () => { describeAuto(); restoreNote.hidden = !auto.checked; });

		const loadError = e => E('div', { class: 'alert-message error' }, text(_('Cannot load the YAML: %s').format(api.errorText(e))));
		const readYaml = async cmd => {
			const reply = await api.readLarge(cmd);
			if (typeof reply?.content !== 'string')
				throw new Error(_('Unexpected response from the router.'));
			return reply;
		};
		const openEditor = () => {
			if (yaml || loading)
				return;
			editorBody.replaceChildren(E('p', { class: 'spinning' }, text(_('Loading…'))));
			loading = readYaml('read-config').then(config => {
				// LuCI's own monospace textarea (as for code fields on stock pages).
				const widget = new ui.Textarea(config.content, { id: 'mw-yaml', monospace: true, wrap: false, rows: 24 }).render();
				yaml = widget.querySelector('textarea');
				yaml.classList.add('mw-yaml');
				yaml.setAttribute('spellcheck', 'false');
				original = config.content;
				editorBody.replaceChildren(
					E('label', { class: 'cbi-value-title', for: 'widget.mw-yaml' }, text(_('Mihomo YAML'))),
					widget,
					E('div', { class: 'mw-row' }, status.config_backup ? [ apply, restore ] : [ apply ]),
					...(status.config_backup ? [ restoreNote ] : []));
			}).catch(e => {
				editorBody.replaceChildren(loadError(e));
			}).finally(() => {
				loading = null;
			});
		};

		// Read-only: what Mihomo actually runs with, re-read on every opening.
		const runtime = E('div', {});
		const openRuntime = () => {
			runtime.replaceChildren(E('p', { class: 'spinning' }, text(_('Loading…'))));
			readYaml('runtime-config').then(config => {
				const widget = new ui.Textarea(config.content, { id: 'mw-runtime', monospace: true, wrap: false, rows: 24, readonly: true }).render();
				const area = widget.querySelector('textarea');
				area.classList.add('mw-yaml');
				area.setAttribute('spellcheck', 'false');
				area.setAttribute('aria-label', _('YAML passed to Mihomo'));
				runtime.replaceChildren(
					E('p', { class: 'mw-muted' }, text(_('Generated by MihoWRT from your YAML: router keys replaced, default DNS and sniffer added when missing, x-mihowrt removed. It contains the controller secret.'))),
					...(config.generated === true ? [ E('p', { class: 'mw-muted' }, text(_('MihoWRT is not running; this is what it would pass at start.'))) ] : []),
					widget);
			}).catch(e => {
				runtime.replaceChildren(loadError(e));
			});
		};

		return E('div', { class: 'mw-page' }, [
			api.style(),
			E('h2', text(_('Subscription'))),
			api.jobNotice(),
			E('div', { class: 'cbi-section' }, [
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title', for: 'mw-url' }, text(_('Subscription URL'))),
					E('div', { class: 'cbi-value-field' }, [ url,
						E('div', { class: 'cbi-value-description' }, text(_('Link to a Clash/Mihomo (YAML) subscription from your provider. Leave empty to manage the YAML yourself.'))) ])
				]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title', for: 'mw-auto' }, text(_('Update automatically'))),
					E('div', { class: 'cbi-value-field' }, [ auto, autoHint ])
				]),
				E('div', { class: 'cbi-value' }, [ E('label', { class: 'cbi-value-title' }, []),
					E('div', { class: 'cbi-value-field' }, [ E('div', { class: 'mw-row' }, [ save, update ]) ]) ])
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', text(_('Advanced: edit the Mihomo YAML'))),
				api.toggle(_('Show the YAML editor'), _('Hide the YAML editor'), editor, openEditor),
				api.toggle(_('Show the YAML passed to Mihomo'), _('Hide the YAML passed to Mihomo'), runtime, openRuntime)
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
