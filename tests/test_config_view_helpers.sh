#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const vm = require('vm');
const harness = require('./tests/js_luci_harness');
const { assertEq } = harness;

const viewSource = harness.readSource('rootfs/www/luci-static/resources/view/mihowrt/config.js');
if (viewSource.includes('window.location.reload()'))
	throw new Error('config.js should not do full page reloads after local actions');
if (!viewSource.includes('external-controller-unix: /tmp/clash/mihomo.sock'))
	throw new Error('config.js should show the tmpfs Mihomo socket path');
if (!viewSource.includes('./ruleset/') || !viewSource.includes('./proxy_providers/'))
	throw new Error('config.js should show tmpfs provider paths');
if (viewSource.includes('cache.db'))
	throw new Error('config.js should not show cache.db naming guidance');

const { module: configHelper } = harness.evaluateLuCIModule('rootfs/www/luci-static/resources/mihowrt/config.js');

function assertHostPort(addr, expectedHost, expectedPort, message) {
	const actual = configHelper.normalizeHostPortFromAddr(addr, 'router.lan', '9090');
	assertEq(actual.host, expectedHost, `${message} host`);
	assertEq(actual.port, expectedPort, `${message} port`);
}

assertHostPort('127.0.0.1:9090', 'router.lan', '9090', 'IPv4 loopback should use LuCI host');
assertHostPort('127.2.3.4:9090', 'router.lan', '9090', 'Any 127/8 loopback should use LuCI host');
assertHostPort('[::1]:9090', 'router.lan', '9090', 'IPv6 loopback should use LuCI host');
assertHostPort('localhost:9090', 'router.lan', '9090', 'localhost should use LuCI host');
assertHostPort('0.0.0.0:9090', 'router.lan', '9090', 'Wildcard IPv4 should use LuCI host');
assertHostPort('[::]:9090', 'router.lan', '9090', 'Wildcard IPv6 should use LuCI host');
assertHostPort('192.168.1.10:9090', '192.168.1.10', '9090', 'Remote controller host should stay unchanged');
assertHostPort('', 'router.lan', '9090', 'Empty controller should keep fallback host/port');

assertEq(configHelper.dashboardUrl({
	externalController: '[2001:db8::1]:9090',
	externalControllerTls: '',
	secret: 'top-secret',
	externalUi: '',
	externalUiName: 'zashboard'
}, 'router.lan').startsWith('http://[2001:db8::1]:9090/zashboard/?'), true, 'dashboardUrl should keep IPv6 host bracketed');
assertEq(configHelper.editorContentForSave('line 1\n\n  tail  '), 'line 1\n\n  tail  ', 'editorContentForSave should preserve whitespace and blank lines');
assertEq(configHelper.editorContentForSave('plain'), 'plain', 'editorContentForSave should not force trailing newline');
assertEq(configHelper.editorContentForSave(null), '', 'editorContentForSave should map null to empty string');
assertEq(configHelper.subscriptionStateErrorDetail({ errors: ['first', '', 'second'] }), 'first; second', 'subscriptionStateErrorDetail should join non-empty errors');
assertEq(configHelper.subscriptionStateErrorDetail({ errors: [] }), 'unknown error', 'subscriptionStateErrorDetail should fallback on empty errors');
assertEq(configHelper.subscriptionUrlInputValue({ value: ' https://example.com/sub.yaml ' }), 'https://example.com/sub.yaml', 'subscriptionUrlInputValue should trim pasted URLs');
assertEq(configHelper.subscriptionUrlInputValue({}), '', 'subscriptionUrlInputValue should tolerate empty inputs');
assertEq(configHelper.serviceToggleLabel(true), 'Stop MihoWRT', 'serviceToggleLabel should render running action');
assertEq(configHelper.serviceToggleLabel(false), 'Start MihoWRT', 'serviceToggleLabel should render stopped action');
assertEq(configHelper.serviceEnabledToggleLabel(true), 'Disable Autostart', 'serviceEnabledToggleLabel should render disable-boot action');
assertEq(configHelper.serviceEnabledToggleLabel(false), 'Enable Autostart', 'serviceEnabledToggleLabel should render enable-boot action');
assertEq(configHelper.serviceBadgeText(true), 'MihoWRT is running', 'serviceBadgeText should render running badge');
assertEq(configHelper.serviceBadgeText(false), 'MihoWRT stopped', 'serviceBadgeText should render stopped badge');
assertEq(configHelper.serviceBadgeColor(true), '#5cb85c', 'serviceBadgeColor should use running color');
assertEq(configHelper.serviceBadgeColor(false), '#d9534f', 'serviceBadgeColor should use stopped color');

const busyMatch = viewSource.match(/function controlsBusy[\s\S]*?\n}\n\nfunction updateControlDisabledState/);
if (!busyMatch)
	throw new Error('controlsBusy() not found');

