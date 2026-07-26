import Foundation
import MotiveCore

/// One atlas image inside a sprite package.
public struct SpriteAtlas: Equatable, Sendable {
    public let key: String
    public let fileURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(key: String, fileURL: URL, pixelWidth: Int, pixelHeight: Int) {
        self.key = key
        self.fileURL = fileURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// A pixel-space rectangle inside an atlas. Not CGRect so the sprite layer
/// stays free of CoreGraphics.
public struct FrameRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One drawable frame: which atlas, which pixels, how long.
public struct SpriteFrame: Equatable, Sendable {
    public let atlasKey: String
    public let rect: FrameRect
    public let duration: TimeInterval

    public init(atlasKey: String, rect: FrameRect, duration: TimeInterval) {
        self.atlasKey = atlasKey
        self.rect = rect
        self.duration = duration
    }
}

/// A fully-resolved animation state: geometry + behavior. Frames are explicit
/// rects, so row grids, arbitrary grids, and non-contiguous layouts all
/// normalize identically.
public struct SpriteState: Equatable, Sendable {
    public let name: String
    public let frames: [SpriteFrame]
    public let loop: Bool
    public let interrupt: InterruptPolicy
    public let then: String?
    public let purpose: String?

    public init(
        name: String,
        frames: [SpriteFrame],
        loop: Bool = true,
        interrupt: InterruptPolicy = .immediate,
        then: String? = nil,
        purpose: String? = nil
    ) {
        self.name = name
        self.frames = frames
        self.loop = loop
        self.interrupt = interrupt
        self.then = then
        self.purpose = purpose
    }

    public var behavior: StateBehavior {
        StateBehavior(
            name: name,
            frameDurations: frames.map(\.duration),
            loop: loop,
            interrupt: interrupt,
            then: then,
            purpose: purpose
        )
    }
}

/// Sprite package metadata (motive/1 carries all of it; codex/1 a subset).
public struct SpriteMetadata: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let author: String?
    public let license: String?
    public let version: String?
    /// How this pet should sound when a host installs spoken output. A
    /// declaration, not a demand — the user's own setting overrides it.
    public let voice: VoicePreferences?

    public init(
        id: String,
        displayName: String,
        description: String? = nil,
        author: String? = nil,
        license: String? = nil,
        version: String? = nil,
        voice: VoicePreferences? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.author = author
        self.license = license
        self.version = version
        self.voice = voice
    }
}

/// The normalized model every runner produces and the engine/renderer consume.
public struct SpriteDefinition: Equatable, Sendable {
    /// The format runner that produced this definition, e.g. "codex/1".
    public let format: String
    public let metadata: SpriteMetadata
    public let atlases: [String: SpriteAtlas]
    public let states: [String: SpriteState]
    public let aliases: [String: String]
    public let triggers: [String: TriggerSpec]
    public let transitions: [TransitionSpec]

    public init(
        format: String,
        metadata: SpriteMetadata,
        atlases: [String: SpriteAtlas],
        states: [String: SpriteState],
        aliases: [String: String] = [:],
        triggers: [String: TriggerSpec] = [:],
        transitions: [TransitionSpec] = []
    ) {
        self.format = format
        self.metadata = metadata
        self.atlases = atlases
        self.states = states
        self.aliases = aliases
        self.triggers = triggers
        self.transitions = transitions
    }

    /// The behavior half handed to `ActorStateMachine`/`MotiveEngine`.
    public var behaviorDefinition: BehaviorDefinition {
        BehaviorDefinition(
            states: states.mapValues(\.behavior),
            aliases: aliases,
            triggers: triggers,
            transitions: transitions
        )
    }

    public func resolveAlias(_ name: String) -> String {
        aliases[name] ?? name
    }

    public func state(named rawName: String) -> SpriteState? {
        states[resolveAlias(rawName)]
    }
}
