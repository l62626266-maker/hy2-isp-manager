#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2317,SC2016
# Pure TUI regressions: every service/install action is stubbed, no host changes.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp
export TMPDIR="$PWD/.tmp" TMP="$PWD/.tmp" TEMP="$PWD/.tmp"
tmp=$(mktemp -d "$TMPDIR/tui-pagination.XXXXXX")
export HY2M_SOURCE_ONLY=1 HY2M_TESTING=1
export HY2M_APP_DIR="$tmp/app" HY2M_STATE_DIR="$tmp/state" HY2M_EXPORT_DIR="$tmp/export"
export HY2M_HYSTERIA_DIR="$tmp/config" HY2M_BACKUP_DIR="$tmp/backup"
export HY2M_SERVICE_DIR="$tmp/systemd" HY2M_SBIN_DIR="$tmp/sbin" HY2M_BIN_DIR="$tmp/bin"
export HY2M_LEGACY_CONFIG="$tmp/legacy.yaml" HY2M_LEGACY_MANAGER_CONFIG="$tmp/legacy.conf"
export HY2M_LEGACY_URI_FILE="$tmp/legacy-uri" HY2M_LEGACY_TLS_CERT="$tmp/legacy-cert"
source ./hy2-manager
# Keep generated fixtures/frames for diagnosis; remove only manager-owned temp files.
trap cleanup EXIT
mkdir -p "$NODE_DIR"
failures=0
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; failures=$((failures + 1)); }
check() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
if ! command -v python3 >/dev/null 2>&1; then
  printf '[SKIP] python3 is required for the panel renderer\n'
  exit 0
fi

export TERM=xterm NO_COLOR=1
TEST_COLS=70 TEST_ROWS=14
tput() { case $1 in cols) printf '%s\n' "$TEST_COLS" ;; lines) printf '%s\n' "$TEST_ROWS" ;; *) return 0 ;; esac; }
ui_node_cells() { printf 'Node-%s\tisp\t运行中\t1443\t2443\n' "$1"; }
ui_cert_text() { UI_CERT_TEXT='证书 未知'; }
DOMAIN=test.example.com NETWORK_MODE=normal
ids=() labels=() entries=()
for ((i = 1; i <= 30; i++)); do
  printf -v id 'isp%02d' "$i"
  printf -v label 'Item-%02d' "$i"
  ids+=("$id"); labels+=("$label"); entries+=("$i|$label")
done

# Each renderer writes a full frame after the home/clear sequence. Check every
# frame, not just the selected item or the final screen, using display widths.
frame_fits() {
  python3 -c '
import pathlib, re, sys, unicodedata
cols, rows = map(int, sys.argv[1:3])
text = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
ansi = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
def width(s):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)
frames = text.split("\x1b[H\x1b[2J")
for frame in frames:
    lines = ansi.sub("", frame).splitlines()
    if len(lines) > rows - 1 or any(width(line) >= cols for line in lines):
        print("frame overflow: lines=%d max_width=%d terminal=%dx%d" % (len(lines), max(map(width, lines), default=0), cols, rows))
        sys.exit(1)
' "$1" "$2" "$3"
}

# Layout red cases: an ISP action menu has 11 entries; the inventory is unbounded.
for geometry in '70 14' '80 24'; do
  read -r TEST_COLS TEST_ROWS <<<"$geometry"
  ui_draw_panel 29 "${ids[@]}" 2>"$tmp/panel-$TEST_COLS.frames"
  check "many-node panel fits ${TEST_COLS}x${TEST_ROWS}" frame_fits "$TEST_COLS" "$TEST_ROWS" "$tmp/panel-$TEST_COLS.frames"
  check 'selected final node stays visible' grep -Fq '>30  Node-isp30' "$tmp/panel-$TEST_COLS.frames"
  if grep -Fq 'Node-isp01' "$tmp/panel-$TEST_COLS.frames"; then fail 'off-page nodes are not rendered'; else pass 'off-page nodes are not rendered'; fi
  check 'panel retains visible exit help' grep -Fq 'q 退出' "$tmp/panel-$TEST_COLS.frames"
  ui_draw_menu '长操作菜单' '选择要执行的操作' 29 "${labels[@]}" 2>"$tmp/menu-$TEST_COLS.frames"
  check "long menu fits ${TEST_COLS}x${TEST_ROWS}" frame_fits "$TEST_COLS" "$TEST_ROWS" "$tmp/menu-$TEST_COLS.frames"
  check 'selected final menu entry stays visible' grep -Fq '> Item-30' "$tmp/menu-$TEST_COLS.frames"
