# MemoryStore 服务端方案设计

> 版本：v0.8  
> 日期：2026-09-04  
> 依据：[MemoryStore 设计文档 v0.7](./MemoryStore-设计文档.md)  
> 范围：运行在家中 iMac 上的 MemoryStore Server（不含云服务器 Nginx/FRP 运维细节，仅描述对接约定）

---

## 第一部分：整体方案设计

### 1. 目标与边界

#### 1.1 服务端要解决什么

MemoryStore Server 是私有媒体库的**权威数据端**，负责：

1. 多用户账号注册、登录与会话管理（前期密码，后期短信）  
2. 在用户维度可靠接收照片/视频上传，校验后落盘  
3. 维护**按用户隔离**的元数据，生成缩略图  
4. 向已登录 App 提供该用户的时间轴浏览、原图下载与**媒体永久删除**  
5. 向 H5 提供受控的只读分享访问（访客无需账号）  
6. 在 FRP 隧道后方稳定对外提供 HTTP API  

#### 1.2 明确不做

| 不做 | 原因 |
|------|------|
| 在云服务器落原片 | 私有数据只存 iMac |
| 社交 feed / 评论点赞 | 非本期目标；账号仅服务媒体归属 |
| 扫描手机相册 | 属于 iOS App |
| 删除手机原片 | 属于 iOS App；服务端只负责权威副本的增删 |
| 首期短信登录 | 后期实现；本期预留表结构与接口形状 |
| AI 聚类、人脸 | 后续增强 |

#### 1.3 运行位置

```
云服务器 (frps + HTTPS 反代)
        │ FRP
        ▼
家中 iMac
  ├── frpc
  └── MemoryStore Server   ← 本文档对象
        ├── HTTP API (:8080 内网)
        ├── 静态 H5
        ├── SQLite
        └── 磁盘 originals / derivatives
```

App / H5 统一访问公网域名；请求经云服务器转到本机 `:8080`。

---

### 2. 技术栈选型

| 层级 | 选型 | 选型理由 |
|------|------|----------|
| 语言 / 运行时 | **Go 1.22+** | 单二进制部署；原生适合流式上传/下载；并发模型简单；在 macOS 上运维成本低 |
| Web 框架 | **Gin**（`github.com/gin-gonic/gin`） | 生态成熟、资料多、开发效率高；本项目瓶颈在磁盘/带宽而非框架，Gin 足够 |
| 元数据库 | **SQLite**（`modernc.org/sqlite` 或 `mattn/go-sqlite3`） | 单机足够；零运维；与文件目录同机备份即可 |
| 迁移 | **golang-migrate** 或内嵌 SQL 迁移 | 版本化 schema |
| 配置 | 环境变量 + `config.yaml` | 存储根路径、端口、注册策略、Token TTL 等可改 |
| 日志 | **slog**（标准库）或 Gin 中间件 + slog | 结构化 JSON/文本日志 |
| 密码哈希 | **argon2id**（`golang.org/x/crypto/argon2`） | 行业推荐；备选 bcrypt |
| 缩略图 · 图片 | **nfnt/resize** 或调用系统 **`sips`** | macOS 上 `sips` 零依赖；Go 库则部署更纯 |
| 缩略图 · 视频封面 | **ffmpeg**（本机安装） | 抽第一帧/指定秒为封面 |
| 异步任务 | **进程内 worker + DB 任务表** | 首期不引入 Redis；崩溃可恢复 |
| 对象 ID | **ULID** 或 **UUID v7** | 可排序，便于按时间排查 |
| 内容哈希 | **SHA-256** | 秒传与完整性校验 |
| 静态 H5 | 构建产物由 Gin `Static` / `StaticFS` 或 `embed` 托管 | 同域部署，分享链接简单 |
| 进程守护 | **launchd**（macOS）或 Docker | iMac 开机自启；数据目录 bind mount 到外盘 |
| 反向入口 | 已有 **FRP** + 云端 Nginx/Caddy | 业务进程只监听本机 |

**框架说明：** 上传分片与原图下载优先使用 `c.Request.Body` 流式读写，以及 `http.ServeContent` / `c.File` 等，避免把大文件一次性读进内存。中间件链：RequestID → Recover → 日志 → CORS（若需要）→ `RequireUser` / `RequireShare`。

**备选：** 若更熟悉标准库风格可用 chi；若更熟悉 Node，可用 Fastify + better-sqlite3 + sharp。业务模块划分与本文一致即可。本文按 **Go + Gin** 展开。

---

### 3. 功能全景

服务端按模块划分如下（均为首期范围）：

```
MemoryStore Server
├── 0. 基础能力
│   ├── 配置加载 / 健康检查
│   ├── 统一错误与鉴权中间件
│   └── 静态 H5 托管
├── 1. 用户账号与会话鉴权（前期密码；后期短信预留）
├── 1b. 设备登记（从属于用户）
├── 2. 媒体去重探测（秒传，用户内）
├── 3. 分片上传与入库校验
├── 4. 媒体元数据与对账清单
├── 5. 缩略图 / 派生文件生成
├── 6. 浏览与原图下载（登录用户）
├── 6b. 删除媒体（登录用户：原片+派生+DB）
├── 6c. 媒体故事 / 文案（登录用户）
├── 7. 分享链接管理（登录用户）
├── 8. 公开只读访问（H5）
└── 9. 存储监控（P1，可后置接口）
```

与产品文档优先级对齐：

| 模块 | 优先级 | 主要消费方 |
|------|--------|------------|
| 健康检查 | P0 | 云端探活 / 运维 |
| 用户注册/登录/会话 | P0 | iOS App |
| 设备登记 | P0 | iOS App |
| 上传（含用户内秒传） | P0 | iOS App |
| 元数据 / manifest | P0 | iOS App |
| 缩略图生成 | P0 | App / H5 间接依赖 |
| 浏览与下载 | P0 | iOS App |
| **删除媒体** | P0 | iOS App（编辑「仅云端」） |
| **媒体故事** | P0 | iOS App 大图展示 / 编辑 |
| 分享 + 公开只读 | P0 | App 创建 / H5 消费 |
| 手机号验证码登录 | P2 | iOS App（后期） |
| 存储监控 | P1 | 用户运维 |

---

### 4. 总体架构

#### 4.1 进程内结构

