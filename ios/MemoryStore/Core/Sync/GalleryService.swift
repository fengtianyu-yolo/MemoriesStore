import Foundation
import Photos

struct MediaItem: Identifiable, Decodable, Hashable {
    var id: String { media_id }
    let media_id: String
    let media_type: String
    let mime_type: String?
    let size_bytes: Int64?
    let width: Int64?
    let height: Int64?
    let duration_ms: Int64?
    let taken_at: String?
    let status: String?
    let thumb_ready: Bool?
    let content_hash: String?
    var story: String?
    var title: String?
    var place_name: String?
}

struct LocalPhotoMeta: Sendable, Hashable {
    let phAssetID: String
    let mediaType: String
    let takenAt: Date?
    let width: Int
    let height: Int
    let durationMs: Int64?
}

struct TimelineEntry: Identifiable, Hashable {
    let id: String
    let remoteMediaID: String?
    let syncLocalID: String?
    let phAssetID: String?
    let mediaType: String
    let takenAt: Date?
    let contentHash: String?
    let byteSize: Int64
    let badge: MediaBadge
    var story: String
    var title: String
    var placeName: String

    var canDeleteLocal: Bool {
        badge == .backedUp && remoteMediaID != nil && syncLocalID != nil && !(phAssetID ?? "").isEmpty
    }

    var canDeleteRemote: Bool {
        badge == .remoteOnly && remoteMediaID != nil
    }

    var canDownload: Bool {
        badge == .remoteOnly && remoteMediaID != nil
    }

    func isLargeBackedUp(threshold: Int64) -> Bool {
        canDeleteLocal && byteSize > threshold
    }

    var shareMediaID: String? { remoteMediaID }
}

