# MemoryStore 客户端（iOS）方案设计

> 版本：v0.5  
> 日期：2026-09-04  
> 依据：[MemoryStore 设计文档 v0.7](./MemoryStore-设计文档.md)、[服务端方案设计 v0.8](./MemoryStore-服务端方案设计.md)  
> 范围：iPhone 上的 MemoryStore App（首期仅 iOS；不含 H5、不含 Android）

---

## 第一部分：整体方案设计

### 1. 目标与边界

#### 1.1 客户端要解决什么

MemoryStore iOS App 是用户在手机上的**唯一业务入口**，负责：

1. 账号注册 / 登录（前期密码；后期短信预留），会话安全持久化  
2. 扫描系统相册，发现新增照片/视频  
3. 在 Wi‑Fi 下自动、可靠地上传到服务端（当前用户库）  
4. 上传校验成功后**标记为已备份**，**保留**本机原片（不自动删除）  
5. 列表以三态角标展示本地/远端关系；编辑模式可过滤「已备份」并手动删除本机原片  
6. 本机已删、远端仍在时支持按需下载回系统相册  
7. 创建/管理分享链接，供他人用 H5 访问  

#### 1.2 明确不做

| 不做 | 原因 |
|------|------|
| 在 App 内做权威永久存储 | 权威副本在 iMac Server |
| 未校验成功就删本地原片 | 硬安全约束 |
| 上传成功后自动删本机 | 改为用户编辑确认后手动清理 |
| 蜂窝网络自动上传（默认） | 流量与稳定性；可后续显式开关 |
| Android / 跨端 UI 框架首期 | 产品决策仅 iOS |
| H5 访客端实现 | 独立前端；App 只负责生成链接 |
| AI 相册聚类 | 后续增强 |
| 首期短信登录 UI 全量 | P2；本期预留入口位置即可 |

#### 1.3 运行位置与访问路径

```
┌──────────────────────┐     HTTPS      ┌─────────────┐    FRP    ┌─────────────────┐
│  MemoryStore iOS App │ ─────────────► │ 云服务器入口 │ ───────► │ iMac Server API │
│  (本文档对象)         │                └─────────────┘          └─────────────────┘
│  - Photos 扫描/删除  │
│  - 本地 Sync DB      │
│  - 上传队列 / 缓存   │
└──────────────────────┘
```

App 统一访问配置的 `baseURL`（公网域名），不直连家中局域网（局域网加速为后期可选）。

---

### 2. 技术栈选型

| 层级 | 选型 | 选型理由 |
|------|------|----------|
| 语言 | **Swift 5.9+** | iOS 一等公民；与 Photos / 后台任务集成成熟 |
| UI | **SwiftUI** | 首期页面量可控；声明式开发快 |
| 最低系统 | **iOS 16+**（建议） | 兼顾 Photos / BackgroundTasks / 现代并发 |
| 并发 | **Swift Concurrency**（async/await、Actor） | 上传队列与扫描用 Actor 隔离状态 |
| 网络 | **Alamofire** | 原生支持后台上传、流式、鉴权头 |
| 本地 DB | **GRDB**（SQLite）或 **SwiftData** | 推荐 **GRDB**：同步索引、队列状态可控性强 |
| 安全存储 | **Keychain**（via SimpleKeychain / 自封装） | access/refresh token、设备 key |
| 照片库 | **Photos**（`PHPhotoLibrary` / `PHAsset` / `PHImageManager`） | 扫描、导出原片、删除 |
| 哈希 | **CryptoKit** SHA-256 | 与服务端 content_hash 对齐 |
| 网络监控 | **Network.framework**（`NWPathMonitor`） | 判定 Wi‑Fi / 蜂窝 |
| 后台任务 | **BGAppRefreshTask** + **BGProcessingTask** | 唤醒扫描与续传（受系统调度） |
| 图片加载 | **自研 ThumbnailLoader** + URLCache / 磁盘 LRU | 列表与大图缓存可控 |
| 日志 | **os.Logger** | 统一子系统，可导出诊断 |
| 依赖管理 | **Swift Package Manager** | 与 Xcode 原生集成 |

**架构风格：** 轻量模块化 + MVVM（SwiftUI）。核心同步引擎不绑 UI，便于单测。

---

### 3. 功能全景