```
                    ┌─────────────────────────────────────────┐
   HTTP 请求         │              HTTP Server (Gin)           │
  (经 FRP 进入) ───► │  Router + Auth Middleware + RequestID    │
                    └───────────────┬─────────────────────────┘
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          ▼                         ▼                         ▼
   AuthHandler               UploadHandler              MediaHandler
   DeviceHandler             ShareHandler               PublicHandler
   HealthHandler
          │                         │                         │
          └─────────────────────────┼─────────────────────────┘
                                    ▼
                          ┌───────────────────┐
                          │   Domain Services │
                          │ Auth / Device /   │
                          │ Upload / Media /  │
                          │ Share / Derivative│
                          └─────────┬─────────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
         SQLite Repo          Storage Engine         Job Worker
         (元数据)            (文件原子写入)          (缩略图队列)
```

#### 4.2 分层模块架构（自底向上实现）

实现时按「下层不依赖上层」原则编码：**先底层，再领域，最后 HTTP 与组装**。

```
┌─────────────────────────────────────────────────────────────────────────┐
│ L5  交付层（最后做）                                                      │
│     cmd/memorystore          依赖注入、启动监听、挂载 Worker               │
│     internal/httpapi         Gin Router / Handler / 中间件挂载             │
│       ├─ middleware          RequestID / Recover / RequireUser / Share   │
│       └─ handlers            把 HTTP 译成对 Service 的调用                 │
├─────────────────────────────────────────────────────────────────────────┤
│ L4  异步执行层                                                            │
│     internal/worker          抢占 jobs 表、调用 Derivative 服务            │
├─────────────────────────────────────────────────────────────────────────┤
│ L3  领域服务层（业务逻辑，无 Gin 类型）                                     │
│     auth          注册/登录/会话/短信预留                                   │
│     device        设备登记                                                 │
│     upload        init / chunk / complete / 秒传                          │
│     media         列表/详情/manifest/鉴权范围内读                           │
│     share         创建/撤销分享                                             │
│     publicshare   分享令牌解析与只读查询（可放 share 包内）                  │
│     derivative    生成 thumb / cover（被 Worker 调用）                     │
│     system        health / storage 监控（薄封装）                          │
├─────────────────────────────────────────────────────────────────────────┤
│ L2  仓储层（只谈数据存取，不谈 HTTP）                                       │
│     internal/repo（或 db/repo）                                           │
│       UserRepo / SessionRepo / DeviceRepo / MediaRepo                    │
│       UploadSessionRepo / ShareRepo / JobRepo / InviteRepo               │
├─────────────────────────────────────────────────────────────────────────┤
│ L1  基础设施层（最先落地的「真·底层」）                                     │
│     internal/db         打开 SQLite、迁移、事务助手                         │
│     internal/storage    DATA_ROOT 路径规则、原子 rename、目录创建           │
│     internal/config     加载 yaml / env                                   │
│     pkg/ids             ULID/UUIDv7 生成                                  │
│     pkg/hashutil        SHA-256 流式计算                                  │
│     pkg/passwd          argon2id 哈希与校验                               │
│     pkg/apperr          统一错误码（供 Service/HTTP 映射）                  │
└─────────────────────────────────────────────────────────────────────────┘

依赖方向：仅允许 上 → 下（箭头向下），禁止 L1/L2 引用 L3/L5。
```

**依赖关系简图：**

```
                    ┌──────────────┐
                    │ L5 httpapi   │
                    │ L5 main      │
                    └──────┬───────┘
                           │ 调用
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │L3 auth   │ │L3 upload │ │L3 media  │ ···
        │L3 device │ │L3 share  │ │L3 deriv. │
        └────┬─────┘ └────┬─────┘ └────┬─────┘
             │            │            │
             └────────────┼────────────┘
                          ▼
                    ┌──────────┐
                    │ L2 repo  │
                    └────┬─────┘
                         │
           ┌─────────────┼─────────────┐
           ▼             ▼             ▼
      ┌────────┐   ┌──────────┐   ┌─────────┐
      │ L1 db  │   │L1 storage│   │L1 config│
      │ ids / hash / passwd / apperr        │
      └────────┘   └──────────┘   └─────────┘

L4 worker ──调用──► L3 derivative ──► L2 + L1 storage
```

##### 各层职责与代码包对应

| 层 | 包路径建议 | 职责 | 禁止 |
|----|------------|------|------|
| L1 | `config` / `db` / `storage` / `pkg/*` | 配置、DB 连接与迁移、文件落盘、通用工具 | 包含业务规则、引用 Gin |
| L2 | `repo` | SQL CRUD、按 `user_id` 查询封装 | 编排多步业务（如 complete 全流程） |
| L3 | `auth` / `upload` / `media` / … | 用例级逻辑、状态机、权限断言 | 依赖 `gin.Context` |
| L4 | `worker` | 异步抢任务、重试退避 | 对外暴露 HTTP |
| L5 | `httpapi` + `cmd` | 路由、DTO 绑定、状态码映射、进程组装 | 直接写复杂 SQL / 直接操裸文件路径拼业务 |

##### 推荐实现顺序（编码 checklist）

按序号推进；同一层内也可微调，但不要跳过 L1 去写 Handler。

| 顺序 | 模块 | 层 | 完成标准（可单测/可手工验证） |
|------|------|----|------------------------------|
| 1 | `config` | L1 | 能读出 `listen`、`data.root`、`auth.*` |
| 2 | `pkg/apperr` + `pkg/ids` + `pkg/hashutil` + `pkg/passwd` | L1 | 单测覆盖哈希与密码 |
| 3 | `db`（连接 + migrations） | L1 | 空库启动后表结构齐全 |
| 4 | `storage` | L1 | 给定 userId 生成路径；tmp→originals 原子移动 |
| 5 | 各 `repo` | L2 | 用户/会话/媒体等 CRUD 单测（可对 SQLite 内存库） |
| 6 | `auth` + `device` | L3 | 注册登录发 token；中间件可先用单测调 Service |
| 7 | `upload` + `media`（读） | L3 | check / init / chunk / complete / manifest 跑通 |
| 8 | `derivative` + `worker` | L3+L4 | complete 后异步出缩略图 |
| 9 | `share` + public 只读 | L3 | 创建分享；token 校验与范围过滤 |
| 10 | `httpapi`（Gin） | L5 | 路由挂上；错误码→HTTP；静态 H5 |
| 11 | `cmd/memorystore` | L5 | 一键启动：migrate + listen + worker |
| 12 | `system`（health/storage） | L3+L5 | `/health` 可供 FRP 探活 |

**经验口诀：**  
`工具与配置 → 数据库与磁盘 → Repo → 账号 → 上传闭环 → 缩略图 → 分享 → 再铺 Gin 路由`。

