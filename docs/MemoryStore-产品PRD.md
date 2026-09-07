# MemoryStore 产品需求文档（PRD）

> 版本：基于当前客户端（iOS）与服务端实现梳理  
> 产品定位：私人照片/视频备份与浏览应用，数据保存在用户自建服务器（家中 iMac），客户端可未登录浏览本机相册，登录后与云端合并并支持备份同步。

---

## 1. 产品概述

### 1.1 目标用户

希望将手机相册备份到自有服务器、并在 App 内浏览回忆的个人用户。

### 1.2 核心价值

| 价值点 | 说明 |
|--------|------|
| 本机优先 | 未登录也能立刻看到系统相册 |
| 私有云备份 | 登录后与家中服务器合并，支持上传/下载 |
| 局域网快传 | 同网段时自动改走家中 LAN IP，上传/浏览不经公网 FRP |
| 状态可视 | 每张照片清晰展示：待上传 / 处理中 / 已备份 / 仅云端 |
| 大图体验 | 边框 / 水印杂志两种浏览样式，支持故事文案 |

### 1.3 信息架构（客户端）

```
App 启动 → 主界面（Tab）
├── 回忆（列表）
├── 同步
└── 设置
     └── 账号（登录 Present / 退出）
大图浏览（全屏 Present）
登录页（Sheet Present）
```

### 1.4 关键数据源

| 数据源 | 存储位置 | 用途 |
|--------|----------|------|
| 系统相册 | Photos 框架（PHAsset） | 列表本地项、缩略图、大图本地原图、同步扫描 |
| 同步索引 | 本机 JSON（按 userID）`SyncIndexStore` | 本地项与远端映射、上传进度、角标状态真相源之一 |
| 服务端媒体库 | 服务器 SQLite + 外接盘媒体文件 | 云端列表、原片/派生图、故事字段 |
| 会话 | Keychain（TokenStore） | access/refresh token、缓存用户资料 |

---

## 2. 模块总览

| 模块 | 入口 | 主要职责 |
|------|------|----------|
| 用户模块 | 设置 → 账号；启动会话恢复 | 注册/登录/登出、会话校验、设备注册 |
| 网络接入（局域网快传） | App 启动自动 | discovery → LAN 探测 → 切换 API 基址 |
| 列表模块（回忆） | Tab「回忆」 | 展示相册时间轴、编辑/分享、进入大图 |
| 大图浏览模块 | 列表点击进入 | 分页浏览、样式渲染、故事编辑、保存到相册 |
| 同步模块 | Tab「同步」；启动确认弹窗 | 扫描相册、哈希、上传、状态机推进 |
| 设置模块 | Tab「设置」 | 账号、大图样式、访问通道与地址 |

---

## 3. 用户模块

### 3.1 状态

| 状态 | 判定 | 表现 |
|------|------|------|
| 未登录 | 无 access token / `isAuthenticated == false` | 可进主界面；账号区显示「去登录」；不同步、不拉云端列表 |
| 已登录（会话有效） | Keychain 有 token，且 `/api/v1/me` 成功 | 显示用户信息；可同步；拉云端列表并合并 |
| 会话失效 | 有本地 token 但 `/me` 失败 | 清空会话，保持主界面未登录体验 |

### 3.2 功能实现

#### 启动

1. **直接进入主界面**（无登录 loading 页）。
2. **局域网快传解析**（见第 3A 章）：经公网 discovery → 探测 LAN → 可能切换 `APIClient.baseURL`。
3. 并行：加载本机相册列表。
4. 若本地有会话：请求 `GET /api/v1/me`（走当前 active 基址）  
   - 成功 → 绑定用户同步索引 → 拉取服务端媒体列表并合并 → 条件满足时弹出「是否开始同步」  
   - 失败 → 清会话，仅保留本机列表。

#### 登录 / 注册

- 入口：设置「去登录」或同步页「去登录」→ **Sheet Present** 登录页。
- 注册：`POST /api/v1/auth/register` → 再登录。
- 登录：`POST /api/v1/auth/login` → 写入 Token + 用户资料 → `POST /api/v1/devices/register`。
- 登录成功后：
  1. 关闭登录页；
  2. `SyncIndexStore.bind(userID)`；
  3. **自动刷新列表**（本机 + 服务端合并）；
  4. 再次评估是否弹出同步确认。

