#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly VERSION="cert-guard-v0.1.0"
readonly REPO="l62626266-maker/hy2-isp-manager"
readonly GUARD_SHA256="27d4200ce686b56332bbd23fbd44b3fb810cb0991d9390b1544c8c5abce3c42e"

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"
for cmd in curl sha256sum mktemp install openssl systemctl runuser; do command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"; done

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT INT TERM
script_dir=""
if [[ -n ${BASH_SOURCE[0]:-} && ${BASH_SOURCE[0]} != /dev/stdin && ${BASH_SOURCE[0]} != bash ]]; then
  if ! script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd); then script_dir=""; fi
fi
if [[ -n $script_dir && -f $script_dir/hy2-cert-guard ]]; then
  install -m 700 "$script_dir/hy2-cert-guard" "$tmp"
else
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 \
    "https://raw.githubusercontent.com/$REPO/$VERSION/hy2-cert-guard" -o "$tmp"
  actual=$(sha256sum "$tmp"); actual=${actual%% *}
  [[ $GUARD_SHA256 != __GUARD_SHA256__ ]] || die "发布版尚未写入 SHA256。"
  [[ $actual == "$GUARD_SHA256" ]] || die "hy2-cert-guard SHA256 校验失败。"
fi
bash -n "$tmp"
install -o root -g root -m 755 "$tmp" /usr/local/sbin/hy2-cert-guard
ln -sfn /usr/local/sbin/hy2-cert-guard /usr/local/bin/hy2-cert-guard

config=/etc/hy2-cert-guard.conf
if [[ ! -r $config || ${HY2CG_RECONFIGURE:-0} == 1 ]]; then
  domain=${HY2CG_DOMAIN:-}
  if [[ -z $domain ]]; then
    mapfile -t certs < <(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
    ((${#certs[@]} == 1)) || die "无法唯一识别证书域名；请设置 HY2CG_DOMAIN。"
    domain=${certs[0]}
  fi
  live_dir="/etc/letsencrypt/live/$domain"
  [[ -r $live_dir/fullchain.pem && -r $live_dir/privkey.pem ]] || die "找不到域名证书：$live_dir"
  if [[ -r /etc/hysteria/tls/fullchain.pem && -r /etc/hysteria/tls/privkey.pem ]]; then
    deploy_cert=/etc/hysteria/tls/fullchain.pem; deploy_key=/etc/hysteria/tls/privkey.pem
  elif [[ -r /etc/hysteria-hy2m/tls/fullchain.pem && -r /etc/hysteria-hy2m/tls/privkey.pem ]]; then
    deploy_cert=/etc/hysteria-hy2m/tls/fullchain.pem; deploy_key=/etc/hysteria-hy2m/tls/privkey.pem
  else die "无法识别HY2部署证书路径，请先创建 /etc/hy2-cert-guard.conf。"; fi
  services=${HY2CG_SERVICES:-}
  if [[ -z $services ]]; then
    while read -r unit _; do
      case $unit in hysteria*.service|hy2m-*.service) [[ $unit == *@.service ]] || services+=" $unit" ;; esac
    done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null || true)
    services=${services# }
  fi
  [[ -n $services ]] || die "没有识别到HY2服务；请设置 HY2CG_SERVICES。"
  ports=${HY2CG_UDP_PORTS:-}
  if [[ -z $ports ]]; then
    for cfg in /etc/hysteria/*.yaml /etc/hysteria-hy2m/*.yaml; do
      [[ -r $cfg ]] || continue
      p=$(awk -F: '/^[[:space:]]*listen:[[:space:]]*:[0-9]+/{gsub(/[[:space:]]/,"",$3);print $3;exit}' "$cfg")
      [[ -n $p ]] && ports+=" $p"
    done
    ports=$(tr ' ' '\n' <<<"$ports" | awk 'NF&&!seen[$0]++' | sort -n | xargs)
  fi
  [[ -n $ports ]] || die "没有识别到HY2 UDP端口；请设置 HY2CG_UDP_PORTS。"
  expected_ip=${HY2CG_EXPECTED_IPV4:-}
  if [[ -z $expected_ip ]]; then expected_ip=$(curl -4fsS --max-time 15 https://api.ipify.org || true); fi
  if [[ -r $config ]]; then cp -a "$config" "$config.before-$(date +%Y%m%d-%H%M%S)"; fi
  {
    printf 'DOMAIN=%q\n' "$domain"
    printf 'EXPECTED_IPV4=%q\n' "$expected_ip"
    printf 'LIVE_DIR=%q\n' "$live_dir"
    printf 'DEPLOY_CERT=%q\n' "$deploy_cert"
    printf 'DEPLOY_KEY=%q\n' "$deploy_key"
    printf 'SERVICES=%q\n' "$services"
    printf 'UDP_PORTS=%q\n' "$ports"
    printf 'WARN_DAYS=30\nFAIL_DAYS=14\n'
  } >"$config"
  chmod 600 "$config"
fi

if ! /usr/local/sbin/hy2-cert-guard install-system; then
  die "安装完成但首次健康检查失败；现有证书和HY2服务未被替换。"
fi

backup_dir="/var/lib/hy2-cert-guard/legacy-hooks/$(date +%Y%m%d-%H%M%S)"
for hook in /etc/letsencrypt/renewal-hooks/deploy/*; do
  [[ -f $hook && $hook != /etc/letsencrypt/renewal-hooks/deploy/hy2-cert-guard ]] || continue
  if grep -Eq 'hysteria|/etc/hysteria' "$hook" 2>/dev/null; then
    install -d -o root -g root -m 700 "$backup_dir"
    mv "$hook" "$backup_dir/"
  fi
done
if [[ -d $backup_dir ]]; then printf '旧Hysteria续期钩子已备份到：%s\n' "$backup_dir"; fi
printf '安装成功。状态：\n'
/usr/local/sbin/hy2-cert-guard status
printf '\n建议现在执行一次：sudo hy2-cert-guard dry-run\n'
