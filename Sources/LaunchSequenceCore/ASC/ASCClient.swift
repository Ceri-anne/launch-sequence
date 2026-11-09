import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 120
        session = URLSession(configuration: config)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LaunchError.api("No HTTP response") }
        return (data, http)
    }
}

/// Hosts this tool will talk to. Anything else is refused before a request is made.
public enum HostPolicy {
    public static let ascHost = "api.appstoreconnect.apple.com"

    /// The authenticated API. Only this host ever receives the JWT.
    public static func isASC(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == ascHost && url.port == nil
    }

    /// Pre-signed asset upload URLs that App Store Connect hands back. They get no Authorization header.
    public static func isAppleUpload(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil, let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".apple.com") && host != ascHost
    }
}

/// App Store Connect API client: JSON:API documents, paging, retries, and dry runs.
///
/// In a dry run, GETs still go to Apple (so the plan is real) but POST, PATCH and DELETE
/// are printed and answered with a placeholder resource whose ID starts with `dryrun-`.
public final class ASCClient: @unchecked Sendable {
    let credentials: ASCCredentials?
    let transport: HTTPTransport
    let console: Console
    public let dryRun: Bool
    private let lock = NSLock()
    private var token: (value: String, made: Date)?
    private var dryRunCounter = 0
    let base = URL(string: "https://api.appstoreconnect.apple.com")!
    let sleep: @Sendable (Double) async -> Void

    public init(credentials: ASCCredentials?, transport: HTTPTransport = URLSessionTransport(), console: Console, dryRun: Bool,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.credentials = credentials
        self.transport = transport
        self.console = console
        self.dryRun = dryRun
        self.sleep = sleep
    }

    // MARK: Requests

    public func get(_ path: String, query: [(String, String)] = []) async throws -> JSONValue {
        if path.contains("dryrun-") { return ["data": .null] }
        return try await send("GET", url: try url(path, query: query), body: nil)
    }

    /// GETs a collection, following `links.next` until done.
    public func getAll(_ path: String, query: [(String, String)] = []) async throws -> [JSONValue] {
        if path.contains("dryrun-") { return [] }
        var next: URL? = try url(path, query: query + [("limit", "200")])
        var all: [JSONValue] = []
        var pages = 0
        while let current = next {
            pages += 1
            guard pages <= 50 else { throw LaunchError.api("Too many pages for \(path)") }
            let doc = try await send("GET", url: current, body: nil)
            all += doc["data"].array
            if let link = doc["links"]["next"].string, let u = URL(string: link) {
                guard HostPolicy.isASC(u) else { throw LaunchError.api("Refusing to follow a next link to another host") }
                next = u
            } else {
                next = nil
            }
        }
        return all
    }

    @discardableResult
    public func post(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        try await change("POST", path, body)
    }

    @discardableResult
    public func patch(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        try await change("PATCH", path, body)
    }

    public func delete(_ path: String) async throws {
        _ = try await change("DELETE", path, nil)
    }

    private func change(_ method: String, _ path: String, _ body: JSONValue?) async throws -> JSONValue {
        if dryRun || path.contains("dryrun-") {
            console.dry("\(method) \(path)\(Self.summary(body))")
            return ["data": ["id": .string(nextDryRunID()), "type": body?["data"]["type"] ?? .null, "attributes": [:]]]
        }
        return try await send(method, url: try url(path, query: []), body: try body?.data())
    }

    private func nextDryRunID() -> String {
        lock.lock(); defer { lock.unlock() }
        dryRunCounter += 1
        return "dryrun-\(dryRunCounter)"
    }

