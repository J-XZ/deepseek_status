#!/bin/bash
# build.sh 行为测试：用假的 git/xcodebuild 在临时目录中验证参数与 submodule 检查。
# 不执行真实构建，不修改仓库。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/Vendor/LevelDB" "$TMP/repo/scripts" "$TMP/bin" "$TMP/log"
touch "$TMP/repo/Vendor/LevelDB/.git"
cp "$ROOT/build.sh" "$TMP/repo/build.sh"
cp "$ROOT/scripts/check_submodule.sh" "$TMP/repo/scripts/check_submodule.sh"
chmod +x "$TMP/repo/build.sh" "$TMP/repo/scripts/check_submodule.sh"

cat >"$TMP/bin/git" <<'EOF'
#!/bin/bash
if [ "$1" = "submodule" ] && [ "$2" = "status" ]; then
  printf '%s\n' "${FAKE_SUBMODULE_STATUS:- 99b3c03b3284f5886f9ef9a4ef703d57373e61be Vendor/LevelDB (1.23)}"
fi
exit 0
EOF

cat >"$TMP/bin/xcodebuild" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$XCODE_LOG"
exit 0
EOF

chmod +x "$TMP/bin/git" "$TMP/bin/xcodebuild"

export PATH="$TMP/bin:$PATH"
export XCODE_LOG="$TMP/log/xcode.log"

fail() {
  echo "build.sh 测试失败：$1" >&2
  exit 1
}

cd "$TMP/repo"

# --help 返回 0
./build.sh --help >/dev/null 2>&1 || fail "--help 应返回 0"

# 非法参数返回非零
if ./build.sh --bogus >/dev/null 2>&1; then
  fail "非法参数应返回非零"
fi

# 默认只构建 Debug
: >"$XCODE_LOG"
./build.sh >/dev/null 2>&1
grep -q -- "-configuration Debug" "$XCODE_LOG" || fail "默认应构建 Debug"
grep -q -- "-configuration Release" "$XCODE_LOG" && fail "默认不应构建 Release"
grep -q "test" "$XCODE_LOG" && fail "默认不应运行测试"

# --release 只构建 Release
: >"$XCODE_LOG"
./build.sh --release >/dev/null 2>&1
grep -q -- "-configuration Release" "$XCODE_LOG" || fail "--release 应构建 Release"
grep -q -- "-configuration Debug" "$XCODE_LOG" && fail "--release 不应构建 Debug"

# --test 构建 Debug 并运行测试
: >"$XCODE_LOG"
./build.sh --test >/dev/null 2>&1
grep -q -- "-configuration Debug" "$XCODE_LOG" || fail "--test 应构建 Debug"
grep -q "test$" "$XCODE_LOG" || grep -q "^test$" "$XCODE_LOG" || grep -q " test$" "$XCODE_LOG" || grep -q "\btest\b" "$XCODE_LOG" || fail "--test 应运行测试"
grep -q -- "-parallel-testing-enabled NO" "$XCODE_LOG" || fail "--test 应串行运行测试"
grep -q -- "-maximum-parallel-testing-workers 1" "$XCODE_LOG" || fail "--test 应限制为一个测试 worker"

# --clean 执行 clean build
: >"$XCODE_LOG"
./build.sh --clean >/dev/null 2>&1
grep -q "\bclean\b" "$XCODE_LOG" || fail "--clean 应执行 clean"

# --all 必须执行 clean、Debug、Release、test、analyze
: >"$XCODE_LOG"
./build.sh --all >/dev/null 2>&1
grep -q "\bclean\b" "$XCODE_LOG" || fail "--all 应执行 clean"
grep -q -- "-configuration Debug" "$XCODE_LOG" || fail "--all 应构建 Debug"
grep -q -- "-configuration Release" "$XCODE_LOG" || fail "--all 应构建 Release"
grep -q "\banalyze\b" "$XCODE_LOG" || fail "--all 应运行 analyze"
grep -q "\btest\b" "$XCODE_LOG" || fail "--all 应运行测试"

# submodule 未初始化
rm -rf "$TMP/repo/Vendor/LevelDB/.git"
if ./build.sh >/dev/null 2>&1; then
  fail "submodule 未初始化时应失败"
fi
mkdir -p "$TMP/repo/Vendor/LevelDB/.git"

# submodule SHA mismatch（+ 前缀）
FAKE_SUBMODULE_STATUS="+99b3c03b3284f5886f9ef9a4ef703d57373e61be Vendor/LevelDB (1.23)" \
  ./build.sh >/dev/null 2>&1 && fail "submodule mismatch 时应失败"

# submodule 冲突（U 前缀）
FAKE_SUBMODULE_STATUS="U99b3c03b3284f5886f9ef9a4ef703d57373e61be Vendor/LevelDB (1.23)" \
  ./build.sh >/dev/null 2>&1 && fail "submodule 冲突时应失败"

echo "build.sh 行为测试全部通过"