#### 退出

- `POST /api/v1/auth/logout`（失败也本地清会话）。
- 停止同步引擎。
- 列表 `reload(authenticated: false)`：清空服务端 items，仅展示本机相册。
- **仍留在主界面**，不强制跳登录页。

---

## 3A. 网络接入模块（局域网快传）

### 3A.1 目标

手机与家中服务器处于同一局域网时，**自动改走 LAN IP** 访问 API（含大文件分片上传），避免经云服务器 FRP 公网中转，提升速度与稳定性。

### 3A.2 状态

| 状态 | 判定 | 表现 |
|------|------|------|
| 公网通道 | LAN 探测失败或不可用 | `usingLANFastPath = false`；请求走 `AppConfig.baseURL`（如 `http://120.48.22.80:10002`） |
| 局域网快传 | `/health` 对某 LAN 候选成功 | `usingLANFastPath = true`；请求走 `http://{lan_ip}:{port}`；Toast「已切换局域网快传」 |
| 缓存命中 | UserDefaults 存有上次成功 LAN 且仍可达 | 跳过公网 discovery，直接快传 |

### 3A.3 服务端

公开接口（**无需登录**）：

`GET /api/v1/network/discovery`

响应 `data` 示例：

```json
{
  "listen_port": 10002,
  "public_base_url": "http://120.48.22.80:10002",
  "lan_ipv4": ["192.168.31.20", "172.20.10.2"]
}
```

| 字段 | 来源 |
|------|------|
| `listen_port` | 配置 `server.listen` 解析出的端口 |
| `public_base_url` | 配置 `server.public_base_url` |
| `lan_ipv4` | 本机网卡私有 IPv4（排除回环/链路本地；优先 192.168 → 10 → 172） |

分享链接等**对外 URL 仍使用**服务端 `public_base_url`，不受客户端快传切换影响。

### 3A.4 客户端流程

```
启动
  ├─ 若缓存 LAN 可达 → 切换 baseURL → 结束
  ├─ 否则用公网 baseURL 请求 /api/v1/network/discovery
  ├─ 并行探测各 http://{lan_ipv4}:{port}/health（短超时 ~0.8s）
  ├─ 首个成功 → 缓存并切换 APIClient.baseURL
  └─ 全部失败 → 保持公网
随后：相册加载 / 登录校验 / 同步 均使用 activeBaseURL
```

### 3A.5 设置展示

| 项 | 内容 |
|----|------|
| 访问通道 | 「局域网快传」或「公网」 |
| 当前地址 | `activeBaseURL` |
| 公网入口 | 快传启用时附带展示配置中的公网地址 |

### 3A.6 边界

- 不在家中 Wi‑Fi / 与服务器不同网段 → 自动回落公网。  
- 公网 discovery 本身不可达 → 无法获知 LAN，保持配置基址（可手动设 `MEMORYSTORE_BASE_URL` 为 LAN）。  
- ATS：依赖 `NSAllowsLocalNetworking`；公网 HTTP IP 另有例外配置。

---

## 4. 列表模块（回忆）

### 4.1 模块状态

| 状态维度 | 取值 | 说明 |
|----------|------|------|
| 登录态 | 未登录 / 已登录 | 决定是否请求服务端、角标是否含云端语义 |
| 加载态 | 空闲 / 加载本机 / 加载云端 | `isLoadingLocal` / `isLoading` |
| 浏览模式 | 浏览 / 编辑 / 分享 | Toolbar 切换 |
| 布局 | 年份分组 / 全铺网格 | AppStorage 持久化 |
| 列表内容 | 空 / 有数据 | 空态文案随过滤条件变化 |

### 4.2 未登录：数据如何读取与展示

**读取**

1. 申请相册权限（`readWrite`）。
2. `PHAsset.fetchAssets` 拉取全部图片/视频，**只取元数据**（localIdentifier、类型、拍摄时间、宽高、时长）。
3. **不**在列表阶段解码原图像素；不请求服务端 API。

**展示**

1. 每条生成本地 `TimelineEntry`：  
   - `id = "ph:{phAssetID}"`  
   - `phAssetID` 有值  
   - `remoteMediaID` 为空（除非本地残留索引，未登录通常无用户索引）  
   - `badge = pendingUpload`（待上传）
