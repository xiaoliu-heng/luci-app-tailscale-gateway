import * as fs from 'fs';
import { connect } from 'ubus';
import { sha256 } from 'digest';
import { ROOT, RUN, ensure, config_cursor, read_json, save_json, run, command_json, integer, equal, uuid } from './common.uc';

const CONFIG = ROOT + '/etc/config/tailscale_memory';
const MEMORY_RUN = ROOT + '/tmp/tailscale-memory';
const SERVICE = 'tailscale-memory-guard';

export function memory_settings() {
	let c = config_cursor();
	return { enabled: c.get('tailscale_memory', 'main', 'enabled') == '1',
		rss_high_mib: int(c.get('tailscale_memory', 'main', 'rss_high_kib') || '98304') / 1024,
		available_low_mib: int(c.get('tailscale_memory', 'main', 'available_low_kib') || '81920') / 1024,
		interval: int(c.get('tailscale_memory', 'main', 'interval') || '10'),
		cooldown: int(c.get('tailscale_memory', 'main', 'cooldown') || '60') };
}

export function validate_memory(value) {
	if (type(value) != 'object' || type(value.enabled) != 'bool') die('内存保护开关必须为布尔值。');
	for (let k in keys(value)) if (index(['enabled', 'rss_high_mib', 'available_low_mib', 'interval', 'cooldown'], k) < 0) die('未知的内存保护选项。');
	return { enabled: value.enabled,
		rss_high_mib: integer(value.rss_high_mib, 64, 192, 'Tailscale RSS 阈值（MiB）'),
		available_low_mib: integer(value.available_low_mib, 32, 128, '系统可用内存阈值（MiB）'),
		interval: integer(value.interval, 10, 60, '检查间隔（秒）'),
		cooldown: integer(value.cooldown, 30, 300, '回收冷却时间（秒）') };
}

function kib(text, field) {
	for (let line in split(text || '', '\n')) {
		let m = match(line, regexp('^' + field + ':\\s+(\\d+)\\s+kB'));
		if (m) return int(m[1]);
	}
	return null;
}
function daemon(pid) {
	if (!pid || trim(fs.readfile(ROOT + '/proc/' + pid + '/comm') || '') != 'tailscaled') return null;
	let text = fs.readfile(ROOT + '/proc/' + pid + '/status');
	let stat = match(fs.readfile(ROOT + '/proc/' + pid + '/stat') || '', /^\d+ \(tailscaled\) (.*)$/);
	let rss = kib(text, 'VmRSS');
	if (rss == null || !stat) return null;
	return { pid: int(pid), start_ticks: int(split(stat[1], ' ')[19]), rss_kib: rss,
		hwm_kib: kib(text, 'VmHWM'), anon_kib: kib(text, 'RssAnon') };
}
function guard_service() {
	let all;
	if (ROOT) all = command_json(['/bin/ubus', 'call', 'service', 'list', sprintf('%J', { name: SERVICE })], {});
	else {
		let bus = connect();
		if (!bus) return { running: false, unavailable: true };
		all = bus.call('service', 'list', { name: SERVICE }) || {}; bus.disconnect();
	}
	let inst = all[SERVICE]?.instances?.guard;
	return { running: inst?.running == true, pid: inst?.pid || null,
		autostart: length(fs.glob(ROOT + '/etc/rc.d/S*' + SERVICE) || []) > 0 };
}
function events() {
	let file = fs.open(MEMORY_RUN + '/events.log', 'r');
	if (!file) return [];
	// The worker rotates at 64 KiB; also bound reads of externally edited files.
	let size = fs.stat(MEMORY_RUN + '/events.log')?.size || 0;
	if (size > 65536) file.seek(size - 65536);
	let text = file.read(65536) || ''; file.close();
	let result = [];
	for (let line in split(text, '\n')) {
		let m = match(line, /^(\S+) pid=(\d+) rss_before_kib=(\d+) rss_after_kib=(\d+) available_kib=(\d+) passes=(\d+) result=(ok|failed|unavailable)$/);
		if (m) push(result, { at: m[1], pid: int(m[2]), before_kib: int(m[3]), after_kib: int(m[4]), available_kib: int(m[5]), passes: int(m[6]), result: m[7] });
	}
	return slice(result, max(0, length(result) - 12));
}

