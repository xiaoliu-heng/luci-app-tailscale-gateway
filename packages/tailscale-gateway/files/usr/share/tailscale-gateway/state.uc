import * as fs from 'fs';
import { ROOT, RUN, STATE, run, command_json, read_json, save_json, sections, section, array, config_cursor, revision, cidr, overlaps } from './common.uc';

export function native_preferences(p) {
	return {
		hostname: p.Hostname || '', accept_routes: p.RouteAll == true,
		advertise_exit: index(p.AdvertiseRoutes || [], '0.0.0.0/0') >= 0,
		advertise_routes: filter(p.AdvertiseRoutes || [], (v) => v != '0.0.0.0/0' && v != '::/0'),
		accept_dns: p.CorpDNS == true, netfilter: p.NetfilterMode,
		exit_node: p.ExitNodeID || '', want_running: p.WantRunning == true
	};
}

export function configuration() {
	let c = config_cursor(), managed = c.get('tailscale_gateway', 'main', 'managed') == '1';
	let native = read_json(RUN + '/native.json', {});
	let value = {
		node: { hostname: native.hostname || '', accept_routes: native.accept_routes == true,
			advertise_exit: native.advertise_exit == true, advertise_routes: native.advertise_routes || [],
			autostart: length(fs.glob(ROOT + '/etc/rc.d/S*tailscale') || []) > 0 },
		uplink: { enabled: false, preferred: '', preferred6: '', table: 203, interval: 10, fail_count: 3,
			recover_count: 2, restart_on_change: true, probes: ['223.5.5.5', '119.29.29.29'],
			probes6: ['2400:3200::1', '2606:4700:4700::1111'] },
		access: { lan_enabled: false, router_access: false, subnet_access: false, interface: 'tailscale',
			device: 'tailscale0', zone: 'tailscale', sources: ['lan'], internet_zones: ['wan'],
			targets: ['100.64.0.0/10'], local_routes: [] },
		dns: { mode: 'off', instance: '', interval: 60, retry: 5 }
	};
	if (managed) {
		for (let group in ['uplink', 'access', 'dns']) for (let k, def in value[group]) {
			let v = c.get('tailscale_gateway', group, k);
			if (v == null) continue;
			value[group][k] = type(def) == 'bool' ? v == '1' : type(def) == 'int' ? int(v) : type(def) == 'array' ? filter(array(v), (x) => length(x) > 0) : trim(v);
		}
	} else {
		let up = c.get_all('tailscale_uplink', 'settings');
		if (up) for (let k, def in value.uplink) {
			if (up[k] == null) continue;
			value.uplink[k] = type(def) == 'bool' ? up[k] == '1' : type(def) == 'int' ? int(up[k]) : type(def) == 'array' ? array(up[k]) : up[k];
		}
		let lan = c.get_all('firewall', 'lan_tailnet_access');
		if (lan?.dest == 'tailscale' && lan.target == 'ACCEPT') value.access.lan_enabled = true;
		value.access.router_access = c.get('firewall', 'tailscale', 'input') == 'ACCEPT';
		for (let s in sections('network', 'rule')) if (index(['office_2_main', 'office_76_main'], s.name) >= 0 && s.options.lookup == 'main' && s.options.dest)
			push(value.access.local_routes, s.options.dest);
		let owned = read_json(ROOT + '/etc/tailscale-dns-sync/owned.json', null);
		if (owned) {
			value.dns.mode = length(fs.glob(ROOT + '/etc/rc.d/S*tailscale-dns-sync') || []) ? 'sync' : 'paused';
			value.dns.instance = owned.section || '';
		}
	}
	let instances = sections('dhcp', 'dnsmasq');
	if (!value.dns.instance && length(instances) == 1) value.dns.instance = instances[0].name;
	return { managed, legacy: !!c.get_all('tailscale_uplink', 'settings') || !!read_json(ROOT + '/etc/tailscale-dns-sync/owned.json', null), revision: revision(), value, native,
		interfaces: map(sections('network', 'interface'), (s) => ({ name: s.name, ...s.options })),
		zones: map(sections('firewall', 'zone'), (s) => ({ name: s.options.name, networks: array(s.options.network) })),
			dnsmasq: map(instances, (s) => ({ name: s.name, domain: s.options.domain || '', port: s.options.port || '53', servers: array(s.options.server) })) };
}

export function source_networks(iface, snapshot) {
	let info = filter(snapshot?.interfaces || [], (s) => s.interface == iface)[0], out = [];
	for (let addr in info?.['ipv4-address'] || []) push(out, cidr(addr.address + '/' + addr.mask, 32));
	if (!length(out)) {
		let s = section('network', iface)?.options || {};
		for (let a in array(s.ipaddr)) {
			if (index(a, '/') >= 0) push(out, cidr(a, 32));
			else if (s.netmask) {
				let bits = 0, b = iptoarr(s.netmask);
				if (b) for (let x in b) for (let i = 0; i < 8; i++) bits += (x >> i) & 1;
				push(out, cidr(a + '/' + bits, 32));
			}
		}
	}
	return out;
}

