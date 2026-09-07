import SwiftUI

struct SyncStatusView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationStack {
            List {
                if app.usingLANFastPath {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "bolt.horizontal.circle.fill")
                                .font(.title3)
                                .foregroundStyle(MSTheme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("处于局域网快传模式")
                                    .font(MSTheme.bodyFont.weight(.semibold))
                                    .foregroundStyle(MSTheme.text)
                                Text("当前经局域网直连服务器，上传与浏览不走公网。\n\(app.activeBaseURL.absoluteString)")
                                    .font(MSTheme.captionFont)
                                    .foregroundStyle(MSTheme.muted)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section("状态") {
                    LabeledContent("引擎", value: app.syncEngine.isPaused ? "暂停" : (app.syncEngine.isRunning ? "运行中" : "停止"))
                    LabeledContent("当前", value: app.syncEngine.statusText)
                    LabeledContent("网络", value: {
                        if app.network.isWifi && !app.network.isCellular { return "Wi‑Fi" }
                        if app.network.isCellular { return "蜂窝" }
                        if app.network.isConnected { return "其他" }
                        return "离线"
                    }())
                    LabeledContent("访问通道", value: app.usingLANFastPath ? "局域网快传" : "公网")
                    if app.network.isCellular || app.network.isExpensive {
                        Text("当前为蜂窝/昂贵网络，自动上传已暂停（需 Wi‑Fi）")
                            .font(MSTheme.captionFont)
                            .foregroundStyle(.orange)
                    }
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
                    if !app.auth.isAuthenticated {
                        Button("去登录") {
                            app.presentLogin()
                        }
                    } else if app.syncEngine.isRunning {
                        Button(app.syncEngine.isPaused ? "恢复同步" : "暂停同步") {
                            app.syncEngine.togglePause()
                        }
                    } else {
                        Button("开始同步") {
                            app.startSyncManually()
                        }
                    }
                    Button("立即扫描相册") {
                        Task { await app.syncEngine.scanLibrary() }
                    }
                    .disabled(!app.auth.isAuthenticated)
                    Text("启动后会先展示本机相册；登录后与云端合并。可同步时会询问是否开始备份。")
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
                    if app.auth.isAuthenticated, let u = app.auth.user {
                        LabeledContent("用户", value: u.display_name)
                        LabeledContent("用户名", value: u.username)
                        Button("退出登录", role: .destructive) {
                            Task { await app.logout() }
                        }
                    } else {
                        Button {
                            app.presentLogin()
                        } label: {
                            HStack {
                                Text("去登录")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(MSTheme.muted)
                            }
                        }
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
                    LabeledContent("访问通道", value: app.usingLANFastPath ? "局域网快传" : "公网")
                    LabeledContent("当前地址", value: app.activeBaseURL.absoluteString)
                    if app.usingLANFastPath {
                        Text("公网入口：\(app.publicBaseURL.absoluteString)")
                            .font(MSTheme.captionFont)
                            .foregroundStyle(MSTheme.muted)
                    }
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
