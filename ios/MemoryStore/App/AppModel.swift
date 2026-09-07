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

    @Published var route: AppRoute = .launch
    @Published var toast: String?

    private var cancellables = Set<AnyCancellable>()

    init(config: AppConfig = .default) {
        self.config = config
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

        // 嵌套 ObservableObject 的 @Published 不会自动冒泡到 AppModel，需手动转发
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

    func bootstrap() async {
        if auth.hasSession {
            do {
                _ = try await auth.refreshMe()
                await syncEngine.bindUser(auth.userID)
                route = .main
                syncEngine.start()
            } catch {
                auth.clearSession()
                route = .login
            }
        } else {
            route = .login
        }
    }

    func didLogin() async {
        await syncEngine.bindUser(auth.userID)
        route = .main
        syncEngine.start()
    }

    func logout() async {
        syncEngine.stop()
        await auth.logout()
        route = .login
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
    case launch
    case login
    case main
}
