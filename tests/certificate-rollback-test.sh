#!/usr/bin/env bash
# Standalone/first-install certificate_http regression tests; no domain wrapper.
# Only real Bash manager functions run; every privileged/network boundary is fake.
# Keep logs/fixtures under repository .tmp, including on failure.
# Run through .local-tests/run-repair-checks.sh when Python needs its local shim.
# shellcheck disable=SC1091,SC2034,SC2317
set -Eeuo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
mkdir -p "$repo/.tmp"
run_root=$(mktemp -d "$repo/.tmp/certificate-rollback.XXXXXX")
export TMPDIR="$run_root/tmp" TMP="$run_root/tmp" TEMP="$run_root/tmp"
export HOME="$run_root/home" XDG_CACHE_HOME="$run_root/cache" XDG_CONFIG_HOME="$run_root/config" XDG_DATA_HOME="$run_root/data"
export PYTHONDONTWRITEBYTECODE=1 PYTHONIOENCODING=utf-8
mkdir -p "$TMPDIR" "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$run_root/bin"

# Defense in depth: command/child-shell bypasses of function mocks still cannot
# reach real privileged tools or the network via PATH. Unexpected calls fail.
for tool in apt apt-get ufw certbot systemctl curl wget dig host nslookup openssl sudo; do
# Expanded in the child shell, not while constructing the command.
# shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'printf "BLOCKED external command: %s %s\n" "${0##*/}" "$*" >>"$MOCK_EVENTS"' 'exit 98' >"$run_root/bin/$tool"
done
chmod +x "$run_root/bin/"*
export PATH="$run_root/bin:$PATH"
# Use one unmodified source snapshot throughout a run, even if another agent is
# repairing the working tree concurrently. It also makes retained logs auditable.
cp -- "$repo/hy2-manager" "$run_root/hy2-manager.snapshot"

