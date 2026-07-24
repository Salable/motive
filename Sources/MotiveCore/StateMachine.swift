import Foundation

/// How a state *enters* when requested while another state is playing.
/// `immediate` preempts now (failed), `afterLoop` waits for the current loop
/// boundary (waving, jumping), `never` waits for the current state to end
/// naturally.
public enum InterruptPolicy: String, Codable, Sendable {
    case immediate
    case afterLoop = "after-loop"
    case never
}

/// The timing/behavior half of an animation state — everything the state
/// machine needs, nothing about pixels. Geometry (which atlas cell each frame
/// shows) lives in `MotiveSprite.SpriteState`, keyed by the same name.
public struct StateBehavior: Equatable, Sendable {
    public let name: String
    public let frameDurations: [TimeInterval]
    public let loop: Bool
    public let interrupt: InterruptPolicy
    /// Optional follow-on state entered when a non-looping state finishes.
    public let then: String?
    /// Human/agent-readable description of what the state expresses.
    public let purpose: String?

    public var frameCount: Int { frameDurations.count }
    public var loopDuration: TimeInterval { frameDurations.reduce(0, +) }

    public init(
        name: String,
        frameDurations: [TimeInterval],
        loop: Bool = true,
        interrupt: InterruptPolicy = .immediate,
        then: String? = nil,
        purpose: String? = nil
    ) {
        self.name = name
        self.frameDurations = frameDurations
        self.loop = loop
        self.interrupt = interrupt
        self.then = then
        self.purpose = purpose
    }

    public func frame(at elapsed: TimeInterval, reducedMotion: Bool = false) -> Int {
        guard !reducedMotion, frameDurations.count > 1, loopDuration > 0 else { return 0 }
        if !loop, elapsed >= loopDuration { return frameDurations.count - 1 }
        var remaining = elapsed.truncatingRemainder(dividingBy: loopDuration)
        if remaining < 0 { remaining += loopDuration }
        for (index, duration) in frameDurations.enumerated() {
            if remaining < duration { return index }
            remaining -= duration
        }
        return frameDurations.count - 1
    }
}

public struct TransitionSpec: Codable, Equatable, Sendable {
    public let from: String
    public let to: String
    public let ms: Int

    public init(from: String, to: String, ms: Int = 180) {
        self.from = from
        self.to = to
        self.ms = ms
    }
}

public struct TriggerSpec: Codable, Equatable, Sendable {
    public let state: String
    /// One-shot triggers play the target once, then return to the prior state.
    public let once: Bool
    public let purpose: String?

    public init(state: String, once: Bool = true, purpose: String? = nil) {
        self.state = state
        self.once = once
        self.purpose = purpose
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(String.self, forKey: .state)
        once = try container.decodeIfPresent(Bool.self, forKey: .once) ?? true
        purpose = try container.decodeIfPresent(String.self, forKey: .purpose)
    }
}

/// The behavior vocabulary of one actor: states, aliases, triggers, and
/// crossfade transitions. Produced by a sprite runner; consumed by
/// `ActorStateMachine`.
public struct BehaviorDefinition: Equatable, Sendable {
    public let states: [String: StateBehavior]
    public let aliases: [String: String]
    public let triggers: [String: TriggerSpec]
    public let transitions: [TransitionSpec]

    public init(
        states: [String: StateBehavior],
        aliases: [String: String] = [:],
        triggers: [String: TriggerSpec] = [:],
        transitions: [TransitionSpec] = []
    ) {
        self.states = states
        self.aliases = aliases
        self.triggers = triggers
        self.transitions = transitions
    }

    public func resolveAlias(_ name: String) -> String {
        aliases[name] ?? name
    }

    public func state(named rawName: String) -> StateBehavior? {
        states[resolveAlias(rawName)]
    }

    public var validStateNames: [String] {
        states.keys.sorted()
    }

    /// Crossfade duration for a state change: exact from/to beats from:*,
    /// beats *:to, beats *:*.
    public func transition(from: String, to: String) -> TransitionSpec {
        var best: TransitionSpec?
        var bestScore = -1
        for candidate in transitions {
            let fromMatches = candidate.from == from || candidate.from == "*"
            let toMatches = candidate.to == to || candidate.to == "*"
            guard fromMatches, toMatches else { continue }
            let score = (candidate.from == from ? 2 : 0) + (candidate.to == to ? 1 : 0)
            if score > bestScore {
                best = candidate
                bestScore = score
            }
        }
        return best ?? TransitionSpec(from: "*", to: "*", ms: 180)
    }
}

public struct Crossfade: Equatable, Sendable {
    public let fromStateName: String
    public let startedAt: Date
    public let duration: TimeInterval

    public init(fromStateName: String, startedAt: Date, duration: TimeInterval) {
        self.fromStateName = fromStateName
        self.startedAt = startedAt
        self.duration = duration
    }

    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(startedAt) / duration))
    }

    public func isActive(at now: Date) -> Bool {
        progress(at: now) < 1
    }
}

/// Everything a rendering surface needs to draw an actor right now. The state
/// is semantic; surfaces resolve geometry for the frame index via their
/// sprite definition.
public struct RenderDirective: Equatable, Sendable {
    public let stateName: String
    public let behavior: StateBehavior
    public let enteredAt: Date
    public let crossfade: Crossfade?

    public init(stateName: String, behavior: StateBehavior, enteredAt: Date, crossfade: Crossfade?) {
        self.stateName = stateName
        self.behavior = behavior
        self.enteredAt = enteredAt
        self.crossfade = crossfade
    }