done
TEST_COLS=70 TEST_ROWS=14
ui_draw_menu 'ISP 节点操作' '包括删除与返回' 10 "${labels[@]:0:11}" 2>"$tmp/isp-actions.frames"
check 'eleven-entry ISP menu fits minimum geometry' frame_fits 70 14 "$tmp/isp-actions.frames"
printf -v long_title '%080d' 0
printf 'T\tbody\n' | ui_box 64 "$long_title" >"$tmp/long-title.frames"
check 'long box title cannot widen its border' frame_fits 70 14 "$tmp/long-title.frames"

# Selection-follow paging and full escape-sequence consumption.
check 'PageUp decodes' test "$(printf '\033[5~' | ui_readkey)" = pageup
check 'PageDown decodes' test "$(printf '\033[6~' | ui_readkey)" = pagedown
idle_resize() (
  UI_COLS=70 UI_ROWS=14 TEST_COLS=40 TEST_ROWS=8
  read() { return 142; }
  [[ $(ui_readkey) == resize ]]
)
idle_without_resize() (
  UI_COLS=70 UI_ROWS=14 TEST_COLS=70 TEST_ROWS=14
  local calls=0
  read() {
    calls=$((calls + 1))
    if (( calls == 1 )); then return 142; fi
    printf -v "${!#}" '%s' q
  }
  [[ $(ui_readkey) == q ]]
)
check 'idle resize asks for a redraw without a keypress' idle_resize
check 'idle timeout is neither Enter nor EOF' idle_without_resize
printf -v down_keys '\033[B%.0s' {1..29}
answer=$(printf '%s\r' "$down_keys" | ui_menu title prompt "${entries[@]}" 2>"$tmp/down-navigation.frames")
check 'all thirty menu choices remain reachable' test "$answer" = 30
check 'every down-navigation frame fits' frame_fits 70 14 "$tmp/down-navigation.frames"
answer=$(printf '\033[6~\r' | ui_menu title prompt "${entries[@]}" 2>"$tmp/pagedown.frames") || answer=cancelled
check 'PageDown advances by the visible five-entry page' test "$answer" = 6
answer=$(printf '\033[6~\033[5~\r' | ui_menu title prompt "${entries[@]}" 2>"$tmp/pageup.frames") || answer=cancelled
check 'PageUp returns to the first page' test "$answer" = 1

# An in-flight shrink must not display overflowing frames or accept hidden actions.
for geometry in '40 8' '10 3' '1 1'; do
  read -r TEST_COLS TEST_ROWS <<<"$geometry"
  ui_draw_panel 29 "${ids[@]}" 2>"$tmp/small-panel-$TEST_COLS.frames"
  check "undersized panel fits ${TEST_COLS}x${TEST_ROWS}" frame_fits "$TEST_COLS" "$TEST_ROWS" "$tmp/small-panel-$TEST_COLS.frames"
  ui_draw_menu title prompt 29 "${labels[@]}" 2>"$tmp/small-menu-$TEST_COLS.frames"
  check "undersized menu fits ${TEST_COLS}x${TEST_ROWS}" frame_fits "$TEST_COLS" "$TEST_ROWS" "$tmp/small-menu-$TEST_COLS.frames"
