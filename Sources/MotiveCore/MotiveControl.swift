import Foundation

/// Wire DTOs for the control surface. Both adapters (REST, MCP) speak these —
/// they are encoded with Codable, never string-templated, so user text can't
/// break the JSON.
public struct ControlStatus: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let state: String
    public let speech: SpeechInfo?

    public struct SpeechInfo: Codable, Equatable, Sendable {
        public let id: String
        public let text: String
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

    init(state: String, scheduled: Bool? = nil, speechID: String? = nil, scriptID: String? = nil) {
        self.ok = true
        self.state = state
        self.scheduled = scheduled
        self.speechID = speechID
        self.scriptID = scriptID
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
            name: "play-script", method: "POST", path: "/v1/script",
            params: ["steps": "array of step objects {type: say|setState|trigger|pause, text|name|ms, hold} (required, ≤64)"],
            description: "Play a queued sequence of say/state/trigger/pause steps. Latest-wins: replaces a running script; any other command cancels it."
        ),
        VerbInfo(
            name: "cancel-script", method: "DELETE", path: "/v1/script", params: [:],
            description: "Cancel the running script, if any."
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
        return ControlStatus(
            name: displayName,
            version: MotiveVersion.current,
            state: directive.stateName,
            speech: speech.map { ControlStatus.SpeechInfo(id: $0.id, text: $0.text) }
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

    /// Validates fail-fast — nothing plays when any step names unknown
    /// vocabulary.
    public func playScript(_ run: ScriptRun) async -> Result<ControlReceipt, ControlFailure> {
        let definition = await engine.machine.definition
        if let failure = run.validate(against: definition) {
            return .failure(failure)
        }
        await engine.playScript(run)
        let current = await engine.machine.currentStateName
        return .success(ControlReceipt(state: current, scriptID: run.id))
    }

    public func cancelScript() async -> ControlReceipt {
        await engine.flushQueue()
        let current = await engine.machine.currentStateName
        return ControlReceipt(state: current)
    }
}
