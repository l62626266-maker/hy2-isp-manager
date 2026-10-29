#!/usr/bin/env bash
# Isolated domain transaction regression tests. Retain each run's fixtures/logs.
# shellcheck disable=SC1090,SC1091,SC2034,SC2317
set -Eeuo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
mkdir -p "$repo/.tmp"
run_root=$(mktemp -d "$repo/.tmp/domain-tests.XXXXXX")
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
  mkdir -p "$NODE_DIR" "$SERVICE_DIR" "$EXPORT_DIR" "$TLS_DIR" "$HY2M_LETSENCRYPT_DIR/renewal-hooks/deploy" "$root/runtime"
  hook="$HY2M_LETSENCRYPT_DIR/renewal-hooks/deploy/hy2-manager-copy.sh"
  events="$root/events"; : >"$events"
  fail_at=""; mock_cert_mode=http; active=active; mock_enabled=disabled; mock_http80=closed; reuse=0
  case $name in
    issuance|copy|link|state|restart|rollback|term|int|cert-term|cert-int|copy-cert|copy-hook|firewall-rollback|snapshot-node|snapshot-manager|snapshot-link) fail_at=$name ;;
    nested-link|extensionless-link) fail_at=state ;;
    cloudflare|absent) fail_at=copy; mock_cert_mode=cloudflare ;;
    absent-late) fail_at="link"; mock_cert_mode=cloudflare ;;
    stopped-failure) fail_at=copy; active=inactive ;;
    existing-http) fail_at=copy; mock_http80=open ;;
    enabled) mock_enabled=enabled ;;
  esac
  [[ $name != stopped ]] || active=inactive
  write_env "$MANAGER_STATE" DOMAIN old.example.com PUBLIC_IP 192.0.2.1 NETWORK_MODE normal CERT_MODE http
  for id in direct isp1; do
    printf 'listen: :443\n' >"$HYSTERIA_DIR/$id.yaml"
    printf '[Service]\n' >"$SERVICE_DIR/hy2m-$id.service"
    printf '%s\n' "$active" >"$root/runtime/hy2m-$id.service.active"
    printf '%s\n' "$mock_enabled" >"$root/runtime/hy2m-$id.service.enabled"
    printf 'hysteria2://pass%%40word@old.example.com:443/?sni=old.example.com&tag=old.example.com#Keep%%20Name\n' >"$EXPORT_DIR/custom $id.txt"
    save_node "$id" "$id" "$id" 443 443 "hy2m-$id.service" "$HYSTERIA_DIR/$id.yaml" "$EXPORT_DIR/custom $id.txt" normal
  done
  printf 'old certificate\n' >"$TLS_DIR/fullchain.pem"; printf 'old key\n' >"$TLS_DIR/privkey.pem"
  printf 'old credentials\n' >"$CF_CREDENTIALS"; printf 'old hook\n' >"$hook"
  printf '443/udp\n' >"$FIREWALL_STATE"
  printf '%s\n' "$mock_http80" >"$root/http80"
  mkdir -p "$root/before"
  cp -p "$MANAGER_STATE" "$root/before/manager"
  cp -p "$TLS_DIR/fullchain.pem" "$root/before/cert"
  cp -p "$TLS_DIR/privkey.pem" "$root/before/key"
  cp -p "$EXPORT_DIR/custom direct.txt" "$root/before/direct"
  cp -p "$EXPORT_DIR/custom isp1.txt" "$root/before/isp1"
  cp -p "$CF_CREDENTIALS" "$root/before/cf"; cp -p "$hook" "$root/before/hook"
  cp -p "$FIREWALL_STATE" "$root/before/firewall"

  # Save real helpers, then replace every external/network boundary before use.
  def=$(declare -f certificate_http); eval "${def/certificate_http/real_certificate_http}"
  def=$(declare -f certificate_cloudflare); eval "${def/certificate_cloudflare/real_certificate_cloudflare}"
  def=$(declare -f copy_certificate); eval "${def/copy_certificate/real_copy_certificate}"
  def=$(declare -f certificate_valid); eval "${def/certificate_valid/real_certificate_valid}"
  def=$(declare -f write_env); eval "${def/write_env/real_write_env}"
  ask_valid_domain() { printf 'new.example.com'; }
  ask() { printf ''; }
  ask_secret() { printf 'dummy-test-token'; }
  choose() { printf '%s' "$mock_cert_mode"; }
  confirm() { return 0; }
  get_public_ipv4() { printf '192.0.2.1'; }
  check_dns() { return 0; }
  port_free() { return 0; }
  curl() { printf 'unexpected network command\n' >>"$events"; return 98; }
  dig() { printf 'unexpected network command\n' >>"$events"; return 98; }
  apt-get() { printf 'apt-get %s\n' "$*" >>"$events"; [[ $fail_at != plugin ]]; }
  openssl() { printf 'mock-public-key\n'; }
  ss() { printf 'UNCONN 0 0 0.0.0.0:443 0.0.0.0:*\n'; }
  sleep() { :; }
  journalctl() { :; }
  certbot() {
    printf 'certbot %s\n' "$*" >>"$events"
    [[ $fail_at != issuance ]] || return 21
    case $fail_at in cert-term) kill -TERM "$BASHPID" ;; cert-int) kill -INT "$BASHPID" ;; esac
    mkdir -p "$HY2M_LETSENCRYPT_DIR/live/new.example.com"
    printf 'issued certificate\n' >"$HY2M_LETSENCRYPT_DIR/live/new.example.com/fullchain.pem"
    printf 'issued key\n' >"$HY2M_LETSENCRYPT_DIR/live/new.example.com/privkey.pem"
    return 0
  }
  ufw() {
    printf 'ufw %s\n' "$*" >>"$events"
    case "$*" in
      status*) printf 'Status: active\n'; [[ $(<"$root/http80") != open ]] || printf '80/tcp ALLOW Anywhere\n'; return 0 ;;
      'allow 80/tcp') printf 'open\n' >"$root/http80" ;;
      '--force delete allow 80/tcp') [[ $fail_at != firewall-rollback ]] || return 22; printf 'closed\n' >"$root/http80" ;;
      *) return 99 ;;
    esac
  }
  systemctl() {
    printf 'systemctl %s\n' "$*" >>"$events"
    local verb=$1 unit=${!#}
    case $verb in
      is-active)
        [[ -r $root/runtime/$unit.active ]] || return 4
        [[ $* == *--quiet* ]] || printf '%s\n' "$(<"$root/runtime/$unit.active")"
        [[ $(<"$root/runtime/$unit.active") == active ]] ;;
      is-enabled)
        [[ -r $root/runtime/$unit.enabled ]] || return 4
        printf '%s\n' "$(<"$root/runtime/$unit.enabled")"
        [[ $(<"$root/runtime/$unit.enabled") == enabled ]] ;;
      restart|start|try-restart)
        if [[ $fail_at == restart || $fail_at == rollback ]] && [[ ! -e $root/restart.failed ]]; then
          : >"$root/restart.failed"; printf 'inactive\n' >"$root/runtime/$unit.active"; return 23
        fi
        [[ -r $root/runtime/$unit.active ]] || return 99
        printf 'active\n' >"$root/runtime/$unit.active" ;;
      stop) printf 'inactive\n' >"$root/runtime/$unit.active" ;;
      enable) printf 'enabled\n' >"$root/runtime/$unit.enabled" ;;
      disable) printf 'disabled\n' >"$root/runtime/$unit.enabled" ;;
      daemon-reload) : ;;
      *) return 99 ;;
    esac
  }
  install_owned() {
    local mode=$1 group=$2 src=$3 dst=$4
    if [[ $fail_at == copy-cert && $dst == "$TLS_DIR/privkey.pem" && ! -e $root/copy.failed ]]; then : >"$root/copy.failed"; return 27; fi
    if [[ $fail_at == copy-hook && $dst == "$hook" && ! -e $root/copy.failed ]]; then : >"$root/copy.failed"; return 27; fi
    if [[ $fail_at == link && $dst == "$EXPORT_DIR/custom isp1.txt" && ! -e $root/link.failed ]]; then : >"$root/link.failed"; return 24; fi
    if [[ $fail_at == state && $dst == "$MANAGER_STATE" && ! -e $root/state.failed ]]; then : >"$root/state.failed"; return 25; fi
    if [[ $fail_at == rollback && -e $root/restart.failed && $dst == "$MANAGER_STATE" ]]; then return 26; fi
    command install -m "$mode" "$src" "$dst"
  }
  cp() {
    if [[ $fail_at == rollback && -e $root/restart.failed && ${!#} == "$MANAGER_STATE" ]]; then return 26; fi
    case "$fail_at:${!#}" in
      snapshot-node:*/node.direct.env.state|snapshot-manager:*/manager.env.state|snapshot-link:*/link.1.state|snapshot-link:*/link.1.path) return 28 ;;
    esac
    command cp "$@"
  }
  write_env() {
    if [[ $fail_at == state && $1 == "$MANAGER_STATE" && ! -e $root/state.failed ]]; then : >"$root/state.failed"; return 25; fi
    real_write_env "$@"
  }
  certificate_valid() { [[ $reuse == 1 ]]; }
  certificate_http() { real_certificate_http "$@"; }
  certificate_cloudflare() { real_certificate_cloudflare "$@"; }
  copy_certificate() {
    printf 'copy_certificate\n' >>"$events"
    printf 'new certificate\n' >"$TLS_DIR/fullchain.pem"
    [[ $fail_at != copy && $fail_at != firewall-rollback ]] || return 27
    printf 'new key\n' >"$TLS_DIR/privkey.pem"; printf 'new hook\n' >"$hook"
    case $fail_at in term) kill -TERM "$BASHPID" ;; int) kill -INT "$BASHPID" ;; esac
  }
  case $name in
    missing) rm -- "$EXPORT_DIR/custom isp1.txt" ;;
    malformed) printf 'broken URI\n' >"$EXPORT_DIR/custom isp1.txt" ;;
    absent|absent-late) rm -- "$CF_CREDENTIALS" "$hook" "$TLS_DIR/fullchain.pem" "$TLS_DIR/privkey.pem" ;;
    copy-cert|copy-hook) copy_certificate() { real_copy_certificate "$@"; } ;;
    foreign|nested-link|extensionless-link)
      case $name in
        foreign) relocated="$root/foreign/link" ;;
        nested-link) relocated="$EXPORT_DIR/subdir/link.txt" ;;
        extensionless-link) relocated="$EXPORT_DIR/link" ;;
      esac
      mkdir -p "${relocated%/*}"; cp "$EXPORT_DIR/custom isp1.txt" "$relocated"
      save_node isp1 isp isp1 443 443 hy2m-isp1.service "$HYSTERIA_DIR/isp1.yaml" "$relocated" normal ;;
    symlink)
      mv "$EXPORT_DIR/custom isp1.txt" "$root/target"
      if ! MSYS=winsymlinks:nativestrict ln -s "$root/target" "$EXPORT_DIR/custom isp1.txt" || [[ ! -L $EXPORT_DIR/custom\ isp1.txt ]]; then
        printf '[SKIP] native symlinks unsupported by this filesystem\n'; return 77
      fi ;;
    rewrite)
      rewrite_node_domain "$EXPORT_DIR/custom direct.txt" old.example.com new.example.com || return 1
      grep -Fq 'sni=new.example.com&tag=old.example.com#Keep%20Name' "$EXPORT_DIR/custom direct.txt" || return 1
      return 0 ;;
    real-copy)
      [[ ${LETSENCRYPT_DIR:-} == "$HY2M_LETSENCRYPT_DIR" && ${RENEWAL_HOOK:-} == "$hook" ]] || return 1
      certbot certonly >/dev/null
      real_copy_certificate new.example.com --no-timer || return 1
      cmp "$TLS_DIR/fullchain.pem" "$HY2M_LETSENCRYPT_DIR/live/new.example.com/fullchain.pem" || return 1
      bash -n "$hook" || return 1
      ! grep -q 'systemctl enable' "$events" || return 1
      return 0 ;;
  esac
  # Intentionally use an if context: errexit is not a transaction mechanism.
  if (change_domain); then rc=0; else rc=$?; fi
  case $name in
    success|stopped)
      [[ $rc == 0 ]] || return 1
      grep -q 'DOMAIN=new.example.com' "$MANAGER_STATE" || return 1
      for id in direct isp1; do
        grep -Fq 'pass%40word@new.example.com:443/?sni=new.example.com&tag=old.example.com#Keep%20Name' "$EXPORT_DIR/custom $id.txt" || return 1
        [[ $(<"$root/runtime/hy2m-$id.service.active") == "$active" ]] || return 1
        [[ $(<"$root/runtime/hy2m-$id.service.enabled") == disabled ]] || return 1
      done
      ! grep -q 'systemctl enable' "$events" || return 1
      if [[ $name == stopped ]]; then ! grep -Eq 'systemctl (restart|start|try-restart)' "$events" || return 1; fi ;;
    missing|malformed|foreign|symlink|snapshot-node|snapshot-manager|snapshot-link)
      [[ $rc != 0 ]] || return 1
      ! grep -Eq 'certbot |copy_certificate|ufw allow|systemctl (restart|enable)' "$events" || return 1
      cmp "$MANAGER_STATE" "$root/before/manager" || return 1
      cmp "$TLS_DIR/fullchain.pem" "$root/before/cert" || return 1 ;;
    rollback|firewall-rollback)
      [[ $rc != 0 ]] || return 1
      shopt -s nullglob; recovery=("$STATE_DIR"/.domain-change.*)
      ((${#recovery[@]} > 0)) || return 1
      if [[ $name == firewall-rollback ]]; then [[ $(<"$root/http80") == open ]] || return 1; fi ;;
    *)
      [[ $rc != 0 ]] || return 1
      [[ $name != term && $name != cert-term || $rc == 143 ]] || return 1
      [[ $name != int && $name != cert-int || $rc == 130 ]] || return 1
      cmp "$MANAGER_STATE" "$root/before/manager" || return 1
      cmp "$EXPORT_DIR/custom direct.txt" "$root/before/direct" || return 1
      cmp "$EXPORT_DIR/custom isp1.txt" "$root/before/isp1" || return 1
      if [[ $name == absent || $name == absent-late ]]; then
        [[ ! -e $CF_CREDENTIALS && ! -e $hook && ! -e $TLS_DIR/fullchain.pem && ! -e $TLS_DIR/privkey.pem ]] || return 1
      else
        cmp "$TLS_DIR/fullchain.pem" "$root/before/cert" || return 1
        cmp "$TLS_DIR/privkey.pem" "$root/before/key" || return 1
        cmp "$CF_CREDENTIALS" "$root/before/cf" || return 1
        cmp "$hook" "$root/before/hook" || return 1
      fi
      cmp "$FIREWALL_STATE" "$root/before/firewall" || return 1
      [[ $(<"$root/http80") == "$mock_http80" ]] || return 1
      if [[ $name == nested-link || $name == extensionless-link ]]; then cmp "$relocated" "$root/before/isp1" || return 1; fi
      for id in direct isp1; do
        [[ $(<"$root/runtime/hy2m-$id.service.active") == "$active" ]] || return 1
        [[ $(<"$root/runtime/hy2m-$id.service.enabled") == disabled ]] || return 1
      done ;;
  esac
)

cases=(success stopped missing malformed foreign symlink rewrite issuance copy link state restart cloudflare absent absent-late term int cert-term cert-int rollback firewall-rollback real-copy copy-cert copy-hook existing-http stopped-failure snapshot-node snapshot-manager snapshot-link nested-link extensionless-link)
skipped=0
for name in "${cases[@]}"; do
  if (set -Eeuo pipefail; run_case "$name") >"$run_root/$name.log" 2>&1; then case_rc=0; else case_rc=$?; fi
  if [[ $case_rc == 0 && $name == rollback ]] && ! grep -q '自动恢复未完成' "$run_root/$name.log"; then case_rc=1; fi
  if [[ $case_rc == 0 ]]; then
    printf '[PASS] %s\n' "$name"
  elif [[ $case_rc == 77 ]]; then
    printf '[SKIP] %s (native symlinks unavailable)\n' "$name"; skipped=$((skipped+1))
  else
    printf '[FAIL] %s (log: %s)\n' "$name" "$run_root/$name.log" >&2
    failures=$((failures+1))
  fi
done
printf 'Domain test artifacts: %s\n' "$run_root"
((failures == 0)) || { printf '%d domain test(s) failed.\n' "$failures" >&2; exit 1; }
printf 'Domain transaction tests passed (%d cases).\n' "${#cases[@]}"