export function collect() {
	let status = command_json(['/usr/sbin/tailscale', 'status', '--json'], null);
	// OpenWrt packages may install the CLI in /usr/bin.
	if (!status) status = command_json(['/usr/bin/tailscale', 'status', '--json'], null);
	let ts = fs.access('/usr/sbin/tailscale', 'x') ? '/usr/sbin/tailscale' : '/usr/bin/tailscale';
	let prefs = command_json([ts, 'debug', 'prefs'], null);
	if (prefs && type(prefs.RouteAll) == 'bool') save_json(RUN + '/native.json', native_preferences(prefs));
	let network = command_json(['/bin/ubus', 'call', 'network.interface', 'dump'], { interface: [] });
	let services = command_json(['/bin/ubus', 'call', 'service', 'list'], {}), running = {};
	for (let name in ['tailscale', 'tailscale-uplink', 'tailscale-dns-sync', 'tailscale-gateway', 'dnsmasq']) {
		let inst = services[name]?.instances || {};
		running[name] = map(keys(inst), (k) => ({ name: k, running: inst[k].running == true, pid: inst[k].pid }));
	}
	let peers = [];
	for (let key, p in status?.Peer || {}) push(peers, {
		id: p.ID, hostname: p.HostName, dns_name: p.DNSName, ips: p.TailscaleIPs || [],
		online: p.Online == true, active: p.Active == true, rx: p.RxBytes, tx: p.TxBytes,
		path: !p.Active ? 'idle' : p.CurAddr ? (index(p.CurAddr, '[') == 0 ? 'direct6' : 'direct4') : p.Relay ? 'relay' : 'unknown',
		endpoint: p.Active ? p.CurAddr : '', relay: p.Active && !p.CurAddr ? p.Relay : '', last_seen: p.LastSeen
	});
	let cfg = configuration(), manifest = read_json(STATE + '/owned.json', {}), warnings = [];
	if (!cfg.managed) push(warnings, '当前为观察模式。预览接管后才会管理网关配置。');
	if (cfg.managed && !manifest.resources) push(warnings, '托管资源记录丢失；网关工作进程不会启动，请恢复备份后再应用。');
	if (!status) push(warnings, '无法读取 Tailscale 状态；显示未知状态，请检查守护进程。');
	if (cfg.native.exit_node) push(warnings, '正在使用另一个 Exit Node；首版不接管这种路由模式。');
	for (let route in cfg.value.node.advertise_routes) {
		let found = false;
		for (let net in network.interface || []) for (let addr in net['ipv4-address'] || [])
			if (overlaps(route, addr.address + '/' + addr.mask)) found = true;
		if (!found) push(warnings, '发布网段 ' + route + ' 未匹配当前直连 IPv4 网络，请核对用途。');
	}
	let drift = [];
	for (let r in manifest.resources || []) {
		let live = section(r.package, r.name);
		if (sprintf('%J', live) != sprintf('%J', r.applied)) {
			// Stable comparison ignores option insertion order.
			let matched = live?.type == r.applied?.type;
			for (let k, v in r.applied?.options || {}) if (sprintf('%J', live?.options?.[k]) != sprintf('%J', v)) matched = false;
			if (!matched) push(drift, r.package + '.' + r.name);
		}
	}
	let dnsOwned = read_json(cfg.managed ? STATE + '/dns/owned.json' : ROOT + '/etc/tailscale-dns-sync/owned.json', {});
	let dnsStatus = read_json(cfg.managed ? RUN + '/dns/status.json' : ROOT + '/var/run/tailscale-dns-sync/status.json', {});
	let uplink = read_json(cfg.managed ? RUN + '/uplink.json' : ROOT + '/var/run/tailscale-uplink.json', {});
	if (!cfg.managed && uplink.active) {
		uplink.active = uplink.active == 'wan' ? 'system' : cfg.value.uplink.preferred;
		uplink.ipv6 = uplink.ipv6 == 'wan' ? 'system' : uplink.ipv6 == 'blocked' ? 'blocked' : cfg.value.uplink.preferred6;
	}
	let snap = {
		checked_at: time(), managed: cfg.managed, native_ok: prefs != null, kernel_tun: prefs?.TUN != false,
		node: { state: status?.BackendState || 'Unknown', online: status?.Self?.Online == true,
			hostname: status?.Self?.HostName || cfg.value.node.hostname, dns_name: status?.Self?.DNSName || '',
			ips: status?.TailscaleIPs || [], health: status?.Health || [],
			version: status?.Version || '', exit_node: cfg.value.node.advertise_exit },
		peers, uplink, dns: { ...dnsStatus, mode: cfg.value.dns.mode, rules: dnsOwned.server || [], instance: dnsOwned.section },
		interfaces: network.interface || [], services: running, warnings, drift,
		capabilities: { fw4: fs.access('/sbin/fw4', 'x'), dnsmasq: fs.access('/usr/sbin/dnsmasq', 'x'),
			dns_json: cfg.value.dns.mode != 'sync' || dnsStatus.state != 'error' },
		tail_routes: command_json(['/sbin/ip', '-4', '-j', 'route', 'show', 'table', '52'], [])
	};
	let devices = command_json(['/sbin/ip', '-j', 'address', 'show'], []);
	snap.tun_devices = map(filter(devices, (d) => length(filter(d.addr_info || [], (a) => index(status?.TailscaleIPs || [], a.local) >= 0)) > 0), (d) => d.ifname);
	save_json(RUN + '/snapshot.json', snap);
	return snap;
}
