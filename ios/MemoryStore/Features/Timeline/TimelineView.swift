import SwiftUI

struct TimelineView: View {
    @EnvironmentObject private var app: AppModel
    @State private var selected: TimelineEntry?
    @State private var mode: TimelineMode = .browse
    @State private var selectedIDs: Set<String> = []
    @State private var editFilter: EditFilter = .all
    @State private var confirmDelete = false
    @State private var oneClickPending = false
    @State private var collapsedYears: Set<Int> = []
    /// 分组展示 / 全铺展示
    @AppStorage("timeline.layoutMode") private var layoutModeRaw = "grouped"

    private let sideInset: CGFloat = 20
    private let gridSpacing: CGFloat = 4
    private var cols: [GridItem] {
        [
            GridItem(.flexible(), spacing: gridSpacing),
            GridItem(.flexible(), spacing: gridSpacing),
            GridItem(.flexible(), spacing: gridSpacing),
        ]
    }

    private enum TimelineLayoutMode: String {
        case grouped
        case flat
    }

    private var layoutMode: TimelineLayoutMode {
        TimelineLayoutMode(rawValue: layoutModeRaw) ?? .grouped
    }

    private var layoutToggleIcon: String {
        // 图标表示「点一下将切换到」的目标模式
        layoutMode == .grouped ? "square.grid.3x3" : "rectangle.3.group"
    }

    private var layoutToggleHint: String {
        layoutMode == .grouped ? "切换为全铺展示" : "切换为年份分组"
    }

    private enum TimelineMode {
        case browse
        case editing
        case sharing
    }