done
TEST_COLS=40 TEST_ROWS=8
rc=0
answer=$(printf '\r1q' | ui_menu title prompt '1|must not execute' 2>"$tmp/small-navigation.frames") || rc=$?
check 'small-window Enter and shortcut cannot accept hidden action' test "$rc:$answer" = '20:'
check 'small-window exit frame stays bounded' frame_fits 40 8 "$tmp/small-navigation.frames"
TEST_COLS=70 TEST_ROWS=14

# Enter/leave must follow is_tty (stdin + stderr), not captured stdout.
screen_capture() (
  is_tty() { return 0; }
  tput() { printf '<%s>' "$1"; }
  result=$({ ui_enter_screen; ui_leave_screen; } 2>"$tmp/screen-controls")
  [[ -z $result ]] && grep -Fq '<smcup>' "$tmp/screen-controls" && grep -Fq '<rmcup>' "$tmp/screen-controls"
)
check 'captured screen lifecycle sends controls only to stderr' screen_capture

# Action subshells change disk state, so the parent panel must reload it.
printf 'DOMAIN=before.example.com\nNETWORK_MODE=normal\n' >"$MANAGER_STATE"
reload_action() (
  load_manager
  is_tty() { return 1; }
  ui_enter_screen() { :; }; ui_leave_screen() { :; }
  change_state() { printf 'DOMAIN=after.example.com\nNETWORK_MODE=nat\n' >"$MANAGER_STATE"; }
  ui_run change_state
  [[ $DOMAIN == after.example.com && $NETWORK_MODE == nat ]]
)
check 'ui_run reloads domain/network after isolated action' reload_action

panel_navigation() (
  ui_enter_screen() { :; }; ui_leave_screen() { :; }
  # ui_main_loop declares its own local ids, which shadows the fixture under
  # Bash dynamic scoping; capture the fixture before the loop starts.
  local -a fixture=("${ids[@]}")
  ui_node_ids() { printf '%s\n' "${fixture[@]}"; }
  ui_node_actions() { printf '%s' "$1" >"$tmp/selected-node"; }
  printf '\033[6~\033[6~\033[6~\033[6~\033[6~\033[6~\r\033[5~\rq' | ui_main_loop 2>"$tmp/panel-navigation.frames"
  [[ $(<"$tmp/selected-node") == isp25 ]]
)
check 'panel page keys clamp at last node and can return one page' panel_navigation
check 'every panel-navigation frame fits' frame_fits 70 14 "$tmp/panel-navigation.frames"
resize_before_action() (
  printf '70 14\n' >"$tmp/resize-geometry"
  tput() {
    local cols rows
    read -r cols rows <"$tmp/resize-geometry"
    case $1 in cols) printf '%s' "$cols" ;; lines) printf '%s' "$rows" ;; esac
  }
  ui_readkey() {
    if [[ ! -e $tmp/resize-shrunk ]]; then
      printf '40 8\n' >"$tmp/resize-geometry"
      : >"$tmp/resize-shrunk"
      printf enter
    else printf q; fi
  }
  local result rc=0
  result=$(ui_menu title prompt '1|hidden action' 2>"$tmp/resize.frames") || rc=$?
  [[ $rc == 20 && -z $result ]]
)
check 'shrink between drawing and Enter cannot execute hidden action' resize_before_action

# The loop owns only its screen traps, never the caller cleanup/signal traps.
preserve_traps() (
  trap 'printf caller-cleanup >"$tmp/caller-cleanup"' EXIT
  trap ':' INT TERM
  before=$(trap -p EXIT INT TERM)
  ui_enter_screen() { :; }; ui_leave_screen() { :; }
  ui_node_ids() { :; }; ui_draw_panel() { :; }
  ui_readkey() { printf q; }
  ui_main_loop
  [[ $(trap -p EXIT INT TERM) == "$before" ]]
)
check 'TUI loop preserves existing cleanup and signal traps' preserve_traps
check 'caller cleanup still runs after the loop' test -s "$tmp/caller-cleanup"

