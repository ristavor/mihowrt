'use strict';
'require baseclass';
'require fs';
'require ui';
'require rpc';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

async function probeServiceStatus(serviceScript) {
	if (!serviceScript)
		throw new Error(_('service probe unavailable'));

	const result = await fs.exec(serviceScript, [ 'running' ]);
	if (result.code === 0)
		return true;
	if (result.code === 1)
		return false;

	throw new Error(execErrorDetail(result));
}

async function getServiceStatus(serviceName, serviceScript) {
	const errors = [];
	let rpcRunning = null;

	try {
		const services = await callServiceList(serviceName);
		const instances = services[serviceName]?.instances || {};
		rpcRunning = !!Object.values(instances)[0]?.running;
		if (rpcRunning)
			return true;
	}
	catch (e) {
		errors.push(e.message || String(e));
	}

	if (serviceScript) {
		try {
			return await probeServiceStatus(serviceScript);
		}
		catch (e) {
			errors.push(e.message || String(e));
		}
	}

	if (rpcRunning != null)
		return rpcRunning;

	throw new Error(errors.join('; ') || _('unknown error'));
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