```
MemoryStore iOS App
├── 0. 基础能力
│   ├── App 配置 / 环境 baseURL
│   ├── 网络可达性与 Wi‑Fi 判定
│   ├── 统一 API Client（鉴权、刷新、错误映射）
│   └── 权限与首次引导
├── 1. 账号与会话（前期密码；后期短信预留）
├── 1b. 设备登记
├── 2. 相册扫描与本地同步索引
├── 3. 内容哈希与秒传探测
├── 4. 上传队列（分片 / 断点 / 重试）
├── 5. 校验成功后删除本地原片
├── 6. 时间轴浏览与大图（按需下载 + 缓存）
├── 7. 分享管理
├── 8. 同步状态面板（P1）
└── 9. 设置与手动操作（P1）
```

| 模块 | 优先级 | 说明 |
|------|--------|------|
| 权限引导 | P0 | 含「上传后保留本机，可手动清理已备份」明示 |
| 账号登录 | P0 | 注册/登录/登出/Token 刷新 |
| 设备登记 | P0 | 登录后登记 |
| 相册扫描 | P0 | 全量 + 增量 |
| Wi‑Fi 自动上传 | P0 | 含秒传、分片、complete |
| 列表三态角标 | P0 | 待上传 / 已备份 / 可下载 |
| 编辑清理本机 | P0 | 过滤已备份 / 已备份且 >30MB → 多选或一键删本机 → remote_only |
| 仅云端删除 | P0 | 过滤 remote_only → 多选 → DELETE 服务端媒体 → 移除本地索引 |
| 下载回本地 | P0 | remote_only → 保存相册 → backed_up |
| 时间轴 + 大图 | P0 | 本地+远端统一列表 + 缓存 |
| 大图边框/水印样式 | P0 | 设置切换；EXIF+故事展示 |
| 照片故事编辑 | P0 | 手动 / AI 草稿；PATCH 落库 |
| 分享管理 | P0（可随 M2） | 创建/复制链接/撤销 |
| 短信登录 | P2 | UI 与 API 预留 |
| 状态面板 / 设置 | P1 | 队列、失败、暂停 |

---

### 4. 总体架构

#### 4.1 分层结构

```
┌──────────────────────────────────────────────────────────┐
│  SwiftUI Views                                           │
│  Login / Onboarding / Timeline / Viewer / Share / Settings│
└────────────────────────────┬─────────────────────────────┘
                             │ Observable / ViewModel
┌────────────────────────────▼─────────────────────────────┐
│  Application Services                                    │
│  AuthService / SyncEngine / GalleryService / ShareService│
└───────┬─────────────────────┬───────────────────┬────────┘
        │                     │                   │
        ▼                     ▼                   ▼
┌───────────────┐   ┌─────────────────┐   ┌──────────────┐
│ APIClient     │   │ PhotosGateway   │   │ LocalStore   │
│ + TokenStore  │   │ (扫描/导出/删除) │   │ (GRDB/Files) │
└───────────────┘   └─────────────────┘   └──────────────┘
        │
        ▼
   MemoryStore Server（经公网域名）
```

#### 4.2 工程目录建议

```
ios/MemoryStore/
├── App/
│   ├── MemoryStoreApp.swift
│   └── AppEnvironment.swift
├── Features/
│   ├── Auth/
│   ├── Onboarding/
│   ├── Timeline/
│   ├── Viewer/
│   ├── Share/
│   ├── SyncStatus/
│   └── Settings/
├── Core/
│   ├── Networking/          # APIClient, Endpoints, DTOs
│   ├── Auth/                # Session, TokenStore(Keychain)
│   ├── Sync/                # SyncEngine, UploadQueue, Scanner
│   ├── Photos/              # PhotosGateway
│   ├── Storage/             # GRDB models, CacheStore
│   ├── NetworkMonitor/
│   └── Utilities/           # Hashing, FileIO
├── Resources/
└── Tests/
```

#### 4.3 关键运行时组件

| 组件 | 类型建议 | 职责 |
|------|----------|------|
| `TokenStore` | Actor / 单例 | Keychain 读写 access/refresh |
| `APIClient` | Actor | 发请求、401 时 refresh 一次、注入 Bearer |
| `NetworkMonitor` | Observable | `isWifi` / `isExpensive` / `isConnected` |
| `PhotosGateway` | Actor | 权限、枚举、导出原文件、删除 asset |
| `SyncIndexStore` | GRDB | 本地同步索引 CRUD |
| `LibraryScanner` | Actor | 全量/增量扫描，写 SyncIndex |
| `UploadQueue` | Actor | 调度 pending → 上传 → 完成/失败 |
| `PurgeService` | Actor | **手动**删本机：编辑确认后批量删 PHAsset |
| `MediaCache` | Actor | 原图/大图磁盘 LRU |
| `SyncEngine` | Actor | 编排：扫描 → 探测 → 入队 → 上传 → 标已备份 |

#### 4.4 与服务端鉴权对齐