##### 与目录结构对齐（按层归类）

```
server/
├── cmd/memorystore/main.go          # L5
├── internal/
│   ├── config/                      # L1
│   ├── db/                          # L1 迁移与连接
│   ├── storage/                     # L1 文件引擎
│   ├── repo/                        # L2
│   ├── auth/                        # L3
│   ├── device/                      # L3
│   ├── upload/                      # L3
│   ├── media/                       # L3
│   ├── share/                       # L3
│   ├── derivative/                  # L3
│   ├── worker/                      # L4
│   ├── system/                      # L3
│   └── httpapi/                     # L5
│       ├── router.go
│       ├── middleware/
│       └── handlers/
├── pkg/
│   ├── ids/
│   ├── hashutil/
│   ├── passwd/
│   └── apperr/
├── web/dist/
├── configs/config.example.yaml
└── go.mod
```

#### 4.3 目录布局（运行时数据）

元数据与媒体可分盘配置：

| 配置 | 环境变量 | 内容 |
|------|----------|------|
| `data.root` | `MEMORYSTORE_DATA_ROOT` | `db/`、`logs/`（建议本机盘） |
| `data.media_root` | `MEMORYSTORE_MEDIA_ROOT` | `originals/`、`derivatives/`、`tmp/uploads/`（可外接硬盘；空则同 `root`） |

```
# 示例：元数据在本机，照片在外接盘
./data/                               # data.root
├── db/memorystore.db
└── logs/

/Volumes/MemoryStore/                 # data.media_root
├── originals/
│   └── {userId}/2026/09/04/
│       └── {mediaId}_{hash12}.jpg
├── derivatives/
│   └── {userId}/
│       ├── thumb_sm/{mediaId}.jpg
│       └── thumb_md/{mediaId}.jpg
└── tmp/
    └── uploads/{userId}/{uploadId}/
        └── data.bin
```

DB 中 `original_path` / 派生路径仍为相对 **media_root** 的路径（如 `originals/...`）。

应用代码仓库建议结构见 **§4.2「与目录结构对齐」**（按层拆包，便于先实现底层）。

#### 4.4 鉴权模型总览

| 调用方 | 凭证 | 中间件 | 权限 |
|--------|------|--------|------|
| iOS App | `Authorization: Bearer <access_token>` | `RequireUser` | 读写**本人**媒体、管理本人分享 |
| H5 访客 | `X-Share-Token: <share_token>` | `RequireShare` | 只读分享范围内媒体 |
| 本地运维 | 本机 loopback 或 `ADMIN_TOKEN` | — | 开户、邀请码、关注册等 |

**原则：**

- 主身份是 **User**，不是 Device。Device 仅作同步元数据挂载点。  
- 无凭证接口：`GET /health`、`/auth/register`、`/auth/login`、后期 `/auth/sms/*`、H5 静态入口。  
- 业务数据接口一律要求用户会话或分享令牌。  

#### 4.5 API 前缀约定

- 业务 API：`/api/v1/...`
- 健康检查：`/health`
- H5 静态：`/`、`/assets/...`
- 公开分享 API：`/api/v1/public/share/...`

统一响应包络（建议）：

```json
{
  "ok": true,
  "data": {},
  "error": null
}
```

失败时：

```json
{
  "ok": false,
  "data": null,
  "error": { "code": "UPLOAD_HASH_MISMATCH", "message": "hash mismatch" }
}
```

---

### 5. 数据模型（Schema 概要）

#### 5.1 `users`

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | 用户 ID |
| username | TEXT UNIQUE | 登录名（前期） |
| password_hash | TEXT NULL | argon2id 编码串；短信-only 用户可空（后期） |
| phone | TEXT UNIQUE NULL | 手机号（后期绑定/登录） |
| display_name | TEXT | 展示名 |
| status | TEXT | `active` / `disabled` |
| created_at / updated_at | DATETIME | |

#### 5.2 `sessions`

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | |
| user_id | TEXT FK | |
| access_token_hash | TEXT UNIQUE | access_token 的 SHA-256 |
| refresh_token_hash | TEXT UNIQUE NULL | |
| expires_at | DATETIME | access 过期 |
| refresh_expires_at | DATETIME NULL | |
| revoked_at | DATETIME NULL | 登出/吊销 |
| created_at | DATETIME | |
| user_agent | TEXT | 可选 |
| device_id | TEXT NULL | 关联已登记设备 |

#### 5.3 `devices`

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | 设备 ID |
| user_id | TEXT FK | 归属用户 |
| name | TEXT | 展示名（如「冯的 iPhone」） |
| platform | TEXT | `ios` |
| last_seen_at | DATETIME | |
| revoked_at | DATETIME NULL | |
| created_at | DATETIME | |

#### 5.4 `invite_codes`（可选，注册管控）

| 字段 | 类型 | 说明 |
|------|------|------|
| code | TEXT PK | 邀请码 |
| max_uses / used_count | INTEGER | |
| expires_at | DATETIME NULL | |
| created_at | DATETIME | |

#### 5.5 `sms_challenges`（后期）

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | |
| phone | TEXT | |
| code_hash | TEXT | 验证码哈希 |
| purpose | TEXT | `login` / `bind` |
| expires_at | DATETIME | 如 5 分钟 |
| consumed_at | DATETIME NULL | |
| attempt_count | INTEGER | |
| created_at | DATETIME | |

#### 5.6 `media`

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | mediaId |
| user_id | TEXT FK | **归属用户，隔离关键** |
| content_hash | TEXT | SHA-256 hex |
| mime_type | TEXT | image/jpeg, video/mp4… |
| media_type | TEXT | `photo` / `video` |
| size_bytes | INTEGER | 字节数 |
| width / height | INTEGER | 可选 |
| duration_ms | INTEGER | 视频时长 |
| taken_at | DATETIME | 拍摄时间（客户端上报） |
| original_path | TEXT | 相对 DATA_ROOT 的路径 |
| status | TEXT | `stored` / `pending_derivatives` / `ready` |
| source_device_id | TEXT | 上传设备 |
| created_at / updated_at | DATETIME | |
| UNIQUE(user_id, content_hash) | | **秒传与去重在用户内** |

#### 5.7 `media_derivatives`

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | |
| media_id | TEXT FK | |
| kind | TEXT | `thumb_sm` / `thumb_md` / `cover` |
| path | TEXT | |
| width / height | INTEGER | |
| size_bytes | INTEGER | |
| UNIQUE(media_id, kind) | | |

