#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly VERSION="v0.2.0-beta.1"
readonly REPO="l62626266-maker/hy2-isp-manager"
readonly MANAGER_SHA256="291ca5c00a0a0bb3816261accc60d20df5bf34212a843924aaa5e2f8e95eab69"

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行。"
for cmd in curl sha256sum mktemp install; do command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"; done

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT INT TERM

# Local repository execution is useful for review and development. Piped/release
# installation always downloads the immutable tagged manager and checks SHA-256.
script_dir=""
if [[ -n ${BASH_SOURCE[0]:-} && ${BASH_SOURCE[0]} != /dev/stdin && ${BASH_SOURCE[0]} != bash ]]; then
  if ! script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd); then script_dir=""; fi
fi
if [[ -n $script_dir && -f $script_dir/hy2-manager ]]; then
  install -m 700 "$script_dir/hy2-manager" "$tmp"
else
  url="https://raw.githubusercontent.com/$REPO/$VERSION/hy2-manager"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 "$url" -o "$tmp"
  actual=$(sha256sum "$tmp"); actual=${actual%% *}
  [[ $MANAGER_SHA256 != __MANAGER_SHA256__ ]] || die "发布包尚未写入 SHA256，拒绝联网安装。"
  [[ $actual == "$MANAGER_SHA256" ]] || die "hy2-manager SHA256 校验失败。"
fi

bash -n "$tmp"
bash "$tmp" install-self
if [[ ${1:-} != --install-only ]]; then exec /usr/local/sbin/hy2-manager menu; fi
