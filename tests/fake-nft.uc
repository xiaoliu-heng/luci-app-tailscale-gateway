import * as fs from 'fs';
let root = getenv('TSG_ROOT'), sets = {};
if (!root) die('Fixture root required');
let text = fs.readfile(ARGV[0]);
for (let name in ['tsg_remote_active', 'tsg_remote_known']) {
	let line = filter(split(text, '\n'), (s) => index(s, 'add element inet fw4 ' + name + ' { ') == 0)[0];
	let entries = line ? split(split(line, '{ ')[1], ' }')[0] : '';
	sets[name] = entries ? split(entries, ', ') : [];
}
fs.writefile(root + '/nft-sets.json', sprintf('%J', sets));