#### 5.8 `upload_sessions`

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | uploadId |
| user_id | TEXT FK | |
| device_id | TEXT NULL | |
| content_hash | TEXT | 客户端声明 |
| size_bytes | INTEGER | 声明大小 |
| received_bytes | INTEGER | 已收字节 |
| tmp_dir | TEXT | |
| status | TEXT | `open` / `completed` / `aborted` / `expired` |
| meta_json | TEXT | filename、takenAt 等 |
| expires_at | DATETIME | 超时清理 |
| media_id | TEXT NULL | 完成后回填 |

#### 5.9 `share_links`

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | |
| user_id | TEXT FK | 创建者 |
| token_hash | TEXT UNIQUE | |
| title | TEXT | 展示标题 |
| scope_type | TEXT | `album` / `media_ids`（首期禁止无确认的 `all`） |
| scope_payload | TEXT | JSON：相册 id 或 mediaId 列表 |
| password_hash | TEXT NULL | 可选口令 |
| expires_at | DATETIME NULL | |
| revoked_at | DATETIME NULL | |
| created_at | DATETIME | |

#### 5.10 `jobs`

| 字段 | 类型 | 说明 |
|------|------|------|
| id | TEXT PK | |
| type | TEXT | `generate_derivatives` |
| payload | TEXT | JSON（含 media_id / user_id） |
| status | TEXT | `pending` / `running` / `done` / `failed` |
| attempts | INTEGER | |
| available_at | DATETIME | 退避重试 |
| last_error | TEXT | |

#### 5.11 索引建议

- `media(user_id, taken_at DESC, id)` — 用户时间轴  
- `media(user_id, content_hash)` — 用户内秒传（UNIQUE 已覆盖）  
- `sessions(access_token_hash)`、`sessions(user_id, revoked_at)`  
- `upload_sessions(status, expires_at)` — 清理  
- `share_links(token_hash)`  
- `jobs(status, available_at)` — worker 拉取  

---

### 6. 模块依赖关系

> 分层与实现顺序见 **§4.2**。此处补充 L3 领域模块之间的调用关系。

```
Auth(User/Session) ──► 被所有登录用户 API 依赖
Device ──────────────► 从属于 User
Upload ──────────────► Media（complete 时创建，带 user_id）+ Storage + Jobs
Media ───────────────► Storage + Derivatives（读）；查询必带 user_id
Derivative Worker ───► Media + Storage
Share ───────────────► Media（校验 scope 属于当前 user）
Public ──────────────► Share + Media（只读，不暴露他库）
```

L3 彼此尽量通过接口依赖，避免循环：`upload` 写媒体用 `MediaRepo`，不要反向依赖 `httpapi`。

---

### 7. 部署与配置要点

#### 7.1 关键配置项

```yaml
server:
  listen: "127.0.0.1:8080"
  public_base_url: "https://memory.example.com"

data:
  root: "/Volumes/MemoryStore"

auth:
  register_mode: "invite"       # open | invite | closed
  access_token_ttl_hours: 168   # 7 天，可按需缩短 + refresh
  refresh_token_ttl_days: 30
  password_min_length: 8

sms:                            # 后期启用
  enabled: false
  provider: ""
  code_ttl_minutes: 5
  send_interval_seconds: 60
  daily_limit_per_phone: 10

upload:
  max_bytes: 5368709120
  chunk_size_hint: 8388608
  session_ttl_hours: 24

derivative:
  thumb_sm: 320
  thumb_md: 1280
  worker_concurrency: 2

share:
  default_ttl_days: 7
```

#### 7.2 与云服务器约定

| 项 | 约定 |
|----|------|
| 上游 | `127.0.0.1:8080`（经 frpc 映射） |
| TLS | 云端终结 |
| 超时 | 上传接口超时加长（如 3600s）；浏览可 60s |
| body 大小 | 云端 `client_max_body_size` 需 ≥ 单分片大小 |
| 健康 | 云端探活 `GET /health` |

---

## 第二部分：详细设计

以下按功能说明：**作用** → **接口** → **实现逻辑** → **失败与边界**。

---

### 功能 0：健康检查与静态托管

#### 作用

- 供云服务器 / FRP / 运维判断进程存活  
- 托管 H5 前端，使分享链接与 API 同域，避免额外 CORS 复杂度  

#### 接口

- `GET /health`  
- 静态：`GET /`、`GET /s/:token`（H5路由由前端处理，服务端 fallback `index.html`）

#### 实现逻辑

1. `/health` 检查：进程存活 + SQLite `SELECT 1` + `DATA_ROOT` 可写。  
2. 任一项失败返回 `503`，body 标明组件。  
3. 静态资源：优先真实文件；SPA 路由回退到 `index.html`。  
4. **不**在无鉴权情况下通过静态路径暴露 `originals/`。

#### 失败与边界

- DB 锁短暂失败可重试一次再 503。  
- 健康检查不得触发重磁盘扫描。

---

### 功能 1：用户账号与会话鉴权

#### 作用

支持多用户：每人拥有独立媒体库。前期用用户名+密码完成注册/登录；后期扩展手机号验证码，而不改动「User + Session」主模型。登录成功后的 `access_token` 是 App 调用业务 API 的主凭证。

#### 接口（前期 P0）

| 方法 | 路径 | 鉴权 | 说明 |
|------|------|------|------|
| `POST` | `/api/v1/auth/register` | 无（受注册模式约束） | 注册 |
| `POST` | `/api/v1/auth/login` | 无 | 登录发 token |
| `POST` | `/api/v1/auth/refresh` | refresh_token | 刷新 access |
| `POST` | `/api/v1/auth/logout` | access | 作废当前会话 |
| `GET` | `/api/v1/me` | access | 当前用户资料 |
| — | 所有用户业务 API | `RequireUser` | 注入 `user_id` |

**register 请求：**

```json
{
  "username": "feng",
  "password": "********",
  "display_name": "冯",
  "invite_code": "可选，取决于 register_mode"
}
```

**login 响应：**

```json
{
  "user": { "id": "01J...", "username": "feng", "display_name": "冯" },
  "access_token": "明文仅此时返回",
  "refresh_token": "明文仅此时返回",
  "expires_at": "2026-09-11T03:00:00Z"
}
```

