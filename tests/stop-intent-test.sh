#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
set -Eeuo pipefail
cd "$(dirname "$0")/.."
export HY2CG_SOURCE_ONLY=1
source ./hy2-cert-guard
current_boot_id() { printf '11111111-1111-1111-1111-111111111111'; }
EXPECTED_STOP_BOOT[hy2m-direct.service]=$(current_boot_id)
service_intentionally_stopped hy2m-direct.service inactive
if service_intentionally_stopped hy2m-direct.service failed; then exit 1; fi
if service_intentionally_stopped hy2m-direct.service active; then exit 1; fi
if service_intentionally_stopped manual.service inactive; then exit 1; fi
current_boot_id() { printf '22222222-2222-2222-2222-222222222222'; }
if service_intentionally_stopped hy2m-direct.service inactive; then exit 1; fi
current_boot_id() { return 1; }
if service_intentionally_stopped hy2m-direct.service inactive; then exit 1; fi
printf '[PASS] stop intent only suppresses inactive service within its original boot\n'
# Exercise the health report, including the paired UDP listener exemption.
mkdir -p .tmp
work=$(mktemp -d "$PWD/.tmp/stop-health.XXXXXX")
LIVE_DIR=$work; DEPLOY_CERT="$work/fullchain.pem"; DEPLOY_KEY="$work/privkey.pem"
: >"$DEPLOY_CERT"; : >"$DEPLOY_KEY"
DOMAIN=node.example.com; EXPECTED_IPV4=192.0.2.1
SERVICES=hy2m-direct.service; UDP_PORTS=8443
MANAGED_SERVICE_PORT[hy2m-direct.service]=8443
current_boot_id() { printf '11111111-1111-1111-1111-111111111111'; }
require_root() { :; }; load_config() { :; }; cert_has_domain() { :; }
cert_pair_matches() { :; }; cert_days_left() { printf 90; }; cert_fingerprint() { printf fingerprint; }
openssl() { printf 'notAfter=Jan 1 00:00:00 2030 GMT\n'; }
id() { return 1; }; check_challenge_access() { :; }; write_result() { :; }
resolve_ipv4() { printf '192.0.2.1\n'; }; ss() { :; }
systemctl() {
  case $1 in
    is-enabled) printf enabled ;;
    is-active) if [[ ${*: -1} == certbot.timer ]]; then printf active; else printf '%s' "$NODE_STATUS"; fi ;;
    show) : ;;
    *) return 1 ;;
  esac
}
NODE_STATUS=inactive
check_all >"$work/intentional.log"
[[ $failures == 0 ]]
NODE_STATUS=failed
if check_all >"$work/failed.log"; then exit 1; fi
NODE_STATUS=inactive
current_boot_id() { printf '22222222-2222-2222-2222-222222222222'; }
if check_all >"$work/reboot.log"; then exit 1; fi
NODE_STATUS=active
if check_all >"$work/no-listener.log"; then exit 1; fi
printf '[PASS] health report skips only deliberately stopped listeners and still detects failures\n'
