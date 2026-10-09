import * as fs from 'fs';
import { sync_subnets } from './subnets.uc';
import { RUN, STATE, read_json, save_json, ensure } from './common.uc';
import { configuration, collect } from './state.uc';
import { make_plan } from './planner.uc';
import { recover } from './apply.uc';
import { job, logs } from './operations.uc';

ensure();
try {
	let value;
	if (ARGV[0] == 'snapshot') value = collect();
	else if (ARGV[0] == 'subnet-sync') {
		let cfg = configuration();
		if (!cfg.managed || !cfg.value.access.remote_enabled || !read_json(STATE + '/owned.json', null)) die('远端子网同步未启用。');
		let snap = collect();
		value = sync_subnets(configuration().value, snap);
	}
	else if (ARGV[0] == 'config') value = configuration();
	else if (ARGV[0] == 'plan') value = make_plan(json(fs.readfile(ARGV[1])));
	else if (ARGV[0] == 'job') value = job(ARGV[1]);
	else if (ARGV[0] == 'recover') value = recover();
	else if (ARGV[0] == 'logs') value = logs();
	else if (ARGV[0] == 'check-uninstall') {
		if (configuration().managed) die('Gateway policies are still managed. Revert adoption before removing the package.');
		value = { ok: true };
	} else die('Unknown command');
	print(sprintf('%J\n', { ok: true, data: value }));
} catch (e) { print(sprintf('%J\n', { ok: false, error: e.message || '' + e })); exit(1); }