#### 接口（后期 P2 预留）

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/api/v1/auth/sms/send` | `{ "phone": "1xxxxxxxxxx", "purpose": "login"|"bind" }` |
| `POST` | `/api/v1/auth/sms/login` | `{ "phone", "code" }` → 同结构 token 响应 |
| `POST` | `/api/v1/auth/phone/bind` | 已登录绑定手机号 |

#### 实现逻辑（前期）

**注册**

1. 读 `register_mode`：  
   - `closed` → 拒绝，返回 `REGISTER_DISABLED`  
   - `invite` → 校验邀请码有效且未超限，`used_count++`  
   - `open` → 直接允许  
2. 校验 username 唯一、密码长度/复杂度。  
3. `password_hash = argon2id(password)`。  
4. 插入 `users`（status=`active`）。  
5. **不自动登录**或自动登录二选一；推荐注册后要求显式 login，逻辑更清晰。

**登录**

1. 按 username 查用户；不存在或 disabled → 统一 `AUTH_INVALID_CREDENTIALS`（防枚举可再加延迟）。  
2. 校验密码哈希。  
3. 生成高熵 `access_token` / `refresh_token`，只存 hash。  
4. 写 `sessions` 行。  
5. 明文 token 仅在响应返回；App 存 Keychain。

**RequireUser 中间件**

1. 解析 `Authorization: Bearer`。  
2. `SHA256(token)` 查 `sessions`：未撤销、未过期，联查 `users.status=active`。  
3. Context 注入 `user_id`、`session_id`。  
4. 可选节流更新 session/device `last_seen`。

**登出 / 刷新**

- logout：当前 session `revoked_at=now`。  
- refresh：校验 refresh_hash → 轮换新 access（建议同时轮换 refresh，旧 refresh 作废）。

#### 实现逻辑（后期短信）

1. `sms/send`：频控（同号间隔、日限额、同 IP 限额）→ 生成 6 位码 → 只存 hash → 调短信通道。  
2. `sms/login`：校验未过期未消费 → 按 phone 找用户，无则自动建号（username 可生成临时名）→ 签发与密码登录相同的 session。  
3. `phone/bind`：已登录用户绑定唯一 phone。  
4. `sms.enabled=false` 时接口返回 `SMS_DISABLED`。

#### 失败与边界

| 情况 | 错误码 |
|------|--------|
| 用户名已存在 | `USERNAME_TAKEN` |
| 邀请码无效 | `INVITE_INVALID` |
| 账密错误 | `AUTH_INVALID_CREDENTIALS` |
| token 无效/过期 | `401 UNAUTHORIZED` |
| 账号禁用 | `USER_DISABLED` |
| 短信未开启 | `SMS_DISABLED` |
| 验证码错误/过期 | `SMS_CODE_INVALID` |

---

### 功能 1b：设备登记

#### 作用

在用户账号下登记 iPhone，用于同步摘要、多设备管理；**不替代**用户 access_token。

#### 接口

| 方法 | 路径 | 鉴权 | 说明 |
|------|------|------|------|
| `POST` | `/api/v1/devices/register` | user | 登记或更新本机 |
| `GET` | `/api/v1/devices` | user | 列出本人设备 |
| `DELETE` | `/api/v1/devices/{id}` | user | 吊销 |

**register 请求：** `{ "name": "iPhone 15 Pro", "platform": "ios", "client_device_key": "可选稳定 ID" }`

#### 实现逻辑

1. 若带 `client_device_key` 且该用户下已存在 → 更新 name/`last_seen`。  
2. 否则新建 `devices` 行，`user_id=当前用户`。  
3. 返回 `device_id`；后续 upload 可带 `X-Device-Id` 写入 `source_device_id`。  
4. 吊销只影响该设备记录，不影响用户登录（除非产品要求「吊销时踢会话」——可选）。

---

### 功能 2：媒体去重探测（秒传）

#### 作用

App 上传前批量询问**当前用户库**中哪些 hash 已存在，避免重复传大文件。秒传成功时，App 同样可以删本地原片。

#### 接口

`POST /api/v1/media/check`（user 鉴权）

```json
{ "hashes": ["abc...", "def..."] }
```

响应：

```json
{
  "existing": [
    { "hash": "abc...", "media_id": "01J...", "size_bytes": 12345 }
  ],
  "missing": ["def..."]
}
```

#### 实现逻辑

1. 限制单次 hashes ≤ 500。  
2. `SELECT ... FROM media WHERE user_id=? AND content_hash IN (...)`。  
3. 拆成 `existing` / `missing`。  
4. **不同用户即使 hash 相同也互不影响**（各存各的，或未来做引用去重——首期各存副本更简单）。

#### 失败与边界

- 空数组返回空结果。  
- 仅匹配已入库媒体；未 complete 的不算。

---

### 功能 3：分片上传与入库校验

#### 作用

可靠接收大图/视频；支持断点续传与完整性校验。  
**`complete` 成功是 App 删除手机原片的唯一服务端扳机**——本功能是全链路安全关键。

#### 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/api/v1/upload/init` | 创建会话；若 hash 已存在则直接秒传返回 |
| `PUT` | `/api/v1/upload/{uploadId}/chunk` | 上传分片（Header 指定 offset） |
| `GET` | `/api/v1/upload/{uploadId}/status` | 查询已收字节，便于续传 |
| `POST` | `/api/v1/upload/{uploadId}/complete` | 校验并入库 |
| `POST` | `/api/v1/upload/{uploadId}/abort` | 放弃会话 |

**init 请求：**

```json
{
  "content_hash": "sha256hex",
  "size_bytes": 10485760,
  "mime_type": "image/jpeg",
  "media_type": "photo",
  "taken_at": "2026-09-04T10:00:00+08:00",
  "width": 4032,
  "height": 3024,
  "filename": "IMG_1234.HEIC"
}
```

**init 响应（需上传）：**

```json
{
  "upload_id": "01J...",
  "resume_from": 0,
  "already_exists": false
}
```

**init 响应（秒传）：**

```json
{
  "already_exists": true,
  "media_id": "01J...",
  "content_hash": "..."
}
```

**chunk：**

- Header：`Content-Range: bytes start-end/total` 或自定义 `X-Chunk-Offset`  
- Body：原始二进制  
- 服务端按 offset 写入临时文件（稀疏文件或追加策略二选一；推荐 **按 offset 写同一 `data.bin`**）

**complete 成功响应：**

```json
{
  "media_id": "01J...",
  "content_hash": "...",
  "size_bytes": 10485760,
  "status": "stored"
}
```

#### 实现逻辑

**init**

