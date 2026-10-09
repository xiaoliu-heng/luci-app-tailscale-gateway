#!/usr/bin/ucode
// Compile Tailscale DNS settings, and stage only the UCI entries we own.
import { readfile, writefile, rename, chmod } from 'fs';
import { cursor } from 'uci';

function read_json(path) {
	let text = readfile(path);
	if (text == null) die(`Cannot read ${path}`);
	return json(text);
}

function save_json(path, value) {
	if (writefile(path + '.new', sprintf('%J\n', value)) == null) die(`Cannot write ${path}`);
	chmod(path + '.new', 0600);
	if (!rename(path + '.new', path)) die(`Cannot replace ${path}`);
}

function unique(values) {
	let seen = {}, result = [];
	for (let value in values) {
		if (!seen[value]) { seen[value] = true; push(result, value); }
	}
	return result;
}

function array(value) {
	if (value == null) return [];
	return type(value) == 'array' ? value : [ value ];
}

function domain(value) {
	if (type(value) != 'string') die('Missing DNS domain');
	let name = lc(replace(value, /\.$/, ''));
	if (!length(name) || length(name) > 253) die('Invalid or catch-all DNS domain');
	for (let label in split(name, '.')) {
		if (!length(label) || length(label) > 63 ||
		    match(label, /[^a-z0-9_-]/) || substr(label, 0, 1) == '-' ||
		    substr(label, length(label) - 1) == '-')
			die(`Invalid DNS domain: ${name}`);
	}
	return name;
}

function resolver(value, blocked) {
	if (type(value) != 'string') die('Missing resolver address');
	let address = value, port = 53;
	let parts = match(value, /^\[([0-9a-fA-F:.]+)\]:(\d+)$/);
	if (!parts) parts = match(value, /^([0-9.]+):(\d+)$/);
	if (parts) { address = parts[1]; port = int(parts[2]); }
	let bytes = iptoarr(address);
	if (!bytes || port < 1 || port > 65535)
		die(`Unsupported DNS resolver (requires an IP address and optional port): ${value}`);
	address = arrtoip(bytes);
	let mapped = length(bytes) == 16 && !length(filter(slice(bytes, 0, 10), (b) => b != 0)) && bytes[10] == 255 && bytes[11] == 255 ? arrtoip(slice(bytes, 12)) : null;
	if (blocked[address] || address == '::' || address == '::1' ||
	    address == '0.0.0.0' || match(address, /^127\./) ||
	    match(address, /^::ffff:127\./) || (mapped && (blocked[mapped] || match(mapped, /^127\./))))
		die(`Refusing a DNS forwarding loop through ${address}`);
	return address + (port == 53 ? '' : `#${port}`);
}

function render(dns, status, output, interfaces) {
	if (status.BackendState != 'Running' || !status.Self?.ID)
		die('Tailscale is not Running with a valid node identity');
	if (type(dns.CurrentTailnet) != 'object' ||
	    type(dns.CurrentTailnet.MagicDNSEnabled) != 'bool' ||
	    type(dns.SplitDNSRoutes) != 'object')
		die('Incomplete Tailscale DNS configuration');
	let blocked = { '100.100.100.100': true, 'fd7a:115c:a1e0::53': true };
	for (let address in array(status.TailscaleIPs)) { let bytes = iptoarr(address); if (bytes) blocked[arrtoip(bytes)] = true; }
	for (let iface in interfaces || []) for (let addr in iface.addr_info || []) {
		let bytes = iptoarr(addr.local); if (bytes) blocked[arrtoip(bytes)] = true;
	}
	let c = cursor();
	c.foreach('network', 'interface', function(s) {
		for (let address in array(s.ipaddr)) {
			let bytes = iptoarr(split(address, '/')[0]);
			if (bytes) blocked[arrtoip(bytes)] = true;
		}
	});
	let routes = {}, magic = null;
	for (let suffix, resolvers in dns.SplitDNSRoutes) {
		let name = domain(suffix);
		if (type(resolvers) != 'array' || !length(resolvers))
			die(`Unsupported empty resolver list for ${name}`);
		if (routes[name] == null) routes[name] = [];
		for (let item in resolvers) push(routes[name], resolver(item?.Addr, blocked));
	}
	if (dns.CurrentTailnet.MagicDNSEnabled) {
		magic = domain(dns.CurrentTailnet.MagicDNSSuffix);
		// The authoritative MagicDNS suffix takes precedence over parent split routes.
		routes[magic] = [ '100.100.100.100' ];
	}
	let servers = [], rebind = [];
	for (let name in sort(keys(routes))) {
		for (let addr in sort(unique(routes[name]))) push(servers, `/${name}/${addr}`);
		push(rebind, name);
	}
	save_json(output, {
		version: 1, node_id: status.Self.ID, magic_suffix: magic,
		server: servers, rebind_domain: rebind
	});
}

