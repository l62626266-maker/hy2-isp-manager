#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2016,SC2034
set -Eeuo pipefail
cd "$(dirname "$0")/.."

failures=0
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; failures=$((failures+1)); }

if bash -n hy2-cert-guard; then pass "cert guard syntax"; else fail "cert guard syntax"; fi
if bash -n install-cert-guard.sh; then pass "cert guard installer syntax"; else fail "cert guard installer syntax"; fi

export HY2CG_SOURCE_ONLY=1
# shellcheck source=../hy2-cert-guard
source ./hy2-cert-guard

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey rsa:2048 -nodes -days 60 -subj '/CN=test.example.com' \
  -addext 'subjectAltName=DNS:test.example.com' -keyout "$tmp/key1.pem" -out "$tmp/cert1.pem" >/dev/null 2>&1
MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey rsa:2048 -nodes -days 60 -subj '/CN=other.example.com' \
  -addext 'subjectAltName=DNS:other.example.com' -keyout "$tmp/key2.pem" -out "$tmp/cert2.pem" >/dev/null 2>&1
if cert_pair_matches "$tmp/cert1.pem" "$tmp/key1.pem"; then pass "matching certificate and key"; else fail "matching certificate and key"; fi
if cert_pair_matches "$tmp/cert1.pem" "$tmp/key2.pem"; then fail "reject mismatched certificate and key"; else pass "reject mismatched certificate and key"; fi
if cert_has_domain "$tmp/cert1.pem" test.example.com; then pass "certificate SAN match"; else fail "certificate SAN match"; fi
if cert_has_domain "$tmp/cert1.pem" wrong.example.com; then fail "reject wrong certificate SAN"; else pass "reject wrong certificate SAN"; fi
days=$(cert_days_left "$tmp/cert1.pem")
if [[ $days =~ ^[0-9]+$ && $days -ge 58 && $days -le 60 ]]; then pass "certificate days remaining"; else fail "certificate days remaining"; fi

for required in 'certbot renew --cert-name "$DOMAIN" --dry-run' 'systemctl try-restart "$unit"' 'Persistent=true' 'RandomizedDelaySec=2h' 'HY2-CERTIFICATE-ALERT.txt' 'source /var/lib/hy2-cert-guard/status'; do
  if grep -Fq "$required" hy2-cert-guard; then pass "contract: $required"; else fail "contract: $required"; fi
done
if grep -Fq -- '--run-deploy-hooks' hy2-cert-guard; then fail "dry-run must not deploy staging certificate"; else pass "dry-run cannot deploy staging certificate"; fi
if grep -Fq 'legacy-hooks/' install-cert-guard.sh; then pass "legacy hook backup"; else fail "legacy hook backup"; fi
if grep -Fq 'GUARD_SHA256=' install-cert-guard.sh && ! grep -Fq 'GUARD_SHA256="__GUARD_SHA256__"' install-cert-guard.sh; then pass "pinned checker hash"; else fail "pinned checker hash"; fi
if grep -Fq 'runuser -u hysteria -- test -r' hy2-cert-guard && grep -Fq '[[ -d $cert_dir ]] || install -d' hy2-cert-guard; then pass "certificate directory permissions protected"; else fail "certificate directory permissions protected"; fi
if grep -REn --exclude='cert-guard-test.sh' '(BEGIN (OPENSSH|RSA|EC) PRIVATE KEY|dns_cloudflare_api_token[[:space:]]*=)' hy2-cert-guard install-cert-guard.sh; then fail "no embedded secrets"; else pass "no embedded secrets"; fi

if ((failures)); then printf '\n%d test(s) failed.\n' "$failures" >&2; exit 1; fi
printf '\nCertificate guard tests passed.\n'
