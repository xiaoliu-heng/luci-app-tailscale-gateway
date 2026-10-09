import * as fs from 'fs';
import { RUN, ensure, save_json, read_json } from '../root/usr/share/tailscale-gateway/common.uc';
ensure();
for (let i = 0; i < 100; i++) {
 save_json(RUN + '/concurrent.json', { writer: ARGV[0], iteration: i });
 let live = read_json(RUN + '/concurrent.json', null);
 if (!live || type(live.iteration) != 'int') die('Concurrent JSON read was incomplete');
}
