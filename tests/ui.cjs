#!/usr/bin/env node
// Exercise the shipped LuCI controller with deferred RPC responses and real handlers.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '../packages/luci-app-tailscale-gateway/htdocs/luci-static/resources/tailscale-gateway');
const version = fs.readdirSync(root).filter(n => n.startsWith('v0_')).sort().at(-1);
const handlers = {};
class Element {
 constructor(tag, attrs = {}, children = []) { this.tag = tag; this.attrs = attrs; this.children = children; this.listeners = {}; Object.assign(this, attrs); }
 setAttribute(k, v) { this.attrs[k] = v; }
 addEventListener(k, fn) { this.listeners[k] = fn; }
 appendChild(child) { this.children.push(child); }
 scrollIntoView() {}
}
const E = (tag, attrs, children) => new Element(tag, attrs, children);
const ok = data => ({ ok: true, data });
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const moduleValue = vm.runInNewContext('(function(){' + fs.readFileSync(path.join(root, version, 'ui.js'), 'utf8') + '\n})()', {
 baseclass: { extend: v => v }, rpc: { declare: ({ method }) => (...args) => handlers[method](...args) },
 ui: { createHandlerFn: (_, fn) => fn, showModal() {}, hideModal() {} },
 dom: { content: (node, content) => { node.children = Array.isArray(content) ? content : [content]; } },
 E, Node: Element, _: s => s, L: {}, sessionStorage: { setItem() {}, removeItem() {} },
 setTimeout, Date, console
});
const fresh = () => ({ managed: true, legacy: false, revision: 'r1', interfaces: [], value: { node: { hostname: 'router', autostart: true }, access: { interface: 'tailscale' } } });
function page() {
 const p = moduleValue.page('node'), cfg = fresh();
 Object.assign(p, { cfg, settings: structuredClone(cfg.value), writable: true, dirty: false, busy: false, configBusy: false,
  draftVersion: 0, previewSequence: 0, fields: {}, saved: E('span'), preview: E('div'), jobOutput: E('div'), form: E('div'),
  previewButton: E('button'), reloadButton: E('button'), refresh: async () => {} });
 p.buildForm();
 return p;
}
function edit(p, value) { const field = p.fields['node.hostname']; field.value = value; field.listeners.input(); }
function buttons(node) { return (node.tag === 'button' ? [node] : []).concat((node.children || []).filter(x => x instanceof Element).flatMap(buttons)); }
const plan = ok({ diffs: [], impacts: [], warnings: [], adopt: false });
let count = 0;
async function test(name, fn) { await fn(); console.log('PASS ' + name); count++; }
(async () => {
 await test('editing while a preview is pending discards its response', async () => {
  const p = page(), d = deferred(); handlers.plan = () => d.promise;
  const pending = p.previewChanges(); edit(p, 'new-name'); d.resolve(plan); await pending;
  assert.equal(p.preview.children.length, 0); assert.equal(p.settings.node.hostname, 'new-name');
 });
 await test('an older preview cannot replace a newer preview', async () => {
  const p = page(), old = deferred(), latest = deferred(); let calls = 0;
  handlers.plan = () => (++calls === 1 ? old : latest).promise;
  const first = p.previewChanges(), second = p.previewChanges(); latest.resolve(plan); await second;
  const shown = p.preview.children; old.resolve(ok({ ...plan.data, warnings: ['stale'] })); await first;
  assert.equal(p.preview.children, shown);
 });
 await test('a retained old Apply callback cannot submit a changed draft', async () => {
  const p = page(); handlers.plan = async () => plan; let calls = 0; p.startJob = () => { calls++; };
  await p.previewChanges(); const apply = buttons(p.preview).find(b => b.children[0] === '保存并应用');
  edit(p, 'changed'); await apply.click(); assert.equal(calls, 0);
 });
 await test('cancelled preview cannot later submit through its old callback', async () => {
  const p = page(); handlers.plan = async () => plan; let calls = 0; p.startJob = () => { calls++; };
  await p.previewChanges(); const actions = buttons(p.preview); actions.find(b => b.children[0] === '取消').click();
  await actions.find(b => b.children[0] === '保存并应用').click(); assert.equal(calls, 0);
 });
 await test('node action completion preserves an existing unapplied hostname', async () => {
  const p = page(); edit(p, 'draft'); handlers.job_status = async () => ok({ state: 'done', action: 'node_action' });
  let reloads = 0; p.reloadConfig = async () => { reloads++; }; await p.watchJob('node-job');
  assert.equal(reloads, 0); assert.equal(p.dirty, true); assert.equal(p.settings.node.hostname, 'draft'); assert.equal(p.fields['node.hostname'].disabled, false);
 });
 await test('configuration enqueue locks inputs and failure preserves the draft', async () => {
  const p = page(), d = deferred(); edit(p, 'draft'); handlers.apply = () => d.promise;
  const pending = p.startJob('apply', {}); assert.equal(p.fields['node.hostname'].disabled, true); assert.equal(p.reloadButton.disabled, true);
  d.reject(new Error('enqueue failed')); await pending;
  assert.equal(p.fields['node.hostname'].disabled, false); assert.equal(p.dirty, true); assert.equal(p.settings.node.hostname, 'draft');
 });
 await test('successful apply reloads its committed result and unlocks rebuilt fields', async () => {
  const p = page(), d = deferred(); edit(p, 'committed'); handlers.apply = async () => ok({ id: 'apply-job' });
  handlers.job_status = () => d.promise; handlers.config = async () => { const c = fresh(); c.value.node.hostname = 'committed'; c.revision = 'r2'; return ok(c); };
  const pending = p.startJob('apply', {}); await Promise.resolve(); assert.equal(p.fields['node.hostname'].disabled, true);
  edit(p, 'should-not-change'); assert.equal(p.settings.node.hostname, 'committed');
  d.resolve(ok({ state: 'done', action: 'apply', result: { applied: true } })); await pending;
  assert.equal(p.cfg.revision, 'r2'); assert.equal(p.dirty, false); assert.equal(p.fields['node.hostname'].disabled, false); assert.equal(p.settings.node.hostname, 'committed');
 });
 await test('failed apply unlocks inputs and retains the submitted draft', async () => {
  const p = page(); edit(p, 'draft'); handlers.job_status = async () => ok({ state: 'failed', action: 'apply', error: 'validation failed' });
  await p.watchJob('failed-job'); assert.equal(p.dirty, true); assert.equal(p.settings.node.hostname, 'draft'); assert.equal(p.configBusy, false);
 });
 await test('editing during a config refresh preserves the newer draft', async () => {
  const p = page(), d = deferred(); handlers.config = () => d.promise;
  const pending = p.reloadConfig(); edit(p, 'newer'); d.resolve(ok(fresh())); await pending;
  assert.equal(p.settings.node.hostname, 'newer'); assert.equal(p.dirty, true);
 });
 await test('a failed stale preview cannot overwrite cleared feedback', async () => {
  const p = page(), d = deferred(); handlers.plan = () => d.promise;
  const pending = p.previewChanges(); edit(p, 'changed'); d.reject(new Error('old failure')); await pending;
  assert.equal(p.preview.children.length, 0);
 });
 await test('enabling remote subnet forwarding includes native route acceptance in the same draft', async () => {
  const p = page(); p.settings.access.remote_enabled = false; p.settings.node.accept_routes = false;
  p.field('node', 'accept_routes', 'Accept', 'bool'); p.field('access', 'remote_enabled', 'Remote', 'bool');
  const remote = p.fields['access.remote_enabled']; remote.checked = true; remote.listeners.change();
  assert.equal(p.settings.node.accept_routes, true); assert.equal(p.fields['node.accept_routes'].checked, true); assert.equal(p.dirty, true);
 });
 await test('turning off native route acceptance also disables dependent LAN forwarding', async () => {
  const p = page(); p.settings.access.remote_enabled = true; p.settings.node.accept_routes = true;
  p.field('node', 'accept_routes', 'Accept', 'bool'); p.field('access', 'remote_enabled', 'Remote', 'bool');
  const accept = p.fields['node.accept_routes']; accept.checked = false; accept.listeners.change();
  assert.equal(p.settings.access.remote_enabled, false); assert.equal(p.fields['access.remote_enabled'].checked, false);
 });
 await test('subnet sync completion preserves an unapplied draft and does not display a DNS timestamp', async () => {
  const p = page(); edit(p, 'draft'); handlers.job_status = async () => ok({ state: 'done', action: 'subnet_sync', result: { state: { checked_at: 1 } } });
  await p.watchJob('subnet-job'); assert.equal(p.settings.node.hostname, 'draft'); assert.equal(p.dirty, true);
  assert.ok(!JSON.stringify(p.jobOutput).includes('DNS 最近成功'));
 });
 await test('sixty-second subnet fallback stays fresh and eventually reports a stopped worker', async () => {
  const p = moduleValue.page('access');
  Object.assign(p, { runtime: E('div'), writable: true, cfg: { value: { access: {} } }, state: { subnets: {
   enabled: true, checked_at: Date.now() / 1000 - 65, poll_seconds: 60, state: 'ok', applied: ['203.0.113.0/24'],
   rows: [{ cidr: '203.0.113.0/24', state: 'ready', peers: ['fixture'], reason: 'ready' }]
  } } });
  p.renderRuntime();
  assert.ok(!JSON.stringify(p.runtime).includes('子网同步状态已过期'));
  assert.ok(JSON.stringify(p.runtime).includes('已放行'));
  p.state.subnets.checked_at = Date.now() / 1000 - 180;
  p.renderRuntime();
  assert.ok(JSON.stringify(p.runtime).includes('子网同步状态已过期'));
 });
 console.log(`${count} UI behavior assertions passed`);
})().catch(e => { console.error(e); process.exitCode = 1; });
