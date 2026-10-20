'use strict';
'require view';
'require mihowrt.api as api';

const text = api.text;

return view.extend({
	load: () => Promise.all([
		api.read('subscription-json').catch(() => ({})),
		api.read('read-config').catch(() => ({ content: '' }))
	]),

	render: function([ sub, config ]) {
		const url = E('input', { id: 'mw-url', type: 'url', class: 'cbi-input-text', style: 'width: 100%',
			value: sub.url || '', placeholder: 'https://provider.example/sub/…' });
		const interval = E('input', { id: 'mw-interval', type: 'number', min: 0, max: 8760, class: 'cbi-input-text',
			style: 'width: 8em', value: sub.interval || '', placeholder: _('auto') });
		const save = E('button', { class: 'cbi-button cbi-button-save' }, text(_('Save')));
		const update = E('button', { class: 'cbi-button cbi-button-action important' }, text(_('Update now')));
		const yaml = E('textarea', { id: 'mw-yaml', class: 'mw-yaml', spellcheck: 'false', wrap: 'off' }, text(config.content));
		const apply = E('button', { class: 'cbi-button cbi-button-apply' }, text(_('Check and apply')));
		const original = config.content;

		const saveSettings = () => api.write('set-subscription', url.value.trim(), interval.value.trim());

		save.addEventListener('click', () => api.busy(save, async () => {
			await saveSettings();
			api.notify(_('Subscription settings saved.'));
		}));
		update.addEventListener('click', () => api.busy(update, async () => {
			if (yaml.value !== original && !confirm(_('Updating replaces your unsaved YAML edits. Continue?')))
				return;
			await saveSettings();
			const res = await api.write('update-subscription');
			api.notify(res.action === 'hot_reloaded' ? _('Subscription updated and applied.') : _('Subscription updated. Start MihoWRT to use it.'));
			location.reload();
		}));
		apply.addEventListener('click', () => api.busy(apply, async () => {
			const path = await api.upload('mihowrt-config', yaml.value);
			const res = await api.write('save-config', path);
			api.notify(res.action === 'hot_reloaded' ? _('Configuration checked and applied.') : _('Configuration checked and saved.'));
		}));

		return E('div', {}, [
			api.style(),
			E('h2', text(_('Subscription'))),
			E('div', { class: 'cbi-section' }, [
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title', for: 'mw-url' }, text(_('Subscription URL'))),
					E('div', { class: 'cbi-value-field' }, [ url,
						E('div', { class: 'cbi-value-description' }, text(_('Link from your VPN provider. Leave empty to manage the YAML yourself.'))) ])
				]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title', for: 'mw-interval' }, text(_('Update every (hours)'))),
					E('div', { class: 'cbi-value-field' }, [ interval,
						E('div', { class: 'cbi-value-description' }, text(
							_('Empty: use the provider\'s interval (now %d h). 0: never update automatically.').format(sub.effective_interval || 24))) ])
				]),
				E('div', { class: 'mw-row' }, [ save, update ])
			]),
			E('details', { class: 'cbi-section' }, [
				E('summary', text(_('Advanced: edit the Mihomo YAML'))),
				E('p', { class: 'mw-muted' }, text(_('MihoWRT manages ports, routing mark, TUN and the controller itself; those keys are overridden. Updating the subscription replaces this file.'))),
				yaml,
				E('div', { class: 'mw-row' }, [ apply ])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
