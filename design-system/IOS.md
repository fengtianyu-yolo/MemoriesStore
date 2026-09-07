# MemoryStore Design System（iOS 适配）

> 来源：ui-ux-pro-max；实现以 SwiftUI 为准（见 `ios/MemoryStore/Core/Theme/MSTheme.swift`）。

## 视觉方向

- **模式**：私人相册 / Gallery — 黑白画廊 + 留白，照片本身是色彩
- **主色**：`#18181B`
- **背景**：`#FAFAFA`
- **强调**：`#0F766E`（teal，避免紫色套路）
- **字体**：品牌用系统 Serif；正文用 Rounded

## 动效

- 登录标题入场约 450ms
- Toast / 双击缩放 200–250ms

## 页面结构

- 登录 → 回忆（网格）→ 同步 → 设置
