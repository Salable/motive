import AppKit
import SwiftUI
import MotiveCore
import MotiveSprite

/// The borderless, transparent, always-on-top desktop window that hosts a
/// sprite. Drag anywhere to move it. This is the "app layer" surface — later
/// milestones add chat, text blobs, and action buttons around the sprite.
@MainActor
public final class SpriteBoxWindow {
    public let panel: NSPanel
    public let host: SpriteHost

    public struct Options: Sendable {
        /// Sprite display size in points (frame aspect is preserved).
        public var spriteSize: CGFloat
        public var alwaysOnTop: Bool
        public var pixelated: Bool

        public init(spriteSize: CGFloat = 160, alwaysOnTop: Bool = true, pixelated: Bool = false) {
            self.spriteSize = spriteSize
            self.alwaysOnTop = alwaysOnTop
            self.pixelated = pixelated
        }
    }

    public init(host: SpriteHost, options: Options = Options()) {
        self.host = host

        let content = SpriteBoxContent(host: host, pixelated: options.pixelated)
        let hosting = NSHostingView(rootView: content)

        let size = NSSize(width: options.spriteSize, height: options.spriteSize + SpriteBoxContent.bubbleReserve)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = options.alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting
        self.panel = panel
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
}

struct SpriteBoxContent: View {
    /// Vertical points reserved above the sprite for the speech bubble.
    static let bubbleReserve: CGFloat = 96

    @ObservedObject var host: SpriteHost
    let pixelated: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let bubble = host.speech {
                SpeechBubbleView(bubble: bubble)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            } else {
                Spacer().frame(height: Self.bubbleReserve)
            }
            SpriteView(host: host, pixelated: pixelated)
        }
        .animation(.spring(duration: 0.25), value: host.speech)
        .padding(8)
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
