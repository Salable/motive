import Foundation
import SwiftUI
import MotiveCore
import MotiveSprite

/// Main-actor bridge between a `MotiveEngine` and SwiftUI: republishes the
/// engine's event stream as observable state the views render from.
@MainActor
public final class SpriteHost: ObservableObject, SpeechInputSink {
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
    /// True while the microphone is open for an answer. Drives the mic button's
    /// active state; there is no other indication that we are listening.
    @Published public private(set) var isListening = false
    /// Set when a spoken answer could not be matched to the question, so the
    /// human is told rather than left wondering why nothing happened.
    @Published public private(set) var lastSpeechMisheard: String?

    private var speechInput: (any SpeechInput)?

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

    /// Seed the presented history from the engine's durable record.
    ///
    /// `answeredQuestions` otherwise only accumulates from live events, so a
    /// restarted pet would show an empty "Answered" list while the file on disk
    /// was intact — the one place the persistence would be invisible.
    public func loadAnsweredQuestions(limit: Int = 50) async {
        answeredQuestions = await engine.questionHistory(limit: limit)
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

    // MARK: spoken answers

    /// Install speech input. Nil (the default) leaves the mic button hidden.
    public func setSpeechInput(_ input: (any SpeechInput)?) {
        speechInput = input
    }

    public var isSpeechInputAvailable: Bool { speechInput != nil }

    /// Listen for an answer to the question currently on screen.
    public func listenForAnswer() async {
        guard let speechInput, let question = headQuestion else { return }
        lastSpeechMisheard = nil
        isListening = true
        await speechInput.startListening(answering: question.id)
    }

    public func stopListening() async {
        await speechInput?.stopListening()
        isListening = false
    }

    /// A spoken answer arrives here and goes through exactly the same path as a
    /// typed one — transcription is an input method, not a separate feature.
    public func transcriptDidFinalize(_ text: String, answering questionID: String?, at: Date) async {
        isListening = false
        guard let questionID,
              let question = outstandingQuestions.first(where: { $0.id == questionID })
        else { return }
        guard let content = question.interpret(spoken: text) else {
            // Better to say "I didn't catch that" than to guess and act on it.
            lastSpeechMisheard = text
            return
        }
        await answer(questionID, with: content, via: .voice)
    }

    /// Dismiss without choosing — the third of MCP's three actions.
    @discardableResult
    public func dismissQuestion(_ id: String) async -> Bool {
        if case .success = await engine.cancelQuestion(id: id, reason: .dismissed) { return true }
        return false
    }

    /// Convenience: build the engine from the definition and start its clock.
    /// `activity` defaults to the standard runtime home, so a pet remembers
    /// what happened across restarts without the host wiring anything. Pass nil
    /// for an ephemeral pet.
    public convenience init(
        definition: SpriteDefinition,
        activity: ActivityStore? = FileActivityStore(
            url: RuntimePaths.standard.activityURL
        )
    ) {
        let engine = MotiveEngine(definition: definition.behaviorDefinition, activity: activity)
        self.init(definition: definition, engine: engine)
        Task { [weak self] in
            await engine.restoreHistory()
            await self?.loadAnsweredQuestions()
            await engine.start()
        }
    }

    deinit {
        subscription?.cancel()
    }
}
