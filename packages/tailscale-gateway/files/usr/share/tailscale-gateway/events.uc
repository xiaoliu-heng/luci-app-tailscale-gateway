// Event payloads are hints to re-read authoritative state, never policy input.
// Keep the decoder/filter separate so fixtures exercise the shipped code.
import { stable } from './common.uc';

export function decoder(consume) {
	let frame = '', depth = 0, quoted = false, escaped = false;
	return function(chunk) {
		let start = 0;
		for (let i = 0; i < length(chunk); i++) {
			let ch = substr(chunk, i, 1);
			if (!depth && match(ch, /\s/)) { start = i + 1; continue; }
			if (!depth && ch != '{') die('Invalid event stream');
			if (length(frame) + i - start > 2097152) die('Event exceeds size limit');
			if (quoted) {
				if (escaped) escaped = false;
				else if (ch == '\\') escaped = true;
				else if (ch == '"') quoted = false;
			} else if (ch == '"') quoted = true;
			else if (ch == '{') depth++;
			else if (ch == '}') depth--;
			if (!depth) {
				let value = json(frame + substr(chunk, start, i - start + 1));
				frame = ''; start = i + 1; consume(value);
			}
		}
		if (depth) frame += substr(chunk, start);
	};
}

export function tailscale_filter() {
	let peers = {};
	return function(n) {
		// SelfChange is also emitted for DNS-only netmap changes. Do not
		// deduplicate it using just the self node's addresses or hostname.
		for (let key in ['State', 'Prefs', 'SelfChange', 'NetMap', 'InitialStatus', 'LoginFinished', 'ErrMessage'])
			if (n[key] != null) return true;
		if (length(n.PeersRemoved || [])) {
			for (let id in n.PeersRemoved) delete peers['' + id];
			return true;
		}
		let changed = false;
		for (let p in n.PeersChanged || []) {
			let id = '' + p.ID, value = {};
			for (let key in ['AllowedIPs', 'PrimaryRoutes', 'Addresses', 'KeyExpiry', 'Expired', 'Name']) value[key] = p[key];
			let next = stable(value);
			if (peers[id] != next) changed = true;
			peers[id] = next;
		}
		for (let patch in n.PeerChangedPatch || []) for (let key in keys(patch))
			// Online/LastSeen describe the control connection, not route health.
			if (index(['NodeID', 'DERPRegion', 'DERPHome', 'Endpoints', 'Online', 'LastSeen'], key) < 0) changed = true;
		return changed;
	};
}

export function line_targets(source, line) {
	if (source == 'firewall') {
		// Element changes include our own atomic updates. Ignore those to
		// prevent a sync -> nft event -> sync feedback loop.
		return match(line, /^(add|create|delete|destroy|flush) (table inet fw4([ {]|$)|set inet fw4 tsg_remote_(active|known)([ {]|$))/)
			? ['subnets', 'collector'] : [];
	}
	if (source == 'route') {
		let table = match(line, /\btable ([^ ]+)/);
		// The uplink worker replaces its separate routing table on probes.
		if (table && index(['main', '254', '52'], table[1]) < 0) return [];
		if (!length(trim(line))) return [];
		return match(line, /(^|\s)(inet |link\/|state )/) ? ['subnets', 'dns', 'collector'] : ['subnets', 'collector'];
	}
	return [];
}
