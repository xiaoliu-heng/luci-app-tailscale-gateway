import * as fs from 'fs';
import { ROOT, RUN, STATE, read_json, save_json, revision, section, config_cursor } from '../root/usr/share/tailscale-gateway/common.uc';
import { configuration, collect } from '../root/usr/share/tailscale-gateway/state.uc';
import { validate, make_plan } from '../root/usr/share/tailscale-gateway/planner.uc';
import { apply_config, rollback } from '../root/usr/share/tailscale-gateway/apply.uc';
import { GUARD, KNOWN, discover_subnets, subnet_guard, sync_subnets, known_subnets } from '../root/usr/share/tailscale-gateway/subnets.uc';
let count = 0;
function assert(test, name) { if (!test) die('FAIL: ' + name); count++; print('PASS ' + name + '\n'); }
function rejects(fn, name) { let failed = false; try { fn(); } catch (e) { failed = true; } assert(failed, name); }
function clone(v) { return json(sprintf('%J', v)); }
function request() { let c = configuration(); return { value: c.value, revision: c.revision }; }
let cfg = configuration().value;
cfg.access.remote_enabled = true;
rejects(() => validate(cfg), 'LAN subnet access requires native route acceptance');
cfg.node.accept_routes = true;
let snap = { status_ok: true, native_ok: true, routes_ok: true, network_ok: true, node: { state: 'Running' },
 interfaces: [{ interface: 'office', 'ipv4-address': [{ address: '172.16.9.1', mask: 24 }] }],
 peers: [{ hostname: 'remote-a', allowed_routes: ['203.0.113.0/24', '100.100.2.1/32', '0.0.0.0/0', '::/0', 'fd7a:115c:a1e0::1/128'], primary_routes: ['203.0.113.0/24'] }],
 tail_routes: [{ dst: '203.0.113.0/24', dev: 'tailscale0' }] };
