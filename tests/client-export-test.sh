#!/usr/bin/env bash
# Offline client-profile regressions. No real services, firewall or credentials.
# shellcheck disable=SC1091,SC2034,SC2317
set -Eeuo pipefail
cd "$(dirname "$0")/.."
[[ ! -L .tmp ]] || exit 1
mkdir -p .tmp
root=$(mktemp -d "$PWD/.tmp/client-export.XXXXXX")
export TMPDIR="$root/tmp" TMP="$root/tmp" TEMP="$root/tmp"
export HOME="$root/home" XDG_CACHE_HOME="$root/cache" XDG_CONFIG_HOME="$root/user-config" XDG_DATA_HOME="$root/data"
export PYTHONDONTWRITEBYTECODE=1 PYTHONIOENCODING=utf-8
mkdir -p "$TMPDIR" "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
export HY2M_SOURCE_ONLY=1 HY2M_TESTING=1
export HY2M_APP_DIR="$root/app" HY2M_STATE_DIR="$root/state" HY2M_EXPORT_DIR="$root/export"
export HY2M_HYSTERIA_DIR="$root/config" HY2M_BACKUP_DIR="$root/backups"
export HY2M_SERVICE_DIR="$root/systemd" HY2M_SBIN_DIR="$root/sbin" HY2M_BIN_DIR="$root/bin"
export HY2M_LETSENCRYPT_DIR="$root/acme" HY2M_SYSCTL_FILE="$root/sysctl" HY2M_SWAP_FILE="$root/swap"
export HY2M_LEGACY_CONFIG="$root/legacy.yaml" HY2M_LEGACY_MANAGER_CONFIG="$root/legacy.conf"
export HY2M_LEGACY_URI_FILE="$root/legacy-uri" HY2M_LEGACY_TLS_CERT="$root/legacy-cert"
source ./hy2-manager
mkdir -p "$NODE_DIR" "$EXPORT_DIR" "$HYSTERIA_DIR"
failures=0
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; failures=$((failures + 1)); }
check() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
forbidden() { printf '%s\n' "$*" >>"$root/forbidden-calls"; return 98; }
systemctl() { forbidden "systemctl $*"; }
ufw() { forbidden "ufw $*"; }
curl() { forbidden "curl $*"; }
confirm() { return 0; }

fixture() {
  local id=$1 name=$2 public=$3 kind=direct
  [[ $id == direct ]] || kind=isp
  save_node "$id" "$kind" "$name" 443 "$public" "hy2m-$id.service" "$HYSTERIA_DIR/$id.yaml" "$EXPORT_DIR/hy2-$id.txt" nat
  printf 'hysteria2://fixture-password@test.example.com:%s/?sni=test.example.com&insecure=0#ignored-name\n' "$public" >"$EXPORT_DIR/hy2-$id.txt"
}
# Quoted values are JSON-compatible YAML scalars; compare decoded values, not
# raw escaping. Full profile structure is checked separately below.
field_equals() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
prefix = '    ' + sys.argv[2] + ': '
values = [json.loads(line[len(prefix):]) for line in lines if line.startswith(prefix)]
sys.exit(0 if len(values) == 1 and str(values[0]) == sys.argv[3] else 1)
PY
}
fixture direct HY2-Direct 56777
fixture isp1 ISP-Test 56778
printf 'password: "upstream-socks-secret"\n' >"$HYSTERIA_DIR/isp1.yaml"
cp -p "$NODE_DIR/direct.env" "$root/state.before"
cp -p "$EXPORT_DIR/hy2-direct.txt" "$root/uri.before"
export_clash direct >"$root/direct.yaml"
check 'full profile has isolated selector and fail-closed default route' python3 - "$root/direct.yaml" <<'PY'
from pathlib import Path
import sys
expected = '''# Sensitive HY2 client profile; do not publish or upload to converters.
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
proxies:
  - name: "HY2-Direct"
    type: hysteria2
    server: "test.example.com"
    port: 56777
    password: "fixture-password"
    sni: "test.example.com"
    skip-cert-verify: false
proxy-groups:
  - name: "HY2-PROXY"
    type: select
    proxies:
      - "HY2-Direct"
rules:
  - "MATCH,HY2-PROXY"
'''
sys.exit(0 if Path(sys.argv[1]).read_text(encoding='utf-8') == expected else 1)
PY
check 'NAT uses public rather than listener port' field_equals "$root/direct.yaml" port 56777
check 'export never changes node state' cmp -s "$NODE_DIR/direct.env" "$root/state.before"
check 'export never changes source URI' cmp -s "$EXPORT_DIR/hy2-direct.txt" "$root/uri.before"
check 'export does not cache a stale YAML alongside URIs' test ! -e "$EXPORT_DIR/hy2-direct.yaml"
export_clash isp1 >"$root/isp.yaml"
check 'ISP node exports HY2 authentication only' field_equals "$root/isp.yaml" password fixture-password
if grep -Fq upstream-socks-secret "$root/isp.yaml"; then fail 'SOCKS credentials never enter client export'; else pass 'SOCKS credentials never enter client export'; fi

# State name wins over an obsolete fragment, and a changed URI is read afresh.
fixture direct Renamed 59443
printf 'hysteria2://changed-password@new.example.com:59443/?sni=tls.example.com&insecure=0#Old\n' >"$EXPORT_DIR/hy2-direct.txt"
export_clash direct >"$root/changed.yaml"
check 're-export follows current public port' field_equals "$root/changed.yaml" port 59443
check 're-export follows current server' field_equals "$root/changed.yaml" server new.example.com
check 'SNI is independent of the server address' field_equals "$root/changed.yaml" sni tls.example.com
check 're-export follows current node name' grep -Fxq '  - name: "Renamed"' "$root/changed.yaml"
check 're-export follows current HY2 password' field_equals "$root/changed.yaml" password changed-password

