import * as fs from 'fs';
import { cursor } from 'uci';
import { sha256 } from 'digest';

export const ROOT = getenv('TSG_ROOT') || '';
export const RUN = ROOT + '/var/run/tailscale-gateway';
export const STATE = ROOT + '/etc/tailscale-gateway';
export const SHARE = ROOT + '/usr/share/tailscale-gateway';
export function ensure() {
	system(['/bin/mkdir', '-p', RUN, STATE, ROOT + '/tmp/tsg-read']);
	if ((fs.stat(RUN)?.mode & 0777) != 0700) fs.chmod(RUN, 0700);
	if ((fs.stat(STATE)?.mode & 0777) != 0700) fs.chmod(STATE, 0700);
}
export function read_json(path, fallback) {
	let s = fs.readfile(path);
	if (s == null) return fallback;
	try { return json(s); } catch (e) { return fallback; }
}
export function save_json(path, value) {
	if (fs.writefile(path + '.new', sprintf('%J\n', value)) == null) die('Cannot write ' + path);
	fs.chmod(path + '.new', 0600);
	if (!fs.rename(path + '.new', path)) die('Cannot replace ' + path);
}
export function run(argv, seconds) {
	ensure();
	if (!ROOT && argv[0] == '/usr/sbin/tailscale' && !fs.access(argv[0], 'x')) argv = ['/usr/bin/tailscale', ...slice(argv, 1)];
	let dir = fs.mkdtemp(RUN + '/cmd.XXXXXX');
	if (!dir) die('Cannot create command workspace');
	let file = dir + '/output';
	if (ROOT) {
		// Fixture runs must never fall through to the live router's commands.
		let runner = ROOT + '/usr/libexec/tsg-test-runner';
		if (!fs.access(runner, 'x')) die('Isolated test runner is required with TSG_ROOT');
		argv = [runner, ...argv];
	}
	let code = system(['/usr/bin/timeout', '-k', '2', '' + (seconds || 10),
		ROOT + '/usr/libexec/tailscale-gateway-capture', file, ...argv]);
	let output = fs.readfile(file) || '';
	fs.unlink(file); fs.rmdir(dir);
	return { code, output: substr(output, 0, 131072) };
}
export function command_json(argv, fallback) {
	let r = run(argv);
	if (r.code) return fallback;
	try { return json(r.output); } catch (e) { return fallback; }
}
export function stable(v) {
	if (type(v) == 'array') return '[' + join(',', map(v, stable)) + ']';
	if (type(v) == 'object') return '{' + join(',', map(sort(keys(v)), (k) => sprintf('%J', k) + ':' + stable(v[k]))) + '}';
	return sprintf('%J', v);
}
export function equal(a, b) { return stable(a) == stable(b); }
export function array(v) { return v == null ? [] : type(v) == 'array' ? v : [v]; }
export function clean(s) {
	if (!s) return null;
	let v = { type: s['.type'], name: s['.name'], options: {} };
	for (let k, x in s) if (substr(k, 0, 1) != '.') v.options[k] = x;
	return v;
}
export function config_cursor(dir, save) { return cursor(dir || ROOT + '/etc/config', save || ROOT + '/tmp/tsg-read'); }
export function sections(pkg, typ) {
	let result = [], c = config_cursor();
	c.foreach(pkg, typ, (s) => push(result, clean(s)));
	return result;
}
export function section(pkg, name) { return clean(config_cursor().get_all(pkg, name)); }
export function uuid() { return substr(sha256(fs.readfile('/proc/sys/kernel/random/uuid') || die('No random source')), 0, 24); }
export function revision() {
	let s = '';
	for (let p in ['network', 'firewall', 'dhcp', 'tailscale_gateway', 'tailscale_uplink', 'tailscale'])
		s += p + '\n' + (fs.readfile(ROOT + '/etc/config/' + p) || '');
	s += stable(read_json(RUN + '/native.json', {}));
	s += fs.readfile(STATE + '/owned.json') || '';
	return sha256(s);
}
export function pending_edits() {
	let paths = [ROOT + '/tmp/.uci/*', ROOT + '/tmp/run/rpcd/uci-*/*'];
	for (let pattern in paths) for (let p in fs.glob(pattern) || [])
		if (index(['network', 'firewall', 'dhcp', 'tailscale_gateway', 'tailscale'], fs.basename(p)) >= 0 && length(fs.readfile(p) || '')) return true;
	return false;
}
export function cidr(value, family) {
	if (type(value) != 'string') die('CIDR must be text');
	let parts = split(value, '/'), bytes = iptoarr(parts[0]);
	if (!bytes || length(parts) != 2 || !match(parts[1], /^\d+$/)) die('Invalid CIDR: ' + value);
	let n = int(parts[1]), bits = length(bytes) * 8;
	if (n < 1 || n > bits || (family && bits != family)) die('Invalid CIDR family or prefix: ' + value);
	for (let i = 0; i < length(bytes); i++) bytes[i] &= 255 << max(0, min(8, (i + 1) * 8 - n));
	return arrtoip(bytes) + '/' + n;
}
export function overlaps(a, b) {
	let aa = split(a, '/'), bb = split(b, '/'), x = iptoarr(aa[0]), y = iptoarr(bb[0]);
	if (!x || !y || length(x) != length(y)) return false;
	// `ip -j route` omits /32 and /128 on host routes.
	let n = min(aa[1] == null ? length(x) * 8 : int(aa[1]), bb[1] == null ? length(y) * 8 : int(bb[1]));
	for (let i = 0; i < length(x); i++) {
		let mask = 255 << max(0, min(8, (i + 1) * 8 - n));
		if ((x[i] & mask) != (y[i] & mask)) return false;
	}
	return true;
}
export function id(v) {
	if (type(v) != 'string' || !match(v, /^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,30}$/)) die('Invalid interface or section name');
	return v;
}
export function integer(v, low, high, label) {
	if (type(v) != 'int' || v < low || v > high) die((label || 'Value') + ' out of range');
	return v;
}
