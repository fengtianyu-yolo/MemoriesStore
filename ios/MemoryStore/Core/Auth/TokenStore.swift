import Foundation
import Security

final class TokenStore: @unchecked Sendable {
    private let lock = NSLock()
    private let accessKey = "ms.access"
    private let refreshKey = "ms.refresh"
    private let userKey = "ms.user"
    private let deviceKey = "ms.device"
    private let clientDeviceKey = "ms.client_device_key"

    var accessToken: String? {
        lock.lock(); defer { lock.unlock() }
        return read(accessKey)
    }

    var refreshToken: String? {
        lock.lock(); defer { lock.unlock() }
        return read(refreshKey)
    }

    var userJSON: Data? {
        lock.lock(); defer { lock.unlock() }
        guard let s = read(userKey) else { return nil }
        return Data(s.utf8)
    }

    var deviceID: String? {
        lock.lock(); defer { lock.unlock() }
        return read(deviceKey)
    }

    var clientDeviceKeyValue: String {
        lock.lock(); defer { lock.unlock() }
        if let existing = read(clientDeviceKey) { return existing }
        let v = UUID().uuidString
        write(clientDeviceKey, v)
        return v
    }

    func saveTokens(access: String, refresh: String) {
        lock.lock(); defer { lock.unlock() }
        write(accessKey, access)
        write(refreshKey, refresh)
    }

    func saveUser(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        write(userKey, String(data: data, encoding: .utf8) ?? "")
    }

    func saveDeviceID(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        write(deviceKey, id)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        delete(accessKey)
        delete(refreshKey)
        delete(userKey)
        delete(deviceKey)
        // keep clientDeviceKey
    }

    private func write(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "MemoryStore",
            kSecValueData as String: data,
        ]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }

    private func read(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "MemoryStore",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "MemoryStore",
        ]
        SecItemDelete(q as CFDictionary)
    }
}
