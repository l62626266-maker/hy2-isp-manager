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
[[ $APP_VERSION == '0.1.0' && $DOMAIN == 'state.example.com' ]] && pass "legacy APP_VERSION state compatibility" || fail "legacy APP_VERSION state compatibility"
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

if (( failures )); then printf '\n%d test(s) failed.\n' "$failures" >&2; exit 1; fi
printf '\nAll tests passed.\n'
