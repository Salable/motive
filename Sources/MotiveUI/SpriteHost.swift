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
                case .queueItemStarted, .queueItemFinished, .queueDrained, .queueFlushed:
                    break // rendering follows the state/speech events queue items produce
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
