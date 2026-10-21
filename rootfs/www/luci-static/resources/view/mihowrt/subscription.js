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
		const auto = E('input', { id: 'mw-auto', type: 'checkbox', checked: sub.auto_update !== false ? '' : null });
		const autoHint = E('div', { class: 'cbi-value-description' });
		// The header period also counts while auto-update is still off.
		const header = Number(sub.header_interval);
		const period = sub.effective_interval > 0 ? sub.effective_interval : (header >= 1 && header <= 8760 ? header : 0);
		const describeAuto = () => {
			autoHint.textContent = !auto.checked ? _('Only when you press Update now.')
				: period > 0 ? _('Your provider decides how often (now every %d h).').format(period)
				: _('Your provider does not set an update period, so the subscription is updated only when you press Update now.');
		};
		describeAuto();
		auto.addEventListener('change', describeAuto);
		const save = E('button', { class: 'cbi-button cbi-button-save' }, text(_('Save')));
		const update = E('button', { class: 'cbi-button cbi-button-action important' }, text(_('Update now')));
		const yaml = E('textarea', { id: 'mw-yaml', class: 'mw-yaml', spellcheck: 'false', wrap: 'off' }, text(config.content));
		const apply = E('button', { class: 'cbi-button cbi-button-apply' }, text(_('Check and apply')));
		const original = config.content;

		const saveSettings = () => api.write('set-subscription', url.value.trim(), auto.checked ? '1' : '0');

		save.addEventListener('click', () => api.busy(save, async () => {
			await saveSettings();
			api.notify(_('Subscription settings saved.'));
		}));
		update.addEventListener('click', () => api.busy(update, async () => {
			if (yaml.value !== original && !confirm(_('Updating replaces your unsaved YAML edits. Continue?')))
				return;
			await saveSettings();
			const res = await api.write('update-subscription');
			api.notify(res.action === 'unchanged' ? _('Subscription is up to date.')
				: res.action === 'hot_reloaded' ? _('Subscription updated and applied.') : _('Subscription updated. Start MihoWRT to use it.'));
			location.reload();
		}));
		apply.addEventListener('click', () => api.busy(apply, async () => {
			const path = await api.upload('mihowrt-config', yaml.value);
			const res = await api.write('save-config', path);
			api.notify(res.action === 'unchanged' ? _('Configuration is unchanged.')
				: res.action === 'hot_reloaded' ? _('Configuration checked and applied.') : _('Configuration checked and saved.'));
		}));

		return E('div', { class: 'mw-page' }, [
			api.style(),
			E('h2', text(_('Subscription'))),
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
			E('details', { class: 'cbi-section' }, [
				E('summary', text(_('Advanced: edit the Mihomo YAML'))),
				E('p', { class: 'mw-muted' }, text(_('MihoWRT manages ports, routing mark, TUN, the controller and the dashboard itself; those keys are overridden. Updating the subscription, including automatic updates, replaces this file.'))),
				yaml,
				E('div', { class: 'mw-row' }, [ apply ])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
