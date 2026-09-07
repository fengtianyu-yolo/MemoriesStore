#!/usr/bin/env bash
# MemoryStore 服务端启动脚本
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

BIN="$ROOT_DIR/bin/memorystore"
RUN_DIR="$ROOT_DIR/run"
PID_FILE="$RUN_DIR/memorystore.pid"
LOG_FILE="${MEMORYSTORE_LOG_FILE:-$RUN_DIR/server.log}"
CONFIG="${MEMORYSTORE_CONFIG:-$ROOT_DIR/configs/config.example.yaml}"

mkdir -p "$RUN_DIR" "$ROOT_DIR/bin"

is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    rm -f "$PID_FILE"
  fi
  return 1
}

if is_running; then
  echo "MemoryStore 已在运行 (pid=$(cat "$PID_FILE"))"
  exit 0
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "找不到配置文件: $CONFIG" >&2
  exit 1
fi

# 无二进制或源码更新时重新编译
need_build=0
if [[ ! -x "$BIN" ]]; then
  need_build=1
elif [[ -n "$(find "$ROOT_DIR/cmd" "$ROOT_DIR/internal" "$ROOT_DIR/pkg" -type f -name '*.go' -newer "$BIN" 2>/dev/null | head -1)" ]]; then
  need_build=1
fi

if [[ "$need_build" -eq 1 ]]; then
  echo "编译 MemoryStore…"
  go build -o "$BIN" ./cmd/memorystore
fi

echo "启动 MemoryStore…"
echo "  config: $CONFIG"
echo "  log:    $LOG_FILE"

nohup "$BIN" -config "$CONFIG" >>"$LOG_FILE" 2>&1 &
echo $! >"$PID_FILE"

sleep 0.4
if ! is_running; then
  echo "启动失败，请查看日志: $LOG_FILE" >&2
  rm -f "$PID_FILE"
  exit 1
fi

echo "已启动 (pid=$(cat "$PID_FILE"))"
echo "健康检查: curl -s http://127.0.0.1:10002/health"
