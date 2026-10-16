'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

const declare = (method, params) => rpc.declare({ object: 'luci.tailscale_gateway', method, params: params || [], expect: { '': {} }, reject: true });
const getStatus = declare('memory_status'), apply = declare('memory_apply', ['data']), getJob = declare('job_status', ['id']);
const unwrap = value => { if (!value.ok) throw new Error(value.error || _('操作失败')); return value.data; };
const clone = value => JSON.parse(JSON.stringify(value));
const mib = value => value == null ? '—' : (value / 1024).toFixed(1) + ' MiB';
const when = value => value ? new Date(typeof value === 'number' ? value * 1000 : value).toLocaleString() : _('尚无记录');
const outcomes = { ok: _('成功'), failed: _('失败'), unavailable: _('进程已退出'), none: _('尚无记录') };
const fields = [
 ['enabled', _('启用内存保护'), null, null, _('回收闲置内存，保持 Tailscale 进程和连接。')],
 ['rss_high_mib', _('Tailscale RSS 阈值（MiB）'), 64, 192, _('达到此占用时触发回收，范围 64–192 MiB。')],
 ['available_low_mib', _('系统可用内存阈值（MiB）'), 32, 128, _('低于此值且 Tailscale 占用至少 48 MiB 时触发，范围 32–128 MiB。')],
 ['interval', _('检查间隔（秒）'), 10, 60, _('只读取进程内存，范围 10–60 秒。')],
 ['cooldown', _('回收冷却时间（秒）'), 30, 300, _('两次触发至少间隔此时长，每次最多两次 GC，范围 30–300 秒。')]
];
function table(headers, rows) {
 return E('div', { 'class': 'tsg-table' + (headers.length > 3 ? ' tsg-wide' : '') }, [E('table', { 'class': 'table' }, [
  E('thead', {}, [E('tr', { 'class': 'tr table-titles' }, headers.map(value => E('th', { 'class': 'th', scope: 'col' }, [value])))]),
  E('tbody', {}, rows.length ? rows.map(row => E('tr', { 'class': 'tr' }, row.map(value => E('td', { 'class': 'td' }, [value])))) : [E('tr', {}, [E('td', { colspan: headers.length }, [_('暂无记录')])])])
 ])]);
}
function button(label, action, primary) {
 return E('button', { type: 'button', 'class': 'cbi-button ' + (primary ? 'cbi-button-action important' : ''), click: ui.createHandlerFn(null, action) }, [label]);
}

