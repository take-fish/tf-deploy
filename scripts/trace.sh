#!/usr/bin/env bash
# 按链路编号查询集中日志的便捷入口，实际逻辑见 trace.py
#
# 用法：
#   bash scripts/trace.sh <编号> [--env prod|test|all] [--lines 30|50|100] [--range 24h]
#   CONSOLE_URL=http://127.0.0.1:8301 bash scripts/trace.sh <编号>
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Windows 上 python3 可能是应用商店占位符：能通过 command -v，
# 但真正执行时直接失败。必须以“带参数执行”作为探测条件。
if [ -z "${PYTHON_BIN:-}" ]; then
  for candidate in python3 python py; do
    if command -v "$candidate" >/dev/null 2>&1 &&
      "$candidate" -c 'import sys' >/dev/null 2>&1; then
      PYTHON_BIN="$candidate"
      break
    fi
  done
fi

if [ -z "${PYTHON_BIN:-}" ]; then
  echo "未找到可用的 Python 3 解释器，请通过 PYTHON_BIN 指定路径。" >&2
  exit 1
fi

if ! "$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
  echo "PYTHON_BIN=$PYTHON_BIN 需要 Python 3.8 或更高版本。" >&2
  exit 1
fi

# Windows 控制台默认按本地代码页输出，中文会乱码；统一按 UTF-8 输出。
export PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/trace.py" "$@"
