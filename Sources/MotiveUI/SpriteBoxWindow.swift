import AppKit
import SwiftUI
import MotiveCore
import MotiveSprite

/// The borderless, transparent, always-on-top desktop window that hosts a
/// sprite — the "app layer" surface. Drag anywhere to move it. Optional
/// interactions: a chat input (default: makes the sprite speak), and action
/// buttons the host app supplies.
@MainActor
public final class SpriteBoxWindow {
    public struct Action: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let handler: @Sendable () -> Void

        public init(id: String = UUID().uuidString, title: String, handler: @escaping @Sendable () -> Void) {
            self.id = id
            self.title = title
            self.handler = handler
        }
    }

    public struct Options: Sendable {
        /// Sprite display size in points (frame aspect is preserved).
        public var spriteSize: CGFloat
        public var alwaysOnTop: Bool
        public var pixelated: Bool
        public var chatEnabled: Bool
        /// Hover-visible skip/clear controls while the action queue is playing.
        public var queueControlsEnabled: Bool

        public init(
            spriteSize: CGFloat = 160,
            alwaysOnTop: Bool = true,
            pixelated: Bool = false,
            chatEnabled: Bool = false,
            queueControlsEnabled: Bool = true
        ) {
            self.spriteSize = spriteSize
            self.alwaysOnTop = alwaysOnTop
            self.pixelated = pixelated
            self.chatEnabled = chatEnabled
            self.queueControlsEnabled = queueControlsEnabled
        }
    }

    final class Model: ObservableObject {
        @Published var spriteSize: CGFloat = 160
        @Published var pixelated = false
        @Published var chatEnabled = false
        @Published var queueControlsEnabled = true
        @Published var actions: [Action] = []
        var onChatSubmit: ((String) -> Void)?
    }

    public let panel: NSPanel
    public let host: SpriteHost
    let model = Model()

    /// Called when the user submits chat text. Defaults to making the sprite
    /// say the text.
    public var onChatSubmit: ((String) -> Void)? {
        get { model.onChatSubmit }
        set { model.onChatSubmit = newValue }
    }

    public var actions: [Action] {
        get { model.actions }
        set { model.actions = newValue }
    }

    public init(host: SpriteHost, options: Options = Options()) {
        self.host = host

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: .zero),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        self.panel = panel

        model.onChatSubmit = { [weak host] text in
            guard let engine = host?.engine else { return }
            Task { await engine.say(text) }
        }
        let hosting = NSHostingView(rootView: SpriteBoxContent(host: host, model: model))
        // The panel's size is set explicitly in update(options:); without this,
        // the hosting view's window-sizing constraints inflate the panel to its
        // own idea of the content size and push the sprite off-screen.
        hosting.sizingOptions = []
        panel.contentView = hosting
        update(options: options)
    }

    /// Re-apply presentation options (used by settings capabilities).
    public func update(options: Options) {
        model.spriteSize = options.spriteSize
        model.pixelated = options.pixelated
        model.chatEnabled = options.chatEnabled
        model.queueControlsEnabled = options.queueControlsEnabled
        panel.level = options.alwaysOnTop ? .floating : .normal
        let size = NSSize(
            width: max(options.spriteSize + 16, 260),
            height: options.spriteSize + SpriteBoxContent.chromeReserve
        )
        panel.setContentSize(size)
    }

    /// Show the box near the bottom-trailing corner of the main screen (or at
    /// an explicit origin).
    public func show(at origin: NSPoint? = nil) {
        if let origin {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - panel.frame.width - 48,
                y: frame.minY + 48
            ))
        }
        panel.orderFrontRegardless()
    }

    public func close() {
        panel.orderOut(nil)
    }

    public var isVisible: Bool { panel.isVisible }
}

struct SpriteBoxContent: View {
    /// Vertical points reserved around the sprite for bubble + controls.
    /// Sized for the tallest arrangement: bubble, hover controls, and a
    /// question's answer row plus its decline link.
    static let chromeReserve: CGFloat = 188

    @ObservedObject var host: SpriteHost
    @ObservedObject var model: SpriteBoxWindow.Model
    @State private var chatText = ""
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            if let bubble = host.speech {
                SpeechBubbleView(bubble: bubble)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            } else {
                Spacer().frame(height: 40)
            }

            SpriteView(host: host, pixelated: model.pixelated)
                .frame(width: model.spriteSize, height: model.spriteSize)

