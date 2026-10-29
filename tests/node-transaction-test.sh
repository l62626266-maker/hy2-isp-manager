#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp
export TMPDIR="$PWD/.tmp"
suite=$(mktemp -d "$TMPDIR/node-transaction.XXXXXX")
fixture() {
  export HY2M_SOURCE_ONLY=1 HY2M_TESTING=1
  export HY2M_STATE_DIR="$suite/$1/state" HY2M_HYSTERIA_DIR="$suite/$1/config"
  export HY2M_SERVICE_DIR="$suite/$1/units" HY2M_EXPORT_DIR="$suite/$1/export"
  source ./hy2-manager
  mkdir -p "$NODE_DIR" "$HYSTERIA_DIR" "$SERVICE_DIR" "$EXPORT_DIR"
  printf inactive >"$STATE_DIR/runtime"; printf disabled >"$STATE_DIR/enabled"
  systemctl() {
    case $1 in
      is-active) cat "$STATE_DIR/runtime" ;;
      is-enabled) cat "$STATE_DIR/enabled" ;;
      stop) printf inactive >"$STATE_DIR/runtime" ;;
      start|restart) printf active >"$STATE_DIR/runtime" ;;
      enable) printf enabled >"$STATE_DIR/enabled" ;;
      disable) printf disabled >"$STATE_DIR/enabled" ;;
      daemon-reload) : ;;
      *) return 1 ;;
    esac
  }
  start_checked() { systemctl enable "$1" && systemctl restart "$1"; }
  restart_unit_checked() { systemctl restart "$1"; }
  open_firewall() { printf '%s/udp\n' "$1" >"$FIREWALL_STATE"; }
  close_firewall() { rm -f "$FIREWALL_STATE"; }
  load_manager() { DOMAIN=node.example.com; NETWORK_MODE=normal; }
  current_boot_id() { printf '11111111-1111-1111-1111-111111111111'; }
  confirm() { :; }
  install() { command install -m 600 "${@: -2}"; }
  is_restricted_container() { return 0; }
  ask_valid_port() { printf 8443; }
  ask_valid_name() { printf NewName; }
  node_port_free() { :; }
  read_socks() { :; }
  verify_socks() { SOCKS_EXIT_IP=192.0.2.2; SOCKS_UDP=supported; }
  render_isp_config() { printf 'new config\n'; }
}
existing() {
  local id=$1
  printf 'old config\n  password: "%048d"\n' 0 >"$HYSTERIA_DIR/$id.yaml"
  printf 'hysteria2://test@node.example.com:8443/#OldName\n' >"$EXPORT_DIR/hy2-$id.txt"
  printf old-unit >"$SERVICE_DIR/hy2m-$id.service"
  save_node "$id" isp OldName 8443 8443 "hy2m-$id.service" "$HYSTERIA_DIR/$id.yaml" "$EXPORT_DIR/hy2-$id.txt" normal
  cp "$NODE_DIR/$id.env" "$STATE_DIR/before.env"
}
create_failure() {
  fixture create
  save_node() { return 51; }
  if create_direct; then return 1; fi
  [[ ! -e $HYSTERIA_DIR/direct.yaml && ! -e $EXPORT_DIR/hy2-direct.txt && ! -e $SERVICE_DIR/hy2m-direct.service && ! -e $NODE_DIR/direct.env && ! -e $FIREWALL_STATE ]]
  [[ $(<"$STATE_DIR/runtime") == inactive && $(<"$STATE_DIR/enabled") == disabled ]]
}
replace_stopped() {
  fixture replace; existing isp1
  replace_isp isp1
  [[ $(<"$STATE_DIR/runtime") == inactive && $(<"$STATE_DIR/enabled") == disabled ]]
  grep -q '^new config' "$HYSTERIA_DIR/isp1.yaml"
}
rename_failure() {
  fixture rename; existing isp1
  eval "$(declare -f install_owned | sed '1s/install_owned/real_install_owned/')"
  install_owned() { [[ $4 != "$EXPORT_DIR/hy2-isp1.txt" ]] || return 52; real_install_owned "$@"; }
  # Also intercept the old direct install implementation, so RED tests the partial write.
  install() { [[ ${*: -1} != "$EXPORT_DIR/hy2-isp1.txt" ]] || return 52; command install -m 600 "${@: -2}"; }
  if rename_node isp1; then return 1; fi
  cmp -s "$STATE_DIR/before.env" "$NODE_DIR/isp1.env"
  grep -q '#OldName' "$EXPORT_DIR/hy2-isp1.txt"
}
stop_intent() {
  fixture stop; existing isp1
  printf active >"$STATE_DIR/runtime"
  stop_node isp1
  grep -Fxq DESIRED_STATE=stopped "$NODE_DIR/isp1.env"
  grep -Fxq STOP_BOOT_ID=11111111-1111-1111-1111-111111111111 "$NODE_DIR/isp1.env"
  start_node isp1
  grep -Fxq DESIRED_STATE=running "$NODE_DIR/isp1.env"
}
replace_failure() {
  fixture replace-fail; existing isp1
  printf active >"$STATE_DIR/runtime"
  cp "$HYSTERIA_DIR/isp1.yaml" "$STATE_DIR/before.yaml"
  save_node() { return 53; }
  if replace_isp isp1; then return 1; fi
  cmp -s "$STATE_DIR/before.env" "$NODE_DIR/isp1.env"
  cmp -s "$STATE_DIR/before.yaml" "$HYSTERIA_DIR/isp1.yaml"
  [[ $(<"$STATE_DIR/runtime") == active ]]
}
snapshot_failure() {
  fixture snapshot; existing isp1
  transaction_snapshot_file() { return 54; }
  if stop_node isp1; then return 1; fi
  cmp -s "$STATE_DIR/before.env" "$NODE_DIR/isp1.env"
  [[ $(<"$STATE_DIR/runtime") == inactive ]]
}
creation_orphan() {
  fixture orphan
  printf unrelated >"$HYSTERIA_DIR/direct.yaml"
  if create_direct; then return 1; fi
  [[ $(<"$HYSTERIA_DIR/direct.yaml") == unrelated && ! -e $NODE_DIR/direct.env ]]
}
create_signal() {
  fixture signal
  save_node() { kill -TERM "$BASHPID"; }
  local rc=0
  create_direct || rc=$?
  [[ $rc == 143 && ! -e $HYSTERIA_DIR/direct.yaml && ! -e $SERVICE_DIR/hy2m-direct.service ]]
  [[ $(<"$STATE_DIR/runtime") == inactive ]]
}
power_write_failure() {
  fixture power-fail; existing isp1
  printf active >"$STATE_DIR/runtime"
  save_node() { return 55; }
  if stop_node isp1; then return 1; fi
  [[ $(<"$STATE_DIR/runtime") == active ]]
  cmp -s "$STATE_DIR/before.env" "$NODE_DIR/isp1.env"
}
rollback_failure() {
  fixture recovery; existing isp1
  save_node() { return 56; }
  transaction_restore_file() { return 57; }
  if rename_node isp1; then return 1; fi
  local materials=("$STATE_DIR"/.node-transaction.*/node.state)
  [[ -f ${materials[0]} ]]
}
port_stopped() {
  fixture port-stopped; existing isp1
  printf 'listen: :8443\n' >"$HYSTERIA_DIR/isp1.yaml"
  ask_valid_port() { printf 9443; }
  change_node_port isp1
  [[ $(<"$STATE_DIR/runtime") == inactive && $(<"$STATE_DIR/enabled") == disabled ]]
  grep -Fxq LISTEN_PORT=9443 "$NODE_DIR/isp1.env"
}
failed=0
for test in create_failure replace_stopped rename_failure stop_intent replace_failure snapshot_failure creation_orphan create_signal power_write_failure rollback_failure port_stopped; do
  set +e
  (set -Eeuo pipefail; "$test") >"$suite/$test.log" 2>&1
  rc=$?; set -e
  if ((rc == 0)); then printf '[PASS] %s\n' "$test"
  else printf '[FAIL] %s (%s)\n' "$test" "$suite/$test.log"; failed=$((failed+1)); fi
done
((failed == 0))
