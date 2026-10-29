#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2317,SC2016
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp
export TMPDIR="${TMPDIR:-$PWD/.tmp}"
tmp=$(mktemp -d "$TMPDIR/ui.XXXXXX")
export HY2M_SOURCE_ONLY=1 HY2M_TESTING=1
export HY2M_APP_DIR="$tmp/app" HY2M_STATE_DIR="$tmp/state" HY2M_EXPORT_DIR="$tmp/export"
export HY2M_HYSTERIA_DIR="$tmp/config" HY2M_BACKUP_DIR="$tmp/backup"
export HY2M_SERVICE_DIR="$tmp/systemd" HY2M_SBIN_DIR="$tmp/sbin" HY2M_BIN_DIR="$tmp/bin"
export HY2M_LEGACY_CONFIG="$tmp/legacy.yaml" HY2M_LEGACY_MANAGER_CONFIG="$tmp/legacy.conf"
export HY2M_LEGACY_URI_FILE="$tmp/legacy-uri" HY2M_LEGACY_TLS_CERT="$tmp/legacy-cert"
source ./hy2-manager
trap 'cleanup; rm -rf "$tmp"' EXIT
mkdir -p "$NODE_DIR" "$EXPORT_DIR" "$HYSTERIA_DIR" "$SERVICE_DIR" "$SBIN_DIR" "$BIN_DIR"
pass() { printf '[PASS] %s\n' "$1"; }
check() { local label=$1; shift; "$@" || { printf '[FAIL] %s\n' "$label" >&2; exit 1; }; pass "$label"; }