            if model.queueControlsEnabled {
                // Fixed-height slot: the buttons appear inside it on hover, so
                // the sprite never reflows in the bottom-aligned stack.
                HStack(spacing: 6) {
                    if hovering && host.queueActive {
                        Button {
                            Task { await host.engine.skipCurrent() }
                        } label: {
                            Image(systemName: "forward.fill")
                        }
                        .help("Skip this step")
                        Button {
                            Task {
                                await host.engine.flushQueue()
                                await host.engine.dismissSpeech()
                            }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .help("Stop the scene")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(height: 26)
                .animation(.easeInOut(duration: 0.15), value: hovering)
                .animation(.easeInOut(duration: 0.15), value: host.queueActive)
            }

            if !model.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.actions) { action in
                        Button(action.title) { action.handler() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            // The answer affordance replaces the chat field while a question is
            // up: one input at a time, and the question is the urgent one.
            if let question = host.headQuestion {
                QuestionAffordanceView(
                    question: question,
                    pendingCount: max(0, host.outstandingQuestions.count - 1),
                    text: $chatText,
                    canListen: host.isSpeechInputAvailable,
                    isListening: host.isListening,
                    misheard: host.lastSpeechMisheard,
                    onListen: {
                        Task {
                            if host.isListening {
                                await host.stopListening()
                            } else {
                                await host.listenForAnswer()
                            }
                        }
                    },
                    onAnswer: { content in
                        let id = question.id
                        chatText = ""
                        Task { await host.answer(id, with: content) }
                    },
                    onDecline: {
                        let id = question.id
                        chatText = ""
                        Task { await host.decline(id) }
                    }
                )
            } else if model.chatEnabled {
                TextField("Say something…", text: $chatText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                    .onSubmit {
                        let text = chatText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        chatText = ""
                        model.onChatSubmit?(text)
                    }
            }
        }
        .animation(.spring(duration: 0.25), value: host.speech)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onHover { hovering = $0 }
    }
}

/// How the human answers the question in the bubble.
///
/// Only the head question gets controls — the pet has one attention surface,
/// and stacking affordances would make the urgent one harder to find, not
/// easier. Anything waiting behind it shows as a quiet count that opens the
/// queue window, which is where questions live.
struct QuestionAffordanceView: View {
    let question: QuestionRecord
    let pendingCount: Int
    @Binding var text: String
    /// Only shown when a host installed speech input *and* the build supports
    /// it — an always-present mic that cannot work is worse than none.
    let canListen: Bool
    let isListening: Bool
    let misheard: String?
    let onListen: () -> Void
    let onAnswer: (AnswerContent) -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            switch question.respond.form {
            case .confirm:
                HStack(spacing: 6) {
                    Button(question.respond.yesLabel ?? "Yes") { onAnswer(.confirm(true)) }
                        .keyboardShortcut(.defaultAction)
                    Button(question.respond.noLabel ?? "No") { onAnswer(.confirm(false)) }
                }
            case .choice:
                HStack(spacing: 6) {
                    ForEach(Array((question.respond.choices ?? []).enumerated()), id: \.offset) { index, option in
                        Button(option) { onAnswer(.choice(option, index: index)) }
                    }
                }
            case .text:
                HStack(spacing: 6) {
                    TextField(question.respond.placeholder ?? "Your answer…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .onSubmit { submitText() }
                    Button("Send") { submitText() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack(spacing: 8) {
                if canListen {
                    Button(action: onListen) {
                        Image(systemName: isListening ? "mic.fill" : "mic")
                    }
                    .help(isListening ? "Listening — click to stop" : "Answer out loud")
                    .foregroundStyle(isListening ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                // Declining is a real answer to record, distinct from dismissing
                // the bubble and from answering "no".
                Button("Not now", action: onDecline)
                    .buttonStyle(.link)
                    .controlSize(.small)
                if pendingCount > 0 {
                    Text("\(pendingCount) more waiting")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let misheard {
                Text("Didn't catch “\(misheard)” — try again or use the buttons.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func submitText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAnswer(.text(trimmed))
    }
}

/// Comic-style speech bubble shown above the sprite.
public struct SpeechBubbleView: View {
    let bubble: SpeechBubble

    public init(bubble: SpeechBubble) {
        self.bubble = bubble
    }

    public var body: some View {
        Text(bubble.text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 240)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            )
            .fixedSize(horizontal: false, vertical: true)
    }
}
