#!/usr/bin/env python3
"""Exercise the real BusyBox guard using isolated proc files and a fake CLI.

No live Tailscale socket, service, routing command, or production UCI is used.
"""
from pathlib import Path
import io, json, shlex, subprocess, sys, tarfile, time, uuid

ROOT = Path(__file__).resolve().parents[1]
HOST = sys.argv[1] if len(sys.argv) > 1 else 'openwrt'
STAGE = '/tmp/tsg-memory-worker-' + uuid.uuid4().hex[:12]

def ssh(command, check=True):
    return subprocess.run(['ssh', HOST, command], capture_output=True, text=True, check=check, timeout=25)

files = {
 'guard': (ROOT/'packages/tailscale-gateway/files/usr/libexec/tailscale-memory-guard').read_text(),
 'etc/config/tailscale_memory': (ROOT/'packages/tailscale-gateway/files/etc/config/tailscale_memory').read_text().replace("enabled '0'", "enabled '1'"),
 'proc/201/comm': 'tailscaled\n', 'proc/100/comm': 'tailscale\n',
 'proc/201/stat': '201 (tailscaled) S ' + ' '.join(['0'] * 18) + ' 500 0\n',
 'proc/201/status': 'VmRSS: 110000 kB\n', 'proc/meminfo': 'MemAvailable: 160000 kB\n',
 'usr/sbin/tailscale': '''#!/bin/sh
set -eu
R=$TSG_MEMORY_ROOT
[ "$*" = 'debug localapi GET pprof?name=heap&gc=1' ] || exit 95
count=0; [ ! -f "$R/calls" ] || read -r count <"$R/calls"
printf '%s\\n' "$((count+1))" >"$R/calls"
[ ! -e "$R/fail" ] || exit 1
if [ -e "$R/stay-high" ]; then
 printf 'VmRSS: 110000 kB\\n' >"$R/proc/201/status"
else
 printf 'VmRSS: 60000 kB\\n' >"$R/proc/201/status"
fi
'''
}
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode='w') as archive:
    for name, text in files.items():
        data = text.encode(); info = tarfile.TarInfo(name); info.size = len(data)
        info.mode = 0o755 if name in ['guard', 'usr/sbin/tailscale'] else 0o600
        archive.addfile(info, io.BytesIO(data))
subprocess.run(['ssh', HOST, 'mkdir -p ' + STAGE + ' && tar -xf - -C ' + STAGE], input=buf.getvalue(), check=True)
active = None
count = 0
def passed(label):
    global count
    count += 1; print('PASS ' + label, flush=True)

def start():
    global active
    command = 'TSG_MEMORY_ROOT=' + STAGE + ' ' + STAGE + '/guard run & child=$!; echo "$child" >' + STAGE + '/worker.pid; wait "$child"'
    active = subprocess.Popen(['ssh', HOST, command], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def stop():
    global active
    if active:
        ssh('kill "$(cat ' + STAGE + '/worker.pid)"')
        output, error = active.communicate(timeout=10)
        assert active.returncode == 0, (output, error)
        active = None

def status():
    return json.loads(ssh('cat ' + STAGE + '/tmp/tailscale-memory/status.json').stdout)

def wait_status(fn):
    for _ in range(40):
        result = ssh('cat ' + STAGE + '/tmp/tailscale-memory/status.json', False)
        if result.returncode == 0:
            data = json.loads(result.stdout)
            if fn(data): return data
        time.sleep(.1)
    raise AssertionError('Guard did not publish expected state')

try:
    start(); state = wait_status(lambda data: data.get('gc_requests') == 1 and data.get('rss_kib') == 60000)
    assert state['pid'] == 201 and state['last_result'] == 'ok' and state['last_rss_before_kib'] == 110000
    passed('actual BusyBox worker reclaims high RSS through isolated CLI and ignores watcher PID')
    assert ssh('TSG_MEMORY_ROOT=' + STAGE + ' ' + STAGE + '/guard check').stdout == ''
    assert ssh('cat ' + STAGE + '/calls').stdout.strip() == '1'
    passed('duplicate worker cannot acquire guard lock or trigger another GC')
    stop()
    ssh("printf 'VmRSS: 110000 kB\\n' >" + STAGE + '/proc/201/status')
    start(); state = wait_status(lambda data: data.get('rss_kib') == 110000)
    assert state['gc_requests'] == 1 and ssh('cat ' + STAGE + '/calls').stdout.strip() == '1'
    passed('guard-only restart retains counters and cooldown while pressure persists')
    stop()
    ssh('touch ' + STAGE + '/stay-high')
    result = json.loads(ssh('TSG_MEMORY_ROOT=' + STAGE + ' ' + STAGE + '/guard reclaim').stdout)
    assert result['gc_requests'] == 3
    passed('persistent pressure is bounded to two GC requests per trigger')
    ssh('touch ' + STAGE + '/fail')
    result = json.loads(ssh('TSG_MEMORY_ROOT=' + STAGE + ' ' + STAGE + '/guard reclaim').stdout)
    assert result['gc_requests'] == 4 and result['last_result'] == 'failed'
    passed('unsupported or failed local API is recorded without a service restart')
    ssh("printf '201 (tailscaled) S " + ' '.join(['0'] * 18) + " 501 0\\n' >" + STAGE + '/proc/201/stat')
    result = json.loads(ssh('TSG_MEMORY_ROOT=' + STAGE + ' ' + STAGE + '/guard check').stdout)
    assert result['gc_requests'] == 0 and result['pid_start_ticks'] == 501
    passed('PID reuse resets history without invoking GC during a read-only check')
finally:
    stop()
    ssh('rm -rf ' + STAGE)
print(f'{count} memory worker assertions passed')