| 项 | 客户端行为 |
|----|------------|
| 凭证 | `Authorization: Bearer <access_token>` |
| 存储 | Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 建议） |
| 刷新 | access 401 → `POST /auth/refresh` → 重试原请求 1 次 |
| 刷新失败 | 清会话，跳转登录 |
| 设备 | 登录成功后 `POST /devices/register`；后续请求可带 `X-Device-Id` |

---

### 5. 本地数据模型

#### 5.1 `sync_assets`（本地同步索引）

| 字段 | 类型 | 说明 |
|------|------|------|
| local_id | TEXT PK | 本地主键 |
| user_id | TEXT | 当前登录用户；切换账号需隔离或清空 |
| ph_asset_id | TEXT | `PHAsset.localIdentifier` |
| content_hash | TEXT NULL | SHA-256 hex；导出后计算 |
| media_type | TEXT | `photo` / `video` |
| byte_size | INTEGER | |
| taken_at | DATETIME | |
| pixel_width / height | INTEGER | |
| duration_ms | INTEGER NULL | |
| status | TEXT | `pending_upload` / `uploading` / `backed_up` / `remote_only` / `failed` 等 |
| remote_media_id | TEXT NULL | 服务端 mediaId |
| upload_id | TEXT NULL | 进行中的上传会话 |
| resume_offset | INTEGER | 已上传字节 |
| last_error | TEXT NULL | |
| updated_at | DATETIME | |

索引：`(user_id, status)`、`(user_id, ph_asset_id)` UNIQUE、`(user_id, content_hash)`。

#### 5.2 `purge_jobs`（编辑手动清理队列，可选）

批量删本机时可同步执行；失败项写入队列重试。字段同前：关联 sync_asset、ph_asset_id、remote_media_id（无 remote 禁止入队）。

#### 5.3 `media_cache_entries`

| 字段 | 说明 |
|------|------|
| remote_media_id | PK |
| file_path | 沙盒相对路径 |
| byte_size / last_access_at | LRU |

#### 5.4 内存/会话态

- 当前 `UserProfile`（id、username、displayName）  
- `SyncEngineState`：running / paused / wifiBlocked / unauthorized  

---

### 6. 模块依赖关系

```
AuthService ──────────► TokenStore, APIClient
DeviceService ────────► APIClient（登录后）
LibraryScanner ───────► PhotosGateway, SyncIndexStore
UploadQueue ──────────► APIClient, PhotosGateway(导出), SyncIndexStore, Hashing
PurgeService ─────────► PhotosGateway, SyncIndexStore（仅编辑触发）
SyncEngine ───────────► Scanner + UploadQueue + NetworkMonitor（上传成功标 backed_up）
GalleryService ───────► APIClient, MediaCache, SyncIndexStore（合并本地/远端）
ShareService ─────────► APIClient
UI ───────────────────► 上述 Services（不直连 Photos/DB）
```

时间轴 UI 合并规则见功能 6；角标由本地 `status` + 是否仍有 `ph_asset_id` 推导。
---

### 7. 配置与权限

#### 7.1 配置项

```swift
struct AppConfig {
  var baseURL: URL              // https://memory.example.com
  var chunkSize: Int            // 8 * 1024 * 1024
  var maxUploadConcurrency: Int // 1~2（家宽友好）
  var mediaCacheLimitBytes: Int64 // 2GB
  var hashBufferSize: Int       // 1MB
  var registerRequiresInvite: Bool // 与服务端策略对齐的 UI 提示
}
```

`baseURL` 可通过 Build Configuration（Debug/Release）或运行时设置页覆盖（仅 Debug）。

#### 7.2 Info.plist / 权限

| Key | 用途 |
|-----|------|
| `NSPhotoLibraryUsageDescription` | 扫描备份说明 |
| `NSPhotoLibraryAddUsageDescription` | 若支持「保存回相册」 |
| 后台模式 | `fetch` / `processing`（按需） |
| ATS | 仅 HTTPS 公网域名 |

**权限策略：** 需要 **读写** 照片库（删除原片）。引导文案必须写清删除行为。

---

## 第二部分：详细设计

以下按功能说明：**作用** → **界面/接口** → **实现逻辑** → **失败与边界**。

---

### 功能 0：基础能力（配置、网络、API Client、引导）

#### 作用

为所有业务模块提供统一网络、鉴权注入、Wi‑Fi 判定与首次说明。

#### 界面 / 接口

- 启动路由：有有效会话 → 主页；否则 → 登录  
- `OnboardingView`：3 步内说明「Wi‑Fi 自动备份」「成功后删除原片」「数据存自家 iMac」  
- `APIClient.request<T>(_ endpoint)`  

