'use strict';
'require view';
'require ui';
'require mihowrt.api as api';

const text = api.text;

const configNotice = action => action === 'unchanged' ? _('Configuration is unchanged.')
	: action === 'hot_reloaded' ? _('Configuration checked and applied.') : _('Configuration checked and saved.');

return view.extend({
	load: () => api.read('subscription-json').catch(e => ({ error: e })),

	render: function(sub) {
		if (sub?.error) {
			const again = E('button', { class: 'cbi-button', type: 'button' }, text(_('Try again')));
			again.addEventListener('click', () => location.reload());
			return E('div', { class: 'mw-page' }, [
				api.style(),
				E('h2', text(_('Subscription'))),
				api.jobNotice(),
				E('div', { class: 'alert-message error', role: 'alert' }, [
					E('p', text(_('Cannot load subscription settings: %s').format(api.errorText(sub.error)))),
					again
				])
			]);
		}
		const readOnly = api.readOnly();
		// type=text: some themes (openwrt-2020) style only text inputs.
		const url = E('input', { id: 'mw-url', type: 'text', inputmode: 'url', autocomplete: 'off', spellcheck: 'false',
			class: 'cbi-input-text', style: 'width: 100%',
			value: sub.url || '', placeholder: 'https://provider.example/sub/…' });
		const urlForm = E('form', { action: '', style: 'width: 100%' }, [ url ]);
		urlForm.addEventListener('submit', e => {
			e.preventDefault();
			if (readOnly)
				return;
			(url.value.trim() ? update : save).click();
		});
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
		const save = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-save' }, text(_('Save')));
		const update = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-action important' }, text(_('Update now')));
		const apply = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null, class: 'cbi-button cbi-button-apply' }, text(_('Check and apply')));
		// The YAML (up to 8 MiB) loads on the first opening of the editor.
		const editorBody = E('div', {});
		const editor = E('div', {}, [
			sub.url ? E('div', { class: 'alert-message warning' }, text(_('An update of the subscription (also automatic) replaces your edits.'))) : '',
			E('p', { class: 'mw-muted' }, text(_('MihoWRT manages ports, routing mark, TUN, the controller and the dashboard itself; those keys are overridden.'))),
			editorBody
		]);
		let yaml = null, original = null, loading = null;

		const onBeforeUnload = e => {
			if (yaml && yaml.value !== original) {
				e.preventDefault();
				e.returnValue = '';
			}
		};
		if (typeof window !== 'undefined' && window.addEventListener)
			window.addEventListener('beforeunload', onBeforeUnload);
		const dropGuard = () => {
			if (typeof window !== 'undefined' && window.removeEventListener)
				window.removeEventListener('beforeunload', onBeforeUnload);
		};

		const saveSettings = () => api.write('set-subscription', url.value.trim(), auto.checked ? '1' : '0');

		// Confirms run before api.busy: a modal dismissed from outside must not leave job buttons locked.
		const confirmOverwrite = async () => !(yaml && yaml.value !== original)
			|| api.confirm(_('Subscription update'), _('Updating replaces your unsaved YAML edits. Continue?'), _('Update'));

		const updateSubscription = async link => {
			const changed = link !== (sub.url || '');
			let res;
			if (!changed)
				await saveSettings();
			// A new link is saved only after it downloads and passes the check.
			try {
				res = await api.job('update-subscription', ...(changed ? [ link ] : []));
			}
			catch (e) {
				throw new Error(e.message + (changed && sub.url ? ' ' + _('The previous link is kept.') : ''));
			}
			if (changed)
				await saveSettings();
			dropGuard();
			api.reloadWithNotice(api.actionNotice(res.action));
		};

		save.addEventListener('click', async () => {
			if (save.disabled || api.jobRunning)
				return;
			const link = url.value.trim();
			const changed = link && link !== (sub.url || '');
			if (!link && sub.url && !await api.confirm(_('Stop using the subscription?'), _('MihoWRT keeps the current YAML, but it will no longer be updated.'), _('Disable'), { danger: true }))
				return;
			if (changed && !await confirmOverwrite())
				return;
			return api.busy(save, async () => {
				if (changed)
					return updateSubscription(link);
				await saveSettings();
				sub.url = link;
				api.notify(_('Subscription settings saved.'));
			});
		});
		update.addEventListener('click', async () => {
			if (update.disabled || api.jobRunning)
				return;
			const link = url.value.trim();
			if (link && !await confirmOverwrite())
				return;
			return api.busy(update, async () => {
				if (!link)
					throw new Error(_('Enter the subscription link, or press Save to stop using a subscription.'));
				return updateSubscription(link);
			});
		});
		apply.addEventListener('click', () => api.busy(apply, async () => {
			if (new Blob([yaml.value]).size > 8388608)
				throw new Error(_('The YAML is larger than 8 MiB.'));
			const path = await api.upload('mihowrt-config', yaml.value);
			const res = await api.job('save-config', path);
			dropGuard();
			api.reloadWithNotice(configNotice(res.action));
		}));

		const restore = E('button', { 'data-mw-job': '', disabled: api.jobRunning || null,
			class: 'cbi-button cbi-button-reset' }, text(_('Restore the previous YAML')));
		restore.addEventListener('click', async () => {
			if (restore.disabled || api.jobRunning)
				return;
			if (!await api.confirm(_('Restore the previous YAML'), _('Replace the current YAML with the previous one?'), _('Restore the previous YAML'), { danger: true }))
				return;
			return api.busy(restore, async () => {
				const res = await api.job('restore-config');
				dropGuard();
				api.reloadWithNotice(configNotice(res.action));
			});
		});
		const restoreNote = E('div', { class: 'cbi-value-description' },
			text(_('Automatic updates replace it again with the subscription.')));
		restoreNote.hidden = !auto.checked;
		auto.addEventListener('change', () => { describeAuto(); restoreNote.hidden = !auto.checked; });

		// Error state with a way forward; the region is busy while it loads.
		const loadError = (e, retry) => {
			const again = E('button', { class: 'cbi-button', type: 'button' }, text(_('Try again')));
			again.addEventListener('click', retry);
			return E('div', { class: 'alert-message error', role: 'alert' }, [
				E('p', text(_('Cannot load the YAML: %s').format(api.errorText(e)))), again ]);
		};
		const loadingState = box => {
			box.setAttribute('aria-busy', 'true');
			box.replaceChildren(E('p', { class: 'spinning' }, text(_('Loading…'))));
		};
		const readYaml = async cmd => {
			const reply = await api.readLarge(cmd);
			if (typeof reply?.content !== 'string')
				throw new Error(_('Unexpected response from the router.'));
			return reply;
		};
		const openEditor = () => {
			if (yaml || loading)
				return;
			loadingState(editorBody);
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
					...(readOnly ? [] : [ E('div', { class: 'mw-row' }, sub.config_backup ? [ apply, restore ] : [ apply ]) ]),
					...(sub.config_backup && !readOnly ? [ restoreNote ] : []));
			}).catch(e => {
				editorBody.replaceChildren(loadError(e, openEditor));
			}).finally(() => {
				editorBody.removeAttribute('aria-busy');
				loading = null;
			});
		};

		// Read-only: what Mihomo actually runs with, re-read on every opening.
		const runtime = E('div', {});
		let runtimeRequest = 0;
		const openRuntime = () => {
			// Only the latest opening may fill the view.
			const request = ++runtimeRequest;
			loadingState(runtime);
			readYaml('runtime-config').then(config => {
				if (request !== runtimeRequest)
					return;
				runtime.removeAttribute('aria-busy');
				const widget = new ui.Textarea(config.content, { id: 'mw-runtime', monospace: true, wrap: false, rows: 24, readonly: true }).render();
				const area = widget.querySelector('textarea');
				area.classList.add('mw-yaml');
				area.setAttribute('spellcheck', 'false');
				area.setAttribute('aria-label', _('YAML passed to Mihomo'));
				runtime.replaceChildren(
					E('p', { class: 'mw-muted' }, text(_('Generated by MihoWRT from your YAML: router keys replaced, default DNS and sniffer added when missing, x-mihowrt removed; the controller secret is hidden.'))),
					...(config.generated === true ? [ E('p', { class: 'mw-muted' }, text(_('MihoWRT is not running; this is what it would pass at start.'))) ] : []),
					widget);
			}).catch(e => {
				if (request !== runtimeRequest)
					return;
				runtime.removeAttribute('aria-busy');
				runtime.replaceChildren(loadError(e, openRuntime));
			});
		};

		return E('div', { class: 'mw-page' }, [
			api.style(),
			E('h2', text(_('Subscription'))),
			api.jobNotice(),
			E('div', { class: 'cbi-section' }, [
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title', for: 'mw-url' }, text(_('Subscription URL'))),
					E('div', { class: 'cbi-value-field' }, [ urlForm,
						E('div', { class: 'cbi-value-description' }, text(_('Link to a Clash/Mihomo (YAML) subscription from your provider. Leave empty to manage the YAML yourself.'))) ])
				]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title', for: 'mw-auto' }, text(_('Update automatically'))),
					E('div', { class: 'cbi-value-field' }, [ auto, autoHint ])
				]),
				...(readOnly ? [] : [ E('div', { class: 'cbi-value' }, [ E('label', { class: 'cbi-value-title' }, []),
					E('div', { class: 'cbi-value-field' }, [ E('div', { class: 'mw-row' }, [ save, update ]) ]) ]) ])
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
