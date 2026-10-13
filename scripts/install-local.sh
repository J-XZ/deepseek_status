#!/bin/bash
# 构建 Release，用稳定的代码签名身份签名后安装到 ~/Applications 并重启。
# 稳定签名使钥匙串 ACL（指定要求）在重装后保持匹配，避免每次安装都弹出钥匙串授权。
# 用法：scripts/install-local.sh   可用 SIGN_IDENTITY 覆盖（默认取第一个 "Apple Development" 身份）。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "未找到代码签名身份" >&2; exit 1; }
./build.sh --release
STAGE="$(mktemp -d)"
ditto --noextattr --norsrc build/DerivedData/Build/Products/Release/DeepSeekBalance.app "$STAGE/DeepSeekBalance.app"
xattr -cr "$STAGE/DeepSeekBalance.app"
codesign --force --deep --options runtime --timestamp=none \
  --entitlements DeepSeekBalance/DeepSeekBalance.entitlements -s "$IDENTITY" "$STAGE/DeepSeekBalance.app"
codesign --verify --deep --strict "$STAGE/DeepSeekBalance.app"
osascript -e 'quit app "DeepSeekBalance"' 2>/dev/null || true
sleep 2; pkill -x DeepSeekBalance 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/DeepSeekBalance.app"
ditto "$STAGE/DeepSeekBalance.app" "$HOME/Applications/DeepSeekBalance.app"
rm -rf "$STAGE"
open "$HOME/Applications/DeepSeekBalance.app"
echo "已安装并启动：$HOME/Applications/DeepSeekBalance.app（签名：${IDENTITY}）"
