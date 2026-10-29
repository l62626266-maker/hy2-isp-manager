#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp
suite=$(mktemp -d "$PWD/.tmp/renewal.XXXXXX")
run_case() (
  mode=$1
  export HY2M_SOURCE_ONLY=1 HY2M_TESTING=1
  export HY2M_STATE_DIR="$suite/$mode/state" HY2M_HYSTERIA_DIR="$suite/$mode/hysteria" HY2M_LETSENCRYPT_DIR="$suite/$mode/acme"
  source ./hy2-manager
  mkdir -p "$NODE_DIR" "$TLS_DIR" "${RENEWAL_HOOK%/*}"
  write_env "$MANAGER_STATE" DOMAIN test.example.com CERT_MODE http PUBLIC_IP 192.0.2.1 NETWORK_MODE normal
  write_env "$NODE_DIR/direct.env" SERVICE hy2m-direct.service LISTEN_PORT 443
  write_env "$NODE_DIR/isp1.env" SERVICE hy2m-isp1.service LISTEN_PORT 8443
  printf old-cert >"$TLS_DIR/fullchain.pem"; printf old-key >"$TLS_DIR/privkey.pem"
  printf old-hook >"$RENEWAL_HOOK"
  export RENEWED_LINEAGE="$LETSENCRYPT_DIR/live/test.example.com"
  systemctl() { if [[ $2 == hy2m-direct.service ]]; then printf 'active\n'; else printf 'inactive\n'; return 3; fi; }
  _copy_certificate() {
    printf new-cert >"$TLS_DIR/fullchain.pem"
    [[ $mode != partial ]] || return 42
    printf new-key >"$TLS_DIR/privkey.pem"; printf new-hook >"$RENEWAL_HOOK"
  }
  restart_unit_checked() {
    printf '%s\n' "$*" >>"$STATE_DIR/restarts"
    if [[ $mode == restart && ! -f $STATE_DIR/failed ]]; then : >"$STATE_DIR/failed"; return 43; fi
  }
  rc=0
  (renew_certificate) >"$suite/$mode.log" 2>&1 || rc=$?
  if [[ $mode == success ]]; then
    [[ $rc == 0 && $(<"$TLS_DIR/fullchain.pem") == new-cert && $(<"$TLS_DIR/privkey.pem") == new-key && $(<"$RENEWAL_HOOK") == new-hook ]]
  else
    [[ $rc != 0 && $(<"$TLS_DIR/fullchain.pem") == old-cert && $(<"$TLS_DIR/privkey.pem") == old-key && $(<"$RENEWAL_HOOK") == old-hook ]]
  fi
  grep -q hy2m-direct "$STATE_DIR/restarts"
  if grep -q hy2m-isp1 "$STATE_DIR/restarts"; then return 1; fi
)
for mode in success partial restart; do
  run_case "$mode"
  printf '[PASS] manager renewal %s preserves stopped nodes and transaction consistency\n' "$mode"
done