2. 按 `takenAt` 倒序；支持年份折叠 / 全铺。
3. 缩略图：`LocalMediaImageLoader.thumbnail`  
   - 目标尺寸 ≈ 屏宽 1/3 × screenScale  
   - `deliveryMode = fastFormat`，`resizeMode = fast`  
   - 优先本机缓存，不默认拉 iCloud 原图。

**可操作能力**

| 操作 | 未登录 |
|------|--------|
| 浏览大图（本地项） | ✅ |
| 编辑故事 / 保存到相册（云端能力） | ❌（无 remote） |
| 分享链接 | ❌（需 remoteMediaID） |
| 删除本机已备份副本 | ❌（无已备份态） |
| 下拉刷新 | 重新扫本机相册 |

### 4.3 已登录：数据如何读取与展示

**读取流水线**

```
① loadLocalPhotos()     ← 系统相册元数据（立刻上屏）
② fetchRemoteAndMerge() ← GET /api/v1/media?limit=60&cursor=… 分页
③ mergeTimeline()       ← 本地库 + 服务端 items + SyncIndexStore 三方合并
```

分页策略：每拉回一页服务端数据就执行一次合并，云端状态尽快出现在列表上；直到 `next_cursor` 为空。

**合并规则（`mergeTimeline`）**

1. **服务端项优先落入结果集**  
   - 用 `SyncIndexStore` 按 `remoteMediaID` 或 `content_hash` 查找本地同步记录。  
   - 若找到 `phAssetID`：列表项可走本地缩略图；标记该 PH 已被占用。  
   - 角标：优先取同步记录的 `badge`；无同步记录且无本机 PH → `remoteOnly`；无同步记录但有 PH → `pendingUpload`（少见，过渡态）。  
   - 故事/标题/地点：来自服务端字段 `story` / `title` / `place_name`。

2. **插入仅服务端有的照片**  
   - 无对应本机 PH 的服务端媒体 → 以 `id = media_id`、`badge = remoteOnly` 插入。

3. **保留仅本机有的照片**  
   - 未被服务端占用的 PHAsset → `id = "ph:…"`。  
   - 角标：若有同步索引用其 `badge`，否则 `pendingUpload`。  
   - 若同步索引已指向某 `remoteMediaID` 且该 ID 已在服务端列表中，则不再重复插本地行。

4. 最终按拍摄时间倒序排序。

**展示**

- 有本机 `phAssetID`：本地缩略图（同上，不加载原图）。  
- 仅云端：请求 `GET /api/v1/media/{id}/derivatives/thumb_sm`（小图派生，需登录鉴权）。  
- 角标角标叠加在格子左下（见第 5 章）。

**下拉刷新**

`reload(authenticated: true)` = 重新扫本机 + 重新拉全部分页云端并合并。

**滚动加载更多**

触底且 `hasMore`（仍有 cursor）时 `loadMore()` 继续请求服务端下一页并再次合并。

### 4.4 列表交互子状态

| 模式 | 行为 |
|------|------|
| 浏览 | 点击进入大图 |
| 编辑 | 过滤：全部 / 已备份 / >30MB / 仅云端；多选删除本机副本或删除云端 |
| 分享 | 多选有 `remoteMediaID` 的项 → 创建分享链接并复制 |

---

## 5. 照片状态（角标）逻辑

### 5.1 对外三种角标（UI）

| 角标 `MediaBadge` | 视觉 | 用户含义 |
|-------------------|------|----------|
| `pendingUpload` | 橙 · 上箭头 | 待上传 |
| `processing` | 靛 · 转圈 Progress | 处理中（哈希 / 上传中） |
| `backedUp` | 主题色 · 云勾 | 已备份（本机仍有原片） |
| `remoteOnly` | 蓝 · 下箭头 | 仅云端（可下载回相册） |

### 5.2 内部同步状态机（SyncAssetStatus → 角标）

同步引擎写入 `SyncIndexStore`，列表角标**主要从这里映射**：

| SyncAssetStatus | 映射角标 | 含义 |
|-----------------|----------|------|
| discovered / pending_upload / failed / waiting_local_resource | pendingUpload | 等待上传 |
| hashing / uploading | processing | 正在处理 |
| backed_up | backedUp | 上传完成且本机仍关联 PHAsset |
| remote_only | remoteOnly | 本机原片已删或仅云端存在 |

映射代码逻辑：`SyncAsset.badge`。

