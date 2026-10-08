import * as fs from 'fs';
import { ROOT, RUN, STATE, read_json, section, sections, array, equal, stable, id, integer, cidr, overlaps, revision, pending_edits, command_json } from './common.uc';
import { configuration, source_networks } from './state.uc';

const list_fields = { probes: true, probes6: true, sources: true, internet_zones: true, targets: true, local_routes: true };

function bool(v, name) { if (type(v) != 'bool') die(name + ' must be a boolean'); return v; }
function list(v, limit) {
	if (type(v) != 'array' || length(v) > (limit || 32)) die('Invalid or oversized list');
	let out = [];
	for (let s in v) { if (type(s) != 'string') die('List entries must be text'); if (index(out, s) < 0) push(out, s); }
	return out;
}
export function validate(raw, env) {
	if (type(raw) != 'object') die('Missing configuration');
	let current = configuration().value, out = {};
	for (let g in keys(current)) {
		if (type(raw[g]) != 'object') die('Missing section: ' + g);
		out[g] = {};
		for (let k in keys(raw[g])) if (current[g][k] == null) die('Unknown setting: ' + g + '.' + k);
		for (let k, def in current[g]) {
			let v = raw[g][k];
			if (type(def) == 'bool') out[g][k] = bool(v, k);
			else if (type(def) == 'array') out[g][k] = list(v);
			else if (type(def) == 'int') out[g][k] = integer(v, 0, 65535, k);
			else { if (type(v) != 'string' || length(v) > 253 || match(v, /[[:cntrl:]]/)) die('Invalid text: ' + k); out[g][k] = trim(v); }
		}
	}
	let n = out.node, u = out.uplink, a = out.access, d = out.dns;
	if (n.hostname && !match(n.hostname, /^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$/)) die('Invalid hostname');
	n.advertise_routes = map(n.advertise_routes, (x) => cidr(x));
	a.local_routes = map(a.local_routes, (x) => cidr(x));
	a.targets = map(a.targets, (x) => cidr(x, 32));
	for (let target in a.targets) if (!overlaps(target, '100.64.0.0/10') || int(split(target, '/')[1]) < 10) die('Tailnet targets must be within 100.64.0.0/10');
	for (let local in a.local_routes) if (overlaps(local, '100.64.0.0/10') || overlaps(local, 'fd7a:115c:a1e0::/48')) die('Local exceptions must not override Tailnet addresses');
	for (let k in ['interface', 'device', 'zone']) id(a[k]);
	if (index(['lan', 'wan'], a.zone) >= 0) die('Choose a dedicated Tailscale firewall zone');
	if (a.interface == 'lan' || a.interface == 'wan') die('Choose a dedicated Tailscale logical interface');
	for (let k in ['preferred', 'preferred6']) if (u[k]) {
		id(u[k]);
		if (!section('network', u[k])) die('Uplink interface does not exist: ' + u[k]);
		if (u[k] == a.interface || u[k] == 'loopback') die('Tailscale cannot use itself or loopback as uplink');
	}
	if (u.enabled && !u.preferred && !u.preferred6) die('Select at least one preferred uplink');
	integer(u.table, 100, 250, 'Routing table');
	if (index([202, 253, 254, 255], u.table) >= 0) die('Reserved routing table');
	integer(u.interval, 5, 300, 'Probe interval'); integer(u.fail_count, 1, 20, 'Failure threshold'); integer(u.recover_count, 1, 20, 'Recovery threshold');
	for (let k in ['probes', 'probes6']) {
		if (length(u[k]) > 4) die('Use at most four probe addresses per family');
		for (let v in u[k]) if (!iptoarr(v) || length(iptoarr(v)) != (k == 'probes' ? 4 : 16)) die('Invalid probe address');
	}
	if (u.enabled && ((u.preferred && !length(u.probes)) || (u.preferred6 && !length(u.probes6)))) die('Selected uplinks require probe addresses');
	for (let iface in a.sources) { id(iface); if (!section('network', iface) || iface == a.interface) die('Invalid source interface: ' + iface); }
	if (a.lan_enabled && (!length(a.sources) || !length(a.targets))) die('Select source networks and Tailnet targets');
	let zones = map(sections('firewall', 'zone'), (s) => s.options.name);
	for (let zone in a.internet_zones) if (index(zones, zone) < 0 || zone == a.zone) die('Invalid Internet firewall zone');
	if (n.advertise_exit && !length(a.internet_zones)) die('Exit Node requires an Internet zone');
	if (index(['off', 'paused', 'sync'], d.mode) < 0) die('Invalid DNS mode');
	integer(d.interval, 15, 3600, 'DNS interval'); integer(d.retry, 3, 300, 'DNS retry');
	if (d.mode != 'off') {
		id(d.instance);
		let inst = section('dhcp', d.instance);
		if (inst?.type != 'dnsmasq' || inst.options.port == '0') die('Select an enabled dnsmasq instance');
		if (d.mode == 'sync' && inst.options.port && inst.options.port != '53') die('DNS synchronization currently requires a port 53 dnsmasq instance');
	}
	return out;
}

