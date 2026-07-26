import Foundation
import MotiveCore

/// Where MCP tool calls land. Two implementations: in-process (the host app
/// embeds the MCP server next to its engine) and REST proxy (the `motive-mcp`
/// stdio shim drives a separately-running Motive app).
///
/// Every method mirrors the `MotiveControl` method of the same name, with the
/// same parameters and the same meaning — deliberately, since MCP tools are
/// 1:1 adapters over the one command surface and add no semantics of their
/// own. Read `MotiveControl` for what each verb does; the only difference here
/// is that a `ControlFailure` arrives as a thrown ``TransportError`` rather
/// than a `Result`, because a tool call either produces a payload or an error.
///
/// Note the absence: nothing resolves a question as *answered*. Agents ask,
/// read, and withdraw. See `MotiveEngine.answerQuestion`, which only
/// `MotiveUI` can reach.
public protocol MotiveCommandTransport: Sendable {
    func schema() async throws -> ControlSchema
    func status() async throws -> ControlStatus
    func setState(_ name: String, durationMS: Int?) async throws -> ControlReceipt
    func fireTrigger(_ name: String) async throws -> ControlReceipt
    func say(_ text: String, ttlMS: Int?, respond: ResponseSpec?) async throws -> ControlReceipt
    func dismissSpeech() async throws -> ControlReceipt
    func playScript(_ run: ScriptRun) async throws -> ControlReceipt
    func enqueue(_ steps: [ScriptStep]) async throws -> ControlReceipt
    func queueStatus() async throws -> QueueStatus
    func clearQueue() async throws -> ControlReceipt
    func skip() async throws -> ControlReceipt
    func pause() async throws -> ControlReceipt
    func resume() async throws -> ControlReceipt
    func questions(id: String?) async throws -> QuestionList
    func cancelQuestion(id: String?) async throws -> ControlReceipt
    func activity(since: UInt64?, limit: Int?) async throws -> ActivityPage
    func clearActivity(keep: Int?) async throws -> ControlReceipt
    func questionHistory(limit: Int?) async throws -> QuestionHistoryPage
}