### 5.3 角标从哪里读、何时更新

```
                    ┌─────────────────┐
  系统相册扫描 ───► │ SyncIndexStore  │ ◄─── 上传完成 / 删本机 / 下载
  （SyncEngine）    │  (本机 JSON)    │
                    └────────┬────────┘
                             │ badge
                             ▼
  服务端 /media ────► GalleryService.mergeTimeline() ──► TimelineEntry.badge
  本机 PH 元数据 ───►
```

| 时机 | 更新方式 |
|------|----------|
| 打开 App / 下拉刷新 | `loadLocalPhotos` +（登录态）`fetchRemoteAndMerge` → `mergeTimeline` |
| 登录成功 | `reload(authenticated: true)` 全量刷新合并 |
| 同步引擎推进（哈希/上传/失败） | SyncEngine 更新 Store → Timeline 监听 `objectWillChange` → `rebuildTimeline` |
| 删除本机已备份副本 | 引擎将状态改为 remote_only → 重建时间轴 |
| 下载回相册 | 建立/更新本地 Sync 记录与 PHAsset → 角标变为 backedUp 或相应态 |
| 退出登录 | 清空服务端 items，按本机库重建，角标回到 pendingUpload（无用户索引时） |

### 5.4 能力与角标的关系

| 能力 | 条件 |
|------|------|
| 可删本机原片（保留云端） | `backedUp` 且有 remoteMediaID、syncLocalID、phAssetID |
| 可删云端 | `remoteOnly` 且有 remoteMediaID |
| 可下载回相册 | `remoteOnly` 且有 remoteMediaID |
| 可编辑故事 | 有 remoteMediaID（通常已在云端） |
| 可分享 | 有 remoteMediaID |

---

## 6. 大图浏览模块

### 6.1 状态

| 状态 | 说明 |
|------|------|
| 样式 | 边框模式 / 水印杂志（设置中选择，UserDefaults 持久化） |
| 当前页 | TabView 分页，`currentID` |
| 操作面板 | 右上角「…」→ confirmationDialog |
| 故事编辑 | Sheet：标题 / 地点 / 故事；可 AI 草稿后保存 |

### 6.2 图片加载策略（注意性能分层）

| 场景 | 策略 |
|------|------|
| 列表缩略图 | 本地：小尺寸 fastFormat；云端：thumb_sm |
| 大图展示 | 优先 `LocalMediaImageLoader.fullImage(phAssetID)`；失败再用 `GET …/original` |
| EXIF / 文案 | 从本地原图字节或服务端故事字段 |

### 6.3 操作实现

| 操作 | 条件 | 实现 |
|------|------|------|
| 编辑故事 | 有 remoteMediaID | `PATCH /api/v1/media/{id}`；AI：`POST …/story/ai`（草稿不自动落库） |
| 保存到相册 | canDownload（仅云端） | 下载 original → 写入系统相册 → 更新同步索引与时间轴 |
| 关闭 | 任意 | dismiss 全屏 |

无可用云端操作时：仍弹出面板，文案提示需先上传或仅云端才可下载。

---

## 7. 同步模块

### 7.1 状态

| 状态 | 说明 |
|------|------|
| 引擎 | 停止 / 运行中 / 暂停 |
| 网络 | 离线 / 蜂窝 / Wi‑Fi（默认仅 Wi‑Fi 上传） |
| 文案 statusText | 空闲、扫描中、等待 Wi‑Fi、发热降速、已同步、出错等 |
| 计数 | 待处理 / 已备份 / 仅远端 / 失败 |
| 启动确认 | 每会话最多自动询问一次 |

### 7.2 何时可以同步

需同时满足：

1. 已登录  
2. 网络可达（`wifiOnlyUpload == true` 时还需 Wi‑Fi）  
3. `GET /health` 成功  

满足后弹窗：「开始同步？」→ 确认则 `SyncEngine.start()`；暂不则保持停止，可在同步页手动开始。

未登录：同步页展示「去登录」，不启动引擎。

### 7.3 同步实现流程

```
start()
  ├─ 监听相册变更（防抖后重扫）
  └─ runLoop()
        ├─ scanLibrary()：权限 → 枚举 PHAsset → upsert 到 SyncIndexStore（仅元数据批次）
        └─ 循环取 pendingWork
              ├─ 哈希（指纹，照片尽量内存哈希，控制发热）
              ├─ POST /media/check 秒传
              ├─ 分片上传 init / chunk / complete
              └─ 更新 status → backed_up，刷新计数与列表角标
```

