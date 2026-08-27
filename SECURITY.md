# Security Policy

## 敏感信息

请勿在 Issue、日志、截图或提交中包含：完整节点 URI/二维码、HY2 密码、SOCKS5 凭据、Cloudflare Token、SSH 私钥或 root 密码。

## 安装安全

- 优先下载固定 Git tag 的 `install.sh`，不要直接执行变化中的 `main`。
- `install.sh` 校验固定版本 `hy2-manager` 的 SHA256。
- `install-cert-guard.sh` 校验固定证书守护器 Tag 和 `hy2-cert-guard` SHA256。
- Hysteria 二进制固定版本，并与同一官方 Release 的 `hashes.txt` 核对。
- 建议先下载、执行 `bash -n` 并人工检查，再以 root 运行。

## 权限边界

- 管理状态、Cloudflare Token、导出 URI：`600 root:root`。
- Hysteria 配置和 TLS 私钥副本：`640 root:hysteria`。
- systemd 服务以低权限 `hysteria` 用户运行。
- 脚本不会修改 SSH 配置。
- 证书守护器配置和部署备份为 root-only；公开状态文件不包含 Token、私钥或节点凭据。
- Certbot dry-run 不运行生产 deploy hook，避免测试证书覆盖正式节点。

## 报告问题

请提交已经脱敏的复现步骤和错误阶段。安全漏洞请只提供最少公开信息，不要附带任何可用凭据。