#### 实现逻辑

1. 启动读 Keychain；有 refresh/access 则校验 `/me`，失败清会话。  
2. `NWPathMonitor` 更新 `isWifi`（`usesInterfaceType(.wifi)` 且 satisfied）。  
3. APIClient：自动加 Bearer；对业务错误码映射为 `AppError`。  
4. 上传类请求超时加长（如 600s+）；浏览类 30–60s。  

#### 失败与边界

- 无网：浏览可展示已缓存缩略图；上传暂停。  
- 非 Wi‑Fi：上传队列不调度（浏览下载默认允许，可配置）。  

---

### 功能 1：账号与会话

#### 作用

多用户登录入口；保证后续同步数据归属正确用户。

#### 界面 / 接口

| 界面 | 能力 |
|------|------|
| 注册页 | username、password、邀请码（按配置显示） |
| 登录页 | username、password |
| 设置 | 当前用户、退出登录 |
| （预留）短信登录页 | 手机号、验证码 |

对接 API：`/auth/register`、`/auth/login`、`/auth/refresh`、`/auth/logout`、`/me`。

#### 实现逻辑

**注册**

1. 本地校验密码长度 ≥ 服务端要求。  
2. 调 register；成功后跳转登录或自动 login。  
3. 错误展示：`USERNAME_TAKEN`、`INVITE_INVALID`、`REGISTER_DISABLED`。  

**登录**

1. 调 login，拿到 tokens + user。  
2. 写入 Keychain；内存保存 UserProfile。  
3. 调用设备登记（功能 1b）。  
4. 若本地 `sync_assets.user_id` 与当前用户不同 → **切换用户策略**：清空或隔离旧用户索引与缓存（推荐：按 user_id 分表数据保留，切换时只加载当前用户行；缓存目录按 userId 隔离）。  
5. 启动 `SyncEngine.start()`。  

**Token 刷新**

1. APIClient 捕获 401。  
2. 单飞（single-flight）refresh，避免并发风暴。  
3. 成功则重试；失败则 `AuthService.logoutLocal()` 并通知 UI。  

**登出**

1. 尽力调 `/auth/logout`。  
2. 清 Keychain、停 SyncEngine、可保留本地索引（仍按 user_id 隔离）或提供「清除本机数据」。  

#### 失败与边界

| 情况 | 处理 |
|------|------|
| 密码错误 | Toast + 不清本地库 |
| 账号禁用 | 提示联系管理员，清会话 |
| 切换用户 | 禁止串数据；上传队列按 user 过滤 |

**后期短信（P2）：** 调用 `/auth/sms/send`、`/auth/sms/login`，成功后走同一套 Token 存储与 SyncEngine 启动逻辑。

---

### 功能 1b：设备登记

#### 作用

向服务端声明本机，便于多设备管理与上传来源标记。

#### 界面 / 接口

- 无独立强交互页；设置中可展示「本机已登记」。  
- API：`POST /devices/register`；Header 后续带 `X-Device-Id`。  

#### 实现逻辑

1. 生成或读取 Keychain 中的 `client_device_key`（UUID，装机稳定）。  
2. 登录成功后 register：`name = UIDevice.current.name`，`platform = ios`。  
3. 持久化返回的 `device_id`。  
4. 登出不删除 `client_device_key`（换账号重新 register 即可）。  

#### 失败与边界

- 登记失败不阻断浏览；上传可暂不带 device_id，后台重试登记。  

---

### 功能 2：相册扫描与本地同步索引

#### 作用

发现系统相册中需要备份的媒体，写入本地索引，作为上传队列的唯一输入源。

#### 界面 / 接口

- 后台行为为主；状态页显示「扫描中 / 上次扫描时间」。  
- 权限拒绝时展示去系统设置引导。  

#### 实现逻辑

**权限**

1. 请求 `.readWrite`。  
2. 受限（Limited Library）时：提示用户选择更多照片，或仅备份已选中项（产品可选；推荐引导「允许访问所有照片」以保证自动备份完整）。  

**全量扫描（首次 / 手动）**

1. 枚举 `PHAsset`（image + video；可配置是否含截图/隐藏相册）。  
2. 对每个 asset upsert `sync_assets`：已存在则更新元数据；新资产 `status=discovered`。  
3. 库中有、相册已无的 asset：若 status 仍为 pending/上传中 → 标 `local_missing`（不删远端）。  

**增量扫描**

1. 注册 `PHPhotoLibraryChangeObserver`。  
2. 变更时根据 `changeDetails` 插入新 asset / 处理删除。  
3. 辅以定时/BG 刷新，防漏监听。  

