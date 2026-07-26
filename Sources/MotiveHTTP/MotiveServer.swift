import Foundation
import MotiveCore
import NIOCore
import NIOHTTP1
import NIOPosix

/// Loopback HTTP control plane: the POST-able animation server.
///
/// Transport hardening: 127.0.0.1 bind only, per-boot 0600 token with
/// constant-time compare, 64KB body cap, shared token-bucket rate limit, and
/// fire-and-forget-friendly responses (every non-SSE response closes the
/// connection; clients are one-shot curls).
///
/// Pipelining assistance is deliberately disabled: `/v1/events` holds an
/// unterminated SSE response open, which the pipelining handler would treat
/// as a stuck response and quiesce.
/// Lifecycle note: `stop()` shuts down the event-loop group, so a stopped
/// server cannot be restarted — build a fresh instance to rebind (settings
/// flows do exactly this).
public final class MotiveServer: @unchecked Sendable {
    public static let defaultPort = 7877

    public let paths: RuntimePaths
    public let bindHost: String
    private let control: MotiveControl
    private let preferredPort: Int
    private let group: MultiThreadedEventLoopGroup
    private let sseHub = SSEHub()
    private let waiters = WaiterBudget()
    private let rateLimiter: RateLimiter
    private var channel: Channel?
    private var currentToken: String?
    private var eventPump: Task<Void, Never>?

    public init(
        control: MotiveControl,
        paths: RuntimePaths = .standard,
        preferredPort: Int = MotiveServer.defaultPort,
        bindHost: String = "127.0.0.1",
        rateLimiter: RateLimiter = RateLimiter()
    ) {
        self.control = control
        self.paths = paths
        self.bindHost = bindHost
        self.preferredPort = preferredPort
        self.rateLimiter = rateLimiter
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    @discardableResult
    public func start() async throws -> ServerInfo {
        try paths.prepare()

        let control = self.control
        let sseHub = self.sseHub
        let rateLimiter = self.rateLimiter
        let waiters = self.waiters
        let tokenProvider: @Sendable () -> String? = { [weak self] in self?.currentToken }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: false,
                    withErrorHandling: true
                ).flatMap {
                    channel.pipeline.addHandler(
                        MotiveHTTPHandler(
                            control: control,
                            tokenProvider: tokenProvider,
                            rateLimiter: rateLimiter,
                            sseHub: sseHub,
                            waiters: waiters
                        )
                    )
                }
            }

        let bound: Channel
        do {
            bound = try await bootstrap.bind(host: bindHost, port: preferredPort).get()
        } catch {
            // Preferred port taken: fall back to an ephemeral port;
            // server.json records the truth either way.
            bound = try await bootstrap.bind(host: bindHost, port: 0).get()
        }
        channel = bound

        guard let port = bound.localAddress?.port else {
            throw MotiveServerError.noLocalPort
        }

        // Token and discovery file are written only after a successful bind so
        // a losing second instance can never clobber the live server's token.
        currentToken = try TokenManager.rotate(at: paths.tokenURL)
        let info = ServerInfo(
            port: port,
            pid: ProcessInfo.processInfo.processIdentifier,
            version: MotiveVersion.current,
            name: await control.displayName,
            host: bindHost
        )
        try info.write(to: paths.serverInfoURL)

