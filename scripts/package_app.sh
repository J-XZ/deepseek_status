#!/bin/bash
# 构建并打包可分发的 macOS 安装文件：ZIP、PKG、DMG 与 SHA256SUMS。
#
# 用法：
#   ./scripts/package_app.sh
#   VERSION=1.0.0 ./scripts/package_app.sh
#   ./scripts/package_app.sh --skip-build
#
# 默认生成到 build/artifacts/。公开分发时应使用 Developer ID 签名并启用 notarization。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

SCHEME="DeepSeekBalance"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/build/ReleaseDerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/build/artifacts}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
CODE_SIGN_STYLE="${CODE_SIGN_STYLE:-}"
NOTARIZE="${NOTARIZE:-NO}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
DEVELOPER_ID_INSTALLER="${DEVELOPER_ID_INSTALLER:-}"
SKIP_BUILD=false

XCODEBUILD_SIGNING_ARGS=("CODE_SIGNING_ALLOWED=$CODE_SIGNING_ALLOWED")
if [ "$CODE_SIGNING_ALLOWED" = "YES" ]; then
  if [ -n "$CODE_SIGN_IDENTITY" ]; then
    XCODEBUILD_SIGNING_ARGS+=("CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY")
  fi
  if [ -n "$DEVELOPMENT_TEAM" ]; then
    XCODEBUILD_SIGNING_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
  fi
  if [ -n "$CODE_SIGN_STYLE" ]; then
    XCODEBUILD_SIGNING_ARGS+=("CODE_SIGN_STYLE=$CODE_SIGN_STYLE")
  fi
fi

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
  CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)"
  DEVELOPMENT_TEAM=TEAMID
  NOTARIZE=YES
  APPLE_ID=developer@example.com
  APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
  APPLE_TEAM_ID=TEAMID
  DEVELOPER_ID_INSTALLER="Developer ID Installer: Example (TEAMID)"
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

if [ "$NOTARIZE" = "YES" ] || [ "$NOTARIZE" = "true" ] || [ "$NOTARIZE" = "TRUE" ]; then
  if [ "$CODE_SIGNING_ALLOWED" != "YES" ]; then
    echo "错误：NOTARIZE=YES 要求 CODE_SIGNING_ALLOWED=YES。" >&2
    exit 1
  fi
  if [ -z "$CODE_SIGN_IDENTITY" ]; then
    echo "错误：NOTARIZE=YES 要求 CODE_SIGN_IDENTITY 为 Developer ID Application 证书。" >&2
    exit 1
  fi
  if [ -z "$DEVELOPER_ID_INSTALLER" ]; then
    echo "错误：NOTARIZE=YES 要求 DEVELOPER_ID_INSTALLER 为 Developer ID Installer 证书。" >&2
    exit 1
  fi
  if [ -z "$NOTARYTOOL_PROFILE" ] && { [ -z "$APPLE_ID" ] || [ -z "$APPLE_APP_SPECIFIC_PASSWORD" ] || [ -z "$APPLE_TEAM_ID" ]; }; then
    echo "错误：请设置 NOTARYTOOL_PROFILE，或同时设置 APPLE_ID、APPLE_APP_SPECIFIC_PASSWORD、APPLE_TEAM_ID。" >&2
    exit 1
  fi
fi

is_notarization_enabled() {
  [ "$NOTARIZE" = "YES" ] || [ "$NOTARIZE" = "true" ] || [ "$NOTARIZE" = "TRUE" ]
}

submit_for_notarization() {
  local artifact="$1"
  echo "==> 提交 Apple notarization：$(basename "$artifact") ..."
  if [ -n "$NOTARYTOOL_PROFILE" ]; then
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARYTOOL_PROFILE" \
      --wait
  else
    xcrun notarytool submit "$artifact" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait
  fi
}

"$PROJECT_DIR/scripts/check_submodule.sh"

if [ "$SKIP_BUILD" = false ]; then
  echo "==> 构建 $SCHEME ($CONFIGURATION) ..."
  xcodebuild \
    -project DeepSeekBalance.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    "${XCODEBUILD_SIGNING_ARGS[@]}" \
    build
fi

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/DeepSeekBalance.app"
if [ ! -d "$APP_PATH" ]; then
  echo "错误：找不到应用包：$APP_PATH" >&2
  echo "请先执行 Release 构建，或不要使用 --skip-build。" >&2
  exit 1
fi

if [ "$CODE_SIGNING_ALLOWED" = "YES" ]; then
  echo "==> 验证代码签名 ..."
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

mkdir -p "$OUTPUT_DIR"
ARCHIVE_BASENAME="DeepSeekBalance-v$VERSION-macOS"
ZIP_PATH="$OUTPUT_DIR/$ARCHIVE_BASENAME.zip"
PKG_PATH="$OUTPUT_DIR/$ARCHIVE_BASENAME.pkg"
DMG_PATH="$OUTPUT_DIR/$ARCHIVE_BASENAME.dmg"
CHECKSUM_PATH="$OUTPUT_DIR/SHA256SUMS"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deepseekbalance-package.XXXXXX")"
cleanup() {
  if [ -n "${WORK_DIR:-}" ] && [[ "$WORK_DIR" == "${TMPDIR:-/tmp}/deepseekbalance-package."* ]] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

if is_notarization_enabled; then
  NOTARY_ZIP_PATH="$WORK_DIR/$ARCHIVE_BASENAME-notary.zip"
  echo "==> 准备 App notarization 文件 ..."
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP_PATH"
  submit_for_notarization "$NOTARY_ZIP_PATH"
  echo "==> 将 notarization ticket 固化到 App ..."
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
fi

echo "==> 生成 ZIP ..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> 生成一键安装 PKG（安装到 /Applications） ..."
pkgbuild \
  --component "$APP_PATH" \
  --install-location /Applications \
  --identifier "com.jxz.deepseekbalance" \
  --version "$VERSION" \
  "$WORK_DIR/$ARCHIVE_BASENAME-unsigned.pkg"

if is_notarization_enabled; then
  productsign \
    --sign "$DEVELOPER_ID_INSTALLER" \
    "$WORK_DIR/$ARCHIVE_BASENAME-unsigned.pkg" \
    "$PKG_PATH"
  submit_for_notarization "$PKG_PATH"
  xcrun stapler staple "$PKG_PATH"
  xcrun stapler validate "$PKG_PATH"
else
  mv "$WORK_DIR/$ARCHIVE_BASENAME-unsigned.pkg" "$PKG_PATH"
fi

STAGING_DIR="$WORK_DIR/dmg-staging"
mkdir -p "$STAGING_DIR"

echo "==> 生成 DMG（拖入 Applications 即可安装） ..."
ditto "$APP_PATH" "$STAGING_DIR/DeepSeekBalance.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "DeepSeekBalance $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

if is_notarization_enabled; then
  submit_for_notarization "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "==> 生成 SHA256SUMS ..."
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$ZIP_PATH")"
  shasum -a 256 "$(basename "$PKG_PATH")"
  shasum -a 256 "$(basename "$DMG_PATH")"
) > "$CHECKSUM_PATH"

echo "==> 打包完成："
printf '    %s\n' "$ZIP_PATH" "$PKG_PATH" "$DMG_PATH" "$CHECKSUM_PATH"
