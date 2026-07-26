import Foundation

/// Wire DTOs for the control surface. Both adapters (REST, MCP) speak these —
/// they are encoded with Codable, never string-templated, so user text can't
/// break the JSON.
public struct ControlStatus: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let state: String
    public let speech: SpeechInfo?
    public let queueDepth: Int

    public struct SpeechInfo: Codable, Equatable, Sendable {
        public let id: String
        public let text: String
    }
}

/// Wire shape of `GET /v1/queue`.
public struct QueueStatus: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let id: String
        public let step: ScriptStep
        /// "question" or "speaking" while the item waits on something outside
        /// the queue; absent for ordinary fixed-duration holds.
        public let awaiting: String?

        init(entry: QueueSnapshot.Entry) {
            id = entry.id
            step = entry.step
            switch entry.awaiting {
            case .question: awaiting = "question"
            case .speaking: awaiting = "speaking"
            case nil: awaiting = nil
            }
        }
    }

    public let depth: Int
    public let current: Item?
    /// Seconds until the current item's hold elapses. Absent while the current
    /// item is parked — a question has no countdown.
    public let currentRemaining: Double?
    public let pending: [Item]

    public init(snapshot: QueueSnapshot) {
        self.depth = snapshot.depth
        self.current = snapshot.current.map(Item.init(entry:))
        self.currentRemaining = snapshot.currentRemaining
        self.pending = snapshot.pending.map(Item.init(entry:))
    }
}

/// Wire shape of one question, for `GET /v1/questions` and its history.
public struct QuestionInfo: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let form: String
    public let choices: [String]?
    public let placeholder: String?
    public let status: String
    public let askedAt: Date
    public let presentedAt: Date?
    public let expiresAt: Date?
    public let resolvedAt: Date?
    /// Present when `status` is `accepted`.
    public let answer: AnswerContent?
    /// How the answer arrived: `typed` or `voice`.
    public let via: String?
    /// Why it ended without an answer, when it did.
    public let cancelReason: String?

    public init(record: QuestionRecord) {
        id = record.id
        text = record.text
        form = record.respond.form.rawValue
        choices = record.respond.choices
        placeholder = record.respond.placeholder
        status = record.status.rawValue
        askedAt = record.askedAt
        presentedAt = record.presentedAt
        expiresAt = record.expiresAt
        resolvedAt = record.resolvedAt
        answer = record.answer
        via = record.via?.rawValue
        cancelReason = record.cancelReason?.rawValue
    }
}

/// Wire shape of `GET /v1/questions`.
public struct QuestionList: Codable, Equatable, Sendable {
    /// Outstanding questions in ask order; `open[0]` owns the speech bubble.
    public let open: [QuestionInfo]
    public let openCount: Int
    /// Set only when the request named an `id` — open or already resolved.
    public let question: QuestionInfo?

    public init(open: [QuestionInfo], question: QuestionInfo? = nil) {
        self.open = open
        self.openCount = open.count
        self.question = question
    }
}

/// Wire shape of `GET /v1/activity`.
public struct ActivityPage: Codable, Equatable, Sendable {
    /// Oldest first, so a caller can apply them in order.
    public let entries: [ActivityRecord]
    /// Pass this back as `since` on the next poll.
    public let nextSeq: UInt64
    /// True when more is waiting — poll again immediately rather than sleeping.
    public let hasMore: Bool

    public init(entries: [ActivityRecord], nextSeq: UInt64, hasMore: Bool) {
        self.entries = entries
        self.nextSeq = nextSeq
        self.hasMore = hasMore
    }
}

/// Wire shape of `GET /v1/questions/history`.
public struct QuestionHistoryPage: Codable, Equatable, Sendable {
    /// Newest first.
    public let entries: [QuestionInfo]
    public let total: Int

    public init(entries: [QuestionInfo], total: Int) {
        self.entries = entries
        self.total = total
    }
}

