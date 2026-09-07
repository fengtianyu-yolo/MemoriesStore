import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    let config: AppConfig
    let api: APIClient
    let auth: AuthService
    let syncEngine: SyncEngine
    let gallery: GalleryService
    let shareService: ShareService
    let network: NetworkMonitor
    let viewerPrefs: ViewerPreferences

    /// 配置中的公网/默认入口（discovery 仍走此地址）
    var publicBaseURL: URL { config.baseURL }
    /// 当前实际请求入口（可能已切到局域网）
    @Published private(set) var activeBaseURL: URL
    @Published private(set) var usingLANFastPath = false

    @Published var route: AppRoute = .main
    @Published var toast: String?
    /// 启动/登录后具备同步条件时弹出确认
    @Published var showSyncConfirm = false
    /// 未登录时 Present 登录页
    @Published var showLoginSheet = false

    private var cancellables = Set<AnyCancellable>()
    private var didOfferSyncThisSession = false

    init(config: AppConfig = .default) {
        self.config = config
        self.activeBaseURL = config.baseURL
        let tokenStore = TokenStore()
        let api = APIClient(baseURL: config.baseURL, tokenStore: tokenStore)
        self.api = api
        self.auth = AuthService(api: api, tokenStore: tokenStore)
        self.network = NetworkMonitor()
        self.viewerPrefs = ViewerPreferences()
        let store = SyncIndexStore(userScoped: true)
        self.syncEngine = SyncEngine(
            api: api,
            store: store,
            photos: PhotosGateway(),
            network: network,
            config: config
        )
        self.gallery = GalleryService(api: api)
        self.gallery.bind(store: store)
        self.shareService = ShareService(api: api)

        forwardChanges(from: gallery)
        forwardChanges(from: syncEngine)
        forwardChanges(from: auth)
        forwardChanges(from: network)
        forwardChanges(from: viewerPrefs)

        Task { await bootstrap() }
    }

    private func forwardChanges<T: ObservableObject>(from child: T) {
        child.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// 直接进入主界面；先尝试局域网快传，再本地相册优先 + 会话恢复
    func bootstrap() async {
        route = .main

        async let localLoad: Void = gallery.loadLocalPhotos()

        // 局域网快传：经公网 discovery → 探测 LAN → 切换 baseURL
        await resolveLANEndpoint()

        if auth.hasSession {
            do {
                _ = try await auth.refreshMe()
                await syncEngine.bindUser(auth.userID)
                await localLoad
                await gallery.fetchRemoteAndMerge()
                await offerSyncIfPossible()
            } catch {
                auth.clearSession()
                await localLoad
            }
        } else {
            await localLoad
        }
    }

    private func resolveLANEndpoint() async {
        let result = await LANEndpointResolver.resolve(publicBaseURL: config.baseURL, api: api)
        activeBaseURL = result.url
        usingLANFastPath = result.usingLAN
        if result.usingLAN {
            showToast("已切换局域网快传")
        }
    }

    func presentLogin() {
        showLoginSheet = true
    }

    func didLogin() async {
        showLoginSheet = false
        await syncEngine.bindUser(auth.userID)
        await gallery.reload(authenticated: true)
        didOfferSyncThisSession = false
        await offerSyncIfPossible()
    }

    func logout() async {
        showSyncConfirm = false
        didOfferSyncThisSession = false
        syncEngine.stop()
        await auth.logout()
        await gallery.reload(authenticated: false)
        route = .main
    }

    var canSyncNow: Bool {
        guard auth.isAuthenticated else { return false }
        guard network.isConnected else { return false }
        if config.wifiOnlyUpload {
            return network.allowsWifiOnlyUpload
        }
        return true
    }

    var syncConfirmMessage: String {
        if config.wifiOnlyUpload {
            return "当前为 Wi‑Fi，可以将相册备份到 MemoryStore。是否现在开始同步？"
        }
        return "当前网络可用，可以将相册备份到 MemoryStore。是否现在开始同步？"
    }

    func offerSyncIfPossible() async {
        guard route == .main, auth.isAuthenticated, !syncEngine.isRunning else { return }
        guard !didOfferSyncThisSession else { return }
        didOfferSyncThisSession = true

        await waitForNetworkPath(timeoutMs: 2000)

        guard canSyncNow else {
            if !network.isConnected {
                showToast("当前离线，暂不同步")
            } else if config.wifiOnlyUpload {
                showToast(network.isCellular || network.isExpensive ? "当前为蜂窝网络，暂不同步" : "未连接 Wi‑Fi，暂不同步")
            }
            return
        }

        let reachable = await pingServerHealth()
        guard reachable else {
            showToast("服务暂不可达，暂不同步")
            return
        }

        showSyncConfirm = true
    }

    func confirmStartSync() {
        showSyncConfirm = false
        guard auth.isAuthenticated, !syncEngine.isRunning else { return }
        syncEngine.start()
        showToast("已开始同步")
    }

    func deferSync() {
        showSyncConfirm = false
        showToast("已暂缓同步，可稍后在「同步」页开始")
    }

    func startSyncManually() {
        guard !syncEngine.isRunning else { return }
        guard auth.isAuthenticated else {
            presentLogin()
            return
        }
        if !canSyncNow {
            if !network.isConnected {
                showToast("当前离线，无法同步")
            } else if config.wifiOnlyUpload && !network.allowsWifiOnlyUpload {
                showToast(network.isCellular ? "需要 Wi‑Fi，当前为蜂窝网络" : "需要 Wi‑Fi 才能同步")
            }
            return
        }
        syncEngine.start()
    }

    private func waitForNetworkPath(timeoutMs: Int) async {
        let steps = max(1, timeoutMs / 200)
        for _ in 0..<steps {
            if network.isConnected { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func pingServerHealth() async -> Bool {
        let base = activeBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/health") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == message { toast = nil }
        }
    }
}

enum AppRoute {
    case main
}
