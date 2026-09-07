import Foundation

struct AppConfig: Sendable {
    var baseURL: URL
    var chunkSize: Int
    var maxUploadConcurrency: Int
    var mediaCacheLimitBytes: Int64
    var wifiOnlyUpload: Bool
    /// 编辑态「大文件」过滤阈值（已备份且超过此大小可一键清理本机）
    var largeFileThresholdBytes: Int64

    static var `default`: AppConfig {
        // 默认走云服务器 FRP 公网入口；可用环境变量 MEMORYSTORE_BASE_URL 覆盖
        let url = URL(string: ProcessInfo.processInfo.environment["MEMORYSTORE_BASE_URL"] ?? "http://120.48.22.80:10002")!
        return AppConfig(
            baseURL: url,
            chunkSize: 8 * 1024 * 1024,
            maxUploadConcurrency: 1,
            mediaCacheLimitBytes: 2 * 1024 * 1024 * 1024,
            wifiOnlyUpload: true,
            largeFileThresholdBytes: 30 * 1024 * 1024
        )
    }
}
