import SwiftUI

struct SyncStatusView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    LabeledContent("引擎", value: app.syncEngine.isPaused ? "暂停" : (app.syncEngine.isRunning ? "运行中" : "停止"))
                    LabeledContent("当前", value: app.syncEngine.statusText)
                    LabeledContent("网络", value: app.network.isWifi ? "Wi‑Fi" : (app.network.isConnected ? "蜂窝/其他" : "离线"))
                    if app.syncEngine.scanProgress > 0, app.syncEngine.scanProgress < 1 {
                        ProgressView(value: app.syncEngine.scanProgress)
                    }
                    if app.syncEngine.isThermalThrottled {
                        Text("设备发热中，同步已自动降速")
                            .font(MSTheme.captionFont)
                            .foregroundStyle(.orange)
                    }
                }
                Section("计数") {
                    LabeledContent("待处理", value: "\(app.syncEngine.pendingCount)")
                    LabeledContent("已备份", value: "\(app.syncEngine.uploadedCount)")
                    LabeledContent("仅远端", value: "\(app.syncEngine.purgedCount)")
                    LabeledContent("失败", value: "\(app.syncEngine.failedCount)")
                }
                if let err = app.syncEngine.lastError {
                    Section("最近错误") {
                        Text(err).foregroundStyle(MSTheme.danger).font(MSTheme.captionFont)
                    }
                }
                Section {
                    Button(app.syncEngine.isPaused ? "恢复同步" : "暂停同步") {
                        app.syncEngine.togglePause()
                    }
                    Button("立即扫描相册") {
                        Task { await app.syncEngine.scanLibrary() }
                    }
                    Text("首次安装若相册很大，会分批扫描并限速哈希/上传，可随时在本页暂停。")
                        .font(MSTheme.captionFont)
                        .foregroundStyle(MSTheme.muted)
                }
            }
            .navigationTitle("同步")
            .background(MSTheme.background)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("账号") {
                    if let u = app.auth.user {
                        LabeledContent("用户", value: u.display_name)
                        LabeledContent("用户名", value: u.username)
                    }
                    Button("退出登录", role: .destructive) {
                        Task { await app.logout() }
                    }
                }
                Section {
                    Picker("大图样式", selection: Binding(
                        get: { app.viewerPrefs.style },
                        set: { app.viewerPrefs.style = $0 }
                    )) {
                        ForEach(ViewerDisplayStyle.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("大图展示")
                } footer: {
                    Text(app.viewerPrefs.style.subtitle)
                        .font(MSTheme.captionFont)
                }
                Section("服务") {
                    LabeledContent("地址", value: app.config.baseURL.absoluteString)
                    Text("仅 Wi‑Fi 自动上传：\(app.config.wifiOnlyUpload ? "开" : "关")")
                        .font(MSTheme.captionFont)
                        .foregroundStyle(MSTheme.muted)
                }
                Section("关于") {
                    Text("MemoryStore 会在上传成功后标记为已备份并保留本机原片；可在回忆页编辑模式中手动删除已备份项的本机副本。大图支持边框/水印样式与照片故事。数据保存在您的私人服务器。")
                        .font(MSTheme.captionFont)
                        .foregroundStyle(MSTheme.muted)
                }
            }
            .navigationTitle("设置")
        }
    }
}
