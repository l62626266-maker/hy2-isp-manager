#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -Eeuo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
version=v2.12.2
asset=hysteria-linux-amd64
base="https://github.com/apernet/hysteria/releases/download/app/$version"
curl -fsSL --proto '=https' --tlsv1.2 --retry 3 "$base/hashes.txt" -o "$tmp/hashes.txt"
curl -fsSL --proto '=https' --tlsv1.2 --retry 3 "$base/$asset" -o "$tmp/hysteria"
expected=$(awk -v n="build/$asset" '$2==n{print $1; exit}' "$tmp/hashes.txt")
actual=$(sha256sum "$tmp/hysteria"); actual=${actual%% *}
[[ -n $expected && $actual == "$expected" ]]
chmod 700 "$tmp/hysteria"

mkdir -p "$tmp/tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=test.example.com' \
  -addext 'subjectAltName=DNS:test.example.com' \
  -keyout "$tmp/tls/privkey.pem" -out "$tmp/tls/fullchain.pem" >/dev/null 2>&1

export HY2M_SOURCE_ONLY=1 HY2M_TESTING=1 HY2M_HYSTERIA_DIR="$tmp"
# shellcheck source=../hy2-manager
source ./hy2-manager
write_common_config 38443 0123456789abcdef0123456789abcdef0123456789abcdef >"$tmp/direct.yaml"
SOCKS_HOST=127.0.0.1; SOCKS_PORT=9; SOCKS_USER=testuser; SOCKS_PASS='test:#@ pass'
render_isp_config 38444 111111111111111111111111111111111111111111111111 isp_all >"$tmp/isp.yaml"

smoke() {
  local cfg=$1 log=$2 code
  set +e
  timeout 3s "$tmp/hysteria" server -c "$cfg" >"$log" 2>&1
  code=$?
  set -e
  [[ $code -eq 124 ]]
  grep -Fq 'server up and running' "$log"
}
smoke "$tmp/direct.yaml" "$tmp/direct.log"
smoke "$tmp/isp.yaml" "$tmp/isp.log"
printf 'Hysteria direct and ISP configuration smoke tests passed.\n'
