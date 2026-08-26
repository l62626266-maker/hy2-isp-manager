# Changelog

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
