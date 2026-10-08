import { readfile, writefile } from 'fs';
let p = json(readfile(ARGV[0]));
for (let arg in slice(ARGV, 2)) {
 let item = split(arg, '='), k = item[0], v = item[1];
 if (k == '--netfilter-mode') p.NetfilterMode = v == 'off' ? 0 : v == 'on' ? 2 : 1;
 if (k == '--hostname') p.Hostname = v;
 if (k == '--accept-routes') p.RouteAll = v == 'true';
 if (k == '--accept-dns') p.CorpDNS = v == 'true';
 if (k == '--advertise-routes') p.AdvertiseRoutes = filter(p.AdvertiseRoutes, (x) => x == '0.0.0.0/0' || x == '::/0');
 if (k == '--advertise-routes' && v) push(p.AdvertiseRoutes, ...split(v, ','));
 if (k == '--advertise-exit-node') {
  p.AdvertiseRoutes = filter(p.AdvertiseRoutes, (x) => x != '0.0.0.0/0' && x != '::/0');
  if (v == 'true') push(p.AdvertiseRoutes, '0.0.0.0/0', '::/0');
 }
}
writefile(ARGV[0], sprintf('%J', p));
