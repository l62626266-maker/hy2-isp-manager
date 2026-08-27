#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2015,SC2016
set -Eeuo pipefail
cd "$(dirname "$0")/.."

failures=0
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; failures=$((failures+1)); }
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

check "manager syntax" bash -n hy2-manager
check "installer syntax" bash -n install.sh
check "manager has no CRLF" bash -c '! grep -q $'"'\r'"' hy2-manager'
check "installer has no CRLF" bash -c '! grep -q $'"'\r'"' install.sh'

export HY2M_SOURCE_ONLY=1
export HY2M_TESTING=1
HY2M_APP_DIR="$(mktemp -d)/app"; export HY2M_APP_DIR
HY2M_STATE_DIR="$(mktemp -d)/state"; export HY2M_STATE_DIR
HY2M_EXPORT_DIR="$(mktemp -d)/export"; export HY2M_EXPORT_DIR
HY2M_HYSTERIA_DIR="$(mktemp -d)/hysteria"; export HY2M_HYSTERIA_DIR
HY2M_BACKUP_DIR="$(mktemp -d)/backup"; export HY2M_BACKUP_DIR
legacy_test_root=$(mktemp -d)
HY2M_LEGACY_CONFIG="$legacy_test_root/config.yaml"; export HY2M_LEGACY_CONFIG
HY2M_LEGACY_MANAGER_CONFIG="$legacy_test_root/manager.conf"; export HY2M_LEGACY_MANAGER_CONFIG
HY2M_LEGACY_URI_FILE="$legacy_test_root/direct-uri.txt"; export HY2M_LEGACY_URI_FILE
HY2M_LEGACY_TLS_CERT="$legacy_test_root/fullchain.pem"; export HY2M_LEGACY_TLS_CERT
# shellcheck source=../hy2-manager
source ./hy2-manager

check "valid low port" valid_port 1
check "valid high port" valid_port 65535
if valid_port 0; then fail "reject port zero"; else pass "reject port zero"; fi
if valid_port 65536; then fail "reject too-high port"; else pass "reject too-high port"; fi
check "valid domain" valid_domain node.example.com
if valid_domain 'https://bad.example.com'; then fail "reject URL as domain"; else pass "reject URL as domain"; fi
check "valid IPv4" valid_ipv4 45.141.36.130
if valid_ipv4 999.1.2.3; then fail "reject invalid IPv4 octet"; else pass "reject invalid IPv4 octet"; fi
[[ $(yaml_quote 'a"b\c') == '"a\"b\\c"' ]] && pass "YAML quoting" || fail "YAML quoting"

mkdir -p "$STATE_DIR"
write_env "$STATE_DIR/test.env" A 'hello world' B 'x$y' C "quote'"
unset A B C
# shellcheck disable=SC1090
source "$STATE_DIR/test.env"
[[ $A == 'hello world' && $B == 'x$y' && $C == "quote'" ]] && pass "state round trip" || fail "state round trip"
[[ $(stat -c '%a' "$STATE_DIR/test.env") == 600 ]] && pass "state mode 600" || fail "state mode 600"
write_env "$MANAGER_STATE" APP_VERSION 'legacy-beta' DOMAIN 'state.example.com' PUBLIC_IP '192.0.2.1' NETWORK_MODE nat CERT_MODE cloudflare
load_manager
[[ $APP_VERSION == '0.2.1' && $DOMAIN == 'state.example.com' ]] && pass "legacy APP_VERSION state compatibility" || fail "legacy APP_VERSION state compatibility"
mkdir -p "$NODE_DIR"; printf 'PUBLIC_PORT=56777\n' >"$NODE_DIR/nat.env"
if public_port_free 56777; then fail "reject duplicate NAT public port"; else pass "reject duplicate NAT public port"; fi
check "allow unused NAT public port" public_port_free 56778

cfg=$(write_common_config 443 abcdef)
grep -Fq 'listen: :443' <<<"$cfg" && pass "common config listen" || fail "common config listen"
grep -Fq 'sniGuard: strict' <<<"$cfg" && pass "strict SNI" || fail "strict SNI"
if grep -Fq 'insecure=1' hy2-manager; then fail "no insecure client URI"; else pass "no insecure client URI"; fi

