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
    /// The current item is parked, waiting on something outside the queue.
    /// `timeoutAt: nil` means indefinitely.
    case queueItemAwaiting(id: String, timeoutAt: Date?)
    /// The last queued item finished naturally.
    case queueDrained
    /// An explicit flush dropped pending items.
    case queueFlushed(dropped: Int)
    /// A question was admitted. Fires when it is *asked*, not when it reaches
    /// the head — a surface showing "2 more waiting" needs to know immediately.
    case questionAsked(QuestionRecord)
    /// A question reached the head and now owns the attention surface.
    case questionPresented(id: String)
    /// Terminal, for every path: answered, declined, cancelled, or expired.
    case questionResolved(QuestionRecord)
}

/// What a successful enqueue admitted.
public struct EnqueueReceipt: Equatable, Sendable {
    public let itemIDs: [String]
    public let queueDepth: Int
}

/// What asking admitted. `id` is the handle an asker polls.
public struct QuestionReceipt: Equatable, Sendable {
    public let id: String
    public let queueDepth: Int
    /// Questions ahead of this one. 0 means it is parked at the head now.
    public let outstandingAhead: Int
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

    /// Outstanding questions by id. A record leaves here the moment it
    /// resolves, so "is anything waiting on the human" is one lookup.
    private var questions: [String: QuestionRecord] = [:]
    /// Recently resolved, newest last. Durable history arrives separately;
    /// this is the in-process read path so polling never touches disk.
    private var recentQuestions: [QuestionRecord] = []
    /// How a resolution the engine initiated should be recorded. The queue
    /// only knows "signalled"; whether that was an answer or a decline is ours.
    private var pendingResolutions: [String: QuestionResolution] = [:]

