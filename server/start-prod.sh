#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
BIN="/tmp/memorystore-clean"
SRC="$ROOT_DIR/bin/memorystore"
RUN_DIR="$ROOT_DIR/run"
PID_FILE="$RUN_DIR/memorystore.pid"
LOG_FILE="$RUN_DIR/server.log"
CONFIG="${MEMORYSTORE_CONFIG:-$ROOT_DIR/configs/config.example.yaml}"
mkdir -p "$RUN_DIR" /Volumes/Library/MemoriesStore
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "already running pid=$(cat "$PID_FILE")"
  exit 0
fi
# prefer unsigned-clean copy to avoid Gatekeeper hang
if [[ ! -x "$BIN" ]] || [[ "$SRC" -nt "$BIN" ]]; then
  cp "$SRC" "$BIN"
  xattr -c "$BIN" 2>/dev/null || true
  codesign --force --sign - "$BIN" 2>/dev/null || true
fi
nohup "$BIN" -config "$CONFIG" >>"$LOG_FILE" 2>&1 &
echo $! >"$PID_FILE"
sleep 0.5
echo "started pid=$(cat "$PID_FILE")"