    /// A short, non-secret description of a request body, for dry-run output.
    static func summary(_ body: JSONValue?) -> String {
        guard let body else { return "" }
        let data = body["data"]
        var parts: [String] = []
        if let type = data["type"].string { parts.append(type) }
        if case .object(let attrs) = data["attributes"], !attrs.isEmpty {
            parts.append(attrs.keys.sorted().map { key -> String in
                if let s = attrs[key]?.string { return "\(key)=\(s.count > 40 ? String(s.prefix(37)) + "..." : s)" }
                return key
            }.joined(separator: ", "))
        }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ": ") + ")"
    }

    func url(_ path: String, query: [(String, String)]) throws -> URL {
        guard path.hasPrefix("/v1/") || path.hasPrefix("/v2/") else { throw LaunchError.api("Bad API path \(path)") }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = components.url, HostPolicy.isASC(url) else { throw LaunchError.api("Bad API URL for \(path)") }
        return url
    }

    private func bearer() throws -> String {
        guard let credentials else { throw LaunchError.precondition("App Store Connect credentials are needed for this step") }
        lock.lock(); defer { lock.unlock() }
        if let token, Date().timeIntervalSince(token.made) < ASCToken.lifetime - 120 { return token.value }
        let fresh = try ASCToken.make(credentials)
        token = (fresh, Date())
        return fresh
    }

    private func send(_ method: String, url: URL, body: Data?) async throws -> JSONValue {
        guard HostPolicy.isASC(url) else { throw LaunchError.api("Refusing to send credentials to \(url.host ?? "?")") }
        var attempt = 0
        while true {
            attempt += 1
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(try bearer())", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            console.debug("\(method) \(url.path)\(url.query.map { "?\($0)" } ?? "")")
            let (data, response) = try await transport.send(request)
            let status = response.statusCode
            if (status == 429 || status >= 500) && attempt < 4 {
                let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt))
                console.debug("HTTP \(status), retrying in \(Int(wait))s")
                await sleep(min(wait, 60))
                continue
            }
            guard (200..<300).contains(status) else {
                throw LaunchError.api("\(method) \(url.path) returned \(status): \(Self.errorDetail(data))")
            }
            if data.isEmpty || status == 204 { return .null }
            return try JSONValue.parse(data)
        }
    }

    static func errorDetail(_ data: Data) -> String {
        guard let doc = try? JSONValue.parse(data) else { return String(data: data.prefix(300), encoding: .utf8) ?? "" }
        let errors = doc["errors"].array.map { e in
            [e["title"].string, e["detail"].string].compactMap { $0 }.joined(separator: " — ")
        }
        return errors.isEmpty ? "unknown error" : errors.joined(separator: "; ")
    }

    // MARK: Uploads

    public struct UploadOperation: Sendable {
        public var method: String
        public var url: URL
        public var offset: Int
        public var length: Int
        public var headers: [(String, String)]
    }

    public static func uploadOperations(_ attributes: JSONValue) throws -> [UploadOperation] {
        try attributes["uploadOperations"].array.map { op in
            guard let method = op["method"].string, let raw = op["url"].string, let url = URL(string: raw),
                  let offset = op["offset"].int, let length = op["length"].int else {
                throw LaunchError.api("Malformed upload operation")
            }
            let headers = op["requestHeaders"].array.compactMap { h -> (String, String)? in
                guard let n = h["name"].string, let v = h["value"].string else { return nil }
                return (n, v)
            }
            return UploadOperation(method: method, url: url, offset: offset, length: length, headers: headers)
        }
    }

    /// Sends one chunk to a pre-signed Apple upload URL. The JWT is never attached.
    public func upload(_ op: UploadOperation, file: Data) async throws {
        guard HostPolicy.isAppleUpload(op.url) else { throw LaunchError.api("Refusing to upload to \(op.url.host ?? "?"), which isn't an Apple host") }
        guard op.offset >= 0, op.length >= 0, op.offset + op.length <= file.count else { throw LaunchError.api("Upload range is outside the file") }
        if dryRun { console.dry("\(op.method) \(op.length) bytes to \(op.url.host ?? "")"); return }
        var request = URLRequest(url: op.url)
        request.httpMethod = op.method
        for (name, value) in op.headers where name.lowercased() != "authorization" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = file.subdata(in: op.offset..<(op.offset + op.length))
        var attempt = 0
        while true {
            attempt += 1
            let (_, response) = try await transport.send(request)
            if (200..<300).contains(response.statusCode) { return }
            if attempt < 3 { await sleep(Double(attempt * 2)); continue }
            throw LaunchError.api("Upload chunk failed with \(response.statusCode)")
        }
    }
}