    public static let maxRecentQuestions = 500

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
        // Outstanding questions replay too: a surface that opens mid-question
        // must render the affordance, not discover it only once it resolves.
        let outstanding = outstandingQuestions()
        let head = outstanding.first { $0.presentedAt != nil }?.id
        return AsyncStream { continuation in
            continuation.yield(.stateChanged(current))
            if let currentSpeech {
                continuation.yield(.speechPosted(currentSpeech))
            }
            for record in outstanding {
                continuation.yield(.questionAsked(record))
            }
            if let head {
                continuation.yield(.questionPresented(id: head))
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
        // Before applying effects: the next item may post a fresh bubble.
        // Matching on the id covers `say` and `ask` alike, and only takes down
        // a bubble this item actually owns. A question's bubble is dismissed by
        // its own resolution, so skip it here and let `skip` cancel it.
        if let bubble = speech, bubble.id == current.id, questions[current.id] == nil {
            speech = nil
            broadcast(.speechDismissed(id: bubble.id))
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
        // The id is known before the item runs, so the receipt is truthful even
        // when a parked question defers this bubble: the caller gets the id the
        // bubble *will* carry, not a throwaway.
        if case .failure = enqueue([item], at: .head, now: now) {
            return SpeechBubble(id: item.id, text: text, ttl: ttl, postedAt: now)
        }
        return lastPostedBubble ?? SpeechBubble(id: item.id, text: text, ttl: ttl, postedAt: now)
    }

    /// Dismiss the current bubble. Immediate — bubble control, not content.
    ///
    /// When the bubble *is* a question, dismissing it resolves the question as
    /// cancelled and lets the queue move on. Anything else would leave the
    /// queue parked on an affordance nobody can see.
    public func dismissSpeech(now: Date = Date()) {
        guard let bubble = speech else { return }
        if questions[bubble.id] != nil {
            _ = resolveQuestion(id: bubble.id, resolution: .cancelled(.dismissed), now: now)
            return
        }
        speech = nil
        broadcast(.speechDismissed(id: bubble.id))
    }

    // MARK: questions

    /// Ask the human something. Tail-enqueued by default, unlike the direct
    /// verbs: head-inserting a second question ahead of the first would
    /// reorder a conversation the human is already partway through.
    @discardableResult
    public func ask(
        _ text: String,
        respond: ResponseSpec,
        at position: ActionQueue.Position = .tail,
        now: Date = Date()
    ) -> Result<QuestionReceipt, ControlFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ControlFailure(error: "missing_text"))
        }
        if let failure = respond.validate() {
            return .failure(failure)
        }
        let ahead = queue.outstandingQuestionIDs.count
        let item = QueueItem(
            action: .ask(text: trimmed, respond: respond),
            completion: .external(timeoutMS: respond.timeoutMS)
        )
        let record = QuestionRecord(
            id: item.id,
            text: String(trimmed.prefix(SpeechBubble.maxLength)),
            respond: respond,
            askedAt: now,
            expiresAt: nil
        )
        questions[item.id] = record
        switch queue.enqueue([item], at: position, now: now) {
        case .failure(let failure):
            questions.removeValue(forKey: item.id)
            return .failure(failure)
        case .success(let effects):
            // Announce before applying effects so an observer sees "asked"
            // before "presented" even when it parks in this same call.
            broadcast(.questionAsked(record))
            applyQueueEffects(effects, now: now)
            return .success(
                QuestionReceipt(id: item.id, queueDepth: queue.depth, outstandingAhead: ahead)
            )
        }
    }

    /// Record the human's answer.
    ///
    /// This is the **only** way a question becomes `accepted`, and it is
    /// deliberately reachable from the UI alone — no REST route or MCP tool
    /// calls it. An agent that could answer its own question would turn a
    /// human-in-the-loop check into a rubber stamp.
    @discardableResult
    public func answerQuestion(
        id: String,
        content: AnswerContent,
        via: AnswerChannel = .typed,
        now: Date = Date()
    ) -> Result<QuestionRecord, ControlFailure> {
        guard let record = questions[id] else {
            return .failure(alreadyResolvedOrUnknown(id))
        }
        if let failure = record.validate(content) {
            return .failure(failure)
        }
        let normalized: AnswerContent
        if case .text(let raw) = content {
            normalized = .text(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            normalized = content
        }
        return resolveQuestion(id: id, resolution: .accepted(normalized, via: via), now: now)
    }

    /// The human explicitly refused to answer — distinct from dismissing it,
    /// and distinct from answering "no" (which is an answer).
    @discardableResult
    public func declineQuestion(
        id: String,
        via: AnswerChannel = .typed,
        now: Date = Date()
    ) -> Result<QuestionRecord, ControlFailure> {
        guard questions[id] != nil else {
            return .failure(alreadyResolvedOrUnknown(id))
        }
        return resolveQuestion(id: id, resolution: .declined(via: via), now: now)
    }

    /// Withdraw a question. Callable by the asker — cancelling is not
    /// answering, so this crosses no boundary.
    @discardableResult
    public func cancelQuestion(
        id: String,
        reason: QuestionCancelReason = .withdrawn,
        now: Date = Date()
    ) -> Result<QuestionRecord, ControlFailure> {
        guard questions[id] != nil else {
            return .failure(alreadyResolvedOrUnknown(id))
        }
        return resolveQuestion(id: id, resolution: .cancelled(reason), now: now)
    }

    /// Withdraw every outstanding question. Returns the ids affected.
    @discardableResult
    public func cancelAllQuestions(
        reason: QuestionCancelReason = .withdrawn,
        now: Date = Date()
    ) -> [String] {
        let ids = outstandingQuestions().map(\.id)
        for id in ids {
            _ = resolveQuestion(id: id, resolution: .cancelled(reason), now: now)
        }
        return ids
    }

    /// Outstanding questions, head first — `first` owns the speech bubble.
    public func outstandingQuestions() -> [QuestionRecord] {
        queue.outstandingQuestionIDs.compactMap { questions[$0] }
    }

    /// One question by id, outstanding or recently resolved.
    public func question(id: String) -> QuestionRecord? {
        questions[id] ?? recentQuestions.last { $0.id == id }
    }

    /// Resolved questions, newest first.
    public func questionHistory(limit: Int = 50) -> [QuestionRecord] {
        Array(recentQuestions.reversed().prefix(max(0, limit)))
    }

    /// Drop stored history. `keep: nil` clears everything. Returns how many
    /// records were removed.
    @discardableResult
    public func clearQuestionHistory(keep: Int? = nil) -> Int {
        let before = recentQuestions.count
        if let keep, keep > 0 {
            recentQuestions = Array(recentQuestions.suffix(keep))
        } else {
            recentQuestions.removeAll()
        }
        return before - recentQuestions.count
    }

    private func resolveQuestion(
        id: String,
        resolution: QuestionResolution,
        now: Date
    ) -> Result<QuestionRecord, ControlFailure> {
        pendingResolutions[id] = resolution
        switch queue.resolveExternal(id: id, reason: .signalled, now: now) {
        case .failure(let failure):
            pendingResolutions.removeValue(forKey: id)
            return .failure(failure)
        case .success(let effects):
            applyQueueEffects(effects, now: now)
            // finalizeQuestion moved it into history during effect application.
            guard let resolved = recentQuestions.last(where: { $0.id == id }) else {
                return .failure(ControlFailure(error: "unknown_question"))
            }
            return .success(resolved)
        }
    }

    private func alreadyResolvedOrUnknown(_ id: String) -> ControlFailure {
        recentQuestions.contains { $0.id == id }
            ? ControlFailure(error: "already_resolved")
            : ControlFailure(error: "unknown_question")
    }

    // MARK: effect execution

    /// Execute queue effects through the private apply paths — queue actions
    /// can never re-enqueue or flush.
    private var lastMachineOutcome: ActorStateMachine.Outcome?
    private var lastPostedBubble: SpeechBubble?

    private func applyQueueEffects(_ effects: [ActionQueue.Effect], now: Date) {
        for effect in effects {
            switch effect {
            case .perform(.say(let id, let text, let ttl, _)):
                lastPostedBubble = applySay(id: id, text, ttl: ttl > 0 ? ttl : nil, now: now)
            case .perform(.setState(let name, let duration)):
                lastMachineOutcome = applyState(name, duration: duration, now: now)
            case .perform(.trigger(let name)):
                lastMachineOutcome = applyTrigger(name, now: now)
            case .emit(.itemStarted(let id, let remaining)):
                broadcast(.queueItemStarted(id: id, remaining: remaining))
            case .emit(.itemFinished(let id)):
                broadcast(.queueItemFinished(id: id))
            case .emit(.itemAwaiting(let id, let timeoutAt)):
                if var record = questions[id] {
                    record.presentedAt = now
                    record.expiresAt = timeoutAt
                    questions[id] = record
                    broadcast(.questionPresented(id: id))
                }
                broadcast(.queueItemAwaiting(id: id, timeoutAt: timeoutAt))
            case .emit(.itemResolved(let id, let reason)):
                finalizeQuestion(id: id, reason: reason, now: now)
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
    private func applySay(id: String, _ text: String, ttl: TimeInterval?, now: Date) -> SpeechBubble {
        // The bubble id *is* the queue item id, so a question's affordance and
        // its queue entry are the same thing to every observer.
        let bubble = SpeechBubble(id: id, text: text, ttl: ttl, postedAt: now)
        speech = bubble
        broadcast(.speechPosted(bubble))
        return bubble
    }

    /// Move a question out of `questions`, stamp its outcome, and announce it.
    /// Every terminal path funnels through here — answered, declined,
    /// withdrawn, skipped, flushed, expired — so a record can never be left
    /// half-resolved.
    private func finalizeQuestion(id: String, reason: ActionQueue.ResolutionReason, now: Date) {
        guard let record = questions.removeValue(forKey: id) else {
            // A non-question external item (spoken output) — nothing to record.
            pendingResolutions.removeValue(forKey: id)
            return
        }
        let resolution: QuestionResolution
        if let stashed = pendingResolutions.removeValue(forKey: id) {
            resolution = stashed
        } else {
            switch reason {
            case .timedOut:
                resolution = .expired
            case .cancelled(let why):
                resolution = .cancelled(why)
            case .signalled:
                // Signalled with nothing stashed means the queue completed it
                // without the engine deciding how — treat as a withdrawal
                // rather than inventing an answer.
                resolution = .cancelled(.withdrawn)
            }
        }
        let resolved = record.resolved(resolution, at: now)
        recordResolved(resolved)
        // Take the bubble down with the question: leaving an unanswerable
        // affordance on screen is worse than an empty stage.
        if let bubble = speech, bubble.id == id {
            speech = nil
            broadcast(.speechDismissed(id: bubble.id))
        }
        broadcast(.questionResolved(resolved))
    }

    private func recordResolved(_ record: QuestionRecord) {
        recentQuestions.append(record)
        if recentQuestions.count > Self.maxRecentQuestions {
            recentQuestions.removeFirst(recentQuestions.count - Self.maxRecentQuestions)
        }
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
