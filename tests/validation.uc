import * as fs from 'fs';
import { ROOT, RUN, STATE, save_json, read_json, section, revision, equal, cidr, overlaps, config_cursor } from '../root/usr/share/tailscale-gateway/common.uc';
import { configuration, collect } from '../root/usr/share/tailscale-gateway/state.uc';
import { validate, make_plan } from '../root/usr/share/tailscale-gateway/planner.uc';
import { apply_config, rollback } from '../root/usr/share/tailscale-gateway/apply.uc';

let count = 0;
function assert(test, name) { if (!test) die('FAIL: ' + name); count++; print('PASS ' + name + '\n'); }
function rejects(fn, name) { let failed = false; try { fn(); } catch (e) { failed = true; } assert(failed, name); }
function clone(v) { return json(sprintf('%J', v)); }
function request() { let cfg = configuration(); return { value: cfg.value, revision: cfg.revision, adopt: true }; }
collect();
let cfg = configuration();
assert(cfg.managed == false, 'fresh install observes without claiming resources');
assert(cidr('172.16.9.44/24', 32) == '172.16.9.0/24', 'CIDR normalizes host bits');
assert(!overlaps('203.0.113.0/24', '100.64.2.1') && overlaps('203.0.113.0/24', '203.0.113.1'), 'kernel host routes use full address prefix');
rejects(() => cidr('0.0.0.0/0', 32), 'catch-all local exception rejected');
let good = clone(cfg.value);
good.access.sources = ['office']; good.uplink.preferred = 'lte'; good.uplink.preferred6 = 'lte6';
assert(validate(good).uplink.preferred == 'lte', 'custom interface names supported');
for (let bad in ['lte; reboot', '$(id)', '../network', "x\ny"]) {
 let v = clone(good); v.uplink.preferred = bad;
 rejects(() => validate(v), 'interface injection rejected: ' + replace(bad, /\n/, '\\n'));
}
for (let target in ['0.0.0.0/0', '192.168.0.0/16', '100.0.0.0/8']) {
 let v = clone(good); v.access.targets = [target]; rejects(() => validate(v), 'Tailnet destination scope rejects ' + target);
}
let v = clone(good); v.uplink.table = 202; rejects(() => validate(v), 'DNSRouter table reserved');
v = clone(good); v.uplink.probes = ['1.1.1.1; touch /tmp/pwn']; rejects(() => validate(v), 'probe injection rejected');
v = clone(good); v.uplink.probes6 = ['1.1.1.1']; rejects(() => validate(v), 'probe address families enforced');
v = clone(good); v.dns.mode = 'sync'; v.dns.instance = 'disabled'; rejects(() => validate(v), 'disabled dnsmasq rejected');
v = clone(good); v.dns.mode = 'sync'; v.dns.instance = 'secondary'; assert(validate(v).dns.instance == 'secondary', 'multiple dnsmasq instances selectable');
v = clone(good); v.access.local_routes = ['100.64.0.0/10']; rejects(() => validate(v), 'local exceptions cannot capture Tailnet');
v = clone(good); v.node.hostname = 'bad;name'; rejects(() => validate(v), 'hostname injection rejected');
v = clone(good); v.dns.interval = 0; rejects(() => validate(v), 'poll interval bounded');
let input = request(); input.value = clone(good); input.value.access.lan_enabled = true;
let plan = make_plan(input);
assert(length(filter(plan.resources, (r) => r.key == 'tsg_lan_0')) == 1, 'LAN access creates one scoped forwarding rule');
let forward = filter(plan.resources, (r) => r.key == 'tsg_lan_0')[0].applied.options;
assert(forward.src_ip == '172.16.9.0/24' && forward.dest_ip == '100.64.0.0/10', 'LAN scope derived from selected interface');
assert(!length(filter(plan.resources, (r) => index(r.key, 'tsg_subnet_') == 0)), 'LAN access does not open reverse subnet forwarding');
let stale = clone(input); stale.revision = 'stale'; rejects(() => make_plan(stale), 'stale revision rejected');
fs.writefile(ROOT + '/tmp/.uci/firewall', 'pending'); rejects(() => make_plan(input), 'pending UCI changes rejected'); fs.unlink(ROOT + '/tmp/.uci/firewall');
let cursor = config_cursor(); cursor.set('network', 'other', 'rule'); cursor.set('network', 'other', 'lookup', '203'); cursor.commit('network');
input = request(); input.value = clone(good); input.value.uplink.enabled = true;
rejects(() => make_plan(input), 'foreign routing table ownership rejected');
cursor.delete('network', 'other'); cursor.commit('network');
input = request(); input.value = clone(good); input.value.access.local_routes = ['192.168.66.0/24'];
save_json(ROOT + '/rules4.json', [{ priority: 4900, src: 'all', table: '202' }]);
rejects(() => make_plan(input), 'kernel-only priority collision rejected'); fs.unlink(ROOT + '/rules4.json');
cursor.set('network', 'other', 'rule'); cursor.set('network', 'other', 'priority', '4900'); cursor.set('network', 'other', 'lookup', 'main'); cursor.commit('network');
input.revision = revision(); rejects(() => make_plan(input), 'local-exception priority conflict rejected');
cursor.delete('network', 'other'); cursor.commit('network');
input = request(); input.value = clone(good);
let beforeNetwork = fs.readfile(ROOT + '/etc/config/network');
let result = apply_config(input, '111111111111111111111111');
assert(result.applied && configuration().managed, 'isolated transaction applies');
assert(section('network', 'office').options.ipaddr == '172.16.9.1/24', 'unrelated LAN configuration retained');
let tx = read_json(STATE + '/transactions/111111111111111111111111.json');
assert(length(rollback(tx, false).problems) == 0, 'isolated transaction rolls back');
assert(fs.readfile(ROOT + '/etc/config/network') == beforeNetwork, 'rollback restores exact prior network bytes');
assert(!configuration().managed, 'rollback restores observe mode');
input = request(); input.value = clone(good);
fs.writefile(ROOT + '/fail-fw4', '1');
rejects(() => apply_config(input, '222222222222222222222222'), 'fw4 failure aborts transaction');
fs.unlink(ROOT + '/fail-fw4');
assert(fs.readfile(ROOT + '/etc/config/network') == beforeNetwork, 'fw4 failure restores prior files');
assert(!fs.access(STATE + '/pending.json'), 'successful failure recovery clears pending journal');
input = request(); input.value = clone(good);
apply_config(input, '333333333333333333333333');
input = request(); input.value.access.lan_enabled = true;
apply_config(input, '444444444444444444444444');
input = request(); input.value.access.lan_enabled = false;
apply_config(input, '555555555555555555555555');
assert(!section('firewall', 'tsg_lan_0'), 'disabling LAN access removes the owned rule');
assert(length(filter(read_json(STATE + '/owned.json').resources, (r) => r.key == 'tsg_lan_0' && r.applied == null)) == 1, 'disabled resource retains an ownership tombstone');
input = request();
apply_config(input, '666666666666666666666666', true);
assert(!configuration().managed && !section('network', 'tailscale'), 'release restores the pre-adoption state after multiple edits');
assert(section('network', 'office').options.ipaddr == '172.16.9.1/24', 'release preserves unrelated network settings');
assert(length(rollback(read_json(STATE + '/transactions/666666666666666666666666.json'), false).problems) == 0, 'release itself can be rolled back');
print(sprintf('RESULT %d assertions passed\n', count));
