import Foundation

/// 启动时经公网 discovery 获取服务端局域网地址，探测可达后切换为局域网访问。
enum LANEndpointResolver {
    private static let cacheKey = "ms.lastLANBaseURL"

    struct Discovery: Decodable {
        let listen_port: Int
        let public_base_url: String?
        let lan_ipv4: [String]
    }

    struct ResolveResult: Sendable {
        let url: URL
        let usingLAN: Bool
    }

    static func resolve(publicBaseURL: URL, api: APIClient) async -> ResolveResult {
        // 1) 优先探测上次成功的局域网地址（同网段重启更快）
        if let cached = UserDefaults.standard.string(forKey: cacheKey),
           let cachedURL = URL(string: cached),
           await probeHealth(baseURL: cachedURL, timeout: 0.6) {
            await api.updateBaseURL(cachedURL)
            return ResolveResult(url: cachedURL, usingLAN: true)
        }

        // 2) 经公网拉取 discovery（当前 api 应仍指向公网）
        await api.updateBaseURL(publicBaseURL)
        let discovery: Discovery
        do {
            discovery = try await api.request("GET", path: "/api/v1/network/discovery", auth: false)
        } catch {
            return ResolveResult(url: publicBaseURL, usingLAN: false)
        }

        guard discovery.listen_port > 0, !discovery.lan_ipv4.isEmpty else {
            clearCache()
            return ResolveResult(url: publicBaseURL, usingLAN: false)
        }

        let candidates: [URL] = discovery.lan_ipv4.compactMap { ip in
            URL(string: "http://\(ip):\(discovery.listen_port)")
        }

        // 3) 并行探测，取首个健康的局域网入口
        if let lan = await firstHealthy(candidates) {
            UserDefaults.standard.set(lan.absoluteString, forKey: cacheKey)
            await api.updateBaseURL(lan)
            return ResolveResult(url: lan, usingLAN: true)
        }

        clearCache()
        await api.updateBaseURL(publicBaseURL)
        return ResolveResult(url: publicBaseURL, usingLAN: false)
    }

    private static func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }

    private static func firstHealthy(_ urls: [URL]) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            for url in urls {
                group.addTask {
                    if await probeHealth(baseURL: url, timeout: 0.8) {
                        return url
                    }
                    return nil
                }
            }
            for await result in group {
                if let url = result {
                    group.cancelAll()
                    return url
                }
            }
            return nil
        }
    }

    private static func probeHealth(baseURL: URL, timeout: TimeInterval) async -> Bool {
        let root = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + "/health") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            // 轻量校验：响应含 ok
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = obj["ok"] as? Bool {
                return ok
            }
            return true
        } catch {
            return false
        }
    }
}