function zone_for(iface) {
	let found = filter(sections('firewall', 'zone'), (s) => index(array(s.options.network), iface) >= 0);
	if (length(found) != 1) die('Source interface must belong to exactly one firewall zone: ' + iface);
	return found[0].options.name;
}

// These aliases are the explicitly supported legacy implementation, not a
// wildcard claim over other applications' UCI sections.
const aliases = {
	'tsg_transport4': 'tailscale_usb', 'tsg_transport6': 'tailscale_usb6',
	'tsg_connected4': 'tailscale_exit_connected', 'tsg_connected6': 'tailscale_exit_connected6',
	'tsg_exit4': 'tailscale_exit_usb', 'tsg_exit6': 'tailscale_exit_usb6',
	'tsg_udp': 'allow_tailscale', 'tsg_exit_forward_0': 'tailscale_exit_wan',
	'tsg_exit_nat6_0': 'tailscale_exit_snat6', 'tsg_lan_0': 'lan_tailnet_access',
	'tsg_nat_0': 'lan_tailnet_snat', 'tsg_local_0': 'office_2_main', 'tsg_local_1': 'office_76_main'
};

export function resources(cfg, adopt, manifest, snapshot) {
	let out = [], a = cfg.access, u = cfg.uplink, n = cfg.node;
	function add(pkg, typ, logical, options, force_name) {
		let old = filter(manifest.resources || [], (r) => r.key == logical)[0];
		let name = force_name || old?.name || logical;
		if (!old && adopt && aliases[logical] && section(pkg, aliases[logical])) name = aliases[logical];
		push(out, { key: logical, package: pkg, name, applied: { type: typ, name, options } });
	}
	let tsif = section('network', a.interface), tszone = filter(sections('firewall', 'zone'), (s) => s.options.name == a.zone)[0];
	if (tsif && (tsif.type != 'interface' || tsif.options.device != a.device)) die('The chosen Tailscale interface already has another purpose');
	if (tszone && (length(array(tszone.options.network)) != 1 || array(tszone.options.network)[0] != a.interface)) die('Choose a dedicated Tailscale firewall zone');
	add('network', 'interface', 'tsg_interface', { proto: 'none', device: a.device, delegate: '0' }, a.interface);
	add('firewall', 'zone', 'tsg_zone', { name: a.zone, input: a.router_access ? 'ACCEPT' : 'REJECT', output: 'ACCEPT', forward: 'REJECT', network: [a.interface] }, tszone?.name || 'tsg_zone');
	let port = int(section('tailscale', 'settings')?.options.port || '41641');
	if (port > 0) add('firewall', 'rule', 'tsg_udp', { name: 'Allow-Tailscale-UDP', src: a.internet_zones[0] || 'wan', proto: 'udp', dest_port: '' + port, target: 'ACCEPT' });
	if (u.enabled) {
		for (let family in [4, 6]) {
			add('network', family == 4 ? 'rule' : 'rule6', 'tsg_transport' + family, { priority: '5000', mark: '0x80000/0xff0000', lookup: '' + u.table });
			add('network', family == 4 ? 'rule' : 'rule6', 'tsg_connected' + family, { 'in': a.interface, priority: '30000', lookup: 'main', suppress_prefixlength: '0' });
			add('network', family == 4 ? 'rule' : 'rule6', 'tsg_exit' + family, { 'in': a.interface, priority: '30010', lookup: '' + u.table });
		}
	}
	for (let i, route in a.local_routes) {
		let logical = 'tsg_local_' + i;
		let prior = filter(manifest.resources || [], (r) => r.key == logical)[0]?.applied || (adopt ? section('network', aliases[logical]) : null);
		let priority = !n.accept_routes && prior?.options.dest == route ? prior.options.priority : '' + (4900 + i);
		add('network', length(iptoarr(split(route, '/')[0])) == 4 ? 'rule' : 'rule6', logical, { dest: route, priority, lookup: 'main' });
	}
	if (n.advertise_exit) for (let i, zone in a.internet_zones) {
		add('firewall', 'forwarding', 'tsg_exit_forward_' + i, { src: a.zone, dest: zone });
		let existing = filter(sections('firewall', 'zone'), (s) => s.options.name == zone)[0];
		if (existing?.options.masq != '1' || existing?.options.masq_src || existing?.options.masq_dest) add('firewall', 'nat', 'tsg_exit_nat4_' + i, { name: 'Tailscale-Exit-SNAT4', family: 'ipv4', src: zone, src_ip: '100.64.0.0/10', proto: 'all', target: 'MASQUERADE' });
		add('firewall', 'nat', 'tsg_exit_nat6_' + i, { name: 'Tailscale-Exit-SNAT6', family: 'ipv6', src: zone, src_ip: 'fd7a:115c:a1e0::/48', proto: 'all', target: 'MASQUERADE' });
	}
	if (a.lan_enabled) for (let i, iface in a.sources) {
		let cidrs = source_networks(iface, snapshot), zone = zone_for(iface);
		if (!length(cidrs)) die('No IPv4 network found on ' + iface);
		add('firewall', 'rule', 'tsg_lan_' + i, { name: 'Allow-LAN-to-Tailscale', src: zone, dest: a.zone, family: 'ipv4', proto: 'all', src_ip: length(cidrs) == 1 ? cidrs[0] : cidrs, dest_ip: length(a.targets) == 1 ? a.targets[0] : a.targets, target: 'ACCEPT' });
		add('firewall', 'nat', 'tsg_nat_' + i, { name: 'LAN-to-Tailscale-SNAT', src: a.zone, family: 'ipv4', proto: 'all', src_ip: length(cidrs) == 1 ? cidrs[0] : cidrs, dest_ip: length(a.targets) == 1 ? a.targets[0] : a.targets, target: 'MASQUERADE' });
	}
	if (a.subnet_access) for (let i, iface in a.sources) for (let j, route in n.advertise_routes) {
		let zone = zone_for(iface), family = length(iptoarr(split(route, '/')[0])) == 4 ? 'ipv4' : 'ipv6';
		add('firewall', 'rule', 'tsg_subnet_' + i + '_' + j, { name: 'Allow-Tailscale-to-Subnet', src: a.zone, dest: zone, dest_ip: route, family, proto: 'all', target: 'ACCEPT' });
	}
	return out;
}

