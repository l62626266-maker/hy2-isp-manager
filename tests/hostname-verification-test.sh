#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317
set -Eeuo pipefail
cd "$(dirname "$0")/.."
for script in hy2-manager hy2-cert-guard; do
  (
    export HY2M_SOURCE_ONLY=1 HY2CG_SOURCE_ONLY=1
    source "./$script"
    openssl() { printf 'Hostname %s does NOT match certificate\n' "${*: -1}"; return 0; }
    if [[ $script == hy2-manager ]]; then
      if certificate_hostname_matches fake.pem node.example.com; then exit 1; fi
      declare -F certificate_hostname_matches >/dev/null
    else
      if cert_has_domain fake.pem node.example.com; then exit 1; fi
    fi
    openssl() { printf 'Hostname %s does match certificate\n' "${*: -1}"; return 0; }
    if [[ $script == hy2-manager ]]; then certificate_hostname_matches fake.pem node.example.com
    else cert_has_domain fake.pem node.example.com; fi
  )
  printf '[PASS] %s verifies affirmative hostname verdict even with zero-exit mismatch\n' "$script"
done