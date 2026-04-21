'use strict';
'require baseclass';
'require ui';
'require rpc';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

async function getServiceStatus(serviceName) {
	try {
		const services = await callServiceList(serviceName);
		const instances = services[serviceName]?.instances || {};
		return Object.values(instances)[0]?.running || false;
	}
	catch (e) {
		return false;
	}
}

function execErrorDetail(result) {
	const detail = String(result?.stderr || result?.stdout || '').trim();
	return detail || _('unknown error');
}

function notify(message, level) {
	ui.addNotification(null, E('p', message), level);
}

return baseclass.extend({
	getServiceStatus: getServiceStatus,
	execErrorDetail: execErrorDetail,
	notify: notify
});