    private enum EditFilter: String, CaseIterable, Identifiable {
        case all
        case backedUp
        case largeBackedUp
        case remoteOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "全部"
            case .backedUp: return "已备份"
            case .largeBackedUp: return ">30MB"
            case .remoteOnly: return "仅云端"
            }
        }

        var deletesRemote: Bool { self == .remoteOnly }
    }

    private struct YearSection: Identifiable {
        let year: Int
        var id: Int { year }
        let items: [TimelineEntry]

        var title: String {
            year == 0 ? "未知日期" : "\(year)"
        }
    }

    private var largeThreshold: Int64 { app.config.largeFileThresholdBytes }

    private var displayed: [TimelineEntry] {
        guard mode == .editing else { return app.gallery.timeline }
        switch editFilter {
        case .all:
            return app.gallery.timeline
        case .backedUp:
            return app.gallery.timeline.filter(\.canDeleteLocal)
        case .largeBackedUp:
            return app.gallery.timeline.filter { $0.isLargeBackedUp(threshold: largeThreshold) }
        case .remoteOnly:
            return app.gallery.timeline.filter(\.canDeleteRemote)
        }
    }

    private var yearSections: [YearSection] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: displayed) { entry -> Int in
            guard let d = entry.takenAt else { return 0 }
            return cal.component(.year, from: d)
        }
        return grouped.keys.sorted(by: >).map { year in
            let items = (grouped[year] ?? []).sorted {
                ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast)
            }
            return YearSection(year: year, items: items)
        }
    }

    private var actionableInView: [TimelineEntry] {
        if editFilter.deletesRemote {
            return displayed.filter(\.canDeleteRemote)
        }
        return displayed.filter(\.canDeleteLocal)
    }

    private var emptyTitle: String {
        switch (mode, editFilter) {
        case (.editing, .backedUp): return "没有已备份项"
        case (.editing, .largeBackedUp): return "没有大于 30MB 的已备份项"
        case (.editing, .remoteOnly): return "没有仅云端项"
        default: return "还没有回忆"
        }
    }

    private var emptyDescription: String {
        switch (mode, editFilter) {
        case (.editing, .backedUp):
            return "上传成功后会出现在这里，可删除本机原片"
        case (.editing, .largeBackedUp):
            return "已备份且超过 30MB 的照片/视频会出现在这里"
        case (.editing, .remoteOnly):
            return "本机已清理、仅保留在服务器上的项会出现在这里"
        default:
            return "连接 Wi‑Fi 后，同步页会自动备份照片"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if displayed.isEmpty && app.gallery.isLoading {
                    ProgressView("加载中…").tint(MSTheme.accent)
                } else if displayed.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "photo.on.rectangle",
                        description: Text(emptyDescription)
                    )
                } else {
                    ScrollView {
                        Group {
                            if layoutMode == .grouped {
                                groupedGrid
                            } else {
                                flatGrid
                            }
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
                    .refreshable {
                        await app.gallery.reload()
                    }
                }
            }
            .background(MSTheme.background)
            .navigationTitle("回忆")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .toolbarBackground(MSTheme.background, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if mode == .editing {
                    editBar
                }
            }
            .confirmationDialog(
                confirmMessage,
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button(confirmActionTitle, role: .destructive) {
                    Task { await performDelete() }
                }
                Button("取消", role: .cancel) {
                    oneClickPending = false
                }
            }
            .fullScreenCover(item: $selected) { item in
                ViewerView(entries: app.gallery.timeline, startID: item.id)
                    .environmentObject(app)
            }
            .task {
                await app.gallery.reload()
            }
            .onReceive(app.syncEngine.objectWillChange) { _ in
                Task { await app.gallery.rebuildTimeline() }
            }
            .onChange(of: editFilter) { _, _ in
                selectedIDs.removeAll()
            }
        }
    }

    private var groupedGrid: some View {
        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
            ForEach(yearSections) { section in
                yearHeader(section)
                    .padding(.horizontal, sideInset)

                if !collapsedYears.contains(section.year) {
                    LazyVGrid(columns: cols, spacing: gridSpacing) {
                        ForEach(section.items) { item in
                            cell(item)
                                .onAppear { loadMoreIfNeeded(item) }
                        }
                    }
                    .padding(.horizontal, sideInset)
                }
            }
        }
    }

    private var flatGrid: some View {
        LazyVGrid(columns: cols, spacing: gridSpacing) {
            ForEach(displayed) { item in
                cell(item)
                    .onAppear { loadMoreIfNeeded(item) }
            }
        }
        .padding(.horizontal, sideInset)
    }

    private func loadMoreIfNeeded(_ item: TimelineEntry) {
        if item.id == displayed.last?.id, app.gallery.hasMore {
            Task { await app.gallery.loadMore() }
        }
    }

    private func yearHeader(_ section: YearSection) -> some View {
        let collapsed = collapsedYears.contains(section.year)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if collapsed {
                    collapsedYears.remove(section.year)
                } else {
                    collapsedYears.insert(section.year)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(MSTheme.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MSTheme.muted)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityLabel(collapsed ? "展开 \(section.title)" : "收起 \(section.title)")
    }

    private var confirmMessage: String {
        if editFilter.deletesRemote {
            let n = oneClickPending ? actionableInView.count : selectedIDs.count
            return "永久删除选中的 \(n) 项云端媒体？原片与派生文件将从服务器移除，不可恢复。"
        }
        if oneClickPending {
            return "一键删除当前 \(actionableInView.count) 项本机原片？云端副本会保留，之后可再下载。"
        }
        return "删除选中项的本机原片？云端副本会保留，之后可再下载。"
    }

    private var confirmActionTitle: String {
        if editFilter.deletesRemote { return "删除云端" }
        return oneClickPending ? "一键删除本机" : "删除本机原片"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    layoutModeRaw = layoutMode == .grouped
                        ? TimelineLayoutMode.flat.rawValue
                        : TimelineLayoutMode.grouped.rawValue
                }
            } label: {
                Image(systemName: layoutToggleIcon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MSTheme.text)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(layoutToggleHint)

            if mode == .browse {
                Menu {
                    Button {
                        mode = .editing
                        editFilter = .all
                        selectedIDs.removeAll()
                        oneClickPending = false
                    } label: {
                        Label("编辑", systemImage: "checkmark.circle")
                    }
                    Button {
                        mode = .sharing
                        selectedIDs.removeAll()
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(MSTheme.text)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            } else if mode == .sharing, !selectedIDs.isEmpty {
                Button("创建链接") { Task { await shareSelected() } }
                Button("完成") { exitMode() }
            } else {
                Button("完成") { exitMode() }
                    .fontWeight(.semibold)
            }
        }
    }

    private func exitMode() {
        mode = .browse
        selectedIDs.removeAll()
        oneClickPending = false
    }

    private var editBar: some View {
        VStack(spacing: 10) {
            Picker("过滤", selection: $editFilter) {
                ForEach(EditFilter.allCases) { f in
                    Text(f.title).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if editFilter == .largeBackedUp {
                Text("已备份且超过 30MB · \(actionableInView.count) 项")
                    .font(MSTheme.captionFont)
                    .foregroundStyle(MSTheme.muted)
            } else if editFilter == .remoteOnly {
                Text("仅云端 · \(actionableInView.count) 项 · 删除不可恢复")
                    .font(MSTheme.captionFont)
                    .foregroundStyle(MSTheme.muted)
            }

            HStack {
                Button("全选") {
                    selectedIDs = Set(actionableInView.map(\.id))
                }
                .disabled(actionableInView.isEmpty)

                if editFilter == .largeBackedUp {
                    Button("一键删除") {
                        oneClickPending = true
                        selectedIDs = Set(actionableInView.map(\.id))
                        confirmDelete = true
                    }
                    .disabled(actionableInView.isEmpty)
                    .foregroundStyle(MSTheme.danger)
                }

                Spacer()
                Text("已选 \(selectedIDs.count)")
                    .font(MSTheme.captionFont)
                    .foregroundStyle(MSTheme.muted)
                Spacer()
                Button(editFilter.deletesRemote ? "删除云端" : "删除本机", role: .destructive) {
                    oneClickPending = false
                    confirmDelete = true
                }
                .disabled(selectedIDs.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func cell(_ item: TimelineEntry) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                handleTap(item)
            } label: {
                ZStack(alignment: .bottomLeading) {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            thumb(item)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    if item.mediaType == "video" {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.white.opacity(0.9))
                            .font(.title2)
                            .padding(6)
                    }
                    HStack(spacing: 4) {
                        BadgeView(badge: item.badge)
                        if mode == .editing, item.canDeleteLocal, item.byteSize > largeThreshold {
                            Text(Self.formatSize(item.byteSize))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                    }
                    .padding(6)
                }
            }
            .buttonStyle(.plain)
            .opacity(mode == .editing && !isSelectable(item) && editFilter == .all ? 0.55 : 1)

            if mode == .editing || mode == .sharing {
                let selectable = mode == .sharing ? (item.shareMediaID != nil) : isSelectable(item)
                if selectable || mode == .editing {
                    Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedIDs.contains(item.id) ? MSTheme.accent : .white)
                        .padding(6)
                        .shadow(radius: 2)
                        .opacity(selectable ? 1 : 0.25)
                }
            }
        }
    }

    @ViewBuilder
    private func thumb(_ item: TimelineEntry) -> some View {
        TimelineThumbView(entry: item, api: app.api)
    }

    private func isSelectable(_ item: TimelineEntry) -> Bool {
        if editFilter.deletesRemote { return item.canDeleteRemote }
        return item.canDeleteLocal
    }

    private func handleTap(_ item: TimelineEntry) {
        switch mode {
        case .browse:
            selected = item
        case .editing:
            guard isSelectable(item) else { return }
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
        case .sharing:
            guard item.shareMediaID != nil else { return }
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
        }
    }

    private func performDelete() async {
        if editFilter.deletesRemote {
            await deleteRemoteSelected()
        } else {
            await deleteLocalSelected(oneClick: oneClickPending)
        }
    }

    private func deleteRemoteSelected() async {
        let mediaIDs = displayed
            .filter { selectedIDs.contains($0.id) && $0.canDeleteRemote }
            .compactMap(\.remoteMediaID)
        oneClickPending = false
        guard !mediaIDs.isEmpty else { return }
        do {
            try await app.syncEngine.deleteRemoteOnly(mediaIDs: mediaIDs)
            app.gallery.removeFromTimeline(mediaIDs: mediaIDs)
            selectedIDs.removeAll()
            await app.gallery.rebuildTimeline()
            app.showToast("已删除 \(mediaIDs.count) 项云端媒体")
        } catch {
            app.showToast(error.localizedDescription)
        }
    }

    private func deleteLocalSelected(oneClick: Bool) async {
        let targets: [TimelineEntry]
        if oneClick {
            targets = actionableInView
        } else {
            targets = displayed.filter { selectedIDs.contains($0.id) && $0.canDeleteLocal }
        }
        let syncIDs = targets.compactMap(\.syncLocalID)
        oneClickPending = false
        guard !syncIDs.isEmpty else { return }
        do {
            try await app.syncEngine.deleteLocalBackedUp(syncIDs: syncIDs)
            selectedIDs.removeAll()
            await app.gallery.rebuildTimeline()
            app.showToast("已删除 \(syncIDs.count) 项本机原片")
        } catch {
            app.showToast(error.localizedDescription)
        }
    }

    private func shareSelected() async {
        let mediaIDs = displayed
            .filter { selectedIDs.contains($0.id) }
            .compactMap(\.shareMediaID)
        guard !mediaIDs.isEmpty else { return }
        do {
            let res = try await app.shareService.create(mediaIDs: mediaIDs, title: "分享相册")
            UIPasteboard.general.string = res.url
            app.showToast("分享链接已复制")
            mode = .browse
            selectedIDs.removeAll()
        } catch {
            app.showToast(error.localizedDescription)
        }
    }

    private static func formatSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 100 {
            return String(format: "%.0fMB", mb)
        }
        return String(format: "%.1fMB", mb)
    }
}

struct BadgeView: View {
    let badge: MediaBadge

    var body: some View {
        Image(systemName: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(5)
            .background(color.opacity(0.85), in: Circle())
            .accessibilityLabel(label)
    }

    private var icon: String {
        switch badge {
        case .pendingUpload: return "arrow.up.circle.fill"
        case .backedUp: return "checkmark.icloud.fill"
        case .remoteOnly: return "arrow.down.circle.fill"
        }
    }

    private var color: Color {
        switch badge {
        case .pendingUpload: return Color.orange
        case .backedUp: return MSTheme.accent
        case .remoteOnly: return Color.blue
        }
    }

    private var label: String {
        switch badge {
        case .pendingUpload: return "待上传"
        case .backedUp: return "已备份"
        case .remoteOnly: return "可下载"
        }
    }
}

struct TimelineThumbView: View {
    let entry: TimelineEntry
    let api: APIClient
    @State private var localFailed = false

    var body: some View {
        let hasLocal = !(entry.phAssetID ?? "").isEmpty
        if hasLocal, !localFailed, let ph = entry.phAssetID {
            LocalAssetThumbnail(phAssetID: ph) {
                localFailed = true
            }
        } else if let mid = entry.remoteMediaID {
            AuthenticatedImage(path: "/api/v1/media/\(mid)/derivatives/thumb_md", api: api)
        } else {
            Rectangle().fill(MSTheme.border)
                .overlay(Image(systemName: "photo").foregroundStyle(MSTheme.muted))
        }
    }
}

struct LocalAssetThumbnail: View {
    let phAssetID: String
    var onFailed: (() -> Void)? = nil
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(MSTheme.border.opacity(0.5))
            }
        }
        .task(id: phAssetID) {
            image = nil
            if let img = await LocalMediaImageLoader.thumbnail(phAssetID: phAssetID) {
                image = img
            } else {
                onFailed?()
            }
        }
    }
}
