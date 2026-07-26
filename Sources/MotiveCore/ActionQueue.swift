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
        /// A `say` that blocks the queue until a human resolves it.
        case ask(text: String, respond: ResponseSpec)
    }

    /// How this item stops occupying the queue. Everything shipped before
    /// questions is `.hold`, and it remains the default — the queue's whole
    /// timer-free design rests on durations being known in advance, and
    /// `.external` is the deliberate, narrow exception.
    public enum Completion: Equatable, Sendable {
        /// Milliseconds this item occupies the queue before the next item runs.
        /// `nil` → per-action default: say 4000 (== bubble TTL), setState 0,
        /// trigger the gesture's loop duration, pause requires an explicit value.
        case hold(ms: Int?)
        /// Completes when something outside the queue says so — a human
        /// answering, a synthesizer finishing. `nil` timeout parks indefinitely.
        case external(timeoutMS: Int?)
    }

    public let id: String
    public let action: Action
    /// Mutable so the engine can promote a `say` to external completion when
    /// spoken output is installed, without minting a new id the caller has
    /// already been given.
    public var completion: Completion

    /// Preserved as a computed accessor so every call site written against the
    /// pre-questions queue keeps working. An external item has no hold.
    public var holdMS: Int? {
        if case .hold(let ms) = completion { return ms }
        return nil
    }

    public var respond: ResponseSpec? {
        if case .ask(_, let spec) = action { return spec }
        return nil
    }

    public var isQuestion: Bool { respond != nil }

    public var isExternal: Bool {
        if case .external = completion { return true }
        return false
    }

    public init(action: Action, holdMS: Int? = nil) {
        self.init(action: action, completion: .hold(ms: holdMS))
    }

    public init(action: Action, completion: Completion) {
        self.id = UUID().uuidString
        self.action = action
        self.completion = completion
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
        case .ask(let text, let respond):
            self.init(
                action: .ask(text: text, respond: respond),
                completion: .external(timeoutMS: respond.timeoutMS)
            )
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
        case .ask(let text, let respond):
            return .ask(text: text, respond: respond)
        }
    }

    public func validate(against definition: BehaviorDefinition) -> ControlFailure? {
        switch action {
        case .say:
            return nil
        case .ask(let text, let respond):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ControlFailure(error: "missing_text")
            }
            return respond.validate()
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
    /// Why an item is occupying the queue without a countdown. Nil for the
    /// ordinary fixed-duration hold every pre-questions item uses.
    public enum Awaiting: Equatable, Sendable {
        case question(ResponseSpec)
        /// Reserved for spoken output: the utterance is playing.
        case speaking
    }

    public struct Entry: Equatable, Sendable {
        public let id: String
        public let step: ScriptStep
        public let awaiting: Awaiting?

        public init(id: String, step: ScriptStep, awaiting: Awaiting? = nil) {
            self.id = id
            self.step = step
            self.awaiting = awaiting
        }
    }

    public let current: Entry?
    /// Seconds until the current item's hold elapses (nil when idle, when the
    /// current item advances on the next tick, or when it is parked waiting on
    /// something outside the queue).
    public let currentRemaining: TimeInterval?
    /// Seconds the current item has been running.
    public let currentElapsed: TimeInterval?
    public let pending: [Entry]
    /// True while playback is paused: nothing finishes and nothing starts.
    public let isPaused: Bool

    public var depth: Int { (current == nil ? 0 : 1) + pending.count }

    public init(
        current: Entry?,
        currentRemaining: TimeInterval?,
        pending: [Entry],
        currentElapsed: TimeInterval? = nil,
        isPaused: Bool = false
    ) {
        self.current = current
        self.currentRemaining = currentRemaining
        self.currentElapsed = currentElapsed
        self.pending = pending
        self.isPaused = isPaused
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
    /// External items get their own, much longer ceiling: a spoken paragraph
    /// or a human deciding both outrun a state duration by design.
    public static let maxExternalTimeout: TimeInterval = 3_600
    /// Outstanding questions cap independently of depth — 64 unanswerable
    /// parks would wedge the pet with no way back short of a flush.
    public static let maxOutstandingQuestions = 8

    public enum Position: Sendable {
        /// Next to run: cuts the current item's remaining hold (its effect
        /// already fired; we just stop waiting) so interjections are
        /// immediate. Queued items continue afterwards.
        case head
        case tail
    }

    public enum ActionEffect: Equatable, Sendable {
        /// Carries the item id so the bubble and the queue entry are the same
        /// thing to every observer — a question's affordance is answered by id.
        case say(id: String, text: String, ttl: TimeInterval, respond: ResponseSpec?)
        case setState(name: String, duration: TimeInterval?)
        case trigger(name: String)
    }

    /// Why an external item stopped waiting.
    public enum ResolutionReason: Equatable, Sendable {
        /// Answered, or an output engine reported completion.
        case signalled
        case timedOut
        /// Ended without a result. Carries which mechanism did it, so a record
        /// can say "you skipped past it" rather than a shrug.
        case cancelled(QuestionCancelReason)
    }

    public enum Signal: Equatable, Sendable {
        case itemStarted(id: String, remaining: Int)
        case itemFinished(id: String)
        /// An external item became current and is now parked. `timeoutAt: nil`
        /// means indefinitely.
        case itemAwaiting(id: String, timeoutAt: Date?)
        /// An external item stopped waiting. Always immediately precedes
        /// `itemFinished`, including for a pending item resolved out of order.
        case itemResolved(id: String, reason: ResolutionReason)
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
    /// When playback was paused. The queue stays timer-free: pausing records a
    /// moment, and resuming pushes the deadline out by however long it lasted.
    private var pausedAt: Date?
    /// Earliest the next item may start — the inter-item gap.
    private var gapUntil: Date?
    /// When the current item started, for elapsed reporting.
    private var startedAt: Date?
    /// Milliseconds of quiet between items. 0 (the default) is the behaviour
    /// everything shipped with.
    public var gapMS: Int = 0

    public init(definition: BehaviorDefinition) {
        self.definition = definition
    }

    public var isActive: Bool { current != nil }
    public var isPaused: Bool { pausedAt != nil }
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
        let incomingQuestions = items.filter(\.isQuestion).count
        guard outstandingQuestionIDs.count + incomingQuestions <= Self.maxOutstandingQuestions else {
            return .failure(ControlFailure(error: "too_many_questions", valid: nil))
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
            //
            // Only a *hold* can be cut short. An external item completes when
            // its signal arrives, so an interjection queues behind it rather
            // than voiding a commitment the pet already made — otherwise an
            // ordinary `say` would silently cancel a question the human is
            // looking at.
            if var running = current, case .hold = running.item.completion {
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
        var effects: [Effect] = []
        // Resolve every external item first — a dropped question that never
        // reported an outcome leaves observers showing an affordance that can
        // never be answered.
        for item in pending where item.isExternal {
            effects.append(.emit(.itemResolved(id: item.id, reason: .cancelled(.flushed))))
        }
        pending.removeAll()
        if let running = current {
            current = nil
            if running.item.isExternal {
                effects.append(.emit(.itemResolved(id: running.item.id, reason: .cancelled(.flushed))))
            }
            effects.append(.emit(.itemFinished(id: running.item.id)))
        }
        if droppedPending > 0 || hadCurrent {
            effects.append(.emit(.flushed(dropped: droppedPending)))
        }
        return effects
    }

    /// End the current item now and let the queue advance — the single-item
    /// counterpart of `flush`: pending items are preserved and the next one
    /// starts immediately (or the queue drains). Quiet no-op when idle.
    public mutating func skip(now: Date) -> [Effect] {
        guard var running = current else { return [] }
        if running.item.isExternal {
            // Don't fake a due deadline: for an external item the deadline
            // slot *is* the timeout, and reusing it would report `timedOut`
            // for what was really a cancellation.
            let id = running.item.id
            current = nil
            return [
                .emit(.itemResolved(id: id, reason: .cancelled(.skipped))),
                .emit(.itemFinished(id: id)),
            ] + advanceIfDue(now: now)
        }
        running.deadline = now
        current = running
        return advanceIfDue(now: now)
    }

    // MARK: external completion

    /// Complete an item that was waiting on the outside world. Searches the
    /// current item first, then pending — a pending question answered out of
    /// order is removed **in place**, leaving the head parked and never
    /// running the removed item.
    public mutating func resolveExternal(
        id: String,
        reason: ResolutionReason,
        now: Date
    ) -> Result<[Effect], ControlFailure> {
        if let running = current, running.item.id == id {
            guard running.item.isExternal else {
                return .failure(ControlFailure(error: "not_awaiting", valid: nil))
            }
            current = nil
            return .success(
                [
                    .emit(.itemResolved(id: id, reason: reason)),
                    .emit(.itemFinished(id: id)),
                ] + advanceIfDue(now: now)
            )
        }
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            return .failure(ControlFailure(error: "unknown_item", valid: nil))
        }
        guard pending[index].isExternal else {
            return .failure(ControlFailure(error: "not_awaiting", valid: nil))
        }
        pending.remove(at: index)
        // No advance: the head keeps its park. This item never started, so it
        // never emits `itemStarted`.
        return .success([
            .emit(.itemResolved(id: id, reason: reason)),
            .emit(.itemFinished(id: id)),
        ])
    }

    /// Ids of every outstanding question, head first.
    public var outstandingQuestionIDs: [String] {
        var ids: [String] = []
        if let running = current, running.item.isQuestion {
            ids.append(running.item.id)
        }
        ids.append(contentsOf: pending.filter(\.isQuestion).map(\.id))
        return ids
    }

    public func item(id: String) -> QueueItem? {
        if let running = current, running.item.id == id { return running.item }
        return pending.first { $0.id == id }
    }

    // MARK: pause / resume

    /// Freeze the current item. A parked item (a question, a line being spoken)
    /// has no clock to freeze — pausing marks the queue paused so nothing new
    /// starts behind it, and the owner pauses the audio itself.
    @discardableResult
    public mutating func pause(now: Date) -> Bool {
        guard pausedAt == nil, current != nil else { return false }
        pausedAt = now
        return true
    }

    /// Resume, pushing the current deadline out by the paused duration so a
    /// half-played item keeps the half it had left.
    @discardableResult
    public mutating func resume(now: Date) -> [Effect] {
        guard let pausedAt else { return [] }
        let elapsed = max(0, now.timeIntervalSince(pausedAt))
        self.pausedAt = nil
        if var running = current, let deadline = running.deadline {
            running.deadline = deadline.addingTimeInterval(elapsed)
            current = running
        }
        // Push the start forward too, or elapsed jumps the moment we resume:
        // paused time is not time the item spent running.
        if let started = startedAt {
            startedAt = started.addingTimeInterval(elapsed)
        }
        if let gap = gapUntil {
            gapUntil = gap.addingTimeInterval(elapsed)
        }
        return advanceIfDue(now: now)
    }

    // MARK: clock

    public mutating func tick(now: Date) -> [Effect] {
        advanceIfDue(now: now)
    }

    public func snapshot(now: Date) -> QueueSnapshot {
        // A parked item has no countdown even when it carries a timeout: the
        // UI renders "waiting on you", not a clock.
        let isParked = current.map { $0.item.isExternal } ?? false
        let remaining: TimeInterval? = isParked
            ? nil
            : current?.deadline.map { max(0, $0.timeIntervalSince(now)) }
        let elapsed = startedAt.map { max(0, (pausedAt ?? now).timeIntervalSince($0)) }
        return QueueSnapshot(
            current: current.map {
                QueueSnapshot.Entry(
                    id: $0.item.id,
                    step: $0.item.step,
                    awaiting: Self.awaiting(for: $0.item)
                )
            },
            currentRemaining: remaining,
            pending: pending.map {
                QueueSnapshot.Entry(id: $0.id, step: $0.step, awaiting: Self.awaiting(for: $0))
            },
            currentElapsed: elapsed,
            isPaused: pausedAt != nil
        )
    }

    private static func awaiting(for item: QueueItem) -> QueueSnapshot.Awaiting? {
        if let respond = item.respond { return .question(respond) }
        if item.isExternal { return .speaking }
        return nil
    }

    // MARK: internals

    /// Finish due items and start the next ones; zero-hold items chain in one
    /// call. Bounded: each iteration consumes one admitted item.
    private mutating func advanceIfDue(now: Date) -> [Effect] {
        // Paused: nothing finishes and nothing starts. The deadline is shifted
        // on resume rather than recomputed here, so time truly stands still.
        guard pausedAt == nil else { return [] }
        var effects: [Effect] = []
        while true {
            if let running = current {
                guard let deadline = running.deadline, now >= deadline else { break }
                current = nil
                // An external item reaching its deadline timed out; a hold
                // simply elapsed.
                if running.item.isExternal {
                    effects.append(.emit(.itemResolved(id: running.item.id, reason: .timedOut)))
                }
                effects.append(.emit(.itemFinished(id: running.item.id)))
                if pending.isEmpty {
                    effects.append(.emit(.drained))
                    break
                }
            }
            guard current == nil else { break }
            guard !pending.isEmpty else { break }
            // Inter-item gap: a beat of quiet before the next item starts.
            if let gapUntil {
                guard now >= gapUntil else { break }
                self.gapUntil = nil
            } else if gapMS > 0, !effects.isEmpty {
                gapUntil = now.addingTimeInterval(min(Self.maxHold, TimeInterval(gapMS) / 1_000))
                break
            }

            let item = pending.removeFirst()
            effects.append(.emit(.itemStarted(id: item.id, remaining: pending.count)))

            // External items never enter the hold ladder below: falling through
            // would let the zero-hold chaining path consume a parked item in
            // the very call that started it.
            if case .external(let timeoutMS) = item.completion {
                let timeoutAt = timeoutMS.map {
                    now.addingTimeInterval(clampedTimeout($0))
                }
                switch item.action {
                case .ask(let text, let respond):
                    // ttl 0 → the engine posts a bubble with no expiry, so the
                    // question survives until it is resolved.
                    effects.append(
                        .perform(.say(id: item.id, text: text, ttl: 0, respond: respond))
                    )
                case .say(let text):
                    effects.append(
                        .perform(.say(id: item.id, text: text, ttl: 0, respond: nil))
                    )
                case .setState(let name, let durationMS):
                    let duration = durationMS.map { max(0, TimeInterval($0) / 1_000) }
                    effects.append(.perform(.setState(name: name, duration: duration)))
                case .trigger(let name):
                    effects.append(.perform(.trigger(name: name)))
                case .pause:
                    break
                }
                effects.append(.emit(.itemAwaiting(id: item.id, timeoutAt: timeoutAt)))
                current = (item, timeoutAt)
                startedAt = now
                break
            }

            let hold: TimeInterval
            switch item.action {
            case .say(let text):
                let clamped = clampedHold(item.holdMS ?? ScriptStep.defaultSayHoldMS)
                effects.append(.perform(.say(id: item.id, text: text, ttl: clamped, respond: nil)))
                hold = clamped
            case .ask(let text, let respond):
                // Unreachable in practice — `.ask` is always `.external`. Kept
                // total rather than fatal so a hand-built item degrades to an
                // ordinary bubble instead of trapping.
                let clamped = clampedHold(item.holdMS ?? ScriptStep.defaultSayHoldMS)
                effects.append(
                    .perform(.say(id: item.id, text: text, ttl: clamped, respond: respond))
                )
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
                startedAt = now
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

    private func clampedTimeout(_ ms: Int) -> TimeInterval {
        min(Self.maxExternalTimeout, max(0, TimeInterval(ms) / 1_000))
    }
}
