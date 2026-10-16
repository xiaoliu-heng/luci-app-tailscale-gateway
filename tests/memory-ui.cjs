const fs = require('node:fs'), vm = require('node:vm'), path = require('node:path'), assert = require('node:assert/strict');
const root = path.join(__dirname, '../packages/luci-app-tailscale-gateway/htdocs/luci-static/resources/view/tailscale-gateway');
const version = fs.readdirSync(root).filter(name => name.startsWith('v0_')).sort().at(-1);
const handlers = {}, store = new Map();
class Element {
 constructor(tag, attrs = {}, children = []) { this.tag = tag; this.attrs = attrs; this.children = children; this.listeners = {}; Object.assign(this, attrs); }
 setAttribute(key, value) { this.attrs[key] = value; }
 addEventListener(key, fn) { this.listeners[key] = fn; }
 setCustomValidity(value) { this.validationMessage = value; }
 reportValidity() { return !this.validationMessage; }
}
const E = (tag, attrs, children) => new Element(tag, attrs, children);
const ok = data => ({ ok: true, data });
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
let writable = true;
const moduleValue = vm.runInNewContext('(function(){' + fs.readFileSync(path.join(root, version, 'memory.js'), 'utf8') + '\n})()', {
 view: { extend: value => value }, rpc: { declare: ({ method }) => (...args) => handlers[method](...args) },
 ui: { createHandlerFn: (_, fn) => fn, showModal() {}, hideModal() {} }, poll: { add() {} },
 dom: { content: (node, children) => { node.children = Array.isArray(children) ? children : [children]; } },
 E, _: text => text, L: { hasViewPermission: () => writable, resource: value => value },
 sessionStorage: { getItem: key => store.get(key), setItem: (key,value) => store.set(key,value), removeItem: key => store.delete(key) },
 setTimeout, Date, console
});
const fresh = () => ({ revision: 'r1', checked_at: Date.now() / 1000,
 value: { enabled: true, rss_high_mib: 96, available_low_mib: 80, interval: 10, cooldown: 60 },
 process: { pid: 201, rss_kib: 60000, hwm_kib: 210000 }, system: { available_kib: 140000, total_kib: 500000 },
 service: { running: true }, protection: { gc_requests: 5, last_result: 'ok', last_gc: 1, observed_peak_kib: 120000, checked_at: Date.now() / 1000 },
 events: [], go_budget: { configured_limit: '128MiB', configured_gogc: '50', running_limit: null, pending: true }
});
function page() { store.clear(); const page = { ...moduleValue }; page.render(fresh()); return page; }
function edit(page, value) { const input = page.inputs.rss_high_mib; input.value = String(value); input.listeners.input(); }
let count = 0;
async function test(label, fn) { await fn(); console.log('PASS ' + label); count++; }
(async () => {
 await test('status polling preserves an unapplied threshold draft', async () => {
  const p = page(); edit(p, 112); const data = fresh(); data.process.rss_kib = 70000; handlers.memory_status = async () => ok(data);
  await p.refresh(); assert.equal(p.settings.rss_high_mib,112); assert.equal(p.inputs.rss_high_mib.value,'112'); assert.equal(p.data.process.rss_kib,70000);
 });
 await test('external edits refresh untouched settings but preserve a conflicting draft', async () => {
  const p = page(), data = fresh(); data.revision = 'r2'; data.value.rss_high_mib = 120; handlers.memory_status = async () => ok(data);
  await p.refresh(); assert.equal(p.settings.rss_high_mib,120); assert.equal(p.revision,'r2');
  edit(p,112); data.revision = 'r3'; await p.refresh(); assert.equal(p.revision,'r2'); assert.equal(p.settings.rss_high_mib,112); assert.match(p.feedback.textContent,/其他会话/);
 });
 await test('editing during configuration reload preserves the newer draft', async () => {
  const p = page(), d = deferred(); handlers.memory_status = () => d.promise; const pending = p.reload(); edit(p,112); d.resolve(ok(fresh())); await pending;
  assert.equal(p.settings.rss_high_mib,112); assert.equal(p.dirty,true);
 });
 await test('invalid and fractional thresholds never enqueue a job', async () => {
  const p = page(); let calls = 0; handlers.memory_apply = () => { calls++; };
  for (const value of [63,193,96.5,'']) { edit(p,value); await p.save(); }
  assert.equal(calls,0);
 });
 await test('saving locks fields and enqueue failure retains the draft', async () => {
  const p = page(), d = deferred(); edit(p,112); handlers.memory_apply = () => d.promise;
  const pending = p.save(); assert.equal(p.inputs.enabled.disabled,true); assert.equal(p.reloadButton.disabled,true);
  edit(p,120); assert.equal(p.settings.rss_high_mib,112); d.reject(new Error('enqueue failed')); await pending;
  assert.equal(p.inputs.enabled.disabled,false); assert.equal(p.dirty,true); assert.equal(p.settings.rss_high_mib,112);
 });
 await test('completed job reloads only committed memory settings', async () => {
  const p = page(); edit(p,112); handlers.memory_apply = async input => { assert.equal(input.revision,'r1'); assert.equal(input.value.rss_high_mib,112); return ok({ id: 'guard-job' }); };
  const data = fresh(); data.revision = 'r2'; data.value.rss_high_mib = 112;
  handlers.job_status = async () => ok({ action: 'memory_apply', state: 'done', result: { status: data, output: 'saved' } });
  await p.save(); assert.equal(p.revision,'r2'); assert.equal(p.dirty,false); assert.equal(p.busy,false); assert.equal(store.has('tsg-memory-job'),false);
 });
 await test('backend rejection unlocks controls without losing the draft', async () => {
  const p = page(); edit(p,112); handlers.job_status = async () => ok({ action: 'memory_apply', state: 'failed', error: 'stale revision' });
  await p.watchJob('job'); assert.equal(p.dirty,true); assert.equal(p.settings.rss_high_mib,112); assert.equal(p.busy,false); assert.equal(p.feedback.textContent,'stale revision');
 });
 await test('read-only view disables all settings and cannot enqueue writes', async () => {
  writable = false; const p = page(); let calls = 0; handlers.memory_apply = () => { calls++; }; await p.save();
  assert.equal(calls,0); assert.equal(p.inputs.enabled.disabled,true); assert.equal(p.saveButton.disabled,true); writable = true;
 });
 await test('pending Go startup settings are never displayed as active', async () => {
  const p = page(); assert.match(JSON.stringify(p.runtime),/尚未在当前进程生效/); assert.match(JSON.stringify(p.runtime),/默认（100）/);
 });
 await test('status refresh preserves expanded Go budget and recovery records', async () => {
  const p = page(); p.budgetDetail.open = true; p.historyDetail.open = true; p.renderRuntime();
  assert.equal(p.budgetDetail.attrs.open,''); assert.equal(p.historyDetail.attrs.open,'');
 });
 await test('historical events from a reused PID do not become current-process recovery statistics', async () => {
  const p = page(); p.data.protection = null;
  p.data.events = [{ pid:201, before_kib:102400, after_kib:51200, available_kib:140000, result:'ok', at:'2026-01-01T00:00:00Z' }];
  p.renderRuntime(); assert.ok(!JSON.stringify(p.runtime).includes('100.0 MiB → 50.0 MiB'));
 });
 console.log(`${count} memory UI behavior assertions passed`);
})().catch(error => { console.error(error); process.exitCode = 1; });
