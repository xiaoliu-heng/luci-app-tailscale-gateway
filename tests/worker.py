#!/usr/bin/env python3
"""Exercise the shipped worker using BusyBox ash in an isolated /tmp directory.

Only test-owned processes are signalled. No live services or policies change.
Run scripts/check.py first to stage the current sources.
"""
import shlex, subprocess, sys, time, uuid

HOST = sys.argv[1] if len(sys.argv) > 1 else 'openwrt'
BASE = '/tmp/tsg-dev/worker-' + uuid.uuid4().hex
LIB = '/tmp/tsg-dev/root/usr/share/tailscale-gateway/worker.sh'
count = 0

def remote(command, data=None):
    result = subprocess.run(['ssh', HOST, command], input=data, text=True, capture_output=True, timeout=10)
    if result.returncode:
        raise AssertionError(result.stderr or result.stdout or command)
    return result.stdout.strip()

def expect(test, label):
    global count
    assert test, label
    count += 1
    print('PASS', label, flush=True)

remote('mkdir -p ' + shlex.quote(BASE))

class Worker:
    def __init__(self, name, body='', period=60, retry=1):
        self.path = BASE + '/' + name
        remote('mkdir -p ' + self.path)
        script = f'''#!/bin/sh
cd {self.path}
echo $$ >pid
. {LIB}
action() {{
    n=$((n + 1))
    cut -d' ' -f1 /proc/uptime >>calls
    {body or ':'}
}}
n=0
tsg_worker {period} {retry} action
'''
        remote('cat >' + self.path + '/run', script)
        self.proc = subprocess.Popen(['ssh', HOST, 'timeout 45 sh ' + self.path + '/run'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.wait_calls(1)

    def calls(self):
        return [float(x) for x in remote('cat ' + self.path + '/calls 2>/dev/null || true').split()]

    def wait_calls(self, total, seconds=6):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            calls = self.calls()
            if len(calls) >= total:
                return calls
            if self.proc.poll() is not None:
                raise AssertionError('worker exited: ' + self.proc.stderr.read())
            time.sleep(.12)
        raise AssertionError(f'{self.path}: expected {total} calls, got {self.calls()}')

    def signal(self, burst=False):
        command = 'kill -USR1 "$(cat ' + self.path + '/pid)"'
        remote(('for n in 1 2 3 4 5 6 7 8 9 10; do ' + command + '; done') if burst else command)

    def close(self):
        remote('kill -TERM "$(cat ' + self.path + '/pid)" 2>/dev/null || true')
        try:
            self.proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.communicate()
            raise AssertionError('worker did not stop promptly')

try:
    worker = Worker('burst')
    try:
        worker.signal(burst=True)
        calls = worker.wait_calls(2)
        expect(1.5 <= calls[1] - calls[0] < 4, 'event burst is coalesced into one bounded two-second window')
        time.sleep(5.2)
        expect(len(worker.calls()) == 2, 'idle worker does not continue the old five-second polling')
    finally:
        worker.close()

    worker = Worker('during-work', 'if [ "$n" = 1 ]; then while [ ! -f released ]; do sleep 0.05; done; fi')
    try:
        worker.signal()
        remote('touch ' + worker.path + '/released')
        calls = worker.wait_calls(2)
        expect(len(calls) == 2, 'an event received during work schedules a follow-up instead of being lost')
    finally:
        worker.close()

    worker = Worker('busy-lock', '[ "$n" != 1 ] || return 75')
    try:
        calls = worker.wait_calls(2)
        expect(1.5 <= calls[1] - calls[0] < 4, 'configuration lock contention retries promptly instead of waiting sixty seconds')
    finally:
        worker.close()

    worker = Worker('backoff', '[ "$n" -gt 3 ] || return 1')
    try:
        calls = worker.wait_calls(4, seconds=10)
        gaps = [calls[i + 1] - calls[i] for i in range(3)]
        expect(all(abs(actual - expected) < .8 for actual, expected in zip(gaps, [1, 2, 4])), 'repeated errors back off instead of permanently polling at the retry interval')
    finally:
        worker.close()

    worker = Worker('long-retry', 'return 1', period=1, retry=2)
    try:
        calls = worker.wait_calls(3)
        expect(all(1.5 <= calls[i + 1] - calls[i] < 3 for i in range(2)), 'configured retry longer than the fallback period is never shortened')
    finally:
        worker.close()

    worker = Worker('fallback', period=3)
    try:
        calls = worker.wait_calls(2)
        expect(2.5 <= calls[1] - calls[0] < 4.5, 'periodic fallback still runs without any event')
    finally:
        worker.close()
    expect(True, 'TERM stops each worker and its timer promptly')
finally:
    remote('rm -rf ' + shlex.quote(BASE))
print(f'RESULT {count} BusyBox worker assertions passed')
