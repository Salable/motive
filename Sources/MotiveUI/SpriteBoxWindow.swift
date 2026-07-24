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

        public init(
            spriteSize: CGFloat = 160,
            alwaysOnTop: Bool = true,
            pixelated: Bool = false,
            chatEnabled: Bool = false
        ) {
            self.spriteSize = spriteSize
            self.alwaysOnTop = alwaysOnTop
            self.pixelated = pixelated
            self.chatEnabled = chatEnabled
        }
    }

    final class Model: ObservableObject {
        @Published var spriteSize: CGFloat = 160
        @Published var pixelated = false
        @Published var chatEnabled = false
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
    static let chromeReserve: CGFloat = 148

    @ObservedObject var host: SpriteHost
    @ObservedObject var model: SpriteBoxWindow.Model
    @State private var chatText = ""

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

            if !model.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.actions) { action in
                        Button(action.title) { action.handler() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            if model.chatEnabled {
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
