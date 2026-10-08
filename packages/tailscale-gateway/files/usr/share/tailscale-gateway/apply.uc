import * as fs from 'fs';
import { ROOT, RUN, STATE, ensure, run, command_json, read_json, save_json, config_cursor, section, equal, stable, revision, pending_edits, uuid } from './common.uc';
import { configuration, collect, native_preferences } from './state.uc';
import { make_plan, release_plan, store_config } from './planner.uc';

function checked(argv, seconds) {
	let r = run(argv, seconds);
	if (r.code) die(join(' ', slice(argv, 0, 2)) + ': ' + substr(r.output, 0, 1200));
	return r;
}
function wait_service(name, instance, expected) {
	for (let attempt = 0; attempt < 45; attempt++) {
		let all = command_json(['/bin/ubus', 'call', 'service', 'list', sprintf('%J', { name })], {});
		let instances = all[name]?.instances || {};
		let running = instance ? instances[instance]?.running == true : length(filter(keys(instances), (k) => instances[k].running == true)) > 0;
		if (running == expected) return;
		run(['/bin/sleep', '1']);
	}
	die('服务未达到预期状态：' + name + (instance ? '/' + instance : ''));
}
function atomic(path, content) {
	if (content == null) { fs.unlink(path); return; }
	if (fs.writefile(path + '.tsg-new', content) == null) die('Cannot stage ' + path);
	fs.chmod(path + '.tsg-new', 0600);
	if (!fs.rename(path + '.tsg-new', path)) die('Cannot replace ' + path);
}
function native_args(before, node, dns, netfilter) {
	let args = ['/usr/sbin/tailscale', 'set'];
	for (let k in ['hostname', 'accept_routes', 'advertise_exit', 'advertise_routes']) {
		let value = node[k];
		if (equal(value, before[k])) continue;
		let flag = { hostname: 'hostname', accept_routes: 'accept-routes', advertise_exit: 'advertise-exit-node', advertise_routes: 'advertise-routes' }[k];
		push(args, '--' + flag + '=' + (type(value) == 'bool' ? (value ? 'true' : 'false') : type(value) == 'array' ? join(',', value) : value));
	}
	if (dns != null && dns != before.accept_dns) push(args, '--accept-dns=' + (dns ? 'true' : 'false'));
	if (netfilter != null && netfilter != before.netfilter) push(args, '--netfilter-mode=' + (netfilter == 0 ? 'off' : netfilter == 1 ? 'nodivert' : 'on'));
	return args;
}

// Restore scoped lists on their original instance, even after a later instance
// switch. The DNS compiler preserves every rule outside its ownership ledger.
function restore_dns(prior, jobid) {
	let current = read_json(STATE + '/dns/owned.json', {});
	let hasCurrent = length(current.server || []) || length(current.rebind_domain || []);
	let hasPrior = length(prior.server || []) || length(prior.rebind_domain || []);
	if (hasCurrent && (!hasPrior || current.section != prior.section))
		checked(['/usr/bin/env', 'TSG_DNS_INSTANCE=' + current.section, '/usr/libexec/tailscale-gateway-dns', 'clear'], 65);
	if (hasPrior) {
		let file = STATE + '/transactions/' + jobid + '-dns-restore.json'; save_json(file, prior);
		checked(['/usr/bin/env', 'TSG_DNS_INSTANCE=' + prior.section, '/usr/libexec/tailscale-gateway-dns', 'restore', file], 65);
		// Restored entries retain their pre-transaction ownership, including
		// recovery after an earlier partial rollback removed the local ledger.
		save_json(STATE + '/dns/owned.json', prior);
	}
}