# Drive the real fresh path (not a demo) while replacing only the installer.
fresh_entry() (
  mkdir -p "$tmp/fresh/state"
  # Independent child-shell fixtures; exports intentionally do not escape.
  # shellcheck disable=SC2030,SC2031
  export HY2M_STATE_DIR="$tmp/fresh/state" HY2M_SOURCE_ONLY=1
  # A new shell is needed because manager paths are readonly after sourcing.
  bash -c '
    source ./hy2-manager
    is_tty() { return 0; }
    tput() { case $1 in cols) printf 70 ;; lines) printf 14 ;; esac; }
    legacy_direct_available() { return 1; }
    choose() { printf plain >"$HY2M_STATE_DIR/plain-called"; printf 0; }
    with_mutation_lock() { "$@"; }
    initial_install() { printf installed >"$HY2M_STATE_DIR/installer-called"; printf "DOMAIN=fresh.example.com\nNETWORK_MODE=normal\n" >"$MANAGER_STATE"; }
    ui_node_ids() { :; }
    ui_cert_text() { UI_CERT_TEXT=unknown; }
    main_menu
  ' <<< $'\rxq' >"$tmp/fresh-stdout" 2>"$tmp/fresh.frames"
  [[ -s $tmp/fresh/state/installer-called && ! -e $tmp/fresh/state/plain-called ]] && grep -Fq 'fresh.example.com' "$tmp/fresh.frames"
)
check 'fresh eligible entry reaches real TUI install then panel' fresh_entry
check 'fresh install and panel frames fit minimum geometry' frame_fits 70 14 "$tmp/fresh.frames"

legacy_entry() (
  # Independent child-shell fixtures; exports intentionally do not escape.
  # shellcheck disable=SC2030,SC2031
  export HY2M_STATE_DIR="$tmp/legacy-state" HY2M_SOURCE_ONLY=1
  bash -c '
    source ./hy2-manager
    ui_requested() { return 0; }
    legacy_direct_available() { return 0; }
    dashboard() { printf legacy; }
    choose() { printf "%s" "$1" >"$HY2M_BACKUP_DIR/legacy-title"; printf 0; }
    ui_main_loop() { printf bad >"$HY2M_BACKUP_DIR/legacy-tui"; }
    main_menu
  '
  [[ ! -e $BACKUP_DIR/legacy-tui ]] && grep -Fq '只读兼容' "$BACKUP_DIR/legacy-title"
)
mkdir -p "$BACKUP_DIR"
check 'legacy-only inventory keeps its read-only route' legacy_entry
fallback_entry() (
  local mode=$1
  # shellcheck disable=SC2030,SC2031
  export HY2M_SOURCE_ONLY=1
  bash -c '
    source ./hy2-manager
    is_tty() { return 0; }
    tput() { case $1 in cols) printf 70 ;; lines) printf 14 ;; esac; }
    case $1 in plain) export HY2M_UI=plain ;; dumb) export TERM=dumb ;; nontty) is_tty() { return 1; } ;; small) tput() { printf 10; } ;; esac
    dashboard() { printf dashboard; }
    choose() { printf plain >"$HY2M_BACKUP_DIR/fallback-$1"; printf 0; }
    ui_main_loop() { return 79; }
    main_menu
  ' _ "$mode"
)
check 'explicit plain mode retains numbered menu' fallback_entry plain
check 'TERM=dumb retains numbered menu' fallback_entry dumb
check 'nonTTY retains numbered menu' fallback_entry nontty
check 'initial small terminal retains numbered menu' fallback_entry small

if ((failures)); then
  printf '\n%d TUI pagination/lifecycle test(s) failed. Frames: %s\n' "$failures" "$tmp" >&2
  exit 1
fi
printf '\nTUI pagination/lifecycle tests passed. Frames: %s\n' "$tmp"