**进入上传前**

1. `discovered` → 导出资源算 hash 后 → `pending_upload`（见功能 3）。  
2. 大视频 hash 计算放后台队列，避免卡 UI。  

#### 失败与边界

- iCloud 未下载到本机的优化存储照片：导出时需 `PHImageRequestOptions.isNetworkAccessAllowed` 策略——**建议仅 Wi‑Fi 允许网络拉原片**，否则标 `waiting_local_resource`。  
- Live Photo：首期可只备份静态图，或图+视频成对（产品可定；默认先静态原图）。  

---

### 功能 3：内容哈希与秒传探测

#### 作用

计算与服务端一致的 SHA-256，调用 `/media/check` 跳过已备份文件；秒传成功 → 标记 `backed_up`，**不删本地**。

#### 界面 / 接口

- 无独立页；状态可显示「秒传 / 计算指纹中」。  

#### 实现逻辑

1. 通过 `PhotosGateway.exportOriginal(asset)` 得到临时文件（或流）。  
2. 流式 SHA-256（CryptoKit），避免整文件进内存。  
3. 写入 `content_hash`、`byte_size`。  
4. 批量（≤500）调用 `POST /media/check`。  
5. existing → 本地写 `remote_media_id`，`status=backed_up`（保留 PHAsset）。  
6. missing → `status=pending_upload`，交上传队列。  

#### 失败与边界

- 导出失败：留在 `discovered`/`hash_failed`，可重试。  
- check 接口失败：指数退避，不改本地相册。  

---

### 功能 4：上传队列（分片 / 断点 / 重试）

#### 作用

在 Wi‑Fi 下把 missing 媒体可靠传到 Server；**complete 成功后标记已备份并保留本机**。

#### 界面 / 接口

- 状态页：待上传数、当前文件名、进度、失败列表、暂停/恢复。  
- API：`/upload/init`、`PUT chunk`、`/upload/{id}/status`、`/upload/{id}/complete`。  

#### 实现逻辑

**调度条件（全部满足才跑）**

1. 已登录  
2. `NetworkMonitor.isWifi == true`  
3. SyncEngine 未 pause  
4. 照片权限有效  

**单任务流程**

```
pending_upload
  → init
       already_exists? → status=backed_up（保留本机）
       else → 保存 upload_id，status=uploading
  → 循环读本地文件 / 导出流，按 chunkSize PUT（Content-Range）
       更新 resume_offset
  → complete
       成功 → remote_media_id，status=backed_up（保留本机）
       UPLOAD_HASH_MISMATCH → status=failed，可重建 hash 后重试
```

**并发：** 默认 1（视频友好）；照片可 2。同一 asset 禁止并行双传。  

**优先级：** `taken_at DESC`（新拍优先）或 FIFO，可配置；推荐新拍优先。  

**断点：** 进程被杀后，启动时对 `uploading` 调 `/upload/{id}/status` 取 `resume_from`，从 offset 续传；session 过期则重新 init。  

**后台：**  

- 前台：`UploadQueue` 持续跑。  
- 进后台：依赖 `URLSession` background configuration 尽量续传；并调度 `BGProcessingTask` 请求系统唤醒。  
- **不保证**系统一定会给长时间后台；回到前台必须能恢复队列。  

#### 失败与边界

| 错误 | 行为 |
|------|------|
| 切到蜂窝 | 立即暂停当前调度（进行中 chunk 可取消或完成当前片后停） |
| 507 磁盘不足 | 暂停队列并强提示 |
| 401 | 走刷新；失败则停引擎 |
| 网络抖动 | 指数退避重试，上限后标 failed 可手动重试 |

**硬约束：** 未 `complete`/`already_exists` 成功前，不得进入可删本机候选（`backed_up`）。

---

### 功能 5：编辑模式 — 过滤已备份 / 大文件并删除本机原片

#### 作用

用户主动释放手机空间；删除后项变为「可下载」，大图仍走服务端。优先支持清理占用空间最大的已备份大文件。

#### 界面 / 接口

| 能力 | 说明 |
|------|------|
| 进入编辑 | 时间轴工具栏「编辑」 |
| 过滤 | 分段控件：全部 / 仅已备份 / **已备份且 >30MB** / **仅云端** |
| 多选 | 勾选网格项；全选当前过滤结果 |
| 一键删除 | 在「已备份且 >30MB」过滤下，一键选中并确认删除当前过滤结果的本机原片 |
| 删除本机 | 「已备份」类过滤：确认后仅删系统相册原片，云端保留 |
| 删除云端 | 「仅云端」过滤：确认后调用 `POST /media/delete` 永久删除远端；不可恢复 |
| 下载回本地 | 非编辑或单项操作：`remote_only` → 保存相册 → `backed_up` |

