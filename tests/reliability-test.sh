#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp
export TMPDIR="$PWD/.tmp"
suite=$(mktemp -d "$TMPDIR/reliability.XXXXXX")
failures=0
check_case() {
  local rc=0
  set +e
  (set -Eeuo pipefail; "$2") >"$suite/$1.log" 2>&1
  rc=$?; set -e
  if ((rc == 0)); then printf '[PASS] %s\n' "$1"
  else printf '[FAIL] %s (%s)\n' "$1" "$suite/$1.log"; failures=$((failures+1)); fi
}
manager_fixture() {
  export HY2M_SOURCE_ONLY=1 HY2M_TESTING=1 HY2M_STATE_DIR="$suite/$1/state" HY2M_HYSTERIA_DIR="$suite/$1/config"
  source ./hy2-manager
  mkdir -p "$NODE_DIR" "$TLS_DIR"
}
atomic_state() {
  manager_fixture atomic
  printf 'A=old\n' >"$STATE_DIR/test.env"
  mv() { return 41; }
  if write_env "$STATE_DIR/test.env" A new; then return 1; fi
  [[ $(<"$STATE_DIR/test.env") == A=old ]]
}
firewall_delete() {
  manager_fixture firewall
  printf '443/udp\n' >"$FIREWALL_STATE"
  ufw() { if [[ $1 == status ]]; then printf 'Status: active\n'; else return 42; fi; }
  install() { command install -m 600 "${@: -2}"; }
  if close_firewall 443 udp; then return 1; fi
  grep -Fxq 443/udp "$FIREWALL_STATE"
}
reserved_port() {
  manager_fixture port
  printf 'LISTEN_PORT=443\nPUBLIC_PORT=443\n' >"$NODE_DIR/direct.env"
  ss() { return 0; }
  declare -F node_port_free >/dev/null
  if node_port_free 443; then return 1; fi
  node_port_free 8443
}
expired_panel() {
  manager_fixture expired
  : >"$TLS_DIR/fullchain.pem"
  openssl() { if [[ $* == *-enddate* ]]; then printf 'notAfter=Jan 1 00:00:00 2020 GMT\n'; else return 1; fi; }
  ui_init_colors
  ui_cert_text
  [[ $UI_CERT_TEXT == *已过期* ]]
}
strict_domain() {
  export HY2CG_SOURCE_ONLY=1
  source ./hy2-cert-guard
  MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=node.example.com.evil.test' -addext 'subjectAltName=DNS:node.example.com.evil.test' -keyout "$suite/key.pem" -out "$suite/cert.pem" >/dev/null 2>&1
  if cert_has_domain "$suite/cert.pem" node.example.com; then return 1; fi
  cert_has_domain "$suite/cert.pem" node.example.com.evil.test
}
managed_identity() {
  export HY2CG_SOURCE_ONLY=1 HY2CG_MANAGER_NODE_DIR="$suite/identity/nodes" HY2CG_MANAGER_CONFIG_DIR="$suite/identity/config"
  export HY2CG_MANAGER_STATE="$suite/identity/manager.env" HY2CG_LETSENCRYPT_DIR="$suite/identity/acme"
  source ./hy2-cert-guard
  mkdir -p "$HY2CG_MANAGER_NODE_DIR" "$HY2CG_MANAGER_CONFIG_DIR"
  trusted_root_file() { [[ -f $1 && ! -L $1 ]]; }
  DEPLOY_CERT="$HY2CG_MANAGER_CONFIG_DIR/tls/fullchain.pem"; DEPLOY_KEY="$HY2CG_MANAGER_CONFIG_DIR/tls/privkey.pem"
  DOMAIN=old.example.com; LIVE_DIR="$HY2CG_LETSENCRYPT_DIR/live/$DOMAIN"; SERVICES=hy2m-direct.service
  printf 'DOMAIN=new.example.com\nPUBLIC_IP=192.0.2.1\nCERT_MODE=cloudflare\n' >"$HY2CG_MANAGER_STATE"
  printf 'SERVICE=hy2m-direct.service\nLISTEN_PORT=443\nCONFIG=%q\n' "$HY2CG_MANAGER_CONFIG_DIR/direct.yaml" >"$HY2CG_MANAGER_NODE_DIR/direct.env"
  printf 'listen: :443\n  cert: "%s"\n  key: "%s"\n' "$DEPLOY_CERT" "$DEPLOY_KEY" >"$HY2CG_MANAGER_CONFIG_DIR/direct.yaml"
  refresh_manager_targets
  [[ $DOMAIN == new.example.com && $LIVE_DIR == "$HY2CG_LETSENCRYPT_DIR/live/new.example.com" && $CERT_MODE == cloudflare ]]
}
guard_deploy_fixture() {
  export HY2CG_SOURCE_ONLY=1 HY2CG_STATE_DIR="$suite/$1/guard"
  source ./hy2-cert-guard
  mkdir -p "$STATE_DIR" "$suite/$1/live" "$suite/$1/tls"
  LIVE_DIR="$suite/$1/live"; DEPLOY_CERT="$suite/$1/tls/cert"; DEPLOY_KEY="$suite/$1/tls/key"
  DOMAIN=test.example.com; SERVICES='hy2m-direct.service hy2m-isp1.service'
  printf old-cert >"$DEPLOY_CERT"; printf old-key >"$DEPLOY_KEY"
  printf new-cert >"$LIVE_DIR/fullchain.pem"; printf new-key >"$LIVE_DIR/privkey.pem"
  require_root() { :; }; load_config() { :; }; cert_has_domain() { :; }; cert_pair_matches() { :; }
  openssl() { :; }; runuser() { :; }; sleep() { :; }; check_all() { :; }
  install() {
    local args=() arg skip=0
    for arg in "$@"; do
      if ((skip)); then skip=0; continue; fi
      case $arg in -o|-g) skip=1 ;; *) args+=("$arg") ;; esac
    done
    if [[ $1 == -d ]]; then mkdir -p "${*: -1}"; else command install "${args[@]}"; fi
  }
  systemctl() {
    case $1 in
      is-active) [[ ${*: -1} == hy2m-direct.service ]] && { printf 'active\n'; return 0; }; printf 'inactive\n'; return 3 ;;
      try-restart|restart) printf '%s\n' "$*" >>"$STATE_DIR/restarts" ;;
      *) return 0 ;;
    esac
  }
}
stopped_deployment() {
  guard_deploy_fixture stopped
  deploy_cert "$LIVE_DIR"
  [[ $(<"$DEPLOY_CERT") == new-cert && $(<"$DEPLOY_KEY") == new-key ]]
  ! grep -q hy2m-isp1 "$STATE_DIR/restarts"
}
partial_deployment() {
  guard_deploy_fixture partial
  systemctl() { if [[ $1 == is-active ]]; then printf 'active\n'; fi; return 0; }
  mv() { if [[ ${*: -1} == "$DEPLOY_KEY" ]]; then : >"$STATE_DIR/fault"; return 44; else command mv "$@"; fi; }
  if (deploy_cert "$LIVE_DIR"); then return 1; fi
  [[ -f $STATE_DIR/fault && $(<"$DEPLOY_CERT") == old-cert && $(<"$DEPLOY_KEY") == old-key ]]
}
dns_challenge() {
  export HY2CG_SOURCE_ONLY=1
  source ./hy2-cert-guard
  CERT_MODE=cloudflare
  ufw() { : >"$suite/unexpected-ufw"; return 1; }
  ss() { : >"$suite/unexpected-ss"; return 1; }
  check_challenge_access
  [[ ! -e $suite/unexpected-ufw && ! -e $suite/unexpected-ss && $failures == 0 ]]
}
old_lineage() {
  guard_deploy_fixture oldlineage
  export RENEWED_LINEAGE="$suite/oldlineage/old" RENEWED_DOMAINS=old.example.com
  deploy_cert "$LIVE_DIR"
  [[ $(<"$DEPLOY_CERT") == old-cert && ! -e $STATE_DIR/restarts ]]
}
signal_deployment() {
  guard_deploy_fixture signal
  mv() {
    command mv "$@" || return 1
    if [[ ${*: -1} == "$DEPLOY_CERT" ]]; then : >"$STATE_DIR/fault"; kill -TERM "$BASHPID"; fi
  }
  local rc=0
  (deploy_cert "$LIVE_DIR") || rc=$?
  [[ $rc == 143 && -f $STATE_DIR/fault && $(<"$DEPLOY_CERT") == old-cert && $(<"$DEPLOY_KEY") == old-key ]]
}
restart_deployment() {
  guard_deploy_fixture restart
  systemctl() {
    case $1 in
      is-active) printf 'active\n'; return 0 ;;
      try-restart) : >"$STATE_DIR/fault"; return 43 ;;
      restart) : >"$STATE_DIR/recovered" ;;
    esac
  }
  if (deploy_cert "$LIVE_DIR"); then return 1; fi
  [[ -f $STATE_DIR/fault && -f $STATE_DIR/recovered && $(<"$DEPLOY_CERT") == old-cert && $(<"$DEPLOY_KEY") == old-key ]]
}
backup_failure() {
  guard_deploy_fixture snapshot
  cp() { : >"$STATE_DIR/fault"; return 49; }
  if (deploy_cert "$LIVE_DIR"); then return 1; fi
  [[ -f $STATE_DIR/fault && $(<"$DEPLOY_CERT") == old-cert && $(<"$DEPLOY_KEY") == old-key && ! -e $STATE_DIR/restarts ]]
}
reuse_domain_certificate() {
  manager_fixture reuse
  certificate_valid() { return 0; }
  copy_certificate() { printf '%s\n' "$*" >"$suite/reused-deployment"; }
  _domain_certificate_stage_impl new.example.com http ''
  [[ -f $suite/reused-deployment ]] && grep -Fxq 'new.example.com --no-timer' "$suite/reused-deployment"
}
initial_guard_check() {
  export HY2CG_HOOK_FILE="$suite/install/hook" HY2CG_SERVICE_FILE="$suite/install/service"
  export HY2CG_TIMER_FILE="$suite/install/timer" HY2CG_PROFILE_FILE="$suite/install/profile"
  mkdir -p "$suite/install"
  guard_deploy_fixture install
  install() { :; }
  systemctl() { if [[ $1 == start ]]; then : >"$suite/install/nested-lock"; return 75; fi; }
  check_all() { : >"$suite/install/checked"; }
  install_system
  [[ -f $suite/install/checked && ! -e $suite/install/nested-lock ]]
}
waiting_lock_interface() {
  manager_fixture waitlock
  export HY2_LOCK_FILE="$suite/test.lock"
  flock() { printf '%s\n' "$*" >"$suite/flock-args"; }
  with_mutation_lock --wait touch "$suite/waited"
  [[ -e $suite/waited ]] && grep -q '^-w 300 ' "$suite/flock-args"
}
firewall_write_failure() {
  manager_fixture firewallwrite
  ufw() { if [[ $1 == status ]]; then printf 'Status: active\n'; else : >"$suite/firewall-mutated"; fi; }
  mv() { return 46; }
  if open_firewall 443 udp; then return 1; fi
  [[ ! -e $suite/firewall-mutated ]]
}
atomic_install_failure() {
  manager_fixture atomicinstall
  printf old >"$STATE_DIR/target"; printf new >"$STATE_DIR/source"
  mv() { return 47; }
  if install_owned 600 root "$STATE_DIR/source" "$STATE_DIR/target"; then return 1; fi
  [[ $(<"$STATE_DIR/target") == old ]]
}
recently_expired_panel() {
  manager_fixture recentexpired
  : >"$TLS_DIR/fullchain.pem"
  openssl() { printf 'notAfter=ignored\n'; }
  date() { if [[ $1 == -d ]]; then printf 100000; else printf 100010; fi; }
  ui_init_colors; ui_cert_text
  [[ $UI_CERT_TEXT == *已过期* ]]
}
guard_publish_failure() {
  export HY2CG_HOOK_FILE="$suite/installfail/hook" HY2CG_SERVICE_FILE="$suite/installfail/service"
  export HY2CG_TIMER_FILE="$suite/installfail/timer" HY2CG_PROFILE_FILE="$suite/installfail/profile"
  mkdir -p "$suite/installfail"
  guard_deploy_fixture installfail
  install() { :; }; systemctl() { :; }
  check_all() { : >"$suite/installfail/checked"; }
  printf original >"$SERVICE_FILE"
  mv() { return 48; }
  if install_system; then return 1; fi
  [[ $(<"$SERVICE_FILE") == original && ! -e $suite/installfail/checked ]]
}
check_case atomic-state atomic_state
check_case failed-firewall-delete firewall_delete
check_case reserved-stopped-port reserved_port
check_case expired-certificate-panel expired_panel
check_case strict-certificate-domain strict_domain
check_case managed-domain-refresh managed_identity
check_case stopped-service-deployment stopped_deployment
check_case partial-certificate-publication partial_deployment
check_case dns-challenge-no-http dns_challenge
check_case stale-lineage-skipped old_lineage
check_case interrupted-publication signal_deployment
check_case restart-failure-rollback restart_deployment
check_case backup-failure-aborts backup_failure
check_case existing-domain-certificate-deployed reuse_domain_certificate
check_case initial-guard-check-no-reentrant-lock initial_guard_check
check_case unattended-lock-waits waiting_lock_interface
check_case firewall-journal-before-mutation firewall_write_failure
check_case atomic-file-publication atomic_install_failure
check_case recently-expired-panel recently_expired_panel
check_case guard-install-publication-failure guard_publish_failure
printf 'Reliability artifacts: %s\n' "$suite"
((failures == 0))