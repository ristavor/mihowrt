'use strict';
'require baseclass';

function errorDetail(result) {
	const detail = String(result?.stderr || result?.stdout || '').trim();
	return detail || _('unknown error');
}

return baseclass.extend({
	errorDetail: errorDetail
});