1. 校验已登录；size ≤ `max_bytes`，hash 格式合法。  
2. 若当前 `user_id` 下已存在同 `content_hash` → 返回 `already_exists=true` + `media_id`（秒传）。  
3. 若同 user（可选同 device）已有同 hash 的 `open` session → 复用并返回 `resume_from=received_bytes`。  
4. 否则创建 `upload_sessions`（写入 `user_id`），建 `tmp/uploads/{userId}/{uploadId}/`，预创建 `data.bin`。  
5. 返回 `upload_id`。

**chunk**

1. 校验 session 属当前 **user** 且 status=`open` 且未过期。  
2. 校验 offset 连续策略：  
   - **严格连续**：只接受 `offset == received_bytes`（实现简单，首期推荐）  
   - 或允许跳跃后由 complete 再校验空洞（首期不做）  
3. 写入文件，更新 `received_bytes`。  
4. 超限或偏移非法 → `400`。

**complete（核心）**

1. 校验 `received_bytes == size_bytes`。  
2. 对临时文件计算 SHA-256，与声明 `content_hash` 比较。  
3. **不一致**：删临时文件，session → `aborted`，返回 `UPLOAD_HASH_MISMATCH`。**此时 App 不得删本地。**  
4. **一致**：  
   a. 再次检查当前 user 下是否已有同 hash（并发秒传竞态）→ 有则删临时文件，返回已有 `media_id`。  
   b. 生成 `media_id`，正式路径 `originals/{userId}/{yyyy}/{mm}/{dd}/{mediaId}_{hash12}.{ext}`。  
   c. **原子 rename** 临时文件 → 正式路径（同盘）。  
   d. 事务写入 `media`（含 `user_id`，status=`pending_derivatives`），更新 session=`completed`。  
   e. 插入 job `generate_derivatives`。  
   f. 返回 `media_id`。  

5. 扩展名：由 mime_type 映射（heic/jpeg/png/mp4/mov…）；未知用 `.bin`。

**过期清理（后台定时）**

- 每小时扫 `upload_sessions`：`open` 且过期 → 删 tmp，标 `expired`。

#### 失败与边界

| 情况 | 行为 |
|------|------|
| 中途断网 | session 保留，App 用 status 续传 |
| 哈希失败 | 不入库、不发 job，明确错误码 |
| 磁盘满 | 写失败 → `507 INSUFFICIENT_STORAGE`，不删手机侧 |
| 并发 complete | UNIQUE(user_id, content_hash) 保证用户内只留一份 |

**HEIC 说明：** 首期可原样存储；缩略图阶段用 `sips` 转 JPEG 预览。不在上传时强制转码，以免拖慢备份。

---

### 功能 4：媒体元数据与对账清单（Manifest）

#### 作用

- 为 App 时间轴、详情提供权威元数据  
- 换机/重装后通过 manifest 与本地 Photos 对账，决定「只上传缺失项」  

#### 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/api/v1/sync/manifest?cursor=&limit=` | 分页清单（hash、media_id、taken_at、size） |
| `GET` | `/api/v1/media/{id}` | 单条详情（含派生是否就绪） |
| `DELETE` | `/api/v1/media/{id}` | 删除单条本人媒体（见功能 6b） |
| `POST` | `/api/v1/media/delete` | 批量删除本人媒体（见功能 6b） |

**manifest 项：**

```json
{
  "media_id": "01J...",
  "content_hash": "...",
  "media_type": "photo",
  "size_bytes": 123,
  "taken_at": "...",
  "status": "ready"
}
```

分页：按 `(taken_at DESC, id DESC)`，cursor 为上一页最后一条的编码。

#### 实现逻辑

1. user 鉴权；仅返回 **当前用户**已入库 media（`stored` / `pending_derivatives` / `ready`）。  
2. 不返回物理路径给客户端；下载走专用 API。  
3. `GET /media/{id}` 须校验归属当前用户，再组装 derivatives 可用 kind 列表。

#### 失败与边界

- limit 默认 100，最大 500。  
- 不存在或不属于当前用户 → `404`。

---

### 功能 5：缩略图 / 派生文件生成

#### 作用

列表墙与 H5 不应每次拉原图。入库后异步生成小图/中图（视频生成封面），提升浏览性能、节省流量。

#### 接口

无直接「触发」公网接口（由 complete 投递 job）。  
读取见功能 6 / 8：`GET .../derivatives/{kind}`。

#### 实现逻辑

**Worker 循环**

1. 事务抢占：`UPDATE jobs SET status='running' WHERE id=(SELECT ... pending ... LIMIT 1)`。  
2. 解析 payload：`{ "media_id": "..." }`。  
3. 读 `media.original_path`、`media_type`。  
4. **照片：**  
   - `thumb_sm`：最长边 320 JPEG quality ~70  
   - `thumb_md`：最长边 1280 JPEG quality ~80  
   - 实现：调用 `sips -Z {size} -s format jpeg` 或纯 Go 解码（HEIC 在 macOS 上优先 sips/ImageIO）。  
5. **视频：**  
   - `ffmpeg -ss 00:00:01 -i input -frames:v 1 -q:v 2 cover.jpg`  
   - 再从 cover 生成 thumb_sm / thumb_md。  
6. 写入 `derivatives/`，upsert `media_derivatives`。  
7. 若所需 kind 齐备 → `media.status = ready`；job → `done`。  
8. 失败：attempts+1，指数退避；超过 N 次标 `failed`，**原片仍可下载**（status 可保持 `stored`）。

**并发：** `worker_concurrency` 默认 2，避免家用电脑卡顿。

#### 失败与边界

- 原片损坏无法解码：记错误，不影响 media 主记录。  
- 派生文件丢失：可提供内部 `POST /admin/rederive/{mediaId}`（本机或 admin token）重入队。

---

### 功能 6：浏览与原图下载（登录用户 App）

#### 作用

支撑 App 时间轴、大图按需加载。原片删除后，App 完全依赖本能力。所有查询强制限定为当前 `user_id`。

#### 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/api/v1/media?cursor=&from=&to=&limit=` | 本人时间轴分页 |
| `GET` | `/api/v1/media/{id}/derivatives/{kind}` | 缩略图文件流 |
| `GET` | `/api/v1/media/{id}/original` | 原图/原视频流 |

列表项建议包含：`media_id, media_type, taken_at, width, height, duration_ms, thumb_ready, size_bytes`。

#### 实现逻辑

**列表**

1. user 鉴权。  
2. `WHERE user_id = ?`，可选 `taken_at` 范围过滤。  
3. 排序：`taken_at DESC, id DESC`。  
4. 联查是否存在 `thumb_sm` 标记 `thumb_ready`。  
5. 返回 cursor。