export function make_plan(input) {
	let env = configuration(), snap = read_json(RUN + '/snapshot.json', {}), manifest = read_json(STATE + '/owned.json', { resources: [] });
	if (input.revision != env.revision) die('配置已变化，请重新加载并预览。');
	if (pending_edits()) die('存在待提交的网络、DNS 或防火墙修改，请先应用或撤销。');
	if (!snap.native_ok || time() - (snap.checked_at || 0) > 90) die('Tailscale 状态不可用或过期，请刷新后重试。');
	if (env.native.exit_node) die('请先停止使用其他 Exit Node，再接管网关策略。');
	if (!env.managed && input.adopt != true) die('首次应用需要明确接管当前配置。');
	let cfg = validate(input.value, env), wanted = resources(cfg, !env.managed, manifest, snap), diffs = [], warnings = [], impacts = [];
	if (snap.kernel_tun == false) die('网关转发需要内核 TUN 接口，不支持 userspace networking 模式。');
	if (length(snap.tun_devices || []) && index(snap.tun_devices, cfg.access.device) < 0) die('所选设备不是当前 Tailscale TUN 接口。请先在原生服务中配置设备名。');
	if (!env.managed && env.legacy && !equal(cfg, env.value)) die('请先按现有配置接管旧服务，接管完成后再调整设置。');
	// Retain tombstones so disabling a feature does not lose its original
	// resource or reuse an adopted name as if it belonged to someone else.
	for (let old in manifest.resources || []) if (!length(filter(wanted, (r) => r.package == old.package && r.name == old.name))) push(wanted, { ...old, applied: null });
	let dnsOwned = read_json(STATE + '/dns/owned.json', read_json(ROOT + '/etc/tailscale-dns-sync/owned.json', {}));
	if (dnsOwned.section && dnsOwned.section != cfg.dns.instance && length(dnsOwned.server || [])) die('请先在原 dnsmasq 实例关闭并清理规则，再切换实例。');
	for (let r in wanted) {
		let live = section(r.package, r.name), old = filter(manifest.resources || [], (x) => x.package == r.package && x.name == r.name)[0];
		if (old && !equal(live, old.applied)) die('托管配置已被外部修改：' + r.package + '.' + r.name);
		if (live && !old && env.managed) die('配置名称被其他设置占用：' + r.package + '.' + r.name);
		if (!equal(live, r.applied)) push(diffs, { resource: r.package + '.' + r.name, before: live, after: r.applied });
		r.original = old ? old.original : live;
	}
	for (let old in manifest.resources || []) if (!length(filter(wanted, (r) => r.package == old.package && r.name == old.name))) {
		if (!equal(section(old.package, old.name), old.applied)) die('不能移除被外部修改的配置：' + old.package + '.' + old.name);
		push(diffs, { resource: old.package + '.' + old.name, before: old.applied, after: null });
	}
	let allowed = map(wanted, (r) => r.package + '.' + r.name);
	if (cfg.uplink.enabled) {
		let ownedTable = env.managed ? env.value.uplink.table : (section('network', 'tailscale_usb')?.options.lookup || null);
		if ('' + ownedTable != '' + cfg.uplink.table) for (let family in [4, 6]) {
			let routes = command_json(['/sbin/ip', '-' + family, '-j', 'route', 'show', 'table', '' + cfg.uplink.table], []);
			if (length(routes)) die('所选路由表包含未托管的内核路由。');
		}
	}
	let policies = filter(wanted, (r) => r.package == 'network' && index(['rule', 'rule6'], r.applied?.type) >= 0);
	for (let s in [...sections('network', 'rule'), ...sections('network', 'rule6')]) {
		if (index(allowed, 'network.' + s.name) >= 0) continue;
		if ((cfg.uplink.enabled && s.options.lookup == '' + cfg.uplink.table) || length(filter(policies, (p) => p.applied.type == s.type && p.applied.options.priority == s.options.priority))) die('路由表或规则优先级冲突：network.' + s.name);
	}
	for (let family in [4, 6]) {
		let typ = family == 4 ? 'rule' : 'rule6';
		let relevant = filter(policies, (p) => p.applied.type == typ);
		for (let rule in command_json(['/sbin/ip', '-' + family, '-j', 'rule', 'show'], [])) {
			if (!length(filter(relevant, (p) => int(p.applied.options.priority) == rule.priority)) && !(cfg.uplink.enabled && '' + rule.table == '' + cfg.uplink.table)) continue;
			let matches = filter(wanted, (p) => {
				let old = section(p.package, p.name), o = old?.options;
				if (p.package != 'network' || old?.type != typ || int(o.priority) != rule.priority || o.lookup != '' + rule.table) return false;
				let dest = rule.dst ? rule.dst + (index(rule.dst, '/') < 0 && rule.dstlen ? '/' + rule.dstlen : '') : '';
				if ((o.dest || '') != dest || (rule.src && rule.src != 'all') || rule.uidrange || rule.ipproto || rule.sport || rule.dport || rule.not) return false;
				if ((o.mark || '') != (rule.fwmark ? rule.fwmark + (rule.fwmask ? '/' + rule.fwmask : '') : '')) return false;
				let device = o['in'] ? section('network', o['in'])?.options.device : '';
				return (device || '') == (rule.iif || '') && (o.suppress_prefixlength == null ? rule.suppress_prefixlen == null : int(o.suppress_prefixlength) == rule.suppress_prefixlen);
			});
			if (!length(matches)) die('内核策略规则冲突：IPv' + family + ' priority ' + rule.priority);
		}
	}
	for (let net in cfg.access.local_routes) for (let r in snap.tail_routes || []) if (r.dst && r.dst != 'default' && overlaps(net, r.dst))
		push(warnings, '本地例外 ' + net + ' 与 Tailscale 路由 ' + r.dst + ' 重叠；应用后本地例外优先。');
	if (!equal(cfg.node, env.value.node)) push(diffs, { resource: 'tailscale.preferences', before: env.value.node, after: cfg.node });
	if (env.native.netfilter != 0) {
		push(diffs, { resource: 'tailscale.netfilter-mode', before: env.native.netfilter, after: 'off' });
		push(impacts, '将 Tailscale 防火墙管理交给 fw4');
	}
	for (let g in ['uplink', 'access', 'dns']) if (!equal(cfg[g], env.value[g])) push(diffs, { resource: 'tailscale_gateway.' + g, before: env.value[g], after: cfg[g] });
	if (cfg.dns.mode == 'sync' && env.native.accept_dns) {
		push(diffs, { resource: 'tailscale.accept-dns', before: true, after: false });
		push(warnings, 'DNS 同步模式将关闭 Tailscale 对系统 DNS 的接管，保留当前默认解析器。');
	}
	if (length(filter(diffs, (x) => index(x.resource, 'network.') == 0))) push(impacts, '重新加载相关网络配置');
	if (length(filter(diffs, (x) => index(x.resource, 'firewall.') == 0))) push(impacts, '重新加载 fw4 防火墙');
	if (!equal(cfg.uplink, env.value.uplink)) push(impacts, '更新上联监测；出口改变时可能短暂重连');
	if (cfg.dns.mode != env.value.dns.mode || cfg.dns.instance != env.value.dns.instance) push(impacts, '更新 DNS 同步；规则变化时 reload dnsmasq');
	if (!env.managed) push(impacts, '接管旧上联与 DNS 同步服务，保持 Tailscale 身份');
	if (cfg.node.advertise_exit || length(cfg.node.advertise_routes)) push(warnings, '发布路由仍受 Tailscale 控制台批准与 ACL 限制。');
	if (cfg.access.lan_enabled) push(warnings, 'LAN 访问采用 SNAT；远端 ACL 识别路由器身份。');
	return { revision: env.revision, config: cfg, resources: wanted, previous: manifest, diffs, warnings, impacts, adopt: !env.managed, created_at: time() };
}

