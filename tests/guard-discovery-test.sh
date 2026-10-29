#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp
export TMPDIR="${TMPDIR:-$PWD/.tmp}"
tmp=$(mktemp -d "$TMPDIR/guard-inventory.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export HY2CG_SOURCE_ONLY=1
export HY2CG_MANAGER_NODE_DIR="$tmp/nodes" HY2CG_MANAGER_CONFIG_DIR="$tmp/config"
export HY2CG_MANAGER_STATE="$tmp/manager.env"
printf 'DOMAIN=test.example.com\nPUBLIC_IP=192.0.2.1\nCERT_MODE=http\n' >"$HY2CG_MANAGER_STATE"
source ./hy2-cert-guard
mkdir -p "$HY2CG_MANAGER_NODE_DIR" "$HY2CG_MANAGER_CONFIG_DIR"
# Fixture ownership is not root on developer machines; only this test stubs it.
trusted_root_file() { [[ -f $1 && ! -L $1 ]]; }
DEPLOY_CERT="$HY2CG_MANAGER_CONFIG_DIR/tls/fullchain.pem"
DEPLOY_KEY="$HY2CG_MANAGER_CONFIG_DIR/tls/privkey.pem"
fixture() {
  local id=$1 port=$2 config="$HY2CG_MANAGER_CONFIG_DIR/$1.yaml"
  printf 'SERVICE=%q\nLISTEN_PORT=%q\nCONFIG=%q\n' "hy2m-$id.service" "$port" "$config" >"$HY2CG_MANAGER_NODE_DIR/$id.env"
  printf 'listen: :%s\n\ntls:\n  cert: "%s"\n  key: "%s"\n' "$port" "$DEPLOY_CERT" "$DEPLOY_KEY" >"$config"
}
fixture direct 443
fixture isp1 8443
fixture isp2 9443
SERVICES='hy2m-direct.service hy2m-isp1.service'; UDP_PORTS='443 8443'
refresh_manager_targets
[[ $SERVICES == 'hy2m-direct.service hy2m-isp1.service hy2m-isp2.service' && $UDP_PORTS == '443 8443 9443' ]]
printf '[PASS] discovers new ISP sharing the same certificate\n'
rm -f "$HY2CG_MANAGER_NODE_DIR/isp1.env"
refresh_manager_targets
[[ $SERVICES == 'hy2m-direct.service hy2m-isp2.service' && $UDP_PORTS == '443 9443' ]]
printf '[PASS] removed ISP no longer remains in restart/check targets\n'
fixture isp2 10443
refresh_manager_targets
[[ $UDP_PORTS == '443 10443' ]]
printf '[PASS] changed listener port follows node inventory\n'
printf 'DESIRED_STATE=stopped\nSTOP_BOOT_ID=11111111-1111-1111-1111-111111111111\n' >>"$HY2CG_MANAGER_NODE_DIR/direct.env"
refresh_manager_targets
[[ ${EXPECTED_STOP_BOOT[hy2m-direct.service]} == 11111111-1111-1111-1111-111111111111 && ${MANAGED_SERVICE_PORT[hy2m-direct.service]} == 443 ]]
printf '[PASS] discovered stop intent retains service-to-port association\n'
AUTO_DISCOVER_MANAGER=0
SERVICES='hy2m-direct.service'; UDP_PORTS=443
refresh_manager_targets
[[ $SERVICES == 'hy2m-direct.service' && $UDP_PORTS == 443 ]]
[[ ${#EXPECTED_STOP_BOOT[@]} == 0 && ${#MANAGED_SERVICE_PORT[@]} == 0 ]]
printf '[PASS] explicit opt-out preserves configured targets\n'
AUTO_DISCOVER_MANAGER=1
SERVICES='hysteria-server.service hy2m-direct.service'; UDP_PORTS='443 8443'
refresh_manager_targets
[[ $SERVICES == 'hysteria-server.service hy2m-direct.service' && $UDP_PORTS == '443 8443' ]]
printf '[PASS] mixed/manual deployment remains explicit\n'
SERVICES='hy2m-direct.service'
printf 'listen: :10443\n\ntls:\n  cert: "/different/cert.pem"\n  key: "%s"\n' "$DEPLOY_KEY" >"$HY2CG_MANAGER_CONFIG_DIR/isp2.yaml"
if (refresh_manager_targets) >/dev/null 2>&1; then printf '[FAIL] unrelated certificate accepted\n'; exit 1; fi
printf '[PASS] mismatched certificate prevents target refresh/deployment\n'
printf '\nCertificate target discovery tests passed.\n'
