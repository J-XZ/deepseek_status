#!/bin/bash
# 检查 LevelDB submodule 状态。退出 0 表示可用，非零表示不可构建。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

if [ ! -e "Vendor/LevelDB/.git" ]; then
  echo "错误：LevelDB submodule 未初始化。" >&2
  echo "请运行：git submodule update --init --recursive" >&2
  exit 1
fi

submodule_status="$(git submodule status Vendor/LevelDB 2>/dev/null || true)"

case "$submodule_status" in
  -*)
    echo "错误：LevelDB submodule 未初始化（$submodule_status）。" >&2
    echo "请运行：git submodule update --init --recursive" >&2
    exit 1
    ;;
  "+"*)
    echo "错误：LevelDB submodule checkout 与仓库记录不一致（$submodule_status）。" >&2
    echo "请运行：git submodule update --init --recursive" >&2
    exit 1
    ;;
  U*)
    echo "错误：LevelDB submodule 存在冲突（$submodule_status）。" >&2
    echo "请先解决冲突，再运行：git submodule update --init --recursive" >&2
    exit 1
    ;;
  "")
    echo "错误：无法读取 LevelDB submodule 状态。" >&2
    echo "请运行：git submodule update --init --recursive" >&2
    exit 1
    ;;
esac

exit 0
