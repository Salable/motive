import Foundation

/// One unit of queued work. Codable with the same `type` discriminator as
/// `ScriptStep` (say / setState / trigger / pause) plus a server-assigned id
/// echoed back to callers for introspection and eventing.
public struct QueueItem: Equatable, Sendable, Identifiable {
    public enum Action: Equatable, Sendable {
        case say(text: String)
        case setState(name: String, durationMS: Int?)
        case trigger(name: String)
        case pause
    }

    public let id: String
    public let action: Action
    /// Milliseconds this item occupies the queue before the next item runs.
    /// `nil` → per-action default: say 4000 (== bubble TTL), setState 0,
    /// trigger the gesture's loop duration, pause requires an explicit value.
    public let holdMS: Int?

    public init(action: Action, holdMS: Int? = nil) {
        self.id = UUID().uuidString
        self.action = action
        self.holdMS = holdMS
    }

    /// Bridge from the wire DTO (`/v1/script`, `/v1/queue`, MCP steps).
    public init(step: ScriptStep) {
        switch step {
        case .say(let text, let holdMS):
            self.init(action: .say(text: text), holdMS: holdMS)
        case .setState(let name, let holdMS):
            self.init(action: .setState(name: name, durationMS: nil), holdMS: holdMS)
        case .trigger(let name):
            self.init(action: .trigger(name: name))
        case .pause(let ms):
            self.init(action: .pause, holdMS: ms)
        }
    }

    /// The wire representation (used by snapshots and round-trips).
    public var step: ScriptStep {
        switch action {
        case .say(let text):
            return .say(text: text, holdMS: holdMS ?? ScriptStep.defaultSayHoldMS)
        case .setState(let name, _):
            return .setState(name: name, holdMS: holdMS)
        case .trigger(let name):
            return .trigger(name: name)
        case .pause:
            return .pause(ms: holdMS ?? 0)
        }
    }

    public func validate(against definition: BehaviorDefinition) -> ControlFailure? {
        switch action {
        case .say:
            return nil
        case .setState(let name, _):
            return definition.state(named: name) == nil
                ? ControlFailure(error: "unknown_state", valid: definition.validStateNames)
                : nil
        case .trigger(let name):
            return definition.triggers[name] == nil
                ? ControlFailure(error: "unknown_trigger", valid: definition.triggers.keys.sorted())
                : nil
        case .pause:
            return (holdMS ?? 0) <= 0
                ? ControlFailure(error: "invalid_items", valid: nil)
                : nil
        }
    }
}

/// A point-in-time view of the queue for `GET /v1/queue`.
public struct QueueSnapshot: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let step: ScriptStep

        public init(id: String, step: ScriptStep) {
            self.id = id
            self.step = step
        }
    }

    public let current: Entry?
    /// Seconds until the current item's hold elapses (nil when idle or the
    /// current item advances on the next tick).
    public let currentRemaining: TimeInterval?
    public let pending: [Entry]

    public var depth: Int { (current == nil ? 0 : 1) + pending.count }

    public init(current: Entry?, currentRemaining: TimeInterval?, pending: [Entry]) {
        self.current = current
        self.currentRemaining = currentRemaining
        self.pending = pending
    }
}

/// Pure, timer-free serial action queue — the single sequencing mechanism.
/// Everything the sprite does is a queue item: direct commands head-enqueue
/// ("plays next"), flows tail-enqueue, and every admitted item is chewed
/// through in order — nothing is dropped except by an explicit `flush`.
/// The owner (`MotiveEngine`) supplies clocks and executes returned effects.
public struct ActionQueue: Sendable {
    /// Pending + current.
    public static let maxDepth = 64
    /// Per-item holds clamp to the same cap as state durations.
    public static let maxHold: TimeInterval = ActorStateMachine.maxDuration

    public enum Position: Sendable {
        /// Next to run: cuts the current item's remaining hold (its effect
        /// already fired; we just stop waiting) so interjections are
        /// immediate. Queued items continue afterwards.
        case head
        case tail
    }

    public enum ActionEffect: Equatable, Sendable {
        case say(text: String, ttl: TimeInterval)
        case setState(name: String, duration: TimeInterval?)
        case trigger(name: String)
    }

    public enum Signal: Equatable, Sendable {
        case itemStarted(id: String, remaining: Int)
        case itemFinished(id: String)
        /// The last item finished naturally.
        case drained
        /// An explicit flush dropped pending work.
        case flushed(dropped: Int)
    }

    public enum Effect: Equatable, Sendable {
        case perform(ActionEffect)
        case emit(Signal)
    }

    private let definition: BehaviorDefinition
    private var pending: [QueueItem] = []
    private var current: (item: QueueItem, deadline: Date?)?

