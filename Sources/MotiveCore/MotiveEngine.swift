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
    case scriptStarted(id: String, stepCount: Int)
    case scriptStepChanged(id: String, index: Int)
    case scriptFinished(id: String)
    case scriptCancelled(id: String)
}

/// The runtime hub for one actor: owns the state machine, ticks it, holds the
/// current speech bubble, and fans typed events out to any number of
/// observers. All decision logic stays in `ActorStateMachine`; the engine just
/// supplies the clock and the fan-out.
public actor MotiveEngine {
    public private(set) var machine: ActorStateMachine
    public private(set) var speech: SpeechBubble?
    private var scriptPlayer = ScriptPlayer()

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
        cancelScriptIfRunning(now: now)
        return applyState(name, duration: duration, now: now)
    }

    @discardableResult
    public func fireTrigger(_ name: String, now: Date = Date()) -> ActorStateMachine.Outcome {
        cancelScriptIfRunning(now: now)
        return applyTrigger(name, now: now)
    }

    @discardableResult
    public func say(_ text: String, ttl: TimeInterval? = 8, now: Date = Date()) -> SpeechBubble {
        cancelScriptIfRunning(now: now)
        return applySay(text, ttl: ttl, now: now)
    }

    public func dismissSpeech(now: Date = Date()) {
        cancelScriptIfRunning(now: now)
        guard let bubble = speech else { return }
        speech = nil
        broadcast(.speechDismissed(id: bubble.id))
    }

    // MARK: scripts

    /// Play a script. Latest-wins: a running script is cancelled and
    /// replaced. Callers should validate first (`ScriptRun.validate`) — an
    /// unvalidated run that names unknown states simply no-ops those steps.
    public func playScript(_ run: ScriptRun, now: Date = Date()) {
        applyScriptEffects(scriptPlayer.play(run, now: now), now: now)
    }

    public func cancelScript(now: Date = Date()) {
        applyScriptEffects(scriptPlayer.cancel(now: now), now: now)
    }

    public var isScriptRunning: Bool { scriptPlayer.isRunning }

    /// External mutating commands interrupt a running script — latest-wins;
    /// the interrupting command is the new truth (no forced return to idle).
    private func cancelScriptIfRunning(now: Date) {
        guard scriptPlayer.isRunning else { return }
        applyScriptEffects(scriptPlayer.cancel(now: now), now: now)
    }

    /// Execute player effects. Script-originated actions use the private
    /// apply paths (never the public commands) so a script can't cancel
    /// itself.
    private func applyScriptEffects(_ effects: [ScriptPlayer.Effect], now: Date) {
        for effect in effects {
            switch effect {
            case .perform(.say(let text, let ttl)):
                applySay(text, ttl: ttl > 0 ? ttl : nil, now: now)
            case .perform(.setState(let name)):
                applyState(name, duration: nil, now: now)
            case .perform(.trigger(let name)):
                applyTrigger(name, now: now)
            case .emit(.started(let id, let stepCount)):
                broadcast(.scriptStarted(id: id, stepCount: stepCount))
            case .emit(.stepChanged(let id, let index)):
                broadcast(.scriptStepChanged(id: id, index: index))
            case .emit(.finished(let id)):
                broadcast(.scriptFinished(id: id))
            case .emit(.cancelled(let id)):
                broadcast(.scriptCancelled(id: id))
            }
        }
    }

    // MARK: private apply paths (no script cancellation)

    @discardableResult
    private func applyState(_ name: String, duration: TimeInterval?, now: Date) -> ActorStateMachine.Outcome {
        let outcome = machine.requestState(name, duration: duration, now: now)
        if case .changed(let directive) = outcome {
            broadcast(.stateChanged(directive))
        }
        return outcome
    }

    @discardableResult
    private func applyTrigger(_ name: String, now: Date) -> ActorStateMachine.Outcome {
        let outcome = machine.fireTrigger(name, now: now)
        if case .changed(let directive) = outcome {
            broadcast(.stateChanged(directive))
        }
        return outcome
    }

    @discardableResult
    private func applySay(_ text: String, ttl: TimeInterval?, now: Date) -> SpeechBubble {
        let bubble = SpeechBubble(text: text, ttl: ttl, postedAt: now)
        speech = bubble
        broadcast(.speechPosted(bubble))
        return bubble
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
        // Script effects run last so a say-step's fresh bubble is never
        // expired by the same tick.
        applyScriptEffects(scriptPlayer.tick(now: now), now: now)
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
