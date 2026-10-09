# Tailscale Gateway for LuCI

通过 OpenWrt 后台管理 Tailscale 节点、优先上联、LAN 访问 Tailnet、Exit Node 和条件 DNS。使用原生 LuCI、rpcd/ucode、UCI、procd、fw4，不增加管理端口，不复制 Tailscale 身份。

## 软件包

- `tailscale-gateway`：配置规划与事务、上联监测、远端子网同步、DNS 同步、状态采集。
- `luci-app-tailscale-gateway`：概览、节点与连接、上联策略、访问与路由、DNS、诊断与日志。

当前版本 `0.2.0-r2`。实机目标是 OpenWrt SNAPSHOT / apk / fw4 / Tailscale 1.102.3。架构无关指这些脚本和页面；目标路由器仍须安装适配自身架构的 Tailscale 和其他依赖。尚未完成稳定版 SDK、第二台硬件的兼容验证。

## 安装

从 [GitHub Releases](https://github.com/xiaoliu-heng/luci-app-tailscale-gateway/releases) 下载同一版本的两个 APK 和 `SHA256SUMS`（也可按下文从源码构建到 `dist/`），核对校验值后将两个 APK 放到目标路由器。在依赖已安装时运行：

```sh
apk verify --allow-untrusted /tmp/tailscale-gateway-0.2.0-r2.apk /tmp/luci-app-tailscale-gateway-0.2.0-r2.apk
apk add --allow-untrusted --network=no /tmp/tailscale-gateway-0.2.0-r2.apk /tmp/luci-app-tailscale-gateway-0.2.0-r2.apk
```

这些是本地构建、未签名的包，`--allow-untrusted` 仅作用于本次安装，不修改全局信任配置。其他路由器可先从自己的 OpenWrt 软件源安装依赖，再安装本地包。

安装后进入 **服务 → Tailscale 网关**。初始为观察模式，安装本身不会接管网络策略。配置完成后点击“预览接管当前配置”，检查差异，再应用。检测到本项目旧脚本时，第一次只能按现状接管，后续再修改设置。升级保留 UCI 和所有权记录；rpcd 使用 reload 保留登录会话。

前提：fw4、TUN 网络模式、rpcd-mod-ucode、ucode 的 fs/uci/ubus/digest 模块、ip-full、jsonfilter，以及 BusyBox 的 flock/timeout。DNS 同步需要可读取 `tailscale dns status --json`，并选择监听 53 端口的 dnsmasq 实例。使用远端 Exit Node、userspace networking 和其他 DNS 服务的路由器不在首版接管范围。

## 功能与行为

| 页面 | 管理内容 |
| --- | --- |
| 概览 | 节点状态、实际出口、DNS 最近成功、当前接口和配置漂移 |
| 节点与连接 | 登录、连接、断开、服务启停、注销；Peer 地址、直连/中继/空闲、流量与 Ping |
| 上联策略 | 分别选择 IPv4/IPv6 优先接口，探测与失败/恢复阈值，专用路由表 |
| 访问与路由 | 限定源 LAN/VLAN 的 IPv4 SNAT、自动接入远端子网；Exit Node、子网发布、反向访问和本地路由例外 |
| DNS | MagicDNS 与 Split DNS 条件同步、实例选择、暂停、清理、手动同步与生成预览 |
| 诊断与日志 | 路由、DNS、netcheck、fw4、服务状态、日志、导出、最近应用回滚和撤销接管 |

普通流量保持系统路由的优先级。Tailscale 传输与 Exit Node 转发共用插件的专用表；首版不是全局多 WAN 管理器。优先链路不可用时退回系统路由。优先 IPv4 可用但优先 IPv6 不可用时阻断该专用表的 IPv6；IPv4/IPv6 分别探测。默认在出口改变后重连 tailscaled，以重建已有连接，因此切换可能短暂中断。

LAN → Tailnet 当前仅支持 IPv4，远端 ACL 识别路由器的 SNAT 身份。反向访问、子网发布和控制台批准互相独立。Tailscale IPv6 地址不代表已实现 LAN → Tailnet IPv6 网关。

远端子网在 **访问与路由 → LAN 访问远端子网 → 自动放行远端子网** 开启，沿用上方选择的 LAN / VLAN。此开关同时启用 Tailscale 原生 `accept-routes`；路由安装、撤回和子网路由器选择由 Tailscale 维护，插件只同步转发与 SNAT。关闭 LAN 访问开关保留路由接收；关闭“接受远端子网路由”会同时关闭 LAN 远端访问。

同步在开机、接口变化和每 5 秒检查时运行。只放行 Peer AllowedIPs/PrimaryRoutes 中、同时已安装到表 52 / TUN 的 IPv4 子网，不接收 Exit Node 默认路由或重复处理 Tailscale 节点地址。主路由表的非默认路由（含直连网络）、本机发布网段、本地优先网段和手动排除项有重叠时，整条远端路由排除。选定 LAN 通过提前的策略规则优先查询主路由表的非默认路由，避免远端同名网段覆盖本地连接。若要某个网段走办公室出口，应配置“优先使用本地路由的网段”；“额外排除网段”只是不自动放行，不改写 Tailscale 路由。

已识别的远端目的网段保留出口保护：路由撤回时拒绝向其他上联转发，已建立的连接也经过保护链。历史网段跨重启保留，只有网段集合变化时写入闪存；在排除列表加入该网段或关闭功能可清除对应保护。防火墙重载后同步进程会恢复动态集合；状态/路由读取失败则清空放行集合并显示错误。保护适用于经过路由器转发的这些目的网段，路由器自身发起的连接不在此保护链内。

自动子网功能需要关闭防火墙 flow offloading；不管理 IPv6 远端子网。fw4 的 UCI NAT 不支持 ipset 匹配，因此 SNAT 和出口保护由插件拥有的 nft include 实现。UI“已放行”表示路由和本地规则就绪，不代表远端主机/端口已实测可达；仍需控制台批准和允许路由器身份访问的 Tailnet ACL。

DNS 通过开机启动、接口 hotplug 和定时检查更新。有效的规则删除会清理托管条目；读取失败、未登录、非法域名、不支持的 DoH 上游或 DNS 回环会保留最后有效规则。未改变的规则不写闪存、不 reload dnsmasq；默认 DNS 上游及手工条件规则保留。更换 dnsmasq 实例须先在原实例关闭并清理规则，再选择新实例。完整 Tailnet 域名可用，短主机名仍依赖客户端搜索域。

## 配置所有权与恢复

- 设置：`/etc/config/tailscale_gateway`；Tailscale 原生偏好仍通过官方 CLI 维护。
- 资源记录和应用事务：`/etc/tailscale-gateway/`，权限 0700。
- 临时状态与异步任务：`/var/run/tailscale-gateway/`，不在周期采集时写闪存。
- 应用先检查配置版本、待提交 UCI、策略路由冲突与 fw4；失败仅恢复仍与本次候选一致的文件，避免覆盖并发编辑。
- “撤销这次应用”恢复一次事务；“撤销接管”恢复首次接管前的托管资源、原生偏好和旧服务状态。两者均不删除 Tailscale 身份。

**推荐卸载顺序：** 诊断页“预览撤销接管” → “撤销接管” → 确认回到观察模式 → `apk del luci-app-tailscale-gateway tailscale-gateway`。

APK 的卸载钩子无法可靠阻止删除。如果直接卸载仍在托管的核心包，钩子停止扩展工作进程，保留 UCI/DNS 资源及 `/etc/tailscale-gateway/uninstall-recovery.tar.gz` 恢复代码；重新安装同版后再撤销接管。直接删包不等于清理网络策略。不要在插件之外修改托管项后强行覆盖冲突。

## 开发与验证

```sh
python3 scripts/package.py          # 可重复构建两个 noarch APK
python3 scripts/source-package.py   # 生成不含实机快照的源码包，更新校验值
python3 scripts/check.py openwrt    # 本地 JS/shell/JSON + 远端 ucode 编译
python3 tests/run.py openwrt        # /tmp 隔离 UCI、命令替身，绝不调用真实策略变更
python3 tests/firewall.py openwrt   # 隔离 UCI，经设备 fw4 渲染与 nft -c 检查
python3 tests/dns.py                # 实际 ucode/UCI/dnsmasq 解析器，隔离 DNS 配置
python3 tests/uplink.py             # 真实控制循环，模拟探测/路由，不触碰网络
node tests/ui.cjs                   # 延迟 RPC 下的编辑保留、预览失效、应用锁定
```

`scripts/deploy.py` 是开发期间的文件覆盖安装器；正式部署使用 APK。测试 host 默认 SSH 别名 `openwrt`，DNS 测试同样使用该别名。

OpenWrt SDK 构建入口分别在 `packages/*/Makefile`。把两个目录放入 SDK 的 `package/`，启用 LuCI feed，选择两个包及依赖后执行 `make package/tailscale-gateway/compile package/luci-app-tailscale-gateway/compile V=s`。当前交付的 APK 由 Python 按 [apk-tools v2 包格式](https://github.com/alpinelinux/apk-tools/blob/master/doc/apk-v2.5.scd)生成，已用目标设备的 apk-tools 3 校验、安装和升级；未声称 SDK/IPK 构建已经通过。

已通过的测试与复现方法见 [验证范围](docs/VALIDATION.md)。实机快照、后台截图、认证信息及环境专用脚本不随仓库或源码包分发；提交排障信息前请阅读 [安全与隐私说明](SECURITY.md)。

软件许可证：GPL-2.0-only。
