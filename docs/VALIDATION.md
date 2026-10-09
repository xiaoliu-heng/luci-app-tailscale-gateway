# 验证范围

`0.2.0-r2` 的基础功能沿用 `0.1.0-r4`，并在同一台设备完成子网功能的安装与验收。此前版本已在一台使用 fw4、apk-tools 3 和 Tailscale 1.102.3 的 OpenWrt SNAPSHOT 设备上完成安装、接管、升级和客户端验证。这里仅发布方法和结果摘要；实机快照、后台截图及网络标识不随仓库分发。

| 检查 | 结果 |
| --- | --- |
| 规划与事务 | 41 项隔离断言：输入校验、不同接口名与网段、并发/资源冲突、应用、回滚、撤销接管、保留无关配置 |
| 远端子网 | 36 项隔离断言：发现/过滤、HA、接口/路由/密钥状态、撤回保护、失败关闭、所有权、应用/回滚/清理 |
| 并发状态写入 | 两个并发进程写入并读取 200 次完整 JSON，独立临时文件避免采集与同步竞争 |
| fw4 / nft | 设备真实 fw4 渲染隔离配置，内核 `nft -c` 验证转发、集合、SNAT 和提前保护链；不激活测试规则 |
| DNS | 12 项断言：实际 ucode/UCI/dnsmasq 解析器，条件规则、失败保留、回环拒绝、幂等更新、实例切换与恢复 |
| 上联 | 8 项断言：真实控制循环配合模拟探测和路由，分别验证 IPv4/IPv6、失败/恢复阈值、回退与重连 |
| 页面行为 | 13 项断言：子网开关联动、同步保留草稿，及延迟 RPC、旧预览失效、应用锁定、未提交草稿保留、失败后解锁 |
| RPC 权限 | 实机临时只读会话可读状态，不能 apply 或 subnet_sync；匿名 apply 被拒绝；会话随后销毁 |
| 实机操作 | 接管、重复应用、DNS 周期修改与恢复、立即同步、节点连接、原身份和既有网络配置保留 |
| 子网实机路径 | 显式绑定客户端 LAN 接口，两个远端子网 HTTP 返回响应；合成测试目的网段的过期放行条目被出口保护拒绝，重载 fw4 后同步恢复；tailscaled 未重启 |
| 客户端路径 | 经 LAN 访问 Tailnet SSH、原局域网 HTTP，以及 MagicDNS、Split DNS 和公共 DNS |
| 界面 | 本版新增访问页经实际登录检查：1440px、390px 和用户当前 1170px；手动同步及开关联动通过，基础六页沿用上版验证 |
| 打包 | APK 校验、安装与升级；源码包可逐字节重建两个 APK |

## 复现

本地检查需要 Python 3、Node.js 18 或更新版本和 POSIX shell：

```sh
node tests/ui.cjs
python3 tests/uplink.py
python3 scripts/package.py
python3 scripts/source-package.py
```

ucode/DNS 测试需要可 SSH 访问的 OpenWrt 测试设备，具备项目依赖和 dnsmasq。`openwrt` 是文档约定的 SSH 别名，应指向自己的测试设备。以下命令将夹具放在 `/tmp/tsg-dev`，策略操作由测试替身处理：

```sh
python3 scripts/check.py openwrt
python3 tests/run.py openwrt
python3 tests/firewall.py openwrt
python3 tests/dns.py
```

RPC 权限测试需要设备上已安装本插件，并有允许创建临时 ubus 会话的 SSH 权限。传入自己的管理 URL，例如 `python3 tests/acl.py http://router.example --host openwrt`。它只在内存中创建 30 秒会话，不创建账户、不保存口令，最终销毁会话。

## 尚未验证

未执行实际拔线、整机重启、第二台物理设备或稳定版 SDK/IPK 构建。模拟故障测试证明控制逻辑，不等同于物理故障验收。LAN → Tailnet IPv6、其他 DNS 服务和使用远端 Exit Node 不在首版范围。