export function store_config(c, cfg, managed) {
	c.set('tailscale_gateway', 'main', 'gateway');
	c.set('tailscale_gateway', 'main', 'managed', managed ? '1' : '0');
	c.set('tailscale_gateway', 'main', 'schema', '1');
	for (let group in ['uplink', 'access', 'dns']) {
		c.delete('tailscale_gateway', group); c.set('tailscale_gateway', group, group);
		for (let k, v in cfg[group]) {
			if (type(v) == 'array' && !length(v)) { c.set('tailscale_gateway', group, k, ''); continue; }
			c.set('tailscale_gateway', group, k, type(v) == 'bool' ? (v ? '1' : '0') : type(v) == 'int' ? '' + v : v);
		}
	}
}

export function release_plan(input) {
	let env = configuration(), manifest = read_json(STATE + '/owned.json', null);
	if (!env.managed || !manifest) die('当前没有托管的网关配置。');
	if (input.revision != env.revision || pending_edits()) die('配置已变化或存在待提交修改，请刷新后重试。');
	let keys = ['hostname', 'accept_routes', 'advertise_exit', 'advertise_routes', 'accept_dns', 'netfilter'];
	for (let k in keys) if (!equal(env.native[k], manifest.native_current?.[k])) die('Tailscale 原生偏好已被外部修改：' + k);
	let desired = [], diffs = [];
	for (let r in manifest.resources) {
		if (!equal(section(r.package, r.name), r.applied)) die('托管资源已被外部修改：' + r.package + '.' + r.name);
		push(desired, { ...r, applied: r.original });
		if (!equal(r.applied, r.original)) push(diffs, { resource: r.package + '.' + r.name, before: r.applied, after: r.original });
	}
	let cfg = env.value;
	for (let k in ['hostname', 'accept_routes', 'advertise_exit', 'advertise_routes']) cfg.node[k] = manifest.native_original[k];
	cfg.node.autostart = manifest.autostart_original;
	cfg.uplink.enabled = false; cfg.dns.mode = 'off';
	return { revision: env.revision, config: cfg, resources: desired, previous: manifest, diffs,
		warnings: ['恢复接管前的原生偏好与托管资源；保留无关配置。'], impacts: ['停止网关扩展服务', '恢复原有服务的启用状态'],
		adopt: false, release: true, native_target: manifest.native_original, created_at: time() };
}
