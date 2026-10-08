#!/usr/bin/env python3
"""Compile in a private /tmp directory; never install or activate policies."""
from pathlib import Path
import io, json, subprocess, sys, tarfile

ROOT = Path(__file__).resolve().parents[1]
host = sys.argv[1] if len(sys.argv) > 1 else 'openwrt'
stage = '/tmp/tsg-dev'
base = ROOT / 'packages/tailscale-gateway/files'
errors = []
for p in [*base.joinpath('usr/libexec').glob('*'), *base.joinpath('etc/init.d').glob('*'), *base.joinpath('etc/hotplug.d/iface').glob('*')]:
    p.chmod(0o755)
    r = subprocess.run(['sh', '-n', str(p)], capture_output=True, text=True)
    if r.returncode: errors.append(f'{p}: {r.stderr}')
for p in ROOT.joinpath('packages').rglob('*.json'):
    json.loads(p.read_text())
for p in ROOT.joinpath('packages').rglob('*.js'):
    r = subprocess.run(['node', '--check', str(p)], capture_output=True, text=True)
    if r.returncode: errors.append(f'{p}: {r.stderr}')
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode='w') as t:
    t.add(base, arcname='root')
    t.add(ROOT / 'tests', arcname='tests')
subprocess.run(['ssh', host, 'mkdir -p /tmp/tsg-dev && tar -xf - -C /tmp/tsg-dev'], input=buf.getvalue(), check=True)
for p in base.joinpath('usr/share/tailscale-gateway').glob('*.uc'):
    mode = '-c' if p.name in ['main.uc', 'dns-render.uc'] else '-c,module'
    r = subprocess.run(['ssh', host, f'ucode {mode} -o {stage}/check.ucb {stage}/root/usr/share/tailscale-gateway/{p.name}'], capture_output=True, text=True)
    if r.returncode: errors.append(f'{p.name}: {r.stderr}')
if errors:
    print('\n'.join(errors)); sys.exit(1)
print('Shell, JSON, JavaScript and ucode compilation passed.')
