'use strict';
'require baseclass';

function errorDetail(result) {
	// Preserve stderr/stdout detail from fs.exec results for LuCI notifications.
	const detail = String(result?.stderr || result?.stdout || '').trim();
	return detail || _('unknown error');
}

return baseclass.extend({
	errorDetail: errorDetail
});
