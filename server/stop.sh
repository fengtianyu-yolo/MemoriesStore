#!/usr/bin/env bash
# MemoryStore 服务端停止脚本
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$ROOT_DIR/run/memorystore.pid"
TIMEOUT_SEC="${MEMORYSTORE_STOP_TIMEOUT:-15}"

if [[ ! -f "$PID_FILE" ]]; then
  # 兜底：按进程名查找（含 /tmp/memorystore-clean）
  pids="$(pgrep -f 'memorystore-clean|[/]bin/memorystore' 2>/dev/null || true)"
  if [[ -z "$pids" ]]; then
    echo "MemoryStore 未在运行"
    exit 0
  fi
  echo "未找到 pid 文件，按进程名停止: $pids"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 1
  # shellcheck disable=SC2086
  kill -0 $pids 2>/dev/null && kill -9 $pids 2>/dev/null || true
  echo "已停止"
  exit 0
fi

pid="$(cat "$PID_FILE" 2>/dev/null || true)"
if [[ -z "${pid:-}" ]]; then
  rm -f "$PID_FILE"
  echo "pid 文件为空，已清理"
  exit 0
fi

if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$PID_FILE"
  echo "进程已不存在 (pid=$pid)，已清理 pid 文件"
  exit 0
fi

echo "停止 MemoryStore (pid=$pid)…"
kill "$pid" 2>/dev/null || true

for ((i = 0; i < TIMEOUT_SEC; i++)); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    echo "已停止"
    exit 0
  fi
  sleep 1
done

echo "优雅退出超时，强制结束…"
kill -9 "$pid" 2>/dev/null || true
rm -f "$PID_FILE"
echo "已强制停止"