@MainActor
final class GalleryService: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var timeline: [TimelineEntry] = []
    @Published var isLoading = false
    @Published var isLoadingLocal = false
    @Published var errorMessage: String?

    private let api: APIClient
    private let photos = PhotosGateway()
    private var store: SyncIndexStore?
    private var nextCursor: String = ""
    /// 系统相册元数据缓存（不含像素数据）
    private var localLibrary: [LocalPhotoMeta] = []

    init(api: APIClient) { self.api = api }

    func bind(store: SyncIndexStore) {
        self.store = store
    }

    /// 下拉刷新 / 登录后：本地优先，再按需拉服务端合并
    func reload(authenticated: Bool) async {
        await loadLocalPhotos()
        if authenticated {
            await fetchRemoteAndMerge()
        } else {
            items = []
            nextCursor = ""
            await mergeTimeline()
        }
    }

    /// 仅读取系统相册元数据并立刻刷新列表（不解码原图）
    func loadLocalPhotos() async {
        isLoadingLocal = true
        defer { isLoadingLocal = false }

        let status = await photos.requestAuthorization()
        guard status == .authorized || status == .limited else {
            localLibrary = []
            if items.isEmpty {
                timeline = []
            } else {
                await mergeTimeline()
            }
            return
        }

        let assets = await photos.fetchAllAssets()
        localLibrary = assets.map { a in
            LocalPhotoMeta(
                phAssetID: a.localIdentifier,
                mediaType: a.mediaType == .video ? "video" : "photo",
                takenAt: a.creationDate,
                width: a.pixelWidth,
                height: a.pixelHeight,
                durationMs: a.mediaType == .video ? Int64(a.duration * 1000) : nil
            )
        }
        await mergeTimeline()
    }

    /// 拉取服务端列表并与本地合并（插入仅云端项、更新状态）
    func fetchRemoteAndMerge() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        nextCursor = ""
        items = []
        do {
            repeat {
                try await fetchNextPage()
                // 每页回来就合并一次，列表更快出现云端状态
                await mergeTimeline()
            } while hasMore
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            await mergeTimeline()
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await fetchNextPage()
            errorMessage = nil
            await mergeTimeline()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchNextPage() async throws {
        struct Resp: Decodable {
            let items: [MediaItem]
            let next_cursor: String?
        }
        var path = "/api/v1/media?limit=60"
        if !nextCursor.isEmpty {
            let enc = nextCursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? nextCursor
            path += "&cursor=\(enc)"
        }
        let resp: Resp = try await api.request("GET", path: path)
        items.append(contentsOf: resp.items)
        nextCursor = resp.next_cursor ?? ""
    }

    /// 用本地库 + 服务端 items + 同步索引重建时间轴
    func rebuildTimeline() async {
        await mergeTimeline()
    }

    private func mergeTimeline() async {
        let syncAll = await store?.all() ?? []
        // 索引可能含重复 phAssetID / hash（历史脏数据），不能用 uniqueKeysWithValues
        let syncByPH = Self.indexSync(syncAll) { s in
            s.phAssetID.isEmpty ? nil : s.phAssetID
        }
        let syncByRemote = Self.indexSync(syncAll) { s in
            guard let rid = s.remoteMediaID, !rid.isEmpty else { return nil }
            return rid
        }
        let syncByHash = Self.indexSync(syncAll) { s in
            guard let h = s.contentHash, !h.isEmpty else { return nil }
            return h
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter2 = ISO8601DateFormatter()
        formatter2.formatOptions = [.withInternetDateTime]

        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return formatter.date(from: s) ?? formatter2.date(from: s)
        }

        var usedLocalPH = Set<String>()
        var entries: [TimelineEntry] = []
        entries.reserveCapacity(localLibrary.count + items.count)

        // 1) 服务端项：匹配本地后更新状态，无法匹配则作为仅云端插入
        for item in items {
            let sync = syncByRemote[item.media_id]
                ?? item.content_hash.flatMap { syncByHash[$0] }

            var ph = (sync?.phAssetID).flatMap { $0.isEmpty ? nil : $0 }
            // 若同步索引尚未写入，仍可能通过 hash 对上本地 sync
            if ph == nil, let h = item.content_hash, let s = syncByHash[h], !s.phAssetID.isEmpty {
                ph = s.phAssetID
            }

            if let ph {
                usedLocalPH.insert(ph)
            }

            let badge: MediaBadge = sync?.badge ?? (ph == nil ? .remoteOnly : .pendingUpload)

            let localMeta = ph.flatMap { id in localLibrary.first { $0.phAssetID == id } }
            let size = max(sync?.byteSize ?? 0, item.size_bytes ?? 0)

            entries.append(TimelineEntry(
                id: item.media_id,
                remoteMediaID: item.media_id,
                syncLocalID: sync?.id,
                phAssetID: ph,
                mediaType: item.media_type,
                takenAt: parseDate(item.taken_at) ?? sync?.takenAt ?? localMeta?.takenAt,
                contentHash: item.content_hash ?? sync?.contentHash,
                byteSize: size,
                badge: badge,
                story: item.story ?? "",
                title: item.title ?? "",
                placeName: item.place_name ?? ""
            ))
        }

        // 2) 仅本地 / 尚未匹配到服务端的系统照片
        for local in localLibrary where !usedLocalPH.contains(local.phAssetID) {
            let sync = syncByPH[local.phAssetID]
            // 已在服务端列表中的 remote 不应再以本地行出现
            if let rid = sync?.remoteMediaID, items.contains(where: { $0.media_id == rid }) {
                continue
            }
            let badge = sync?.badge ?? .pendingUpload
            entries.append(TimelineEntry(
                id: "ph:\(local.phAssetID)",
                remoteMediaID: sync?.remoteMediaID,
                syncLocalID: sync?.id,
                phAssetID: local.phAssetID,
                mediaType: local.mediaType,
                takenAt: local.takenAt ?? sync?.takenAt,
                contentHash: sync?.contentHash,
                byteSize: sync?.byteSize ?? 0,
                badge: badge,
                story: "",
                title: "",
                placeName: ""
            ))
        }

        entries.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        timeline = entries
    }

    /// 安全建索引：遇重复 key 时保留状态更“靠前”或更新时间更新者。
    private static func indexSync(_ items: [SyncAsset], key: (SyncAsset) -> String?) -> [String: SyncAsset] {
        var dict: [String: SyncAsset] = [:]
        dict.reserveCapacity(items.count)
        for s in items {
            guard let k = key(s) else { continue }
            if let existing = dict[k] {
                dict[k] = preferSync(existing, s)
            } else {
                dict[k] = s
            }
        }
        return dict
    }

    private static func preferSync(_ a: SyncAsset, _ b: SyncAsset) -> SyncAsset {
        func rank(_ status: SyncAssetStatus) -> Int {
            switch status {
            case .backedUp: return 50
            case .remoteOnly: return 40
            case .uploading: return 30
            case .hashing: return 25
            case .pendingUpload: return 20
            case .discovered: return 10
            case .waitingLocalResource: return 5
            case .failed: return 0
            }
        }
        if rank(a.status) != rank(b.status) {
            return rank(a.status) > rank(b.status) ? a : b
        }
        return a.updatedAt >= b.updatedAt ? a : b
    }

    func removeFromTimeline(mediaIDs: [String]) {
        let idSet = Set(mediaIDs)
        items.removeAll { idSet.contains($0.media_id) }
        timeline.removeAll { entry in
            guard let rid = entry.remoteMediaID else { return false }
            return idSet.contains(rid)
        }
    }

    func applyCaption(mediaID: String, story: String, title: String, placeName: String) {
        if let i = items.firstIndex(where: { $0.media_id == mediaID }) {
            items[i].story = story
            items[i].title = title
            items[i].place_name = placeName
        }
        if let i = timeline.firstIndex(where: { $0.remoteMediaID == mediaID }) {
            timeline[i].story = story
            timeline[i].title = title
            timeline[i].placeName = placeName
        }
    }

    func patchCaption(mediaID: String, story: String, title: String, placeName: String) async throws {
        struct Body: Encodable {
            let story: String
            let title: String
            let place_name: String
        }
        struct ItemResp: Decodable {
            let media_id: String
            let story: String?
            let title: String?
            let place_name: String?
        }
        let item: ItemResp = try await api.request(
            "PATCH",
            path: "/api/v1/media/\(mediaID)",
            body: Body(story: story, title: title, place_name: placeName)
        )
        applyCaption(
            mediaID: mediaID,
            story: item.story ?? story,
            title: item.title ?? title,
            placeName: item.place_name ?? placeName
        )
    }

    func generateStoryAI(mediaID: String) async throws -> (story: String, title: String) {
        struct Resp: Decodable {
            let story: String
            let title: String?
            let source: String?
        }
        let res: Resp = try await api.request("POST", path: "/api/v1/media/\(mediaID)/story/ai")
        return (res.story, res.title ?? "")
    }

    func originalPath(mediaID: String) -> String {
        "/api/v1/media/\(mediaID)/original"
    }

    var hasMore: Bool { !nextCursor.isEmpty }
}

@MainActor
final class ShareService: ObservableObject {
    private let api: APIClient
    init(api: APIClient) { self.api = api }

    struct CreateResult: Decodable {
        let share_id: String
        let url: String
        let token: String
        let expires_at: String?
    }

    func create(mediaIDs: [String], title: String, days: Int = 7) async throws -> CreateResult {
        struct Body: Encodable {
            let title: String
            let scope_type: String
            let media_ids: [String]
            let expires_in_days: Int
        }
        return try await api.request(
            "POST",
            path: "/api/v1/shares",
            body: Body(title: title, scope_type: "media_ids", media_ids: mediaIDs, expires_in_days: days)
        )
    }
}
