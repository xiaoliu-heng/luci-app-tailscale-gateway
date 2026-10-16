import * as fs from 'fs';
import { ROOT, RUN, read_json, save_json, equal } from '../root/usr/share/tailscale-gateway/common.uc';
import { memory_status, validate_memory, apply_memory } from '../root/usr/share/tailscale-gateway/memory.uc';

let count = 0;
function assert(value, label) { if (!value) die('FAIL ' + label); count++; print('PASS ' + label + '\n'); }
function rejects(fn, label) { let failed = false; try { fn(); } catch (e) { failed = true; } assert(failed, label); }
function clone(value) { return json(sprintf('%J', value)); }
function request() { let s = memory_status(); return { revision: s.revision, value: clone(s.value) }; }
system(['/bin/mkdir', '-p', ROOT + '/proc/201', ROOT + '/proc/100', ROOT + '/tmp/tailscale-memory']);
fs.writefile(ROOT + '/proc/201/comm', 'tailscaled\n');
fs.writefile(ROOT + '/proc/100/comm', 'tailscale\n');
fs.writefile(ROOT + '/proc/201/stat', '201 (tailscaled) S ' + join(' ', map([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18], (n) => '0')) + ' 500 0\n');
fs.writefile(ROOT + '/proc/201/status', 'VmRSS:\t70000 kB\nVmHWM:\t210000 kB\nRssAnon:\t60000 kB\n');
fs.writefile(ROOT + '/proc/meminfo', 'MemTotal: 500000 kB\nMemAvailable: 120000 kB\n');
fs.writefile(ROOT + '/proc/201/environ', 'GOMEMLIMIT=128MiB\x00GOGC=50\x00SECRET=never-return\x00');
save_json(ROOT + '/tmp/tailscale-memory/status.json', { pid: 100, rss_kib: 999999, checked_at: time(), gc_requests: 5 });
let s = memory_status();
assert(s.process.pid == 201 && s.process.rss_kib == 70000, 'read current daemon RSS, not watcher or cached RSS');
assert(s.protection == null, 'discard cache from a different process');
assert(s.value.enabled == false, 'fresh install keeps optional protection disabled');
assert(s.go_budget.running_limit == '128MiB' && s.go_budget.running_gogc == '50' && index(sprintf('%J', s), 'never-return') < 0, 'expose only Go budget variables');
save_json(ROOT + '/tmp/tailscale-memory/status.json', { pid: 201, pid_start_ticks: 500, observed_peak_kib: 123456, gc_requests: 5, last_gc: 1 });
s = memory_status(); assert(s.protection.gc_requests == 5 && s.process.hwm_kib == 210000, 'report guard counters and kernel HWM separately');
save_json(ROOT + '/tmp/tailscale-memory/status.json', { pid: 201, pid_start_ticks: 501, gc_requests: 99 });
assert(memory_status().protection == null, 'reject history after PID reuse');
fs.writefile(ROOT + '/tmp/tailscale-memory/events.log', '2026-01-01T00:00:00Z pid=201 rss_before_kib=102400 rss_after_kib=60000 available_kib=140000 passes=2 result=ok\nsecret invalid line\n');
assert(length(memory_status().events) == 1 && memory_status().events[0].before_kib == 102400, 'parse only bounded numeric recovery events');
let good = request().value;
for (let pair in [['rss_high_mib',63],['rss_high_mib',193],['available_low_mib',31],['available_low_mib',129],['interval',9],['interval',61],['cooldown',29],['cooldown',301],['enabled','1'],['interval','10; reboot'],['rss_high_mib',96.5]]) {
	let bad = clone(good); bad[pair[0]] = pair[1]; rejects(() => validate_memory(bad), 'reject invalid ' + pair[0] + '=' + pair[1]);
}
let bad = clone(good); bad.restart_tailscale = true; rejects(() => validate_memory(bad), 'reject unsupported operations');
let protected = {};
for (let name in ['network','firewall','dhcp','tailscale','tailscale_gateway']) protected[name] = fs.readfile(ROOT + '/etc/config/' + name);
fs.writefile(ROOT + '/commands.log', '');
let input = request(); input.value.enabled = true; input.value.rss_high_mib = 112; input.value.cooldown = 90;
let result = apply_memory(input);
assert(result.changed && memory_status().value.rss_high_mib == 112 && memory_status().service.running, 'apply thresholds and start only guard');
assert(memory_status().service.autostart, 'enabled guard persists at boot');
let before = fs.readfile(ROOT + '/etc/config/tailscale_memory');
rejects(() => apply_memory(input), 'reject stale configuration revision');
fs.writefile(ROOT + '/tmp/.uci/tailscale_memory', 'pending');
rejects(() => apply_memory(request()), 'reject pending memory UCI edits'); fs.unlink(ROOT + '/tmp/.uci/tailscale_memory');
assert(apply_memory(request()).changed == false, 'identical healthy settings avoid service reload');
input = request(); input.value.enabled = false; apply_memory(input);
assert(!memory_status().service.running && !memory_status().service.autostart, 'disable stops only guard and removes its boot entry');
input = request(); input.value.enabled = true; apply_memory(input);
before = fs.readfile(ROOT + '/etc/config/tailscale_memory');
input = request(); input.value.rss_high_mib = 120; fs.writefile(ROOT + '/fail-memory-service','1');
rejects(() => apply_memory(input), 'guard startup failure is reported');
assert(fs.readfile(ROOT + '/etc/config/tailscale_memory') == before && memory_status().service.running, 'failed apply restores exact memory settings and prior service');
for (let name, text in protected) assert(fs.readfile(ROOT + '/etc/config/' + name) == text, 'preserve unrelated ' + name + ' config');
let commands = fs.readfile(ROOT + '/commands.log') || '';
assert(!match(commands, /tailscale (up|down|set|debug|restart)|fw4|network reload|nft/), 'status and memory edits never mutate Tailscale or networking');
assert(!length(filter(split(commands, '\n'), (line) => index(line, '/etc/init.d/') == 0 && index(line, '/etc/init.d/tailscale-memory-guard ') != 0)), 'all service mutations target guard only');
print(sprintf('RESULT %d memory assertions passed\n', count));