热管理：设备过热时拉长间隔；任务间 sleep，避免连续打满 CPU。

### 7.4 与列表的关系

- 同步**不负责**画列表；列表由 GalleryService 合并。  
- 同步写入 Store 后，列表通过 `rebuildTimeline` **消费**最新 badge。  
- 因此：先看到本地列表（pending），备份成功后角标变为已备份，无需整表重下本机相册。

---

## 8. 设置模块

### 8.1 分组与状态

| 分组 | 未登录 | 已登录 |
|------|--------|--------|
| 账号 | 「去登录」→ Present 登录 | 显示昵称/用户名；「退出登录」 |
| 大图展示 | 边框 / 水印杂志选择 | 同左 |
| 服务 | 访问通道（公网/局域网快传）、当前地址、仅 Wi‑Fi 说明 | 同左 |
| 关于 | 产品说明 | 同左 |

### 8.2 配置来源

| 项 | 来源 |
|----|------|
| 公网/默认地址 | `AppConfig.baseURL`（可用环境变量 `MEMORYSTORE_BASE_URL` 覆盖） |
| 当前访问地址 | 启动局域网快传解析后的 `activeBaseURL` |
| 仅 Wi‑Fi | `AppConfig.wifiOnlyUpload`（当前默认 true） |
| 大图样式 | `ViewerPreferences` → UserDefaults |
| 上次成功 LAN | UserDefaults `ms.lastLANBaseURL` |

---

## 9. 端到端主路径（摘要）

### 9.1 未登录用户

```
启动 → 主界面回忆
  → 局域网快传探测（可能切换至 LAN）
  → 授权相册 → 元数据列表 + 缩略图
  → 可浏览本机大图
  → 设置「去登录」才进入账号体系
```

### 9.2 登录用户

```
启动 → 主界面
  → 局域网快传探测
  → 先本机列表
  → 校验会话 → 拉 /media 合并（插入仅云端 + 更新角标）
  → 询问是否同步
  → 确认后扫描/哈希/上传（走 activeBaseURL，同网段为 LAN）→ Store 更新 → 列表角标刷新
```

### 9.3 退出

```
退出 → 停同步 → 清 Token
  → 列表仅本机 → 仍停留主界面
```

---

## 10. 非功能需求（与实现一致）

| 类别 | 要求 |
|------|------|
| 列表性能 | 禁止列表阶段加载原图；缩略图限制像素尺寸与 fastFormat |
| 启动体验 | 不因登录校验阻塞进入列表 |
| 隐私 | 媒体默认存用户自有服务器；Token 存 Keychain |
| 网络策略 | 默认仅 Wi‑Fi 自动上传；同网段优先局域网快传；否则走公网 FRP |
| 安全 | 生产 HTTP 入口需 ATS 例外（当前对公网 IP 配置）；后续建议 HTTPS |

---

## 11. 模块 × 状态矩阵（速查）

| 模块 | 未登录 | 已登录 · 未开同步 | 已登录 · 同步中 |
|------|--------|-------------------|-----------------|
| 网络接入 | 可快传则 LAN，否则公网 | 同左 | 同左（上传走 active 基址） |
| 列表 | 仅本机，角标待上传 | 本机+云端合并 | 合并结果 + 角标随 Store 变 |
| 大图 | 本地原图浏览 | 本地优先，云端可故事/下载 | 同左 |
| 同步 | 引导登录 | 可手动开始 / 曾弹确认 | 扫描上传循环 |
| 设置·账号 | 去登录 | 用户信息 / 退出 | 同左 |
| 用户会话 | 无 Token | Token + /me 有效 | 同左 |

---

## 12. 后续可演进（非当前必须）

- 局域网快传：Bonjour / 多网卡优先级可配置、失败自动回切公网提示  
- 未登录分享/多设备冲突提示  
- 列表虚拟化与差分刷新（大数据量）  
- HTTPS / 自定义域名  
- 同步冲突与「跳过本项」策略产品化  
- 故事 AI 接真实大模型  

---

*本文档描述「当前已实现」行为，作为产品与研发对齐基线；若实现变更，应同步修订本章。*
