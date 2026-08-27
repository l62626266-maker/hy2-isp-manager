# Changelog

## v0.2.1

- 修复删除ISP后Direct因缺少管理器状态文件而无法显示的问题。
- `show`、`status` 和诊断可只读识别现有旧版Direct服务，不要求 `manager.env`。
- Direct和ISP节点记录独立；删除ISP只移除指定ISP，Direct继续显示和运行。
- ISP必须依赖Direct；仍有ISP记录时禁止删除Direct，并拒绝不受支持的ISP-only清单。
- 新增Direct+ISP、删除ISP、旧Direct兼容显示和依赖约束回归测试。

## cert-guard-v0.1.0

- 新增独立 `hy2-cert-guard`，不集成原管理器菜单。
- 每日检查证书、私钥、部署副本、Certbot、DNS、TCP 80、UFW、HY2服务和UDP端口。
- 新增续期部署、双服务重启、失败回滚、root告警、SSH登录提示和dry-run。
- 旧Hysteria续期钩子只备份不删除。
- 在KVM生产VPS完成正常/异常告警、权限失败修复、部署回滚、真实dry-run、timer、登录提示、卸载重装及重启验证。

## v0.2.0

- 将交互重试、菜单错误隔离和非敏感安装断点转为稳定功能。
- 在 KVM 公网 VPS 验证现有直连/ISP节点不中断、SOCKS5 TCP认证与出口、网络参数、清理恢复和重启持久化。
- SOCKS5 UDP ASSOCIATE 不支持时明确报告，不影响 TCP/HTTPS 全隧道用途。

## v0.2.0-beta.1

- 菜单动作加入错误隔离，内部失败返回主菜单而不是退出到 root shell。
- 端口、域名、IPv4、节点名和 SOCKS5 字段支持当前项循环校验。
- SOCKS5 测试失败可重新输入，不必重新启动管理器。
- 文本模式支持输入 `:menu` 取消当前操作。
- 全新安装保存 root-only 非敏感断点，证书失败后可继续；断点文件不包含 Token 和密码。

## v0.1.1

- 修复部分 Debian `qrencode` 版本将 `-r -` 解释为文件名而无法显示终端二维码的问题。
- 二维码改为通过标准输入直接传递 URI，不影响节点服务或导入链接。

## v0.1.0

- 首个稳定版本。
- 在一次性 LXD NAT VPS 验证证书、旧状态兼容、直连节点创建、systemd 启动及 UDP 监听。
- 纳入 beta.1 至 beta.5 的安全、NAT、ISP 全隧道、回滚和受限容器兼容修复。

## v0.1.0-beta.5

- 修复受限 LXD 容器禁止 systemd mount namespace 时 HY2 服务启动失败的问题。
- 完整 VM 继续启用 `PrivateTmp`、`ProtectSystem` 等文件系统隔离；受限容器仅省略不兼容项，保留专用用户、能力边界和 `NoNewPrivileges`。

## v0.1.0-beta.4

- 修复旧状态文件中的 `APP_VERSION` 与管理器只读版本变量冲突。
- 新状态改用 `INSTALLED_VERSION`，并兼容 beta.3 及更早状态，无需重装证书或节点。

## v0.1.0-beta.3

- 自动识别 LXC/LXD/OpenVZ 等受限容器，跳过宿主机控制的内核调优和 Swap。
- 不再执行全局 `sysctl --system`，完整 VM 上只逐项应用并持久化实际成功的参数。
- 修复受限容器在网络优化阶段中断全新安装的问题。

## v0.1.0-beta.2

- 修复 SOCKS5 UDP 探测曾通过进程参数传递凭据的问题，改为仅 root 可读临时文件。
- 增加公网 IPv4 严格校验和 NAT 公网端口冲突检测。
- 增加现有证书安全复用、IPv6 SOCKS5 地址格式和直连节点补建入口。
- 明确应用层无 direct fallback 不等于内核级出站隔离。

## v0.1.0-beta.1

- 首个公开 Beta。
- 普通公网 VPS 与 NAT 双端口模型。
- HY2 直连节点和多 ISP SOCKS5 全局节点。
- ISP outbound 配置无 VPS direct fallback（应用层；非内核级隔离）。
- ISP 新增、更换、删除、状态、诊断、导出、二维码和备份。
- Let’s Encrypt HTTP-01 与 Cloudflare DNS-01。
- 保守 BBR/fq、QUIC 缓冲和低内存 Swap。
- Hysteria 固定版本和官方 SHA256 校验。
- UFW 仅管理本项目新增规则。
- Bash、ShellCheck 和契约测试。
