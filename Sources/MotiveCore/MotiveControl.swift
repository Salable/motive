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
    }

    public let depth: Int
    public let current: Item?
    /// Seconds until the current item's hold elapses.
    public let currentRemaining: Double?
    public let pending: [Item]

    public init(snapshot: QueueSnapshot) {
        self.depth = snapshot.depth
        self.current = snapshot.current.map { Item(id: $0.id, step: $0.step) }
        self.currentRemaining = snapshot.currentRemaining
        self.pending = snapshot.pending.map { Item(id: $0.id, step: $0.step) }
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

    init(
        state: String,
        scheduled: Bool? = nil,
        speechID: String? = nil,
        scriptID: String? = nil,
        itemIDs: [String]? = nil,
        queueDepth: Int? = nil,
        dropped: Int? = nil
    ) {
        self.ok = true
        self.state = state
        self.scheduled = scheduled
        self.speechID = speechID
        self.scriptID = scriptID
        self.itemIDs = itemIDs
        self.queueDepth = queueDepth
        self.dropped = dropped
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
            params: ["text": "string (required, ≤400 chars)", "ttl": "milliseconds (optional; default 8000)"],
            description: "Show a speech bubble."
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
            description: "Flush the queue: drop all pending items and stop waiting on the current one."
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

    public func say(_ text: String, ttlMS: Int? = nil) async -> Result<ControlReceipt, ControlFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ControlFailure(error: "missing_text"))
        }
        let ttl: TimeInterval? = ttlMS.map { TimeInterval(max(0, $0)) / 1_000 } ?? 8
        let bubble = await engine.say(trimmed, ttl: ttl)
        let current = await engine.machine.currentStateName
        return .success(ControlReceipt(state: current, speechID: bubble.id))
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

    /// Compat sugar for `/v1/script`: replace the queue with these steps.
    public func playScript(_ run: ScriptRun) async -> Result<ControlReceipt, ControlFailure> {
        let definition = await engine.machine.definition
        if let failure = run.validate(against: definition) {
            return .failure(failure)
        }
        _ = await engine.flushQueue()
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