# Static security contracts for ISP full nodes.
grep -Fq 'printf '\''acl:\n  inline:\n    - %s(all)\n'\''' hy2-manager && pass "ISP ACL is explicit all" || fail "ISP ACL is explicit all"
if awk '/create_isp\(\)/,/^}/' hy2-manager | grep -Fq 'type: direct'; then fail "ISP block has direct fallback"; else pass "ISP block has no direct fallback"; fi
grep -Fq 'SOCKS_PASS=$(ask_secret' hy2-manager && pass "SOCKS password hidden input" || fail "SOCKS password hidden input"
if grep -Eq 'python3[^#]*\$SOCKS_PASS' hy2-manager; then fail "SOCKS password exposed in process arguments"; else pass "SOCKS password absent from process arguments"; fi
grep -Fq 'dns_cloudflare_api_token' hy2-manager && pass "Cloudflare DNS-01 supported" || fail "Cloudflare DNS-01 supported"
grep -Fq 'PUBLIC_PORT' hy2-manager && grep -Fq 'LISTEN_PORT' hy2-manager && pass "public/listen ports separated" || fail "public/listen ports separated"
grep -Fq 'sha256sum "$binary"' hy2-manager && pass "Hysteria checksum verification" || fail "Hysteria checksum verification"
grep -Fq 'systemd-detect-virt --container' hy2-manager && pass "restricted container detection" || fail "restricted container detection"
if grep -Fq 'sysctl --system' hy2-manager; then fail "must not reapply unrelated sysctl files"; else pass "no global sysctl replay"; fi
grep -Fq 'try_network_sysctl net.core.rmem_max 16777216' hy2-manager && pass "conservative QUIC buffer attempt" || fail "conservative QUIC buffer attempt"
grep -Fq 'if ! is_restricted_container' hy2-manager && grep -Fq 'restricted container blocks CLONE_NEWNS' hy2-manager && pass "restricted container systemd compatibility" || fail "restricted container systemd compatibility"
grep -Fq 'NoNewPrivileges=true' hy2-manager && grep -Fq 'CapabilityBoundingSet=' hy2-manager && pass "service baseline hardening retained" || fail "service baseline hardening retained"
grep -Fq "qrencode -t ANSIUTF8 || true" hy2-manager && pass "qrencode reads URI from stdin" || fail "qrencode reads URI from stdin"
if grep -Fq 'qrencode -t ANSIUTF8 -r -' hy2-manager; then fail "no incompatible qrencode stdin filename"; else pass "no incompatible qrencode stdin filename"; fi
port_result=$(ask_valid_port test 'port' '' <<< $'bad\n70000\n8443')
[[ $port_result == 8443 ]] && pass "invalid port retries in current field" || fail "invalid port retries in current field"
set +e; ask test value '' <<<':menu' >/dev/null; menu_rc=$?; set -e
[[ $menu_rc == 20 ]] && pass "text prompt can return to menu" || fail "text prompt can return to menu"
test_fail_action() { exit 7; }
run_menu_action test_fail_action
pass "menu isolates action failure"
grep -Fq 'INSTALL_SESSION=' hy2-manager && grep -Fq '已恢复非敏感安装进度' hy2-manager && pass "non-secret install checkpoint" || fail "non-secret install checkpoint"
grep -Fq 'SOCKS5 测试失败，是否重新输入' hy2-manager && pass "SOCKS failure retry path" || fail "SOCKS failure retry path"

# Node inventory must remain independent: deleting ISP cannot hide Direct.
rm -rf "$NODE_DIR"; mkdir -p "$NODE_DIR" "$EXPORT_DIR" "$HYSTERIA_DIR"
printf 'direct-uri\n' >"$EXPORT_DIR/direct.txt"; printf 'isp-uri\n' >"$EXPORT_DIR/isp1.txt"
printf 'direct-config\n' >"$HYSTERIA_DIR/direct.yaml"; printf 'isp-config\n' >"$HYSTERIA_DIR/isp1.yaml"
save_node direct direct HY2-Direct 443 443 hy2m-direct.service "$HYSTERIA_DIR/direct.yaml" "$EXPORT_DIR/direct.txt" normal
save_node isp1 isp HY2-ISP-Full 8443 8443 hy2m-isp1.service "$HYSTERIA_DIR/isp1.yaml" "$EXPORT_DIR/isp1.txt" normal
TEST_CONFIRM=no
confirm() { [[ $TEST_CONFIRM == yes ]]; }
systemctl() { return 0; }
view_before=$(show_nodes)
[[ $view_before == *HY2-Direct* && $view_before == *HY2-ISP-Full* ]] && pass "show Direct and ISP independently" || fail "show Direct and ISP independently"
TEST_CONFIRM=yes
remove_node <<<'isp1' >/dev/null
[[ -r $NODE_DIR/direct.env && ! -e $NODE_DIR/isp1.env ]] && pass "deleting ISP preserves Direct state" || fail "deleting ISP preserves Direct state"
TEST_CONFIRM=no
view_after=$(show_nodes)
[[ $view_after == *HY2-Direct* && $view_after != *HY2-ISP-Full* ]] && pass "Direct remains visible after ISP deletion" || fail "Direct remains visible after ISP deletion"
save_node isp1 isp HY2-ISP-Full 8443 8443 hy2m-isp1.service "$HYSTERIA_DIR/isp1.yaml" "$EXPORT_DIR/isp1.txt" normal
if (TEST_CONFIRM=yes; remove_node <<<'direct' >/dev/null 2>&1); then fail "block deleting Direct while ISP exists"; else pass "block deleting Direct while ISP exists"; fi
rm -f "$NODE_DIR/direct.env"
if (show_nodes >/dev/null 2>&1); then fail "reject unsupported ISP-only inventory"; else pass "reject unsupported ISP-only inventory"; fi

# Existing pre-manager Direct nodes remain visible without manager.env.
rm -f "$MANAGER_STATE" "$NODE_DIR"/*.env
printf 'listen: :443\n' >"$LEGACY_CONFIG"
printf 'DOMAIN=legacy.example.com\n' >"$LEGACY_MANAGER_CONFIG"
printf 'hysteria2://redacted@legacy.example.com:443/?sni=legacy.example.com#Direct\n' >"$LEGACY_URI_FILE"
legacy_view=$(show_nodes)
[[ $legacy_view == *'HY2-Direct（现有兼容节点）'* && $legacy_view == *'内部 UDP: 443'* ]] && pass "legacy Direct visible without manager state" || fail "legacy Direct visible without manager state"
legacy_status=$(status_all)
[[ $legacy_status == *'现有兼容节点视图'* && $legacy_status == *'legacy.example.com'* ]] && pass "legacy Direct status without manager state" || fail "legacy Direct status without manager state"
grep -Fq '必须先存在HY2直连节点，才能添加ISP节点' hy2-manager && pass "ISP requires Direct" || fail "ISP requires Direct"

if (( failures )); then printf '\n%d test(s) failed.\n' "$failures" >&2; exit 1; fi
printf '\nAll tests passed.\n'
