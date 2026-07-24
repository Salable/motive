import Foundation
import MotiveCore

/// Where MCP tool calls land. Two implementations: in-process (the host app
/// embeds the MCP server next to its engine) and REST proxy (the `motive-mcp`
/// stdio shim drives a separately-running Motive app).
public protocol MotiveCommandTransport: Sendable {
    func schema() async throws -> ControlSchema
    func status() async throws -> ControlStatus
    func setState(_ name: String, durationMS: Int?) async throws -> ControlReceipt
    func fireTrigger(_ name: String) async throws -> ControlReceipt
    func say(_ text: String, ttlMS: Int?) async throws -> ControlReceipt
    func playScript(_ run: ScriptRun) async throws -> ControlReceipt
}

public struct TransportError: Error, CustomStringConvertible {
    public let message: String
    /// The valid vocabulary, when the failure was a bad name.
    public let valid: [String]?

    public init(message: String, valid: [String]? = nil) {
        self.message = message
        self.valid = valid
    }

    public var description: String {
        if let valid { return "\(message) (valid: \(valid.joined(separator: ", ")))" }
        return message
    }
}

/// In-process transport over a `MotiveControl`.
public struct LocalCommandTransport: MotiveCommandTransport {
    private let control: MotiveControl

    public init(control: MotiveControl) {
        self.control = control
    }

    public func schema() async throws -> ControlSchema {
        await control.schema()
    }

    public func status() async throws -> ControlStatus {
        await control.status()
    }

    public func setState(_ name: String, durationMS: Int?) async throws -> ControlReceipt {
        try unwrap(await control.setState(name, durationMS: durationMS))
    }

    public func fireTrigger(_ name: String) async throws -> ControlReceipt {
        try unwrap(await control.fireTrigger(name))
    }

    public func say(_ text: String, ttlMS: Int?) async throws -> ControlReceipt {
        try unwrap(await control.say(text, ttlMS: ttlMS))
    }

    public func playScript(_ run: ScriptRun) async throws -> ControlReceipt {
        try unwrap(await control.playScript(run))
    }

    private func unwrap(_ result: Result<ControlReceipt, ControlFailure>) throws -> ControlReceipt {
        switch result {
        case .success(let receipt): return receipt
        case .failure(let failure): throw TransportError(message: failure.error, valid: failure.valid)
        }
    }
}

/// REST proxy transport: drives a running Motive app found via
/// `~/.motive/runtime/` (or an explicit base URL + token).
public struct RESTCommandTransport: MotiveCommandTransport {
    public let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Discover the running app through the runtime files.
    public static func discover(paths: RuntimePaths = .standard) throws -> RESTCommandTransport {
        guard let info = ServerInfo.load(from: paths.serverInfoURL) else {
            throw TransportError(message: "no running Motive app found (missing \(paths.serverInfoURL.path)); start one first")
        }
        guard info.processIsAlive else {
            throw TransportError(message: "the recorded Motive app (pid \(info.pid)) is no longer running")
        }
        guard let token = TokenManager.load(at: paths.tokenURL) else {
            throw TransportError(message: "no control-plane token at \(paths.tokenURL.path)")
        }
        guard let url = URL(string: "http://127.0.0.1:\(info.port)") else {
            throw TransportError(message: "invalid port in \(paths.serverInfoURL.path)")
        }
        return RESTCommandTransport(baseURL: url, token: token)
    }

    public func schema() async throws -> ControlSchema {
        try await get("/v1/schema")
    }

    public func status() async throws -> ControlStatus {
        try await get("/v1/status")
    }

    public func setState(_ name: String, durationMS: Int?) async throws -> ControlReceipt {
        var body: [String: Any] = ["state": name]
        if let durationMS { body["duration"] = durationMS }
        return try await post("/v1/state", body: body)
    }

    public func fireTrigger(_ name: String) async throws -> ControlReceipt {
        try await post("/v1/trigger", body: ["name": name])
    }

    public func say(_ text: String, ttlMS: Int?) async throws -> ControlReceipt {
        var body: [String: Any] = ["text": text]
        if let ttlMS { body["ttl"] = ttlMS }
        return try await post("/v1/say", body: body)
    }

    public func playScript(_ run: ScriptRun) async throws -> ControlReceipt {
        let data = try JSONEncoder().encode(run)
        return try await send(request(path: "/v1/script", method: "POST", body: data))
    }

    // MARK: internals

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(request(path: path, method: "GET", body: nil))
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await send(request(path: path, method: "POST", body: data))
    }

    private func request(path: String, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            if let failure = try? JSONDecoder().decode(ControlFailure.self, from: data) {
                throw TransportError(message: failure.error, valid: failure.valid)
            }
            throw TransportError(message: "control plane returned HTTP \(status)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
