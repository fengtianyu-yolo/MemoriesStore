# MemoryStore Server

Go + Gin 私有媒体库服务端，部署于家中 iMac。

## 快速启动

```bash
cd server
go mod tidy
./start.sh          # 后台启动（自动编译 bin/memorystore）
./stop.sh           # 停止服务
```

也可前台调试：

```bash
go run ./cmd/memorystore -config configs/config.example.yaml
```

默认监听见配置文件（示例为 `0.0.0.0:10002`），数据目录 `./data`，日志与 pid 在 `./run/`。

可选环境变量：

| 变量 | 说明 |
|------|------|
| `MEMORYSTORE_CONFIG` | 配置文件路径（默认 `configs/config.example.yaml`） |
| `MEMORYSTORE_LOG_FILE` | 日志路径（默认 `run/server.log`） |
| `MEMORYSTORE_STOP_TIMEOUT` | 停止等待秒数（默认 15） |

## 健康检查

```bash
curl http://127.0.0.1:10002/health
```

## 注册 / 登录

```bash
curl -s -X POST http://127.0.0.1:10002/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"demo","password":"password1","display_name":"Demo"}'

curl -s -X POST http://127.0.0.1:10002/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"demo","password":"password1"}'
```

登录响应中的 `access_token` 用于后续 `Authorization: Bearer <token>`。

## 删除媒体

```bash
# 单条
curl -s -X DELETE "http://127.0.0.1:10002/api/v1/media/{id}" \
  -H "Authorization: Bearer $TOKEN"

# 批量
curl -s -X POST "http://127.0.0.1:10002/api/v1/media/delete" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"media_ids":["id1","id2"]}'
```

会删除 DB 记录以及 originals / derivatives 文件。

## 媒体故事

```bash
# 更新故事
curl -s -X PATCH "http://127.0.0.1:10002/api/v1/media/{id}" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"story":"……","title":"暮色","place_name":"伦敦"}'

# AI 草稿（不落库）
curl -s -X POST "http://127.0.0.1:10002/api/v1/media/{id}/story/ai" \
  -H "Authorization: Bearer $TOKEN"
```

## 配置

见 `configs/config.example.yaml`。关键项：

| 配置项 | 环境变量 | 说明 |
|--------|----------|------|
| `data.root` | `MEMORYSTORE_DATA_ROOT` | SQLite / 日志等元数据目录 |
| `data.media_root` | `MEMORYSTORE_MEDIA_ROOT` | 原片与缩略图目录；空则与 `root` 相同 |
| `server.listen` | — | 监听地址 |
| `auth.register_mode` | — | 注册策略 |

外接硬盘示例：

```yaml
data:
  root: "./data"
  media_root: "/Volumes/MemoryStore"
```

或启动时：

```bash
MEMORYSTORE_MEDIA_ROOT=/Volumes/MemoryStore go run ./cmd/memorystore -config configs/config.example.yaml
```

请确保外接盘已挂载且进程可写；跨盘提交上传时会自动 fallback 为复制。