# Production operations are mocked; this suite never talks to systemd/UFW/sudo.
systemctl() { printf '%s\n' "$*" >>"$tmp/systemctl-calls"; [[ $1 != is-active ]] || printf 'active\n'; return 0; }
open_firewall() { printf 'open %s\n' "$1" >>"$tmp/firewall-calls"; }
close_firewall() { printf 'close %s\n' "$1" >>"$tmp/firewall-calls"; }
port_free() { return 0; }
certificate_summary() { printf '证书：测试状态（不含凭据）\n'; }
confirm() { return 0; }
# Only ownership is stripped: the CI user need not be root or own a hysteria group.
install() {
  local args=()
  while (($#)); do case $1 in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
  command install "${args[@]}"
}
start_checked() {
  printf 'start %s %s\n' "$1" "$2" >>"$tmp/start-calls"
  [[ $2 != "${FAIL_PORT:-none}" ]]
}

restart_unit_checked() { start_checked "$@"; }
has_whiptail() { return 1; }
check 'port input is normalized' test "$(ask_valid_port test port '' <<<'00443')" = 443
if valid_port 18446744073709552059; then exit 1; fi
pass 'oversized port input cannot overflow into valid range'
set +e
ask test input '' </dev/null >/dev/null; rc=$?
set -e
check 'EOF cancels prompt' test "$rc" = 20
set +e
ask_secret test password <<<':menu' >/dev/null; rc=$?
set -e
check 'secret input can cancel' test "$rc" = 20
set +e
choose test menu 1 one </dev/null >/dev/null; rc=$?
set -e
check 'EOF cancels menu' test "$rc" = 20
has_whiptail() { return 0; }
whiptail() { return 255; }
set +e
choose test menu 1 one >/dev/null; rc=$?
set -e
check 'dialog Escape maps to cancellation' test "$rc" = 20
restart_unit_checked() { start_checked "$@"; }
has_whiptail() { return 1; }

# Noninteractive fixture: paste is parsed from a protected file, not argv/eval.
printf '%s' 'socks5://alice:p%%40ss@proxy.example.com:1080' >"$tmp/paste"
# Malformed percent encoding is deliberately rejected.
if parse_socks_file "$tmp/paste"; then exit 1; fi
pass 'malformed URL encoding rejected'
printf '%s' 'socks5://alice:p%40ss%3Aword@[2001:db8::1]:1080' >"$tmp/paste"
check 'SOCKS URL parser' parse_socks_file "$tmp/paste"
check 'IPv6 address preserved' test "$SOCKS_HOST" = '2001:db8::1'
check 'encoded password decoded' test "$SOCKS_PASS" = 'p@ss:word'
printf '%s' 'proxy.example.com:1080:alice:pass:with:colon' >"$tmp/paste"
check 'provider colon format parser' parse_socks_file "$tmp/paste"
check 'colon format password preserved' test "$SOCKS_PASS" = 'pass:with:colon'
for bad in 'socks5://u:p@host:0' 'socks5://u:p@host:65536' 'http://u:p@host:1080' 'socks5://u%0Aname:p@host:1080' 'socks5://u:p%0A@host:1080' 'socks5://u:p@host:1080/#fragment' 'host:1080::p'; do
  printf '%s' "$bad" >"$tmp/paste"
  if parse_socks_file "$tmp/paste"; then printf '[FAIL] invalid proxy accepted\n'; exit 1; fi
done
pass 'invalid proxies and control characters rejected'
printf '%s' 'host:1080:user:$(touch SHOULD_NOT_EXIST)' >"$tmp/paste"
check 'shell-looking password remains data' parse_socks_file "$tmp/paste"
check 'no execution during parsing' test "$SOCKS_PASS" = '$(touch SHOULD_NOT_EXIST)'

fixture() {
  write_env "$MANAGER_STATE" DOMAIN test.example.com NETWORK_MODE normal PUBLIC_IP 192.0.2.1 CERT_MODE http
  local id=$1 port=$2 type=isp
  [[ $id != direct ]] || type=direct
  if [[ $type == isp ]]; then
    SOCKS_HOST=proxy.example.com; SOCKS_PORT=1080; SOCKS_USER=fixture; SOCKS_PASS='test:password@only'
    render_isp_config "$port" "$(printf 'a%.0s' {1..48})" isp_all >"$HYSTERIA_DIR/$id.yaml"
  else
    write_common_config "$port" "$(printf 'a%.0s' {1..48})" >"$HYSTERIA_DIR/$id.yaml"
  fi
  printf 'hysteria2://%s@test.example.com:%s/?sni=test.example.com#%s\n' "$(printf 'a%.0s' {1..48})" "$port" "$id" >"$EXPORT_DIR/hy2-$id.txt"
  save_node "$id" "$type" "$id" "$port" "$port" "hy2m-$id.service" "$HYSTERIA_DIR/$id.yaml" "$EXPORT_DIR/hy2-$id.txt" normal
  [[ $id == direct ]] || printf 'SOCKS_EXIT_IP=192.0.2.2\nSOCKS_UDP=supported\n' >>"$NODE_DIR/$id.env"
}
fixture direct 443
fixture isp1 8443
check 'node selection uses visible number' test "$(select_node <<<'2')" = isp1
check 'ISP picker excludes Direct' test "$(select_node isp <<<'1')" = isp1
set +e
select_node <<<'0' >/dev/null; rc=$?
set -e
check 'node picker returns without mutation' test "$rc" = 20
home=$(dashboard)
check 'dashboard lists nodes' bash -c '[[ $1 == *direct* && $1 == *isp1* ]]' _ "$home"
if [[ $home == *hysteria2://* || $home == *"$(printf 'a%.0s' {1..48})"* ]]; then exit 1; fi
pass 'dashboard hides authentication and URIs'
main_menu <<<'0' 2>"$tmp/menu"
check 'installed menu exposes node management' grep -Fq '管理节点' "$tmp/menu"
if grep -Fq '全新安装' "$tmp/menu"; then exit 1; fi
pass 'installed menu hides reinstall'
(
  MANAGER_STATE_UNUSED=1
  # The only removed file is this suite's generated state fixture.
  rm -f "$MANAGER_STATE"
  main_menu <<<'0' 2>"$tmp/fresh-menu"
)
check 'fresh menu offers custom-domain installation' grep -Fq '自定义域名' "$tmp/fresh-menu"
fixture isp1 8443

change_node_port isp1 <<<'9443'
check 'port configuration updated' grep -Fxq 'listen: :9443' "$HYSTERIA_DIR/isp1.yaml"
check 'export port updated' grep -Fq '@test.example.com:9443/' "$EXPORT_DIR/hy2-isp1.txt"
check 'state port updated' grep -Fxq 'LISTEN_PORT=9443' "$NODE_DIR/isp1.env"
check 'ISP metadata survives port update' grep -Fxq 'SOCKS_UDP=supported' "$NODE_DIR/isp1.env"
check 'ISP credentials survive port update' grep -Fq 'password: "test:password@only"' "$HYSTERIA_DIR/isp1.yaml"
check 'old firewall rule closed after success' grep -Fxq 'close 8443' "$tmp/firewall-calls"
cp "$HYSTERIA_DIR/isp1.yaml" "$tmp/config-before-failure"
cp "$NODE_DIR/isp1.env" "$tmp/state-before-failure"
cp "$EXPORT_DIR/hy2-isp1.txt" "$tmp/uri-before-failure"
FAIL_PORT=10443
set +e
(set -e; change_node_port isp1 <<<'10443'); rc=$?
set -e
check 'start failure reports failure' test "$rc" -ne 0
check 'config restored on start failure' cmp -s "$HYSTERIA_DIR/isp1.yaml" "$tmp/config-before-failure"
check 'state restored on start failure' cmp -s "$NODE_DIR/isp1.env" "$tmp/state-before-failure"
check 'URI restored on start failure' cmp -s "$EXPORT_DIR/hy2-isp1.txt" "$tmp/uri-before-failure"
check 'old listener restarted on rollback' grep -Fxq 'start hy2m-isp1.service 9443' "$tmp/start-calls"
check 'new firewall rule removed on rollback' grep -Fxq 'close 10443' "$tmp/firewall-calls"
unset FAIL_PORT
set +e
(
  set -e
  install() {
    [[ ${*: -2:1} != */uri.new ]] || return 1
    local args=()
    while (($#)); do case $1 in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
    command install "${args[@]}"
  }
  simulate_node_menu() { local id=isp1; change_node_port "$id" <<<'11443'; }
  simulate_node_menu
)
rc=$?
set -e
check 'file-write failure is reported' test "$rc" -ne 0
check 'partially installed config is rolled back' cmp -s "$HYSTERIA_DIR/isp1.yaml" "$tmp/config-before-failure"
check 'URI is preserved on file-write failure' cmp -s "$EXPORT_DIR/hy2-isp1.txt" "$tmp/uri-before-failure"
check 'state is preserved on file-write failure' cmp -s "$NODE_DIR/isp1.env" "$tmp/state-before-failure"
(confirm() { return 1; }; change_node_port isp1 <<<'12443')
check 'cancelled confirmation leaves config intact' cmp -s "$HYSTERIA_DIR/isp1.yaml" "$tmp/config-before-failure"
if recorded_port_free 443 LISTEN_PORT isp1; then exit 1; fi
pass 'inactive node port reservations are respected'

# NAT-only external port changes do not restart the service.
write_env "$MANAGER_STATE" DOMAIN test.example.com NETWORK_MODE nat PUBLIC_IP 192.0.2.1 CERT_MODE http
write_env "$NODE_DIR/isp1.env" ID isp1 TYPE isp NAME isp1 LISTEN_PORT 9443 PUBLIC_PORT 19443 SERVICE hy2m-isp1.service CONFIG "$HYSTERIA_DIR/isp1.yaml" URI_FILE "$EXPORT_DIR/hy2-isp1.txt" NETWORK_MODE nat
before=$(wc -l <"$tmp/start-calls")
change_node_port isp1 <<< $'9443\n29443'
check 'NAT public port saved' grep -Fxq 'PUBLIC_PORT=29443' "$NODE_DIR/isp1.env"
check 'NAT-only edit avoids restarting service' test "$(wc -l <"$tmp/start-calls")" = "$before"

# Protect aliases belonging to other applications.
require_root() { return 0; }
printf 'unrelated\n' >"$BIN_DIR/hy2"
set +e
(set -e; install_self) >/dev/null 2>&1; rc=$?
set -e
check 'shortcut collision is rejected' test "$rc" -ne 0
check 'foreign shortcut is untouched' grep -Fxq unrelated "$BIN_DIR/hy2"

# Remove only the collision fixture created above.
rm -f "$BIN_DIR/hy2"
(
  BASH_ARGV0="$PWD/hy2-manager"
  install_self
)
check 'shortcut executable is installed' test -f "$BIN_DIR/hy2"
check 'installed manager content matches source' cmp -s hy2-manager "$APP_DIR/hy2-manager"
if [[ -L $BIN_DIR/hy2 ]]; then
  check 'shortcut targets installed manager' test "$(readlink "$BIN_DIR/hy2")" = "$APP_DIR/hy2-manager"
  (BASH_ARGV0="$PWD/hy2-manager"; install_self)
  pass 'shortcut installation is idempotent'
else
  printf '[SKIP] native symlink idempotence requires POSIX symlinks; CI verifies it\n'
fi

printf '\nUI and port transaction tests passed.\n'
