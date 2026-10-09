'use strict';
'require baseclass';
'require rpc';
'require ui';
'require poll';
'require dom';

const call = (name, params) => rpc.declare({ object: 'luci.tailscale_gateway', method: name, params: params || [], expect: { '': {} }, reject: true });
const status = call('status'), config = call('config'), plan = call('plan', ['data']), releasePlan = call('release_plan', ['data']);
const jobStatus = call('job_status', ['id']), getLogs = call('logs');
const writes = {};
['apply', 'release', 'node_action', 'dns_sync', 'subnet_sync', 'diagnose', 'rollback', 'recover'].forEach(k => writes[k] = call(k, ['data']));
const unwrap = r => { if (!r.ok) throw new Error(r.error || _('操作失败')); return r.data; };
const text = x => x == null || x === '' ? '—' : String(x);
const when = x => x ? new Date(x * 1000).toLocaleString() : _('尚无记录');
const bytes = x => { if (x == null) return '—'; let n = Number(x), units = ['B', 'KiB', 'MiB', 'GiB'], i = 0; while (n >= 1024 && i < 3) { n /= 1024; i++; } return n.toFixed(i ? 1 : 0) + ' ' + units[i]; };
const clone = x => JSON.parse(JSON.stringify(x));
const configActions = ['apply', 'release', 'rollback', 'recover'];
const labels = { overview: _('概览'), node: _('节点与连接'), uplink: _('上联策略'), access: _('访问与路由'), dns: _('DNS'), diagnostics: _('诊断与日志') };
const descriptions = {
 overview: _('查看节点、出口和 DNS 的实际运行状态。'),
 node: _('管理路由器节点，查看各个 Peer 的连接路径。'),
 uplink: _('Tailscale 传输和 Exit Node 流量共用优先上联；普通流量继续使用系统路由。'),
 access: _('分别控制访问方向。发布路由后，仍需控制台批准并符合 Tailnet ACL。'),
 dns: _('将 MagicDNS 和 Split DNS 同步为条件转发，保留现有默认 DNS 上游。'),
 diagnostics: _('这些检查从路由器发起；客户端到目标的完整路径需要另行实测。')
};
function notice(s, error) { return E('p', { 'class': error ? 'alert-message error' : 'alert-message notice', role: error ? 'alert' : 'status' }, [s]); }
function button(label, fn, primary, disabled) {
 return E('button', { type: 'button', 'class': 'cbi-button ' + (primary ? 'cbi-button-action important' : ''), disabled: disabled ? '' : null, click: ui.createHandlerFn(null, fn) }, [label]);
}
function table(headers, rows) {
 return E('div', { 'class': 'tsg-table' + (headers.length > 3 ? ' tsg-wide' : ''), tabindex: headers.length > 3 ? '0' : null }, [E('table', { 'class': 'table' }, [
  E('thead', {}, [E('tr', { 'class': 'tr table-titles' }, headers.map(h => E('th', { 'class': 'th', scope: 'col' }, [h])))]),
  E('tbody', {}, rows.length ? rows.map(row => E('tr', { 'class': 'tr' }, row.map(cell => E('td', { 'class': 'td' }, [cell instanceof Node ? cell : text(cell)])))) : [E('tr', {}, [E('td', { colspan: headers.length }, [_('暂无记录')])])])
 ])]);
}
function facts(rows) { return table([_('项目'), _('当前状态')], rows); }
function section(title, children) { return E('section', { 'class': 'cbi-section tsg-section' }, [E('h3', {}, [title])].concat(children)); }
function link(page, label) { return E('a', { href: L.url('admin/services/tailscale-gateway/' + page) }, [label]); }
async function copy(value) {
 let copied = false;
 try { if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(value); copied = true; } } catch (_) { /* Use explicit fallback. */ }
 if (!copied) {
  const input = E('textarea', { 'class': 'tsg-copy', 'aria-label': _('待复制文本') }, [value]);
  document.body.appendChild(input); input.select();
  try { copied = document.execCommand('copy') === true; } catch (_) { copied = false; }
  input.remove();
 }
 if (copied) ui.addNotification(null, E('p', {}, [_('已复制')]), 'info');
 else {
  const input = E('input', { type: 'text', readonly: '', value });
  ui.showModal(_('请手动复制'), [E('p', {}, [_('浏览器没有允许自动复制，请选择下方文本复制。')]), input, button(_('关闭'), () => ui.hideModal())]);
  input.focus(); input.select();
 }
}
function copyable(value) {
 return E('span', { 'class': 'tsg-inline' }, [E('span', { 'class': 'tsg-address' }, [text(value)]), value ? button(_('复制'), () => copy(value)) : null]);
}

