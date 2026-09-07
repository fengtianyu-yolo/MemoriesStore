import Foundation

enum SyncAssetStatus: String, Codable, Sendable {
    case discovered
    case hashing
    case pendingUpload = "pending_upload"
    case uploading
    case backedUp = "backed_up"
    case remoteOnly = "remote_only"
    case failed
    case waitingLocalResource = "waiting_local_resource"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "uploaded_verified", "purge_failed", "backed_up":
            self = .backedUp
        case "local_purged", "remote_only":
            self = .remoteOnly
        case "discovered": self = .discovered
        case "hashing": self = .hashing
        case "pending_upload": self = .pendingUpload
        case "uploading": self = .uploading
        case "failed": self = .failed
        case "waiting_local_resource": self = .waitingLocalResource
        default:
            self = .failed
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

enum MediaBadge: String, Sendable, Hashable {
    case pendingUpload
    /// 正在哈希 / 上传等处理中
    case processing
    case backedUp
    case remoteOnly
}

struct SyncAsset: Codable, Identifiable, Sendable {
    var id: String
    var userID: String
    var phAssetID: String
    var contentHash: String?
    var mediaType: String
    var byteSize: Int64
    var takenAt: Date?
    var width: Int
    var height: Int
    var durationMs: Int64?
    var status: SyncAssetStatus
    var remoteMediaID: String?
    var uploadID: String?
    var resumeOffset: Int64
    var lastError: String?
    var updatedAt: Date

    var badge: MediaBadge {
        switch status {
        case .backedUp:
            return .backedUp
        case .remoteOnly:
            return .remoteOnly
        case .hashing, .uploading:
            return .processing
        case .discovered, .pendingUpload, .failed, .waitingLocalResource:
            return .pendingUpload
        }
    }
}

struct DiscoveredPhoto: Sendable {
    let phAssetID: String
    let mediaType: String
    let width: Int
    let height: Int
    let durationMs: Int64?
    let takenAt: Date?
}

actor SyncIndexStore {
    private var userID: String = ""
    private var assets: [String: SyncAsset] = [:] // local id ->
    private var phIndex: [String: String] = [:] // phAssetID -> local id
    private let userScoped: Bool
    private var persistTask: Task<Void, Never>?
    private var dirty = false

    init(userScoped: Bool) {
        self.userScoped = userScoped
    }

    func bind(userID: String) async {
        if self.userID != userID {
            self.userID = userID
            await load()
        }
    }

    func boundUserID() -> String { userID }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MemoryStore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sync_\(userID).json")
    }

    func load() async {
        guard !userID.isEmpty, let data = try? Data(contentsOf: fileURL) else {
            assets = [:]
            phIndex = [:]
            return
        }
        let list = (try? JSONDecoder().decode([SyncAsset].self, from: data)) ?? []
        var map: [String: SyncAsset] = [:]
        map.reserveCapacity(list.count)
        for asset in list {
            if let existing = map[asset.id] {
                // 同 id 重复时保留更新时间较新者
                map[asset.id] = existing.updatedAt >= asset.updatedAt ? existing : asset
            } else {
                map[asset.id] = asset
            }
        }
        assets = map
        rebuildPhIndex()
    }

    private func rebuildPhIndex() {
        phIndex.removeAll(keepingCapacity: true)
        for asset in assets.values where !asset.phAssetID.isEmpty {
            phIndex[asset.phAssetID] = asset.id
        }
    }

    /// 扫描阶段批量写入，只落盘一次，避免上万次 JSON 编码。
    func upsertDiscoveredBatch(_ items: [DiscoveredPhoto]) -> (inserted: Int, updated: Int) {
        var inserted = 0
        var updated = 0
        let now = Date()
        for item in items {
            if let id = phIndex[item.phAssetID], var existing = assets[id] {
                existing.width = item.width
                existing.height = item.height
                existing.durationMs = item.durationMs
                existing.takenAt = item.takenAt
                existing.mediaType = item.mediaType
                existing.updatedAt = now
                if existing.status == .remoteOnly {
                    existing.status = .backedUp
                }
                assets[id] = existing
                updated += 1
            } else {
                let asset = SyncAsset(
                    id: UUID().uuidString,
                    userID: userID,
                    phAssetID: item.phAssetID,
                    contentHash: nil,
                    mediaType: item.mediaType,
                    byteSize: 0,
                    takenAt: item.takenAt,
                    width: item.width,
                    height: item.height,
                    durationMs: item.durationMs,
                    status: .discovered,
                    remoteMediaID: nil,
                    uploadID: nil,
                    resumeOffset: 0,
                    lastError: nil,
                    updatedAt: now
                )
                assets[asset.id] = asset
                phIndex[item.phAssetID] = asset.id
                inserted += 1
            }
        }
        persistNow()
        return (inserted, updated)
    }