export function rollback(tx, recovering) {
	let problems = [], restored = [], dnsRestored = false;
	if (tx.legacy_resumed) for (let name, service in tx.legacy || {}) {
		run(['/etc/init.d/' + name, 'stop'], 50); run(['/etc/init.d/' + name, 'disable']);
	}
	if (tx.dns_touched) {
		run(['/etc/init.d/tailscale-gateway', 'stop', 'dns'], 50);
		try { restore_dns(tx.dns_before || {}, tx.id); dnsRestored = true; }
		catch (e) { push(problems, 'DNS restore: ' + e.message); }
	}
	for (let path, v in tx.files || {}) {
		let now = fs.readfile(path);
		if (now == v.before) continue;
		if (index(path, STATE + '/dns/') == 0 && tx.dns_touched) {
			if (dnsRestored) atomic(path, v.before);
			continue;
		}
		if (now != v.after) { push(problems, 'Concurrent edit: ' + path); continue; }
		try { atomic(path, v.before); push(restored, path); } catch (e) { push(problems, e.message); }
	}
	if (tx.native_applied) {
		collect();
		let current = read_json(RUN + '/native.json', {});
		if (equal(current, tx.native_after)) {
			let args = native_args(current, tx.native_before, tx.native_before.accept_dns, tx.native_before.netfilter);
			if (length(args) > 2) { let r = run(args, 20); if (r.code) push(problems, 'Tailscale preferences: ' + r.output); }
		} else if (!equal(current, tx.native_before)) push(problems, 'Tailscale preferences changed; automatic restore skipped');
	}
	if (tx.autostart_applied) run(['/etc/init.d/tailscale', tx.autostart_before ? 'enable' : 'disable']);
	if (length(filter(restored, (p) => p == ROOT + '/etc/config/network'))) {
		let r = run(['/bin/ubus', 'call', 'network', 'reload'], 20); if (r.code) push(problems, r.output);
	}
	if (length(filter(restored, (p) => p == ROOT + '/etc/config/firewall'))) {
		let r = run(['/sbin/fw4', 'reload'], 30); if (r.code) push(problems, r.output);
	}
	if (length(filter(restored, (p) => p == ROOT + '/etc/config/dhcp'))) run(['/etc/init.d/dnsmasq', 'reload'], 30);
	if (!recovering) run(['/etc/init.d/tailscale-gateway', 'reload'], 20);
	if (tx.legacy_stopped) for (let name, service in tx.legacy || {}) {
		if (service.enabled) run(['/etc/init.d/' + name, 'enable']);
		if (service.running) run(['/etc/init.d/' + name, 'start']);
	}
	tx.state = length(problems) ? 'rollback_incomplete' : 'rolled_back'; tx.problems = problems; tx.finished_at = time();
	save_json(STATE + '/transactions/' + tx.id + '.json', tx);
	if (!length(problems)) fs.unlink(STATE + '/pending.json');
	return { restored, problems };
}

export function recover() {
	let tx = read_json(STATE + '/pending.json', null);
	if (!tx) return { recovered: false };
	return { recovered: true, ...rollback(tx, true) };
}

