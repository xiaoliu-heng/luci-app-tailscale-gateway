#!/usr/bin/env python3
"""Create a source release without private device snapshots or office tests."""
from pathlib import Path
import gzip, hashlib, io, os, re, tarfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.search(r"^VERSION = '([^']+)'", (ROOT/'scripts/package.py').read_text(), re.M)[1]
EPOCH = int(os.environ.get('SOURCE_DATE_EPOCH', '1791417600'))
name = 'tailscale-gateway-' + VERSION
files = sorted(p for p in (ROOT/'packages').rglob('*') if p.is_file())
files += [ROOT/p for p in ['README.md', 'LICENSE', 'SECURITY.md', '.gitignore', 'docs/VALIDATION.md',
 'scripts/check.py', 'scripts/package.py', 'scripts/source-package.py', 'scripts/deploy.py',
 'tests/run.py', 'tests/test-runner.sh', 'tests/fake-set.uc', 'tests/validation.uc',
 'tests/dns.py', 'tests/uplink.py', 'tests/ui.cjs', 'tests/acl.py']]
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode='w', format=tarfile.PAX_FORMAT) as archive:
    for p in sorted(files):
        content = p.read_bytes()
        entry = tarfile.TarInfo(name + '/' + str(p.relative_to(ROOT)))
        entry.mtime = EPOCH; entry.uid = entry.gid = 0; entry.uname = entry.gname = 'root'
        entry.mode = 0o755 if p.stat().st_mode & 0o111 else 0o644
        entry.size = len(content); archive.addfile(entry, io.BytesIO(content))
dist = ROOT/'dist'; dist.mkdir(exist_ok=True)
output = dist/(name + '-source.tar.gz')
output.write_bytes(gzip.compress(buf.getvalue(), mtime=EPOCH))
artifacts = sorted(dist.glob('*-' + VERSION + '.apk')) + [output]
(dist/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in artifacts))
print(output)