printf '%s\n' 'hysteria2://user%3Apa%40ss%23%20%22%5C%25@test.example.com:443/?sni=test.example.com' >"$EXPORT_DIR/hy2-direct.txt"
export_clash direct >"$root/escaped.yaml"
check 'encoded password survives YAML quoting' field_equals "$root/escaped.yaml" password 'user:pa@ss# "\%'
printf '%s\n' 'hysteria2://test%E4%B8%AD%E6%96%87%E2%80%A8password@test.example.com:443/' >"$EXPORT_DIR/hy2-direct.txt"
export_clash direct >"$root/unicode.yaml"
check 'Unicode line separators stay escaped in YAML' grep -Fq '\u2028' "$root/unicode.yaml"
printf '%s\n' 'hy2://user:password@[2001:db8::1]/' >"$EXPORT_DIR/hy2-direct.txt"
export_clash direct >"$root/ipv6.yaml"
check 'username/password auth is not truncated' field_equals "$root/ipv6.yaml" password user:password
check 'IPv6 hostname loses URI brackets' field_equals "$root/ipv6.yaml" server 2001:db8::1
check 'omitted URI port defaults to 443' field_equals "$root/ipv6.yaml" port 443
check 'omitted SNI defaults to URI host' field_equals "$root/ipv6.yaml" sni 2001:db8::1

fixture direct DIRECT 443
export_clash direct >"$root/reserved.yaml"
check 'node cannot shadow built-in DIRECT' grep -Fxq '  - name: "HY2-DIRECT"' "$root/reserved.yaml"
fixture direct HY2-PROXY 443
export_clash direct >"$root/group-collision.yaml"
check 'selector name cannot collide with node' grep -Fxq '  - "MATCH,HY2-PROXY-OUT"' "$root/group-collision.yaml"
fixture direct 'quoted: "name"' 443
export_clash direct >"$root/quoted.yaml"
check 'node names are safely quoted in YAML and selector' python3 - "$root/quoted.yaml" <<'PY'
import json, sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
name = json.loads(next(line[len('  - name: '):] for line in lines if line.startswith('  - name: ')))
member = json.loads(next(line[len('      - '):] for line in lines if line.startswith('      - ')))
sys.exit(0 if name == member == 'quoted: "name"' else 1)
PY

bad_uris=(
  'not-a-uri'
  'https://password@test.example.com:443/'
  'hysteria2://@test.example.com:443/'
  'hysteria2://password@test.example.com:0/'
  'hysteria2://password@test.example.com:65536/'
  'hysteria2://password@test.example.com:443/path'
  'hysteria2://password@test.example.com:443/?insecure=1'
  'hysteria2://password@test.example.com:443/?insecure=true'
  'hysteria2://password@test.example.com:443/?sni='
  'hysteria2://password@test.example.com:443/?sni=a.example.com&sni=b.example.com'
  'hysteria2://password@test.example.com:443/?obfs=salamander&obfs-password=example'
  'hysteria2://password@test.example.com:443/?pinSHA256=example'
  'hysteria2://invalid%ZZ@test.example.com:443/'
  'hysteria2://password@test.example.com:443/?sni=%FF'
  'hysteria2://bad%0Apassword@test.example.com:443/'
)
for uri in "${bad_uris[@]}"; do
  printf '%s\n' "$uri" >"$EXPORT_DIR/hy2-direct.txt"
  if export_clash direct >"$root/rejected.yaml" 2>"$root/rejected.log"; then fail 'invalid/unsupported URI rejected'
  elif [[ -s $root/rejected.yaml ]]; then fail 'invalid URI produced a partial profile'
  else pass 'invalid/unsupported URI rejected without partial output'; fi
  if grep -Fq "$uri" "$root/rejected.log"; then fail 'error must not print sensitive URI'; fi
done
fixture direct HY2-Direct 443
select_node() { printf direct; }
export_clash >"$root/selected.yaml"
check 'interactive selection exports the selected node' field_equals "$root/selected.yaml" port 443
if export_clash '../outside' >"$root/invalid-id.yaml" 2>"$root/invalid-id.log"; then fail 'path traversal ID rejected'; else pass 'path traversal ID rejected'; fi
check 'invalid ID produces no profile' test ! -s "$root/invalid-id.yaml"
if export_clash isp99 >"$root/missing.yaml" 2>"$root/missing.log"; then fail 'missing node rejected'; else pass 'missing node rejected'; fi
(confirm() { return 1; }; show_clash_export direct) >"$root/cancelled.yaml"
check 'menu cancellation reveals no credentials' test ! -s "$root/cancelled.yaml"
show_clash_export direct >"$root/confirmed.yaml"
check 'confirmed menu export matches CLI' cmp -s "$root/confirmed.yaml" "$root/selected.yaml"
check 'no service/firewall/network mutations' test ! -e "$root/forbidden-calls"
# Expanded in the child shell, not while constructing the command.
# shellcheck disable=SC2016
check 'help documents the CLI export' bash -c '[[ $(HY2M_SOURCE_ONLY=0 bash hy2-manager --help) == *"export-clash"* ]]'
check 'plain node menu exposes export' grep -Fq 'menu_action show_clash_export' <<<"$(declare -f node_menu)"
check 'TUI node menu exposes export' grep -Fq 'ui_run show_clash_export' <<<"$(declare -f ui_node_actions)"
printf 'Client export failures: %d; fixtures: %s\n' "$failures" "$root"
((failures == 0))
