import SwiftUI
import UIKit

struct AuthenticatedImage: View {
    let path: String
    let api: APIClient
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Rectangle().fill(MSTheme.border)
                    .overlay(Image(systemName: "photo").foregroundStyle(MSTheme.muted))
            } else {
                Rectangle().fill(MSTheme.border.opacity(0.5))
                    .overlay(ProgressView().tint(MSTheme.muted))
            }
        }
        .task(id: path) {
            failed = false
            image = nil
            do {
                let data = try await api.download(path: path)
                if let ui = UIImage(data: data) {
                    image = ui
                    return
                }
            } catch {}
            if path.contains("derivatives") {
                let parts = path.split(separator: "/")
                if let mediaIdx = parts.firstIndex(of: "media"), mediaIdx + 1 < parts.count {
                    let mid = String(parts[mediaIdx + 1])
                    if let data = try? await api.download(path: "/api/v1/media/\(mid)/original"),
                       let ui = UIImage(data: data) {
                        image = ui
                        return
                    }
                }
            }
            failed = true
        }
    }
}

struct ViewerView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let entries: [TimelineEntry]
    let startID: String
    @State private var currentID: String
    @State private var busy = false
    @State private var showStoryEditor = false
    @State private var showActions = false
    @State private var showNoActionAlert = false

    init(entries: [TimelineEntry], startID: String) {
        self.entries = entries
        self.startID = startID
        _currentID = State(initialValue: startID)
    }

    private var current: TimelineEntry? {
        app.gallery.timeline.first { $0.id == currentID } ?? entries.first { $0.id == currentID }
    }

    private var currentIndexLabel: String {
        let list = app.gallery.timeline.isEmpty ? entries : app.gallery.timeline
        guard let idx = list.firstIndex(where: { $0.id == currentID }) else { return "" }
        return "\(idx + 1)/\(list.count)"
    }

    private var canEditStory: Bool { current?.remoteMediaID != nil }
    private var canSaveToLibrary: Bool {
        guard let cur = current else { return false }
        return cur.canDownload && cur.remoteMediaID != nil
    }

    var body: some View {
        ZStack {
            TabView(selection: $currentID) {
                ForEach(displayEntries) { item in
                    StyledViewerPage(entry: item, style: app.viewerPrefs.style, api: app.api)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // 顶栏单独叠层，避免被分页 TabView 吞掉点击；空白区域不拦截手势
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(chromeForeground)
                            .frame(width: 44, height: 44)
                            .background(chromeBackground, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                    Text(currentIndexLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(chromeForeground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(chromeBackground, in: Capsule())
                    Spacer(minLength: 0)

                    Button {
                        if canEditStory || canSaveToLibrary {
                            showActions = true
                        } else {
                            showNoActionAlert = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(chromeForeground)
                            .frame(width: 44, height: 44)
                            .background(chromeBackground, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
            }
            .zIndex(10)
        }
        .confirmationDialog("照片操作", isPresented: $showActions, titleVisibility: .visible) {
            if canEditStory {
                Button("编辑故事") { showStoryEditor = true }
            }
            if canSaveToLibrary, let mid = current?.remoteMediaID {
                Button("保存到相册") { Task { await save(mid) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("选择要执行的操作")
        }
        .alert("暂无可用操作", isPresented: $showNoActionAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("该项尚未上传到云端。上传完成后可编辑故事；仅云端项可保存回相册。")
        }
        .sheet(isPresented: $showStoryEditor) {
            if let mid = current?.remoteMediaID {
                StoryEditSheet(
                    mediaID: mid,
                    initialTitle: current?.title ?? "",
                    initialPlace: current?.placeName ?? "",
                    initialStory: current?.story ?? ""
                )
                .environmentObject(app)
            }
        }
    }

    private var displayEntries: [TimelineEntry] {
        app.gallery.timeline.isEmpty ? entries : app.gallery.timeline
    }

    private var chromeForeground: Color {
        app.viewerPrefs.style == .watermark ? MSTheme.text : .white
    }

    private var chromeBackground: Color {
        app.viewerPrefs.style == .watermark
            ? Color.white.opacity(0.72)
            : Color.black.opacity(0.35)
    }

    private func save(_ mediaID: String) async {
        busy = true
        defer { busy = false }
        do {
            try await app.syncEngine.downloadToLibrary(remoteMediaID: mediaID, mediaType: current?.mediaType ?? "photo")
            await app.gallery.rebuildTimeline()
            app.showToast("已保存到相册")
        } catch {
            app.showToast(error.localizedDescription)
        }
    }
}

struct StyledViewerPage: View {
    let entry: TimelineEntry
    let style: ViewerDisplayStyle
    let api: APIClient
    @State private var image: UIImage?
    @State private var exif = PhotoEXIFInfo()
    @State private var loading = true

    var body: some View {
        Group {
            switch style {
            case .border:
                BorderStyleViewer(entry: entry, image: image, exif: exif, loading: loading)
            case .watermark:
                WatermarkStyleViewer(entry: entry, image: image, exif: exif, loading: loading)
            }
        }
        .task(id: entry.id) {
            await loadImage()
        }
    }

    private func loadImage() async {
        loading = true
        defer { loading = false }
        image = nil
        exif = PhotoEXIFInfo()

        // 1) 本地相册优先
        if let ph = entry.phAssetID, !ph.isEmpty {
            if let local = await LocalMediaImageLoader.fullImage(phAssetID: ph) {
                image = local.image
                exif = PhotoEXIFReader.read(from: local.data)
                return
            }
        }

        // 2) 仅云端 / 本地不可读时再请求服务端
        if let mid = entry.remoteMediaID {
            if let data = try? await api.download(path: "/api/v1/media/\(mid)/original") {
                image = UIImage(data: data)
                exif = PhotoEXIFReader.read(from: data)
            }
        }
    }
}

// MARK: - Style 1 Border

struct BorderStyleViewer: View {
    let entry: TimelineEntry
    let image: UIImage?
    let exif: PhotoEXIFInfo
    let loading: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 40)
                        .overlay(Color.black.opacity(0.32))
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                }

                VStack(spacing: 20) {
                    Spacer(minLength: 64)

                    Group {
                        if let image {
                            let containerWidth = geo.size.width - 48 // 左右各 24
                            let aspect = image.size.height / max(image.size.width, 1)
                            let containerHeight = containerWidth * aspect

                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: containerWidth, height: containerHeight)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                // 双层阴影营造悬浮立体感
                                .shadow(color: .black.opacity(0.55), radius: 32, x: 0, y: 18)
                                .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                                )
                        } else if loading {
                            ProgressView().tint(.white)
                                .frame(width: geo.size.width - 48, height: 220)
                        } else {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Color.white.opacity(0.12))
                                .frame(width: geo.size.width - 48, height: 220)
                                .overlay(Text("无法加载").foregroundStyle(.white.opacity(0.7)))
                        }
                    }
                    .frame(maxWidth: .infinity)

                    metaBlock
                        .padding(.horizontal, 32)

                    Spacer(minLength: 48)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
    }

    private var metaBlock: some View {
        VStack(spacing: 8) {
            if !entry.story.isEmpty {
                Text(entry.story)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            } else {
                if let camera = exif.cameraLine {
                    Text(camera)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                }
                if let exposure = exif.exposureLine {
                    Text(exposure)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            HStack(spacing: 16) {
                Text(dateTimeText)
                if !placeText.isEmpty {
                    Text("·")
                    Text(placeText)
                }
            }
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var dateTimeText: String {
        let d = exif.takenAt ?? entry.takenAt
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f.string(from: d)
    }

    private var placeText: String {
        if !entry.placeName.isEmpty { return entry.placeName }
        return exif.placeName ?? ""
    }
}

// MARK: - Style 2 Watermark magazine

struct WatermarkStyleViewer: View {
    let entry: TimelineEntry
    let image: UIImage?
    let exif: PhotoEXIFInfo
    let loading: Bool

    private let canvas = Color(hex: 0xF7F3EC)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                canvas.ignoresSafeArea()
                centeredMagazineLayout(geo: geo)
            }
        }
        .ignoresSafeArea()
    }

    /// 横/竖图：主图在屏幕正中，标题浮在上方；左右各留 24
    private func centeredMagazineLayout(geo: GeometryProxy) -> some View {
        let sideInset: CGFloat = 24
        let maxWidth = geo.size.width - sideInset * 2
        // 为顶部标题与底部留出余量，避免贴边
        let maxHeight = geo.size.height * 0.72

        return ZStack {
            Group {
                if let image {
                    let aspect = image.size.height / max(image.size.width, 1)
                    let heightIfFullWidth = maxWidth * aspect
                    let displayWidth = heightIfFullWidth > maxHeight ? maxHeight / aspect : maxWidth
                    let displayHeight = displayWidth * aspect
                    photoBlock(displayWidth: displayWidth, displayHeight: displayHeight)
                } else if loading {
                    photoBlock(displayWidth: maxWidth, displayHeight: min(maxWidth * 1.25, maxHeight))
                } else {
                    photoBlock(displayWidth: maxWidth, displayHeight: min(maxWidth * 1.25, maxHeight))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            VStack(spacing: 0) {
                headerBlock
                    .padding(.horizontal, 24)
                    .padding(.top, 64)
                Spacer(minLength: 0)
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
    }

    private var headerBlock: some View {
        VStack(spacing: 10) {
            Text(heroTitle)
                .font(.system(size: 34, weight: .semibold, design: .serif))
                .tracking(4)
                .foregroundStyle(MSTheme.text)
                .multilineTextAlignment(.center)
            HStack {
                Text(monthLabel)
                Spacer()
                Text(placeText.uppercased())
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(MSTheme.muted)
            .padding(.horizontal, 4)
        }
    }

    /// 固定宽高的照片块：图填满容器，文案叠在底部；自身不额外撑高
    private func photoBlock(displayWidth: CGFloat, displayHeight: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: displayWidth, height: displayHeight)
                        .clipped()
                } else if loading {
                    Rectangle()
                        .fill(MSTheme.border.opacity(0.5))
                        .frame(width: displayWidth, height: displayHeight)
                        .overlay(ProgressView())
                } else {
                    Rectangle()
                        .fill(MSTheme.border)
                        .frame(width: displayWidth, height: displayHeight)
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(width: displayWidth, height: min(160, displayHeight * 0.55))
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 8) {
                Text(overlayTitle)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                HStack(spacing: 8) {
                    if !dateTimeText.isEmpty {
                        Text(dateTimeText)
                    }
                    if !placeText.isEmpty {
                        if !dateTimeText.isEmpty { Text("·") }
                        Text(placeText)
                    }
                    if dateTimeText.isEmpty && placeText.isEmpty {
                        Text("—")
                    }
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .opacity(0.9)
                if !displayStory.isEmpty {
                    Text("「\(displayStory)」")
                        .font(.system(size: 15, weight: .regular, design: .serif))
                        .lineSpacing(5)
                        .padding(.top, 4)
                } else if let exposure = exif.exposureLine {
                    Text(exposure)
                        .font(.system(size: 12, design: .monospaced))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .frame(width: displayWidth, height: displayHeight)
        .clipped()
    }

    private var heroTitle: String {
        if !entry.title.isEmpty { return entry.title.uppercased() }
        return "MEMORY"
    }

    private var overlayTitle: String {
        if !entry.title.isEmpty { return entry.title }
        return dateText.isEmpty ? "片刻" : dateText
    }

    private var displayStory: String {
        entry.story.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var monthLabel: String {
        let d = exif.takenAt ?? entry.takenAt
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f.string(from: d)
    }

    private var dateText: String {
        let d = exif.takenAt ?? entry.takenAt
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: d)
    }

    private var dateTimeText: String {
        let d = exif.takenAt ?? entry.takenAt
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }

    private var placeText: String {
        if !entry.placeName.isEmpty { return entry.placeName }
        return exif.placeName ?? ""
    }
}

// MARK: - Story editor

struct StoryEditSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let mediaID: String
    @State private var title: String
    @State private var place: String
    @State private var story: String
    @State private var saving = false
    @State private var generating = false

    init(mediaID: String, initialTitle: String, initialPlace: String, initialStory: String) {
        self.mediaID = mediaID
        _title = State(initialValue: initialTitle)
        _place = State(initialValue: initialPlace)
        _story = State(initialValue: initialStory)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标题") {
                    TextField("光影里的片刻", text: $title)
                }
                Section("地点") {
                    TextField("城市或地点", text: $place)
                }
                Section("故事") {
                    TextEditor(text: $story)
                        .frame(minHeight: 140)
                }
                Section {
                    Button {
                        Task { await generateAI() }
                    } label: {
                        if generating {
                            ProgressView()
                        } else {
                            Label("AI 撰写草稿", systemImage: "sparkles")
                        }
                    }
                    .disabled(generating || saving)
                } footer: {
                    Text("AI 仅生成草稿，需点保存后才会写入服务器。首期为模板文案，后续可接大模型。")
                        .font(MSTheme.captionFont)
                }
            }
            .navigationTitle("编辑故事")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(saving)
                }
            }
        }
    }

    private func generateAI() async {
        generating = true
        defer { generating = false }
        do {
            let draft = try await app.gallery.generateStoryAI(mediaID: mediaID)
            story = draft.story
            if title.isEmpty { title = draft.title }
            app.showToast("已填入 AI 草稿")
        } catch {
            app.showToast(error.localizedDescription)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await app.gallery.patchCaption(
                mediaID: mediaID,
                story: story,
                title: title,
                placeName: place
            )
            app.showToast("故事已保存")
            dismiss()
        } catch {
            app.showToast(error.localizedDescription)
        }
    }
}
