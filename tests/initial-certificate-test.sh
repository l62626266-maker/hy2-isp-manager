#!/usr/bin/env bash
# Isolated initial-install certificate regressions. All external effects are mocked.
# Keep each run's fixtures/logs inside this repository for failure inspection.
# shellcheck disable=SC1090,SC1091,SC2034,SC2317
set -Eeuo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
mkdir -p "$repo/.tmp"
run_root=$(mktemp -d "$repo/.tmp/initial-cert.XXXXXX")
export TMPDIR="$run_root/tmp" TMP="$run_root/tmp" TEMP="$run_root/tmp"
export HOME="$run_root/home" XDG_CACHE_HOME="$run_root/cache" XDG_CONFIG_HOME="$run_root/config" XDG_DATA_HOME="$run_root/data"
export PYTHONDONTWRITEBYTECODE=1 PYTHONIOENCODING=utf-8
mkdir -p "$TMPDIR" "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
failures=0

run_case() (
  name=$1
  root="$run_root/$name fixture"
  export HY2M_SOURCE_ONLY=1 HY2M_TESTING=1
  export HY2M_APP_DIR="$root/app" HY2M_STATE_DIR="$root/state" HY2M_SERVICE_DIR="$root/systemd"
  export HY2M_EXPORT_DIR="$root/export" HY2M_HYSTERIA_DIR="$root/hysteria" HY2M_BACKUP_DIR="$root/backups"
  export HY2M_LETSENCRYPT_DIR="$root/letsencrypt" HY2M_BIN_DIR="$root/bin" HY2M_SBIN_DIR="$root/sbin"
  export HY2M_SYSCTL_FILE="$root/sysctl" HY2M_SWAP_FILE="$root/swap"
  export HY2M_LEGACY_CONFIG="$root/legacy/config" HY2M_LEGACY_MANAGER_CONFIG="$root/legacy/manager"
  export HY2M_LEGACY_URI_FILE="$root/legacy/uri" HY2M_LEGACY_TLS_CERT="$root/legacy/cert"
  source ./hy2-manager
  mkdir -p "$NODE_DIR" "$TLS_DIR" "${RENEWAL_HOOK%/*}" "$SERVICE_DIR" "$EXPORT_DIR" "$BACKUP_DIR" "$root/before" "$root/runtime"
  events="$root/events"; : >"$events"
  # `initial_install` declares a local `cert_mode`; bash dynamic scoping would
  # shadow ours inside the mocked choose(), so keep a distinct name.
  want_cert_mode=http; original=1; failure=""; signal_code=0; send_signal=0
  timer_enabled=disabled; timer_active=inactive
  case $name in cf-*) want_cert_mode=cloudflare ;; esac
  case $name in *-absent) original=0 ;; esac
  case $name in
    *-return-int) signal_code=130 ;;
    *-return-term) signal_code=143 ;;
    *-signal-int) signal_code=130; send_signal=1 ;;
    *-signal-term) signal_code=143; send_signal=1 ;;
    http-fail-*|cf-fail-*) failure=issuance ;;
    copy-cert-*) failure=cert ;;
    copy-key-*) failure=key ;;
    copy-hook-*) failure=hook ;;
    manager-*) failure=manager ;;
    timer-partial-*) failure=timer ;;
    timer-enabled-inactive) timer_enabled=enabled; failure=manager ;;
    timer-disabled-active) timer_active=active; failure=manager ;;
    timer-enabled-active) timer_enabled=enabled; timer_active=active; failure=manager ;;
    node-cancel) failure=node-cancel ;;
    node-failure) failure=node-failure ;;
  esac
  printf '%s\n' "$timer_enabled" >"$root/runtime/timer.enabled"
  printf '%s\n' "$timer_active" >"$root/runtime/timer.active"
  printf 'closed\n' >"$root/runtime/http80"
  if ((original)); then
    printf 'old certificate\n' >"$TLS_DIR/fullchain.pem"
    printf 'old key\n' >"$TLS_DIR/privkey.pem"
    printf 'old credentials\n' >"$CF_CREDENTIALS"
    printf 'old hook\n' >"$RENEWAL_HOOK"
    printf '443/udp\n' >"$FIREWALL_STATE"
    cp -p "$TLS_DIR/fullchain.pem" "$root/before/cert"
    cp -p "$TLS_DIR/privkey.pem" "$root/before/key"
    cp -p "$CF_CREDENTIALS" "$root/before/cf"
    cp -p "$RENEWAL_HOOK" "$root/before/hook"
    cp -p "$FIREWALL_STATE" "$root/before/firewall"
  fi

  # Preserve real certificate/transaction helpers. Replace every system/network
  # boundary before invoking initial_install, never install packages or services.
  def=$(declare -f write_env); eval "${def/write_env/real_write_env}"
  bad() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; return 1; }
  os_check() { :; }
  require_systemd() { :; }
  install_packages() { printf 'install_packages\n' >>"$events"; }
  ensure_layout() { :; }
  install_hysteria() { printf 'install_hysteria\n' >>"$events"; }
  make_backup() { printf 'make_backup\n' >>"$events"; }
  configure_network() { printf 'configure_network\n' >>"$events"; }
  get_public_ipv4() { printf '192.0.2.1'; }
  check_dns() { return 0; }
  certificate_valid() { return 1; }
  port_free() { return 0; }
  ask_valid_domain() { printf 'new.example.com'; }
  ask() { printf ''; }
  ask_secret() { printf 'dummy-test-token'; }
  choose() {
    case $1 in
      '网络类型') printf normal ;;
      '证书') printf '%s' "$want_cert_mode" ;;
      *) bad "unexpected choice: $1" ;;
    esac
  }
  # Decline retries and optional ISP setup. Signal results must never ask again.
  confirm() { printf 'confirm %s\n' "$*" >>"$events"; return 1; }
  curl() { bad 'unexpected network: curl'; }
  dig() { bad 'unexpected network: dig'; }
  apt-get() { printf 'apt-get %s\n' "$*" >>"$events"; return 0; }
  openssl() { if [[ " $* " == *" -checkhost "* ]]; then printf 'Hostname %s does match certificate\n' "${*: -1}"; else printf 'mock-public-key\n'; fi; }
  certbot() {
    printf 'certbot %s\n' "$*" >>"$events"
    if ((signal_code)); then
      if ((send_signal)); then
        if ((signal_code == 130)); then kill -INT "$BASHPID"; else kill -TERM "$BASHPID"; fi
      fi
      return "$signal_code"
    fi
    [[ $failure != issuance ]] || return 61
    mkdir -p "$LETSENCRYPT_DIR/live/new.example.com"
    printf 'issued certificate\n' >"$LETSENCRYPT_DIR/live/new.example.com/fullchain.pem"
    printf 'issued key\n' >"$LETSENCRYPT_DIR/live/new.example.com/privkey.pem"
  }
  ufw() {
    printf 'ufw %s\n' "$*" >>"$events"
    case "$*" in
      status*)
        printf 'Status: active\n'
        [[ $(<"$root/runtime/http80") != open ]] || printf '80/tcp ALLOW Anywhere\n'
        return 0 ;;
      'allow 80/tcp') printf 'open\n' >"$root/runtime/http80" ;;
      '--force delete allow 80/tcp') printf 'closed\n' >"$root/runtime/http80" ;;
      *) bad "unexpected UFW action: $*" ;;
    esac
  }
  systemctl() {
    printf 'systemctl %s\n' "$*" >>"$events"
    [[ $* == *certbot.timer* ]] || { bad "unexpected unit action: $*"; return 99; }
    case $1 in
      is-enabled)
        printf '%s\n' "$(<"$root/runtime/timer.enabled")"
        [[ $(<"$root/runtime/timer.enabled") == enabled ]]; return $? ;;
      is-active)
        [[ $* == *--quiet* ]] || printf '%s\n' "$(<"$root/runtime/timer.active")"
        [[ $(<"$root/runtime/timer.active") == active ]]; return $? ;;
      enable)
        printf 'enabled\n' >"$root/runtime/timer.enabled"
        [[ $* != *--now* ]] || printf 'active\n' >"$root/runtime/timer.active"
        if [[ $failure == timer && ! -e $root/timer.failed ]]; then
          : >"$root/timer.failed"
          # Model partial success: enable/start happened before nonzero status.
          printf 'active\n' >"$root/runtime/timer.active"
          return 62
        fi ;;
      disable)
        printf 'disabled\n' >"$root/runtime/timer.enabled"
        [[ $* != *--now* ]] || printf 'inactive\n' >"$root/runtime/timer.active" ;;
      start|restart) printf 'active\n' >"$root/runtime/timer.active" ;;
      stop) printf 'inactive\n' >"$root/runtime/timer.active" ;;
      *) bad "unexpected timer action: $*" ;;
    esac
    return 0
  }
  # Publication now occurs at the atomic rename, not install into its staging file.
  mv() {
    local target=${!#} trip=0
    case $failure in
      cert) [[ $target != "$TLS_DIR/fullchain.pem" ]] || trip=1 ;;
      key) [[ $target != "$TLS_DIR/privkey.pem" ]] || trip=1 ;;
      hook) [[ $target != "$RENEWAL_HOOK" ]] || trip=1 ;;
    esac
    if ((trip)) && [[ ! -e $root/copy.failed ]]; then
      : >"$root/copy.failed"
      printf 'copy-failed %s\n' "$target" >>"$events"
      return 63
    fi
    command mv "$@"
  }
  write_env() {
    if [[ $1 == "$MANAGER_STATE" ]]; then
      printf 'manager-write\n' >>"$events"
      if [[ $failure == manager && ! -e $root/manager.failed ]]; then
        : >"$root/manager.failed"
        printf 'PARTIAL_MANAGER=1\n' >"$MANAGER_STATE"
        return 64
      fi
    fi
    real_write_env "$@"
  }
  create_direct() {
    printf 'node-create\n' >>"$events"
    [[ -r $MANAGER_STATE ]] || { bad 'node created before manager state'; return 96; }
    grep -Fxq 'DOMAIN=new.example.com' "$MANAGER_STATE" || { bad 'node created before committed domain'; return 96; }
    cmp "$TLS_DIR/fullchain.pem" "$LETSENCRYPT_DIR/live/new.example.com/fullchain.pem" || { bad 'node created before certificate'; return 96; }
    cmp "$TLS_DIR/privkey.pem" "$LETSENCRYPT_DIR/live/new.example.com/privkey.pem" || { bad 'node created before private key'; return 96; }
    bash -n "$RENEWAL_HOOK" || { bad 'node created before valid renewal hook'; return 96; }
    [[ $(<"$root/runtime/timer.enabled") == enabled && $(<"$root/runtime/timer.active") == active ]] || { bad 'node created before timer handoff'; return 96; }
    if [[ $want_cert_mode == http ]]; then
      if [[ $(<"$root/runtime/http80") != open ]] || ! grep -Fxq 80/tcp "$FIREWALL_STATE"; then bad 'node created before HTTP ownership handoff'; return 96; fi
    else
      grep -Fxq 'dns_cloudflare_api_token = dummy-test-token' "$CF_CREDENTIALS" || { bad 'node created before Cloudflare handoff'; return 96; }
    fi
    case $failure in node-cancel) return 20 ;; node-failure) return 79 ;; esac
    printf 'created\n' >"$root/node.created"
  }
  create_isp() { bad 'unexpected ISP creation'; }

  # Deliberately disable errexit via the caller: all transaction checks must be
  # explicit, including snapshot/copy/manager failures and signal return codes.
  if (initial_install); then rc=0; else rc=$?; fi
  [[ $(grep -c '^certbot ' "$events") == 1 ]] || { bad 'issuance repeated or skipped'; return 1; }
  if ((signal_code)); then
    [[ $rc == "$signal_code" ]] || { bad "expected signal status $signal_code, got $rc"; return 1; }
    ! grep -q '^confirm ' "$events" || { bad 'signal prompted retry instead of returning'; return 1; }
  fi

  case $name in
    http-success|cf-success|node-cancel|node-failure)
      case $name in
        node-cancel) [[ $rc == 20 ]] || { bad "node cancellation status lost: $rc"; return 1; } ;;
        node-failure) [[ $rc == 79 ]] || { bad "node failure status lost: $rc"; return 1; } ;;
        *) [[ $rc == 0 && -e $root/node.created ]] || { bad 'successful install did not create a node'; return 1; } ;;
      esac
      grep -Fxq 'DOMAIN=new.example.com' "$MANAGER_STATE" || return 1
      cmp "$TLS_DIR/fullchain.pem" "$LETSENCRYPT_DIR/live/new.example.com/fullchain.pem" || return 1
      cmp "$TLS_DIR/privkey.pem" "$LETSENCRYPT_DIR/live/new.example.com/privkey.pem" || return 1
      [[ ! -e $INSTALL_SESSION ]] || { bad 'committed install retained old checkpoint'; return 1; }
      [[ $(<"$root/runtime/timer.enabled") == enabled && $(<"$root/runtime/timer.active") == active ]] || return 1
      if [[ $want_cert_mode == http ]]; then
        [[ $(<"$root/runtime/http80") == open ]] && grep -Fxq 80/tcp "$FIREWALL_STATE" || return 1
      else
        grep -Fxq 'dns_cloudflare_api_token = dummy-test-token' "$CF_CREDENTIALS" || return 1
        [[ $(<"$root/runtime/http80") == closed ]] || return 1
      fi
      ! grep -q '^ufw --force delete allow 80/tcp' "$events" || { bad 'success handoff rolled HTTP rule back'; return 1; }
      return 0 ;;
  esac

  [[ ! -e $MANAGER_STATE ]] || { bad 'failed certificate transaction left manager state'; return 1; }
  if [[ -e $root/node.created ]] || grep -q '^node-create' "$events"; then bad 'node creation ran after certificate failure'; return 1; fi
  if [[ $failure != issuance ]] && ((signal_code == 0)); then
    [[ $rc != 0 ]] || { bad 'deployment failure reported success'; return 1; }
  fi
  [[ -r $INSTALL_SESSION ]] || { bad 'failed install lost resumable checkpoint'; return 1; }
  ! grep -q 'dummy-test-token' "$INSTALL_SESSION" || { bad 'checkpoint contains secret'; return 1; }
  if ((original)); then
    cmp "$TLS_DIR/fullchain.pem" "$root/before/cert" || { bad 'old certificate not restored'; return 1; }
    cmp "$TLS_DIR/privkey.pem" "$root/before/key" || { bad 'old private key not restored'; return 1; }
    cmp "$CF_CREDENTIALS" "$root/before/cf" || { bad 'old Cloudflare credentials not restored'; return 1; }
    cmp "$RENEWAL_HOOK" "$root/before/hook" || { bad 'old hook not restored'; return 1; }
    cmp "$FIREWALL_STATE" "$root/before/firewall" || { bad 'old firewall ownership not restored'; return 1; }
  else
    [[ ! -e $TLS_DIR/fullchain.pem && ! -e $TLS_DIR/privkey.pem && ! -e $CF_CREDENTIALS && ! -e $RENEWAL_HOOK && ! -e $FIREWALL_STATE ]] || { bad 'new certificate/credential/hook/ledger survived rollback'; return 1; }
  fi
  [[ $(<"$root/runtime/http80") == closed ]] || { bad 'failed transaction left HTTP port open'; return 1; }
  [[ $(<"$root/runtime/timer.enabled") == "$timer_enabled" ]] || { bad 'timer enablement not restored'; return 1; }
  [[ $(<"$root/runtime/timer.active") == "$timer_active" ]] || { bad 'timer active state not restored'; return 1; }
)

cases=(
  http-success cf-success
  http-return-int http-return-term cf-return-int cf-return-term
  http-signal-int http-signal-term cf-signal-int cf-signal-term
  http-fail-old http-fail-absent cf-fail-old cf-fail-absent
  copy-cert-old copy-cert-absent copy-key-old copy-key-absent copy-hook-old copy-hook-absent
  manager-old manager-absent timer-partial-old timer-partial-absent
  timer-enabled-inactive timer-disabled-active timer-enabled-active node-cancel node-failure
)
for name in "${cases[@]}"; do
  if (set -Eeuo pipefail; run_case "$name") >"$run_root/$name.log" 2>&1; then
    printf '[PASS] %s\n' "$name"
  else
    printf '[FAIL] %s (log: %s)\n' "$name" "$run_root/$name.log" >&2
    failures=$((failures+1))
  fi
done
printf 'Initial certificate test artifacts: %s\n' "$run_root"
((failures == 0)) || { printf '%d initial certificate test(s) failed.\n' "$failures" >&2; exit 1; }
printf 'Initial certificate tests passed (%d cases).\n' "${#cases[@]}"
