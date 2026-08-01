#!/bin/bash
# 构建并打包可分发的 macOS 安装文件：ZIP、PKG、DMG 与 SHA256SUMS。
#
# 用法：
#   ./scripts/package_app.sh
#   VERSION=1.0.0 ./scripts/package_app.sh
#   ./scripts/package_app.sh --skip-build
#
# 默认生成到 build/artifacts/。Release 未签名时，首次打开可能需要在“系统设置 → 隐私与安全性”中允许。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

SCHEME="DeepSeekBalance"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/build/ReleaseDerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/build/artifacts}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
SKIP_BUILD=false

print_usage() {
  cat <<'EOF'
用法：
  ./scripts/package_app.sh              构建 Release 并生成 ZIP、PKG、DMG、校验文件
  ./scripts/package_app.sh --skip-build 使用已有的 Release .app 直接打包

环境变量：
  VERSION=1.0.0
  DERIVED_DATA=/tmp/deepseek-derived-data
  OUTPUT_DIR=/tmp/deepseek-artifacts
  CODE_SIGNING_ALLOWED=NO
EOF
}

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "未知参数：$arg" >&2; print_usage >&2; exit 1 ;;
  esac
done

if [ -z "${VERSION:-}" ]; then
  BUILD_SETTINGS="$(xcodebuild \
    -project DeepSeekBalance.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -showBuildSettings)"
  VERSION="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '$1 ~ /MARKETING_VERSION$/ { print $2; exit }')"
fi

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "错误：VERSION 必须是数字版本号，例如 1.0.0；当前为：$VERSION" >&2
  exit 1
fi

"$PROJECT_DIR/scripts/check_submodule.sh"

if [ "$SKIP_BUILD" = false ]; then
  echo "==> 构建 $SCHEME ($CONFIGURATION) ..."
  xcodebuild \
    -project DeepSeekBalance.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    build
fi

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/DeepSeekBalance.app"
if [ ! -d "$APP_PATH" ]; then
  echo "错误：找不到应用包：$APP_PATH" >&2
  echo "请先执行 Release 构建，或不要使用 --skip-build。" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
ARCHIVE_BASENAME="DeepSeekBalance-v$VERSION-macOS"
ZIP_PATH="$OUTPUT_DIR/$ARCHIVE_BASENAME.zip"
PKG_PATH="$OUTPUT_DIR/$ARCHIVE_BASENAME.pkg"
DMG_PATH="$OUTPUT_DIR/$ARCHIVE_BASENAME.dmg"
CHECKSUM_PATH="$OUTPUT_DIR/SHA256SUMS"

echo "==> 生成 ZIP ..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> 生成一键安装 PKG（安装到 /Applications） ..."
pkgbuild \
  --component "$APP_PATH" \
  --install-location /Applications \
  --identifier "com.jxz.deepseekbalance" \
  --version "$VERSION" \
  "$PKG_PATH"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deepseekbalance-dmg.XXXXXX")"
cleanup() {
  if [ -n "${STAGING_DIR:-}" ] && [[ "$STAGING_DIR" == "${TMPDIR:-/tmp}/deepseekbalance-dmg."* ]] && [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
}
trap cleanup EXIT

echo "==> 生成 DMG（拖入 Applications 即可安装） ..."
ditto "$APP_PATH" "$STAGING_DIR/DeepSeekBalance.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "DeepSeekBalance $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "==> 生成 SHA256SUMS ..."
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$ZIP_PATH")"
  shasum -a 256 "$(basename "$PKG_PATH")"
  shasum -a 256 "$(basename "$DMG_PATH")"
) > "$CHECKSUM_PATH"

echo "==> 打包完成："
printf '    %s\n' "$ZIP_PATH" "$PKG_PATH" "$DMG_PATH" "$CHECKSUM_PATH"
