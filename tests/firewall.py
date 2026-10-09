#!/usr/bin/env python3
"""Render isolated UCI through the device's fw4; nft -c never installs rules.
Run tests/run.py first to prepare the private /tmp/tsg-dev fixture.
"""
from pathlib import Path
import subprocess, sys
host = sys.argv[1] if len(sys.argv) > 1 else 'openwrt'
prepare = r'''
import { configuration, collect } from '/tmp/tsg-dev/root/usr/share/tailscale-gateway/state.uc';
import { apply_config } from '/tmp/tsg-dev/root/usr/share/tailscale-gateway/apply.uc';
import { config_cursor } from '/tmp/tsg-dev/root/usr/share/tailscale-gateway/common.uc';
let c = config_cursor(); c.delete('firewall', 'tsg_zone', 'device'); c.commit('firewall');
collect(); let cfg = configuration();
cfg.value.node.accept_routes = true; cfg.value.access.remote_enabled = true; cfg.value.access.sources = ['office'];
apply_config({ revision: cfg.revision, value: cfg.value, adopt: true }, 'cccccccccccccccccccccccc');
c = config_cursor();
c.set('firewall', 'inside', 'device', ['br-fixture']);
c.set('firewall', 'tsg_zone', 'device', ['tailscale0']); c.commit('firewall');
'''
r = subprocess.run(['ssh', host, 'TSG_ROOT=/tmp/tsg-dev/fixture ucode -'], input=prepare, text=True, capture_output=True)
if r.returncode: sys.exit(r.stderr or r.stdout)
# Only the isolated copy's UCI cursor/state path change. Parser and templates
# are the installed implementation, with no replacement of policy commands.
module = subprocess.check_output(['ssh', host, 'cat /usr/share/ucode/fw4.uc'], text=True)
assert 'this.cursor = uci.cursor();' in module
module = module.replace('this.cursor = uci.cursor();', 'this.cursor = uci.cursor("/tmp/tsg-dev/fixture/etc/config", "/tmp/tsg-dev/fixture/tmp/tsg-read");')
module = module.replace('"/var/run/fw4.state"', '"/tmp/tsg-dev/render/fw4.state"')
subprocess.run(['ssh', host, 'mkdir -p /tmp/tsg-dev/render && cat > /tmp/tsg-dev/render/fw4.uc'], input=module, text=True, check=True)
main = '{% let fw4 = require("fw4"); fw4.load(false); include("/usr/share/firewall4/templates/ruleset.uc", { fw4, type, exists, length, include }); %}'
subprocess.run(['ssh', host, 'cat > /tmp/tsg-dev/render/main.uc'], input=main, text=True, check=True)
r = subprocess.run(['ssh', host, 'utpl -S -L /tmp/tsg-dev/render /tmp/tsg-dev/render/main.uc'], capture_output=True, text=True)
if r.returncode: sys.exit(r.stderr)
assert 'tsg_remote' not in '\n'.join(line for line in r.stderr.splitlines() if 'ignoring' in line or 'unsupported' in line), r.stderr
assert 'ip saddr 172.16.9.0/24 ip daddr @tsg_remote_active' in r.stdout, r.stdout
assert 'include "/tmp/tsg-dev/fixture/etc/tailscale-gateway/subnet-guard.nft"' in r.stdout
assert 'set tsg_remote_sources' in r.stdout and 'set tsg_remote_known' in r.stdout
r = subprocess.run(['ssh', host, 'nft -c -f -'], input=r.stdout, text=True, capture_output=True)
if r.returncode: sys.exit(r.stderr)
print('PASS installed fw4 renders scoped forwarding, all sets and guard/SNAT include; kernel nft syntax check passed without activation')