**派生 / 原图**

1. 鉴权 + 确认 media 存在且 `media.user_id == 当前用户`（否则 `404`，防枚举）。  
2. 解析绝对路径：`filepath.Join(DATA_ROOT, rel)`，`Clean` 后必须仍在 DATA_ROOT 下。  
3. 设置正确 `Content-Type`；支持 `Range`。  
4. 使用类似 `http.ServeContent` 输出。

#### 失败与边界

| 情况 | 行为 |
|------|------|
| 缩略图未就绪 | `404 DERIVATIVE_PENDING` |
| 越权访问他人 media id | `404 NOT_FOUND` |
| 原片缺失 | `404` + 日志告警 |
| Range 非法 | `416` |

---

### 功能 6b：删除媒体（登录用户）

#### 作用

App 编辑态「仅云端」过滤后，用户可永久删除服务端权威副本（原片、派生文件与数据库记录）。

#### 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| `DELETE` | `/api/v1/media/{id}` | 删除单条本人媒体 |
| `POST` | `/api/v1/media/delete` | 批量删除 `{ "media_ids": ["…"] }` |

**批量响应示例：** `{ "deleted": ["id1"], "missing": ["id2"] }`（`missing` 含本不存在或非本人，按已处理）。

#### 实现逻辑

1. 鉴权；仅允许删除 `media.user_id == 当前用户` 的行。  
2. 读取 `original_path` 与全部 `media_derivatives.path`。  
3. 事务内：删除 `media` 行（`media_derivatives` 依赖 `ON DELETE CASCADE`）；可选清理相关 `jobs`。  
4. 事务成功后尽力删除磁盘上的原片与派生文件（文件缺失不视为失败）。  
5. 分享 `scope_payload` 中残留 id：解析时自然跳过缺失媒体；可不强制改写分享行。  

#### 失败与边界

| 情况 | 行为 |
|------|------|
| 非本人 / 不存在 | 单删 `404`；批量记入 `missing` |
| 磁盘删除失败 | 记日志；DB 已删仍返回成功（避免僵尸记录） |
| 空 media_ids | `400` |

---

### 功能 6c：媒体故事与展示文案（登录用户）

#### 作用

为大图「边框 / 水印」样式提供可编辑文案：故事正文、可选标题与地点名。EXIF（焦距、光圈等）由客户端读原片，服务端不强制解析入库。

#### Schema 扩展（迁移 `002_media_story.sql`）

| 列 | 类型 | 说明 |
|----|------|------|
| `story` | TEXT | 故事正文，可空 |
| `title` | TEXT | 展示标题，可空（杂志风主标题） |
| `place_name` | TEXT | 地点文案，可空（可覆盖/补充 EXIF 地名） |

#### 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| `PATCH` | `/api/v1/media/{id}` | 更新 `{ "story"?, "title"?, "place_name"? }`（仅本人） |
| `POST` | `/api/v1/media/{id}/story/ai` | 生成故事草稿；响应 `{ "story", "title?" }`，**不自动写入** |
| `GET` | `/api/v1/media` / `{id}` | 列表与详情附带上述字段 |

#### AI 草稿（首期）

- 若未配置外部 LLM：基于 `taken_at` / `place_name` / `media_type` 生成简短模板文案，标记 `source=template`。  
- 后续可接 OpenAI 兼容接口；配置项预留 `ai.story_endpoint`（本期可不启用）。  

#### 失败与边界

| 情况 | 行为 |
|------|------|
| 非本人 | `404` |
| story 过长（>8000 字） | `400` |
| AI 未配置 | 仍返回模板草稿，不报错 |

---

### 功能 7：分享链接管理（登录用户）

#### 作用

用户把本人一部分媒体生成可发给朋友的链接；可设过期、可撤销、可选口令。是 H5 访问的前置。

#### 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/api/v1/shares` | 创建分享 |
| `GET` | `/api/v1/shares` | 我创建的分享列表 |
| `DELETE` | `/api/v1/shares/{id}` | 撤销 |

**创建请求：**

```json
{
  "title": "青海旅行",
  "scope_type": "media_ids",
  "media_ids": ["01J...", "01K..."],
  "expires_in_days": 7,
  "password": "optional"
}
```

**响应：**

```json
{
  "share_id": "01J...",
  "url": "https://memory.example.com/s/plaintextToken",
  "token": "plaintextToken",
  "expires_at": "..."
}
```

#### 实现逻辑

1. user 鉴权。  
2. 校验 scope 内每个 media 均属于**当前用户**；数量上限（如 2000）。  
3. 首期默认禁止 `scope_type=all`（防误分享全家底）；若开放需 `confirm_share_all: true`。  
4. 生成高熵 token → 存 hash；口令则 argon2/bcrypt。  
5. 写 `share_links`（`user_id=当前用户`）。  
6. 撤销：`revoked_at=now`，立即失效。

#### 失败与边界

- 空 media_ids → `400`。  
- 含不存在或不属于本人的 id → `400 SHARE_SCOPE_INVALID`。  

---

### 功能 8：公开只读访问（H5）

#### 作用

访客不装 App、不持有用户 token，仅凭分享 token（及可选口令）浏览范围内照片/视频。

#### 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/api/v1/public/share/meta` | 标题、过期、是否需口令 |
| `POST` | `/api/v1/public/share/unlock` | 提交口令（可选） |
| `GET` | `/api/v1/public/share/media` | 范围内列表 |
| `GET` | `/api/v1/public/share/media/{id}/derivatives/{kind}` | 缩略图 |
| `GET` | `/api/v1/public/share/media/{id}/file` | 大图/视频 |

Header：`X-Share-Token: ...`

#### 实现逻辑

**鉴权中间件 `RequireShare`**

1. 取 share token → hash → 查表。  
2. 校验：未撤销、未过期。  
3. 若设置了 password：校验口令。  
4. 解析允许的 media 集合（均属于该 share 的 `user_id`）。

**列表 / 文件**

1. 仅返回允许集合内媒体。  
2. 越权 id 统一 `404`（不暴露是否存在于其他用户库）。  
3. public 下不提供任何 upload/delete。  
4. 按 IP + token 做简单限流。

#### 失败与边界

| 情况 | 错误 |
|------|------|
| token 无效 | `401 SHARE_INVALID` |
| 过期/撤销 | `403 SHARE_EXPIRED` / `SHARE_REVOKED` |
| 口令错误 | `403 SHARE_PASSWORD_REQUIRED` |
| 越权 media id | `404` |

