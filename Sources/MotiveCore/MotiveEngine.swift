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
    case queueItemStarted(id: String, remaining: Int)
    case queueItemFinished(id: String)
    /// The last queued item finished naturally.
    case queueDrained
    /// An explicit flush dropped pending items.
    case queueFlushed(dropped: Int)
}

/// What a successful enqueue admitted.
public struct EnqueueReceipt: Equatable, Sendable {
    public let itemIDs: [String]
    public let queueDepth: Int
}

/// The runtime hub for one actor: owns the state machine, the action queue,
/// and the current speech bubble; ticks them; and fans typed events out to
/// observers.
///
/// Queue-first model: every command is a queue item. Direct verbs
/// (`say`/`requestState`/`fireTrigger`) enqueue at the **head** — they play
/// next, cutting the current item's remaining hold, and everything already
/// queued continues afterwards. Flows enqueue at the tail. Nothing is
/// dropped except by an explicit `flushQueue`.
public actor MotiveEngine {
    public private(set) var machine: ActorStateMachine
    public private(set) var speech: SpeechBubble?
    /// The "standard" resting state (the resolved initial state): duration'd
    /// states auto-revert to it, and clearing the queue returns to it.
    public let defaultState: String
    private var queue: ActionQueue

    private var observers: [UUID: AsyncStream<MotiveEvent>.Continuation] = [:]
    private var tickTask: Task<Void, Never>?
    private let tickInterval: TimeInterval

    public init(definition: BehaviorDefinition, initialState: String = "idle", tickInterval: TimeInterval = 0.1) {
        let machine = ActorStateMachine(definition: definition, initialState: initialState)
        self.machine = machine
        self.defaultState = machine.defaultStateName
        self.queue = ActionQueue(definition: definition)
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

    // MARK: queue

    /// Append items (tail by default). All-or-nothing validation and depth
    /// cap; admitted items start executing within this call when due.
    public func enqueue(
        _ items: [QueueItem],
        at position: ActionQueue.Position = .tail,
        now: Date = Date()
    ) -> Result<EnqueueReceipt, ControlFailure> {
        switch queue.enqueue(items, at: position, now: now) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let effects):
            applyQueueEffects(effects, now: now)
            return .success(EnqueueReceipt(itemIDs: items.map(\.id), queueDepth: queue.depth))
        }
    }

    /// Wipe pending items, stop waiting on the current one, and return to the
    /// default state — clearing a scene never leaves the sprite stuck in a
    /// state a dropped item would have cleaned up. `revertToDefault: false`
    /// is for queue *replacement* (playScript), where the incoming items set
    /// their own state and a reset would flash. Returns the dropped count.
    @discardableResult
    public func flushQueue(now: Date = Date(), revertToDefault: Bool = true) -> Int {
        let effects = queue.flush(now: now)
        let dropped = effects.compactMap { effect -> Int? in
            if case .emit(.flushed(let count)) = effect { return count }
            return nil
        }.first ?? 0
        applyQueueEffects(effects, now: now)
        if revertToDefault {
            applyState(defaultState, duration: nil, now: now)
        }
        return dropped
    }

    /// Skip the current queue item: it finishes immediately and the next
    /// pending item starts (or the queue drains). Pending items are preserved.
    /// A skipped `say`'s bubble is dismissed. Returns the skipped item's id,
    /// or nil when the queue was idle (no-op).
    @discardableResult
    public func skipCurrent(now: Date = Date()) -> String? {
        guard let current = queue.snapshot(now: now).current else { return nil }
        if case .say = current.step {
            // Before applying effects: the next item may post a fresh bubble.
            dismissSpeech(now: now)
        }
        applyQueueEffects(queue.skip(now: now), now: now)
        return current.id
    }

    public var queueDepth: Int { queue.depth }

    public func queueSnapshot(now: Date = Date()) -> QueueSnapshot {
        queue.snapshot(now: now)
    }

    /// Compat sugar for `/v1/script`: replace the queue with these steps.
    /// Returns the enqueue result — the queue is already flushed by the time
    /// a failure is reported, so callers who ignore it are choosing a silent
    /// empty stage over a visible error.
    @discardableResult
    public func playScript(_ run: ScriptRun, now: Date = Date()) -> Result<EnqueueReceipt, ControlFailure> {
        _ = flushQueue(now: now, revertToDefault: false)
        return enqueue(run.steps.map(QueueItem.init(step:)), at: .tail, now: now)
    }

    // MARK: direct verbs (head-enqueue: "plays next")

    @discardableResult
    public func requestState(_ name: String, duration: TimeInterval? = nil, now: Date = Date()) -> ActorStateMachine.Outcome {
        guard machine.definition.state(named: name) != nil else {
            return .rejected(valid: machine.definition.validStateNames)
        }
        let item = QueueItem(
            action: .setState(name: name, durationMS: duration.map { Int($0 * 1_000) }),
            holdMS: nil
        )
        lastMachineOutcome = nil
        if case .failure = enqueue([item], at: .head, now: now) {
            return .noChange // queue full — pathological; nothing dropped
        }
        return lastMachineOutcome ?? .noChange
    }

    @discardableResult
    public func fireTrigger(_ name: String, now: Date = Date()) -> ActorStateMachine.Outcome {
        guard machine.definition.triggers[name] != nil else {
            return .rejected(valid: machine.definition.triggers.keys.sorted())
        }
        // Default hold = the gesture's loop duration, so a queued flow
        // resumes only after the gesture has played out.
        let item = QueueItem(action: .trigger(name: name))
        lastMachineOutcome = nil
        if case .failure = enqueue([item], at: .head, now: now) {
            return .noChange
        }
        return lastMachineOutcome ?? .noChange
    }

    @discardableResult
    public func say(_ text: String, ttl: TimeInterval? = 8, now: Date = Date()) -> SpeechBubble {
        let holdMS = (ttl ?? 8) * 1_000
        let item = QueueItem(action: .say(text: text), holdMS: Int(holdMS))
        lastPostedBubble = nil
        if case .failure = enqueue([item], at: .head, now: now) {
            return SpeechBubble(text: text, ttl: ttl, postedAt: now)
        }
        return lastPostedBubble ?? SpeechBubble(text: text, ttl: ttl, postedAt: now)
    }

    /// Dismiss the current bubble. Immediate — bubble control, not content;
    /// does not touch the queue.
    public func dismissSpeech(now: Date = Date()) {
        guard let bubble = speech else { return }
        speech = nil
        broadcast(.speechDismissed(id: bubble.id))
    }

    // MARK: effect execution

    /// Execute queue effects through the private apply paths — queue actions
    /// can never re-enqueue or flush.
    private var lastMachineOutcome: ActorStateMachine.Outcome?
    private var lastPostedBubble: SpeechBubble?

    private func applyQueueEffects(_ effects: [ActionQueue.Effect], now: Date) {
        for effect in effects {
            switch effect {
            case .perform(.say(let text, let ttl)):
                lastPostedBubble = applySay(text, ttl: ttl > 0 ? ttl : nil, now: now)
            case .perform(.setState(let name, let duration)):
                lastMachineOutcome = applyState(name, duration: duration, now: now)
            case .perform(.trigger(let name)):
                lastMachineOutcome = applyTrigger(name, now: now)
            case .emit(.itemStarted(let id, let remaining)):
                broadcast(.queueItemStarted(id: id, remaining: remaining))
            case .emit(.itemFinished(let id)):
                broadcast(.queueItemFinished(id: id))
            case .emit(.drained):
                broadcast(.queueDrained)
            case .emit(.flushed(let dropped)):
                broadcast(.queueFlushed(dropped: dropped))
            }
        }
    }

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

    public var currentDirective: RenderDirective { machine.directive() }

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
        // Queue effects run last so a say-item's fresh bubble is never
        // expired by the same tick.
        applyQueueEffects(queue.tick(now: now), now: now)
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
