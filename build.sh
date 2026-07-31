#!/bin/bash
# DeepSeekBalance 本地构建脚本
#
# 用法：
#   ./build.sh                     Debug 构建（免签名，默认）
#   ./build.sh --release           Release 构建
#   ./build.sh --test              运行本地单元测试（Debug）
#   ./build.sh --clean             清理并构建 Debug
#   ./build.sh --all               清理、构建 Debug + Release、运行测试
#
# 可覆盖环境变量：
#   DERIVED_DATA=/tmp/dd ./build.sh
#   CODE_SIGNING_ALLOWED=YES ./build.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

SCHEME="DeepSeekBalance"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="platform=macOS"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/build/DerivedData}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"

RUN_TESTS=false
DO_CLEAN=false

usage() {
  cat <<'EOF'
用法：
  ./build.sh                     Debug 构建（免签名，默认）
  ./build.sh --release           Release 构建
  ./build.sh --test              运行本地单元测试（Debug）
  ./build.sh --clean             清理并构建 Debug
  ./build.sh --all               清理、构建 Debug 与 Release、运行测试
EOF
  exit 1
}

check_submodule() {
  if [ ! -f "Vendor/LevelDB/.git" ] && [ ! -d "Vendor/LevelDB/.git" ]; then
    echo "错误：LevelDB submodule 未初始化。"
    echo "请运行：git submodule update --init --recursive"
    exit 1
  fi
  local submodule_status=""
  submodule_status="$(git submodule status Vendor/LevelDB 2>/dev/null || true)"
  case "$submodule_status" in
    -*|"")
      echo "错误：LevelDB submodule 状态异常（$status）。"
      echo "请运行：git submodule update --init --recursive"
      exit 1
      ;;
  esac
}

run_build() {
  local config="$1"
  echo "==> 构建 $SCHEME ($config) ..."
  if [ "$DO_CLEAN" = true ]; then
    xcodebuild \
      -project DeepSeekBalance.xcodeproj \
      -scheme "$SCHEME" \
      -configuration "$config" \
      -destination "$DESTINATION" \
      -derivedDataPath "$DERIVED_DATA" \
      CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
      clean build
  else
    xcodebuild \
      -project DeepSeekBalance.xcodeproj \
      -scheme "$SCHEME" \
      -configuration "$config" \
      -destination "$DESTINATION" \
      -derivedDataPath "$DERIVED_DATA" \
      CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
      build
  fi
  echo "==> $config 构建成功：$DERIVED_DATA/Build/Products/$config/DeepSeekBalance.app"
}

run_tests() {
  echo "==> 运行本地单元测试 ..."
  xcodebuild \
    -project DeepSeekBalance.xcodeproj \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    test
}

for arg in "$@"; do
  case "$arg" in
    --release) CONFIGURATION="Release" ;;
    --test) RUN_TESTS=true ;;
    --clean) DO_CLEAN=true ;;
    --all) RUN_TESTS=true; DO_CLEAN=true ;;
    -h|--help) usage ;;
    *)
      echo "未知参数：$arg"
      usage
      ;;
  esac
done

check_submodule
run_build "$CONFIGURATION"
if [ "$RUN_TESTS" = true ]; then
  run_tests
fi
