import Foundation

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
    @Published var errorMessage: String?

    private let api: APIClient
    private var store: SyncIndexStore?
    private var nextCursor: String = ""

    init(api: APIClient) { self.api = api }

    func bind(store: SyncIndexStore) {
        self.store = store
    }

    func reload() async {
        nextCursor = ""
        items = []
        await loadMore()
        await rebuildTimeline()
    }

    func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
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
            errorMessage = nil
            await rebuildTimeline()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rebuildTimeline() async {
        let syncAll = await store?.all() ?? []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter2 = ISO8601DateFormatter()
        formatter2.formatOptions = [.withInternetDateTime]

        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return formatter.date(from: s) ?? formatter2.date(from: s)
        }

        var remoteIDs = Set<String>()
        var entries: [TimelineEntry] = []

        for item in items {
            remoteIDs.insert(item.media_id)
            let sync = syncAll.first { $0.remoteMediaID == item.media_id }
                ?? (item.content_hash.flatMap { h in syncAll.first { $0.contentHash == h } })
            let badge: MediaBadge = {
                if let sync { return sync.badge }
                return .remoteOnly
            }()
            let size: Int64 = {
                let local = sync?.byteSize ?? 0
                let remote = item.size_bytes ?? 0
                return max(local, remote)
            }()
            entries.append(TimelineEntry(
                id: item.media_id,
                remoteMediaID: item.media_id,
                syncLocalID: sync?.id,
                phAssetID: (sync?.phAssetID).flatMap { $0.isEmpty ? nil : $0 },
                mediaType: item.media_type,
                takenAt: parseDate(item.taken_at) ?? sync?.takenAt,
                contentHash: item.content_hash ?? sync?.contentHash,
                byteSize: size,
                badge: badge,
                story: item.story ?? "",
                title: item.title ?? "",
                placeName: item.place_name ?? ""
            ))
        }

        for sync in syncAll where sync.remoteMediaID == nil || !remoteIDs.contains(sync.remoteMediaID ?? "") {
            if let rid = sync.remoteMediaID, remoteIDs.contains(rid) { continue }
            if sync.status == .remoteOnly { continue }
            entries.append(TimelineEntry(
                id: "local:\(sync.id)",
                remoteMediaID: sync.remoteMediaID,
                syncLocalID: sync.id,
                phAssetID: sync.phAssetID.isEmpty ? nil : sync.phAssetID,
                mediaType: sync.mediaType,
                takenAt: sync.takenAt,
                contentHash: sync.contentHash,
                byteSize: sync.byteSize,
                badge: sync.badge,
                story: "",
                title: "",
                placeName: ""
            ))
        }

        entries.sort { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
        timeline = entries
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
