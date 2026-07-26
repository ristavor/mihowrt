#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

node <<'EOF'
const harness = require('./tests/js_luci_harness');

const formValues = {
	policy_mode: 'direct-first',
	source_network_interfaces: [ 'br-lan' ],
	dns_hijack: '1',
	disable_quic: '1',
	_always_proxy_dst: '203.0.113.9',
	_always_proxy_src: '',
	_direct_dst: ''
};

const uciValues = {
	policy_mode: 'direct-first',
	source_network_interfaces: [ 'br-lan' ],
	dns_hijack: '1',
	disable_quic: '1'
};

const map = {
	options: {},
	visibleDestinationValue: '',
	resetCount: 0,
	section() {
		return {
			option: (type, name) => {
				const option = {
					formvalue: () => formValues[name] ?? '',
					value: () => {},
					depends: () => {}
				};
				this.options[name] = option;
				return option;
			}
		};
	},
	async save() {
		await this.options._always_proxy_dst.write('settings', formValues._always_proxy_dst);
		// LuCI's Map.save() redraws here, before the view flushes deferred file writes.
		this.visibleDestinationValue = this.options._always_proxy_dst.cfgvalue('settings');
	},
	async reset() {
		this.resetCount++;
		this.visibleDestinationValue = this.options._always_proxy_dst.cfgvalue('settings');
	},
	render() {
		return Promise.resolve(this);
	}
};

const savedLists = [];
let remoteScheduleSyncs = 0;

const { module: page } = harness.evaluateLuCIModule(
	'rootfs/www/luci-static/resources/view/mihowrt/policy.js', {
		view: { extend: value => value },
		form: {
			Map: function() { return map; },
			NamedSection: function() {},
			ListValue: function() {},
			DynamicList: function() {},
			Flag: function() {},
			Button: function() {},
			TextValue: function() {}
		},
		uci: {
			get: (config, section, option) => uciValues[option],
			load: async () => {},
			changes: async () => ({})
		},
		fs: {
			read: async () => '',
			write: async () => {},
			remove: async () => {}
		},
		ui: {},
		network: {},
		backendHelper: {
			applyPolicyLists: async (values, reload) => {
				savedLists.push({ values, reload });
				return { changed: true, reloaded: reload };
			},
			syncPolicyRemoteAutoUpdate: async () => { remoteScheduleSyncs++; },
			updatePolicyLists: async () => false
		},
		mihowrtUi: {
			getServiceStatus: async () => true,
			notify: () => {}
		},
		document: undefined
	});

(async() => {
	await page.render([ null, '', '', '', [] ]);
	await page.handleSave();

	if (savedLists.length !== 1)
		throw new Error('saving a changed destination list should apply one list transaction');
	if (savedLists[0].values.dst !== '203.0.113.9\n')
		throw new Error('saving should normalize and persist the destination entry');
	if (map.resetCount !== 1)
		throw new Error('saving a deferred list write should redraw after its cache is committed');
	if (map.visibleDestinationValue !== '203.0.113.9\n')
		throw new Error('destination textarea should show the committed value without a page reload');
	if (remoteScheduleSyncs !== 1)
		throw new Error('saving a changed list should refresh its remote schedule state');
})().catch(err => {
	throw err;
});
EOF

pass "policy save keeps list UI in sync"