return view.extend({
 handleSaveApply: null, handleSave: null, handleReset: null,
 load: () => getStatus().then(unwrap),
 render: function(data) {
  this.data = data; this.settings = clone(data.value); this.revision = data.revision;
  this.dirty = false; this.busy = false; this.editVersion = 0; this.refreshId = 0;
  this.writable = L.hasViewPermission() !== false; this.inputs = {};
  this.runtime = E('div', { 'aria-live': 'polite' }); this.form = E('div', { 'class': 'tsg-fields' });
  this.feedback = E('p', { role: 'status', 'class': 'tsg-help' }, [_('配置已加载')]);
  this.saveButton = button(_('保存并应用'), () => this.save(), true);
  this.reloadButton = button(_('重新加载配置'), () => this.reload());
  this.buildForm(); this.renderRuntime(); this.lock(false);
  poll.add(() => this.refresh(), 15);
  const pending = sessionStorage.getItem('tsg-memory-job');
  if (pending && this.writable) this.watchJob(pending);
  return E('div', {}, [
   E('link', { rel: 'stylesheet', href: L.resource('tailscale-gateway/style.css') + '?v=0.2.3-r1' }),
   E('div', { 'class': 'tsg-app' }, [
    E('h2', {}, [_('Tailscale 网关 · 内存保护')]),
    E('p', { 'class': 'tsg-intro' }, [_('查看进程占用并回收闲置内存。保存设置只更新内存保护服务。')]),
    this.writable ? null : E('p', { 'class': 'alert-message notice' }, [_('当前为只读权限。')]),
    this.runtime, E('section', { 'class': 'cbi-section tsg-section' }, [E('h3', {}, [_('保护设置')]), this.form]),
    E('div', { 'class': 'tsg-toolbar' }, [this.saveButton, this.reloadButton]), this.feedback
   ])
  ]);
 },
 buildForm: function() {
  this.inputs = {};
  dom.content(this.form, fields.map(([key, label, min, max, hint]) => {
   const boolean = key === 'enabled', id = 'tsg-memory-' + key;
   const input = E('input', { id, type: boolean ? 'checkbox' : 'number', checked: boolean && this.settings[key] ? '' : null,
    value: boolean ? null : this.settings[key], min, max, step: boolean ? null : 1, required: boolean ? null : '' });
   input.disabled = this.busy || !this.writable;
   const changed = () => {
    if (this.busy || !this.writable) return;
    this.settings[key] = boolean ? input.checked : Number(input.value);
    this.dirty = true; this.editVersion++; this.feedback.textContent = _('有未应用的修改');
   };
   input.addEventListener('input', changed); input.addEventListener('change', changed);
   input.setAttribute('aria-describedby', id + '-hint'); this.inputs[key] = input;
   return E('div', { 'class': 'cbi-value' }, [E('label', { 'class': 'cbi-value-title', for: id }, [label]),
    E('div', { 'class': 'cbi-value-field' }, [input, E('div', { 'class': 'cbi-value-description', id: id + '-hint' }, [hint])])]);
  }));
 },
 renderRuntime: function() {
  const data = this.data, proc = data.process || {}, cached = data.protection || {}, service = data.service || {};
  const state = !data.value.enabled ? _('已关闭') : service.running ? _('保护运行中') : _('保护未运行');
  const recent = cached.last_gc ? (data.events || []).filter(event => event.pid === proc.pid).at(-1) : null;
  const before = cached.last_rss_before_kib || (recent && recent.before_kib), after = cached.last_rss_after_kib || (recent && recent.after_kib);
  const children = [table([_('项目'), _('当前状态')], [
   [_('Tailscale 当前占用（RSS）'), mib(proc.rss_kib)], [_('本进程历史峰值'), mib(proc.hwm_kib)],
   [_('保护观测峰值'), mib(cached.observed_peak_kib)],
   [_('系统可用 / 总内存'), mib(data.system.available_kib) + ' / ' + mib(data.system.total_kib)],
   [_('保护状态'), state], [_('最近回收'), when(cached.last_gc)],
   [_('最近回收前 → 后'), before == null ? '—' : mib(before) + ' → ' + mib(after)],
   [_('GC 请求次数 / 结果'), (cached.gc_requests || 0) + ' / ' + (outcomes[cached.last_result] || _('尚无记录'))],
   [_('状态时间'), when(data.checked_at)]
  ])];
  if (!data.process) children.push(E('p', { 'class': 'alert-message notice' }, [_('Tailscale 进程未运行，保护会等待进程启动。')]));
  if (data.value.enabled && !service.running) children.push(E('p', { 'class': 'alert-message warning' }, [_('保护已启用但服务未运行，可保存设置以重新启动保护服务。')]));
  if (data.value.enabled && service.running && (!cached.checked_at || Date.now() / 1000 - cached.checked_at > data.value.interval * 3 + 20))
   children.push(E('p', { 'class': 'alert-message warning' }, [_('保护采样暂未更新，请查看保护服务是否正常。')]));
  if (cached.last_result === 'failed') children.push(E('p', { 'class': 'alert-message warning' }, [_('在线回收失败，请检查 Tailscale 版本是否支持本地堆分析接口。')]));
  const budget = data.go_budget || {};
  if (budget.configured_limit || budget.configured_gogc || budget.running_limit || budget.running_gogc) {
   this.budgetDetail = E('details', { open: this.budgetDetail && this.budgetDetail.open ? '' : null }, [
   E('summary', {}, [_('Go 内存预算')]), table([_('项目'), _('当前状态')], [
    [_('当前进程 GOMEMLIMIT'), budget.running_limit || _('未设置')], [_('当前进程 GOGC'), budget.running_gogc || _('默认（100）')],
    [_('启动配置 GOMEMLIMIT'), budget.configured_limit || _('未设置')], [_('启动配置 GOGC'), budget.configured_gogc || _('未设置')]
   ]), E('p', { 'class': 'tsg-help' }, [budget.pending ? _('启动预算尚未在当前进程生效，将在下次正常启动时应用。') : _('当前进程已使用所列环境设置。')]),
   E('p', { 'class': 'tsg-help' }, [_('Go 预算是软限制，不等同于 RSS 上限。在线回收只释放闲置内存，极端负载下仍可能超限。')])
   ]); children.push(this.budgetDetail);
  }
  this.historyDetail = E('details', { open: this.historyDetail && this.historyDetail.open ? '' : null }, [E('summary', {}, [_('最近回收记录')]), table([_('时间'), _('回收前'), _('回收后'), _('系统可用'), _('结果')],
   (data.events || []).slice().reverse().map(event => [when(event.at), mib(event.before_kib), mib(event.after_kib), mib(event.available_kib), outcomes[event.result] || event.result]))]);
  children.push(this.historyDetail);
  dom.content(this.runtime, children);
 },
 lock: function(active) {
  this.busy = active;
  Object.values(this.inputs).forEach(input => { input.disabled = active || !this.writable; });
  this.saveButton.disabled = active || !this.writable; this.reloadButton.disabled = active;
 },
 replaceConfig: function(data) {
  this.data = data; this.settings = clone(data.value); this.revision = data.revision; this.dirty = false;
  this.editVersion++; this.refreshId++; this.buildForm(); this.renderRuntime(); this.feedback.textContent = _('配置已加载');
 },
 refresh: async function() {
  const request = ++this.refreshId, version = this.editVersion;
  try {
   const data = unwrap(await getStatus()); if (request !== this.refreshId) return;
   this.data = data; this.renderRuntime();
   if (!this.busy && !this.dirty && version === this.editVersion && data.revision !== this.revision) this.replaceConfig(data);
   else if (this.dirty && data.revision !== this.revision) this.feedback.textContent = _('配置已在其他会话修改，请重新加载后再保存。');
  } catch (error) { if (request === this.refreshId) this.feedback.textContent = _('无法刷新状态：') + error.message; }
 },
 reload: async function(discard) {
  if (this.busy) return;
  if (this.dirty && !discard) {
   ui.showModal(_('放弃未应用的修改？'), [E('p', {}, [_('重新加载路由器当前的保护设置。')]),
    E('div', { 'class': 'tsg-toolbar' }, [button(_('取消'), () => ui.hideModal()), button(_('重新加载'), () => { ui.hideModal(); return this.reload(true); }, true)])]);
   return;
  }
  const version = this.editVersion;
  try { const data = unwrap(await getStatus()); if (version === this.editVersion && !this.busy) this.replaceConfig(data); }
  catch (error) { this.feedback.textContent = error.message; }
 },
 save: async function() {
  if (this.busy || !this.writable) return;
  for (const [key, label, min, max] of fields) if (key !== 'enabled') {
   const input = this.inputs[key], value = this.settings[key];
   input.setCustomValidity(Number.isInteger(value) && input.value !== '' && value >= min && value <= max ? '' : label + _('请输入范围内的整数。'));
   if (!input.reportValidity()) return;
  }
  this.lock(true); this.feedback.textContent = _('正在应用内存保护设置…');
  try {
   const job = unwrap(await apply({ revision: this.revision, value: clone(this.settings) }));
   sessionStorage.setItem('tsg-memory-job', job.id); await this.watchJob(job.id);
  } catch (error) { this.feedback.textContent = error.message; this.lock(false); }
 },
 watchJob: async function(id) {
  this.lock(true);
  try {
   for (let i = 0; i < 180; i++) {
    const job = unwrap(await getJob(id));
    if (job.action !== 'memory_apply') { sessionStorage.removeItem('tsg-memory-job'); throw new Error(_('内存保护任务不匹配。')); }
    if (job.state === 'failed') { sessionStorage.removeItem('tsg-memory-job'); throw new Error(job.error || _('内存保护设置应用失败。')); }
    if (job.state === 'done') {
     this.replaceConfig(job.result.status); this.feedback.textContent = job.result.output;
     sessionStorage.removeItem('tsg-memory-job'); return;
    }
    await new Promise(resolve => setTimeout(resolve, 500));
   }
   throw new Error(_('后台任务仍在执行，可稍后重新打开此页查看结果。'));
  } catch (error) { this.feedback.textContent = error.message; }
  finally { this.lock(false); }
 }
});