        // Pump engine events out to SSE observers.
        let engine = await control.engine
        eventPump = Task { [sseHub] in
            for await event in await engine.events() {
                guard !Task.isCancelled else { return }
                switch event {
                case .stateChanged(let directive):
                    sseHub.broadcast(event: "state", json: Self.encode(StateEventDTO(state: directive.stateName)))
                case .speechPosted(let bubble):
                    sseHub.broadcast(event: "speech", json: Self.encode(SpeechEventDTO(id: bubble.id, text: bubble.text)))
                case .speechDismissed(let id):
                    sseHub.broadcast(event: "speech-dismissed", json: Self.encode(SpeechEventDTO(id: id, text: nil)))
                case .queueItemStarted(let id, let remaining):
                    sseHub.broadcast(event: "queue", json: Self.encode(QueueEventDTO(phase: "item-started", id: id, remaining: remaining, dropped: nil)))
                case .queueItemFinished(let id):
                    sseHub.broadcast(event: "queue", json: Self.encode(QueueEventDTO(phase: "item-finished", id: id, remaining: nil, dropped: nil)))
                case .queueDrained:
                    sseHub.broadcast(event: "queue", json: Self.encode(QueueEventDTO(phase: "drained", id: nil, remaining: nil, dropped: nil)))
                case .queueFlushed(let dropped):
                    sseHub.broadcast(event: "queue", json: Self.encode(QueueEventDTO(phase: "flushed", id: nil, remaining: nil, dropped: dropped)))
                case .queueItemAwaiting(let id, _):
                    sseHub.broadcast(event: "queue", json: Self.encode(QueueEventDTO(phase: "awaiting", id: id, remaining: nil, dropped: nil)))
                case .questionAsked(let record):
                    sseHub.broadcast(event: "question", json: Self.encode(QuestionEventDTO(record: record, phase: "asked")))
                case .questionPresented(let id):
                    sseHub.broadcast(event: "question", json: Self.encode(QuestionEventDTO(phase: "presented", id: id)))
                case .questionResolved(let record):
                    sseHub.broadcast(event: "question", json: Self.encode(QuestionEventDTO(record: record, phase: "resolved")))
                }
            }
        }
        return info
    }

    public func stop() async {
        eventPump?.cancel()
        eventPump = nil
        sseHub.closeAll()
        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        // Both files are ours by construction (rotated/written at start).
        try? FileManager.default.removeItem(at: paths.serverInfoURL)
        try? FileManager.default.removeItem(at: paths.tokenURL)
        try? await group.shutdownGracefully()
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return #"{"ok":false,"error":"encoding"}"# }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum MotiveServerError: Error {
    case noLocalPort
}

struct StateEventDTO: Codable { let state: String }
struct QueueEventDTO: Codable {
    let phase: String
    let id: String?
    let remaining: Int?
    let dropped: Int?
}
struct SpeechEventDTO: Codable {
    let id: String
    let text: String?
}

/// One `question` event carries the whole lifecycle, distinguished by `phase`
/// — the same discipline the `queue` event uses, rather than five event names.
struct QuestionEventDTO: Codable {
    let phase: String
    let id: String
    let status: String?
    let form: String?
    let text: String?
    let choices: [String]?
    let answer: AnswerContent?
    let expiresAt: Date?

    init(phase: String, id: String) {
        self.phase = phase
        self.id = id
        status = nil
        form = nil
        text = nil
        choices = nil
        answer = nil
        expiresAt = nil
    }

    init(record: QuestionRecord, phase: String) {
        self.phase = phase
        id = record.id
        status = record.status.rawValue
        form = record.respond.form.rawValue
        text = record.text
        choices = record.respond.choices
        answer = record.answer
        expiresAt = record.expiresAt
    }
}

// MARK: - SSE hub

final class SSEHub: @unchecked Sendable {
    static let maxClients = 16

    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    // One heartbeat for the whole hub, alive only while observers exist —
    // per-connection timers would fan out N heartbeats to N clients (N²).
    private var heartbeatTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "motive.sse-heartbeat")

    func add(_ channel: Channel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard channels.count < Self.maxClients else { return false }
        channels[ObjectIdentifier(channel)] = channel
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.remove(channel)
        }
        if heartbeatTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in self?.write(": heartbeat\n\n") }
            timer.resume()
            heartbeatTimer = timer
        }
        return true
    }

    func remove(_ channel: Channel) {
        lock.lock()
        defer { lock.unlock() }
        channels.removeValue(forKey: ObjectIdentifier(channel))
        if channels.isEmpty {
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
        }
    }

    func broadcast(event: String, json: String) {
        write("event: \(event)\ndata: \(json)\n\n")
    }

    private func write(_ frame: String) {
        lock.lock()
        let targets = Array(channels.values)
        lock.unlock()
        for channel in targets {
            var buffer = channel.allocator.buffer(capacity: frame.utf8.count)
            buffer.writeString(frame)
            let part = HTTPServerResponsePart.body(.byteBuffer(buffer))
            channel.writeAndFlush(part).whenFailure { [weak self] _ in
                self?.remove(channel)
                channel.close(promise: nil)
            }
        }
    }

    func closeAll() {
        lock.lock()
        let targets = Array(channels.values)
        channels.removeAll()
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        lock.unlock()
        for channel in targets {
            channel.close(promise: nil)
        }
    }
}