public struct ControlReceipt: Codable, Equatable, Sendable {
    public let ok: Bool
    /// Current state after the command was applied.
    public let state: String
    /// True when the change waits for a loop boundary or natural end.
    public let scheduled: Bool?
    /// Set by `say`.
    public let speechID: String?
    /// Set by `play-script`.
    public let scriptID: String?
    /// Set by `enqueue` and `play-script`: the admitted items' ids, in order.
    public let itemIDs: [String]?
    /// Queue depth after the command.
    public let queueDepth: Int?
    /// Set by `clear-queue`: pending items dropped.
    public let dropped: Int?
    /// Set by `skip`: the id of the item that was skipped, when one was playing.
    public let skippedID: String?
    /// Set by `say` when it carried a `respond` block: the handle to poll.
    public let questionID: String?
    /// Set by `cancel-question`: the questions withdrawn.
    public let cancelledIDs: [String]?
    /// Set by `clear-question-history`: records deleted.
    public let removed: Int?

    init(
        state: String,
        scheduled: Bool? = nil,
        speechID: String? = nil,
        scriptID: String? = nil,
        itemIDs: [String]? = nil,
        queueDepth: Int? = nil,
        dropped: Int? = nil,
        skippedID: String? = nil,
        questionID: String? = nil,
        cancelledIDs: [String]? = nil,
        removed: Int? = nil
    ) {
        self.ok = true
        self.state = state
        self.scheduled = scheduled
        self.speechID = speechID
        self.scriptID = scriptID
        self.itemIDs = itemIDs
        self.queueDepth = queueDepth
        self.dropped = dropped
        self.skippedID = skippedID
        self.questionID = questionID
        self.cancelledIDs = cancelledIDs
        self.removed = removed
    }
}

public struct ControlFailure: Error, Codable, Equatable, Sendable {
    public let ok = false
    /// Machine-readable error code, e.g. "unknown_state".
    public let error: String
    /// The valid vocabulary, when the failure was a bad name.
    public let valid: [String]?

    public init(error: String, valid: [String]? = nil) {
        self.error = error
        self.valid = valid
    }

    enum CodingKeys: String, CodingKey { case ok, error, valid }
}

/// Self-describing schema: everything an agent needs to drive this sprite.
public struct ControlSchema: Codable, Equatable, Sendable {
    public struct StateInfo: Codable, Equatable, Sendable {
        public let name: String
        public let purpose: String?
        public let interrupt: String
    }

    public struct TriggerInfo: Codable, Equatable, Sendable {
        public let name: String
        public let state: String
        public let purpose: String?
    }

    public struct VerbInfo: Codable, Equatable, Sendable {
        public let name: String
        public let method: String
        public let path: String
        public let params: [String: String]
        public let description: String
    }

    public let name: String
    public let version: String
    public let states: [StateInfo]
    public let triggers: [TriggerInfo]
    public let aliases: [String: String]
    public let verbs: [VerbInfo]

