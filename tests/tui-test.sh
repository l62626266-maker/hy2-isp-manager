#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2317,SC2016
# Covers the interactive panel: key decoding, layout rendering, node lifecycle
# actions and the plain-menu fallback. Never talks to systemd/UFW/sudo.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp
export TMPDIR="${TMPDIR:-$PWD/.tmp}"
tmp=$(mktemp -d "$TMPDIR/tui.XXXXXX")
export HY2M_SOURCE_ONLY=1 HY2M_TESTING=1
export HY2M_APP_DIR="$tmp/app" HY2M_STATE_DIR="$tmp/state" HY2M_EXPORT_DIR="$tmp/export"
export HY2M_HYSTERIA_DIR="$tmp/config" HY2M_BACKUP_DIR="$tmp/backup"
export HY2M_SERVICE_DIR="$tmp/systemd" HY2M_SBIN_DIR="$tmp/sbin" HY2M_BIN_DIR="$tmp/bin"
export HY2M_LEGACY_CONFIG="$tmp/legacy.yaml" HY2M_LEGACY_MANAGER_CONFIG="$tmp/legacy.conf"
export HY2M_LEGACY_URI_FILE="$tmp/legacy-uri" HY2M_LEGACY_TLS_CERT="$tmp/legacy-cert"
source ./hy2-manager
trap 'cleanup; rm -rf "$tmp"' EXIT
mkdir -p "$NODE_DIR" "$EXPORT_DIR" "$HYSTERIA_DIR" "$SERVICE_DIR" "$SBIN_DIR" "$BIN_DIR"

failures=0
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; failures=$((failures + 1)); }
check() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

# A missing python3 must degrade to the plain menu, never to a broken panel.
if ! command -v python3 >/dev/null 2>&1; then
  printf '[SKIP] python3 is required for the panel renderer\n'
  exit 0
fi

# Rendering helpers are pure; stub the terminal and the service backend.
tput() { case $1 in cols) printf '80\n' ;; lines) printf '24\n' ;; *) return 0 ;; esac; }
systemctl() {
  printf '%s\n' "$*" >>"$tmp/systemctl-calls"
  [[ $1 != is-active ]] || printf '%s\n' "${FAKE_STATE:-active}"
  return 0
}
confirm() { return 0; }
start_checked() { printf 'start %s %s\n' "$1" "$2" >>"$tmp/start-calls"; }
select_node() { printf 'isp1'; }

fixture() {
  local id=$1 port=$2 type=direct
  [[ $id != direct ]] && type=isp
  printf 'listen: :%s\n' "$port" >"$HYSTERIA_DIR/$id.yaml"
  printf 'hysteria2://secret@test.example.com:%s/\n' "$port" >"$EXPORT_DIR/hy2-$id.txt"
  save_node "$id" "$type" "$id" "$port" "$port" "hy2m-$id.service" \
    "$HYSTERIA_DIR/$id.yaml" "$EXPORT_DIR/hy2-$id.txt" normal
}
write_env "$MANAGER_STATE" DOMAIN test.example.com NETWORK_MODE normal PUBLIC_IP 192.0.2.1 CERT_MODE http
fixture direct 443
fixture isp1 8443
load_manager

# --- key decoding -----------------------------------------------------------
check 'enter decodes' test "$(printf '\r' | ui_readkey)" = enter
check 'plain key passes through' test "$(printf 'q' | ui_readkey)" = q
check 'arrow up decodes' test "$(printf '\033[A' | ui_readkey)" = up
check 'arrow down decodes' test "$(printf '\033[B' | ui_readkey)" = down
check 'lone escape decodes' test "$(printf '\033' | ui_readkey)" = esc
check 'EOF becomes quit' test "$(ui_readkey </dev/null)" = quit

# --- inventory --------------------------------------------------------------
check 'inventory lists managed nodes' test "$(ui_node_ids | tr '\n' ' ')" = 'direct isp1 '
check 'node cells carry name and type' bash -c '[[ $1 == isp1*isp* ]]' _ "$(ui_node_cells isp1)"