    func upsertDiscovered(phAssetID: String, mediaType: String, width: Int, height: Int, durationMs: Int64?, takenAt: Date?) {
        _ = upsertDiscoveredBatch([
            DiscoveredPhoto(
                phAssetID: phAssetID,
                mediaType: mediaType,
                width: width,
                height: height,
                durationMs: durationMs,
                takenAt: takenAt
            )
        ])
    }

    func all() -> [SyncAsset] { Array(assets.values) }

    func asset(id: String) -> SyncAsset? { assets[id] }

    func asset(phAssetID: String) -> SyncAsset? {
        guard !phAssetID.isEmpty, let id = phIndex[phAssetID] else { return nil }
        return assets[id]
    }

    func asset(remoteMediaID: String) -> SyncAsset? {
        assets.values.first { $0.remoteMediaID == remoteMediaID }
    }

    func asset(contentHash: String) -> SyncAsset? {
        assets.values.first { $0.contentHash == contentHash }
    }

    func pendingWork(limit: Int = 1) -> [SyncAsset] {
        Array(
            assets.values
                .filter {
                    [.discovered, .pendingUpload, .uploading, .failed, .waitingLocalResource, .hashing].contains($0.status)
                }
                .sorted { ($0.takenAt ?? .distantPast) > ($1.takenAt ?? .distantPast) }
                .prefix(max(1, limit))
        )
    }

    func update(_ asset: SyncAsset) {
        if let old = assets[asset.id], !old.phAssetID.isEmpty, old.phAssetID != asset.phAssetID {
            phIndex.removeValue(forKey: old.phAssetID)
        }
        assets[asset.id] = asset
        if !asset.phAssetID.isEmpty {
            phIndex[asset.phAssetID] = asset.id
        }
        schedulePersist()
    }

    func remove(_ id: String) {
        if let old = assets.removeValue(forKey: id), !old.phAssetID.isEmpty {
            phIndex.removeValue(forKey: old.phAssetID)
        }
        schedulePersist()
    }

    func removeByRemoteMediaIDs(_ mediaIDs: [String]) {
        let idSet = Set(mediaIDs)
        let doomed = assets.values.compactMap { asset -> String? in
            guard let rid = asset.remoteMediaID, idSet.contains(rid) else { return nil }
            return asset.id
        }
        for id in doomed {
            if let old = assets.removeValue(forKey: id), !old.phAssetID.isEmpty {
                phIndex.removeValue(forKey: old.phAssetID)
            }
        }
        persistNow()
    }

    func markRemoteOnly(ids: [String]) {
        for id in ids {
            guard var asset = assets[id], asset.status == .backedUp, asset.remoteMediaID != nil else { continue }
            if !asset.phAssetID.isEmpty {
                phIndex.removeValue(forKey: asset.phAssetID)
            }
            asset.phAssetID = ""
            asset.status = .remoteOnly
            asset.updatedAt = Date()
            assets[id] = asset
        }
        persistNow()
    }

    func reconcileMissingLocals(existingPHAssetIDs: Set<String>) {
        for (id, var asset) in assets {
            guard !asset.phAssetID.isEmpty else { continue }
            guard !existingPHAssetIDs.contains(asset.phAssetID) else { continue }
            if asset.status == .backedUp, asset.remoteMediaID != nil {
                phIndex.removeValue(forKey: asset.phAssetID)
                asset.phAssetID = ""
                asset.status = .remoteOnly
                asset.updatedAt = Date()
                assets[id] = asset
            } else if [.discovered, .pendingUpload, .uploading, .hashing, .waitingLocalResource, .failed].contains(asset.status) {
                phIndex.removeValue(forKey: asset.phAssetID)
                assets.removeValue(forKey: id)
            }
        }
        persistNow()
    }

    func badge(remoteMediaID: String?, contentHash: String?) -> MediaBadge {
        if let remoteMediaID, let a = asset(remoteMediaID: remoteMediaID) {
            return a.badge
        }
        if let contentHash, let a = asset(contentHash: contentHash) {
            return a.badge
        }
        return .remoteOnly
    }

    func counts() -> (pending: Int, backedUp: Int, remoteOnly: Int, failed: Int) {
        let vals = assets.values
        return (
            vals.filter { [.discovered, .pendingUpload, .uploading, .hashing, .waitingLocalResource].contains($0.status) }.count,
            vals.filter { $0.status == .backedUp }.count,
            vals.filter { $0.status == .remoteOnly }.count,
            vals.filter { $0.status == .failed }.count
        )
    }

    private func schedulePersist() {
        dirty = true
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            if dirty {
                persistNow()
            }
        }
    }

    private func persistNow() {
        dirty = false
        persistTask?.cancel()
        persistTask = nil
        guard !userID.isEmpty else { return }
        let list = Array(assets.values)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