export function apply_config(input, jobid, release) {
	collect();
	let plan = release ? release_plan(input) : make_plan(input), before = configuration(), cfg = plan.config;
	if (fs.access(STATE + '/pending.json')) die('上一次应用尚未完成回滚，请先处理诊断中的恢复记录。');
	let work = fs.mkdtemp(RUN + '/apply.XXXXXX');
	checked(['/bin/mkdir', '-p', work + '/config', work + '/save', STATE + '/transactions', STATE + '/dns']);
	let tx = { id: jobid, state: 'preparing', started_at: time(), files: {}, native_before: before.native,
		native_applied: false, legacy: {}, autostart_before: before.value.node.autostart };
	tx.dns_before = read_json(STATE + '/dns/owned.json', read_json(ROOT + '/etc/tailscale-dns-sync/owned.json', { version: 1, server: [], rebind_domain: [] }));
	function journal() { save_json(STATE + '/pending.json', tx); save_json(STATE + '/transactions/' + jobid + '.json', tx); }
	function remember(path, after) { tx.files[path] = { before: fs.readfile(path), after }; }
	try {
		for (let pkg in ['network', 'firewall', 'tailscale_gateway']) {
			let text = fs.readfile(ROOT + '/etc/config/' + pkg) || '';
			if (fs.writefile(work + '/config/' + pkg, text) == null) die('Cannot stage ' + pkg);
		}
		let c = config_cursor(work + '/config', work + '/save');
		for (let old in plan.previous.resources || []) c.delete(old.package, old.name);
		for (let r in plan.resources) {
			c.delete(r.package, r.name);
			if (!r.applied) continue;
			c.set(r.package, r.name, r.applied.type);
			for (let k, v in r.applied.options) if (!c.set(r.package, r.name, k, v)) die('Cannot stage ' + r.package + '.' + r.name);
		}
		store_config(c, cfg, !release);
		for (let pkg in ['network', 'firewall', 'tailscale_gateway']) {
			if (!c.commit(pkg)) die('Cannot commit staged ' + pkg);
			// Preserve exact existing file bytes when the resource model is unchanged.
			let changed = pkg == 'tailscale_gateway' || length(filter(plan.diffs, (d) => index(d.resource, pkg + '.') == 0));
			if (changed) remember(ROOT + '/etc/config/' + pkg, fs.readfile(work + '/config/' + pkg));
		}
		if (plan.adopt) {
			for (let name in ['tailscale-uplink', 'tailscale-dns-sync']) {
				let instances = read_json(RUN + '/snapshot.json', {}).services?.[name] || [];
				tx.legacy[name] = { running: length(filter(instances, (s) => s.running)) > 0,
					enabled: length(fs.glob('/etc/rc.d/S*' + name) || []) > 0 };
			}
			for (let name in ['owned.json', 'last-good.json']) {
				let old = fs.readfile(ROOT + '/etc/tailscale-dns-sync/' + name);
				if (old != null) remember(STATE + '/dns/' + name, old);
			}
		}
		let nativeTarget = release ? { ...before.native } : { ...before.native, hostname: cfg.node.hostname, accept_routes: cfg.node.accept_routes,
			advertise_exit: cfg.node.advertise_exit, advertise_routes: cfg.node.advertise_routes, netfilter: 0,
			accept_dns: cfg.dns.mode == 'sync' ? false : before.native.accept_dns };
		if (release) for (let k in ['hostname', 'accept_routes', 'advertise_exit', 'advertise_routes', 'netfilter', 'accept_dns']) nativeTarget[k] = plan.native_target[k];
		let manifest = { schema: 1, resources: plan.resources, updated_at: time(),
			native_original: plan.previous.native_original || before.native, native_current: nativeTarget,
			autostart_original: plan.previous.autostart_original ?? before.value.node.autostart,
			legacy: plan.previous.legacy || tx.legacy, dns_original: plan.previous.dns_original || tx.dns_before };
		remember(STATE + '/owned.json', release ? null : sprintf('%J\n', manifest));
		if (revision() != plan.revision || pending_edits()) die('配置在预览后发生变化，请重新预览。');
		journal();
		if (plan.adopt) {
			tx.legacy_stopped = true; journal();
			for (let name, old in tx.legacy) if (fs.access('/etc/init.d/' + name)) {
				checked(['/etc/init.d/' + name, 'disable']);
				if (old.running) { checked(['/etc/init.d/' + name, 'stop'], 50); wait_service(name, null, false); }
			}
		}
		for (let path, v in tx.files) atomic(path, v.after);
		// fw4 checks syntax before any firewall rules are activated. A failure
		// restores only files still identical to this transaction's candidate.
		if (tx.files[ROOT + '/etc/config/firewall']) checked(['/sbin/fw4', 'check'], 25);
		let dns = release ? nativeTarget.accept_dns : cfg.dns.mode == 'sync' ? false : null;
		let args = native_args(before.native, cfg.node, dns, nativeTarget.netfilter);
		if (length(args) > 2) {
			tx.native_after = nativeTarget;
			tx.native_applied = true; journal();
			checked(args, 25);
		}
		if (cfg.node.autostart != before.value.node.autostart) {
			tx.autostart_applied = true; journal();
			checked(['/etc/init.d/tailscale', cfg.node.autostart ? 'enable' : 'disable']);
		}
		if (tx.files[ROOT + '/etc/config/network']) checked(['/bin/ubus', 'call', 'network', 'reload'], 25);
		if (tx.files[ROOT + '/etc/config/firewall']) checked(['/sbin/fw4', 'reload'], 30);
		tx.dns_touched = cfg.dns.mode != 'paused'; journal();
		checked(['/etc/init.d/tailscale-gateway', 'enable']);
		checked(['/etc/init.d/tailscale-gateway', 'reload'], 25);
		if (!release && before.managed && before.value.uplink.enabled && !cfg.uplink.enabled && cfg.uplink.restart_on_change)
			checked(['/etc/init.d/tailscale', 'restart'], 25);
		if (release) {
			let original = plan.previous.dns_original || { version: 1, server: [], rebind_domain: [] };
			restore_dns(original, jobid);
			tx.legacy = plan.previous.legacy || {}; tx.legacy_resumed = true; journal();
			for (let name, old in tx.legacy) {
				if (old.enabled) checked(['/etc/init.d/' + name, 'enable']);
				if (old.running) checked(['/etc/init.d/' + name, 'start'], 20);
			}
		} else if (cfg.dns.mode == 'off' && length(read_json(STATE + '/dns/owned.json', {}).server || [])) {
			// The DNS worker has its own scoped transaction and ownership journal.
			checked(['/usr/libexec/tailscale-gateway-dns', 'clear'], 65);
		} else if (cfg.dns.mode == 'sync') checked(['/usr/libexec/tailscale-gateway-dns', 'sync'], 65);
		wait_service('tailscale-gateway', 'collector', true);
		wait_service('tailscale-gateway', 'uplink', !release && cfg.uplink.enabled);
		wait_service('tailscale-gateway', 'dns', !release && cfg.dns.mode == 'sync');
		collect();
		for (let r in plan.resources) if (!equal(section(r.package, r.name), r.applied)) die('应用后配置检查失败：' + r.package + '.' + r.name);
		tx.state = 'applied'; tx.finished_at = time();
		save_json(STATE + '/transactions/' + jobid + '.json', tx); fs.unlink(STATE + '/pending.json');
		save_json(STATE + '/last-apply.json', { id: jobid, state: 'applied', time: time(), diffs: plan.diffs, impacts: plan.impacts });
		run(['/bin/rm', '-rf', work]);
		return { applied: true, changes: length(plan.diffs), adopted: plan.adopt, released: !!release, checked_at: time() };
	} catch (e) {
		let error = e.message || '' + e, result = {}, touched = fs.access(STATE + '/pending.json');
		if (touched) result = rollback(tx, false);
		save_json(STATE + '/last-apply.json', { id: jobid, state: 'failed', time: time(), error, rollback: result });
		run(['/bin/rm', '-rf', work]);
		die(error + (length(result.problems || []) ? '; rollback needs attention: ' + join('; ', result.problems) : touched ? '; changes rolled back' : '; configuration unchanged'));
	}
}
