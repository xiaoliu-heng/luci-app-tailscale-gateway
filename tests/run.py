#!/usr/bin/env python3
from pathlib import Path
import io, json, subprocess, sys, tarfile

ROOT = Path(__file__).resolve().parents[1]
host = sys.argv[1] if len(sys.argv)>1 else 'openwrt'
subprocess.run([sys.executable, str(ROOT/'scripts/check.py'), host], check=True)
files = {
 'etc/config/network': """config interface 'office'
 option proto 'static'
 option device 'br-office'
 option ipaddr '172.16.9.1/24'
config interface 'lte'
 option proto 'dhcp'
 option device 'eth8'
config interface 'lte6'
 option proto 'dhcpv6'
 option device '@lte'
""",
 'etc/config/firewall': """config defaults
 option forward 'REJECT'
config zone 'inside'
 option name 'inside'
 list network 'office'
config zone 'outside'
 option name 'wan'
 option masq '1'
 list network 'lte'
 list network 'lte6'
""",
 'etc/config/dhcp': """config dnsmasq 'primary'
 option domain 'lan'
 list server '127.0.0.1#1053'
config dnsmasq 'secondary'
 option domain 'guest'
config dnsmasq 'disabled'
 option port '0'
""",
 'etc/config/tailscale_gateway': (ROOT/'packages/tailscale-gateway/files/etc/config/tailscale_gateway').read_text(),
 'etc/config/tailscale': "config settings 'settings'\n option port '41641'\n",
 'status.json': json.dumps({'BackendState':'Running','Self':{'ID':'test','HostName':'test','Online':True},'Peer':{},'TailscaleIPs':['100.100.1.1']}),
 'prefs.json': json.dumps({'Hostname':'test','RouteAll':False,'CorpDNS':False,'NetfilterMode':0,'AdvertiseRoutes':[], 'WantRunning':True}),
 'interfaces.json': json.dumps({'interface':[{'interface':'office','up':True,'ipv4-address':[{'address':'172.16.9.1','mask':24}]}]}),
 'usr/libexec/tsg-test-runner': (ROOT/'tests/test-runner.sh').read_text(),
 'usr/libexec/tailscale-gateway-capture': (ROOT/'packages/tailscale-gateway/files/usr/libexec/tailscale-gateway-capture').read_text()
}
buf=io.BytesIO()
with tarfile.open(fileobj=buf,mode='w') as t:
 for name,content in files.items():
  b=content.encode(); info=tarfile.TarInfo('fixture/'+name); info.size=len(b); info.mode=0o755 if name.startswith('usr/libexec/') else 0o600;t.addfile(info,io.BytesIO(b))
subprocess.run(['ssh',host,'rm -rf /tmp/tsg-dev/fixture && tar -xf - -C /tmp/tsg-dev && mkdir -p /tmp/tsg-dev/fixture/tmp/.uci /tmp/tsg-dev/fixture/var/run/tailscale-gateway /tmp/tsg-dev/fixture/etc/tailscale-gateway'],input=buf.getvalue(),check=True)
r=subprocess.run(['ssh',host,'TSG_ROOT=/tmp/tsg-dev/fixture ucode /tmp/tsg-dev/tests/validation.uc'],capture_output=True,text=True)
print(r.stdout);print(r.stderr,end='');sys.exit(r.returncode)
