#!/usr/bin/env python3
"""Check the real HTTP RPC boundary with a 30-second read-only test session.

Permissions come from the shipped read ACL. No password or persistent account
is created, and the session ID is never printed or written to an artifact.
"""
import argparse, json, shlex, subprocess, urllib.request
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('url',help='Router management origin, for example http://router.example')
parser.add_argument('--host',default='openwrt',help='SSH host for the same test router')
args=parser.parse_args()
ROOT=Path(__file__).resolve().parents[1]
def ubus(method, value):
    r=subprocess.run(['ssh',args.host,'ubus call session '+method+' '+shlex.quote(json.dumps(value))],capture_output=True,text=True,check=True)
    return json.loads(r.stdout) if r.stdout.strip() else {}
acl=json.loads((ROOT/'packages/luci-app-tailscale-gateway/root/usr/share/rpcd/acl.d/luci-app-tailscale-gateway.json').read_text())['luci-app-tailscale-gateway']
session=ubus('create',{'timeout':30})['ubus_rpc_session']
def rpc(sid, method, parameters):
    body=json.dumps({'jsonrpc':'2.0','id':1,'method':'call','params':[sid,'luci.tailscale_gateway',method,parameters]}).encode()
    with urllib.request.urlopen(urllib.request.Request(args.url.rstrip('/')+'/ubus',data=body,headers={'Content-Type':'application/json'}),timeout=10) as r:
        return json.load(r)
try:
    objects=[[obj,method] for obj,methods in acl['read']['ubus'].items() for method in methods]
    ubus('grant',{'ubus_rpc_session':session,'scope':'ubus','objects':objects})
    assert rpc(session,'status',{})['result'][0]==0
    assert rpc(session,'apply',{'data':{}})['error']['code']==-32002
    assert rpc(session,'subnet_sync',{'data':{}})['error']['code']==-32002
    assert rpc('0'*32,'apply',{'data':{}})['error']['code']==-32002
    print('PASS read-only session can inspect status but cannot apply; anonymous apply denied')
finally:
    ubus('destroy',{'ubus_rpc_session':session})