const context = harness.createContext();
vm.runInContext(`
let serviceActionInFlight = false;
let saveInFlight = false;
let subscriptionInFlight = false;
${busyMatch[0].replace(/\n\nfunction updateControlDisabledState$/, '')}
globalThis.controlsBusy = controlsBusy;
globalThis.setBusyFlags = (serviceBusy, saveBusy, subscriptionBusy) => {
	serviceActionInFlight = serviceBusy;
	saveInFlight = saveBusy;
	subscriptionInFlight = subscriptionBusy;
};
`, context);

context.setBusyFlags(false, false, false);
assertEq(String(context.controlsBusy()), 'false', 'controlsBusy should be false when no action is running');
context.setBusyFlags(true, false, false);
assertEq(String(context.controlsBusy()), 'true', 'controlsBusy should be true when service action is running');
context.setBusyFlags(false, true, false);
assertEq(String(context.controlsBusy()), 'true', 'controlsBusy should be true when save is running');
context.setBusyFlags(false, false, true);
assertEq(String(context.controlsBusy()), 'true', 'controlsBusy should be true when subscription action is running');

(async () => {
	const notifications = [];
	let openedUrl = null;
	let probedScript = null;

	await configHelper.openDashboard({
		serviceName: 'mihowrt',
		serviceScript: '/etc/init.d/mihowrt',
		backendHelper: {
			readConfig: async() => ({ errors: ['Failed to read config'] })
		},
		uiHelper: {
			getServiceStatus: async(serviceName, serviceScript) => {
				probedScript = `${serviceName}:${serviceScript}`;
				return true;
			},
			notify: (message, level) => notifications.push({ message, level })
		},
		windowObject: {
			location: { hostname: 'router.lan' },
			open: (url) => {
				openedUrl = url;
				return {};
			}
		}
	});

	assertEq(String(openedUrl), 'null', 'openDashboard should not open guessed URL when config has errors');
	assertEq(notifications.length, 1, 'openDashboard should emit one notification when config has errors');
	assertEq(notifications[0].level, 'error', 'openDashboard should surface config errors as error notification');
	assertEq(probedScript, 'mihowrt:/etc/init.d/mihowrt', 'openDashboard should probe service with init script fallback context');
	if (!String(notifications[0].message).includes('Failed to read config'))
		throw new Error('openDashboard should include backend config error details');

	const ipv6Notifications = [];
	let ipv6OpenedUrl = null;
	await configHelper.openDashboard({
		serviceName: 'mihowrt',
		serviceScript: '/etc/init.d/mihowrt',
		backendHelper: {
			readConfig: async() => ({
				errors: [],
				externalController: '[2001:db8::1]:9090',
				externalControllerTls: '',
				secret: 'top-secret',
				externalUi: '',
				externalUiName: 'zashboard'
			})
		},
		uiHelper: {
			getServiceStatus: async() => true,
			notify: (message, level) => ipv6Notifications.push({ message, level })
		},
		windowObject: {
			location: { hostname: 'router.lan' },
			open: (url) => {
				ipv6OpenedUrl = url;
				return {};
			}
		}
	});

	assertEq(ipv6Notifications.length, 0, 'openDashboard should not warn on valid IPv6 controller config');
	if (!String(ipv6OpenedUrl).startsWith('http://[2001:db8::1]:9090/zashboard/?'))
		throw new Error(`openDashboard should keep IPv6 host bracketed, got '${ipv6OpenedUrl}'`);

	const liveNotifications = [];
	let liveOpenedUrl = null;
	await configHelper.openDashboard({
		serviceName: 'mihowrt',
		serviceScript: '/etc/init.d/mihowrt',
		backendHelper: {
			readLiveApiConfig: async() => ({
				errors: [],
				externalController: '127.0.0.1:9191',
				externalControllerTls: '',
				secret: 'old-secret',
				externalUi: '',
				externalUiName: 'ui-old'
			}),
			readConfig: async() => ({
				errors: [],
				externalController: '192.168.1.1:9090',
				externalControllerTls: '',
				secret: 'new-secret',
				externalUi: '',
				externalUiName: 'ui-new'
			})
		},
		uiHelper: {
			getServiceStatus: async() => true,
			notify: (message, level) => liveNotifications.push({ message, level })
		},
		windowObject: {
			location: { hostname: 'router.lan' },
			open: (url) => {
				liveOpenedUrl = url;
				return {};
			}
		}
	});

	assertEq(liveNotifications.length, 0, 'openDashboard should not warn when live API state is available');
	if (!String(liveOpenedUrl).startsWith('http://router.lan:9191/ui-old/?'))
		throw new Error(`openDashboard should use live API endpoint before manual restart, got '${liveOpenedUrl}'`);
	if (!String(liveOpenedUrl).includes('secret=old-secret'))
		throw new Error('openDashboard should use live API secret before manual restart');
})().catch(err => {
	throw err;
});
EOF

pass "config view helpers"
