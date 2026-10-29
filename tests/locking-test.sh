#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317,SC2016
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if ! command -v flock >/dev/null 2>&1; then
  printf '[SKIP] flock requires Linux; CI executes real concurrency tests\n'; exit 0
fi
mkdir -p .tmp
root=$(mktemp -d "$PWD/.tmp/locking.XXXXXX")
export HY2_LOCK_FILE="$root/mutations.lock" HY2M_SOURCE_ONLY=1 HY2CG_SOURCE_ONLY=1
source ./hy2-manager
hold_lock() {
  : >"$root/ready"
  while [[ ! -f $root/release ]]; do sleep 0.05; done
}
with_mutation_lock hold_lock &
holder=$!
trap 'touch "$root/release"; wait "$holder" || true' EXIT
for ((i=0; i<100; i++)); do [[ ! -f $root/ready ]] || break; sleep 0.05; done
[[ -f $root/ready ]]
for script in hy2-manager hy2-cert-guard; do
  rc=0
  bash -c 'source "./$1"; with_mutation_lock touch "$2"' _ "$script" "$root/unexpected" >"$root/$script.log" 2>&1 || rc=$?
  [[ $rc == 75 && ! -e $root/unexpected ]]
  printf '[PASS] %s respects shared mutation lock\n' "$script"
done
# Restore may replace its state tree; the lock must not be stored in it.
mkdir -p "$root/state"; mv "$root/state" "$root/state-before"; mkdir -p "$root/state"
rc=0
with_mutation_lock touch "$root/unexpected" 2>/dev/null || rc=$?
[[ $rc == 75 && ! -e $root/unexpected ]]
touch "$root/release"; wait "$holder"
with_mutation_lock touch "$root/after"
[[ -f "$root/after" ]]
printf '[PASS] lock survives state replacement and releases after completion\n'