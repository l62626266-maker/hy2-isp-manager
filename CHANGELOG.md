# Changelog

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