#### 尺寸判定

- 常量：`largeFileThresholdBytes = 30 * 1024 * 1024`（30 MiB）。  
- 优先 `SyncAsset.byte_size`（上传/导出时写入）；若为 0/缺失，回退 `MediaItem.size_bytes`（服务端列表）。  
- 仅 `canDeleteLocal`（已备份且本机仍有 PHAsset）且 `byteSize > threshold` 进入大文件过滤结果。  

#### 实现逻辑

1. 仅 `status=backed_up` 且持有 `remote_media_id` + `ph_asset_id` 可入选删除。  
2. 大文件过滤 = 上述条件 ∧ `byteSize > 30MiB`。  
3. 「一键删除」= 对当前过滤结果执行全选 + 同一确认删除流程（不绕过确认）。  
4. 确认后 `PHPhotoLibrary.performChanges` 批量删除对应 `PHAsset`。  
5. 成功 → 清空/作废 `ph_asset_id`，`status=remote_only`；角标=可下载。  
6. 部分失败 → 成功项改 `remote_only`，失败项保留 `backed_up` 并提示。  
7. 下载回本地：`GET /media/{id}/original` → 写入相册 → 绑定新 `ph_asset_id`，`status=backed_up`。  
8. **仅云端过滤**：`badge=remote_only` 且有 `remote_media_id`；确认后 `POST /api/v1/media/delete`；成功则从 SyncIndex 移除并刷新时间轴。  
9. 首期不对 `backed_up` 项提供删云端入口（须先变 `remote_only`）。  

#### 失败与边界

| 点 | 处理 |
|----|------|
| 无写权限 | 引导开启；不改变状态 |
| asset 已被用户手动删 | 直接标 `remote_only` |
| 待上传/上传中 | 过滤与删除入口不可选 |
| 尺寸未知（两侧均为 0） | 不进入「>30MB」过滤；可走「仅已备份」手动选 |
| 「最近删除」残留 | 系统行为，文案说明即可 |
| 云端删除部分失败 | 成功项从列表移除；失败项保留并 toast |
| 云端 404 | 视为已删，清理本地索引 |

---

### 功能 6：时间轴浏览与大图（角标 + 按需下载 + 缓存）

#### 作用

统一展示「本地待传 + 已备份 + 仅远端」；角标传达三态；大图按本地优先、否则远端。

#### 界面 / 接口

| 界面 | 能力 |
|------|------|
| 时间轴 | 按日/月分组网格；三态角标；下拉刷新；分页；编辑入口 |
| 大图查看器 | 左右滑、缩放；视频；可下载项提供「保存到相册」 |

API：`GET /media`、`/derivatives/{kind}`、`/original`。

#### 实现逻辑

**时间轴**

1. 合并本地 SyncIndex（待上传/已备份）与 `GalleryService` 远端分页；按 `taken_at` 分组。  
2. 单元格角标：`pending_upload`/`uploading`→待上传；`backed_up`→已备份；`remote_only`→可下载。  
3. 缩略图：本地有 PHAsset 用 Photos 请求；否则加载远端 `thumb_sm`/`thumb_md`。  
4. `thumb_ready=false` 时显示占位，短轮询或下次刷新。  

**大图**

1. 打开 viewer：先展 thumb_md（若有）。  
2. 查 `MediaCache`：命中原图则直接显示。  
3. 未命中：下载 `/original` 到 `Caches/Media/{userId}/{mediaId}`，更新 LRU。  
4. 视频：`AVPlayer` + 支持 Range 的流式或先下后播（首期可先下后播简化）。  

**缓存淘汰**

- 总大小超过 `mediaCacheLimitBytes` → 按 `last_access_at` 删文件。

---

### 功能 6b：大图展示样式（边框 / 水印）与故事

#### 作用

大图不再使用纯黑底；按设置在两种艺术化展示间切换，并支持为照片撰写故事。

#### 设置

| 项 | 存储 | 说明 |
|----|------|------|
| `viewerStyle` | UserDefaults | `border`（边框模糊底）/ `watermark`（杂志水印） |

#### 边框模式（Style 1）

1. 背景：当前原图强高斯模糊铺满。  
2. 主图：居中、圆角 ~14pt、轻阴影；可缩放。  
3. 主图下方（白/浅字，视对比）：时间、地点；相机品牌型号与 EXIF（焦距/光圈/快门/ISO）。  
4. **若 `story` 非空：优先展示故事**（可取代或压过 EXIF 叙述块）。  
5. 顶栏：关闭、序号；入口「编辑故事」。

