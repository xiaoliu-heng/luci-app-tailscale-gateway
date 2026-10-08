#!/usr/bin/env python3
"""Install files and start observation only. This never adopts gateway policies."""
from pathlib import Path
import argparse, datetime, io, json, shlex, subprocess, tarfile

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('host', nargs='?', default='openwrt')
args = p.parse_args()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
backup = '/etc/backup/tailscale-gateway-install-' + stamp
files = {}
for part, prefix in [('packages/tailscale-gateway/files',''), ('packages/luci-app-tailscale-gateway/root',''), ('packages/luci-app-tailscale-gateway/htdocs','www/')]:
    base = ROOT/part
    for path in base.rglob('*'):
        if path.is_file(): files[prefix+str(path.relative_to(base))] = path
manifest = sorted(files)
archive = io.BytesIO()
with tarfile.open(fileobj=archive,mode='w:gz') as tar:
    for dest,path in files.items(): tar.add(path,arcname=dest)
    payload = ('\n'.join(manifest)+'\n').encode()
    info=tarfile.TarInfo('tsg-install-manifest'); info.size=len(payload); info.mode=0o600;tar.addfile(info,io.BytesIO(payload))
remote = f'''set -eu
stage=$(mktemp -d /tmp/tsg-install.XXXXXX)
trap 'rm -rf "$stage"' EXIT
tar -xzf - -C "$stage"
mkdir -p {shlex.quote(backup)}
chmod 700 {shlex.quote(backup)}
cp "$stage/tsg-install-manifest" {shlex.quote(backup)}/manifest
while IFS= read -r path; do
  if [ -f "/$path" ]; then
    mkdir -p {shlex.quote(backup)}/"$(dirname "$path")"
    cp -p "/$path" {shlex.quote(backup)}/"$path"
  else
    printf '%s\\n' "$path" >>{shlex.quote(backup)}/new-files
  fi
  if [ "$path" = etc/config/tailscale_gateway ] && [ -f "/$path" ]; then continue; fi
  mkdir -p "/$(dirname "$path")"
  cp -p "$stage/$path" "/$path"
done <"$stage/tsg-install-manifest"
ucode -c -o "$stage/check.ucb" /usr/share/tailscale-gateway/main.uc
ucode -c -o "$stage/rpc.ucb" /usr/share/rpcd/ucode/luci.tailscale_gateway
/etc/init.d/tailscale-gateway enable
/etc/init.d/tailscale-gateway start
/etc/init.d/rpcd reload
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
printf '%s\\n' {shlex.quote(backup)}
'''
# The script is the SSH command, while stdin exclusively carries the archive.
r=subprocess.run(['ssh',args.host,remote],input=archive.getvalue(),capture_output=True)
print(r.stdout.decode());print(r.stderr.decode())
if r.returncode: raise SystemExit(r.returncode)
out=ROOT/'outputs/luci-app-tailscale-gateway'
out.mkdir(parents=True,exist_ok=True)
(out/'installation.json').write_text(json.dumps({'installed_at_utc':stamp,'host':args.host,'backup':backup,'files':manifest,'mode':'observation'},indent=2)+'\n')