run_case() (
  local name=$1 root="$run_root/$1 fixture" assertions=0 rc=0
  local cert_mode=success firewall_mode=closed allow_mode=success delete_mode=success mv_mode=success
  local has_ledger=1 caller_traps=0 expected_rc=0 expected_open=0 expected_owned=0 expected_cert_calls=1
  local expected_allow=0 expected_delete=0 email=admin@example.com
  case $name in
    success|success-no-email|success-no-ledger|repeat-success|caller-success) expected_open=1; expected_owned=1; expected_allow=1 ;;
    issuance-fail|issuance-fail-no-ledger|caller-failure) cert_mode=fail; expected_rc=nonzero; expected_allow=1; expected_delete=1 ;;
    cert-int|caller-int) cert_mode=INT; expected_rc=130; expected_allow=1; expected_delete=1 ;;
    cert-term|caller-term) cert_mode=TERM; expected_rc=143; expected_allow=1; expected_delete=1 ;;
    existing-*-success) firewall_mode=${name#existing-}; firewall_mode=${firewall_mode%-success} ;;
    existing-*-fail) firewall_mode=${name#existing-}; firewall_mode=${firewall_mode%-fail}; cert_mode=fail; expected_rc=nonzero ;;
    no-ufw-success) firewall_mode=missing ;;
    no-ufw-fail) firewall_mode=missing; cert_mode=fail; expected_rc=nonzero ;;
    inactive-success) firewall_mode=inactive ;;
    inactive-fail) firewall_mode=inactive; cert_mode=fail; expected_rc=nonzero ;;
    allow-fail-clean) allow_mode=fail-clean; expected_rc=nonzero; expected_allow=1; expected_cert_calls=0 ;;
    allow-fail-applied) allow_mode=fail-applied; expected_rc=nonzero; expected_allow=1; expected_delete=1; expected_cert_calls=0 ;;
    ledger-mv-fail) mv_mode=fail; expected_rc=nonzero; expected_allow=1; expected_delete=1 ;;
    rollback-fail-cert) cert_mode=fail; delete_mode=fail; expected_rc=nonzero; expected_open=1; expected_owned=1; expected_allow=1; expected_delete=1 ;;
    rollback-fail-allow) allow_mode=fail-applied; delete_mode=fail; expected_rc=nonzero; expected_open=1; expected_owned=1; expected_allow=1; expected_delete=1; expected_cert_calls=0 ;;
    rollback-fail-mv) mv_mode=fail; delete_mode=fail; expected_rc=nonzero; expected_open=1; expected_owned=1; expected_allow=1; expected_delete=1 ;;
    rollback-fail-int) cert_mode=INT; delete_mode=fail; expected_rc=130; expected_open=1; expected_owned=1; expected_allow=1; expected_delete=1 ;;
    rollback-fail-term) cert_mode=TERM; delete_mode=fail; expected_rc=143; expected_open=1; expected_owned=1; expected_allow=1; expected_delete=1 ;;
    *) printf 'Unknown case: %s\n' "$name" >&2; return 2 ;;
  esac
  [[ $name != *no-ledger ]] || has_ledger=0
  [[ $name != caller-* ]] || caller_traps=1
  [[ $name != success-no-email ]] || email=''
  [[ $name != repeat-success ]] || expected_cert_calls=2

  export HY2M_SOURCE_ONLY=1 HY2M_TESTING=1
  export HY2M_APP_DIR="$root/app" HY2M_STATE_DIR="$root/state" HY2M_SERVICE_DIR="$root/systemd"
  export HY2M_EXPORT_DIR="$root/export" HY2M_HYSTERIA_DIR="$root/hysteria" HY2M_BACKUP_DIR="$root/backups"
  export HY2M_LETSENCRYPT_DIR="$root/letsencrypt" HY2M_BIN_DIR="$root/bin" HY2M_SBIN_DIR="$root/sbin"
  export HY2M_SYSCTL_FILE="$root/sysctl" HY2M_SWAP_FILE="$root/swap"
  export HY2M_LEGACY_CONFIG="$root/legacy/config" HY2M_LEGACY_MANAGER_CONFIG="$root/legacy/manager"
  export HY2M_LEGACY_URI_FILE="$root/legacy/uri" HY2M_LEGACY_TLS_CERT="$root/legacy/cert"
  export TMPDIR="$root/scratch" TMP="$root/scratch" TEMP="$root/scratch"
  export MOCK_EVENTS="$root/events"
  mkdir -p "$HY2M_STATE_DIR" "$TMPDIR" "$root/runtime"
  : >"$MOCK_EVENTS"
  source "$run_root/hy2-manager.snapshot"
  # An outer domain transaction must not be necessary for any of these cases.
  unset _domain_transaction _domain_http80_added
  printf 'closed\n' >"$root/runtime/http80"
  if ((has_ledger)); then
    printf '443/udp\n9443/udp\n' >"$FIREWALL_STATE"
    cp -p -- "$FIREWALL_STATE" "$root/before-ledger"
  fi
  printf 'Status: active\n\nTo                         Action      From\n--                         ------      ----\n' >"$root/before-rules"
  printf '443/udp                    ALLOW       Anywhere\n' >>"$root/before-rules"
  case $firewall_mode in
    allow) printf '80/tcp                     ALLOW       Anywhere\n80/tcp (v6)                ALLOW       Anywhere (v6)\n' >>"$root/before-rules" ;;
    restricted) printf '80/tcp                     ALLOW       192.0.2.7\n' >>"$root/before-rules" ;;
    deny) printf '80/tcp                     DENY        Anywhere\n' >>"$root/before-rules" ;;
    bare80) printf '80                         ALLOW       192.0.2.7\n' >>"$root/before-rules" ;;
    v6) printf '80/tcp (v6)                DENY        Anywhere (v6)\n' >>"$root/before-rules" ;;
    inactive) printf 'Status: inactive\n' >"$root/before-rules" ;;
  esac
  cp -p -- "$root/before-rules" "$root/runtime/rules"

  check() {
    local description=$1; shift
    if "$@"; then return 0; fi
    printf 'ASSERTION FAILED: %s\n' "$description" >&2
    assertions=$((assertions + 1))
    return 0
  }
  event_count() { local n; n=$(grep -Fxc -- "$1" "$MOCK_EVENTS") || true; printf '%s' "$n"; }
  forbidden() { printf 'BLOCKED external command: %s\n' "$*" >>"$MOCK_EVENTS"; return 98; }
  systemctl() { forbidden "systemctl $*"; }
  apt() { forbidden "apt $*"; }
  apt-get() { forbidden "apt-get $*"; }
  curl() { forbidden "curl $*"; }
  wget() { forbidden "wget $*"; }
  dig() { forbidden "dig $*"; }
  host() { forbidden "host $*"; }
  nslookup() { forbidden "nslookup $*"; }
  openssl() { forbidden "openssl $*"; }
  sudo() { forbidden "sudo $*"; }
  port_free() { printf 'port_free %s\n' "$*" >>"$MOCK_EVENTS"; [[ $* == '80 tcp' ]]; }
  # Deterministically simulate absence even on a machine with a real ufw binary.
  command() {
    if [[ $firewall_mode == missing && $* == '-v ufw' ]]; then return 1; fi
    builtin command "$@"
  }
  ufw() {
    printf 'ufw %s\n' "$*" >>"$MOCK_EVENTS"
    case "$*" in
      status*)
        [[ $firewall_mode != missing ]] || return 98
        builtin command cat "$root/runtime/rules"
        [[ $(<"$root/runtime/http80") != open ]] || printf '80/tcp                     ALLOW       Anywhere\n'
        return 0 ;;
      'allow 80/tcp')
        [[ $allow_mode != fail-clean ]] || return 31
        printf 'open\n' >"$root/runtime/http80"
        [[ $allow_mode != fail-applied ]] || return 31 ;;
      '--force delete allow 80/tcp')
        [[ $delete_mode != fail ]] || return 32
        printf 'closed\n' >"$root/runtime/http80" ;;
      *) forbidden "ufw $*" ;;
    esac
  }
  certbot() {
    printf 'certbot\n' >>"$MOCK_EVENTS"
    printf '%s\n' "$@" >"$root/certbot-args"
    case $cert_mode in
      fail) return 33 ;;
      INT|TERM)
        # Deliver the signal while inside certbot, not after issuance returns.
        kill -s "$cert_mode" "$BASHPID"
        return 0 ;;
    esac
    return 0
  }
  mv() {
    if [[ $mv_mode == fail && ${!#} == "$FIREWALL_STATE" && ! -e $root/runtime/mv-failed ]]; then
      : >"$root/runtime/mv-failed"
      printf 'injected ledger mv failure\n' >>"$MOCK_EVENTS"
      return 34
    fi
    builtin command mv "$@"
  }

  # The first-install caller uses an &&/if context. Do not accidentally make
  # errexit provide rollback that the callable function itself does not own.
  if (
    if ((caller_traps)); then
      trap 'printf "caller EXIT\n" >>"$root/caller-events"' EXIT
      trap 'printf "caller INT\n" >>"$root/caller-events"' INT
      trap 'printf "caller TERM\n" >>"$root/caller-events"' TERM
      trap 'printf "caller ERR\n" >>"$root/caller-events"' ERR
    else
      trap - EXIT INT TERM ERR
    fi
    trap -p EXIT INT TERM ERR >"$root/traps-before"
    if certificate_http test.example.com "$email"; then call_rc=0; else call_rc=$?; fi
    printf '%s\n' "$call_rc" >"$root/returned-status"
    if [[ $name == repeat-success && $call_rc == 0 ]]; then
      if certificate_http test.example.com "$email"; then call_rc=0; else call_rc=$?; fi
      printf '%s\n' "$call_rc" >"$root/returned-status"
    fi
    trap -p EXIT INT TERM ERR >"$root/traps-after"
    if ((caller_traps)); then
      # Check restored handlers are still live, not merely textually retained.
      kill -INT "$BASHPID"
      kill -TERM "$BASHPID"
    fi
    exit "$call_rc"
  ) >"$root/invocation.log" 2>&1; then rc=0; else rc=$?; fi
  printf 'certificate_http status: %s (expected %s)\n' "$rc" "$expected_rc"
  if [[ $expected_rc == nonzero ]]; then
    check 'failure must return nonzero' test "$rc" -ne 0
  else
    check "status must be $expected_rc (got $rc)" test "$rc" -eq "$expected_rc"
  fi
  check 'certificate_http returns control to its direct caller' test -f "$root/returned-status"
  check 'caller trap definitions survive the call' cmp -s "$root/traps-before" "$root/traps-after"
  if ((caller_traps)); then
    check 'caller EXIT trap still runs' grep -Fxq 'caller EXIT' "$root/caller-events"
    check 'caller INT trap still runs after return' grep -Fxq 'caller INT' "$root/caller-events"
    check 'caller TERM trap still runs after return' grep -Fxq 'caller TERM' "$root/caller-events"
  fi

  if ((expected_open)); then
    check 'owned HTTP rule remains open' test "$(<"$root/runtime/http80")" = open
  else
    check 'no owned HTTP rule remains open' test "$(<"$root/runtime/http80")" = closed
  fi
  check 'existing UFW rules are unchanged' cmp -s "$root/before-rules" "$root/runtime/rules"
  check 'correct number of certbot invocations' test "$(event_count certbot)" -eq "$expected_cert_calls"
  check 'correct number of new HTTP rules' test "$(event_count 'ufw allow 80/tcp')" -eq "$expected_allow"
  if [[ $name == allow-fail-clean ]]; then
    # UFW may fail before or after applying a change; a defensive delete is OK.
    check 'failed allow never repeats mutation' test "$(event_count 'ufw --force delete allow 80/tcp')" -le 1
  else
    check 'only owned HTTP rules are revoked when needed' test "$(event_count 'ufw --force delete allow 80/tcp')" -eq "$expected_delete"
  fi
  check 'no real privileged/network boundary is reached' test "$(grep -c '^BLOCKED' "$MOCK_EVENTS" || true)" -eq 0

  if ((expected_owned)); then
    check 'owned HTTP rule is durably recorded in ledger' grep -Fxq '80/tcp' "$FIREWALL_STATE"
    check 'HTTP ownership is not duplicated' test "$(grep -Fxc '80/tcp' "$FIREWALL_STATE" 2>/dev/null || true)" = 1
    if ((has_ledger)); then
      grep -Fxv '80/tcp' "$FIREWALL_STATE" >"$root/other-ledger" || true
      check 'unrelated ownership entries survive' cmp -s "$root/before-ledger" "$root/other-ledger"
    fi
  elif ((has_ledger)); then
    check 'original ownership ledger is restored byte-for-byte' cmp -s "$root/before-ledger" "$FIREWALL_STATE"
  else
    check 'failed first issuance leaves no invented ledger' test ! -s "$FIREWALL_STATE"
  fi
  if [[ $delete_mode == fail ]]; then
    check 'rollback failure reports a warning' grep -Eq '恢复失败|撤销失败|回滚失败|清理失败|人工|[Ww][Aa][Rr][Nn]|[Rr]ollback' "$root/invocation.log"
  fi

  if ((expected_cert_calls)); then
    check 'real certificate_http uses standalone HTTP challenge' grep -Fxq -- '--standalone' "$root/certbot-args"
    check 'certbot receives the requested domain' grep -Fxq 'test.example.com' "$root/certbot-args"
    check 'ACME state path stays inside fixture' grep -Fxq "$LETSENCRYPT_DIR" "$root/certbot-args"
    check 'ACME work path stays inside fixture' grep -Fxq "$LETSENCRYPT_DIR/work" "$root/certbot-args"
    check 'ACME log path stays inside fixture' grep -Fxq "$LETSENCRYPT_DIR/logs" "$root/certbot-args"
    if [[ -n $email ]]; then
      check 'certbot receives the requested email' grep -Fxq "$email" "$root/certbot-args"
    else
      check 'empty email uses explicit no-email registration' grep -Fxq -- '--register-unsafely-without-email' "$root/certbot-args"
    fi
  fi
  shopt -s nullglob dotglob
  local leftover
  local -a recovery_contents
  for leftover in "$STATE_DIR"/* "$TMPDIR"/*; do
    [[ $leftover == "$FIREWALL_STATE" ]] && continue
    # Failed revocation must retain recovery evidence. An explicitly reported,
    # nonempty state directory is intentional recovery, not a temporary leak.
    if [[ $delete_mode == fail && $leftover == "$STATE_DIR/"* && -d $leftover && ! -L $leftover ]] &&
      grep -Fq -- "$leftover" "$root/invocation.log"; then
      recovery_contents=("$leftover"/*)
      check 'retained recovery directory contains evidence' test "${#recovery_contents[@]}" -gt 0
      continue
    fi
    printf 'ASSERTION FAILED: temporary file leaked: %s\n' "$leftover" >&2
    assertions=$((assertions + 1))
  done
  printf '%d assertion failure(s)\n' "$assertions"
  ((assertions == 0))
)

cases=(
  success success-no-email success-no-ledger repeat-success
  issuance-fail issuance-fail-no-ledger cert-int cert-term
  caller-success caller-failure caller-int caller-term
  existing-allow-success existing-allow-fail existing-restricted-success existing-restricted-fail
  existing-deny-success existing-deny-fail existing-bare80-success existing-bare80-fail existing-v6-success existing-v6-fail
  no-ufw-success no-ufw-fail inactive-success inactive-fail
  allow-fail-clean allow-fail-applied ledger-mv-fail
  rollback-fail-cert rollback-fail-allow rollback-fail-mv rollback-fail-int rollback-fail-term
)
failures=0
for name in "${cases[@]}"; do
  if run_case "$name" >"$run_root/$name.log" 2>&1; then
    printf '[PASS] %s\n' "$name"
  else
    printf '[FAIL] %s (log: %s)\n' "$name" "$run_root/$name.log" >&2
    failures=$((failures + 1))
  fi
done
printf 'Certificate rollback artifacts: %s\n' "$run_root"
printf '%d/%d certificate rollback cases passed.\n' "$((${#cases[@]} - failures))" "${#cases[@]}"
((failures == 0))
