# HY2 ISP Manager

一个面向普通用户的 Hysteria 2 终端管理器，重点解决：

- 普通公网 VPS 与 NAT/端口映射 VPS；
- HY2 直连节点；
- 以有认证 ISP SOCKS5 为**全局、失败关闭**出口的 HY2 节点；
- Let’s Encrypt HTTP-01 与 Cloudflare DNS-01；
- v2rayN URI、终端二维码、状态、诊断、备份和安全卸载。

> 当前版本：`v0.1.0-beta.1`。已通过 Bash 语法、ShellCheck 和本地契约测试；真实公网/NAT、证书签发和不同 ISP 服务商仍应先在可重装测试 VPS 上验证。不要先在唯一的生产 VPS 上运行 Beta 版。

## 支持环境

- Debian 12 / 13
- Ubuntu 22.04 / 24.04
- amd64 / arm64
- systemd
- root 权限

## 一键安装

固定版本发布后：

```bash
curl -fsSL https://raw.githubusercontent.com/l62626266-maker/hy2-isp-manager/v0.1.0-beta.1/install.sh -o /tmp/hy2-install.sh
bash -n /tmp/hy2-install.sh
sudo bash /tmp/hy2-install.sh
```

也可以先克隆并检查：

```bash
git clone https://github.com/l62626266-maker/hy2-isp-manager.git
cd hy2-isp-manager
bash -n install.sh hy2-manager
sudo bash install.sh
```

安装管理器后运行：

```bash
sudo hy2-manager
```

## 傻瓜式菜单

```text
1. 全新安装
2. 创建/补建 HY2 直连节点
3. 添加 ISP SOCKS5 全局节点
4. 更换现有 ISP SOCKS5
5. 查看节点与二维码
6. 查看状态
7. 一键诊断
8. 删除指定节点
9. 备份当前配置
10. 卸载
0. 退出
```

命令行方式：

```bash
sudo hy2-manager install
sudo hy2-manager create-direct
sudo hy2-manager add-isp
sudo hy2-manager replace-isp
sudo hy2-manager show
sudo hy2-manager status
sudo hy2-manager diagnose
sudo hy2-manager backup
sudo hy2-manager remove-node
sudo hy2-manager uninstall
```

## 普通 VPS 与 NAT VPS

普通 VPS 的内部监听端口和公网端口相同。

NAT VPS 会分别询问：

```text
VPS 内部 UDP 监听端口
服务商控制台的公网 UDP 端口
```

例如服务商控制台显示：

```text
公网 56777 → 内部 443（UDP 或 TCP/UDP）
```

则 HY2 在 VPS 内监听 `443/UDP`，v2rayN URI 使用公网端口 `56777`。脚本不能替你操作 VPS 服务商的端口映射控制台，但会明确显示需要添加的规则。

## 证书

### 普通公网 VPS

可使用 HTTP-01，需要：

```text
公网 TCP 80 → VPS 内部 TCP 80
```

### NAT VPS

如果无法获得公网 80，选择 Cloudflare DNS-01。需要输入一个仅具有目标 Zone 的 `Zone.DNS Edit` 权限的 API Token。Token 保存为：

```text
/etc/hy2-isp-manager/cloudflare.ini
```

权限为 `600 root:root`，Certbot 自动续期需要保留该文件。不要使用 Global API Key。

## 节点结构

### HY2 Direct

```text
客户端 → HY2 → VPS 直接出站
```

### HY2 ISP Full

```text
客户端 → HY2 → VPS → ISP SOCKS5 → 目标网站
```

ISP 节点配置只定义 SOCKS5 outbound，并使用该 outbound 匹配 `all`。配置中没有 direct fallback：正常情况下 ISP 失效时节点会失败，而不是主动改走 VPS 出口。

当前 Beta 的“失败关闭”属于 **Hysteria 配置层保证**，尚未增加每节点独立 UID、network namespace 或 nftables 出站白名单，因此不把它宣传为内核级绝对隔离。强对抗场景应等待后续隔离版及数据包级实测。

如果 ISP SOCKS5 不支持 UDP，普通 TCP/HTTPS 网页通常仍可使用，但游戏、QUIC/HTTP3 或必须使用 UDP 的应用可能失败或回退 TCP。

## 敏感文件

```text
/etc/hy2-isp-manager/             管理状态
/etc/hysteria-hy2m/               HY2 配置和证书副本
/root/hy2-export/                 节点 URI
/root/hy2-manager-backups/        权限保护备份
```

状态和导出文件为 `600 root:root`；HY2 配置为 `640 root:hysteria`。SOCKS5 密码不会写入节点 URI，但必须保存在 root/hysteria 可读的服务端配置中。

不要把以下内容提交到 GitHub Issue：

- 完整 HY2 URI 或二维码；
- SOCKS5 地址、用户名和密码；
- Cloudflare Token；
- SSH 私钥或 root 密码。

## 网络优化

脚本只设置保守参数：

```text
BBR + fq
QUIC rmem_max/wmem_max = 16 MiB
低内存且没有 Swap 时创建独立 Swap
```

不安装魔改内核，不修改 SSH，不关闭密码登录，不清空系统防火墙。UFW 已启用时，只记录并在卸载时删除脚本自己新增的规则。

## 安全和回滚

- Hysteria 固定为 `v2.12.2`，并使用官方 `hashes.txt` 校验 SHA256。
- manager 的联网安装固定 Git tag，并校验内嵌 SHA256。
- 服务使用低权限 `hysteria` 账户和 systemd 沙箱。
- ISP 凭据隐藏输入。
- 服务启动失败会删除本次新节点。
- 更换 ISP 失败会恢复旧配置。
- 卸载不修改 SSH，也不删除 Let’s Encrypt 账户和恢复备份。

## 测试

本地测试：

```bash
bash tests/run.sh
shellcheck -x hy2-manager install.sh tests/run.sh
```

测试覆盖语法、端口/域名校验、状态安全序列化、文件权限、TLS 安全字段、ISP fail-closed 静态契约、Cloudflare DNS-01、NAT 双端口和 Hysteria SHA256 校验。

以下项目必须使用一次性 VPS 或快照进行真实集成测试：

- apt/systemd/UFW 生命周期；
- Let’s Encrypt HTTP-01/DNS-01 实际签发和续期；
- 公网 UDP 与 NAT 映射；
- v2rayN 真机连接；
- ISP 出口一致性和 UDP 能力；
- 重启、升级、回滚和卸载。

## 已知限制

- 脚本无法自动修改 VPS 厂商控制台中的 NAT 映射或安全组。
- VPS 内部测试不能证明 NAT 公网 UDP 一定可达，必须从外部客户端测试。
- 当前 Beta 不提供公开订阅网页，避免节点凭据泄露。
- “中国网站走家庭网络、国外走节点”属于 v2rayN 本地规则，不可能由 VPS 服务端实现。

## License

MIT