function stage(desired, previous, configdir, savedir, outputdir, selected) {
	let c = cursor(configdir, savedir), sections = [];
	c.foreach('dhcp', 'dnsmasq', function(s) { push(sections, s); });
	if (selected) sections = filter(sections, (s) => s['.name'] == selected);
	if (length(sections) != 1) die('Select exactly one dnsmasq instance');
	let section = sections[0], name = section['.name'];
	if (section.port == '0') die('Selected dnsmasq instance has DNS disabled');
	if (previous.section && previous.section != name && (length(previous.server || []) || length(previous.rebind_domain || []))) die('Clear the previous dnsmasq instance before switching');
	if (previous.version != 1) die('Unknown ownership state version');
	let localname = lc(section.domain || 'lan');
	for (let suffix in desired.rebind_domain) {
		if (suffix == localname || (length(suffix) > length(localname) &&
		    substr(suffix, length(suffix) - length(localname) - 1) == `.${localname}`))
			die(`Refusing to override the local DNS zone ${localname}`);
	}
	let owned = { version: 1, section: name }, pending = { version: 1, section: name };
	let snippet = [];
	for (let key in [ 'server', 'rebind_domain' ]) {
		let prior = array(previous[key]), current = array(section[key]);
		let manual = filter(current, function(value) { return index(prior, value) < 0; });
		owned[key] = filter(desired[key], function(value) { return index(manual, value) < 0; });
		pending[key] = unique([ ...prior, ...owned[key] ]);
		let result = unique([ ...manual, ...desired[key] ]);
		if (length(result)) {
			if (!c.set('dhcp', name, key, result)) die(`Cannot stage ${key}`);
		} else if (section[key] != null) {
			if (!c.delete('dhcp', name, key)) die(`Cannot remove ${key}`);
		}
		let option = key == 'server' ? 'server' : 'rebind-domain-ok';
		for (let value in result) {
			// UCI normally accepts these values verbatim; reject multiline config injection.
			if (type(value) != 'string' || match(value, /[\r\n]/)) die(`Invalid existing ${key}`);
			push(snippet, `${option}=${value}`);
		}
	}
	if (!c.commit('dhcp')) die('Cannot commit staged DHCP configuration');
	save_json(`${outputdir}/owned.json`, owned);
	save_json(`${outputdir}/pending.json`, pending);
	writefile(`${outputdir}/forward.conf`, join('\n', snippet) + '\n');
	writefile(`${outputdir}/section`, name + '\n');
}

function record(path, state, reason) {
	let oldtext = readfile(path), old = oldtext ? json(oldtext) : {};
	let now = time();
	let next = {
		state, reason, checked_at: now,
		last_success: old.last_success, last_change: old.last_change,
		poll_seconds: int(cursor().get('tailscale_gateway', 'dns', 'interval') || '300'), retry_seconds: int(cursor().get('tailscale_gateway', 'dns', 'retry') || '5')
	};
	if (state == 'unchanged' || state == 'updated') next.last_success = now;
	if (state == 'updated') next.last_change = now;
	save_json(path, next);
}

if (ARGV[0] == 'render') render(read_json(ARGV[1]), read_json(ARGV[2]), ARGV[3], ARGV[4] ? read_json(ARGV[4]) : []);
else if (ARGV[0] == 'stage') stage(read_json(ARGV[1]), read_json(ARGV[2]), ARGV[3], ARGV[4], ARGV[5], ARGV[6]);
else if (ARGV[0] == 'record') record(ARGV[1], ARGV[2], ARGV[3]);
else die('Usage: render.uc render|stage|record ...');