let found = discover_subnets(cfg, snap, []);
assert(length(found.rows) == 1 && found.active[0] == '203.0.113.0/24', 'approved installed subnet discovered; peers, defaults and IPv6 excluded');
snap.peers[0].online = false;
assert(length(discover_subnets(cfg, snap, []).active) == 1, 'control connection online flag is not a reachability gate');
snap.peers[0].expired = true;
assert(length(discover_subnets(cfg, snap, []).active) == 0, 'expired subnet router is not enabled');
snap.peers[0].expired = false;
snap.peers[1] = { hostname: 'remote-b', primary_routes: ['203.0.113.0/24'] };
assert(length(discover_subnets(cfg, snap, []).rows[0].peers) == 2, 'HA routers share one destination');
for (let device in ['eth8', 'lo']) {
 let bad = clone(snap); bad.tail_routes[0].dev = device;
 assert(!length(discover_subnets(cfg, bad, []).active), 'wrong egress never becomes an active subnet: ' + device);
}
let bad = clone(snap); bad.tail_routes = [];
found = discover_subnets(cfg, bad, ['203.0.113.0/24']);
assert(!length(found.active) && found.known[0] == '203.0.113.0/24', 'route withdrawal removes allowlist and retains guard');
bad.peers = [];
assert(discover_subnets(cfg, bad, ['203.0.113.0/24']).rows[0].state == 'unavailable', 'removed peer retains a visible protected destination');
for (let field in ['local_routes', 'remote_exclude']) {
 let custom = clone(cfg); custom.access[field] = ['203.0.113.128/25'];
 found = discover_subnets(custom, snap, ['203.0.113.0/24']);
 assert(!length(found.active) && !length(found.known) && found.rows[0].state == 'excluded', 'partial overlap excludes the whole subnet: ' + field);
}
let custom = clone(cfg); custom.node.advertise_routes = ['203.0.113.0/24'];
assert(!length(discover_subnets(custom, snap, []).active), 'own advertised subnet excluded');
bad = clone(snap); bad.interfaces[0]['ipv4-address'][0].address = '203.0.113.1';
assert(!length(discover_subnets(cfg, bad, []).active), 'directly connected network excluded');
bad = clone(snap); bad.main_routes = [{ dst: '203.0.113.0/24', dev: 'eth8' }];
assert(!length(discover_subnets(cfg, bad, []).active), 'explicit main-table route wins for selected LANs');
let injected = clone(snap); injected.peers[0].allowed_routes = ['203.0.113.0/24; flush ruleset']; injected.peers[0].primary_routes = []; injected.peers = [injected.peers[0]];
assert(!length(discover_subnets(cfg, injected, []).known), 'untrusted route text cannot enter nft syntax');
assert(index(subnet_guard('tailscale0'), 'hook forward priority -1') >= 0 && index(subnet_guard('tailscale0'), 'oifname != "tailscale0"') >= 0, 'guard runs before conntrack accept and checks actual output device');
rejects(() => subnet_guard('x"; flush ruleset'), 'guard device injection rejected');
let c = config_cursor(); c.set('firewall', 'defaults_test', 'defaults'); c.set('firewall', 'defaults_test', 'flow_offloading', '1'); c.commit('firewall');
rejects(() => validate(cfg), 'flow offloading conflict rejected');
c.delete('firewall', 'defaults_test'); c.commit('firewall');
let status = read_json(ROOT + '/status.json');
status.Peer = { test: { ID: 'remote-a', HostName: 'remote-a', AllowedIPs: ['203.0.113.0/24'], PrimaryRoutes: ['203.0.113.0/24'] } };
save_json(ROOT + '/status.json', status); save_json(ROOT + '/routes4.json', snap.tail_routes); collect();
let input = request(); input.value = cfg; input.value.access.local_routes = ['198.51.100.0/24'];
let plan = make_plan(input);
let allow = filter(plan.resources, (r) => r.key == 'tsg_remote_lan_0')[0].applied.options;
let nat = filter(plan.resources, (r) => r.key == 'tsg_remote_sources')[0].applied.options;
assert(allow.src_ip == '172.16.9.0/24' && allow.ipset == 'tsg_remote_active' && nat.entry[0] == allow.src_ip && index(subnet_guard('tailscale0'), 'ip saddr @tsg_remote_sources ip daddr @tsg_remote_active counter masquerade') >= 0, 'allow and SNAT are scoped to LAN and the dynamic active set');
assert(filter(plan.resources, (r) => r.key == 'tsg_remote_local_0')[0].applied.options.suppress_prefixlength == '0', 'selected LAN checks non-default local routes before Tailnet');
assert(filter(plan.resources, (r) => r.key == 'tsg_local_0')[0].applied.options.priority == '4900', 'local exception stays ahead of table 52');
apply_config(input, '777777777777777777777777');
assert(configuration().value.access.remote_enabled && known_subnets()[0] == '203.0.113.0/24', 'enable transaction starts sync and seeds restart protection');
assert(index(fs.readfile(ROOT + '/last-nft.txt'), 'add element inet fw4 tsg_remote_active { 203.0.113.0/24 }') >= 0, 'effective route installed in active firewall set');
save_json(ROOT + '/routes4.json', []);
let synced = sync_subnets(configuration().value, collect());
assert(synced.state == 'ok' && !length(synced.active) && length(synced.known) == 1, 'live withdrawal closes LAN access without forgetting destination');
assert(index(fs.readfile(ROOT + '/last-nft.txt'), 'add element inet fw4 tsg_remote_active') < 0, 'withdrawal actually clears firewall allowlist');
fs.writefile(ROOT + '/fail-routes', '1');
synced = sync_subnets(configuration().value, collect()); fs.unlink(ROOT + '/fail-routes');
assert(synced.state == 'error' && length(synced.known) == 1 && !length(synced.active), 'route read failure fails closed and retains protection');
fs.writefile(ROOT + '/fail-nft', '1');
synced = sync_subnets(configuration().value, collect()); fs.unlink(ROOT + '/fail-nft');
assert(synced.state == 'error', 'nft failure is not reported as sync success');
save_json(ROOT + '/routes4.json', snap.tail_routes);
synced = sync_subnets(configuration().value, collect());
assert(synced.state == 'ok' && length(synced.active) == 1, 'next tick repairs an empty set after reload or failure');
let originalGuard = fs.readfile(GUARD); fs.writefile(GUARD, '# external edit');
rejects(() => make_plan(request()), 'external guard edit blocks apply'); fs.writefile(GUARD, originalGuard);
input = request(); input.value.access.remote_enabled = false;
fs.writefile(ROOT + '/fail-fw4', '1');
rejects(() => apply_config(input, '888888888888888888888888'), 'failed disable rolls back'); fs.unlink(ROOT + '/fail-fw4');
assert(configuration().value.access.remote_enabled && fs.readfile(GUARD) == originalGuard && length(known_subnets()) == 1, 'rollback restores guard and prefix history');
apply_config(request(), '999999999999999999999999');
// A running worker can learn a new destination after a successful apply.
fs.writefile(KNOWN, '192.0.2.0/24\n203.0.113.0/24\n');
assert(!length(rollback(read_json(STATE + '/transactions/999999999999999999999999.json'), false).problems), 'routine runtime history updates do not break manual rollback');
input = request(); input.value.access.remote_enabled = false;
apply_config(input, 'aaaaaaaaaaaaaaaaaaaaaaaa');
assert(!section('firewall', 'tsg_remote_active') && !fs.access(GUARD) && !fs.access(KNOWN), 'disable removes only owned remote resources and history');
assert(configuration().value.node.accept_routes, 'disabling LAN forwarding retains native route acceptance');
assert(!length(rollback(read_json(STATE + '/transactions/aaaaaaaaaaaaaaaaaaaaaaaa.json'), false).problems) && fs.access(GUARD), 'disabled feature can be rolled back');
apply_config(request(), 'bbbbbbbbbbbbbbbbbbbbbbbb', true);
assert(!configuration().managed && !fs.access(GUARD) && !fs.access(KNOWN), 'release removes remote guard and sync configuration');
print(sprintf('RESULT %d subnet assertions passed\n', count));
