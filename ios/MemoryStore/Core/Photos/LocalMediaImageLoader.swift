import Foundation
import Photos
import UIKit

/// 从系统相册读取缩略图 / 原图（优先本机资源，必要时再拉 iCloud）。
enum LocalMediaImageLoader {
    /// 列表网格用：按屏宽约 1/3 cell，乘 scale，避免解码原图
    static var listThumbnailPixelSize: CGSize {
        let sideInset: CGFloat = 40
        let spacing: CGFloat = 8
        let cell = max(80, (UIScreen.main.bounds.width - sideInset - spacing) / 3)
        let px = cell * UIScreen.main.scale
        return CGSize(width: px, height: px)
    }

    static func thumbnail(
        phAssetID: String,
        targetSize: CGSize = listThumbnailPixelSize,
        allowNetwork: Bool = false
    ) async -> UIImage? {
        guard let asset = fetchAsset(phAssetID) else { return nil }
        if let img = await requestThumbnail(asset, targetSize: targetSize, networkAccess: false, fast: true) {
            return img
        }
        guard allowNetwork else { return nil }
        return await requestThumbnail(asset, targetSize: targetSize, networkAccess: true, fast: true)
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
        networkAccess: Bool,
        fast: Bool
    ) async -> UIImage? {
        await withCheckedContinuation { cont in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = fast ? .fastFormat : .opportunistic
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = networkAccess
            opts.isSynchronous = false
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: opts
            ) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                // opportunistic 可忽略中间 degraded；fastFormat 通常一次回调
                if !fast, degraded, img != nil { return }
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
