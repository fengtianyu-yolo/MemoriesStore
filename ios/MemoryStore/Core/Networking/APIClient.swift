import Foundation

struct APIEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: APIErrorBody?
}

struct APIErrorBody: Decodable {
    let code: String
    let message: String
}

enum APIError: LocalizedError {
    case http(Int)
    case server(code: String, message: String)
    case decoding
    case unauthorized
    case message(String)

    var errorDescription: String? {
        switch self {
        case .http(let c): return "HTTP \(c)"
        case .server(_, let m): return m
        case .decoding: return "数据解析失败"
        case .unauthorized: return "请重新登录"
        case .message(let m): return m
        }
    }
}

actor APIClient {
    let baseURL: URL
    let tokenStore: TokenStore
    private let session: URLSession

    init(baseURL: URL, tokenStore: TokenStore, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokenStore = tokenStore
        self.session = session
    }

    func request<T: Decodable>(
        _ method: String,
        path: String,
        body: (any Encodable)? = nil,
        auth: Bool = true,
        headers: [String: String] = [:]
    ) async throws -> T {
        let data = try await rawRequest(method, path: path, body: body, auth: auth, headers: headers, retryOn401: auth)
        let env = try JSONDecoder.api.decode(APIEnvelope<T>.self, from: data)
        if env.ok, let value = env.data {
            return value
        }
        if let e = env.error {
            if e.code == "UNAUTHORIZED" { throw APIError.unauthorized }
            throw APIError.server(code: e.code, message: e.message)
        }
        throw APIError.decoding
    }

    func requestEmpty(
        _ method: String,
        path: String,
        body: (any Encodable)? = nil,
        auth: Bool = true
    ) async throws {
        let _: EmptyData = try await request(method, path: path, body: body, auth: auth)
    }

    func download(path: String, auth: Bool = true) async throws -> Data {
        try await rawRequest("GET", path: path, body: nil as String?, auth: auth, headers: [:], retryOn401: auth)
    }

    func putChunk(path: String, offset: Int64, data: Data) async throws -> ChunkResponse {
        try await request(
            "PUT",
            path: path,
            body: nil as String?,
            auth: true,
            headers: [
                "X-Chunk-Offset": "\(offset)",
                "Content-Type": "application/octet-stream",
            ],
            rawBody: data
        )
    }

    private func request<T: Decodable>(
        _ method: String,
        path: String,
        body: (any Encodable)?,
        auth: Bool,
        headers: [String: String],
        rawBody: Data
    ) async throws -> T {
        let data = try await rawRequest(method, path: path, body: body, auth: auth, headers: headers, retryOn401: auth, rawBody: rawBody)
        let env = try JSONDecoder.api.decode(APIEnvelope<T>.self, from: data)
        if env.ok, let value = env.data { return value }
        if let e = env.error { throw APIError.server(code: e.code, message: e.message) }
        throw APIError.decoding
    }

    private func rawRequest(
        _ method: String,
        path: String,
        body: (any Encodable)?,
        auth: Bool,
        headers: [String: String],
        retryOn401: Bool,
        rawBody: Data? = nil
    ) async throws -> Data {
        var url = baseURL
        if path.hasPrefix("http") {
            url = URL(string: path)!
        } else {
            url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            // appendingPathComponent messes query; build manually
            let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + trimmed)!
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = method == "PUT" ? 600 : 60
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        if auth, let token = tokenStore.accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: Authorization)
        }
        if let deviceID = tokenStore.deviceID {
            req.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        }

        if let rawBody {
            req.httpBody = rawBody
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            }
        } else if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder.api.encode(AnyEncodable(body))
        }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.message("无响应") }

        if http.statusCode == 401, retryOn401, tokenStore.refreshToken != nil {
            try await refreshToken()
            return try await rawRequest(method, path: path, body: body, auth: auth, headers: headers, retryOn401: false, rawBody: rawBody)
        }
        if !(200..<300).contains(http.statusCode) {
            if let env = try? JSONDecoder.api.decode(APIEnvelope<EmptyData>.self, from: data), let e = env.error {
                throw APIError.server(code: e.code, message: e.message)
            }
            throw APIError.http(http.statusCode)
        }
        return data
    }

    private let Authorization = "Authorization"

    private func refreshToken() async throws {
        guard let refresh = tokenStore.refreshToken else { throw APIError.unauthorized }
        struct Body: Encodable { let refresh_token: String }
        struct LoginData: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_at: String?
        }
        // avoid recursion with retryOn401 false
        var url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/auth/refresh")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder.api.encode(Body(refresh_token: refresh))
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.unauthorized
        }
        let env = try JSONDecoder.api.decode(APIEnvelope<LoginData>.self, from: data)
        guard let d = env.data else { throw APIError.unauthorized }
        tokenStore.saveTokens(access: d.access_token, refresh: d.refresh_token)
    }
}

struct EmptyData: Decodable {}
struct ChunkResponse: Decodable { let received_bytes: Int64 }

struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ value: any Encodable) {
        encodeFunc = { try value.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}

extension JSONEncoder {
    static let api: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
