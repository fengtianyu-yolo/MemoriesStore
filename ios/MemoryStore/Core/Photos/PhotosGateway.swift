import Foundation
import Photos
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation

actor PhotosGateway {
    func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
    }

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func fetchAllAssets() -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.includeHiddenAssets = false
        let result = PHAsset.fetchAssets(with: opts)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image || asset.mediaType == .video {
                assets.append(asset)
            }
        }
        return assets
    }

    struct ExportResult: Sendable {
        let fileURL: URL
        let byteSize: Int64
        let contentHash: String
        let mimeType: String
        let mediaType: String
        let width: Int
        let height: Int
        let durationMs: Int64?
        let takenAt: Date?
    }

    struct FingerprintResult: Sendable {
        let contentHash: String
        let byteSize: Int64
        let mimeType: String
        let mediaType: String
        let width: Int
        let height: Int
        let durationMs: Int64?
        let takenAt: Date?
    }

    /// 仅计算指纹：照片在内存中哈希，不写临时文件，降低首装发热。
    func fingerprint(asset: PHAsset, networkAccess: Bool) async throws -> FingerprintResult {
        if asset.mediaType == .image {
            return try await fingerprintImage(asset, networkAccess: networkAccess)
        }
        let exported = try await exportVideo(asset, networkAccess: networkAccess)
        defer { try? FileManager.default.removeItem(at: exported.fileURL) }
        return FingerprintResult(
            contentHash: exported.contentHash,
            byteSize: exported.byteSize,
            mimeType: exported.mimeType,
            mediaType: exported.mediaType,
            width: exported.width,
            height: exported.height,
            durationMs: exported.durationMs,
            takenAt: exported.takenAt
        )
    }

    private func fingerprintImage(_ asset: PHAsset, networkAccess: Bool) async throws -> FingerprintResult {
        try await withCheckedThrowingContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.version = .original
            opts.isNetworkAccessAllowed = networkAccess
            opts.deliveryMode = .highQualityFormat
            opts.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, uti, _, info in
                if let err = info?[PHImageErrorKey] as? Error {
                    cont.resume(throwing: err)
                    return
                }
                guard let data else {
                    cont.resume(throwing: PhotosError.exportFailed)
                    return
                }
                let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                let mime = self.mime(for: uti) ?? "image/jpeg"
                cont.resume(returning: FingerprintResult(
                    contentHash: hash,
                    byteSize: Int64(data.count),
                    mimeType: mime,
                    mediaType: "photo",
                    width: asset.pixelWidth,
                    height: asset.pixelHeight,
                    durationMs: nil,
                    takenAt: asset.creationDate
                ))
            }
        }
    }

    func exportOriginal(asset: PHAsset, networkAccess: Bool) async throws -> ExportResult {
        if asset.mediaType == .image {
            return try await exportImage(asset, networkAccess: networkAccess)
        } else {
            return try await exportVideo(asset, networkAccess: networkAccess)
        }
    }

    private func exportImage(_ asset: PHAsset, networkAccess: Bool) async throws -> ExportResult {
        try await withCheckedThrowingContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.version = .original
            opts.isNetworkAccessAllowed = networkAccess
            opts.deliveryMode = .highQualityFormat
            opts.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, uti, _, info in
                if let err = info?[PHImageErrorKey] as? Error {
                    cont.resume(throwing: err)
                    return
                }
                guard let data else {
                    cont.resume(throwing: PhotosError.exportFailed)
                    return
                }
                do {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + self.ext(for: uti))
                    try data.write(to: url)
                    let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
                    let mime = self.mime(for: uti) ?? "image/jpeg"
                    cont.resume(returning: ExportResult(
                        fileURL: url,
                        byteSize: Int64(data.count),
                        contentHash: hash,
                        mimeType: mime,
                        mediaType: "photo",
                        width: asset.pixelWidth,
                        height: asset.pixelHeight,
                        durationMs: nil,
                        takenAt: asset.creationDate
                    ))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func exportVideo(_ asset: PHAsset, networkAccess: Bool) async throws -> ExportResult {
        try await withCheckedThrowingContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.version = .original
            opts.isNetworkAccessAllowed = networkAccess
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { av, _, info in
                if let err = info?[PHImageErrorKey] as? Error {
                    cont.resume(throwing: err)
                    return
                }
                guard let urlAsset = av as? AVURLAsset else {
                    cont.resume(throwing: PhotosError.exportFailed)
                    return
                }
                Task {
                    do {
                        let src = urlAsset.url
                        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                        if FileManager.default.fileExists(atPath: dest.path) {
                            try FileManager.default.removeItem(at: dest)
                        }
                        try FileManager.default.copyItem(at: src, to: dest)
                        let hash = try Self.hashFile(dest)
                        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
                        cont.resume(returning: ExportResult(
                            fileURL: dest,
                            byteSize: size,
                            contentHash: hash,
                            mimeType: "video/quicktime",
                            mediaType: "video",
                            width: asset.pixelWidth,
                            height: asset.pixelHeight,
                            durationMs: Int64(asset.duration * 1000),
                            takenAt: asset.creationDate
                        ))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func deleteAssets(identifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    func saveImage(data: Data) async throws -> String {
        var localID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: nil)
            localID = req.placeholderForCreatedAsset?.localIdentifier
        }
        guard let localID else { throw PhotosError.saveFailed }
        return localID
    }

    func saveVideo(at fileURL: URL) async throws -> String {
        var localID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .video, fileURL: fileURL, options: nil)
            localID = req.placeholderForCreatedAsset?.localIdentifier
        }
        guard let localID else { throw PhotosError.saveFailed }
        return localID
    }

    nonisolated static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 1024 * 1024)
            if let chunk, !chunk.isEmpty {
                hasher.update(data: chunk)
                return true
            }
            return false
        }) {}
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    private func ext(for uti: String?) -> String {
        guard let uti, let t = UTType(uti) else { return ".jpg" }
        return "." + (t.preferredFilenameExtension ?? "jpg")
    }

    private func mime(for uti: String?) -> String? {
        guard let uti, let t = UTType(uti) else { return nil }
        return t.preferredMIMEType
    }
}

enum PhotosError: LocalizedError {
    case exportFailed
    case saveFailed
    var errorDescription: String? {
        switch self {
        case .exportFailed: return "导出原片失败"
        case .saveFailed: return "保存到相册失败"
        }
    }
}
