import Foundation

/// One step of a script. Codable with a `type` discriminator — scripts are
/// data, never code, and travel over REST/MCP.
public enum ScriptStep: Codable, Equatable, Sendable {
    /// Show a speech bubble and hold the step for the same interval, so the
    /// bubble dismissal and the step advance coincide by construction.
    case say(text: String, holdMS: Int)
    /// Change state; `holdMS: nil` advances on the next tick.
    case setState(name: String, holdMS: Int?)
    /// Fire a one-shot trigger and advance immediately (the state machine
    /// handles the gesture's own return).
    case trigger(name: String)
    case pause(ms: Int)

    public static let defaultSayHoldMS = 4000

    enum CodingKeys: String, CodingKey {
        case type, text, name, ms, hold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "say":
            let text = try container.decode(String.self, forKey: .text)
            let hold = try container.decodeIfPresent(Int.self, forKey: .hold) ?? Self.defaultSayHoldMS
            self = .say(text: text, holdMS: hold)
        case "setState", "set-state", "state":
            let name = try container.decode(String.self, forKey: .name)
            let hold = try container.decodeIfPresent(Int.self, forKey: .hold)
            self = .setState(name: name, holdMS: hold)
        case "trigger":
            self = .trigger(name: try container.decode(String.self, forKey: .name))
        case "pause":
            self = .pause(ms: try container.decode(Int.self, forKey: .ms))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown step type '\(type)' (valid: say, setState, trigger, pause)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .say(let text, let holdMS):
            try container.encode("say", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(holdMS, forKey: .hold)
        case .setState(let name, let holdMS):
            try container.encode("setState", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(holdMS, forKey: .hold)
        case .trigger(let name):
            try container.encode("trigger", forKey: .type)
            try container.encode(name, forKey: .name)
        case .pause(let ms):
            try container.encode("pause", forKey: .type)
            try container.encode(ms, forKey: .ms)
        }
    }
}

/// A playable script: an ordered list of steps executed in flow.
public struct ScriptRun: Codable, Equatable, Sendable {
    public static let maxSteps = 64

    public let id: String
    public let steps: [ScriptStep]

    public init(id: String = UUID().uuidString, steps: [ScriptStep]) {
        self.id = id
        self.steps = steps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        steps = try container.decode([ScriptStep].self, forKey: .steps)
    }

    enum CodingKeys: String, CodingKey { case id, steps }

    /// Fail-fast validation before anything plays: every referenced state and
    /// trigger must exist. Returns nil when the script is playable.
    public func validate(against definition: BehaviorDefinition) -> ControlFailure? {
        guard !steps.isEmpty else {
            return ControlFailure(error: "empty_script")
        }
        guard steps.count <= Self.maxSteps else {
            return ControlFailure(error: "script_too_long", valid: nil)
        }
        for step in steps {
            switch step {
            case .setState(let name, _):
                if definition.state(named: name) == nil {
                    return ControlFailure(error: "unknown_state", valid: definition.validStateNames)
                }
            case .trigger(let name):
                if definition.triggers[name] == nil {
                    return ControlFailure(error: "unknown_trigger", valid: definition.triggers.keys.sorted())
                }
            case .say, .pause:
                continue
            }
        }
        return nil
    }
}

/// Pure, timer-free script sequencer — the `ActorStateMachine` of scripts.
/// The owner (`MotiveEngine`) calls `tick` with explicit clocks and executes
/// the returned effects; the player itself never touches the engine, so
/// tests are exact.
///
/// Steps complete on explicit holds known at step entry (a `say` step's
/// bubble TTL and hold are the same value by construction). Consecutive
/// zero-duration steps advance in one call, bounded by the step count.
/// `play` over a running script is latest-wins: cancel, then replace.
public struct ScriptPlayer: Sendable {
    /// A side effect the owner must perform on the engine.
    public enum Action: Equatable, Sendable {
        case say(text: String, ttl: TimeInterval)
        case setState(name: String)
        case trigger(name: String)
    }

    /// A lifecycle signal the owner should broadcast.
    public enum Signal: Equatable, Sendable {
        case started(id: String, stepCount: Int)
        case stepChanged(id: String, index: Int)
        case finished(id: String)
        case cancelled(id: String)
    }

    public enum Effect: Equatable, Sendable {
        case perform(Action)
        case emit(Signal)
    }

    /// Per-step holds clamp to the same cap as state durations.
    public static let maxHold: TimeInterval = ActorStateMachine.maxDuration

    private var run: ScriptRun?
    private var stepIndex = 0
    private var stepDeadline: Date?

    public init() {}

    public var isRunning: Bool { run != nil }
    public var currentRunID: String? { run?.id }

    // MARK: commands

    public mutating func play(_ newRun: ScriptRun, now: Date) -> [Effect] {
        var effects = cancel(now: now)
        run = newRun
        stepIndex = -1
        stepDeadline = nil
        effects.append(.emit(.started(id: newRun.id, stepCount: newRun.steps.count)))
        effects.append(contentsOf: advance(now: now))
        return effects
    }

    public mutating func cancel(now: Date) -> [Effect] {
        guard let current = run else { return [] }
        run = nil
        stepIndex = 0
        stepDeadline = nil
        return [.emit(.cancelled(id: current.id))]
    }

    // MARK: clock

    public mutating func tick(now: Date) -> [Effect] {
        guard run != nil else { return [] }
        if let deadline = stepDeadline, now < deadline { return [] }
        return advance(now: now)
    }

    // MARK: internals

    /// Enter the next step (and any following zero-duration steps). Bounded:
    /// each iteration consumes one step of a ≤maxSteps script.
    private mutating func advance(now: Date) -> [Effect] {
        var effects: [Effect] = []
        while let current = run {
            stepIndex += 1
            guard stepIndex < current.steps.count else {
                run = nil
                stepDeadline = nil
                effects.append(.emit(.finished(id: current.id)))
                break
            }
            effects.append(.emit(.stepChanged(id: current.id, index: stepIndex)))

            let hold: TimeInterval
            switch current.steps[stepIndex] {
            case .say(let text, let holdMS):
                let clamped = min(Self.maxHold, max(0, TimeInterval(holdMS) / 1_000))
                effects.append(.perform(.say(text: text, ttl: clamped)))
                hold = clamped
            case .setState(let name, let holdMS):
                effects.append(.perform(.setState(name: name)))
                hold = holdMS.map { min(Self.maxHold, max(0, TimeInterval($0) / 1_000)) } ?? 0
            case .trigger(let name):
                effects.append(.perform(.trigger(name: name)))
                hold = 0
            case .pause(let ms):
                hold = min(Self.maxHold, max(0, TimeInterval(ms) / 1_000))
            }

            if hold > 0 {
                stepDeadline = now.addingTimeInterval(hold)
                break
            }
            stepDeadline = nil
        }
        return effects
    }
}