---

### 功能 9：存储监控（P1）

#### 作用

了解磁盘空间与（可选）当前用户占用，避免备份到一半失败。

#### 接口

`GET /api/v1/system/storage`（user 鉴权）

```json
{
  "data_root": "/Volumes/MemoryStore",
  "total_bytes": ...,
  "available_bytes": ...,
  "my_originals_bytes": ...,
  "my_media_count": 1234
}
```

#### 实现逻辑

1. `statfs` 取卷容量。  
2. `my_*` 用 `SUM(size_bytes) WHERE user_id=?`。  
3. 可选管理员接口看全局（需 ADMIN_TOKEN）。

---

## 第三部分：关键时序与状态机

### 1. 上传成功与客户端「已备份」标记（不自动删片）

```
App                         Server                         Disk/DB
 │  media/check               │                              │
 │───────────────────────────►│                              │
 │  upload/init + chunks      │                              │
 │───────────────────────────►│                              │
 │  upload/complete           │ SHA256 校验 → 落盘 + job     │
 │───────────────────────────►│─────────────────────────────►│
 │  { media_id, ok }          │                              │
 │◄───────────────────────────│                              │
 │  标记 backed_up，保留本机   │                              │
 │  （编辑删本机不经 Server）  │  下载仍走 /original          │
```

**说明：** 服务端无「删手机相册」接口；手动清理本机后的再下载使用既有原图 API。

客户端编辑态「已备份且 >30MB」过滤依赖列表/索引中的 `size_bytes`（media 表已有）；**无需新增 API**。阈值由客户端常量决定（首期 30 MiB）。

### 2. media 状态机（服务端）

```
（upload session open）
        │ complete 成功
        ▼
    stored  / pending_derivatives
        │ worker 成功
        ▼
      ready
```

任一步失败不得进入「对客户端宣称成功」的 complete 响应。

### 3. share 状态

```
active ── revoke / expire ──► inactive（不可逆，需新建分享）
```

---

## 第四部分：错误码与可观测性

### 常用错误码

| code | HTTP | 含义 |
|------|------|------|
| `UNAUTHORIZED` | 401 | 会话令牌无效 |
| `AUTH_INVALID_CREDENTIALS` | 401 | 用户名或密码错误 |
| `USERNAME_TAKEN` | 409 | 用户名已占用 |
| `REGISTER_DISABLED` | 403 | 关闭注册 |
| `INVITE_INVALID` | 400 | 邀请码无效 |
| `USER_DISABLED` | 403 | 账号禁用 |
| `SMS_DISABLED` | 503 | 短信登录未启用 |
| `SMS_CODE_INVALID` | 400 | 验证码无效 |
| `UPLOAD_HASH_MISMATCH` | 400 | 完整性失败，客户端不得标记已备份 |
| `UPLOAD_INCOMPLETE` | 400 | 字节未收齐 |
| `UPLOAD_TOO_LARGE` | 413 | 超大小限制 |
| `INSUFFICIENT_STORAGE` | 507 | 磁盘不足 |
| `DERIVATIVE_PENDING` | 404 | 缩略图未好 |
| `SHARE_INVALID` | 401 | 分享令牌无效 |
| `SHARE_EXPIRED` | 403 | 已过期 |
| `SHARE_REVOKED` | 403 | 已撤销 |
| `NOT_FOUND` | 404 | 资源不存在 |

### 日志与审计

每条请求：`request_id, user_id|share_id, path, status, latency_ms`。  
额外审计事件：`user_register`、`user_login`、`user_logout`、`upload_complete`、`media_delete`、`share_create`、`share_revoke`。  
**不**记录原图内容、明文密码、明文 token、短信验证码。

---

## 第五部分：实现分期（仅服务端）

### S1 — 可登录可备份

- [ ] 工程骨架、配置、SQLite 迁移、health  
- [ ] 用户注册/登录/会话 + RequireUser  
- [ ] 设备登记  
- [ ] check / upload init·chunk·complete（用户内哈希校验与秒传）  
- [ ] media 详情 + original 下载（用户隔离）  
- [ ] manifest  

### S2 — 可浏览与删除

- [ ] derivative worker（图片 + 视频封面）  
- [ ] 时间轴列表 + derivatives 下载  
- [ ] `DELETE /media/{id}` 与 `POST /media/delete`（DB + 原片/派生文件）  

### S3 — 可分享

- [ ] shares CRUD（归属用户）  
- [ ] public share API  
- [ ] 托管 H5 静态资源  

### S4 — 可运营与登录增强

- [ ] 存储监控  
- [ ] 上传会话清理、限流  
- [ ] 手机号 + 短信验证码登录（P2）  

---

## 附录 A：与产品设计文档的追溯

| 产品能力 | 服务端模块 |
|----------|------------|
| 多用户账号 / 密码登录 | 功能 1 |
| 手机号验证码登录（后期） | 功能 1 预留接口 + `sms_challenges` |
| 设备登记 | 功能 1b |
| 用户数据隔离 | Schema `user_id` + 全查询强制过滤 |
| Wi‑Fi 自动上传落地 | 功能 2 + 3 |
| 校验成功才能删本地 | 功能 3 `complete` 契约 |
| 时间轴 / 大图 | 功能 5 + 6 |
| 仅云端永久删除 | 功能 6b |
| 照片故事 / 大图文案 | 功能 6c |
| 换机对账 | 功能 4 manifest |
| H5 分享浏览 | 功能 7 + 8 |
| FRP 后方稳定服务 | 功能 0 health + 监听 127.0.0.1 |

## 附录 B：修订记录

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.1 | 2026-09-04 | 首版：服务端整体方案 + 分功能详细设计 |
| v0.2 | 2026-09-04 | 多用户账号体系；设备配对改为用户会话；短信登录预留 |
| v0.3 | 2026-09-04 | Web 框架选型由 chi 调整为 Gin |
| v0.4 | 2026-09-04 | 补充分层模块架构图与自底向上实现顺序 |
| v0.5 | 2026-09-04 | 与产品对齐：complete 不再作为自动删片扳机；删本机为客户端编辑行为 |
| v0.6 | 2026-09-04 | 注明客户端大文件过滤复用 size_bytes，无新接口 |
| v0.7 | 2026-09-04 | 新增 DELETE/批量删除媒体：清理 DB + 原片/派生文件；补全目录/优先级/分期追溯 |
| v0.8 | 2026-09-04 | 媒体 story/title/place_name；PATCH 与 AI 故事草稿接口 |
