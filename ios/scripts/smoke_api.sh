#!/usr/bin/env bash
# 模拟客户端联调路径：注册→登录→设备→check→upload→list→share
set -euo pipefail
BASE="${MEMORYSTORE_BASE_URL:-http://120.48.22.80:10002}"
USER="ios_client_$(date +%s)"
PASS="password1"

echo "== health =="
curl -sf "$BASE/health" | head -c 200; echo

echo "== register/login =="
curl -sf -X POST "$BASE/api/v1/auth/register" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\",\"display_name\":\"iOS\"}" >/dev/null
LOGIN=$(curl -sf -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}")
TOKEN=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['data']['access_token'])" "$LOGIN")
AUTH="Authorization: Bearer $TOKEN"

echo "== device =="
DEV=$(curl -sf -X POST "$BASE/api/v1/devices/register" -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"name":"iPhone Simulator","platform":"ios","client_device_key":"sim-key-1"}')
echo "$DEV" | head -c 200; echo

python3 - <<'PY'
import hashlib
p='/tmp/ms-ios-client.jpg'
open(p,'wb').write(b'\xff\xd8\xff\xe0'+b'A'*2048+b'\xff\xd9')
h=hashlib.sha256(open(p,'rb').read()).hexdigest()
open('/tmp/ms-ios.hash','w').write(h)
print(h, len(open(p,'rb').read()))
PY
HASH=$(cat /tmp/ms-ios.hash)
SIZE=$(wc -c </tmp/ms-ios-client.jpg | tr -d ' ')

echo "== check =="
curl -sf -X POST "$BASE/api/v1/media/check" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"hashes\":[\"$HASH\"]}"; echo

echo "== upload =="
INIT=$(curl -sf -X POST "$BASE/api/v1/upload/init" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"content_hash\":\"$HASH\",\"size_bytes\":$SIZE,\"mime_type\":\"image/jpeg\",\"media_type\":\"photo\",\"taken_at\":\"2026-09-04T12:00:00Z\"}")
UPLOAD_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['data']['upload_id'])" "$INIT")
curl -sf -X PUT "$BASE/api/v1/upload/$UPLOAD_ID/chunk" -H "$AUTH" -H 'X-Chunk-Offset: 0' --data-binary @/tmp/ms-ios-client.jpg >/dev/null
DONE=$(curl -sf -X POST "$BASE/api/v1/upload/$UPLOAD_ID/complete" -H "$AUTH")
MID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['data']['media_id'])" "$DONE")
echo "media_id=$MID"

echo "== list =="
curl -sf "$BASE/api/v1/media?limit=5" -H "$AUTH"; echo

echo "== share =="
curl -sf -X POST "$BASE/api/v1/shares" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"title\":\"from-ios\",\"scope_type\":\"media_ids\",\"media_ids\":[\"$MID\"],\"expires_in_days\":7}"; echo

echo "OK client API path verified"
