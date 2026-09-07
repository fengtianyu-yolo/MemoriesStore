import Foundation
import Combine
import UIKit

struct UserProfile: Codable, Equatable {
    let id: String
    let username: String
    let display_name: String
}

@MainActor
final class AuthService: ObservableObject {
    private let api: APIClient
    private let tokenStore: TokenStore

    @Published private(set) var user: UserProfile?
    @Published private(set) var isAuthenticated = false

    var userID: String { user?.id ?? "" }
    var hasSession: Bool { tokenStore.accessToken != nil }

    init(api: APIClient, tokenStore: TokenStore) {
        self.api = api
        self.tokenStore = tokenStore
        if let data = tokenStore.userJSON,
           let u = try? JSONDecoder().decode(UserProfile.self, from: data) {
            user = u
            isAuthenticated = tokenStore.accessToken != nil
        }
    }

    func register(username: String, password: String, displayName: String, inviteCode: String?) async throws {
        struct Body: Encodable {
            let username: String
            let password: String
            let display_name: String
            let invite_code: String?
        }
        struct Resp: Decodable { let registered: Bool }
        let _: Resp = try await api.request(
            "POST",
            path: "/api/v1/auth/register",
            body: Body(username: username, password: password, display_name: displayName, invite_code: inviteCode),
            auth: false
        )
    }

    func login(username: String, password: String) async throws {
        struct Body: Encodable { let username: String; let password: String }
        struct Resp: Decodable {
            let user: UserProfile
            let access_token: String
            let refresh_token: String
            let expires_at: String?
        }
        let res: Resp = try await api.request(
            "POST",
            path: "/api/v1/auth/login",
            body: Body(username: username, password: password),
            auth: false
        )
        tokenStore.saveTokens(access: res.access_token, refresh: res.refresh_token)
        if let data = try? JSONEncoder().encode(res.user) {
            tokenStore.saveUser(data)
        }
        user = res.user
        isAuthenticated = true
        try await registerDevice()
    }

    func refreshMe() async throws -> UserProfile {
        let me: UserProfile = try await api.request("GET", path: "/api/v1/me")
        user = me
        if let data = try? JSONEncoder().encode(me) { tokenStore.saveUser(data) }
        isAuthenticated = true
        try? await registerDevice()
        return me
    }

    func logout() async {
        try? await api.requestEmpty("POST", path: "/api/v1/auth/logout")
        clearSession()
    }

    func clearSession() {
        tokenStore.clear()
        user = nil
        isAuthenticated = false
    }

    private func registerDevice() async throws {
        struct Body: Encodable {
            let name: String
            let platform: String
            let client_device_key: String
        }
        struct Resp: Decodable { let device_id: String }
        let name = await MainActor.run { UIDevice.current.name }
        let res: Resp = try await api.request(
            "POST",
            path: "/api/v1/devices/register",
            body: Body(name: name, platform: "ios", client_device_key: tokenStore.clientDeviceKeyValue)
        )
        tokenStore.saveDeviceID(res.device_id)
    }
}
