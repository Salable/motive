import Foundation
import SwiftUI
import MotiveCore
import MotiveSprite

/// Main-actor bridge between a `MotiveEngine` and SwiftUI: republishes the
/// engine's event stream as observable state the views render from.
@MainActor
public final class SpriteHost: ObservableObject {
    public let definition: SpriteDefinition
    public let engine: MotiveEngine

    @Published public private(set) var directive: RenderDirective?
    @Published public private(set) var speech: SpeechBubble?
    /// True while the action queue is playing — from the first item starting
    /// until the queue drains or is flushed. Drives contextual queue controls.
    @Published public private(set) var queueActive = false

    private var subscription: Task<Void, Never>?

    public init(definition: SpriteDefinition, engine: MotiveEngine) {
        self.definition = definition
        self.engine = engine
        subscription = Task { [weak self] in
            guard let stream = await self?.engine.events() else { return }
            for await event in stream {
                guard let self else { return }
                switch event {
                case .stateChanged(let directive):
                    self.directive = directive
                case .speechPosted(let bubble):
                    self.speech = bubble
                case .speechDismissed(let id):
                    if self.speech?.id == id { self.speech = nil }
                case .queueItemStarted:
                    self.queueActive = true
                case .queueItemFinished:
                    break // the next item's start, or drained/flushed, follows
                case .queueDrained, .queueFlushed:
                    self.queueActive = false
                }
            }
        }
    }

    /// Convenience: build the engine from the definition and start its clock.
    public convenience init(definition: SpriteDefinition) {
        let engine = MotiveEngine(definition: definition.behaviorDefinition)
        self.init(definition: definition, engine: engine)
        Task { await engine.start() }
    }

    deinit {
        subscription?.cancel()
    }
}
