import * as fs from 'fs';
import { connect } from 'ubus';
import { RUN, ROOT, save_json, usr1_signal } from './common.uc';
import { decoder, tailscale_filter, line_targets } from './events.uc';

let source = ARGV[0];
if (index(['tailscale', 'route', 'firewall'], source) < 0) die('Invalid event source');
let bus = ROOT ? null : connect(), last = {}, status = { state: 'listening', started_at: time(), events: 0 };
let signal = usr1_signal();
function wake(targets) {
	for (let target in targets) {
		// Worker debounce spans two seconds; one signal per second suffices.
		if (last[target] == time()) continue;
		last[target] = time();
		if (ROOT) fs.stdout.write(target + '\n');
		else if (bus && signal) bus.call('service', 'signal', { name: 'tailscale-gateway', instance: target, signal });
	}
	status.events++; status.last_event = time();
	save_json(RUN + '/events-' + source + '.json', status);
}
if (ARGV[1] == 'disconnected') {
	status.state = 'reconnecting'; save_json(RUN + '/events-' + source + '.json', status);
	exit(0);
}
save_json(RUN + '/events-' + source + '.json', status);
let relevant = tailscale_filter(), decode = decoder((n) => {
	if (relevant(n)) wake(['subnets', 'dns', 'collector']);
});
try {
	for (let line = fs.stdin.read('line'); length(line); line = fs.stdin.read('line')) {
		if (source == 'tailscale') decode(line);
		else { let targets = line_targets(source, line); if (length(targets)) wake(targets); }
	}
} catch (e) {
	// Never log event bodies: preferences/netmaps may contain private data.
	status.state = 'invalid-stream';
}
// A lost subscription may mean tailscaled or the network has disappeared.
// Re-read now; authoritative read failures retain the existing fail-closed policy.
wake(source == 'firewall' ? ['subnets', 'collector'] : ['subnets', 'dns', 'collector']);
status.state = 'reconnecting'; save_json(RUN + '/events-' + source + '.json', status);