    /// The canonical verb list. The REST adapter serves these routes 1:1 and
    /// MCP tools map onto the same names — every verb here ships rendered.
    public static let standardVerbs: [VerbInfo] = [
        VerbInfo(
            name: "status", method: "GET", path: "/v1/status", params: [:],
            description: "Current state and speech."
        ),
        VerbInfo(
            name: "set-state", method: "POST", path: "/v1/state",
            params: ["state": "string (required)", "duration": "milliseconds (optional; auto-revert to idle)"],
            description: "Change the animation state."
        ),
        VerbInfo(
            name: "trigger", method: "POST", path: "/v1/trigger",
            params: ["name": "string (required)"],
            description: "Play a one-shot gesture, then return to the prior state."
        ),
        VerbInfo(
            name: "say", method: "POST", path: "/v1/say",
            params: [
                "text": "string (required, ≤400 chars)",
                "ttl": "milliseconds (optional; default 8000; ignored when respond is set)",
                "respond": "object (optional) {form: confirm|choice|text, choices: 2–6 strings for choice, placeholder for text, timeout: milliseconds} — turns the bubble into a question that blocks the queue until a human answers",
            ],
            description: "Show a speech bubble, or ask a question when `respond` is set."
        ),
        VerbInfo(
            name: "dismiss-speech", method: "DELETE", path: "/v1/speech", params: [:],
            description: "Dismiss the current speech bubble."
        ),
        VerbInfo(
            name: "enqueue", method: "POST", path: "/v1/queue",
            params: ["items": "array of item objects {type: say|setState|trigger|pause, text|name|ms, hold} (required, ≤64 total depth)"],
            description: "Append items to the action queue; they play in order after everything already queued. All-or-nothing validation."
        ),
        VerbInfo(
            name: "queue", method: "GET", path: "/v1/queue", params: [:],
            description: "Inspect the queue: depth, current item (with remaining hold), pending items."
        ),
        VerbInfo(
            name: "clear-queue", method: "DELETE", path: "/v1/queue", params: [:],
            description: "Flush the queue: drop all pending items, stop waiting on the current one, and return to the default state."
        ),
        VerbInfo(
            name: "skip", method: "DELETE", path: "/v1/queue/current", params: [:],
            description: "Skip the current queue item: it ends now and the next pending item plays immediately. Pending items are preserved."
        ),
        VerbInfo(
            name: "questions", method: "GET", path: "/v1/questions",
            params: [
                "id": "string (optional; one question, open or resolved)",
                "wait": "milliseconds (optional, ≤30000; long-poll until it resolves)",
            ],
            description: "List the questions the pet is waiting on. Pass `id` for one, `wait` to block until it is answered. Only the human can answer — there is no verb that submits an answer."
        ),
        VerbInfo(
            name: "cancel-question", method: "DELETE", path: "/v1/questions",
            params: ["id": "string (optional; omit to withdraw every open question)"],
            description: "Withdraw a question you no longer need an answer to. Resolves it as cancelled and the queue moves on."
        ),
        VerbInfo(
            name: "activity", method: "GET", path: "/v1/activity",
            params: [
                "since": "integer (optional; sequence number of the last entry you saw — omit for the beginning)",
                "limit": "integer (optional; default 100, max 500)",
            ],
            description: "What has happened, oldest first: commands, questions, and the human's answers. Poll with `since` to catch up without holding the event stream open."
        ),
        VerbInfo(
            name: "clear-activity", method: "DELETE", path: "/v1/activity",
            params: ["keep": "integer (optional; retain the newest N; omit to clear everything)"],
            description: "Delete stored activity. Also available in Settings."
        ),
        VerbInfo(
            name: "question-history", method: "GET", path: "/v1/questions/history",
            params: ["limit": "integer (optional; default 50, max 500)"],
            description: "Past questions and their answers, newest first."
        ),
        VerbInfo(
            name: "play-script", method: "POST", path: "/v1/script",
            params: ["steps": "array of step objects {type: say|setState|trigger|pause, text|name|ms, hold} (required, ≤64)"],
            description: "Replace the queue with this sequence (flush, then enqueue in order)."
        ),
        VerbInfo(
            name: "cancel-script", method: "DELETE", path: "/v1/script", params: [:],
            description: "Alias of clear-queue."
        ),
        VerbInfo(
            name: "events", method: "GET", path: "/v1/events", params: [:],
            description: "Server-sent events stream of state changes and speech."
        ),
    ]
}

