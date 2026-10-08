#!/usr/bin/env python3
"""Run the shipped controller loop with deterministic probes and inert routes.

No network command or service management command is executed by this test.
"""
import json, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'packages/tailscale-gateway/files/usr/libexec/tailscale-gateway-uplink').read_text()
loop=source[source.index('while [ "$stopping" = 0 ]; do'):].replace('/etc/init.d/tailscale restart','fake_restart')
setup=r'''
set -eu
RUN=$1
preferred=cellular preferred6=cellular_v6
ready4=0 ready6=0 failures=0 failures6=0
fail_count=3 recover_count=2 interval=1 restart_on_change=1
successes=1 successes6=1 applied='' first=1 stopping=0
probes=192.0.2.1 probes6=2001:db8::1
printf '0' >"$RUN/step"
get4() {
 step=$(cat "$RUN/step")
 [ "$step" -lt 9 ] || exit 0
 device=eth8 address=192.0.2.2 gateway=192.0.2.1
}
get6() { device6=eth9 address6=2001:db8::2 gateway6=fe80::1; }
probe() {
 case "$1:$step" in 6:1|6:2|6:3|6:4|6:5|6:6|4:4|4:5|4:6) return 1;; *) return 0;; esac
}
route4() { :; }
route6() { :; }
clear_routes() { :; }
logger() { :; }
pidof() { return 0; }
fake_restart() { echo restart >>"$RUN/restarts"; }
sleep() { cp "$RUN/uplink.json" "$RUN/state-$step.json"; echo $((step + 1)) >"$RUN/step"; }
'''
with tempfile.TemporaryDirectory(prefix='tsg-uplink-test-') as work:
    r=subprocess.run(['sh','-s',work],input=setup+loop,text=True,capture_output=True,timeout=15)
    assert r.returncode==0,r.stderr
    states=[json.loads(Path(work,f'state-{i}.json').read_text()) for i in range(9)]
    assert states[0]['active']=='cellular' and states[0]['ipv6']=='cellular_v6'
    assert states[2]['ipv6']=='cellular_v6',states[2]
    assert states[3]['ipv6']=='blocked' and states[3]['active']=='cellular'
    assert states[5]['active']=='cellular'
    assert states[6]['active']=='system' and states[6]['ipv6']=='system'
    assert states[7]['active']=='system'
    assert states[8]['active']=='cellular' and states[8]['ipv6']=='cellular_v6'
    assert len(Path(work,'restarts').read_text().splitlines())==3
print('RESULT 8 uplink assertions passed: independent families, failure/recovery thresholds, fallback, reconnects')
