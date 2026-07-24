import Foundation

/// An addressable speech bubble shown next to the sprite.
public struct SpeechBubble: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    /// Seconds the bubble stays up once fully shown. `nil` means until replaced
    /// or dismissed.
    public let ttl: TimeInterval?
    public let postedAt: Date

    public static let maxLength = 400

    public init(id: String = UUID().uuidString, text: String, ttl: TimeInterval? = 8, postedAt: Date = Date()) {
        self.id = id
        self.text = String(text.prefix(Self.maxLength))
        self.ttl = ttl
        self.postedAt = postedAt
    }

    public func isExpired(at now: Date) -> Bool {
        guard let ttl else { return false }
        return now.timeIntervalSince(postedAt) >= ttl
    }
}

/// Everything observers (rendering surfaces, SSE clients, MCP sessions) can
/// learn from the engine.
public enum MotiveEvent: Equatable, Sendable {
    case stateChanged(RenderDirective)
    case speechPosted(SpeechBubble)
    case speechDismissed(id: String)
}

/// The runtime hub for one actor: owns the state machine, ticks it, holds the
/// current speech bubble, and fans typed events out to any number of
/// observers. All decision logic stays in `ActorStateMachine`; the engine just
/// supplies the clock and the fan-out.
public actor MotiveEngine {
    public private(set) var machine: ActorStateMachine
    public private(set) var speech: SpeechBubble?

    private var observers: [UUID: AsyncStream<MotiveEvent>.Continuation] = [:]
    private var tickTask: Task<Void, Never>?
    private let tickInterval: TimeInterval

    public init(definition: BehaviorDefinition, initialState: String = "idle", tickInterval: TimeInterval = 0.1) {
        self.machine = ActorStateMachine(definition: definition, initialState: initialState)
        self.tickInterval = tickInterval
    }

    deinit {
        tickTask?.cancel()
    }

    // MARK: observation

    /// A stream of engine events. Each caller gets an independent stream that
    /// begins with the current state so late joiners render correctly.
    public func events() -> AsyncStream<MotiveEvent> {
        let id = UUID()
        let current = machine.directive()
        let currentSpeech = speech
        return AsyncStream { continuation in
            continuation.yield(.stateChanged(current))
            if let currentSpeech {
                continuation.yield(.speechPosted(currentSpeech))
            }
            self.observers[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func broadcast(_ event: MotiveEvent) {
        for continuation in observers.values {
            continuation.yield(event)
        }
    }

    // MARK: commands

    public var currentDirective: RenderDirective { machine.directive() }

    @discardableResult
    public func requestState(_ name: String, duration: TimeInterval? = nil, now: Date = Date()) -> ActorStateMachine.Outcome {
        let outcome = machine.requestState(name, duration: duration, now: now)
        if case .changed(let directive) = outcome {
            broadcast(.stateChanged(directive))
        }
        return outcome
    }

    @discardableResult
    public func fireTrigger(_ name: String, now: Date = Date()) -> ActorStateMachine.Outcome {
        let outcome = machine.fireTrigger(name, now: now)
        if case .changed(let directive) = outcome {
            broadcast(.stateChanged(directive))
        }
        return outcome
    }

    @discardableResult
    public func say(_ text: String, ttl: TimeInterval? = 8, now: Date = Date()) -> SpeechBubble {
        let bubble = SpeechBubble(text: text, ttl: ttl, postedAt: now)
        speech = bubble
        broadcast(.speechPosted(bubble))
        return bubble
    }

    public func dismissSpeech() {
        guard let bubble = speech else { return }
        speech = nil
        broadcast(.speechDismissed(id: bubble.id))
    }

    // MARK: clock

    /// Advance the machine once. Exposed for tests and for hosts that drive
    /// their own clock; `start()` calls this on a repeating task.
    public func tick(now: Date = Date()) {
        if case .changed(let directive) = machine.tick(now: now) {
            broadcast(.stateChanged(directive))
        }
        if let bubble = speech, bubble.isExpired(at: now) {
            speech = nil
            broadcast(.speechDismissed(id: bubble.id))
        }
    }

    /// Begin ticking on the engine's own clock. Idempotent.
    public func start() {
        guard tickTask == nil else { return }
        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.tick()
            }
        }
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
    }
}
