#!/bin/bash
# DeepSeekBalance 命令行构建脚本
#
# 用法：
#   ./build.sh                     # Debug 构建（免签名）
#   CONFIGURATION=Release ./build.sh
#   DERIVED_DATA=/tmp/dd ./build.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

SCHEME="DeepSeekBalance"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="platform=macOS"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/build/DerivedData}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"

echo "==> 构建 $SCHEME ($CONFIGURATION) ..."
xcodebuild \
  -project DeepSeekBalance.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/DeepSeekBalance.app"
echo "==> 构建成功：$APP_PATH"
echo "==> 运行：open \"$APP_PATH\""
