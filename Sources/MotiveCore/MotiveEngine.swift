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
public actor MotiveEngine: SpeechOutputSink {
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
    /// Durable record of what happened. Nil by default so no existing test
    /// touches disk and a headless embedder opts in rather than out.
    private let activity: ActivityStore?
    /// Serial chain of pending appends — see `record`.
    private var historyWrite: Task<Void, Never>?
    /// In-process activity ring: the read path for polling, so an agent asking
    /// "what changed" never waits on disk.
    private var recentActivity: [ActivityRecord] = []
    private var nextSequence: UInt64 = 1

    /// Where spoken output goes, when a host installs one. Nil means
    /// bubble-only, which is every pre-voice pet and every headless one.
    private var speechOutput: SpeechOutput?
    /// Utterances we have asked for and not yet heard back about, and whether
    /// each was ever observed to start.
    private var speaking: [String: Bool] = [:]
    /// Serial chain of pending utterance dispatches — see `startSpeaking`.
    private var speechRequest: Task<Void, Never>?
    /// Voice preferences a sprite declared; user settings override these.
    public var voicePreferences: VoicePreferences?

    public static let maxRecentQuestions = 500
    public static let maxRecentActivity = 2_000

    public init(
        definition: BehaviorDefinition,
        initialState: String = "idle",
        tickInterval: TimeInterval = 0.1,
        activity: ActivityStore? = nil
    ) {
        let machine = ActorStateMachine(definition: definition, initialState: initialState)
        self.machine = machine
        self.defaultState = machine.defaultStateName
        self.queue = ActionQueue(definition: definition)
        self.tickInterval = tickInterval
        self.activity = activity
    }

    /// Read durable history back into the in-memory window. Call once next to
    /// `start()`; without it a restarted pet answers history reads from an
    /// empty ring even though the file is intact.
    public func restoreHistory() async {
        guard let activity else { return }
        await drainHistoryWrites()
        let stored = await activity.recent(limit: Self.maxRecentActivity)
        // `recent` is newest-first; the ring is oldest-first.
        recentActivity = stored.reversed()
        // Continue the numbering: an agent holding a cursor from a previous run
        // must not have it invalidated by a restart.
        //
        // Never *lower* it. Restoring races whatever the pet is already doing
        // — an onboarding line can be recorded before this returns — and
        // rewinding would hand out a sequence number twice, which silently
        // breaks every cursor that skips the duplicate.
        nextSequence = max(nextSequence, (await activity.lastSequence()) + 1)
        recentQuestions = recentActivity.compactMap {
            $0.kind == .questionResolved ? $0.question : nil
        }
    }

    /// Install spoken output. A `say` will then occupy the queue for exactly as
    /// long as its audio, so the sprite's talking state and the sound stop
    /// together instead of drifting apart.
    public func setSpeechOutput(_ output: SpeechOutput?) {
        speechOutput = output
    }

    public func setVoicePreferences(_ preferences: VoicePreferences?) {
        voicePreferences = preferences
    }

    public var isSpeechOutputInstalled: Bool { speechOutput != nil }

    /// Why the last utterance did not play, when one didn't. Read by voice
    /// diagnostics so a broken audio route is visible rather than merely quiet.
    public private(set) var lastSpeechFailure: String?

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
        let items = items.map(withSpokenCompletion)
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
        if dropped > 0 || !effects.isEmpty {
            record(.queueCleared, actor: .human, summary: "Cleared the queue",
                   detail: ["dropped": String(dropped)], now: now)
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
        record(.skipped, actor: .human, summary: "Skipped the current step",
               detail: ["itemID": current.id], now: now)
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
        record(.stateRequested, actor: .agent, summary: "State → \(name)",
               detail: ["state": name], now: now)
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
        record(.triggerFired, actor: .agent, summary: "Trigger \(name)",
               detail: ["trigger": name], now: now)
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
        record(.said, actor: .agent, summary: text, detail: ["itemID": item.id], now: now)
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
            self.record(.asked, actor: .agent, summary: trimmed, question: record, now: now)
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

    // MARK: SpeechOutputSink

    public func speechDidStart(id: String, at date: Date) {
        guard speaking[id] != nil else { return }
        speaking[id] = true
    }

    public func speechDidFinish(id: String, outcome: SpeechOutcome, at date: Date) {
        guard let observedStart = speaking.removeValue(forKey: id) else { return }
        // Reading a question aloud finishing means exactly that: the pet has
        // finished saying it. The question is still waiting on a human, and
        // completing its queue item here would cancel it the instant it was
        // spoken — the two features would silently destroy each other.
        if questions[id] != nil { return }
        // Finishing without ever having started means the audio never played —
        // a broken route, not a spoken line. Reporting it as success would let
        // a silent queue masquerade as a spoken one.
        // Whatever happened, the queue must move on — a wedged synthesizer
        // must not park the pet forever. The distinction between a spoken line
        // and a silently-dropped one is surfaced by MotiveVoice's diagnostics,
        // which is where a user can act on it.
        let reason: ActionQueue.ResolutionReason
        switch outcome {
        case .cancelled:
            reason = .cancelled(.skipped)
        case .finished where !observedStart:
            lastSpeechFailure = "audio never started for \(id)"
            reason = .signalled
        case .failed(let why):
            lastSpeechFailure = why
            reason = .signalled
        case .finished:
            reason = .signalled
        }
        if case .success(let effects) = queue.resolveExternal(id: id, reason: reason, now: date) {
            applyQueueEffects(effects, now: date)
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
                startSpeaking(id: id, text: text)
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
        recordResolved(resolved, now: now)
        // Take the bubble down with the question: leaving an unanswerable
        // affordance on screen is worse than an empty stage.
        if let bubble = speech, bubble.id == id {
            speech = nil
            broadcast(.speechDismissed(id: bubble.id))
        }
        broadcast(.questionResolved(resolved))
    }

    // MARK: spoken output

    private func startSpeaking(id: String, text: String) {
        guard let speechOutput else { return }
        speaking[id] = false
        let utterance = SpeechUtterance(
            id: id,
            text: text,
            voiceID: voicePreferences?.voiceID,
            rate: voicePreferences?.rate
        )
        // Chained rather than detached: two lines queued back to back must
        // reach the synthesizer in the order they were said, and the engine
        // must not block on it.
        let previous = speechRequest
        speechRequest = Task {
            await previous?.value
            await speechOutput.speak(utterance)
        }
    }

    /// Wait for queued utterance dispatches to reach the output. Tests and
    /// shutdown need this; nothing in normal operation does.
    public func drainSpeechRequests() async {
        await speechRequest?.value
    }

    /// A `say` becomes an external item when audio is installed: its duration
    /// is the audio's, which nobody knows in advance, so the talking state and
    /// the sound end together instead of drifting apart.
    private func withSpokenCompletion(_ item: QueueItem) -> QueueItem {
        guard speechOutput != nil, case .say = item.action, case .hold = item.completion else {
            return item
        }
        var copy = item
        copy.completion = .external(timeoutMS: Self.spokenTimeoutMS(for: item))
        return copy
    }

    /// A generous ceiling derived from length: the delegate is the real
    /// detector, this only stops a wedged engine parking the queue forever.
    static func spokenTimeoutMS(for item: QueueItem) -> Int {
        guard case .say(let text) = item.action else { return 60_000 }
        let seconds = Double(text.count) / 8.0 + 15.0
        return Int(min(seconds, ActionQueue.maxExternalTimeout) * 1_000)
    }

    private func recordResolved(_ record: QuestionRecord, now: Date) {
        recentQuestions.append(record)
        if recentQuestions.count > Self.maxRecentQuestions {
            recentQuestions.removeFirst(recentQuestions.count - Self.maxRecentQuestions)
        }
        self.record(
            .questionResolved,
            // An answer or a decline is the human's; a timeout is nobody's.
            actor: record.via != nil ? .human : (record.status == .expired ? .system : .agent),
            summary: Self.summary(for: record),
            question: record,
            now: now
        )
    }

    private static func summary(for record: QuestionRecord) -> String {
        switch record.status {
        case .accepted:
            switch record.answer {
            case .confirm(let yes): return yes ? "Answered yes" : "Answered no"
            case .choice(let value, _): return "Chose \(value)"
            case .text(let value): return "Replied “\(value)”"
            case nil: return "Answered"
            }
        case .declined: return "Declined to answer"
        case .cancelled: return "Question \(record.cancelReason?.rawValue ?? "cancelled")"
        case .expired: return "Question timed out"
        case .awaiting: return "Waiting"
        }
    }

    /// Observers must not wait on disk, but writes still have to *land* in
    /// order relative to each other and to a later cull — a detached task per
    /// append would let a clear overtake an in-flight write and resurrect the
    /// record it was meant to delete. Chaining keeps the engine unblocked and
    /// the file ordered.
    /// Record something a human or an agent did.
    ///
    /// Decisions only — an agent asking for a state, not the transitions that
    /// follow. A frame-by-frame trace would bury exactly the signal an agent
    /// polls this for.
    @discardableResult
    private func record(
        _ kind: ActivityKind,
        actor: ActivityActor,
        summary: String,
        question: QuestionRecord? = nil,
        detail: [String: String]? = nil,
        now: Date
    ) -> ActivityRecord {
        let entry = ActivityRecord(
            seq: nextSequence,
            at: now,
            actor: actor,
            kind: kind,
            summary: summary,
            question: question,
            detail: detail
        )
        nextSequence += 1
        recentActivity.append(entry)
        if recentActivity.count > Self.maxRecentActivity {
            recentActivity.removeFirst(recentActivity.count - Self.maxRecentActivity)
        }
        guard let activity else { return entry }
        // Chained rather than detached: writes must land in order relative to
        // each other and to a later cull, or a clear can overtake an in-flight
        // append and resurrect the record it was meant to delete.
        let previous = historyWrite
        historyWrite = Task {
            await previous?.value
            await activity.append(entry)
        }
        return entry
    }

    // MARK: activity

    /// Everything after `seq`, oldest first. The polling cursor that lets an
    /// agent catch up without holding an event stream open.
    public func activityEntries(after seq: UInt64 = 0, limit: Int = 100) -> [ActivityRecord] {
        Array(recentActivity.filter { $0.seq > seq }.prefix(max(0, limit)))
    }

    public func latestSequence() -> UInt64 { nextSequence - 1 }

    @discardableResult
    public func clearActivity(keep: Int? = nil) async -> Int {
        let before = recentActivity.count
        if let keep, keep > 0 {
            recentActivity = Array(recentActivity.suffix(keep))
        } else {
            recentActivity.removeAll()
        }
        recentQuestions = recentActivity.compactMap {
            $0.kind == .questionResolved ? $0.question : nil
        }
        var removedFromDisk = 0
        if let activity {
            await drainHistoryWrites()
            if let keep, keep > 0 {
                removedFromDisk = await activity.cull(keepingNewest: keep)
            } else {
                removedFromDisk = await activity.clear()
            }
        }
        return max(before - recentActivity.count, removedFromDisk)
    }

    /// Wait for queued history writes to land. Cull, restore, and shutdown all
    /// need this; ordinary reads do not, because the in-memory ring is
    /// authoritative for them.
    public func drainHistoryWrites() async {
        await historyWrite?.value
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
