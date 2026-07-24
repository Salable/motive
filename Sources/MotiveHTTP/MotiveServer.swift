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
public final class MotiveServer: @unchecked Sendable {
    public static let defaultPort = 7877

    public let paths: RuntimePaths
    private let control: MotiveControl
    private let preferredPort: Int
    private let group: MultiThreadedEventLoopGroup
    private let sseHub = SSEHub()
    private let rateLimiter: RateLimiter
    private var channel: Channel?
    private var currentToken: String?
    private var eventPump: Task<Void, Never>?

    public init(
        control: MotiveControl,
        paths: RuntimePaths = .standard,
        preferredPort: Int = MotiveServer.defaultPort,
        rateLimiter: RateLimiter = RateLimiter()
    ) {
        self.control = control
        self.paths = paths
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
                            sseHub: sseHub
                        )
                    )
                }
            }

        let bound: Channel
        do {
            bound = try await bootstrap.bind(host: "127.0.0.1", port: preferredPort).get()
        } catch {
            // Preferred port taken: fall back to an ephemeral port;
            // server.json records the truth either way.
            bound = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
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
            name: await control.displayName
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
                case .scriptStarted(let id, _):
                    sseHub.broadcast(event: "script", json: Self.encode(ScriptEventDTO(id: id, phase: "started", step: nil)))
                case .scriptStepChanged(let id, let index):
                    sseHub.broadcast(event: "script", json: Self.encode(ScriptEventDTO(id: id, phase: "step", step: index)))
                case .scriptFinished(let id):
                    sseHub.broadcast(event: "script", json: Self.encode(ScriptEventDTO(id: id, phase: "finished", step: nil)))
                case .scriptCancelled(let id):
                    sseHub.broadcast(event: "script", json: Self.encode(ScriptEventDTO(id: id, phase: "cancelled", step: nil)))
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
struct ScriptEventDTO: Codable {
    let id: String
    let phase: String
    let step: Int?
}
struct SpeechEventDTO: Codable {
    let id: String
    let text: String?
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

final class MotiveHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    static let maxBodyBytes = 64 * 1024

    private let control: MotiveControl
    private let tokenProvider: @Sendable () -> String?
    private let rateLimiter: RateLimiter
    private let sseHub: SSEHub

    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    private var rejected = false

    init(
        control: MotiveControl,
        tokenProvider: @escaping @Sendable () -> String?,
        rateLimiter: RateLimiter,
        sseHub: SSEHub
    ) {
        self.control = control
        self.tokenProvider = tokenProvider
        self.rateLimiter = rateLimiter
        self.sseHub = sseHub
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

    // MARK: routing

    private func route(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri

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
            Task { [control] in
                Self.respond(channel: channel, result: await control.say(text, ttlMS: ttl))
            }

        case (.DELETE, "/v1/speech"):
            guard allowMutation(context: context) else { return }
            Task { [control] in
                Self.respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(await control.dismissSpeech()))
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

    static func respond(channel: Channel, result: Result<ControlReceipt, ControlFailure>) {
        switch result {
        case .success(let receipt):
            respondJSON(channel: channel, status: .ok, json: MotiveServer.encode(receipt))
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
