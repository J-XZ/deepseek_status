#!/bin/bash
# DeepSeekBalance 本地构建脚本
#
# 用法：
#   ./build.sh                     Debug 构建（免签名，默认）
#   ./build.sh --release           Release 构建
#   ./build.sh --test              运行本地单元测试（Debug）
#   ./build.sh --clean             清理并构建 Debug
#   ./build.sh --all               清理、构建 Debug + Release、运行测试与静态分析
#
# 可覆盖环境变量：
#   DERIVED_DATA=/tmp/dd ./build.sh
#   CODE_SIGNING_ALLOWED=YES ./build.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

SCHEME="DeepSeekBalance"
DESTINATION="platform=macOS"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_DIR/build/DerivedData}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"

RUN_TESTS=false
RUN_ANALYZE=false
DO_CLEAN=false
ALL_MODE=false

print_usage() {
  cat <<'EOF'
用法：
  ./build.sh                     Debug 构建（免签名，默认）
  ./build.sh --release           Release 构建
  ./build.sh --test              运行本地单元测试（Debug）
  ./build.sh --clean             清理并构建 Debug
  ./build.sh --all               清理、构建 Debug + Release、运行测试与静态分析
EOF
}

usage_exit_ok() {
  print_usage
  exit 0
}

usage_exit_error() {
  print_usage
  exit 1
}

run_build() {
  local config="$1"
  echo "==> 构建 $SCHEME ($config) ..."
  if [ "$DO_CLEAN" = true ] || [ "$ALL_MODE" = true ]; then
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

run_analyze() {
  echo "==> 运行静态分析（Debug） ..."
  xcodebuild \
    -project DeepSeekBalance.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    analyze
}

for arg in "$@"; do
  case "$arg" in
    --release) CONFIGURATION="Release" ;;
    --test) RUN_TESTS=true ;;
    --clean) DO_CLEAN=true ;;
    --all)
      ALL_MODE=true
      RUN_TESTS=true
      RUN_ANALYZE=true
      ;;
    -h|--help) usage_exit_ok ;;
    *)
      echo "未知参数：$arg" >&2
      usage_exit_error
      ;;
  esac
done

CONFIGURATION="${CONFIGURATION:-Debug}"

"$PROJECT_DIR/scripts/check_submodule.sh"

if [ "$ALL_MODE" = true ]; then
  echo "==> [1/5] 清理 DerivedData ..."
  xcodebuild \
    -project DeepSeekBalance.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
    clean >/dev/null
  echo "==> [2/5] Debug 构建 ..."
  DO_CLEAN=false
  run_build Debug
  echo "==> [3/5] Release 构建 ..."
  run_build Release
  echo "==> [4/5] 单元测试 ..."
  run_tests
  echo "==> [5/5] 静态分析 ..."
  run_analyze
  echo "==> build.sh --all 全部完成：Debug、Release、测试、分析均已执行。"
  exit 0
fi

if [ "$DO_CLEAN" = true ]; then
  echo "==> 清理并构建 $CONFIGURATION ..."
fi
run_build "$CONFIGURATION"
if [ "$RUN_TESTS" = true ]; then
  run_tests
fi
if [ "$RUN_ANALYZE" = true ]; then
  run_analyze
fi