/// The single command surface for one sprite actor. REST routes and MCP tools
/// are thin 1:1 adapters over these methods; nothing here is aspirational —
/// every verb is honored by the renderer.
public actor MotiveControl {
    public let engine: MotiveEngine
    public let displayName: String

    public init(engine: MotiveEngine, displayName: String) {
        self.engine = engine
        self.displayName = displayName
    }

    public func status() async -> ControlStatus {
        let directive = await engine.currentDirective
        let speech = await engine.speech
        let depth = await engine.queueDepth
        return ControlStatus(
            name: displayName,
            version: MotiveVersion.current,
            state: directive.stateName,
            speech: speech.map { ControlStatus.SpeechInfo(id: $0.id, text: $0.text) },
            queueDepth: depth
        )
    }

    public func schema() async -> ControlSchema {
        let definition = await engine.machine.definition
        let states = definition.states.values
            .sorted { $0.name < $1.name }
            .map { ControlSchema.StateInfo(name: $0.name, purpose: $0.purpose, interrupt: $0.interrupt.rawValue) }
        let triggers = definition.triggers
            .sorted { $0.key < $1.key }
            .map { ControlSchema.TriggerInfo(name: $0.key, state: $0.value.state, purpose: $0.value.purpose) }
        return ControlSchema(
            name: displayName,
            version: MotiveVersion.current,
            states: states,
            triggers: triggers,
            aliases: definition.aliases,
            verbs: ControlSchema.standardVerbs
        )
    }

    public func setState(_ name: String, durationMS: Int? = nil) async -> Result<ControlReceipt, ControlFailure> {
        let duration = durationMS.map { TimeInterval(max(0, $0)) / 1_000 }
        let outcome = await engine.requestState(name, duration: duration)
        let current = await engine.machine.currentStateName
        switch outcome {
        case .changed, .noChange:
            return .success(ControlReceipt(state: current))
        case .scheduled:
            return .success(ControlReceipt(state: current, scheduled: true))
        case .rejected(let valid):
            return .failure(ControlFailure(error: "unknown_state", valid: valid))
        }
    }

    public func fireTrigger(_ name: String) async -> Result<ControlReceipt, ControlFailure> {
        let outcome = await engine.fireTrigger(name)
        let current = await engine.machine.currentStateName
        switch outcome {
        case .changed, .noChange:
            return .success(ControlReceipt(state: current))
        case .scheduled:
            return .success(ControlReceipt(state: current, scheduled: true))
        case .rejected(let valid):
            return .failure(ControlFailure(error: "unknown_trigger", valid: valid))
        }
    }

    /// Show a speech bubble — or, when `respond` is set, ask a question that
    /// blocks the queue until a human resolves it. One verb: audio and an
    /// answer affordance are renderings of speech, not separate acts.
    public func say(
        _ text: String,
        ttlMS: Int? = nil,
        respond: ResponseSpec? = nil
    ) async -> Result<ControlReceipt, ControlFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ControlFailure(error: "missing_text"))
        }
        if let respond {
            // `ttl` is deliberately ignored: a question lives until it is
            // resolved, so a bubble timeout would strand the queue.
            switch await engine.ask(trimmed, respond: respond) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let receipt):
                let current = await engine.machine.currentStateName
                return .success(ControlReceipt(
                    state: current,
                    speechID: receipt.id,
                    queueDepth: receipt.queueDepth,
                    questionID: receipt.id
                ))
            }
        }
        let ttl: TimeInterval? = ttlMS.map { TimeInterval(max(0, $0)) / 1_000 } ?? 8
        let bubble = await engine.say(trimmed, ttl: ttl)
        let current = await engine.machine.currentStateName
        return .success(ControlReceipt(state: current, speechID: bubble.id))
    }

    // MARK: questions
    //
    // Read and withdraw only. There is deliberately no verb that answers a
    // question: answers originate from UI input alone.

    public func questions(id: String? = nil) async -> Result<QuestionList, ControlFailure> {
        let open = await engine.outstandingQuestions().map(QuestionInfo.init(record:))
        guard let id else {
            return .success(QuestionList(open: open))
        }
        guard let record = await engine.question(id: id) else {
            return .failure(ControlFailure(error: "unknown_question"))
        }
        return .success(QuestionList(open: open, question: QuestionInfo(record: record)))
    }

    public func cancelQuestion(id: String? = nil) async -> Result<ControlReceipt, ControlFailure> {
        let cancelled: [String]
        if let id {
            switch await engine.cancelQuestion(id: id) {
            case .failure(let failure): return .failure(failure)
            case .success(let record): cancelled = [record.id]
            }
        } else {
            cancelled = await engine.cancelAllQuestions()
        }
        let current = await engine.machine.currentStateName
        let depth = await engine.queueDepth
        return .success(ControlReceipt(
            state: current, queueDepth: depth, cancelledIDs: cancelled
        ))
    }

    public func activity(since: UInt64? = nil, limit: Int? = nil) async -> ActivityPage {
        let capped = min(max(1, limit ?? 100), 500)
        let cursor = since ?? 0
        // Ask for one more than requested: that is how we know whether to tell
        // the caller to poll again immediately rather than wait.
        let fetched = await engine.activityEntries(after: cursor, limit: capped + 1)
        let page = Array(fetched.prefix(capped))
        let latest = await engine.latestSequence()
        return ActivityPage(
            entries: page,
            nextSeq: page.last?.seq ?? cursor,
            hasMore: fetched.count > capped || (page.last.map { $0.seq < latest } ?? false)
        )
    }

    public func clearActivity(keep: Int? = nil) async -> ControlReceipt {
        let removed = await engine.clearActivity(keep: keep)
        let current = await engine.machine.currentStateName
        return ControlReceipt(state: current, removed: removed)
    }

    public func questionHistory(limit: Int? = nil) async -> QuestionHistoryPage {
        let capped = min(max(1, limit ?? 50), 500)
        let entries = await engine.questionHistory(limit: capped)
        return QuestionHistoryPage(
            entries: entries.map(QuestionInfo.init(record:)),
            total: entries.count
        )
    }



    public func dismissSpeech() async -> ControlReceipt {
        await engine.dismissSpeech()
        let current = await engine.machine.currentStateName
        return ControlReceipt(state: current)
    }

    /// Append items to the queue (tail). All-or-nothing validation — nothing
    /// enqueues when any item names unknown vocabulary or the batch would
    /// exceed the depth cap.
    public func enqueue(_ steps: [ScriptStep]) async -> Result<ControlReceipt, ControlFailure> {
        let items = steps.map(QueueItem.init(step:))
        switch await engine.enqueue(items, at: .tail) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let receipt):
            let current = await engine.machine.currentStateName
            return .success(ControlReceipt(
                state: current,
                itemIDs: receipt.itemIDs,
                queueDepth: receipt.queueDepth
            ))
        }
    }

    public func queueStatus() async -> QueueStatus {
        QueueStatus(snapshot: await engine.queueSnapshot())
    }

    public func clearQueue() async -> ControlReceipt {
        let dropped = await engine.flushQueue()
        let current = await engine.machine.currentStateName
        let depth = await engine.queueDepth
        return ControlReceipt(state: current, queueDepth: depth, dropped: dropped)
    }

    /// Skip the current queue item; pending items are preserved. Idempotent —
    /// skipping an idle queue is an ok no-op.
    public func skip() async -> ControlReceipt {
        let skippedID = await engine.skipCurrent()
        let current = await engine.machine.currentStateName
        let depth = await engine.queueDepth
        return ControlReceipt(state: current, queueDepth: depth, skippedID: skippedID)
    }

    /// Compat sugar for `/v1/script`: replace the queue with these steps.
    public func playScript(_ run: ScriptRun) async -> Result<ControlReceipt, ControlFailure> {
        let definition = await engine.machine.definition
        if let failure = run.validate(against: definition) {
            return .failure(failure)
        }
        _ = await engine.flushQueue(revertToDefault: false)
        let result = await engine.enqueue(run.steps.map(QueueItem.init(step:)), at: .tail)
        let current = await engine.machine.currentStateName
        switch result {
        case .failure(let failure):
            return .failure(failure)
        case .success(let receipt):
            return .success(ControlReceipt(
                state: current,
                scriptID: run.id,
                itemIDs: receipt.itemIDs,
                queueDepth: receipt.queueDepth
            ))
        }
    }

    public func cancelScript() async -> ControlReceipt {
        await clearQueue()
    }
}
