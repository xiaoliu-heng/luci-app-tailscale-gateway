#!/usr/bin/env python3
"""Reproducible noarch APK v2 packages, readable by apk-tools 3 as well.

OpenWrt SDK Makefiles remain the normal feed build entry point. This builder
packages interpreted sources directly; no router SDK or cross compiler needed.
See apk-tools/doc/apk-v2.5.scd for split gzip and per-file checksum formats.
"""
from pathlib import Path
import gzip, hashlib, io, json, os, tarfile, time

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT/'dist'; DIST.mkdir(exist_ok=True)
VERSION = '0.2.1-r1'
EPOCH = int(os.environ.get('SOURCE_DATE_EPOCH', '1791417600'))

def archive(files, *, end=True, checksums=False):
    buf=io.BytesIO(); last=0
    with tarfile.open(fileobj=buf,mode='w',format=tarfile.PAX_FORMAT) as t:
        for name,(data,mode) in files.items():
            item=tarfile.TarInfo(name); item.mtime=EPOCH; item.uid=item.gid=0; item.uname=item.gname='root';item.mode=mode
            if data is None:
                item.type=tarfile.DIRTYPE;item.size=0;t.addfile(item)
            else:
                item.size=len(data)
                if checksums: item.pax_headers={'APK-TOOLS.checksum.SHA1':hashlib.sha1(data).hexdigest()}
                t.addfile(item,io.BytesIO(data))
            last=buf.tell()
    return gzip.compress(buf.getvalue() if end else buf.getvalue()[:last],mtime=EPOCH)

def payload(parts):
    files={}
    for part,prefix in parts:
        base=ROOT/part
        for p in sorted(base.rglob('*')):
            if not p.is_file(): continue
            dest=prefix+str(p.relative_to(base))
            for parent in reversed(Path(dest).parents):
                if str(parent)!='.': files.setdefault(str(parent)+'/',(None,0o755))
            files[dest]=(p.read_bytes(),0o755 if '/usr/libexec/' in '/'+dest or '/etc/init.d/' in '/'+dest or '/etc/hotplug.d/' in '/'+dest else 0o644)
    return files

def build(name,desc,parts,deps,scripts,conffiles=()):
    files=payload(parts)
    if conffiles:
        files.setdefault('lib/apk/',(None,0o755))
        files.setdefault('lib/apk/packages/',(None,0o755))
        for suffix in ['conffiles','conffiles_static']:
            files[f'lib/apk/packages/{name}.{suffix}']=(('\n'.join(conffiles)+'\n').encode(),0o644)
    data=archive(files,checksums=True)
    info=[f'pkgname = {name}',f'pkgver = {VERSION}',f'pkgdesc = {desc}','arch = noarch',
          f'size = {sum(len(v[0]) for v in files.values() if v[0] is not None)}',f'builddate = {EPOCH}',
          'license = GPL-2.0-only',f'origin = {name}',f'datahash = {hashlib.sha256(data).hexdigest()}']
    info += ['depend = '+x for x in deps]
    control={'.PKGINFO':(('\n'.join(info)+'\n').encode(),0o644)}
    control.update({'.'+k:(v.encode(),0o755) for k,v in scripts.items()})
    path=DIST/f'{name}-{VERSION}.apk';path.write_bytes(archive(control,end=False)+data)
    return path

core_post='''#!/bin/sh
set -e
for command in ucode ubus ip fw4 flock timeout jsonfilter; do
 command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done
/etc/init.d/tailscale-gateway enable
/etc/init.d/tailscale-gateway start
'''
core_pre_remove='''#!/bin/sh
if ! /usr/libexec/tailscale-gateway check-uninstall; then
 umask 077
 tar -czf /etc/tailscale-gateway/uninstall-recovery.tar.gz /usr/share/tailscale-gateway /usr/libexec/tailscale-gateway* /etc/init.d/tailscale-gateway /etc/config/tailscale_gateway
 echo 'Package removal does not revert managed UCI/DNS rules. Reinstall to release ownership, or restore uninstall-recovery.tar.gz. Tailscale identity is preserved.' >&2
fi
/etc/init.d/tailscale-gateway stop
/etc/init.d/tailscale-gateway disable
'''
ui_post='''#!/bin/sh
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
/etc/init.d/rpcd reload
'''
paths=[build('tailscale-gateway','Tailscale gateway policies and DNS synchronization',
 [('packages/tailscale-gateway/files','')],
 ['tailscale','ip-full','firewall4','busybox','ucode','ucode-mod-fs','ucode-mod-uci','ucode-mod-ubus','ucode-mod-digest','jsonfilter'],
 {'post-install':core_post,'post-upgrade':core_post,'pre-deinstall':core_pre_remove},['/etc/config/tailscale_gateway']),
 build('luci-app-tailscale-gateway','LuCI management for Tailscale gateway',
 [('packages/luci-app-tailscale-gateway/root',''),('packages/luci-app-tailscale-gateway/htdocs','www/')],
 ['tailscale-gateway='+VERSION,'luci-base','rpcd-mod-ucode'],
 {'post-install':ui_post,'post-upgrade':ui_post,'post-deinstall':ui_post})]
(DIST/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in paths))
print('\n'.join(str(p) for p in paths))