// MARK: - HTTP handler

/// Bounds how many long-polls may park at once. Process-wide: the NIO group
/// runs a single thread and every parked poll holds a connection open, so this
/// is the same class of protection `SSEHub.maxClients` gives the event stream.
final class WaiterBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private let limit: Int

    init(limit: Int = 8) { self.limit = limit }

    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight < limit else { return false }
        inFlight += 1
        return true
    }

    func release() {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        lock.unlock()
    }
}

final class MotiveHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    static let maxBodyBytes = 64 * 1024

    private let control: MotiveControl
    private let tokenProvider: @Sendable () -> String?
    private let rateLimiter: RateLimiter
    private let sseHub: SSEHub
    private let waiters: WaiterBudget

    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    private var rejected = false

    init(
        control: MotiveControl,
        tokenProvider: @escaping @Sendable () -> String?,
        rateLimiter: RateLimiter,
        sseHub: SSEHub,
        waiters: WaiterBudget
    ) {
        self.control = control
        self.tokenProvider = tokenProvider
        self.rateLimiter = rateLimiter
        self.sseHub = sseHub
        self.waiters = waiters
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            body = context.channel.allocator.buffer(capacity: 0)
            rejected = false

        case .body(var part):
            guard !rejected else { return }
            if (body?.readableBytes ?? 0) + part.readableBytes > Self.maxBodyBytes {
                rejected = true
                respondJSON(context: context, status: .payloadTooLarge, json: #"{"ok":false,"error":"payload_too_large"}"#)
                return
            }
            body?.writeBuffer(&part)

        case .end:
            guard !rejected, let head else {
                self.head = nil
                self.body = nil
                return
            }
            let bodyData = body.map { Data($0.readableBytesView) } ?? Data()
            self.head = nil
            self.body = nil
            route(context: context, head: head, body: bodyData)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    /// Long-poll ceiling. Callers loop rather than waiting once for minutes:
    /// the event loop runs on a single thread and every parked poll pins a
    /// connection.
    static let maxWaitMS = 30_000

    static func parseQuery(_ uri: String) -> [String: String] {
        guard let queryPart = uri.split(separator: "?", maxSplits: 1).dropFirst().first else {
            return [:]
        }
        var result: [String: String] = [:]
        for pair in queryPart.split(separator: "&") {
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard let key = halves.first else { continue }
            let value = halves.count > 1 ? String(halves[1]) : ""
            result[String(key)] = value.removingPercentEncoding ?? value
        }
        return result
    }

    // MARK: routing

    private func route(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let query = Self.parseQuery(head.uri)

        if head.method == .GET, path == "/v1/ping" {
            respondJSON(context: context, status: .ok, json: #"{"ok":true,"version":"\#(MotiveVersion.current)"}"#)
            return
        }

        guard authorized(head: head) else {
            respondJSON(context: context, status: .unauthorized, json: #"{"ok":false,"error":"unauthorized"}"#)
            return
        }

        let channel = context.channel
        switch (head.method, path) {
        case (.GET, "/v1/schema"):
            Task { [control] in
                Self.respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(await control.schema()))
            }

        case (.GET, "/v1/status"):
            Task { [control] in
                Self.respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(await control.status()))
            }

        case (.GET, "/v1/events"):
            startSSE(context: context)

        case (.POST, "/v1/state"):
            guard allowMutation(context: context) else { return }
            guard let json = decodeObject(body) else {
                respondJSON(context: context, status: .badRequest, json: #"{"ok":false,"error":"invalid_json"}"#)
                return
            }
            guard let state = json["state"] as? String else {
                respondJSON(context: context, status: .badRequest, json: #"{"ok":false,"error":"missing_state"}"#)
                return
            }
            let duration = (json["duration"] as? NSNumber).map { max(0, $0.intValue) }
            Task { [control] in
                Self.respond(channel: channel, result: await control.setState(state, durationMS: duration))
            }

        case (.POST, "/v1/trigger"):
            guard allowMutation(context: context) else { return }
            guard let json = decodeObject(body) else {
                respondJSON(context: context, status: .badRequest, json: #"{"ok":false,"error":"invalid_json"}"#)
                return
            }
            guard let name = (json["name"] as? String) ?? (json["trigger"] as? String) else {
                respondJSON(context: context, status: .badRequest, json: #"{"ok":false,"error":"missing_name"}"#)
                return
            }
            Task { [control] in
                Self.respond(channel: channel, result: await control.fireTrigger(name))
            }

        case (.POST, "/v1/say"):
            guard allowMutation(context: context) else { return }
            guard let json = decodeObject(body) else {
                respondJSON(context: context, status: .badRequest, json: #"{"ok":false,"error":"invalid_json"}"#)
                return
            }
            guard let text = json["text"] as? String else {
                respondJSON(context: context, status: .badRequest, json: #"{"ok":false,"error":"missing_text"}"#)
                return
            }
            let ttl = (json["ttl"] as? NSNumber).map { max(0, $0.intValue) }
            var respond: ResponseSpec?
            if let raw = json["respond"] {
                guard let data = try? JSONSerialization.data(withJSONObject: raw),
                      let spec = try? JSONDecoder().decode(ResponseSpec.self, from: data)
                else {
                    respondJSON(context: context, status: .badRequest, json: #"{"ok":false,"error":"invalid_respond"}"#)
                    return
                }
                respond = spec
            }
            let spec = respond
            Task { [control] in
                Self.respond(channel: channel, result: await control.say(text, ttlMS: ttl, respond: spec))
            }

        case (.DELETE, "/v1/speech"):
            guard allowMutation(context: context) else { return }
            Task { [control] in
                Self.respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(await control.dismissSpeech()))
            }

        case (.POST, "/v1/queue"):
            guard allowMutation(context: context) else { return }
            struct EnqueueRequest: Decodable {
                let items: [ScriptStep]?
                let steps: [ScriptStep]?
            }
            let steps: [ScriptStep]
            do {
                let decoded = try JSONDecoder().decode(EnqueueRequest.self, from: body.isEmpty ? Data("{}".utf8) : body)
                guard let list = decoded.items ?? decoded.steps else {
                    respondJSON(context: context, status: .badRequest, json: #"{"ok":false,"error":"missing_items"}"#)
                    return
                }
                steps = list
            } catch {
                respondJSON(context: context, status: .badRequest, json: #"{"ok":false,"error":"invalid_items"}"#)
                return
            }
            Task { [control] in
                Self.respond(channel: channel, result: await control.enqueue(steps))
            }

        case (.GET, "/v1/queue"):
            Task { [control] in
                Self.respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(await control.queueStatus()))
            }

        case (.DELETE, "/v1/queue"):
            guard allowMutation(context: context) else { return }
            Task { [control] in
                Self.respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(await control.clearQueue()))
            }

        case (.DELETE, "/v1/queue/current"):
            guard allowMutation(context: context) else { return }
            Task { [control] in
                Self.respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(await control.skip()))
            }

        case (.POST, "/v1/queue/pause"):
            guard allowMutation(context: context) else { return }
            Task { [control] in
                Self.respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(await control.pause()))
            }

        case (.POST, "/v1/queue/resume"):
            guard allowMutation(context: context) else { return }
            Task { [control] in
                Self.respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(await control.resume()))
            }

        case (.GET, "/v1/questions"):
            let id = query["id"]
            let wait = query["wait"].flatMap(Int.init).map { min(max(0, $0), Self.maxWaitMS) } ?? 0
            guard wait == 0 || waiters.acquire() else {
                // Too many parked polls: answer immediately rather than
                // holding another connection on a single-threaded loop.
                Task { [control] in
                    Self.respond(channel: channel, result: await control.questions(id: id))
                }
                return
            }
            Task { [control, waiters] in
                defer { if wait > 0 { waiters.release() } }
                let deadline = Date().addingTimeInterval(TimeInterval(wait) / 1_000)
                while true {
                    let result = await control.questions(id: id)
                    // A resolved question, or an unknown one, returns at once —
                    // `wait` only ever delays an answer that might still come.
                    if case .success(let list) = result {
                        if let question = list.question, question.status != "awaiting" {
                            Self.respond(channel: channel, result: result)
                            return
                        }
                        if id == nil, !list.open.isEmpty {
                            Self.respond(channel: channel, result: result)
                            return
                        }
                    } else {
                        Self.respond(channel: channel, result: result)
                        return
                    }
                    if Date() >= deadline || Task.isCancelled {
                        // A timed-out long poll is a 200 with status
                        // "awaiting", never an error: that is what makes the
                        // caller's loop trivially correct.
                        Self.respond(channel: channel, result: result)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }

        case (.DELETE, "/v1/questions"):
            guard allowMutation(context: context) else { return }
            let id = (decodeObject(body)?["id"] as? String) ?? query["id"]
            Task { [control] in
                Self.respond(channel: channel, result: await control.cancelQuestion(id: id))
            }

        case (.GET, "/v1/activity"):
            let since = query["since"].flatMap(UInt64.init)
            let limit = query["limit"].flatMap(Int.init)
            Task { [control] in
                Self.respondJSON(
                    channel: channel, status: .ok,
                    json: MotiveServer.encode(await control.activity(since: since, limit: limit))
                )
            }

        case (.DELETE, "/v1/activity"):
            guard allowMutation(context: context) else { return }
            let keep = (decodeObject(body)?["keep"] as? NSNumber)?.intValue
                ?? query["keep"].flatMap(Int.init)
            Task { [control] in
                Self.respondJSON(
                    channel: channel, status: .ok,
                    json: MotiveServer.encode(await control.clearActivity(keep: keep))
                )
            }

        case (.GET, "/v1/questions/history"):
            let limit = query["limit"].flatMap(Int.init)
            Task { [control] in
                Self.respondJSON(
                    channel: channel, status: .ok,
                    json: MotiveServer.encode(await control.questionHistory(limit: limit))
                )
            }

        case (.POST, "/v1/script"):
            guard allowMutation(context: context) else { return }
            let run: ScriptRun
            do {
                run = try JSONDecoder().decode(ScriptRun.self, from: body.isEmpty ? Data("{}".utf8) : body)
            } catch {
                respondJSON(context: context, status: .badRequest, json: #"{"ok":false,"error":"invalid_steps"}"#)
                return
            }
            Task { [control] in
                Self.respond(channel: channel, result: await control.playScript(run))
            }

        case (.DELETE, "/v1/script"):
            guard allowMutation(context: context) else { return }
            Task { [control] in
                Self.respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(await control.cancelScript()))
            }

        default:
            respondJSON(context: context, status: .notFound, json: #"{"ok":false,"error":"not_found"}"#)
        }
    }

    private func decodeObject(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body.isEmpty ? Data("{}".utf8) : body)) as? [String: Any]
    }

    private func allowMutation(context: ChannelHandlerContext) -> Bool {
        guard rateLimiter.allow() else {
            respondJSON(context: context, status: .tooManyRequests, json: #"{"ok":false,"error":"rate_limited"}"#)
            return false
        }
        return true
    }

    // MARK: SSE

    private func startSSE(context: ChannelHandlerContext) {
        guard sseHub.add(context.channel) else {
            respondJSON(context: context, status: .serviceUnavailable, json: #"{"ok":false,"error":"too_many_observers"}"#)
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)

        var opening = context.channel.allocator.buffer(capacity: 32)
        opening.writeString(": connected\n\n")
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(opening))), promise: nil)
    }

    // MARK: responses

    private func authorized(head: HTTPRequestHead) -> Bool {
        guard let expected = tokenProvider() else { return false }
        var provided: String?
        if let bearer = head.headers.first(name: "Authorization"), bearer.hasPrefix("Bearer ") {
            provided = String(bearer.dropFirst("Bearer ".count))
        } else if let headerToken = head.headers.first(name: "X-Motive-Token") {
            provided = headerToken
        }
        guard let provided else { return false }
        return TokenManager.constantTimeEquals(provided, expected)
    }

    private func respondJSON(context: ChannelHandlerContext, status: HTTPResponseStatus, json: String) {
        Self.respondJSON(channel: context.channel, status: status, json: json)
    }

    static func respond<Success: Encodable>(
        channel: Channel,
        result: Result<Success, ControlFailure>
    ) {
        switch result {
        case .success(let value):
            respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(value))
        case .failure(let failure):
            respondJSON(channel: channel, status: .badRequest, json: MotiveServer.encode(failure))
        }
    }

    static func respondJSON(channel: Channel, status: HTTPResponseStatus, json: String) {
        channel.eventLoop.execute {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: String(json.utf8.count))
            headers.add(name: "Connection", value: "close")
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            var buffer = channel.allocator.buffer(capacity: json.utf8.count)
            buffer.writeString(json)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }
}