/// A rejected command. Carries the valid vocabulary when the rejection was a
/// bad name, so an agent can correct itself from the error alone rather than
/// re-reading the schema.
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
///
/// Use when the app hosting the companion is also the MCP server: no REST hop, no
/// token, no discovery. An app that ships only this never needs `MotiveHTTP`.
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

    public func say(_ text: String, ttlMS: Int?, respond: ResponseSpec?) async throws -> ControlReceipt {
        try unwrap(await control.say(text, ttlMS: ttlMS, respond: respond))
    }

    public func dismissSpeech() async throws -> ControlReceipt {
        await control.dismissSpeech()
    }

    public func playScript(_ run: ScriptRun) async throws -> ControlReceipt {
        try unwrap(await control.playScript(run))
    }

    public func enqueue(_ steps: [ScriptStep]) async throws -> ControlReceipt {
        try unwrap(await control.enqueue(steps))
    }

    public func queueStatus() async throws -> QueueStatus {
        await control.queueStatus()
    }

    public func clearQueue() async throws -> ControlReceipt {
        await control.clearQueue()
    }

    public func skip() async throws -> ControlReceipt {
        await control.skip()
    }

    public func pause() async throws -> ControlReceipt { await control.pause() }
    public func resume() async throws -> ControlReceipt { await control.resume() }

    public func questions(id: String?) async throws -> QuestionList {
        try unwrapValue(await control.questions(id: id))
    }

    public func cancelQuestion(id: String?) async throws -> ControlReceipt {
        try unwrap(await control.cancelQuestion(id: id))
    }

    public func activity(since: UInt64?, limit: Int?) async throws -> ActivityPage {
        await control.activity(since: since, limit: limit)
    }

    public func clearActivity(keep: Int?) async throws -> ControlReceipt {
        await control.clearActivity(keep: keep)
    }

    public func questionHistory(limit: Int?) async throws -> QuestionHistoryPage {
        await control.questionHistory(limit: limit)
    }

    private func unwrapValue<T>(_ result: Result<T, ControlFailure>) throws -> T {
        switch result {
        case .success(let value): return value
        case .failure(let failure): throw TransportError(message: failure.error, valid: failure.valid)
        }
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
    ///
    /// Reads `runtime/server.json` for the port and `runtime/token` for the
    /// bearer token. Call this per request rather than once at startup: the
    /// token rotates on every app start, so a cached transport stops working
    /// the first time the companion restarts — which it does far more often than an
    /// MCP host does.
    ///
    /// - Parameter paths: Runtime home; `.standard` honors `MOTIVE_HOME`, read
    ///   from *this* process's environment (for the shim, that is the MCP
    ///   host's environment).
    /// - Throws: If either file is missing or unreadable — which is the normal
    ///   signal that no Motive app is running.
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

    public func say(_ text: String, ttlMS: Int?, respond: ResponseSpec?) async throws -> ControlReceipt {
        var body: [String: Any] = ["text": text]
        if let ttlMS { body["ttl"] = ttlMS }
        if let respond {
            let data = try JSONEncoder().encode(respond)
            body["respond"] = try JSONSerialization.jsonObject(with: data)
        }
        return try await post("/v1/say", body: body)
    }

    public func playScript(_ run: ScriptRun) async throws -> ControlReceipt {
        let data = try JSONEncoder().encode(run)
        return try await send(request(path: "/v1/script", method: "POST", body: data))
    }

    public func dismissSpeech() async throws -> ControlReceipt {
        try await send(request(path: "/v1/speech", method: "DELETE", body: nil))
    }

    public func enqueue(_ steps: [ScriptStep]) async throws -> ControlReceipt {
        struct Payload: Encodable { let items: [ScriptStep] }
        let data = try JSONEncoder().encode(Payload(items: steps))
        return try await send(request(path: "/v1/queue", method: "POST", body: data))
    }

    public func queueStatus() async throws -> QueueStatus {
        try await get("/v1/queue")
    }

    public func clearQueue() async throws -> ControlReceipt {
        try await send(request(path: "/v1/queue", method: "DELETE", body: nil))
    }

    public func skip() async throws -> ControlReceipt {
        try await send(request(path: "/v1/queue/current", method: "DELETE", body: nil))
    }

    public func pause() async throws -> ControlReceipt {
        try await post("/v1/queue/pause", body: [:])
    }

    public func resume() async throws -> ControlReceipt {
        try await post("/v1/queue/resume", body: [:])
    }

    public func questions(id: String?) async throws -> QuestionList {
        // No `wait` from MCP: hosts time tool calls out, so an agent polls
        // repeatedly rather than parking a call for half a minute.
        let query = id.map { "?id=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" } ?? ""
        return try await get("/v1/questions" + query)
    }

    public func cancelQuestion(id: String?) async throws -> ControlReceipt {
        let data = id.map { try? JSONSerialization.data(withJSONObject: ["id": $0]) } ?? nil
        return try await send(request(path: "/v1/questions", method: "DELETE", body: data))
    }

    public func activity(since: UInt64?, limit: Int?) async throws -> ActivityPage {
        var parts: [String] = []
        if let since { parts.append("since=\(since)") }
        if let limit { parts.append("limit=\(limit)") }
        let query = parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
        return try await get("/v1/activity" + query)
    }

    public func clearActivity(keep: Int?) async throws -> ControlReceipt {
        let data = keep.map { try? JSONSerialization.data(withJSONObject: ["keep": $0]) } ?? nil
        return try await send(request(path: "/v1/activity", method: "DELETE", body: data))
    }

    public func questionHistory(limit: Int?) async throws -> QuestionHistoryPage {
        let query = limit.map { "?limit=\($0)" } ?? ""
        return try await get("/v1/questions/history" + query)
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
        // Split the query off before appending: `appendingPathComponent`
        // percent-encodes `?`, which would turn a query into part of the path.
        let parts = path.split(separator: "?", maxSplits: 1)
        var url = baseURL.appendingPathComponent(String(parts[0]))
        if parts.count > 1, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = String(parts[1])
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
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
        // Dates cross this hop as ISO8601 (the server encodes them that way);
        // without the matching strategy every question timestamp fails to
        // decode and the whole payload is lost.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
