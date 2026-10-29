#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
# All services, permissions requiring accounts, and listeners are test doubles.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp
export TMPDIR="$PWD/.tmp" TMP="$PWD/.tmp" TEMP="$PWD/.tmp"
suite=$(mktemp -d "$TMPDIR/backup-repair.XXXXXX")
failures=0
setup_fixture() {
  root="$suite/$1"; mkdir -p "$root"
  export HY2M_SOURCE_ONLY=1 HY2M_TESTING=1
  export HY2M_APP_DIR="$root/app" HY2M_STATE_DIR="$root/state"
  export HY2M_HYSTERIA_DIR="$root/config" HY2M_EXPORT_DIR="$root/export"
  export HY2M_BACKUP_DIR="$root/backups" HY2M_SERVICE_DIR="$root/services"
  export HY2M_LETSENCRYPT_DIR="$root/acme"
  export HY2M_LEGACY_CONFIG="$root/no-legacy" HY2M_SYSCTL_FILE="$root/sysctl"
  source ./hy2-manager
  test_hook="$HY2M_LETSENCRYPT_DIR/renewal-hooks/deploy/hy2-manager-copy.sh"
  mkdir -p "$NODE_DIR" "$TLS_DIR" "$EXPORT_DIR" "$SERVICE_DIR" "${test_hook%/*}"
  write_env "$MANAGER_STATE" DOMAIN old.example.com NETWORK_MODE normal PUBLIC_IP 192.0.2.1 CERT_MODE http
  printf 'old certificate\n' >"$TLS_DIR/fullchain.pem"
  printf 'old private key\n' >"$TLS_DIR/privkey.pem"
  printf 'old renewal hook\n' >"$test_hook"
  printf 'unrelated unit\n' >"$SERVICE_DIR/website.service"
  for id in direct isp1; do
    port=443; kind=direct; [[ $id == direct ]] || { port=8443; kind=isp; }
    printf 'listen: :%s\n' "$port" >"$HYSTERIA_DIR/$id.yaml"
    printf 'hysteria2://test-secret@old.example.com:%s/?sni=old.example.com#%s\n' "$port" "$id" >"$EXPORT_DIR/hy2-$id.txt"
    save_node "$id" "$kind" "$id" "$port" "$port" "hy2m-$id.service" "$HYSTERIA_DIR/$id.yaml" "$EXPORT_DIR/hy2-$id.txt" normal
    printf '[Service]\nExecStart=test-fixture\n' >"$SERVICE_DIR/hy2m-$id.service"
  done
  printf 'old marker\n' >"$STATE_DIR/marker.txt"
  : >"$root/service-calls"
  confirm() { return 0; }
  systemctl() {
    printf '%s\n' "$*" >>"$root/service-calls"
    case $1 in
      is-active) [[ ${*: -1} == hy2m-direct.service ]] && { [[ $* == *--quiet* ]] || printf 'active\n'; return 0; }; [[ $* == *--quiet* ]] || printf 'inactive\n'; return 3 ;;
      is-enabled) [[ $2 == hy2m-direct.service ]] && { printf 'enabled\n'; return 0; }; printf 'disabled\n'; return 1 ;;
    esac
    return 0
  }
  start_checked() { printf 'checked %s %s\n' "$1" "$2" >>"$root/service-calls"; }
  ss() { printf 'UNCONN 0 0 0.0.0.0:443 *:*\n'; }
  install() {
    local args=()
    while (($#)); do case $1 in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
    command install "${args[@]}"
  }
}
backup_name() { local paths=("$BACKUP_DIR"/hy2m-*.tar.gz); printf '%s' "${paths[0]##*/}"; }
run_case() {
  local label=$1; shift
  if (setup_fixture "${label// /-}"; "$@"); then printf '[PASS] %s\n' "$label"
  else printf '[FAIL] %s\n' "$label" >&2; failures=$((failures+1)); fi
}
complete_roundtrip() {
  make_backup >/dev/null || return 1
  local name; name=$(backup_name)
  printf 'changed\n' >"$EXPORT_DIR/hy2-direct.txt"
  printf 'changed\n' >"$STATE_DIR/marker.txt"
  printf 'changed\n' >"$test_hook"
  restore_backup "$name" >"$root/restore.log" 2>&1 || return 1
  grep -Fq 'old.example.com' "$EXPORT_DIR/hy2-direct.txt" || return 1
  grep -Fxq 'old marker' "$STATE_DIR/marker.txt" || return 1
  grep -Fxq 'old renewal hook' "$test_hook" || return 1
  grep -Fxq 'unrelated unit' "$SERVICE_DIR/website.service" || return 1
  ! grep -Eq '^(restart|start|enable|checked) hy2m-isp1.service' "$root/service-calls"
}
unique_archives() {
  date() { printf '20260101-000000\n'; }
  make_backup >/dev/null || return 1
  make_backup >/dev/null || return 1
  local paths=("$BACKUP_DIR"/hy2m-*.tar.gz)
  [[ ${#paths[@]} == 2 ]]
}
backup_failure_aborts() {
  make_backup >/dev/null || return 1
  local name; name=$(backup_name)
  printf 'current\n' >"$STATE_DIR/marker.txt"
  make_backup() { return 37; }
  if (restore_backup "$name" >"$root/restore.log" 2>&1); then return 1; fi
  [[ $(<"$STATE_DIR/marker.txt") == current ]] || return 1
  ! grep -Eq '^(stop|disable|enable|restart|start|daemon-reload)' "$root/service-calls"
}
invalid_archive_aborts() {
  mkdir -p "$BACKUP_DIR"
  python3 - "$BACKUP_DIR/hy2m-evil.tar.gz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], 'w:gz') as out:
    member = tarfile.TarInfo('../outside-sentinel'); member.size = 5
    out.addfile(member, io.BytesIO(b'owned'))
PY
  if (restore_backup hy2m-evil.tar.gz >"$root/restore.log" 2>&1); then return 1; fi
  [[ $(<"$STATE_DIR/marker.txt") == 'old marker' && ! -s $root/service-calls ]]
}
failed_restart_rolls_back() {
  make_backup >/dev/null || return 1
  local name; name=$(backup_name)
  printf 'current\n' >"$STATE_DIR/marker.txt"
  printf 'current-uri\n' >"$EXPORT_DIR/hy2-direct.txt"
  printf 'current-hook\n' >"$test_hook"
  start_checked() { return 9; }
  # Restore implementation may use restart + a listener check rather than start_checked.
  eval "$(declare -f systemctl | sed '1s/systemctl/normal_systemctl/')"
  systemctl() { [[ $1 != restart ]] || return 9; normal_systemctl "$@"; }
  if (restore_backup "$name" >"$root/restore.log" 2>&1); then return 1; fi
  [[ $(<"$STATE_DIR/marker.txt") == current ]] || return 1
  [[ $(<"$EXPORT_DIR/hy2-direct.txt") == current-uri ]] || return 1
  [[ $(<"$test_hook") == current-hook ]] || return 1
  ! grep -Fq '已还原' "$root/restore.log"
}
run_case 'complete restore preserves exports hook and stopped node' complete_roundtrip
run_case 'same second backups never overwrite' unique_archives
run_case 'failed safety backup aborts before mutation' backup_failure_aborts
run_case 'unsafe archive is rejected before mutation' invalid_archive_aborts
run_case 'restart failure rolls files back and reports failure' failed_restart_rolls_back
printf 'Backup restore failures: %d; fixtures: %s\n' "$failures" "$suite"
((failures == 0))
