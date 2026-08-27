# HY2 ISP Manager

一个面向普通用户的 Hysteria 2 终端管理器，重点解决：

- 普通公网 VPS 与 NAT/端口映射 VPS；
- HY2 直连节点；
- 以有认证 ISP SOCKS5 为**全局、失败关闭**出口的 HY2 节点；
- Let’s Encrypt HTTP-01 与 Cloudflare DNS-01；
- v2rayN URI、终端二维码、状态、诊断、备份和安全卸载。

> 当前稳定版本：`v0.2.1`。已在 LXD NAT VPS 与 KVM 公网 VPS 验证输入重试、菜单错误隔离、证书、服务、节点独立状态、旧Direct兼容显示、SOCKS5 TCP认证、ISP出口、清理恢复及重启持久化。

## 支持环境

- Debian 12 / 13
- Ubuntu 22.04 / 24.04
- amd64 / arm64
- systemd
- root 权限

## 一键安装

固定版本发布后：

```bash
curl -fsSL https://raw.githubusercontent.com/l62626266-maker/hy2-isp-manager/v0.2.1/install.sh -o /tmp/hy2-install.sh
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

## 交互与失败恢复

- 端口、域名、IPv4、节点名称和 SOCKS5 字段格式错误会在当前字段重新询问；
- 端口占用或节点 ID 不存在时不会退出管理器；
- SOCKS5 测试失败可直接重新输入凭据；
- 文本终端输入 `:menu` 可取消当前操作并回到主菜单；
- 菜单动作在隔离子进程运行，深层错误不会把整个菜单退出到 root shell；
- 全新安装会以 root-only 断点文件保存域名、模式、公网 IP、证书方式和邮箱等非敏感进度；断点文件不保存 Cloudflare Token 或 SOCKS5 密码。DNS-01 成功续期仍需使用单独的 root-only Cloudflare 凭据文件。

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

节点依赖和显示规则：

- 支持“只有Direct”以及“Direct + 一个或多个ISP”；不支持ISP脱离Direct单独存在。
- 删除ISP只删除指定ISP，最后一个ISP删除后Direct继续显示和运行。
- 仍有ISP记录时禁止删除其依赖的Direct。
- `show`、`status` 和诊断不再把 `manager.env` 当作节点清单；即使旧版Direct没有管理器状态文件，也会通过 `/etc/hysteria/config.yaml` 和 `hysteria-server.service` 兼容显示。
- 兼容显示为只读，不会重建、重启或覆盖旧Direct服务。

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

## 独立证书守护器

`hy2-cert-guard` 是同仓库中的独立工具，不加入 `hy2-manager` 菜单，也可以管理手工部署的 Hysteria 服务。

固定版本安装：

```bash
curl -fsSL https://raw.githubusercontent.com/l62626266-maker/hy2-isp-manager/cert-guard-v0.1.0/install-cert-guard.sh -o /tmp/install-cert-guard.sh
bash -n /tmp/install-cert-guard.sh
sudo bash /tmp/install-cert-guard.sh
```

常用命令：

```bash
hy2-cert-guard status
sudo hy2-cert-guard check
sudo hy2-cert-guard dry-run
hy2-cert-guard logs
```

它会安装每日 `systemd` timer、Certbot deploy hook 和 SSH 登录提示，检查证书有效期、证书/私钥匹配、部署证书一致性、Certbot timer、DNS、TCP 80、UFW、HY2 服务和 UDP 端口。续期成功后原子替换证书并重启登记服务；失败时自动恢复部署前证书并生成：

```text
/root/HY2-CERTIFICATE-ALERT.txt
```

非敏感状态保存在 `/var/lib/hy2-cert-guard/status`。旧 Hysteria deploy hooks 会先移动到 `/var/lib/hy2-cert-guard/legacy-hooks/<timestamp>/`，不会永久删除。`dry-run` 不使用 `--run-deploy-hooks`，不会把 Let’s Encrypt staging 证书部署到生产节点。

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

当前版本的“失败关闭”属于 **Hysteria 配置层保证**，尚未增加每节点独立 UID、network namespace 或 nftables 出站白名单，因此不把它宣传为内核级绝对隔离。强对抗场景应等待后续隔离版及数据包级实测。

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

脚本只设置保守参数。LXC、LXD、OpenVZ 等受限容器的 BBR、`net.core` 缓冲和真实 Swap 由宿主机管理，脚本会自动识别并安全跳过，不影响节点继续部署。受限容器若禁止 systemd mount namespace，服务会保留非 namespace 安全限制并省略不兼容的文件系统隔离项：

```text
BBR + fq
QUIC rmem_max/wmem_max = 16 MiB（完整 VM 且内核允许时）
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
