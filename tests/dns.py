#!/usr/bin/env python3
"""Exercise the actual ucode DNS compiler against isolated UCI files."""
import copy, json, shlex, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REMOTE = '/tmp/tsg-dev/dns-tests'
COMPILER = '/tmp/tsg-dev/root/usr/share/tailscale-gateway/dns-render.uc'
count = 0
def call(command, data=None):
    return subprocess.run(['ssh','openwrt',command],input=data,text=True,capture_output=True)
def put(name, data):
    r=call('cat >'+shlex.quote(REMOTE+'/'+name), data if isinstance(data,str) else json.dumps(data))
    assert r.returncode == 0, r.stderr
def read(name):
    r=call('cat '+shlex.quote(REMOTE+'/'+name)); assert r.returncode == 0,r.stderr; return r.stdout
def ok(test, label):
    global count
    assert test,label
    count+=1;print('PASS',label)
assert call('mkdir -p '+REMOTE+'/config '+REMOTE+'/save').returncode == 0
status={'BackendState':'Running','Self':{'ID':'fixture'},'TailscaleIPs':['100.64.1.1']}
dns={'CurrentTailnet':{'MagicDNSEnabled':True,'MagicDNSSuffix':'tail.example.ts.net'},
     'SplitDNSRoutes':{'office.example':[{'Addr':'100.64.2.1'},{'Addr':'[fd7a:115c:a1e0::2]:5353'}]}}
put('status.json',status)
put('addresses.json',[{'addr_info':[{'local':'172.16.9.1'}]}])
def render(value, valid=True):
    put('dns.json',value)
    r=call(f'ucode {COMPILER} render {REMOTE}/dns.json {REMOTE}/status.json {REMOTE}/wanted.json {REMOTE}/addresses.json')
    assert (r.returncode==0)==valid, r.stderr
    return json.loads(read('wanted.json')) if valid else None
desired=render(dns)
ok('/tail.example.ts.net/100.100.100.100' in desired['server'] and '/office.example/fd7a:115c:a1e0::2#5353' in desired['server'],'custom MagicDNS suffix and IPv6 resolver port')
for label, value in [('dynamic LAN address','172.16.9.1'),('IPv4-mapped LAN address','::ffff:172.16.9.1'),('loopback','127.0.0.1'),('custom Quad100 forwarding','100.100.100.100'),('unsupported DoH','https://dns.example/dns-query')]:
    bad=copy.deepcopy(dns);bad['SplitDNSRoutes']={'bad.example':[{'Addr':value}]};render(bad,False);ok(True,'reject '+label)
bad=copy.deepcopy(dns);del bad['SplitDNSRoutes'];render(bad,False);ok(True,'incomplete DNS response preserves last good rules')
empty={'version':1,'server':[],'rebind_domain':[]}
base="""config dnsmasq 'primary'
 option domain 'lan'
 list server '127.0.0.1#1053'
config dnsmasq 'guest'
 option domain 'guest'
 list server '/manual.example/192.0.2.1'
"""
def stage(wanted, owner, text, instance, valid=True):
    put('wanted.json',wanted);put('previous.json',owner);put('config/dhcp',text)
    r=call(f'ucode {COMPILER} stage {REMOTE}/wanted.json {REMOTE}/previous.json {REMOTE}/config {REMOTE}/save {REMOTE} {instance}')
    assert (r.returncode==0)==valid,r.stderr
    if not valid:return None
    assert call(f'dnsmasq --test --conf-file={REMOTE}/forward.conf').returncode==0
    return read('config/dhcp'),json.loads(read('owned.json'))
first,owner=stage(desired,empty,base,'guest')
ok("list server '127.0.0.1#1053'" in first and owner['section']=='guest','selected dnsmasq instance retains other instance and manual upstream')
second,owner2=stage(desired,owner,first,'guest')
ok(first==second and owner==owner2,'unchanged DNS is byte-idempotent')
stage(desired,owner,first,'primary',False);ok(True,'uncleared instance switch is rejected')
cleared,empty_owner=stage(empty,owner,first,'guest')
switched,new_owner=stage(desired,empty_owner,cleared,'primary')
ok(new_owner['section']=='primary' and '/manual.example/192.0.2.1' in switched,'clear then switch preserves manually configured rules')
cleared2,empty_owner2=stage(empty,new_owner,switched,'primary')
restored,restored_owner=stage(desired,empty_owner2,cleared2,'guest')
ok(restored==first and restored_owner==owner,'release can restore original DNS instance after switching')
print(f'RESULT {count} DNS assertions passed')