export function memory_status() {
	let cached = read_json(MEMORY_RUN + '/status.json', {}), proc = daemon(cached.pid);
	if (!proc) for (let path in fs.glob(ROOT + '/proc/[0-9]*/comm') || []) {
		let m = match(path, /\/(\d+)\/comm$/);
		proc = daemon(m ? m[1] : null); if (proc) break;
	}
	let same = proc && cached.pid == proc.pid && (!cached.pid_start_ticks || cached.pid_start_ticks == proc.start_ticks);
	let c = config_cursor(), environment = proc ? fs.readfile(ROOT + '/proc/' + proc.pid + '/environ') || '' : '';
	let env = {};
	for (let line in split(environment, '\x00')) {
		let m = match(line, /^(GOMEMLIMIT|GOGC)=(.*)$/); if (m) env[m[1]] = m[2];
	}
	let configured_limit = c.get('tailscale', 'settings', 'gomemlimit') || null;
	let configured_gogc = c.get('tailscale', 'settings', 'gogc') || null;
	return { checked_at: time(), revision: sha256(fs.readfile(CONFIG) || ''), value: memory_settings(),
		process: proc, system: { total_kib: kib(fs.readfile(ROOT + '/proc/meminfo'), 'MemTotal'), available_kib: kib(fs.readfile(ROOT + '/proc/meminfo'), 'MemAvailable') },
		service: guard_service(), protection: same ? cached : null, events: events(),
		go_budget: { configured_limit, configured_gogc, running_limit: env.GOMEMLIMIT || null, running_gogc: env.GOGC || null,
			pending: !!proc && ((configured_limit && configured_limit != env.GOMEMLIMIT) || (configured_gogc && configured_gogc != env.GOGC)) } };
}

function checked(argv) {
	let r = run(argv, 15); if (r.code) die(r.output || '内存保护服务操作失败。');
}
function control(value, restoring) {
	let enabled = restoring ? restoring.running : value.enabled;
	let autostart = restoring ? restoring.autostart : value.enabled;
	checked(['/etc/init.d/' + SERVICE, autostart ? 'enable' : 'disable']);
	checked(['/etc/init.d/' + SERVICE, enabled ? 'reload' : 'stop']);
	for (let i = 0; i < 4; i++) {
		if (guard_service().running == enabled) return;
		run(['/bin/sleep', '1']);
	}
	die('内存保护服务未达到预期状态。');
}
function atomic(content) {
	if (content == null) { fs.unlink(CONFIG); return; }
	let temporary = CONFIG + '.' + uuid() + '.new';
	if (fs.writefile(temporary, content) == null) die('无法写入内存保护配置。');
	fs.chmod(temporary, 0600);
	if (!fs.rename(temporary, CONFIG)) { fs.unlink(temporary); die('无法替换内存保护配置。'); }
}

export function apply_memory(input) {
	let value = validate_memory(input?.value), before = fs.readfile(CONFIG);
	if (input.revision != sha256(before || '')) die('内存保护配置已被修改，请重新加载后再保存。');
	for (let pattern in [ROOT + '/tmp/.uci/tailscale_memory', ROOT + '/tmp/run/rpcd/uci-*/tailscale_memory'])
		for (let path in fs.glob(pattern) || []) if (length(fs.readfile(path) || '')) die('内存保护存在未提交的 UCI 修改，请先处理。');
	let previous = memory_settings(), service = guard_service();
	if (equal(previous, value) && service.running == value.enabled && service.autostart == value.enabled)
		return { changed: false, output: '设置未变化。', status: memory_status() };
	ensure();
	let work = fs.mkdtemp(RUN + '/memory-config.XXXXXX'), candidate, result;
	if (!work) die('无法创建内存保护配置目录。');
	try {
		fs.mkdir(work + '/save', 0700);
		fs.writefile(work + '/tailscale_memory', before || "config memory 'main'\n");
		let c = config_cursor(work, work + '/save');
		if (c.get('tailscale_memory', 'main') != 'memory') die('内存保护配置节类型不正确。');
		for (let k, v in { enabled: value.enabled ? '1' : '0', rss_high_kib: '' + value.rss_high_mib * 1024,
			available_low_kib: '' + value.available_low_mib * 1024, interval: '' + value.interval, cooldown: '' + value.cooldown })
			if (!c.set('tailscale_memory', 'main', k, v)) die('无法准备内存保护配置。');
		if (!c.commit('tailscale_memory')) die('无法提交内存保护配置。');
		candidate = fs.readfile(work + '/tailscale_memory');
		if (!candidate || fs.readfile(CONFIG) != before) die('内存保护配置发生并发修改。');
		atomic(candidate);
		try { control(value); }
		catch (e) {
			if (fs.readfile(CONFIG) != candidate) die(e.message + '；配置已被外部修改，未自动覆盖。');
			atomic(before);
			try { control(previous, service); } catch (r) { die(e.message + '；恢复保护服务失败：' + r.message); }
			die(e.message + '；已恢复先前内存保护配置。');
		}
		save_json(RUN + '/memory-last-apply.json', { at: time(), before: previous, after: value });
		result = { changed: true, output: '内存保护设置已应用。', status: memory_status() };
	} catch (e) { run(['/bin/rm', '-rf', work]); die(e.message || '' + e); }
	run(['/bin/rm', '-rf', work]);
	return result;
}