    public func frame(at now: Date, reducedMotion: Bool = false) -> Int {
        behavior.frame(at: now.timeIntervalSince(enteredAt), reducedMotion: reducedMotion)
    }
}

/// Pure, timer-free state machine for one actor. The owner (`MotiveEngine`)
/// calls `tick` periodically; all methods take explicit clocks so tests are
/// exact.
///
/// Pending requests coalesce latest-wins — never a queue (queues strobe,
/// replacement stays honest).
public struct ActorStateMachine: Sendable {
    public enum Outcome: Equatable, Sendable {
        case changed(RenderDirective)
        case scheduled(at: Date)
        case rejected(valid: [String])
        case noChange
    }

    public static let maxDuration: TimeInterval = 30

    public let definition: BehaviorDefinition

    private var currentState: StateBehavior
    private var enteredAt: Date
    private var revertAt: Date?
    private var crossfade: Crossfade?
    private var pending: (name: String, duration: TimeInterval?, promoteAt: Date)?
    private var triggerReturnState: String?

    public init(definition: BehaviorDefinition, initialState: String = "idle", now: Date = Date()) {
        self.definition = definition
        let name = definition.resolveAlias(initialState)
        self.currentState = definition.states[name]
            ?? definition.states["idle"]
            ?? definition.states.values.sorted { $0.name < $1.name }.first
            ?? StateBehavior(name: "idle", frameDurations: [1])
        self.enteredAt = now
    }

    public var currentStateName: String { currentState.name }

    // MARK: requests

    public mutating func requestState(_ rawName: String, duration: TimeInterval? = nil, now: Date = Date()) -> Outcome {
        let name = definition.resolveAlias(rawName)
        guard let target = definition.states[name] else {
            return .rejected(valid: definition.validStateNames)
        }

        if name == currentState.name, pending == nil {
            if let duration {
                revertAt = now.addingTimeInterval(min(max(duration, 0), Self.maxDuration))
            }
            return .noChange
        }

        switch target.interrupt {
        case .immediate:
            enter(target, duration: duration, now: now)
            return .changed(directive(now: now))
        case .afterLoop:
            let promoteAt = nextLoopBoundary(after: now)
            pending = (name, duration, promoteAt)
            return .scheduled(at: promoteAt)
        case .never:
            let promoteAt = naturalEnd(after: now) ?? .distantFuture
            pending = (name, duration, promoteAt)
            return .scheduled(at: promoteAt)
        }
    }

    public mutating func fireTrigger(_ rawName: String, now: Date = Date()) -> Outcome {
        guard let trigger = definition.triggers[rawName] else {
            return .rejected(valid: definition.triggers.keys.sorted())
        }
        guard let target = definition.states[definition.resolveAlias(trigger.state)] else {
            return .rejected(valid: definition.validStateNames)
        }
        let returnName = trigger.once ? currentState.name : nil
        enter(target, duration: nil, now: now)
        triggerReturnState = returnName
        return .changed(directive(now: now))
    }

    // MARK: clock

    public mutating func tick(now: Date = Date()) -> Outcome {
        if let crossfade, !crossfade.isActive(at: now) {
            self.crossfade = nil
        }

        if let revertAt, now >= revertAt {
            self.revertAt = nil
            if let idle = definition.states[definition.resolveAlias("idle")] {
                enter(idle, duration: nil, now: now)
                return .changed(directive(now: now))
            }
        }

        if let returnName = triggerReturnState,
           now.timeIntervalSince(enteredAt) >= currentState.loopDuration,
           let target = definition.states[returnName] {
            triggerReturnState = nil
            enter(target, duration: nil, now: now)
            return .changed(directive(now: now))
        }

        if !currentState.loop,
           now.timeIntervalSince(enteredAt) >= currentState.loopDuration,
           let thenName = currentState.then,
           let target = definition.states[definition.resolveAlias(thenName)] {
            enter(target, duration: nil, now: now)
            return .changed(directive(now: now))
        }

        if let pending, now >= pending.promoteAt {
            self.pending = nil
            if let target = definition.states[pending.name] {
                enter(target, duration: pending.duration, now: now)
                return .changed(directive(now: now))
            }
        }

        return .noChange
    }

    public func directive(now: Date = Date()) -> RenderDirective {
        RenderDirective(
            stateName: currentState.name,
            behavior: currentState,
            enteredAt: enteredAt,
            crossfade: crossfade?.isActive(at: now) == true ? crossfade : nil
        )
    }

    // MARK: internals

    private mutating func enter(_ target: StateBehavior, duration: TimeInterval?, now: Date) {
        let transition = definition.transition(from: currentState.name, to: target.name)
        crossfade = Crossfade(
            fromStateName: currentState.name,
            startedAt: now,
            duration: TimeInterval(transition.ms) / 1_000
        )
        currentState = target
        enteredAt = now
        revertAt = duration.map { now.addingTimeInterval(min(max($0, 0), Self.maxDuration)) }
        triggerReturnState = nil
        pending = nil
    }

    private func nextLoopBoundary(after now: Date) -> Date {
        let loop = currentState.loopDuration
        guard loop > 0 else { return now }
        let elapsed = now.timeIntervalSince(enteredAt)
        let completed = (elapsed / loop).rounded(.up)
        let boundary = enteredAt.addingTimeInterval(max(completed, 1) * loop)
        return boundary > now ? boundary : now
    }

    private func naturalEnd(after now: Date) -> Date? {
        if let revertAt { return revertAt }
        if !currentState.loop {
            let end = enteredAt.addingTimeInterval(currentState.loopDuration)
            return end > now ? end : now
        }
        return nil
    }
}