return baseclass.extend({
 page: function(kind) {
  return {
   handleSaveApply: null, handleSave: null, handleReset: null,
   load: function() { return Promise.all([status().then(unwrap), config().then(unwrap)]); },
   render: function(data) {
    this.kind = kind; this.state = data[0]; this.cfg = data[1]; this.settings = clone(this.cfg.value);
    this.writable = L.hasViewPermission() !== false; this.dirty = false; this.busy = false; this.fields = {};
    this.configBusy = false; this.draftVersion = 0; this.previewSequence = 0;
    this.root = E('div', { 'class': 'tsg-app' });
    this.runtime = E('div', { 'aria-live': 'polite' });
    this.preview = E('div', { 'aria-live': 'polite' });
    this.jobOutput = E('div', { 'aria-live': 'polite' });
    this.saved = E('span', { 'class': 'tsg-help', role: 'status' }, [_('配置已加载')]);
    this.root.appendChild(E('h2', {}, [_('Tailscale 网关') + ' · ' + labels[kind]]));
    this.root.appendChild(E('p', { 'class': 'tsg-intro' }, [descriptions[kind]]));
    if (!this.writable) this.root.appendChild(notice(_('当前为只读权限。')));
    this.root.appendChild(this.runtime);
    this.form = E('div', { 'class': 'tsg-fields' });
    this.buildForm(); this.root.appendChild(this.form);
    if (!['diagnostics'].includes(kind)) {
     this.previewButton = button(this.cfg.managed ? _('预览并应用') : _('预览接管当前配置'), () => this.previewChanges(), true, !this.writable);
     this.reloadButton = button(_('重新加载配置'), () => this.reloadConfig());
     this.root.appendChild(E('div', { 'class': 'tsg-toolbar' }, [this.previewButton, this.reloadButton, this.saved]));
    }
    this.root.appendChild(this.preview); this.root.appendChild(this.jobOutput);
    this.renderRuntime();
    poll.add(() => this.refresh(), 15);
    const pending = sessionStorage.getItem('tsg-job');
    if (pending && this.writable) this.watchJob(pending);
    return E('div', {}, [E('link', { rel: 'stylesheet', href: L.resource('tailscale-gateway/style.css') + '?v=0.2.0-r2' }), this.root]);
   },
   refresh: async function() {
    try { this.state = unwrap(await status()); this.renderRuntime(); }
    catch (e) { dom.content(this.runtime, notice(_('无法刷新状态：') + e.message, true)); }
   },
   setConfigBusy: function(active) {
    this.configBusy = active;
    Object.values(this.fields).forEach(input => { input.disabled = active || !this.writable || (this.cfg.legacy && !this.cfg.managed); });
    if (this.previewButton) this.previewButton.disabled = active || !this.writable;
    if (this.reloadButton) this.reloadButton.disabled = active;
   },
   reloadConfig: async function(discard, fromJob) {
    if (this.configBusy && !fromJob) return;
    if (this.dirty && !discard) {
     ui.showModal(_('放弃未应用的修改？'), [E('p', {}, [_('重新加载将恢复路由器当前配置。')]), E('div', { 'class': 'tsg-toolbar' }, [button(_('取消'), () => ui.hideModal()), button(_('重新加载'), async () => { ui.hideModal(); await this.reloadConfig(true); }, true)])]);
     return;
    }
    const version = this.draftVersion, next = unwrap(await config());
    if (version !== this.draftVersion) return;
    this.cfg = next; this.settings = clone(this.cfg.value); this.fields = {}; this.dirty = false;
    this.draftVersion++; this.previewSequence++;
    if (this.previewButton) this.previewButton.textContent = this.cfg.managed ? _('预览并应用') : _('预览接管当前配置');
    dom.content(this.form, []); this.buildForm(); dom.content(this.preview, []); this.saved.textContent = _('配置已加载');
   },
   field: function(group, key, label, type, hint, choices) {
    const value = this.settings[group][key], fieldId = 'tsg-' + group + '-' + key;
    let input;
    if (type === 'select' || type === 'multi') {
     input = E('select', { id: fieldId, multiple: type === 'multi' ? '' : null, size: type === 'multi' ? Math.min(5, Math.max(2, choices.length)) : null }, choices.map(([v, name]) => E('option', { value: v, selected: (type === 'multi' ? value.includes(v) : value === v) ? '' : null }, [name])));
    } else if (type === 'list') input = E('textarea', { id: fieldId, rows: Math.max(2, Math.min(5, value.length)), spellcheck: 'false' }, [value.join('\n')]);
    else input = E('input', { id: fieldId, type: type === 'bool' ? 'checkbox' : type, checked: type === 'bool' && value ? '' : null, value: type === 'bool' ? null : value, spellcheck: 'false' });
    input.disabled = this.configBusy || !this.writable || (this.cfg.legacy && !this.cfg.managed);
    if (hint) input.setAttribute('aria-describedby', fieldId + '-hint');
    const changed = () => {
     if (this.configBusy) return;
     this.settings[group][key] = type === 'bool' ? input.checked : type === 'number' ? Number(input.value) : type === 'list' ? input.value.split(/[\n,]+/).map(x => x.trim()).filter(Boolean) : type === 'multi' ? Array.from(input.selectedOptions).map(o => o.value) : input.value;
     if (group === 'access' && key === 'remote_enabled' && input.checked) {
      this.settings.node.accept_routes = true;
      if (this.fields['node.accept_routes']) this.fields['node.accept_routes'].checked = true;
     }
     if (group === 'node' && key === 'accept_routes' && !input.checked) {
      this.settings.access.remote_enabled = false;
      if (this.fields['access.remote_enabled']) this.fields['access.remote_enabled'].checked = false;
     }
     this.dirty = true; this.draftVersion++; this.previewSequence++;
     this.saved.textContent = _('有未应用的修改'); dom.content(this.preview, []);
    };
    input.addEventListener('change', changed); input.addEventListener('input', changed);
    this.fields[group + '.' + key] = input;
    return E('div', { 'class': 'cbi-value' }, [E('label', { 'class': 'cbi-value-title', for: fieldId }, [label]), E('div', { 'class': 'cbi-value-field' }, [input, hint ? E('div', { 'class': 'cbi-value-description', id: fieldId + '-hint' }, [hint]) : null])]);
   },
   buildForm: function() {
    const f = this.field.bind(this), sections = [], ifaces = this.cfg.interfaces.filter(x => x.name !== this.settings.access.interface && x.name !== 'loopback').map(x => [x.name, x.name + (x.device ? ' · ' + x.device : '')]);
    if (kind === 'node') sections.push(section(_('节点设置'), [
     f('node', 'hostname', _('节点名称'), 'text'), f('node', 'autostart', _('开机启动 Tailscale'), 'bool')
    ]));
    if (kind === 'uplink') {
     sections.push(section(_('优先上联'), [
      f('uplink', 'enabled', _('启用优先上联'), 'bool', _('关闭后跟随系统路由。不会更改系统 WAN 的 metric。')),
      f('uplink', 'preferred', _('IPv4 接口'), 'select', null, [['', _('不指定')]].concat(ifaces)),
      f('uplink', 'preferred6', _('IPv6 接口'), 'select', _('可单独选择 IPv6 接口。优先 IPv4 可用但 IPv6 不可用时，专用表会阻断 IPv6。'), [['', _('不指定')]].concat(ifaces)),
      f('uplink', 'interval', _('探测间隔（秒）'), 'number'), f('uplink', 'fail_count', _('连续失败次数'), 'number'), f('uplink', 'recover_count', _('连续恢复次数'), 'number'),
      f('uplink', 'probes', _('IPv4 探测地址'), 'list', _('每行一个 IP，任一探测成功即认为该族可用。最多四个。')),
      f('uplink', 'probes6', _('IPv6 探测地址'), 'list'),
      f('uplink', 'restart_on_change', _('出口改变后重连 Tailscale'), 'bool', _('重启 tailscaled 以重建已有连接，会产生短暂重连；节点身份保留。'))
     ]));
     sections.push(E('details', {}, [E('summary', {}, [_('高级路由设置')]), f('uplink', 'table', _('专用路由表'), 'number', _('应用前检查资源冲突；不能使用 DNSRouter 的表 202。'))]));
    }
    if (kind === 'access') {
     sections.push(section(_('LAN 访问 Tailnet'), [
      f('access', 'lan_enabled', _('允许 LAN → Tailnet'), 'bool', _('IPv4 转发及限定范围的 SNAT。远端 ACL 看到路由器身份。')),
      f('access', 'sources', _('允许的 LAN / VLAN'), 'multi', null, ifaces),
      f('access', 'targets', _('Tailnet 目标网段'), 'list', _('范围必须位于 100.64.0.0/10 内。每行一个 CIDR。'))
     ]));
     sections.push(section(_('LAN 访问远端子网'), [
      f('access', 'remote_enabled', _('自动放行远端子网'), 'bool', _('使用上方选定的 LAN / VLAN，自动同步远端 IPv4 子网的转发与 SNAT。启用时同时接受远端路由；远端 ACL 使用路由器身份。')),
      f('access', 'remote_exclude', _('额外排除网段'), 'list', _('每行一个 IPv4 CIDR。与本地非默认路由、本机发布网段、本地优先网段或此列表重叠时，整条远端路由不自动放行。'))
     ]));
     sections.push(section(_('发布与反向访问'), [
      f('node', 'advertise_exit', _('提供 Exit Node'), 'bool'),
      f('access', 'internet_zones', _('互联网出口区域'), 'multi', _('使用现有防火墙区域的 IPv4 NAT；插件维护 Exit Node IPv6 NAT。'), this.cfg.zones.filter(z => z.name !== this.settings.access.zone).map(z => [z.name, z.name])),
      f('node', 'advertise_routes', _('发布子网'), 'list', _('每行一个 CIDR。发布、控制台批准与防火墙放行是独立步骤。')),
      f('access', 'subnet_access', _('允许 Tailnet → 发布子网'), 'bool', _('仅向上方选择的 LAN / VLAN 区域放行所发布的目的网段。')),
      f('access', 'router_access', _('允许 Tailnet 访问路由器服务'), 'bool', _('控制 Tailscale 防火墙区域的入站策略，与 LAN 转发分开。'))
     ]));
     sections.push(section(_('路由接收与本地网络'), [
      f('node', 'accept_routes', _('接受远端子网路由'), 'bool', _('由 Tailscale 维护路由。关闭时也会关闭 LAN 远端子网访问。')),
      f('access', 'local_routes', _('优先使用本地路由的网段'), 'list', _('例如办公室网段。检查与 Tailnet 路由是否重叠。'))
     ]));
     sections.push(E('details', {}, [E('summary', {}, [_('Tailscale 接口与防火墙区域')]),
      f('access', 'interface', _('逻辑接口'), 'text'), f('access', 'device', _('网络设备'), 'text'), f('access', 'zone', _('专用防火墙区域'), 'text')
     ]));
    }
    if (kind === 'dns') sections.push(section(_('同步设置'), [
     f('dns', 'mode', _('运行方式'), 'select', _('暂停保留规则；关闭会移除插件托管的规则，保留手工配置。'), [['sync', _('自动同步')], ['paused', _('暂停更新，保留规则')], ['off', _('关闭并清理托管规则')]]),
     f('dns', 'instance', _('dnsmasq 实例'), 'select', _('使用其他 DNS 服务或已关闭 DNS 的实例需要单独适配。'), [['', _('请选择')]].concat(this.cfg.dnsmasq.map(x => [x.name, x.name + ' · ' + x.domain + ' · :' + x.port]))),
     f('dns', 'interval', _('兜底检查间隔（秒）'), 'number'), f('dns', 'retry', _('失败重试间隔（秒）'), 'number'),
     E('p', { 'class': 'tsg-help' }, [_('开机与接口变化会触发检查；配置未变化时不写入闪存、不 reload dnsmasq。完整 Tailnet 域名可直接使用，短主机名需要客户端搜索域。')])
    ]));
    if (kind === 'diagnostics') {
     this.diagnosticKind = E('select', { id: 'tsg-check-kind' }, [['route', _('路由查询')], ['dns', _('DNS 查询')], ['netcheck', _('Tailscale netcheck')], ['firewall', _('Tailscale 防火墙规则')]].map(([v, name]) => E('option', { value: v }, [name])));
     this.diagnosticTarget = E('input', { id: 'tsg-check-target', type: 'text', placeholder: _('IP 地址或完整域名'), spellcheck: 'false' });
     this.diagnosticKind.addEventListener('change', () => { this.diagnosticTarget.disabled = ['netcheck', 'firewall'].includes(this.diagnosticKind.value); });
     sections.push(section(_('按需检查'), [
      E('label', { for: 'tsg-check-kind' }, [_('检查类型')]), this.diagnosticKind,
      E('label', { for: 'tsg-check-target' }, [_('目标')]), this.diagnosticTarget,
      E('div', { 'class': 'tsg-toolbar' }, [button(_('运行检查'), () => this.startJob('diagnose', { kind: this.diagnosticKind.value, target: this.diagnosticTarget.value.trim() }), true, !this.writable), button(_('读取服务日志'), async () => { const data = unwrap(await getLogs()); dom.content(this.logBox, E('pre', {}, [data.output || _('尚无服务日志')])); })])
     ]));
     this.logBox = E('div'); sections.push(section(_('日志'), [this.logBox]));
     sections.push(button(_('导出排障信息'), () => {
      const data = { exported_at: new Date().toISOString(), version: '0.2.0', status: this.state, configuration: this.cfg.value };
      const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }));
      const a = E('a', { href: url, download: 'tailscale-gateway-diagnostics.json' }); document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
     }));
    }
    dom.content(this.form, sections);
   },
   renderRuntime: function() {
    const s = this.state, sections = [], age = Date.now() / 1000 - (s.checked_at || 0), n = s.node || {}, up = s.uplink || {}, dns = s.dns || {};
    if (this.cfg.legacy && !this.cfg.managed) sections.push(notice(_('检测到旧后台服务。首次按现有配置接管，完成后即可调整设置。')));
    if (age > 90) sections.push(notice(_('状态已过期，请检查后台采集服务。'), true));
    if (s.recovery) sections.push(notice(_('上一次应用需要恢复，请到诊断页面处理。'), true));
    if ((s.drift || []).length) sections.push(notice(_('检测到外部修改：') + s.drift.join(', '), true));
    if (kind === 'overview') {
     sections.push(facts([
      [_('节点'), (n.hostname || '—') + ' · ' + (n.state === 'Running' ? (n.online ? _('已连接') : _('运行中，协调状态离线')) : text(n.state))],
      [_('网关管理'), s.managed ? _('已接管') : _('观察模式')],
      [_('Tailscale IPv4 出口'), up.active === 'system' ? _('系统路由') : text(up.active)],
      [_('Tailscale IPv6 出口'), up.ipv6 === 'blocked' ? _('优先 IPv6 不可用，专用表已阻断') : up.ipv6 === 'system' ? _('系统路由') : text(up.ipv6)],
      [_('DNS 最近成功'), when(dns.last_success)], [_('采集时间'), when(s.checked_at)]
     ]));
     if ((s.warnings || []).length) sections.push(section(_('需要留意'), s.warnings.map(x => E('p', {}, [x]))));
     sections.push(section(_('当前网络'), [this.interfaceTable()]));
     sections.push(E('div', { 'class': 'tsg-toolbar' }, [link('access', _('管理访问与路由')), link('dns', _('管理 DNS')), link('diagnostics', _('打开诊断'))]));
    }
    if (kind === 'node') {
     sections.push(facts([[_('运行状态'), n.state], [_('Tailscale 地址'), E('div', {}, (n.ips || []).map(copyable))], [_('完整 DNS 名'), copyable(n.dns_name)], [_('版本'), n.version]]));
     sections.push(E('div', { 'class': 'tsg-toolbar' }, [
      button(_('登录'), () => this.confirmNode('login', _('开始浏览器登录流程。')), true, !this.writable),
      button(_('连接'), () => this.startJob('node_action', { action: 'connect' }), false, !this.writable),
      button(_('断开'), () => this.confirmNode('disconnect', _('断开后，LAN 到 Tailnet 和本机 Exit Node 将暂时不可用。')), false, !this.writable),
      button(_('启动服务'), () => this.startJob('node_action', { action: 'start' }), false, !this.writable),
      button(_('停止服务'), () => this.confirmNode('stop', _('停止 tailscaled 会中断经本机的 Tailscale 连接。')), false, !this.writable),
      button(_('注销'), () => this.confirmNode('logout', _('注销后需要重新登录；经本机的 Tailnet 访问将中断。')), false, !this.writable)
     ]));
     if ((n.health || []).length) sections.push(section(_('Tailscale 提示'), n.health.map(x => E('p', {}, [x]))));
     const names = { idle: _('空闲，未判断当前路径'), direct4: _('IPv4 直连'), direct6: _('IPv6 直连'), relay: _('中继'), unknown: _('未知') };
     sections.push(section(_('Peers'), [table([_('设备'), _('地址'), _('在线'), _('当前路径'), _('接收 / 发送'), _('检查')], (s.peers || []).map(p => [
      p.hostname, copyable(p.ips[0]), p.online ? _('在线') : _('离线'), names[p.path] + (p.relay ? ' · ' + p.relay : ''),
      bytes(p.rx) + ' / ' + bytes(p.tx),
      button(_('Ping'), () => this.startJob('diagnose', { kind: 'ping', target: p.ips[0] }), false, !this.writable || !p.ips.length)
     ]))]));
    }
    if (kind === 'uplink') {
     sections.push(facts([[_('IPv4 实际出口'), up.active], [_('IPv6 实际出口'), up.ipv6], [_('IPv4 连续成功 / 失败'), text(up.successes) + ' / ' + text(up.failures)], [_('IPv6 连续成功 / 失败'), text(up.ipv6_successes) + ' / ' + text(up.ipv6_failures)], [_('最近探测'), when(up.checked_at)]]));
     if (up.error) sections.push(notice(up.error, true));
     sections.push(section(_('系统上联'), [this.interfaceTable(), E('a', { href: L.url('admin/network/network') }, [_('在网络设置中调整普通上网优先级')])]));
    }
    if (kind === 'access') {
     const remote = s.subnets || {}, stale = Date.now() / 1000 - (remote.checked_at || 0) > (remote.poll_seconds || 300) * 2 + 30;
     const names = { ready: _('已放行'), unavailable: _('不可用'), excluded: _('已排除'), disabled: _('未启用') };
     const rows = (remote.rows || []).map(r => {
      let label = names[r.state] || _('待同步'), reason = r.reason;
      if (r.state === 'ready' && (remote.state !== 'ok' || stale || !(remote.applied || []).includes(r.cidr))) {
       label = _('待同步'); reason = _('尚未确认防火墙放行状态');
      }
      return [E('span', { 'class': 'tsg-address' }, [r.cidr]), label, r.peers.join(', '), reason];
     });
     sections.push(section(_('远端子网状态'), [
      E('p', {}, [remote.enabled ? _('自动同步已启用 · 最近检查：') + when(remote.checked_at) : _('自动同步未启用；下方可开启 LAN 访问。')]),
      remote.enabled && remote.error ? notice(remote.error, true) : null,
      remote.enabled && stale ? notice(_('子网同步状态已过期，请检查后台服务或立即同步。'), true) : null,
      rows.length ? table([_('网段'), _('状态'), _('子网路由器'), _('说明')], rows) : E('p', {}, [_('尚未发现远端 IPv4 子网。请在远端节点发布路由，并在 Tailscale 控制台批准。')]),
      E('p', { 'class': 'tsg-help' }, [_('路由变化时同步，每 300 秒兜底核对；未变化时不重写规则。路由撤回后保留出口保护，防止已识别网段转走其他上联；排除网段或关闭功能会清除对应保护。已放行表示规则就绪，连通性仍受远端服务和 ACL 限制。')]),
      button(_('立即同步子网'), () => this.startJob('subnet_sync', {}), false, !this.writable || !remote.enabled || this.busy)
     ]));
    }
    if (kind === 'dns') {
     const names = { unchanged: _('规则已一致'), updated: _('已更新规则'), error: _('同步失败，保留有效规则'), deferred: _('等待其他配置编辑完成') };
     const modes = { sync: _('自动同步'), paused: _('暂停更新，保留规则'), off: _('已关闭') };
     sections.push(facts([[_('运行方式'), modes[dns.mode] || text(dns.mode)], [_('状态'), names[dns.state] || text(dns.state)], [_('详情'), dns.reason], [_('最近检查'), when(dns.checked_at)], [_('最近成功'), when(dns.last_success)], [_('最近变更'), when(dns.last_change)]]));
     const instance = this.cfg.dnsmasq.find(x => x.name === this.cfg.value.dns.instance);
     sections.push(E('p', {}, [_('原有默认上游：') + ((instance && (instance.servers || []).filter(x => !x.startsWith('/')).join(', ')) || _('按现有 dnsmasq 配置'))]));
     sections.push(section(_('当前托管规则'), [table([_('域名及子域名'), _('DNS 上游')], (dns.rules || []).map(rule => { const parts = rule.split('/'); return [parts[1], parts.slice(2).join('/')]; }))]));
     sections.push(E('div', { 'class': 'tsg-toolbar' }, [button(_('立即同步'), () => this.startJob('dns_sync', {}), false, !this.writable || !s.managed || this.cfg.value.dns.mode !== 'sync'), button(_('预览生成规则'), () => this.startJob('dns_sync', { preview: true }), false, !this.writable || !s.managed || this.cfg.value.dns.mode !== 'sync')]));
    }
    if (kind === 'diagnostics') {
     const rows = [];
     Object.entries(s.services || {}).forEach(([name, instances]) => rows.push([name, instances.length ? instances.map(x => x.running ? _('运行中') + ' · PID ' + x.pid : _('未运行')).join(', ') : _('未运行')]));
     sections.push(section(_('服务'), [facts(rows)]));
     if (s.last_apply) sections.push(section(_('最近应用'), [facts([[_('时间'), when(s.last_apply.time)], [_('状态'), s.last_apply.state], [_('详情'), s.last_apply.error || _('应用完成')]]),
      s.last_apply.state === 'applied' ? button(_('撤销这次应用'), () => this.confirmAction(_('撤销最近应用'), _('仅恢复仍与本次结果一致的托管配置；遇到后续修改将停止自动恢复。'), 'rollback', { id: s.last_apply.id }), false, !this.writable) : null]));
     if (s.recovery) sections.push(button(_('恢复未完成的应用'), () => this.startJob('recover', {}), false, !this.writable));
     if (s.managed) sections.push(button(_('预览撤销接管'), async () => {
      try {
       const fresh = unwrap(await config()), input = { revision: fresh.revision }, data = unwrap(await releasePlan(input));
       dom.content(this.preview, section(_('撤销接管预览'), [
        E('p', {}, [_('恢复接管前的托管资源和原生偏好，停止网关扩展服务。存在旧后台服务时恢复其原有状态。')]),
        table([_('资源'), _('当前'), _('恢复为')], data.diffs.map(x => [x.resource, E('pre', {}, [JSON.stringify(x.before, null, 2)]), E('pre', {}, [JSON.stringify(x.after, null, 2)])])),
        button(_('撤销接管'), () => this.startJob('release', input), true, !this.writable)
       ]));
      } catch (e) { dom.content(this.preview, notice(e.message, true)); }
     }, false, !this.writable));
    }
    dom.content(this.runtime, sections);
   },
   interfaceTable: function() {
    return table([_('接口'), _('状态'), _('设备'), _('IPv4'), _('默认路由 metric')], (this.state.interfaces || []).filter(x => x.interface !== 'loopback').map(x => [x.interface, x.up ? _('已连接') : _('未连接'), x.l3_device, (x['ipv4-address'] || []).map(a => a.address + '/' + a.mask).join(', '), x.metric]));
   },
   confirmNode: function(action, message) { return this.confirmAction(_('Tailscale 节点操作'), message, 'node_action', { action }); },
   confirmAction: function(title, message, operation, data) {
    ui.showModal(title, [E('p', {}, [message]), E('div', { 'class': 'tsg-toolbar' }, [button(_('取消'), () => ui.hideModal()), button(_('确认执行'), () => { ui.hideModal(); return this.startJob(operation, data); }, true)])]);
   },
   previewChanges: async function() {
    if (this.configBusy) return;
    const sequence = ++this.previewSequence, version = this.draftVersion;
    try {
     const input = { revision: this.cfg.revision, value: clone(this.settings), adopt: !this.cfg.managed };
     const data = unwrap(await plan(input));
     if (sequence !== this.previewSequence || version !== this.draftVersion) return;
     const changes = data.diffs.map(x => [x.resource, E('pre', {}, [JSON.stringify(x.before, null, 2)]), E('pre', {}, [JSON.stringify(x.after, null, 2)])]);
     dom.content(this.preview, section(_('应用预览'), [
      E('p', {}, [data.adopt ? _('将接管当前配置并交接旧后台服务。Tailscale 身份保留。') : _('以下配置将在校验后应用。')]),
      changes.length ? table([_('资源'), _('现有'), _('应用后')], changes) : E('p', {}, [_('现有规则无需改变。')]),
      E('ul', {}, data.impacts.map(x => E('li', {}, [x]))), E('ul', {}, data.warnings.map(x => E('li', {}, [x]))),
      E('div', { 'class': 'tsg-toolbar' }, [button(_('取消'), () => { this.previewSequence++; dom.content(this.preview, []); }), button(data.adopt ? _('接管并应用') : _('保存并应用'), () => {
       if (sequence !== this.previewSequence || version !== this.draftVersion || input.revision !== this.cfg.revision) {
        dom.content(this.preview, notice(_('设置已变化，请重新预览。'), true)); return;
       }
       return this.startJob('apply', input);
      }, true, !this.writable || this.busy)])
     ]));
     this.preview.scrollIntoView({ block: 'nearest' });
    } catch (e) { if (sequence === this.previewSequence && version === this.draftVersion) dom.content(this.preview, notice(e.message, true)); }
   },
   startJob: async function(operation, data) {
    if (this.busy) return;
    this.busy = true;
    if (configActions.includes(operation)) this.setConfigBusy(true);
    try {
     const job = unwrap(await writes[operation](data));
     sessionStorage.setItem('tsg-job', job.id);
     await this.watchJob(job.id);
    } catch (e) { this.busy = false; this.setConfigBusy(false); dom.content(this.jobOutput, notice(e.message, true)); }
   },
   watchJob: async function(id) {
    this.busy = true;
    this.setConfigBusy(true);
    dom.content(this.jobOutput, notice(_('后台操作进行中，可离开此页面。操作记录：') + id));
    const started = Date.now();
    try {
     let result;
     for (;;) {
      result = unwrap(await jobStatus(id));
      this.setConfigBusy(configActions.includes(result.action));
      if (['done', 'failed'].includes(result.state)) break;
      if (Date.now() - started > 240000) throw new Error(_('等待超时；操作可能仍在执行，请刷新诊断页面，勿重复提交。'));
      await new Promise(resolve => setTimeout(resolve, 1500));
     }
     sessionStorage.removeItem('tsg-job');
     if (result.state === 'failed') throw new Error(result.error || _('后台操作失败'));
     if (configActions.includes(result.action)) await this.reloadConfig(true, true);
     else if (result.action === 'node_action' && !this.dirty) await this.reloadConfig();
     await this.refresh();
     const data = result.result || {}, content = [notice(_('操作已完成'))];
     if (data.output) content.push(E('pre', {}, [data.output]));
     if (data.auth_url && /^https:\/\/[a-zA-Z0-9.-]+\/a\//.test(data.auth_url)) content.push(E('a', { href: data.auth_url, target: '_blank', rel: 'noopener noreferrer' }, [_('打开 Tailscale 登录页面')]));
     if (data.scope === 'router') content.push(E('p', {}, [_('路由器侧检查退出码：') + data.exit_code]));
     if (data.applied) content.push(E('p', {}, [data.released ? _('已恢复接管前的配置。') : data.adopted ? _('当前配置已接管，后台服务已完成交接。') : _('设置已应用并完成校验。')]));
     if (result.action === 'dns_sync' && data.state) content.push(E('p', {}, [_('DNS 最近成功：') + when(data.state.last_success)]));
     dom.content(this.jobOutput, content);
    } catch (e) { dom.content(this.jobOutput, notice(e.message, true)); }
    finally { this.busy = false; this.setConfigBusy(false); }
   }
  };
 }
});
