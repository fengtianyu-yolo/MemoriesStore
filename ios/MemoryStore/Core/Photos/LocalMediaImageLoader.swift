import Foundation
import Photos
import UIKit

/// 从系统相册读取缩略图 / 原图（优先本机资源，必要时再拉 iCloud）。
enum LocalMediaImageLoader {
    static func thumbnail(phAssetID: String, targetSize: CGSize = CGSize(width: 300, height: 300)) async -> UIImage? {
        guard let asset = fetchAsset(phAssetID) else { return nil }
        if let img = await requestThumbnail(asset, targetSize: targetSize, networkAccess: false) {
            return img
        }
        return await requestThumbnail(asset, targetSize: targetSize, networkAccess: true)
    }

    /// 返回展示用 UIImage 与原始字节（供 EXIF）；失败返回 nil。
    static func fullImage(phAssetID: String) async -> (image: UIImage, data: Data)? {
        guard let asset = fetchAsset(phAssetID) else { return nil }
        if let r = await requestFullData(asset, networkAccess: false) { return r }
        return await requestFullData(asset, networkAccess: true)
    }

    private static func fetchAsset(_ id: String) -> PHAsset? {
        guard !id.isEmpty else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private static func requestThumbnail(
        _ asset: PHAsset,
        targetSize: CGSize,
        networkAccess: Bool
    ) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = networkAccess
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: opts
            ) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded, img != nil { return }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: img)
            }
        }
    }

    private static func requestFullData(
        _ asset: PHAsset,
        networkAccess: Bool
    ) async -> (image: UIImage, data: Data)? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.version = .current
            opts.deliveryMode = .highQualityFormat
            opts.isNetworkAccessAllowed = networkAccess
            opts.isSynchronous = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, info in
                if info?[PHImageErrorKey] != nil {
                    cont.resume(returning: nil)
                    return
                }
                guard let data, let image = UIImage(data: data) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: (image, data))
            }
        }
    }
}
