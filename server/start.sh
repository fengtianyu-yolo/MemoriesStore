#!/usr/bin/env bash
# MemoryStore 服务端启动脚本
set -euo pipefail

# x/crypto 等依赖要求 Go >= 1.26；本机若只有 1.25，自动下载工具链
export PATH="/usr/local/go/bin:/opt/homebrew/bin:${PATH:-}"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export GOSUMDB="${GOSUMDB:-sum.golang.google.cn}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-go1.26.0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

SRC_BIN="$ROOT_DIR/bin/memorystore"
# 拷到 /tmp 再清 quarantine + adhoc 签名，规避 Gatekeeper 卡在 _dyld_start
RUN_BIN="${MEMORYSTORE_RUN_BIN:-/tmp/memorystore-clean}"
RUN_DIR="$ROOT_DIR/run"
PID_FILE="$RUN_DIR/memorystore.pid"
LOG_FILE="${MEMORYSTORE_LOG_FILE:-$RUN_DIR/server.log}"
CONFIG="${MEMORYSTORE_CONFIG:-$ROOT_DIR/configs/config.example.yaml}"
LISTEN_PORT="${MEMORYSTORE_PORT:-10002}"

mkdir -p "$RUN_DIR" "$ROOT_DIR/bin"

is_listening() {
  lsof -nP -iTCP:"$LISTEN_PORT" -sTCP:LISTEN >/dev/null 2>&1
}

is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null && is_listening; then
      return 0
    fi
    # 进程在但不监听：多为 Gatekeeper 卡住，清掉后允许重启
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "检测到僵尸进程 (pid=$pid，未监听 :$LISTEN_PORT)，正在清理…"
      kill "$pid" 2>/dev/null || true
      sleep 0.5
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
  return 1
}

prepare_run_bin() {
  if [[ ! -x "$SRC_BIN" ]]; then
    echo "找不到可执行文件: $SRC_BIN" >&2
    exit 1
  fi
  cp "$SRC_BIN" "$RUN_BIN"
  xattr -c "$RUN_BIN" 2>/dev/null || true
  codesign --force --sign - "$RUN_BIN" >/dev/null 2>&1 || true
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
if [[ ! -x "$SRC_BIN" ]]; then
  need_build=1
elif [[ -n "$(find "$ROOT_DIR/cmd" "$ROOT_DIR/internal" "$ROOT_DIR/pkg" -type f -name '*.go' -newer "$SRC_BIN" 2>/dev/null | head -1)" ]]; then
  need_build=1
fi

if [[ "$need_build" -eq 1 ]]; then
  echo "编译 MemoryStore…"
  go build -o "$SRC_BIN" ./cmd/memorystore
fi

echo "准备运行二进制（清除 quarantine）…"
prepare_run_bin

echo "启动 MemoryStore…"
echo "  binary: $RUN_BIN"
echo "  config: $CONFIG"
echo "  log:    $LOG_FILE"

nohup "$RUN_BIN" -config "$CONFIG" >>"$LOG_FILE" 2>&1 &
echo $! >"$PID_FILE"

sleep 0.8
if ! is_running; then
  echo "启动失败，请查看日志: $LOG_FILE" >&2
  rm -f "$PID_FILE"
  exit 1
fi

echo "已启动 (pid=$(cat "$PID_FILE"))"
echo "健康检查: curl -s http://127.0.0.1:${LISTEN_PORT}/health"