    public init(definition: BehaviorDefinition) {
        self.definition = definition
    }

    public var isActive: Bool { current != nil }
    public var depth: Int { (current == nil ? 0 : 1) + pending.count }

    // MARK: enqueue / flush

    /// All-or-nothing: every item validates and the batch fits the depth cap,
    /// or nothing is admitted. Execution starts (or resumes at the head)
    /// within this call.
    public mutating func enqueue(
        _ items: [QueueItem],
        at position: Position = .tail,
        now: Date
    ) -> Result<[Effect], ControlFailure> {
        guard !items.isEmpty else {
            return .failure(ControlFailure(error: "empty_queue_request"))
        }
        guard depth + items.count <= Self.maxDepth else {
            return .failure(ControlFailure(error: "queue_full", valid: nil))
        }
        for item in items {
            if let failure = item.validate(against: definition) {
                return .failure(failure)
            }
        }

        switch position {
        case .tail:
            pending.append(contentsOf: items)
        case .head:
            pending.insert(contentsOf: items, at: 0)
            // Cut the current hold: the interjection plays immediately, the
            // rest of the queue flows on afterwards.
            if var running = current {
                running.deadline = now
                current = running
            }
        }
        return .success(advanceIfDue(now: now))
    }

    /// Wipe pending work and stop waiting on the current item. On-screen
    /// state/bubbles are not rewound — flushing is about future work.
    public mutating func flush(now: Date) -> [Effect] {
        let droppedPending = pending.count
        let hadCurrent = current != nil
        pending.removeAll()
        var effects: [Effect] = []
        if let running = current {
            current = nil
            effects.append(.emit(.itemFinished(id: running.item.id)))
        }
        if droppedPending > 0 || hadCurrent {
            effects.append(.emit(.flushed(dropped: droppedPending)))
        }
        return effects
    }

    // MARK: clock

    public mutating func tick(now: Date) -> [Effect] {
        advanceIfDue(now: now)
    }

    public func snapshot(now: Date) -> QueueSnapshot {
        let remaining: TimeInterval? = current?.deadline.map { max(0, $0.timeIntervalSince(now)) }
        return QueueSnapshot(
            current: current.map { QueueSnapshot.Entry(id: $0.item.id, step: $0.item.step) },
            currentRemaining: remaining,
            pending: pending.map { QueueSnapshot.Entry(id: $0.id, step: $0.step) }
        )
    }

    // MARK: internals

    /// Finish due items and start the next ones; zero-hold items chain in one
    /// call. Bounded: each iteration consumes one admitted item.
    private mutating func advanceIfDue(now: Date) -> [Effect] {
        var effects: [Effect] = []
        while true {
            if let running = current {
                guard let deadline = running.deadline, now >= deadline else { break }
                current = nil
                effects.append(.emit(.itemFinished(id: running.item.id)))
                if pending.isEmpty {
                    effects.append(.emit(.drained))
                    break
                }
            }
            guard current == nil else { break }
            guard !pending.isEmpty else { break }

            let item = pending.removeFirst()
            effects.append(.emit(.itemStarted(id: item.id, remaining: pending.count)))

            let hold: TimeInterval
            switch item.action {
            case .say(let text):
                let clamped = clampedHold(item.holdMS ?? ScriptStep.defaultSayHoldMS)
                effects.append(.perform(.say(text: text, ttl: clamped)))
                hold = clamped
            case .setState(let name, let durationMS):
                let duration = durationMS.map { max(0, TimeInterval($0) / 1_000) }
                effects.append(.perform(.setState(name: name, duration: duration)))
                hold = clampedHold(item.holdMS ?? 0)
            case .trigger(let name):
                effects.append(.perform(.trigger(name: name)))
                // Default: occupy the queue for one loop of the gesture, so
                // flows don't need hand-tuned pauses after wave/jump.
                if let holdMS = item.holdMS {
                    hold = clampedHold(holdMS)
                } else {
                    let target = definition.triggers[name].flatMap { definition.state(named: $0.state) }
                    hold = min(Self.maxHold, target?.loopDuration ?? 0)
                }
            case .pause:
                hold = clampedHold(item.holdMS ?? 0)
            }

            if hold > 0 {
                current = (item, now.addingTimeInterval(hold))
                break
            }
            // Zero-hold: finish immediately and keep chaining.
            effects.append(.emit(.itemFinished(id: item.id)))
            if pending.isEmpty {
                effects.append(.emit(.drained))
                break
            }
        }
        return effects
    }

    private func clampedHold(_ ms: Int) -> TimeInterval {
        min(Self.maxHold, max(0, TimeInterval(ms) / 1_000))
    }
}
