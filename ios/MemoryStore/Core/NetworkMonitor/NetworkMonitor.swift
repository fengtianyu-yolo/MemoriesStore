import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = true
    @Published private(set) var isWifi = false
    /// 蜂窝或个人热点等昂贵路径
    @Published private(set) var isExpensive = false
    @Published private(set) var isCellular = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ms.network")

    /// 适合「仅 Wi‑Fi 上传」：已连网、走 Wi‑Fi、且非昂贵蜂窝路径
    var allowsWifiOnlyUpload: Bool {
        isConnected && isWifi && !isCellular && !isExpensive
    }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConnected = path.status == .satisfied
                self?.isWifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
                self?.isCellular = path.usesInterfaceType(.cellular)
                self?.isExpensive = path.isExpensive || path.isConstrained
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