#### 水印杂志模式（Style 2）

1. 浅色画布（近 `#FAF7F2` / 主题 background）。  
2. 顶区艺术字标题（`title` 或回退月日/「回忆」）+ 日期与地点。  
3. 大图完整 `scaledToFit`。  
4. 图上底部渐变叠字：标题、地点、引用样式故事；分享可后续接。  
5. 字体：衬线/手写体（如 New York / Snell 系系统字体）混排，注意行距与边距。

#### 元数据读取

- EXIF：ImageIO / Photos 从本地 PHAsset 或下载的原图 Data 解析。  
- 故事：`GET /media` 或详情中的 `story`/`title`/`place_name`。  

#### 故事编辑

- 表单：标题、地点、故事正文。  
- 「AI 撰写」→ `POST /media/{id}/story/ai` → 填入草稿 → 用户改后 `PATCH /media/{id}`。  
- 仅有 `remoteMediaID` 时可落库；纯本地未上传项可本地暂存（首期可提示先备份）。
  

#### 失败与边界

- 下载失败：保留缩略图 + 重试按钮。  
- 蜂窝下大图：默认允许；可在设置增加「仅 Wi‑Fi 加载原图」。  
- 切换用户：缓存目录隔离，避免串图。  

---

### 功能 7：分享管理

#### 作用

用户选择照片创建分享链接，复制给朋友用 H5 打开。

#### 界面 / 接口

| 界面 | 能力 |
|------|------|
| 多选 → 创建分享 | 标题、有效期、可选口令 |
| 分享列表 | 复制链接、撤销 |
| 系统分享板 | `UIActivityViewController` 发出 URL |

API：`POST /shares`、`GET /shares`、`DELETE /shares/{id}`。

#### 实现逻辑

1. 时间轴多选得到 `media_ids`。  
2. 调创建接口，拿到 `url`/`token`（仅一次）。  
3. 复制到剪贴板并给出成功反馈。  
4. 列表页展示未撤销分享；撤销后本地列表更新。  

#### 失败与边界

- 空选不可创建。  
- 创建失败展示服务端错误。  
- 不在 App 内嵌 WebView 作为主分享浏览（避免与 H5 双端维护）；可选「预览」打开 Safari。  

---

### 功能 8：同步状态面板（P1）

#### 作用

让用户理解备份进度与失败原因，建立信任。

#### 界面

- 待上传 / 上传中 / 已备份已删 / 失败  
- 当前网络：Wi‑Fi / 蜂窝（已暂停上传）  
- 最近错误列表与「重试失败项」「暂停同步」  

#### 实现逻辑

- 订阅 `SyncEngine` 快照（Combine / AsyncStream）。  
- 失败项支持单条重试（清 last_error，回 pending）。  

---

### 功能 9：设置与手动操作（P1）

#### 作用

账号、缓存、同步开关、关于。

#### 能力清单

| 项 | 说明 |
|----|------|
| 退出登录 | 功能 1 |
| 暂停/恢复自动备份 | 控制 SyncEngine |
| 仅 Wi‑Fi 上传 | 默认开，不可轻易关（关时二次确认） |
| 清除浏览缓存 | 清空 MediaCache |
| 手动全量扫描 | 触发 Scanner |
| 保存原图回相册 | 从缓存或重新下载写入 Photos |

---

## 第三部分：关键时序与状态机

### 1. 主路径：拍摄 → 备份 → 删本地 → 可浏览

```
Photos 变更
   → Scanner upsert discovered
   → 导出 + SHA256
   → media/check
        ├─ existing ──────────────────────────────┐
        └─ missing → UploadQueue → complete 成功 ─┤
                                                   ▼
                                          backed_up（保留本机，角标=已备份）
                                                   │ 用户编辑删本机
                                                   ▼
                                             remote_only（角标=可下载）
                                                   │ 保存回相册
                                                   ▼
                                              backed_up
```

### 2. 本地 `sync_assets.status` 状态机

```
discovered → hashing → pending_upload → uploading → backed_up ──(编辑删本机)──► remote_only
                │            │              │                                      │
                └────────────┴──────────────┴─► failed / waiting_local_resource     │
                                                              remote_only ─(下载)──┘
```

合法删本机前置状态：**仅** `backed_up` 且持有 `remote_media_id`。

### 3. 与服务端契约（已备份标记）

| 服务端结果 | 客户端 |
|------------|--------|
| `check` existing / `init` already_exists | 标 `backed_up`，保留本机 |
| `complete` 成功返回 media_id | 标 `backed_up`，保留本机 |
| hash mismatch / 上传中失败 / 无网 | 不得标已备份 / 不得删本机 |

