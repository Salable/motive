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
    /// Live view of the queue: the running item, its remaining hold, and the
    /// pending work behind it. Refreshed on every queue event.
    @Published public private(set) var queue = QueueSnapshot(current: nil, currentRemaining: nil, pending: [])
    /// Every question the pet is waiting on, head first. `first` owns the
    /// speech bubble; the rest are the "N more waiting" count.
    @Published public private(set) var outstandingQuestions: [QuestionRecord] = []
    /// The question currently presented — the one the bubble is showing.
    @Published public private(set) var headQuestion: QuestionRecord?
    /// Resolved questions, newest first. Presentational: the durable record
    /// lives in the engine.
    @Published public private(set) var answeredQuestions: [QuestionRecord] = []

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
                    await self.refreshQueue()
                case .queueItemFinished:
                    // The next item's start, or drained/flushed, follows — but
                    // pending shrinks now, so the queue view stays truthful.
                    await self.refreshQueue()
                case .queueDrained, .queueFlushed:
                    self.queueActive = false
                    await self.refreshQueue()
                case .queueItemAwaiting:
                    // A parked item is still active work — the skip and clear
                    // controls must stay reachable precisely now.
                    self.queueActive = true
                    await self.refreshQueue()
                case .questionAsked(let record):
                    if !self.outstandingQuestions.contains(where: { $0.id == record.id }) {
                        self.outstandingQuestions.append(record)
                    }
                case .questionPresented(let id):
                    self.headQuestion = self.outstandingQuestions.first { $0.id == id }
                case .questionResolved(let record):
                    self.outstandingQuestions.removeAll { $0.id == record.id }
                    if self.headQuestion?.id == record.id { self.headQuestion = nil }
                    self.answeredQuestions.insert(record, at: 0)
                }
            }
        }
    }

    /// Re-read the queue from the engine. Queue events do this automatically;
    /// surfaces that render the current item's countdown (`QueueWindow`) call
    /// it on their own display clock, between events.
    public func refreshQueue() async {
        queue = await engine.queueSnapshot()
    }

    // MARK: answering
    //
    // Answers reach the engine from here and nowhere else. There is no REST
    // route or MCP tool that resolves a question as answered — that absence is
    // what makes a human-in-the-loop check mean anything.

    @discardableResult
    public func answer(
        _ id: String,
        with content: AnswerContent,
        via: AnswerChannel = .typed
    ) async -> Bool {
        if case .success = await engine.answerQuestion(id: id, content: content, via: via) {
            return true
        }
        return false
    }

    @discardableResult
    public func decline(_ id: String, via: AnswerChannel = .typed) async -> Bool {
        if case .success = await engine.declineQuestion(id: id, via: via) { return true }
        return false
    }

    /// Dismiss without choosing — the third of MCP's three actions.
    @discardableResult
    public func dismissQuestion(_ id: String) async -> Bool {
        if case .success = await engine.cancelQuestion(id: id, reason: .dismissed) { return true }
        return false
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
