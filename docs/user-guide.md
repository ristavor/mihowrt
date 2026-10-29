# MihoWRT user guide

[Quick start](../README.md) · [Technical reference](reference.md)

## Pages

| Page | What it does |
|---|---|
| Overview | First-run *Connect a subscription* card, status, traffic and expiry, proxy group selection with latency test, start/stop, dashboard, core update |
| Subscription | Subscription link and *Update automatically*; *Advanced* holds the YAML editor (*Check and apply*, up to 8 MiB) and *Restore the previous YAML* |
| Traffic | Mode (read-only), lists of the active mode, devices from DHCP leases (by MAC or IP), provider settings with *Use my own value*; *Advanced* holds interfaces, DNS redirect, QUIC block, *Block external IPv6 from clients*, NTP and subscription DNS bypass, NetBird, *Mihomo log level*, and *Mihomo dashboard*. One *Save & Apply* button applies lists and settings together |
| Diagnostics | Checklist with fixes (core, config, service state and last error, DNS answers, rules, conflicting dnsmasq servers, conflicting proxy packages, free flash and RAM, open proxy ports), details (including Mihomo memory) and log |

### Dashboard

The optional Mihomo web panel (zashboard) is off on fresh installs. Start MihoWRT, then press *Install dashboard* on Overview; the download restarts the running service. After installation press *Open dashboard* (it does not open automatically). Remove it under Traffic → Advanced → Mihomo dashboard. The measured installed size was 5284 KiB; it is not needed for MihoWRT. Existing installations with a non-empty dashboard directory retain it during migration. Installation while stopped is refused immediately.

### Background jobs

Long actions (connect, core update, subscription update, list refresh, saving
the YAML or the lists, dashboard install/remove, start/stop/restart) run in the background, one at a
time, so a slow router or a closed browser tab does not interrupt them. The page
polls the result; every page shows a notice while a job is running. A second
action during that time is refused with *Another operation is running*. If the
router reboots mid-way, the job is reported as interrupted; every action is safe
to run again. The status block of Overview refreshes every 10 seconds while the tab is visible. A completed job does not reload a page with unsaved edits: reload it yourself after saving or discarding them.

### Editing the YAML

The editor on the *Subscription* page takes a YAML up to 8 MiB. This is an upload limit, not a RAM guarantee: on 128–256 MiB keep the YAML small. The 8 MiB VM fixture ran out of memory on 128 MiB (including older builds) and on 256 MiB; 512 MiB succeeded. An empty YAML is
refused and nothing is changed. *Restore the previous YAML* puts
`config.yaml.bak` back (the current one becomes the new backup, so restore can
be undone). A subscription update or an automatic update replaces the YAML
again. The YAML is loaded when you open the editor; if it cannot be loaded, the
editor is not shown, so a broken page can never overwrite it.

*Show the YAML passed to Mihomo* shows, read-only, the generated
`/tmp/mihowrt/config.yaml` (router keys replaced, default DNS and sniffer
added, `x-mihowrt` removed). When MihoWRT has not started since boot, it shows
what would be passed at start.

### Devices

*Devices via proxy* / *Devices always direct* take **MAC addresses**
(`aa:bb:cc:dd:ee:ff`, any case) or **IP addresses**, mixed in one list. The
lease picker adds a device as *MAC (IPv4 + IPv6)* (default) or *IP address*.
Devices with a private (randomized) Wi-Fi MAC are marked *private MAC* in the
picker, and the field description says how to keep it fixed for your network.
One MAC entry covers IPv4 and IPv6 of the device; an IPv4 entry never
covers its IPv6 traffic, and IPv6 privacy addresses change daily anyway.
Address lists (*Addresses ...*) accept no MAC.

Phones and laptops use a private (random) Wi-Fi address per network:

- Keep a fixed address for this network: iPhone, iPad, Mac: *Private Wi-Fi
  Address* = *Fixed*; Android: *Use randomized MAC* (kept per network); Windows:
  *Random hardware addresses*, not *Change daily*. Rotating modes (Apple
  *Rotating*, Android non-persistent) break the entry.
- The address changes after *Forget this network* or a reset. A new MAC also gets
  a new DHCP lease, so IPv4 entries and static leases break the same way.
- A device that changes its address drops out of the list and gets the
  default of the mode: direct in *Only selected traffic via proxy*, via proxy in
  *All traffic via proxy*. Nothing breaks. The page shows entries that are not in
  the current DHCP leases as *Not connected now* (MAC and IPv4 only).
- MAC entries work only for devices in the router's own L2 network. Behind
  another router or a mesh node in router mode the router sees the MAC of that
  router or node, not of the device, so MAC entries do not match; use IP entries
  there.

### Modes

The mode follows the DNS settings of your YAML; there is no switch:

- **Only selected traffic via proxy**: only when `dns.enhanced-mode` is
  `fake-ip` and `dns.fake-ip-filter-mode` is `whitelist`. Addresses and
  devices from the lists, plus domains that Mihomo answers with a fake-IP
  (usually the blocked sites of your subscription), go to Mihomo. Everything
  else is direct.