---

## 第四部分：错误模型与可观测性

### 常用本地错误映射

| AppError | 来源 | 用户提示方向 |
|----------|------|--------------|
| `notWifi` | NetworkMonitor | 连接 Wi‑Fi 后自动继续 |
| `photoPermissionDenied` | Photos | 去设置开启 |
| `authExpired` | API 401 | 重新登录 |
| `uploadFailed` | 网络/5xx | 可重试 |
| `hashMismatch` | complete | 重新备份该文件 |
| `purgeFailed` | Photos 删除 | 保留远端，稍后重试删 |
| `serverStorageFull` | 507 | 联系存储空间 |

### 日志与隐私

- 记录：asset 匿名 id、status 变迁、API path、耗时、错误码。  
- **不记录：** 密码、token、照片内容、精确 GPS 到日志文件（若导出 EXIF 仅用于上传 meta）。  

### 诊断导出（P1）

设置页「导出日志」→ 分享 zip（不含缓存原图）。

---

## 第五部分：实现分期（仅客户端）

### C1 — 可登录可备份 + 角标/编辑清理

- [ ] 工程骨架、SwiftUI 导航、APIClient、Keychain  
- [ ] 注册/登录/刷新/登出、设备登记  
- [ ] 权限引导文案（上传后保留本机）  
- [ ] Scanner + SyncIndex  
- [ ] Hash + check 秒传 → `backed_up`（不自动删）  
- [ ] UploadQueue（Wi‑Fi 门闩、分片、complete）→ `backed_up`  
- [ ] 时间轴三态角标  
- [ ] 编辑：过滤已备份 / >30MB / 仅云端 → 删本机或删服务端  
- [ ] 验证：上传后角标=已备份且相册仍在；编辑删本机后角标=可下载  

### C2 — 可浏览与再下载

- [ ] 时间轴分页 + 缩略图（本地/远端）  
- [ ] 大图 Viewer + MediaCache LRU  
- [ ] 视频基础播放  
- [ ] `remote_only` 保存回相册 → `backed_up`  

### C3 — 可分享

- [ ] 多选创建分享、复制链接、撤销列表  

### C4 — 体验与登录增强

- [ ] 状态面板、暂停/失败重试  
- [ ] 后台任务尽力续传  
- [ ] 短信登录 UI（P2）  
- [ ] 缓存与蜂窝策略细化  

---

## 附录 A：与产品 / 服务端文档追溯

| 产品能力 | 客户端模块 | 服务端依赖 |
|----------|------------|------------|
| 多用户密码登录 | 功能 1 | `/auth/*` |
| 短信登录（后期） | 功能 1 预留 | `/auth/sms/*` |
| 设备登记 | 功能 1b | `/devices/*` |
| 自动扫描上传 | 功能 2–4 | `/media/check`、`/upload/*` |
| 成功后删原片 | 功能 5 | complete / 秒传成功契约 |
| 时间轴大图 | 功能 6 | `/media`、derivatives、original |
| 分享 | 功能 7 | `/shares` |
| 仅 Wi‑Fi 上传 | 功能 0 + 4 | — |
| 用户隔离 | Auth 切换策略 + user_id 索引 | 服务端强制 user_id |

## 附录 B：关键实现注意（iOS 特有）

1. **Limited Photo Library**：自动备份场景强烈建议引导「完全访问」。  
2. **iCloud 优化存储**：未本机化资源需明确策略，避免蜂窝偷跑。  
3. **后台上传不可依赖**：队列状态必须落库，冷启动可恢复。  
4. **HEIC**：原样上传；与服务端存 HEIC + sips 转缩略图方案一致。  
5. **删除权限**：`PHPhotoLibrary` 写权限与用户可见的系统确认弹窗（若系统弹出）需产品文案预期。  
6. **App Store 审核**：隐私政策需写明「备份至用户自有服务器；本机原片由用户手动清理」；权限描述字符串准确。  

## 附录 C：修订记录

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.1 | 2026-09-04 | 首版：iOS 客户端整体方案 + 分功能详细设计 |
| v0.2 | 2026-09-04 | 上传后标已备份不自动删；三态角标；编辑过滤删本机；下载回相册 |
| v0.3 | 2026-09-04 | 编辑态增加已备份且 >30MB 过滤与一键删本机 |
| v0.4 | 2026-09-04 | 编辑「仅云端」过滤；调用服务端删除媒体 |
| v0.5 | 2026-09-04 | 大图边框/水印样式；故事编辑与 AI 草稿 |
