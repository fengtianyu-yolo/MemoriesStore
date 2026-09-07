import Foundation
import Photos
import Combine

@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var statusText = "空闲"
    @Published private(set) var pendingCount = 0
    @Published private(set) var uploadedCount = 0
    @Published private(set) var purgedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var scanProgress: Double = 0
    @Published private(set) var isThermalThrottled = false

    let store: SyncIndexStore
    private let api: APIClient
    private let photos: PhotosGateway
    private let network: NetworkMonitor
    private let config: AppConfig
    private var loopTask: Task<Void, Never>?
    private var observer: PhotoObserver?
    private var scanTask: Task<Void, Never>?
    private var isScanning = false

    private let scanBatchSize = 200

    init(api: APIClient, store: SyncIndexStore, photos: PhotosGateway, network: NetworkMonitor, config: AppConfig) {
        self.api = api
        self.store = store
        self.photos = photos
        self.network = network
        self.config = config
    }

    func bindUser(_ userID: String) async {
        await store.bind(userID: userID)
        await refreshCounts()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        observer = PhotoObserver { [weak self] in
            self?.scheduleScan(debounced: true)
        }
        loopTask = Task { await runLoop() }
    }

    func stop() {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        scanTask?.cancel()
        scanTask = nil
        observer = nil
    }

    func togglePause() {
        isPaused.toggle()
        statusText = isPaused ? "已暂停" : "运行中"
    }

    func scheduleScan(debounced: Bool) {
        scanTask?.cancel()
        scanTask = Task {
            if debounced {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
            }
            await scanLibrary()
        }
    }

    func runLoop() async {
        await scanLibrary()
        while !Task.isCancelled && isRunning {
            await refreshCounts()
            if isPaused {
                statusText = "已暂停"
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }
            if isScanning {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            if config.wifiOnlyUpload && !network.allowsWifiOnlyUpload {
                statusText = network.isCellular || network.isExpensive ? "等待 Wi‑Fi（当前蜂窝）…" : "等待 Wi‑Fi…"
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }

            let coolDown = thermalCooldownNanoseconds()
            if coolDown > 0 {
                isThermalThrottled = true
                statusText = "设备发热，已降速…"
                try? await Task.sleep(nanoseconds: coolDown)
                continue
            }
            isThermalThrottled = false

            let work = await store.pendingWork(limit: 1)
            guard let next = work.first else {
                statusText = "已同步"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            do {
                try await process(next)
                lastError = nil
                // 任务间让出 CPU，避免上万张连续哈希把机器打满
                try? await Task.sleep(nanoseconds: interItemDelayNanoseconds())
            } catch {
                lastError = error.localizedDescription
                statusText = "出错：\(error.localizedDescription)"
                var asset = next
                asset.status = .failed
                asset.lastError = error.localizedDescription
                asset.updatedAt = Date()
                await store.update(asset)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func scanLibrary() async {
        guard !isScanning else { return }
        isScanning = true
        defer {
            isScanning = false
            scanProgress = 1
        }

        let status = await photos.requestAuthorization()
        guard status == .authorized || status == .limited else {
            statusText = "需要照片权限"
            return
        }
        statusText = "扫描相册…"
        scanProgress = 0

        let assets = await photos.fetchAllAssets()
        let total = assets.count
        guard total > 0 else {
            await store.reconcileMissingLocals(existingPHAssetIDs: [])
            await refreshCounts()
            statusText = "扫描完成"
            return
        }

        var ids = Set<String>()
        ids.reserveCapacity(total)
        var batch: [DiscoveredPhoto] = []
        batch.reserveCapacity(scanBatchSize)

        for (idx, a) in assets.enumerated() {
            if Task.isCancelled { return }
            ids.insert(a.localIdentifier)
            batch.append(
                DiscoveredPhoto(
                    phAssetID: a.localIdentifier,
                    mediaType: a.mediaType == .video ? "video" : "photo",
                    width: a.pixelWidth,
                    height: a.pixelHeight,
                    durationMs: a.mediaType == .video ? Int64(a.duration * 1000) : nil,
                    takenAt: a.creationDate
                )
            )
            if batch.count >= scanBatchSize {
                _ = await store.upsertDiscoveredBatch(batch)
                batch.removeAll(keepingCapacity: true)
                scanProgress = Double(idx + 1) / Double(total)
                statusText = "扫描相册… \(idx + 1)/\(total)"
                await Task.yield()
            }
        }
        if !batch.isEmpty {
            _ = await store.upsertDiscoveredBatch(batch)
        }

        await store.reconcileMissingLocals(existingPHAssetIDs: ids)
        await refreshCounts()
        scanProgress = 1
        statusText = "扫描完成 · \(total) 项"
    }

    /// 编辑模式：删除已备份项的本机原片，状态变为 remote_only。
    func deleteLocalBackedUp(syncIDs: [String]) async throws {
        var toDeletePH: [String] = []
        var okIDs: [String] = []
        for id in syncIDs {
            guard let asset = await store.asset(id: id) else { continue }
            guard asset.status == .backedUp, asset.remoteMediaID != nil else { continue }
            if !asset.phAssetID.isEmpty {
                toDeletePH.append(asset.phAssetID)
            }
            okIDs.append(id)
        }
        guard !okIDs.isEmpty else { return }
        if !toDeletePH.isEmpty {
            try await photos.deleteAssets(identifiers: toDeletePH)
        }
        await store.markRemoteOnly(ids: okIDs)
        statusText = "已删除 \(okIDs.count) 项本机原片"
        await refreshCounts()
    }

    /// 编辑模式：永久删除仅云端媒体（服务端文件+库）。
    func deleteRemoteOnly(mediaIDs: [String]) async throws {
        let ids = Array(Set(mediaIDs.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return }
        struct Body: Encodable { let media_ids: [String] }
        struct Resp: Decodable {
            let deleted: [String]?
            let missing: [String]?
        }
        let res: Resp = try await api.request(
            "POST",
            path: "/api/v1/media/delete",
            body: Body(media_ids: ids)
        )
        let gone = (res.deleted ?? []) + (res.missing ?? [])
        await store.removeByRemoteMediaIDs(gone)
        statusText = "已删除 \(res.deleted?.count ?? 0) 项云端媒体"
        await refreshCounts()
    }

    /// 将仅远端项下载并写回系统相册。
    func downloadToLibrary(remoteMediaID: String, mediaType: String = "photo") async throws {
        let asset = await store.asset(remoteMediaID: remoteMediaID)
        let data = try await api.download(path: "/api/v1/media/\(remoteMediaID)/original")
        let type = asset?.mediaType ?? mediaType
        let isVideo = type == "video"
        let newID: String
        if isVideo {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            newID = try await photos.saveVideo(at: url)
        } else {
            newID = try await photos.saveImage(data: data)
        }
        if var existing = asset {
            existing.phAssetID = newID
            existing.status = .backedUp
            existing.updatedAt = Date()
            await store.update(existing)
        } else {
            let created = SyncAsset(
                id: UUID().uuidString,
                userID: await store.boundUserID(),
                phAssetID: newID,
                contentHash: nil,
                mediaType: isVideo ? "video" : "photo",
                byteSize: Int64(data.count),
                takenAt: nil,
                width: 0,
                height: 0,
                durationMs: nil,
                status: .backedUp,
                remoteMediaID: remoteMediaID,
                uploadID: nil,
                resumeOffset: 0,
                lastError: nil,
                updatedAt: Date()
            )
            await store.update(created)
        }
        statusText = "已保存到相册"
        await refreshCounts()
    }

    private func process(_ asset: SyncAsset) async throws {
        var current = asset
        switch current.status {
        case .discovered, .failed, .waitingLocalResource, .hashing:
            try await hashAndProbe(&current)
        case .pendingUpload, .uploading:
            try await upload(&current)
        case .backedUp, .remoteOnly:
            break
        }
    }

    private func hashAndProbe(_ asset: inout SyncAsset) async throws {
        statusText = "计算指纹…"
        asset.status = .hashing
        await store.update(asset)

        guard let ph = fetchAsset(asset.phAssetID) else {
            if asset.remoteMediaID != nil {
                asset.phAssetID = ""
                asset.status = .remoteOnly
            } else {
                asset.status = .failed
                asset.lastError = "本地资源不存在"
            }
            await store.update(asset)
            return
        }

        let finger: PhotosGateway.FingerprintResult
        do {
            finger = try await photos.fingerprint(asset: ph, networkAccess: network.isWifi)
        } catch {
            asset.status = .waitingLocalResource
            asset.lastError = error.localizedDescription
            await store.update(asset)
            throw error
        }

        asset.contentHash = finger.contentHash
        asset.byteSize = finger.byteSize
        asset.mediaType = finger.mediaType

        struct CheckBody: Encodable { let hashes: [String] }
        struct CheckResp: Decodable {
            struct Existing: Decodable { let hash: String; let media_id: String; let size_bytes: Int64 }
            let existing: [Existing]?
            let missing: [String]?
        }
        let check: CheckResp = try await api.request(
            "POST",
            path: "/api/v1/media/check",
            body: CheckBody(hashes: [finger.contentHash])
        )
        if let hit = check.existing?.first {
            asset.remoteMediaID = hit.media_id
            asset.status = .backedUp
            asset.updatedAt = Date()
            await store.update(asset)
            statusText = "已备份（秒传）"
            return
        }
        asset.status = .pendingUpload
        await store.update(asset)
        try await upload(&asset)
    }

    private func upload(_ asset: inout SyncAsset) async throws {
        statusText = "上传中…"
        asset.status = .uploading
        asset.updatedAt = Date()
        await store.update(asset)

        guard let ph = fetchAsset(asset.phAssetID) else {
            if asset.remoteMediaID != nil {
                asset.phAssetID = ""
                asset.status = .remoteOnly
            } else {
                asset.status = .failed
                asset.lastError = "本地资源不存在"
            }
            await store.update(asset)
            return
        }
        let exported = try await photos.exportOriginal(asset: ph, networkAccess: network.isWifi)
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }

        if asset.contentHash == nil {
            asset.contentHash = exported.contentHash
            asset.byteSize = exported.byteSize
        }

        struct InitBody: Encodable {
            let content_hash: String
            let size_bytes: Int64
            let mime_type: String
            let media_type: String
            let taken_at: String?
            let width: Int?
            let height: Int?
            let duration_ms: Int64?
        }
        struct InitResp: Decodable {
            let upload_id: String?
            let resume_from: Int64?
            let already_exists: Bool
            let media_id: String?
            let content_hash: String?
        }

        let taken: String? = {
            guard let d = exported.takenAt else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.string(from: d)
        }()

        let initRes: InitResp = try await api.request(
            "POST",
            path: "/api/v1/upload/init",
            body: InitBody(
                content_hash: exported.contentHash,
                size_bytes: exported.byteSize,
                mime_type: exported.mimeType,
                media_type: exported.mediaType,
                taken_at: taken,
                width: exported.width,
                height: exported.height,
                duration_ms: exported.durationMs
            )
        )

        if initRes.already_exists, let mid = initRes.media_id {
            asset.remoteMediaID = mid
            asset.status = .backedUp
            asset.updatedAt = Date()
            await store.update(asset)
            statusText = "已备份"
            return
        }

        guard let uploadID = initRes.upload_id else {
            throw APIError.message("缺少 upload_id")
        }
        asset.uploadID = uploadID
        asset.resumeOffset = initRes.resume_from ?? 0
        await store.update(asset)

        let handle = try FileHandle(forReadingFrom: exported.fileURL)
        defer { try? handle.close() }
        var offset = asset.resumeOffset
        if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }

        while offset < exported.byteSize {
            if Task.isCancelled { return }
            if config.wifiOnlyUpload && !network.allowsWifiOnlyUpload {
                throw APIError.message("已离开 Wi‑Fi，上传暂停")
            }
            let end = min(offset + Int64(config.chunkSize), exported.byteSize)
            let length = Int(end - offset)
            guard let chunk = try handle.read(upToCount: length), !chunk.isEmpty else { break }
            let resp = try await api.putChunk(path: "/api/v1/upload/\(uploadID)/chunk", offset: offset, data: chunk)
            offset = resp.received_bytes
            asset.resumeOffset = offset
            await store.update(asset)
            statusText = String(format: "上传 %.0f%%", Double(offset) / Double(exported.byteSize) * 100)
            // 分片间稍作停顿，降低 FRP 链路压力
            try? await Task.sleep(nanoseconds: 80_000_000)
            await Task.yield()
        }

        struct CompleteResp: Decodable {
            let media_id: String
            let content_hash: String
            let size_bytes: Int64
            let status: String
        }
        let done: CompleteResp = try await api.request("POST", path: "/api/v1/upload/\(uploadID)/complete")
        asset.remoteMediaID = done.media_id
        asset.status = .backedUp
        asset.uploadID = nil
        asset.updatedAt = Date()
        await store.update(asset)
        statusText = "已备份"
        await refreshCounts()
    }

    private func fetchAsset(_ id: String) -> PHAsset? {
        guard !id.isEmpty else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func refreshCounts() async {
        let c = await store.counts()
        pendingCount = c.pending
        uploadedCount = c.backedUp
        purgedCount = c.remoteOnly
        failedCount = c.failed
    }

    private func thermalCooldownNanoseconds() -> UInt64 {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair:
            return 0
        case .serious:
            return 3_000_000_000
        case .critical:
            return 8_000_000_000
        @unknown default:
            return 1_000_000_000
        }
    }

    private func interItemDelayNanoseconds() -> UInt64 {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return 150_000_000
        case .fair:
            return 400_000_000
        case .serious:
            return 2_000_000_000
        case .critical:
            return 5_000_000_000
        @unknown default:
            return 500_000_000
        }
    }
}

final class PhotoObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: () -> Void
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