# --- layout -----------------------------------------------------------------
panel=$(ui_draw_panel 1 direct isp1 2>&1)
check 'panel shows manager title' bash -c '[[ $1 == *"HY2 ISP Manager"* ]]' _ "$panel"
check 'panel shows domain' bash -c '[[ $1 == *test.example.com* ]]' _ "$panel"
check 'panel lists every node' bash -c '[[ $1 == *direct* && $1 == *isp1* ]]' _ "$panel"
check 'panel shows ports' bash -c '[[ $1 == *443/443* && $1 == *8443/8443* ]]' _ "$panel"
check 'panel marks the selected row' bash -c '[[ $1 == *">2  isp1"* ]]' _ "$panel"
check 'panel shows service state' bash -c '[[ $1 == *运行中* ]]' _ "$panel"
if [[ $panel == *hysteria2://* || $panel == *secret@* ]]; then
  fail 'panel must not leak the import URI'
else
  pass 'panel hides authentication and URIs'
fi
check 'panel borders are aligned' python3 -c '
import re, sys, unicodedata
ansi = re.compile(r"\[[0-9;]*[A-Za-z]")
def dw(s):
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)
lines = [ansi.sub("", l) for l in sys.argv[1].splitlines()]
lines = [l for l in lines if l]
widths = {dw(l) for l in lines}
sys.exit(0 if len(widths) == 1 else 1)
' "$panel"
empty=$(ui_draw_panel 0 2>&1)
check 'empty inventory explains the next step' bash -c '[[ $1 == *"尚未创建节点"* ]]' _ "$empty"

menu_view=$(ui_draw_menu '管理 isp1' '选择要执行的操作' 0 '查看详情' '启动节点' 2>&1)
check 'menu renders every entry' bash -c '[[ $1 == *查看详情* && $1 == *启动节点* ]]' _ "$menu_view"
check 'menu marks the selected entry' bash -c '[[ $1 == *"> 查看详情"* ]]' _ "$menu_view"

# --- navigation -------------------------------------------------------------
check 'menu returns the highlighted key' test "$(printf '\r' | ui_menu t p '1|one' '2|two')" = 1
check 'menu follows the cursor' test "$(printf '\033[B\r' | ui_menu t p '1|one' '2|two')" = 2
check 'menu stops at the last entry' test "$(printf '\033[B\033[B\033[B\r' | ui_menu t p '1|one' '2|two')" = 2
set +e
printf '\033' | ui_menu t p '1|one' >/dev/null; rc=$?
set -e
check 'escape leaves the menu' test "$rc" = 20

# --- lifecycle --------------------------------------------------------------
FAKE_STATE=inactive
start_node isp1 >/dev/null
check 'start checks the unit state first' grep -Fq 'is-active hy2m-isp1.service' "$tmp/systemctl-calls"
check 'start verifies the listener' grep -Fq 'start hy2m-isp1.service 8443' "$tmp/start-calls"
FAKE_STATE=active
: >"$tmp/start-calls"
start_node isp1 >/dev/null
check 'start is idempotent' test ! -s "$tmp/start-calls"
stop_node isp1 >/dev/null
check 'stop issues a stop' grep -Fq 'stop hy2m-isp1.service' "$tmp/systemctl-calls"
: >"$tmp/start-calls"
restart_node isp1 >/dev/null
check 'restart restarts the unit' grep -Fq 'start hy2m-isp1.service 8443' "$tmp/start-calls"

# --- entry conditions -------------------------------------------------------
ui_requested && fail 'panel requires a TTY' || pass 'panel requires a TTY'
HY2M_UI=plain ui_requested && fail 'HY2M_UI=plain disables the panel' || pass 'HY2M_UI=plain disables the panel'
TERM=dumb ui_requested && fail 'TERM=dumb disables the panel' || pass 'TERM=dumb disables the panel'

# Without a TTY the classic numbered menu must still drive the manager.
tput() { case $1 in cols) printf '40\n' ;; *) return 0 ;; esac; }
choose() { printf '0\n'; }
main_menu </dev/null >/dev/null 2>&1
check 'plain menu still opens without a TTY' true

if ((failures)); then
  printf '\n%d TUI test(s) failed.\n' "$failures" >&2
  exit 1
fi
printf '\nTUI panel tests passed.\n'
