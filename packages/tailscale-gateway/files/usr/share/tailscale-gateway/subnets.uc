import * as fs from 'fs';
import { RUN, STATE, read_json, save_json, run, cidr, overlaps, equal, id, section } from './common.uc';

export const GUARD = STATE + '/subnet-guard.nft';
export const KNOWN = STATE + '/subnet-known.list';

function prefix(value) {
	try {
		let p = cidr(index(value, '/') < 0 ? value + '/32' : value, 32);
		// Peer addresses, defaults and special-use destinations are not subnets.
		for (let reserved in ['100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', '224.0.0.0/3', '0.0.0.0/8'])
			if (overlaps(p, reserved)) return null;
		return p;
	} catch (e) { return null; }
}

export function known_subnets() {
	return filter(split(trim(fs.readfile(KNOWN) || ''), '\n'), (p) => p && prefix(p) == p);
}

export function subnet_guard(device) {
	id(device);
	// Before fw4's established/related accept: withdrawn routes must never
	// fall through to another uplink, even for an existing connection.
	return 'chain tsg_remote_guard {\n' +
		' type filter hook forward priority -1; policy accept;\n' +
		' ip daddr @tsg_remote_known oifname != "' + device + '" counter reject with icmp type admin-prohibited\n' +
		' ip daddr @tsg_remote_known ip daddr != @tsg_remote_active counter reject with icmp type admin-prohibited\n}\n' +
		'chain tsg_remote_snat {\n type nat hook postrouting priority 99; policy accept;\n' +
		' oifname "' + device + '" ip saddr @tsg_remote_sources ip daddr @tsg_remote_active counter masquerade\n}\n';
}

export function discover_subnets(cfg, snap, known) {
	let candidates = {}, active = [], remembered = [], rows = [];
	function candidate(value) {
		let p = prefix(value);
		if (!p) return null;
		if (!candidates[p]) candidates[p] = { cidr: p, peers: [], usable_peer: false, advertised: false };
		return candidates[p];
	}
	for (let p in known || []) candidate(p);
	for (let peer in snap.peers || []) for (let p in [...(peer.allowed_routes || []), ...(peer.primary_routes || [])]) {
		let r = candidate(p);
		if (!r) continue;
		r.advertised = true;
		if (index(r.peers, peer.hostname || peer.id || 'Unknown') < 0) push(r.peers, peer.hostname || peer.id || 'Unknown');
		// Online only describes the control connection; offline peers can
		// still pass traffic. Do not turn that hint into a reachability test.
		if (!peer.expired) r.usable_peer = true;
	}
	if (length(keys(candidates)) > 512) die('远端子网超过 512 条，请缩小路由发布范围。');
	let exclusions = [];
	for (let p in cfg.access.local_routes) push(exclusions, { cidr: p, reason: '本地优先网段' });
	for (let p in cfg.access.remote_exclude || []) push(exclusions, { cidr: p, reason: '手动排除' });
	for (let p in cfg.node.advertise_routes) push(exclusions, { cidr: p, reason: '本机发布网段' });
	for (let iface in snap.interfaces || []) for (let a in iface['ipv4-address'] || [])
		push(exclusions, { cidr: a.address + '/' + a.mask, reason: '直连网络：' + iface.interface });
	// Selected LANs consult explicit main-table routes before table 52.
	// Preserve site-local routes even when a remote advertises the same range.
	for (let route in snap.main_routes || []) {
		let p = prefix(route.dst || '');
		if (p && route.dev != cfg.access.device) push(exclusions, { cidr: p, reason: '本地主路由表' });
	}
	for (let p in sort(keys(candidates))) {
		let r = candidates[p], exclusion = filter(exclusions, (x) => overlaps(p, x.cidr))[0];
		let installed = length(filter(snap.tail_routes || [], (x) => prefix(x.dst || '') == p && x.dev == cfg.access.device && (!x.type || x.type == 'unicast') && !x.gateway)) > 0;
		let state = 'unavailable', reason = !r.advertised ? '路由已撤回，保留出口保护' : !r.usable_peer ? '子网路由器密钥已过期' : !installed ? '等待 Tailscale 安装路由' : 'Tailscale 状态不可用';
		if (exclusion) { state = 'excluded'; reason = exclusion.reason + '（重叠时整段排除）'; }
		else {
			push(remembered, p);
			if (!cfg.access.remote_enabled) { state = 'disabled'; reason = '尚未启用 LAN 访问'; }
			else if (snap.status_ok && snap.routes_ok && snap.network_ok && snap.node?.state == 'Running' && cfg.node.accept_routes && r.advertised && r.usable_peer && installed) {
				push(active, p); state = 'ready'; reason = 'Tailscale 路由已安装';
			}
		}
		push(rows, { cidr: p, peers: r.peers, state, reason });
	}
	return { active, known: remembered, rows };
}

function update_sets(active, known) {
	let text = 'flush set inet fw4 tsg_remote_active\nflush set inet fw4 tsg_remote_known\n';
	if (length(known)) text += 'add element inet fw4 tsg_remote_known { ' + join(', ', known) + ' }\n';
	if (length(active)) text += 'add element inet fw4 tsg_remote_active { ' + join(', ', active) + ' }\n';
	let file = RUN + '/subnet-update.nft';
	if (fs.writefile(file, text) == null) die('Cannot stage subnet firewall update');
	fs.chmod(file, 0600);
	// nft applies a batch atomically; fw4 reload leaves the active set empty
	// until the next sync. Reapply every tick to heal external fw4 reloads.
	let result = run(['/usr/sbin/nft', '-f', file]);
	fs.unlink(file);
	if (result.code) die('子网防火墙更新失败：' + substr(result.output, 0, 400));
}

export function sync_subnets(cfg, snap) {
	let old = known_subnets(), result, error = null;
	try {
		if (!snap.network_ok) die('无法读取接口状态，暂停远端子网放行。');
		result = discover_subnets(cfg, snap, old);
		if (!snap.status_ok || !snap.routes_ok || !snap.native_ok) die('无法读取 Tailscale 或路由表，暂停远端子网放行。');
		let manifest = read_json(STATE + '/owned.json', {});
		for (let r in manifest.resources || []) if (index(r.key, 'tsg_remote_') == 0 && !equal(section(r.package, r.name), r.applied)) die('远端子网托管配置被外部修改：' + r.package + '.' + r.name);
		if (fs.readfile(GUARD) != manifest.subnet_guard || manifest.subnet_guard != subnet_guard(cfg.access.device)) die('子网出口保护配置已变化，请重新预览并应用。');
		// Persist only on prefix changes. Retired prefixes stay protected
		// across reboot; an explicit exclusion or disabling clears ownership.
		if (!equal(old, result.known)) {
			if (fs.writefile(KNOWN + '.new', length(result.known) ? join('\n', result.known) + '\n' : '') == null) die('Cannot save subnet history');
			fs.chmod(KNOWN + '.new', 0600);
			if (!fs.rename(KNOWN + '.new', KNOWN)) die('Cannot replace subnet history');
		}
		update_sets(result.active, result.known);
	} catch (e) {
		error = e.message || '' + e;
		// Keep the last known destinations protected when input is missing.
		// Never interpret a failed read as an empty Tailnet.
		try { update_sets([], old); } catch (closed) { error += '; ' + closed.message; }
	}
	let status = { checked_at: time(), state: error ? 'error' : 'ok', error,
		active: error ? [] : result.active, rows: result?.rows || [], known: error ? old : result.known };
	save_json(RUN + '/subnets.json', status);
	return status;
}
