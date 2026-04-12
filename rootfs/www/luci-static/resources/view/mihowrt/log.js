'use strict';
'require view';
'require poll';
'require fs';
'require mihowrt.ace as aceHelper';

let editor = null;
let loggerPath = null;

async function initializeAceEditor(node) {
	editor = await aceHelper.createEditor(node, 'text', {
		fontSize: '11px',
		readOnly: true,
	});

	poll.add(() => {
		if (!loggerPath)
			return Promise.resolve();

		return fs.exec_direct(loggerPath, ['-e', 'mihowrt']).then(res => {
			editor.setValue(res || _('No logs yet.'), -1);
			editor.scrollToLine(editor.session.getLength(), false, true, function() {});
		}).catch(err => {
			editor.setValue(_('Error reading logs: %s').format(err.message), -1);
		});
	});
}

return view.extend({
	load: function() {
		return fs.stat('/sbin/logread').then(stat => {
			loggerPath = stat && stat.path ? stat.path : null;
		}).catch(() => {
			loggerPath = null;
		});
	},

	render: function() {
		const logNode = E('div', {
			id: 'logfile',
			style: 'width: 100% !important; height: 640px;'
		});
		const page = E('div', { class: 'cbi-map' }, [
			E('div', { class: 'cbi-section' }, [
				logNode
			])
		]);

		window.requestAnimationFrame(() => {
			initializeAceEditor(logNode).catch(err => {
				logNode.textContent = _('Unable to initialize log viewer: %s').format(err.message);
			});
		});

		return page;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