- **All traffic via proxy except exclusions**: every other case (blacklist or
  rule filter, `redir-host`, `normal`, no `dns` section). All TCP/UDP goes to
  Mihomo, except *Addresses always direct* and *Devices always direct*.
  *Devices always direct* bypasses Mihomo for real destinations. With fake-IP
  DNS, connections to fake addresses use the `mihowrt-direct` TPROXY listener
  on port 7895 and its first `IN-NAME,mihowrt-direct,DIRECT` rule: Mihomo resolves the real
  destination and sends the connection DIRECT. `redir-host` / `normal` retain
  full nft bypass. QUIC blocking still applies to fake destinations when enabled.
  The `IN-NAME` rule applies only in Mihomo `mode: rule`; `global` and `direct`
  modes ignore rules.

In *All traffic via proxy except exclusions*, traffic originated by the router itself (such as WireGuard client tunnels, DDNS updates with `ip_source=web` which would register the proxy's IP, and Tailscale connections) is also intercepted and routed through Mihomo. To keep these direct, add their remote endpoints and server addresses to *Addresses always direct* (`direct_dst`).

With fake-IP DNS, client queries receive synthetic `198.18.x.x` addresses. If your Mihomo rules send private ranges `DIRECT` (for example `GEOIP,private,DIRECT` or `IP-CIDR,192.168.0.0/16,DIRECT`), Mihomo resolves the hostname internally and connects from the router via local output. This bypasses dnsmasq DNS rebind protection and firewall guest→LAN isolation for those queries.

Apart from the dedicated fake-IP direct-device inbound, Mihomo's own rules
decide the outbound (proxy group or DIRECT). Domain filtering remains the
provider's job; MihoWRT does not add vendor/private domains to `fake-ip-filter`.
The name `mihowrt-direct` is reserved: a same-named provider listener is replaced
with a warning when injection succeeds. For proxy-first fake-IP, `listeners` and
`rules` support block lists (empty `[]` / null are accepted). Unsupported forms
(non-empty flow lists, aliases/anchors, flow listener items, escaped listener
names or duplicate top-level lists) leave the runtime YAML unchanged from
normal generation, with one warning and no direct-listener injection. The
subscription still applies, but *Devices always direct* is unavailable with
fake-IP DNS, as before this feature; those devices follow the normal policy.

### Provider settings

A subscription can supply router settings through [`x-mihowrt`](reference.md#provider-settings-x-mihowrt). On Traffic, *Use my own value* overrides a provider value; list selectors offer *Provider list*, *Provider list + mine* or *Only mine*. Your saved list is not deleted when it is inactive.

### Client IPv6

*Block external IPv6 from clients* (Traffic → Advanced, default off) rejects
external IPv6 from selected client interfaces only when it bypasses Mihomo,
and only in **Only selected traffic via proxy** mode. IPv6 selected by address,
device or port lists still reaches Mihomo. IPv6 DNS hijack remains active;
Mihomo IPv6 and DNS behaviour belongs to the provider's `ipv6` / `dns.ipv6` keys.
In **All traffic via proxy except exclusions** mode the flag has no effect.

Set `x-mihowrt.block-client-ipv6: true` in the provider block, or use the existing
*Use my own value* control. Router-originated and Mihomo traffic, IPv4 and
NetBird ingress are unchanged. Local destinations use the existing local-network
exclusions and remain subject to fw4 rules. External TCP gets a reset; other
IPv6 gets ICMPv6 administratively prohibited. This does not disable kernel IPv6
or guarantee an application's IPv4 fallback. Existing offloaded connections may
continue until expiry. Stop, cleanup and watchdog fail-open remove the policy.

### Lists

One entry per line, IPv4 or IPv6:

```text
1.1.1.1
8.8.8.0/24
2001:db8::/32
9.9.9.9;443          # only these ports
;53                  # any address, these ports
https://example.com/list.txt;443   # remote list, cached on flash
# comment
```

Remote lists (up to 1 MiB each, 32 URLs, 8 MiB total cache) are refreshed every *Update remote lists
every (hours)* (24 for new installs; existing installs keep their value) or
with the button. Applying policy never waits for the network: it uses the cache.
A failed refresh reports an error even if some lists updated successfully; old caches are kept for the failed downloads. A semicolon must be followed by ports (`1.2.3.4;` is invalid).

Provider list entries are validated the same way; invalid ones are dropped
with a warning.

## If internet is lost

1. Open LuCI at your router address (usually `http://192.168.1.1`) — LuCI remains accessible without an internet connection.
2. Go to **Services → MihoWRT → Overview** and press **Stop**, or run `service mihowrt stop` over SSH.
3. Stopping cleanly removes MihoWRT DNS redirection and policy routing rules, restoring direct internet access immediately.
4. If connectivity is restored, the issue is in your subscription, rules or nodes: check **Diagnostics** or read the journal with `logread -e mihowrt` (in LuCI: **Status → System Log**).
5. "Stop" persists until reboot. To disable autostart across reboots, run `service mihowrt disable` over SSH.

