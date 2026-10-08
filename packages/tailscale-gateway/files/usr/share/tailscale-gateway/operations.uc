import * as fs from 'fs';
import { RUN, STATE, run, read_json, save_json, id, uuid, ensure } from './common.uc';
import { configuration, collect } from './state.uc';
import { apply_config, rollback, recover } from './apply.uc';

export function execute(action, data, jobid) {
	if (action == 'apply') return apply_config(data, jobid);
	if (action == 'release') return apply_config(data, jobid, true);
	if (action == 'recover') return recover();
	if (action == 'rollback') {
		if (!match(data.id || '', /^[a-f0-9]{24}$/)) die('Invalid application ID');
		let tx = read_json(STATE + '/transactions/' + data.id + '.json', null);
		if (!tx || tx.state != 'applied') die('Only a completed application can be reverted');
		let r = rollback(tx, false); collect();
		if (length(r.problems)) die(join('; ', r.problems));
		return r;
	}
	if (action == 'dns_sync') {
		let cfg = configuration();
		if (!cfg.managed || cfg.value.dns.mode != 'sync') die('请先接管配置并启用 DNS 同步。');
		let r = run(['/usr/libexec/tailscale-gateway-dns', data.preview ? '--dry-run' : 'sync'], 55);
		collect();
		if (r.code) die(r.output || 'DNS 同步失败，详情见状态与日志。');
		return { output: r.output, state: read_json(RUN + '/dns/status.json', {}) };
	}
	if (action == 'node_action') {
		let commands = {
			connect: ['/usr/sbin/tailscale', 'up'], disconnect: ['/usr/sbin/tailscale', 'down'],
			logout: ['/usr/sbin/tailscale', 'logout'], login: ['/usr/sbin/tailscale', 'login', '--timeout=15s'],
			start: ['/etc/init.d/tailscale', 'start'], stop: ['/etc/init.d/tailscale', 'stop'],
			restart: ['/etc/init.d/tailscale', 'restart']
		};
		if (!commands[data.action]) die('Unknown node action');
		let r = run(commands[data.action], 20);
		collect();
		if (data.action == 'login') {
			let m = match(r.output, /https:\/\/[a-zA-Z0-9.-]+\/a\/[a-zA-Z0-9]+/);
			return { output: r.output, auth_url: m ? m[0] : '', awaiting_login: !!m };
		}
		if (r.code) die(r.output);
		return { output: r.output || '操作完成' };
	}
	if (action == 'diagnose') {
		let argv, value = data.target || '';
		if (data.kind == 'netcheck') argv = ['/usr/sbin/tailscale', 'netcheck'];
		else if (data.kind == 'ping') {
			let ips = [];
			for (let p in read_json(RUN + '/snapshot.json', {}).peers || []) push(ips, ...p.ips);
			if (index(ips, value) < 0) die('请选择已知 Peer 的 Tailscale IP。');
			argv = ['/usr/sbin/tailscale', 'ping', '--c=3', '--timeout=3s', value];
		} else if (data.kind == 'route') {
			let ip = iptoarr(value); if (!ip) die('请输入有效 IPv4 或 IPv6 地址。');
			argv = ['/sbin/ip', length(ip) == 4 ? '-4' : '-6', 'route', 'get', value];
		} else if (data.kind == 'dns') {
			if (length(value) > 253 || !match(value, /^[a-zA-Z0-9_][a-zA-Z0-9_.-]*\.?$/)) die('请输入完整域名。');
			argv = ['/usr/bin/nslookup', value, '127.0.0.1'];
		} else if (data.kind == 'firewall') argv = ['/usr/sbin/nft', 'list', 'table', 'inet', 'fw4'];
		else die('Unknown diagnostic');
		let r = run(argv, 25), output = r.output;
		if (data.kind == 'firewall') output = join('\n', filter(split(output, '\n'), (s) => match(s, /[Tt]ailscale|tsg_/)));
		return { scope: 'router', exit_code: r.code, output: substr(output, 0, 16000) };
	}
	die('Unknown operation');
}

export function job(id) {
	if (!match(id || '', /^[a-f0-9]{24}$/)) die('Invalid job ID');
	let path = RUN + '/jobs/' + id + '.json', j = read_json(path, null);
	if (!j || j.state != 'queued') die('Missing or consumed job');
	j.state = 'running'; j.started_at = time(); j.pid = int(split(fs.readfile('/proc/self/stat') || '', ' ')[0]); save_json(path, j);
	try { j.result = execute(j.action, j.data, id); j.state = 'done'; }
	catch (e) { j.state = 'failed'; j.error = e.message || '' + e; }
	j.finished_at = time(); delete j.data; save_json(path, j);
	return j;
}

export function enqueue(action, data, session) {
	ensure();
	let jobs = fs.glob(RUN + '/jobs/*.json') || [];
	for (let path in jobs) {
		let j = read_json(path, {});
		if ((j.state == 'queued' && time() - j.created_at < 30) || (j.state == 'running' && j.pid && fs.access('/proc/' + j.pid))) die('已有操作执行中，请等待完成。');
	}
	if (length(jobs) > 40) for (let path in slice(sort(jobs), 0, length(jobs) - 30)) fs.unlink(path);
	if (length(sprintf('%J', data)) > 20000) die('Request is too large');
	system(['/bin/mkdir', '-p', RUN + '/jobs']);
	let key = uuid();
	save_json(RUN + '/jobs/' + key + '.json', { id: key, action, data, owner: session, state: 'queued', created_at: time() });
	let code = system(['/usr/libexec/tailscale-gateway', 'start-job', key]);
	if (code) die('无法启动后台操作');
	return { id: key };
}

export function logs() {
	let r = run(['/sbin/logread', '-e', 'tailscale-gateway'], 5);
	return { output: substr(r.output, max(0, length(r.output) - 16000)) };
}
