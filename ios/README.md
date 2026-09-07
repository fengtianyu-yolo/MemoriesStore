# MemoryStore iOS

SwiftUI 客户端，对接家中 MemoryStore Server。

## 生成工程

```bash
cd ios
xcodegen generate
open MemoryStore.xcodeproj
```

## 联调

1. 启动服务端（真机需监听 `0.0.0.0`，不要用仅本机的 `127.0.0.1`）：

```bash
cd ../server
go run ./cmd/memorystore -config configs/config.example.yaml
```

启动日志应类似：`addr=0.0.0.0:10002`。可用浏览器访问 `http://120.48.22.80:10002/health` 验证公网入口。

2. **默认配置**：`AppConfig.baseURL` 为 `http://120.48.22.80:10002`（云服务器 FRP 穿透）。
3. **覆盖地址**：可用环境变量 `MEMORYSTORE_BASE_URL`（如局域网调试 `http://192.168.x.x:10002`）。
4. Info.plist 已为公网 IP 配置 ATS HTTP 例外；真机需能访问公网。

## 功能

- 注册 / 登录 / Keychain 会话
- Wi‑Fi 下扫描相册、SHA-256、秒传 / 分片上传
- 上传成功后标记「已备份」并保留本机原片
- 时间轴三态角标（待上传 / 已备份 / 可下载）
- 编辑模式：过滤已备份 → 多选 → 删除本机原片
- 仅远端项可下载回系统相册
- 大图浏览、创建分享链接
